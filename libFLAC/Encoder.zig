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
config: Config,

// Context
writer: *std.Io.Writer,

// One time allocation
/// Channel 1~8, or stereo: [left right mid side(conditional)] + raw[mid side(conditional)]
residuals: [8][*]i32 = undefined,
side_samples_64: [*]i64 = undefined, // Conditional

const MID_RES = 2;
const MID_RAW = 4;
const SIDE_RES = 3;
const SIDE_RAW = 5;

// -- Initializer --

/// Allocate one time allocated buffers used internally conditionally
pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, config: Config, bit_depth: u8) error{OutOfMemory}!FlacEncoder {
    var result: FlacEncoder = .{ .writer = writer, .config = config };

    switch (config.channels) {
        _ => {
            const channels = config.channels.getNum();
            const slice = try allocator.alloc(i32, config.block_size * channels);
            for (0..channels) |i| {
                result.residuals[i] = slice[config.block_size * i ..].ptr;
            }
        },
        .stereo_auto => {
            const channels_32: u8 = if (bit_depth == 32) 5 else 6;
            const slice_32 = try allocator.alloc(i32, config.block_size * channels_32);
            errdefer allocator.free(slice_32);
            if (bit_depth == 32) {
                result.side_samples_64 = (try allocator.alloc(i64, config.block_size)).ptr;
            }
            const idx: []const usize = if (bit_depth == 32)
                &.{ 0, 1, 2, 3, MID_RAW }
            else
                &.{ 0, 1, 2, 3, 4, 5 };
            for (idx, 0..) |i, c| {
                result.residuals[i] = slice_32[c * config.block_size ..].ptr;
            }
        },
    }

    return result;
}

/// Clean up allocated slices
pub fn deinit(self: @This(), allocator: std.mem.Allocator, bit_depth: u8) void {
    switch (self.config.channels) {
        _ => allocator.free(self.residuals[0][0 .. self.config.channels.getNum() * self.config.block_size]),
        else => {
            const channels_32: u8 = if (bit_depth == 32) 5 else 6;
            allocator.free(self.residuals[0][0 .. self.config.block_size * channels_32]);
            if (bit_depth == 32) allocator.free(self.side_samples_64[0..self.config.block_size]);
        },
    }
}

// -- Methods --

/// Write a frame from `MultiChannelIter` with block__size specified \
/// Only 2 channels are allowed if `config.stereo` != `.indep` \
/// \
/// return:
/// - `Bytes of frame` for updating stream info
/// - `Error` when writing
pub fn writeFrame(
    self: @This(),
    samples: []const []const i32,
    frame_idx: u36,
    streaminfo: metadata.StreamInfo,
) error{WriteFailed}!u24 {
    std.debug.assert(samples.len != 0 and
        ((samples.len == @intFromEnum(self.config.channels) and @as(u8, @intFromEnum(self.config.channels)) <= 8) or
            (samples.len == 2 and self.config.channels == .stereo_auto)));
    std.debug.assert(samples[0].len != 0 and samples.len <= self.config.block_size);

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        for (0..samples.len - 1) |i|
            std.debug.assert(samples[i].len == samples[i + 1].len);
    }

    var fwriter_buf: [1024]u64 = undefined;
    var fwriter: FrameWriter = .init(self.writer, &fwriter_buf);

    const sample_size: u6 = streaminfo.bit_depth;
    const block_size: u16 = @intCast(samples[0].len);
    const ch_type, const subframe_types = self.processChannels(samples, streaminfo.bit_depth);

    // Write header start
    try fwriter.writeHeader(
        true,
        block_size,
        streaminfo.sample_rate,
        if (ch_type == .Indep)
            .simple(streaminfo.channels)
        else
            @enumFromInt(@intFromEnum(ch_type) + 7),
        sample_size,
        frame_idx,
    );

    if (ch_type == .Indep) {
        for (samples, subframe_types[0..samples.len]) |s, ty| {
            try writeChannelSubframe(i32, ty, s, &fwriter, streaminfo.bit_depth);
        }
        // Close subframe
        try fwriter.writeCrc16();
        return fwriter.bytes_written;
    }

    const Ch = enum { left, right, mid, side };
    const channels: [2]Ch = switch (ch_type) {
        .LeftSide => .{ .left, .side },
        .SideRight => .{ .side, .right },
        .MidSide => .{ .mid, .side },
        else => unreachable,
    };

    for (channels) |ch| {
        switch (ch) {
            .left => try writeChannelSubframe(i32, subframe_types[0], samples[0], &fwriter, sample_size),
            .right => try writeChannelSubframe(i32, subframe_types[1], samples[1], &fwriter, sample_size),
            .mid => try writeChannelSubframe(i32, subframe_types[MID_RES], self.residuals[MID_RAW][0..block_size], &fwriter, sample_size),
            .side => if (streaminfo.bit_depth == 32)
                try writeChannelSubframe(i64, subframe_types[SIDE_RES], self.side_samples_64[0..block_size], &fwriter, sample_size + 1)
            else
                try writeChannelSubframe(i32, subframe_types[SIDE_RES], self.residuals[SIDE_RAW][0..block_size], &fwriter, sample_size + 1),
        }
    }

    // Close subframe
    try fwriter.writeCrc16();
    return fwriter.bytes_written;
}

/// Write subframe of a channel (any kind: single, mid, side)
fn writeChannelSubframe(
    SampleT: type,
    subframe_type: SubframeType,
    samples: []const SampleT,
    fwriter: *FrameWriter,
    sample_size: u6,
) error{WriteFailed}!void {
    switch (subframe_type) {
        .Constant => try fwriter.writeConstantSubframe(sample_size, samples[0]),
        .Verbatim => try fwriter.writeVerbatimSubframe(SampleT, sample_size, samples),
        .Fixed => |f| {
            try fwriter.writeFixedSubframe(sample_size, f.residuals, f.order, f.rice_config);
        },
        // else => unreachable, // TODO
    }
}

fn processChannels(
    self: @This(),
    samples: []const []const i32,
    sample_size: u8,
) std.meta.Tuple(&.{ ChType, [8]SubframeType }) {
    const block_size = samples[0].len;

    var ch_subframe_types: [8]SubframeType = undefined;
    const ch_type: ChType = switch (self.config.channels) {
        _ => blk: {
            for (samples, self.residuals[0..samples.len], ch_subframe_types[0..samples.len]) |s, r, *ty| {
                _, ty.* = chooseSubframeEncoding(i32, sample_size, self.config, s, r[0..block_size]);
            }
            break :blk .Indep;
        },
        else => blk: {
            var frame_sizes: [4]u64 = undefined;

            // Generate Mid and Side Channels
            if (sample_size == 32) {
                samples_fn.midSideChannels(
                        i64,
                        samples[0],
                        samples[1],
                        self.residuals[MID_RAW][0..block_size],
                        self.side_samples_64[0..block_size],
                    );
            } else {
                samples_fn.midSideChannels(
                    i32,
                    samples[0],
                    samples[1],
                    self.residuals[MID_RAW][0..block_size],
                    self.residuals[SIDE_RAW][0..block_size],
                );
            }

            const left_right_mid: [3][]const i32 = .{ samples[0], samples[1], self.residuals[MID_RAW][0..block_size] };

            // Left Right Mid
            for (0..3) |i| {
                frame_sizes[i], ch_subframe_types[i] = chooseSubframeEncoding(
                    i32,
                    sample_size,
                    self.config,
                    left_right_mid[i],
                    self.residuals[i][0..block_size],
                );
            }
            // Side
            frame_sizes[SIDE_RES], ch_subframe_types[SIDE_RES] = if (sample_size == 32)
                chooseSubframeEncoding(
                    i64,
                    sample_size,
                    self.config,
                    self.side_samples_64[0..block_size],
                    self.residuals[SIDE_RES][0..block_size],
                )
            else
                chooseSubframeEncoding(
                    i32,
                    sample_size,
                    self.config,
                    self.residuals[SIDE_RAW][0..block_size],
                    self.residuals[SIDE_RES][0..block_size],
                );

            const sum: [4]u64 = .{
                frame_sizes[0] + frame_sizes[1], // Left Right
                frame_sizes[0] + frame_sizes[SIDE_RES], // Left Side
                frame_sizes[SIDE_RES] + frame_sizes[1], // Side Right
                frame_sizes[MID_RES] + frame_sizes[SIDE_RES], // Mid Side
            };

            break :blk @enumFromInt(std.mem.indexOfMin(u64, &sum));
        },
    };
    return .{ ch_type, ch_subframe_types };
}

/// Evaluate best encoding for a subframe
fn chooseSubframeEncoding(
    SampleT: type,
    sample_size: u8,
    config: Config,
    samples: []const SampleT,
    residuals_dest: []i32,
) std.meta.Tuple(&.{ u64, SubframeType }) {
    // -- Constant -- (First priority)
    if (std.mem.allEqual(SampleT, samples[1..], samples[0]))
        return .{ @bitSizeOf(SampleT), .{ .Constant = {} } };

    var subframe_type: SubframeType = .{ .Verbatim = {} }; // Default fallback to Verbatim
    var subframe_size: u64 = @as(usize, samples.len) * @bitSizeOf(SampleT); // Default fallback to Verbatim

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed_prediction.MAX_ORDER) return .{ subframe_size, subframe_type };

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
        ) orelse return .{ subframe_size, subframe_type };

    // Prepare residuals
    fixed_prediction.calcResiduals(SampleT, samples, residuals_dest, best_fixed_order);

    const fixed_size, const rice_config = rice_code.calcRiceParams(
        residuals_dest,
        config.max_rice_order,
        config.max_rice_param,
        sample_size,
        best_fixed_order,
    );
    if (fixed_size < subframe_size) {
        subframe_size = fixed_size;
        subframe_type = .{ .Fixed = .{
            .order = best_fixed_order,
            .residuals = residuals_dest,
            .rice_config = rice_config,
        } };
    }

    return .{ subframe_size, subframe_type };
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
    /// (maximum) block size
    block_size: u16,
    prediction: Prediction,
    channels: Stereo,
    /// Rice partition order: value [0, 15] ([0, 8] for subset)
    max_rice_order: u4,
    /// Rice param limit: value [0, 30] ([0, 14] for rice1 only)
    max_rice_param: u5,

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
        // left_side,
        // side_right,
        // mid_side,
        stereo_auto = 9,
        _,

        pub fn fromNum(channels: u8) Stereo {
            return switch (channels) {
                1...8 => @enumFromInt(channels),
                else => unreachable,
            };
        }

        pub fn getNum(self: Stereo) u8 {
            return switch (self) {
                _ => @intFromEnum(self),
                else => unreachable,
            };
        }
    };

    pub fn default(channels: u8) @This() {
        return .{
            .block_size = 4096,
            .prediction = .fixed,
            .channels = if (channels == 2) .stereo_auto else .fromNum(channels),
            .max_rice_order = 8,
            .max_rice_param = rice_code.MAX_PARAM,
        };
    }
};

const ChType = enum(u8) {
    Indep = 0,
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
