const std = @import("std");

const fixed = @import("fixed.zig");
const metadata = @import("metadata.zig");
const rice = @import("rice.zig");
const simd = @import("simd.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const FrameWriter = @import("frame_writer.zig");
const Md5 = @import("md5.zig").Md5;
const StreamInfo = metadata.StreamInfo;
const Encoder = @This();

config: Config,
writer: *Writer,
md5: Md5,
// One time allocation
/// Raw samples. channel 1~8, or stereo [left right mid side(32bits)]
samples: [8][*]align(simd.VEC_ALIGN32) i32 = undefined,
/// Wide raw value samples for 32-bits stereo's side channel
samples64: [*]align(simd.VEC_ALIGN64) i64 = undefined, // Conditional
/// Residuals. channel 1~8, or stereo: [left right mid side]
residuals: [8][*]align(simd.VEC_ALIGN32) i32 = undefined,

// -- Constants --

const guard_len32 = std.simd.suggestVectorLength(i32) orelse 4;
const guard_len64 = std.simd.suggestVectorLength(i64) orelse 4;
/// currently have no difference due to no lpc support yet
const guard_len_front32 = std.simd.suggestVectorLength(i32) orelse 4;
/// currently have no difference due to no lpc support yet
const guard_len_front64 = std.simd.suggestVectorLength(i64) orelse 4;

// -- Initializer --

/// Allocate one time allocated buffers used internally conditionally
pub fn init(
    gpa: Allocator,
    writer: *Writer,
    config: Config,
) Allocator.Error!Encoder {
    std.debug.assert(config.bit_depth_max > 0 and config.bit_depth_max % 4 == 0);
    std.debug.assert(config.block_size_max > 0);
    std.debug.assert(config.channels_max > 0 and config.channels_max <= 8);

    var result: Encoder = .{ .writer = writer, .config = config, .md5 = .init(.{}) };
    // increase block_size to the multiple of vector length
    // TODO 0.17.x replace with @divCeil(config.blovk_size_max, simd.VEC_ALIGN) * simd.VEC_ALIGN;
    const block_len32 =
        @divFloor(config.block_size_max + simd.LEN32 - 1, simd.LEN32) * simd.LEN32;
    const block_len64 =
        @divFloor(config.block_size_max + simd.LEN64 - 1, simd.LEN64) * simd.LEN64;
    const buf_count32 =
        if (config.stereo_decorrelation == true and config.channels_max != 1)
            @max(config.channels_max, 4)
        else
            config.channels_max;

    // 32 bits raw samples buffers
    // [GUARD_FRONT] [[CH]...[CH]] [GUARD]
    const sample_buf_len = guard_len_front32 + block_len32 * buf_count32 + guard_len32;

    const sample_buf = try gpa.alignedAlloc(i32, simd.ALIGNMENT32, sample_buf_len);
    errdefer gpa.free(sample_buf);

    for (0..buf_count32) |i| {
        result.samples[i] =
            @alignCast(sample_buf[block_len32 * i + guard_len_front32 ..].ptr);
    }

    // 32 bits residuals buffers
    // [GUARD_FRONT] [[CH][GUARD]..[CH][GUARD]]
    const res_buf_len = guard_len_front32 + (block_len32 + guard_len32) * buf_count32;

    const res_buf = try gpa.alignedAlloc(i32, simd.ALIGNMENT32, res_buf_len);
    errdefer gpa.free(res_buf);

    for (0..buf_count32) |i| {
        result.residuals[i] =
            @alignCast(res_buf[guard_len_front32 + (block_len32 + guard_len32) * i ..].ptr);
    }

    // 64 bits side samples buffer
    if (config.bit_depth_max == 32) {
        if (config.stereo_decorrelation == true and config.channels_max != 1) {
            // [GUARD_FRONT] [CH] [GUARD]
            const wsample_buf_len = guard_len_front64 + block_len64 + guard_len64;
            const wsample_buf = try gpa.alignedAlloc(i64, simd.ALIGNMENT64, wsample_buf_len);
            result.samples64 =
                @alignCast(wsample_buf[guard_len_front64..].ptr);
        }
    }

    return result;
}

/// Clean up allocated slices
pub fn deinit(self: @This(), gpa: Allocator) void {
    const config = self.config;

    // increase block_size to the multiple of vector alignment
    // TODO 0.17.x replace with @divCeil(config.blovk_size_max, simd.VEC_ALIGN) * simd.VEC_ALIGN;
    const block_len32 =
        @divFloor(config.block_size_max + simd.LEN32 - 1, simd.LEN32) * simd.LEN32;
    const block_len64 =
        @divFloor(config.block_size_max + simd.LEN64 - 1, simd.LEN64) * simd.LEN64;
    const buf_count32 =
        if (config.stereo_decorrelation == true and config.channels_max != 1)
            @max(config.channels_max, 4)
        else
            config.channels_max;

    // 32 bits raw samples buffers
    // [GUARD_FRONT] [[CH]...[CH]] [GUARD]
    const sample_buf_len = guard_len_front32 + block_len32 * buf_count32 + guard_len32;
    const sample_buf_start: [*]i32 =
        @ptrFromInt(@intFromPtr(self.samples[0]) - (guard_len_front32 * @sizeOf(i32)));
    gpa.free(sample_buf_start[0..sample_buf_len]);

    // 32 bits residuals buffers
    // [GUARD_FRONT] [[CH][GUARD]..[CH][GUARD]]
    const res_buf_len = guard_len_front32 + (block_len32 + guard_len32) * buf_count32;
    const res_buf_start: [*]i32 =
        @ptrFromInt(@intFromPtr(self.residuals[0]) - (guard_len_front32 * @sizeOf(i32)));
    gpa.free(res_buf_start[0..res_buf_len]);

    // 64 bits side samples buffer
    if (config.bit_depth_max == 32) {
        if (config.stereo_decorrelation == true and config.channels_max != 1) {
            // [GUARD_FRONT] [CH] [GUARD]
            const wsample_buf_len = guard_len_front64 + block_len64 + guard_len64;
            const wsample_buf_start: [*]i64 =
                @ptrFromInt(@intFromPtr(self.samples64) - (guard_len_front64 * @sizeOf(i64)));
            gpa.free(wsample_buf_start[0..wsample_buf_len]);
        }
    }
}

// -- Methods --

pub fn finalizeStreamInfoMd5(self: *Encoder, streaminfo: *StreamInfo) void {
    self.md5.final(&streaminfo.md5);
}

/// Skip signature and Streaminfo by writing 0s.
/// Expect call at start of the FLAC file.
///
/// return:
/// - `Error` while writing
pub fn skipHeader(self: @This()) Writer.Error!void {
    // Amount of bytes to skip when skipping Header
    // so you can seek to 0 and write it after calculating MD5 checksums
    // Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
    const HEADER_SIZE = 4 + 1 + 3 + 34;

    // Might be faster than `file.seekTo` while saving a syscall?
    try self.writer.splatByteAll(0, HEADER_SIZE);
}

/// Write Signature and Streaminfo
/// Expect call at start of the FLAC file
///
/// return:
/// - `Error` while writing
pub fn writeHeader(self: @This(), streaminfo: StreamInfo, last_metadata: bool) Writer.Error!void {

    // Write Signature
    try self.writer.writeAll("fLaC");

    // Write Streaminfo Block Header
    try self.writer.writeStruct(
        metadata.BlockHeader{ .is_last_block = last_metadata, .block_type = .StreamInfo },
        .little,
    );
    try self.writer.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try self.writer.writeAll(&streaminfo.bytes());
}

/// Write Vendor and Vorbis Comments
///
/// return:
/// - `Error` while writing
pub fn writeVorbisComment(self: @This(), last_metadata: bool) Writer.Error!void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    // Write VorbisComment Block Header
    try self.writer.writeStruct(
        metadata.BlockHeader{ .is_last_block = last_metadata, .block_type = .VorbisComment },
        .little,
    );
    // vendor len + vendor_len len(4) + tags_len len(4)
    try self.writer.writeInt(u24, @intCast(vendor.len + 8), .big);
    // Write vendor string
    try self.writer.writeInt(u32, @intCast(vendor.len), .little);
    try self.writer.writeAll(vendor);
    // Write comments
    // tags len (4 bytes) (no tag now)
    try self.writer.writeInt(u32, 0, .little);
}

/// Write a frame from `MultiChannelIter` with block__size specified.
/// Only 2 channels are allowed if `config.stereo` != `.indep`.
///
/// return:
/// - `Bytes of frame` for updating stream info
/// - `Error` when writing
pub fn writeFrame(self: @This(), frame_number: u36, frame_info: FrameInfo) Writer.Error!u24 {
    std.debug.assert(frame_info.samples_count != 0);

    var fwriter_buf: [1024]u64 = undefined;
    var fwriter: FrameWriter = .init(self.writer, &fwriter_buf);

    const subframe_type = self.processChannels(
        frame_info.bit_depth,
        frame_info.channels,
        frame_info.samples_count,
    );

    // Write header start
    try fwriter.writeHeader(
        frame_number,
        frame_info.bit_depth,
        switch (subframe_type) {
            .indep => .simple(frame_info.channels),
            .stereo_auto => |sa| switch (sa.ch_type) {
                .indep => .simple(2),
                .left_side, .side_right, .mid_side => @enumFromInt(@intFromEnum(sa.ch_type) + 7),
            },
        },
        frame_info.samples_count,
        frame_info.sample_rate,
        true, // is_fixed_size
    );

    // Write independent channels
    if (subframe_type == .indep) {
        for (0..frame_info.channels) |ch| {
            try writeChannelSubframe(
                i32,
                &fwriter,
                subframe_type.indep[ch],
                self.samples[ch][0..frame_info.samples_count],
                frame_info.bit_depth,
            );
        }
        // Close subframe
        try fwriter.writeCrc16();
        return fwriter.bytes_written;
    }

    // else
    // Write stereo_auto channels
    const Ch = enum { left, right, mid, side };
    const channels: [2]Ch = switch (subframe_type.stereo_auto.ch_type) {
        .indep => .{ .left, .right },
        .left_side => .{ .left, .side },
        .side_right => .{ .side, .right },
        .mid_side => .{ .mid, .side },
    };

    for (channels) |ch| {
        switch (ch) {
            .left => try writeChannelSubframe(
                i32,
                &fwriter,
                subframe_type.stereo_auto.left,
                self.autoSamples(.left, frame_info.samples_count),
                frame_info.bit_depth,
            ),
            .right => try writeChannelSubframe(
                i32,
                &fwriter,
                subframe_type.stereo_auto.right,
                self.autoSamples(.right, frame_info.samples_count),
                frame_info.bit_depth,
            ),
            .mid => try writeChannelSubframe(
                i32,
                &fwriter,
                subframe_type.stereo_auto.mid,
                self.autoSamples(.mid, frame_info.samples_count),
                frame_info.bit_depth,
            ),
            .side => {
                if (frame_info.bit_depth == 32) {
                    try writeChannelSubframe(
                        i64,
                        &fwriter,
                        subframe_type.stereo_auto.side,
                        self.samples64[0..frame_info.samples_count],
                        frame_info.bit_depth + 1,
                    );
                } else {
                    try writeChannelSubframe(
                        i32,
                        &fwriter,
                        subframe_type.stereo_auto.side,
                        self.autoSamples(.side, frame_info.samples_count),
                        frame_info.bit_depth + 1,
                    );
                }
            },
        }
    }

    // Close subframe
    try fwriter.writeCrc16();
    return fwriter.bytes_written;
}

/// Write subframe of a channel (any kind: single, mid, side)
fn writeChannelSubframe(
    T: type,
    fwriter: *FrameWriter,
    subframe_type: SubframeType.Encoding,
    samples: []align(simd.VEC_ALIGN_OF(T)) const T,
    bit_depth: u6,
) Writer.Error!void {
    switch (subframe_type) {
        .constant => |c| try fwriter.writeConstantSubframe(
            bit_depth,
            c.sample,
        ),
        .verbatim => try fwriter.writeVerbatimSubframe(
            T,
            bit_depth,
            samples,
        ),
        .fixed => |f| try fwriter.writeFixedSubframe(
            T,
            bit_depth,
            samples,
            f.residuals,
            f.order,
            f.rice_config,
        ),
        // else => unreachable, // TODO
    }
}

/// Decide encoding of each channels, and ch_type for stereo audio
fn processChannels(
    self: @This(),
    bit_depth: u6,
    channels: u4,
    samples_count: u16,
) SubframeType {
    blk: switch (channels) {
        2 => {
            if (self.config.stereo_decorrelation == false) continue :blk 0;

            var result: SubframeType = .{ .stereo_auto = undefined };
            var frame_size_l: u64 = undefined;
            var frame_size_r: u64 = undefined;
            var frame_size_m: u64 = undefined;
            var frame_size_s: u64 = undefined;

            // Generate Mid and Side Channels
            if (bit_depth == 32) {
                for (
                    self.autoSamples(.left, samples_count),
                    self.autoSamples(.right, samples_count),
                    self.autoSamples(.mid, samples_count),
                    self.samples64[0..samples_count],
                ) |left, right, *mid, *side| {
                    mid.* = @intCast((@as(i64, left) + @as(i64, right)) >> 1);
                    side.* = @as(i64, left) - @as(i64, right);
                }
            } else {
                for (
                    self.autoSamples(.left, samples_count),
                    self.autoSamples(.right, samples_count),
                    self.autoSamples(.mid, samples_count),
                    self.autoSamples(.side, samples_count),
                ) |left, right, *mid, *side| {
                    mid.* = (left + right) >> 1;
                    side.* = left - right;
                }
            }

            // Evaulate each channels
            // Left
            frame_size_l, result.stereo_auto.left = chooseSubframeEncoding(
                i32,
                self.autoSamples(.left, samples_count),
                self.autoResiduals(.left, samples_count),
                bit_depth,
                self.config.max_rice_order,
                self.config.max_rice_param,
            );

            // Right
            frame_size_r, result.stereo_auto.right = chooseSubframeEncoding(
                i32,
                self.autoSamples(.right, samples_count),
                self.autoResiduals(.right, samples_count),
                bit_depth,
                self.config.max_rice_order,
                self.config.max_rice_param,
            );

            // Mid
            frame_size_m, result.stereo_auto.mid = chooseSubframeEncoding(
                i32,
                self.autoSamples(.mid, samples_count),
                self.autoResiduals(.mid, samples_count),
                bit_depth,
                self.config.max_rice_order,
                self.config.max_rice_param,
            );

            // Side
            frame_size_s, result.stereo_auto.side = switch (bit_depth) {
                32 => chooseSubframeEncoding(
                    i64,
                    self.samples64[0..samples_count],
                    self.autoResiduals(.side, samples_count),
                    bit_depth,
                    self.config.max_rice_order,
                    self.config.max_rice_param,
                ),
                else => chooseSubframeEncoding(
                    i32,
                    self.autoSamples(.side, samples_count),
                    self.autoResiduals(.side, samples_count),
                    bit_depth,
                    self.config.max_rice_order,
                    self.config.max_rice_param,
                ),
            };

            // Choose stereo decorrelation format
            const sum: [4]u64 = .{ // match the order as ChType
                frame_size_l + frame_size_r, // left right
                frame_size_l + frame_size_s, // left side
                frame_size_s + frame_size_r, // side right
                frame_size_m + frame_size_s, // mid  side
            };
            result.stereo_auto.ch_type = @enumFromInt(std.mem.indexOfMin(u64, &sum));

            return result;
        },
        else => {
            var result: SubframeType = .{ .indep = undefined };
            for (0..channels) |ch| {
                _, result.indep[ch] = chooseSubframeEncoding(
                    i32,
                    self.samples[ch][0..samples_count],
                    self.residuals[ch][0..samples_count],
                    bit_depth,
                    self.config.max_rice_order,
                    self.config.max_rice_param,
                );
            }
            return result;
        },
    }
}

/// Evaluate best encoding for a subframe
fn chooseSubframeEncoding(
    T: type,
    samples: []align(simd.VEC_ALIGN_OF(T)) const T,
    residuals_dst: []align(simd.VEC_ALIGN32) i32,
    bit_depth: u6,
    rice_order_max: u4,
    rice_param_max: u5,
) struct { u64, SubframeType.Encoding } {
    // -- Constant -- (First priority)
    if (std.mem.allEqual(T, samples[1..], samples[0])) {
        return .{ @bitSizeOf(T), .{ .constant = .{ .sample = samples[0] } } };
    }

    // Verbatim as default
    var subframe_type: SubframeType.Encoding = .{ .verbatim = {} };
    var subframe_size: u64 = @as(usize, samples.len) * @bitSizeOf(T);

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed.MAX_ORDER) return .{ subframe_size, subframe_type };

    // -- Fixed Prediction --
    const best_fixed_order = if (bit_depth < 28 and T == i32)
        fixed.bestOrder(T, .normal, samples) orelse unreachable
    else
        fixed.bestOrder(T, .wide, samples) orelse return .{ subframe_size, subframe_type };

    // Prepare residuals
    if (bit_depth < 28 and T == i32) {
        fixed.calcResiduals(T, .normal, samples, residuals_dst, best_fixed_order);
    } else {
        fixed.calcResiduals(T, .wide, samples, residuals_dst, best_fixed_order);
    }

    const fixed_size, const rice_config = rice.calcParams(
        residuals_dst,
        rice_order_max,
        rice_param_max,
        bit_depth,
        best_fixed_order,
    );
    if (fixed_size < subframe_size) {
        subframe_size = fixed_size;
        subframe_type = .{ .fixed = .{
            .order = best_fixed_order,
            .residuals = residuals_dst,
            .rice_config = rice_config,
        } };
    }

    return .{ subframe_size, subframe_type };
}

fn autoSamples(self: Encoder, channel: StereoChannel, len: usize) []align(simd.VEC_ALIGN32) i32 {
    std.debug.assert(self.config.stereo_decorrelation == true);

    return switch (channel) {
        .left => self.samples[0][0..len],
        .right => self.samples[1][0..len],
        .mid => self.samples[2][0..len],
        .side => self.samples[3][0..len],
    };
}

fn autoResiduals(self: Encoder, channel: StereoChannel, len: usize) []align(simd.VEC_ALIGN32) i32 {
    std.debug.assert(self.config.stereo_decorrelation == true);
    return switch (channel) {
        .left => self.residuals[0][0..len],
        .right => self.residuals[1][0..len],
        .mid => self.residuals[2][0..len],
        .side => self.residuals[3][0..len],
    };
}

// -- Types --

pub const Config = struct {
    /// (maximum) block size
    block_size_max: u16,
    prediction: Prediction,
    bit_depth_max: u6,
    channels_max: u4,
    stereo_decorrelation: bool,
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

    pub fn default(channels: u4, bit_depth: u6) @This() {
        return .{
            .block_size_max = 4096,
            .prediction = .fixed,
            .bit_depth_max = bit_depth,
            .channels_max = channels,
            .stereo_decorrelation = true,
            .max_rice_order = 8,
            .max_rice_param = rice.MAX_PARAM,
        };
    }
};

const FrameInfo = struct {
    bit_depth: u6,
    channels: u4,
    samples_count: u16,
    sample_rate: u20,
};

const ChType = enum(u8) {
    indep = 0,
    left_side = 1,
    side_right = 2,
    mid_side = 3,
};

const StereoChannel = enum { left, right, mid, side };

const SubframeType = union(enum) {
    indep: [8]Encoding,
    stereo_auto: struct {
        ch_type: ChType,

        left: Encoding,
        right: Encoding,
        mid: Encoding,
        side: Encoding,
    },

    pub const Encoding = union(enum) {
        constant: struct {
            sample: i64,
        },
        verbatim: void,
        fixed: struct {
            order: u8,
            residuals: []i32,
            rice_config: rice.Config,
        },
        // linear: struct {
        //     order: u8,
        //     rice_order: u8 = undefined,
        //     partition_order: u8 = undefined,
        //     residuals: []isize,
        // },
    };
};
