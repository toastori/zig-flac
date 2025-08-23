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
lpc: Setting.LPC = .fixed,
stereo: Setting.Stereo = .auto,
// value [1, 32] ([1, 12] for subset when sample_rate <= 48k)
min_lpc_order: u8 = 0,
max_lpc_order: u8 = 0,
// value [0, 30] (each increase oubles search time)
lpc_round_var: u8 = 0,
// value [0, 15] ([0, 8] for subset)
max_fixed_rice_order: u8 = 8,
max_lpc_rice_order: u8 = 8,

// Context
writer: *std.Io.Writer,

mid_samples: [*]i32 = undefined,
side_samples: [*]i32 = undefined,
side_samples_wide: [*]i64 = undefined,
max_frame_size: usize = undefined,

// -- Initializer --

/// Allocate for `mid_samples`, `side_samples` and `side_samples_wide`
pub fn initSamples(self: *@This(), allocator: std.mem.Allocator, bit_depth: u6, max_frame_size: usize) error{OutOfMemory}!void {
    self.max_frame_size = max_frame_size;
    if (self.stereo == .indep) return;
    self.mid_samples = (try allocator.alloc(i32, max_frame_size)).ptr;
    errdefer allocator.free(self.mid_samples[0..self.max_frame_size]);
    if (bit_depth < 32)
        self.side_samples = (try allocator.alloc(i32, max_frame_size)).ptr
    else
        self.side_samples_wide =  (try allocator.alloc(i64, max_frame_size)).ptr;
}

/// Clean up allocated slices
pub fn deinit(self: @This(), allocator: std.mem.Allocator, bit_depth: u6) void {
    if (self.stereo == .indep) return;
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
    self: *@This(),
    allocator: std.mem.Allocator,
    samples: []const []const i32,
    frame_idx: u36,
    streaminfo: metadata.StreamInfo,
) error{OutOfMemory, WriteFailed}!u24 {
    std.debug.assert(samples.len != 0 and samples[0].len != 0);
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        for (0..samples.len - 1) |i|
            std.debug.assert(samples[i].len == samples[i + 1].len);
    }

    var fwriter: FrameWriter = .init(self.writer);

    const frame_size: u16 = @intCast(samples[0].len);
    const stereo_mode: StereoType = if (samples.len == 2 and self.stereo != .indep)
        chooseStereoMethod(samples, frame_size)
    else
        .LeftRight;

    const mid, const side, const side_wide = switch (stereo_mode) {
        .LeftRight => .{undefined, undefined, undefined},
        .MidSide => blk: {
            if (streaminfo.bit_depth == 32) {
                const m, const s = samples_fn.midSideChannels(i64, samples[0], samples[1], self.mid_samples[0..self.max_frame_size], self.side_samples_wide[0..self.max_frame_size]);
                break :blk .{m, undefined, s};
            } else {
                const m, const s = samples_fn.midSideChannels(i32, samples[0], samples[1], self.mid_samples[0..self.max_frame_size], self.side_samples[0..self.max_frame_size]);
                break :blk .{m, s, undefined};
            }
        },
        else => blk: {
            if (streaminfo.bit_depth == 32) {
                const s = samples_fn.sideChannel(i64, samples[0], samples[1], self.side_samples_wide[0..self.max_frame_size]);
                break :blk .{undefined, undefined, s};
            } else {
                const s = samples_fn.sideChannel(i32, samples[0], samples[1], self.side_samples[0..self.max_frame_size]);
                break :blk .{undefined, s, undefined};
            }
        }
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

    try fwriter.flushBytes(.only16);

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
) error{OutOfMemory, WriteFailed}!void {
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

    var left_prev: @Vector(4, i64) = .{ left[1], left[0], undefined, undefined };
    var right_prev: @Vector(4, i64) = .{ left[1], right[0], undefined, undefined };

    for (2..left.len) |i| {
        const l: i64 = fp.calcResidual(left[i], left_prev, 2);
        const r: i64 = fp.calcResidual(right[i], right_prev, 2);

        sum[LEFT] += @abs(l);
        sum[RIGHT] += @abs(r);
        sum[MID] += @abs(l + r >> 1);
        sum[SIDE] += @abs(l - r);

        left_prev =
            std.simd.shiftElementsRight(left_prev, 1, left[i]);
        right_prev =
            std.simd.shiftElementsRight(right_prev, 1, right[i]);
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
    constant: {
        const first_sample: SampleT = samples[0];
        for (samples[1..]) |sample| {
            if (sample != first_sample) break :constant;
        }
        return .{ .Constant = {} };
    }

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed_prediction.MAX_ORDER) return .{ .Verbatim = {} };

    const verbatim_size: usize = @as(usize, samples.len) * @bitSizeOf(SampleT);
    var subframe_type: SubframeType = .{ .Verbatim = {} }; // Default fallback to Verbatim

    // -- Fixed Prediction --
    const best_fixed_order = (if (sample_size < 28)
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            false,
        )
    else
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            true,
        )) orelse return subframe_type;

    // Prepare residuals
    const residuals = try allocator.alloc(i32, samples.len);
    samples_fn.fixedResiduals(SampleT, best_fixed_order, samples, residuals);

    const fixed_size, const rice_config = rice_code.calcRiceParamFixed(
        residuals,
        0,
        self.max_fixed_rice_order,
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

pub const Setting = struct {
    pub const LPC = enum {
        none,
        fixed, // TODO
    };

    pub const Stereo = enum {
        indep,
        mid_side,
        auto,
    };
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
