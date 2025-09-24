const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");
const samples_fn = @import("samples.zig");
const rice_code = @import("rice_code.zig");
const fixed_prediction = @import("fixed_prediction.zig");

const FrameWriter = @import("FrameWriter.zig");
const MultiChannelIter = @import("samples.zig").MultiChannelIter;
const SingleChannelIter = @import("samples.zig").SingleChannelIter;
const SampleIter = @import("samples.zig").SampleIter;

// -- Constants --

const FlacEncoder = @This();

/// Amount of bytes to skip when skipping Header
/// so you can seek to 0 and write it after calculating
/// MD5 checksums
// Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
pub const HEADER_SIZE = 4 + 1 + 3 + 34;

// -- Members --

// Settings
config: Config = .test_default,

// Context
writer: *std.Io.Writer,

// One time allocation
mid_samples: [*]i32 = undefined, // Conditional
side_samples: [*]i32 = undefined, // Conditional
side_samples_wide: [*]i64 = undefined, // Conditional
max_frame_size: usize,

// -- Initializer --

/// Allocate one time allocated buffers used internally conditionally
pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, setting: Config, bit_depth: u8, max_frame_size: usize) error{OutOfMemory}!FlacEncoder {
    var result: FlacEncoder = .{ .writer = writer, .max_frame_size = max_frame_size };
    if (setting.stereo == .indep) return result;
    result.mid_samples = (try allocator.alloc(i32, max_frame_size)).ptr;
    errdefer allocator.free(result.mid_samples[0..max_frame_size]);
    if (bit_depth < 32)
        result.side_samples = (try allocator.alloc(i32, max_frame_size)).ptr
    else
        result.side_samples_wide = (try allocator.alloc(i64, max_frame_size)).ptr;
    return result;
}

/// Clean up allocated slices
pub fn deinit(self: @This(), allocator: std.mem.Allocator, bit_depth: u6) void {
    if (self.config.stereo == .indep) return;
    allocator.free(self.mid_samples[0..self.max_frame_size]);
    if (bit_depth < 32)
        allocator.free(self.side_samples[0..self.max_frame_size])
    else
        allocator.free(self.side_samples_wide[0..self.max_frame_size]);
}

// -- Methods --

/// Write a frame from `MultiChannelIter` with block__size specified \
/// \
/// return:
/// - `Bytes of frame` for updating stream info
/// - `Error` when writing
pub fn writeFrame(
    self: @This(),
    allocator: std.mem.Allocator,
    samples: []const []const i32,
    frame_idx: u36,
    streaminfo: metadata.StreamInfo,
) error{ OutOfMemory, WriteFailed }!u24 {
    std.debug.assert(samples.len != 0 and samples[0].len != 0);
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        for (0..samples.len - 1) |i|
            std.debug.assert(samples[i].len == samples[i + 1].len);
    }

    var fwriter_buf: [1024]u64 = undefined;
    var fwriter: FrameWriter = .init(self.writer, &fwriter_buf);

    const frame_size: u16 = @intCast(samples[0].len);
    const stereo_mode: StereoType = if (samples.len == 2 and self.config.stereo != .indep)
        chooseStereoMethod(samples, frame_size)
    else
        .LeftRight;

    const mid, const side, const side_wide = switch (stereo_mode) {
        .LeftRight => .{ undefined, undefined, undefined },
        .MidSide => blk: {
            if (streaminfo.bit_depth == 32) {
                const m, const s = samples_fn.midSideChannels(i64, samples[0], samples[1], self.mid_samples[0..self.max_frame_size], self.side_samples_wide[0..self.max_frame_size]);
                break :blk .{ m, undefined, s };
            } else {
                const m, const s = samples_fn.midSideChannels(i32, samples[0], samples[1], self.mid_samples[0..self.max_frame_size], self.side_samples[0..self.max_frame_size]);
                break :blk .{ m, s, undefined };
            }
        },
        else => blk: {
            if (streaminfo.bit_depth == 32) {
                const s = samples_fn.sideChannel(i64, samples[0], samples[1], self.side_samples_wide[0..self.max_frame_size]);
                break :blk .{ undefined, undefined, s };
            } else {
                const s = samples_fn.sideChannel(i32, samples[0], samples[1], self.side_samples[0..self.max_frame_size]);
                break :blk .{ undefined, s, undefined };
            }
        },
    };

    // Write header start
    try fwriter.writeHeader(
        true,
        frame_size,
        streaminfo.sample_rate,
        if (stereo_mode == .LeftRight)
            .simple(streaminfo.channels)
        else
            @enumFromInt(@intFromEnum(stereo_mode) + 7),
        streaminfo.bit_depth,
        frame_idx,
    );

    // Write a subframe per channel
    switch (stereo_mode) {
        .LeftRight => for (0..streaminfo.channels) |i| {
            try self.writeChannelSubframe(i32, allocator, samples[i], &fwriter, streaminfo.bit_depth);
        },
        .LeftSide => { // Left
            try self.writeChannelSubframe(i32, allocator, samples[0], &fwriter, streaminfo.bit_depth);
        },
        .MidSide => { // Mid
            try self.writeChannelSubframe(i32, allocator, mid, &fwriter, streaminfo.bit_depth);
        },
        else => {},
    }

    if (stereo_mode != .LeftRight) { // Side
        if (streaminfo.bit_depth < 32) {
            try self.writeChannelSubframe(i32, allocator, side, &fwriter, streaminfo.bit_depth + 1);
        } else {
            try self.writeChannelSubframe(i64, allocator, side_wide, &fwriter, streaminfo.bit_depth + 1);
        }
    }

    if (stereo_mode == .SideRight) { // Right
        try self.writeChannelSubframe(i32, allocator, samples[1], &fwriter, streaminfo.bit_depth);
    }

    // Close subframe
    try fwriter.writeCrc16();
    return fwriter.bytes_written;
}

/// Write subframe of a channel (any kind: single, mid, side)
fn writeChannelSubframe(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
    samples: []const SampleT,
    fwriter: *FrameWriter,
    sample_size: u6,
) error{ OutOfMemory, WriteFailed }!void {
    std.debug.assert(samples.len != 0);
    const subframe_type = try self.chooseSubframeEncoding(
        SampleT,
        allocator,
        sample_size,
        samples,
    );

    switch (subframe_type) {
        .Constant => try fwriter.writeConstantSubframe(sample_size, samples[0]),
        .Verbatim => try fwriter.writeVerbatimSubframe(SampleT, sample_size, samples),
        .Fixed => |f| {
            defer allocator.free(f.residuals);
            try fwriter.writeFixedSubframe(sample_size, f.residuals, f.order, f.rice_config);
        },
        // else => unreachable, // TODO
    }
}

// Copy from flake
/// Evaluate best method to encode Stereo frame \
/// Channels must be 2
fn chooseStereoMethod(
    samples: []const []const i32,
    frame_size: u16,
) StereoType {
    const fp = @import("fixed_prediction.zig");

    std.debug.assert(samples.len == 2);

    var sum: [4]u64 = .{ 0, 0, 0, 0 };
    const LEFT, const RIGHT, const MID, const SIDE = .{ 0, 1, 2, 3 };

    const left = samples[0];
    const right = samples[1];


    for (2..left.len) |i| {
        const l: i64 = fp.calcResidual(i32, i64, left, i, 2);
        const r: i64 = fp.calcResidual(i32, i64, right, i, 2);

        sum[LEFT] += @abs(l);
        sum[RIGHT] += @abs(r);
        sum[MID] += @abs(l + r >> 1);
        sum[SIDE] += @abs(l - r);
    }
    for (&sum) |*s| {
        _, const bits = rice_code.findOptimalParamEstimate(2 * s.*, frame_size);
        s.* = bits;
    }

    const score: [4]u64 = .{
        sum[LEFT] + sum[RIGHT], // Left Right
        sum[LEFT] + sum[SIDE], // Left Side
        sum[SIDE] + sum[RIGHT], // Side Right
        sum[MID] + sum[SIDE], // Mid Side
    };

    return @enumFromInt(std.mem.indexOfMin(u64, &score));
}

/// Evaluate best encoding for a subframe
fn chooseSubframeEncoding(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
    sample_size: u8,
    samples: []const SampleT,
) error{OutOfMemory}!SubframeType {
    // -- Constant -- (First priority)
    if (std.mem.allEqual(SampleT, samples[1..], samples[0]))
        return .{ .Constant = {} };

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed_prediction.MAX_ORDER) return .{ .Verbatim = {} };

    const verbatim_size: usize = @as(usize, samples.len) * @bitSizeOf(SampleT);
    var subframe_type: SubframeType = .{ .Verbatim = {} }; // Default fallback to Verbatim

    // -- Fixed Prediction --
    const best_fixed_order = if (sample_size < 28)
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            false,
        ) orelse unreachable
    else
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            true,
        ) orelse return subframe_type;

    // Prepare residuals
    const residuals = try allocator.alloc(i32, samples.len);
    samples_fn.fixedResiduals(SampleT, best_fixed_order, samples, residuals);

    const fixed_size, const rice_config = rice_code.calcRiceParamFixed(
        residuals,
        self.config.max_rice_order,
        self.config.max_rice_param,
        sample_size,
        best_fixed_order,
    );
    if (fixed_size < verbatim_size) {
        subframe_type = .{ .Fixed = .{
            .order = best_fixed_order,
            .residuals = residuals,
            .rice_config = rice_config,
        } };
    } else {
        allocator.free(residuals);
    }

    return subframe_type;
}

/// Skip signature and Streaminfo by writing 0s \
/// Expect file cursor at 0 \
/// Might be faster than `file.seekTo` while saving a syscall? \
/// \
/// return:
/// - `Error` while writing
pub fn skipHeader(self: @This()) error{WriteFailed}!void {
    // Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
    try self.writer.splatByteAll(0, HEADER_SIZE);
}

/// Write Signature and Streaminfo \
/// Expect file cursor at 0 \
/// \
/// return:
/// - `Error` while writing
pub fn writeHeader(self: @This(), streaminfo: metadata.StreamInfo, is_last_metadata: bool) error{WriteFailed}!void {
    // Write Signature
    try self.writer.writeAll("fLaC");

    // Write Streaminfo Block Header
    try self.writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .StreamInfo }, .little);
    try self.writer.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try self.writer.writeAll(&streaminfo.bytes());
}

/// Write Vendor and Vorbis Comments \
/// \
/// return:
/// - `Error` while writing
pub fn writeVorbisComment(self: @This(), is_last_metadata: bool) error{WriteFailed}!void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    // Write VorbisComment Block Header
    try self.writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .VorbisComment }, .little);
    try self.writer.writeInt(u24, @intCast(vendor.len + 8), .big); // vendor len + vendor_len len(4) + tags_len len(4)
    // Write vendor string
    try self.writer.writeInt(u32, @intCast(vendor.len), .little);
    try self.writer.writeAll(vendor);
    // Write comments
    try self.writer.writeInt(u32, 0, .little); // tags len (4 bytes) (no tag now)
}

// -- Types --

pub const Config = struct {
    prediction: Prediction,
    stereo: Stereo,
    /// Rice partition order: value [0, 15] ([0, 8] for subset)
    max_rice_order: u8,
    /// Rice param limit: value [0, 30] ([0, 14] for rice1 only)
    max_rice_param: u8,

    /// linear prediction
    /// - Lax within range [1, 32]
    /// - Subset within range [1, 12] for sampling rates <= 48k
    pub const Prediction = enum(u8) {
        fixed = 0,
        none = 0xFF,
        _,

        fn linear(self: @This()) u8 {
            return switch (@intFromBool(self)) {
                1...32 => |i| i,
                else => unreachable,
            };
        }
    };

    /// Stereo decorrelation option
    pub const Stereo = enum(u8) {
        indep,
        // left_side,
        // side_right,
        // mid_side,
        auto,
    };

    pub const test_default: @This() = .{ .prediction = .fixed, .stereo = .auto, .max_rice_order = 8, .max_rice_param = rice_code.MAX_PARAM };
};

const StereoType = enum(u8) {
    LeftRight = 0,
    LeftSide = 1,
    SideRight = 2,
    MidSide = 3,
};

const SubframeType = union(enum) {
    Constant: void,
    Verbatim: void,
    Fixed: struct {
        order: u8,
        residuals: []i32, // need free
        rice_config: rice_code.RiceConfig,
    },
    // Linear: struct {
    //     order: u8,
    //     rice_order: u8 = undefined,
    //     partition_order: u8 = undefined,
    //     residuals: []isize, // need free
    // },
};
