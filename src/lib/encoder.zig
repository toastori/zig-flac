const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const fixed = @import("fixed.zig");
const flac_type = @import("type.zig");
const metadata = @import("metadata.zig");
const rice = @import("rice.zig");
const simd = @import("simd.zig");
const Channel = flac_type.Channel;
const FrameWriter = @import("frame_writer.zig");
const Md5 = @import("md5.zig").Md5;
const SampleVariant = flac_type.SampleVariant;
const StreamInfo = metadata.StreamInfo;
const Encoder = @This();

config: Config,
writer: *Writer,
md5: Md5,
// One time allocation
fwriter_buf: []u64 = undefined,
/// Raw samples. channel 1~8, or stereo [left right mid side(32bits)]
samples: [8][*]align(simd.VEC_ALIGN32) i32 = undefined,
/// Wide raw value samples for 32-bits stereo's side channel
samples64: [*]align(simd.VEC_ALIGN64) i64 = undefined, // Conditional
/// Residuals. channel 1~8, or stereo: [left right mid side]
residuals: [8][*]align(simd.VEC_ALIGN32) i32 = undefined,
// Rice calculation
rice_sum_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64 = undefined,
rice_max_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64 = undefined,
rice_params: [*][rice.ORDER_MAX + 1][rice.PART_MAX]rice.Config.Param = undefined,

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
    std.debug.assert(config.bit_depth > 0 and config.bit_depth % 4 == 0);
    std.debug.assert(config.block_size > 0);
    std.debug.assert(config.channels > 0 and config.channels <= 8);

    var result: Encoder = .{ .writer = writer, .config = config, .md5 = .init(.{}) };
    // frame writer buffer (allocate large enough so no checks during encoding)
    const fwriter_buf = try gpa.alloc(u64, std.math.divCeil(usize, maxFrameBytes(
        config.block_size,
        config.bit_depth,
        config.channels,
        config.feature.compute_waste_bits,
    ), 8) catch unreachable);
    errdefer gpa.free(fwriter_buf);
    result.fwriter_buf = fwriter_buf;

    result.rice_sum_buf = try gpa.create(@TypeOf(result.rice_sum_buf.*));
    errdefer gpa.destroy(result.rice_sum_buf);

    result.rice_max_buf = try gpa.create(@TypeOf(result.rice_max_buf.*));
    errdefer gpa.destroy(result.rice_max_buf);


    // increase block_size to the multiple of vector length
    // TODO 0.17.x replace with @divCeil(config.blovk_size_max, simd.VEC_ALIGN) * simd.VEC_ALIGN;
    const block_len32 =
        @divFloor(config.block_size + simd.LEN32 - 1, simd.LEN32) * simd.LEN32;
    const block_len64 =
        @divFloor(config.block_size + simd.LEN64 - 1, simd.LEN64) * simd.LEN64;
    const buf_count32 =
        if (config.feature.stereo_decorrelation == true and config.channels == 2)
            @max(config.channels, 4)
        else
            config.channels;

    result.rice_params =
        (try gpa.alloc([rice.ORDER_MAX + 1][rice.PART_MAX]rice.Config.Param, buf_count32)).ptr;
    errdefer gpa.free(result.rice_params[0..config.channels]);

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
    if (config.bit_depth == 32) {
        if (config.feature.stereo_decorrelation == true and config.channels != 1) {
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

    gpa.free(self.fwriter_buf);
    gpa.destroy(self.rice_sum_buf);
    gpa.destroy(self.rice_max_buf);

    // increase block_size to the multiple of vector alignment
    // TODO 0.17.x replace with @divCeil(config.blovk_size_max, simd.VEC_ALIGN) * simd.VEC_ALIGN;
    const block_len32 =
        @divFloor(config.block_size + simd.LEN32 - 1, simd.LEN32) * simd.LEN32;
    const block_len64 =
        @divFloor(config.block_size + simd.LEN64 - 1, simd.LEN64) * simd.LEN64;
    const buf_count32 =
        if (config.feature.stereo_decorrelation == true and config.channels == 2)
            @max(config.channels, 4)
        else
            config.channels;

    gpa.free(self.rice_params[0..buf_count32]);

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
    if (config.bit_depth == 32) {
        if (config.feature.stereo_decorrelation == true and config.channels != 1) {
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
    var fwriter: FrameWriter = .init(self.writer, self.fwriter_buf);

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
            .indep => .indep(frame_info.channels),
            .stereo_auto => |sa| sa.ch_type,
        },
        frame_info.samples_count,
        frame_info.sample_rate,
        true, // is_fixed_size
    );

    // Write independent channels
    if (subframe_type == .indep) { // Indep Channels
        for (0..frame_info.channels) |ch| {
            try writeChannelSubframe(&fwriter, subframe_type.indep[ch], frame_info.bit_depth);
        }
    } else { // Stereo ever considering decorrelation
        const channels: [2]u2 = switch (subframe_type.stereo_auto.ch_type) {
            .l_s => .{ 0, 3 }, // left side
            .s_r => .{ 3, 1 }, // side right
            .m_s => .{ 2, 3 }, // mid  side
            else => .{ 0, 1 }, // left right (indep)
        };

        for (channels) |ch| {
            const bit_depth = if (ch == 3) frame_info.bit_depth + 1 else frame_info.bit_depth;
            const encoding = switch (ch) {
                0 => &subframe_type.stereo_auto.left,
                1 => &subframe_type.stereo_auto.right,
                2 => &subframe_type.stereo_auto.mid,
                3 => &subframe_type.stereo_auto.side,
            };
            try writeChannelSubframe(&fwriter, encoding.*, bit_depth);
        }
    }
    // Close subframe
    try fwriter.writeCrc16();
    return fwriter.bytes_written;
}

/// Write subframe of a channel (any kind: single, mid, side)
fn writeChannelSubframe(
    fwriter: *FrameWriter,
    subframe_type: SubframeType.Encoding,
    bit_depth: u6,
) Writer.Error!void {
    switch (subframe_type) {
        .constant => |c| {
            const bps = bit_depth - c.waste_bits;
            try fwriter.writeConstantSubframe(c.sample, bps, c.waste_bits);
        },
        .verbatim => |v| {
            const bps = bit_depth - v.waste_bits;
            try switch (v.samples) {
                .normal => |samples| fwriter.writeVerbatimSubframe(i32, samples, bps, v.waste_bits),
                .wide => |samples| fwriter.writeVerbatimSubframe(i64, samples, bps, v.waste_bits),
            };
        },
        .fixed => |f| {
            const bps = bit_depth - f.waste_bits;
            try fwriter.writeFixedSubframe(f.warmup_samples, f.residuals, f.order, f.rice_config, bps, f.waste_bits);
        },
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
            if (self.config.feature.stereo_decorrelation == false) continue :blk 0;

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
            { // Left
                const samples = self.autoSamples(.left, samples_count);
                const waste_bits = calcWasteBits(.normal, samples, samples, bit_depth);
                frame_size_l, result.stereo_auto.left = chooseSubframeEncoding(
                    .normal,
                    samples,
                    self.autoResiduals(.left, samples_count),
                    self.config.feature.max_rice_order,
                    self.config.feature.max_rice_param,
                    self.rice_sum_buf,
                    self.rice_max_buf,
                    &self.rice_params[0],
                    bit_depth,
                    waste_bits,
                );
            }
            { // Right
                const samples = self.autoSamples(.right, samples_count);
                const waste_bits = calcWasteBits(.normal, samples, samples, bit_depth);
                frame_size_r, result.stereo_auto.right = chooseSubframeEncoding(
                    .normal,
                    samples,
                    self.autoResiduals(.right, samples_count),
                    self.config.feature.max_rice_order,
                    self.config.feature.max_rice_param,
                    self.rice_sum_buf,
                    self.rice_max_buf,
                    &self.rice_params[1],
                    bit_depth,
                    waste_bits,
                );
            }
            { // Mid
                const samples = self.autoSamples(.mid, samples_count);
                const waste_bits = calcWasteBits(.normal, samples, samples, bit_depth);
                frame_size_m, result.stereo_auto.mid = chooseSubframeEncoding(
                    .normal,
                    samples,
                    self.autoResiduals(.mid, samples_count),
                    self.config.feature.max_rice_order,
                    self.config.feature.max_rice_param,
                    self.rice_sum_buf,
                    self.rice_max_buf,
                    &self.rice_params[2],
                    bit_depth,
                    waste_bits,
                );
            }
            { // Side
                const waste_bits = switch (bit_depth) {
                    32 => calcWasteBits(
                        .wide,
                        self.samples64[0..samples_count],
                        self.autoSamples(.side, samples_count),
                        bit_depth + 1,
                    ),
                    else => calcWasteBits(
                        .normal,
                        self.autoSamples(.side, samples_count),
                        self.autoSamples(.side, samples_count),
                        bit_depth + 1,
                    ),
                };
                frame_size_s, result.stereo_auto.side =
                    if (bit_depth == 32 and waste_bits == 0) side_p: {
                        break :side_p chooseSubframeEncoding(
                            .wide,
                            self.samples64[0..samples_count],
                            self.autoResiduals(.side, samples_count),
                            self.config.feature.max_rice_order,
                            self.config.feature.max_rice_param,
                            self.rice_sum_buf,
                            self.rice_max_buf,
                            &self.rice_params[3],
                            bit_depth + 1,
                            0,
                        );
                    } else side_p: {
                        break :side_p chooseSubframeEncoding(
                            .normal,
                            self.autoSamples(.side, samples_count),
                            self.autoResiduals(.side, samples_count),
                            self.config.feature.max_rice_order,
                            self.config.feature.max_rice_param,
                            self.rice_sum_buf,
                            self.rice_max_buf,
                            &self.rice_params[3],
                            bit_depth + 1,
                            waste_bits,
                        );
                    };
            }

            // Choose stereo decorrelation format
            const sum: [4]u64 = .{ // match the order as ChType
                frame_size_l + frame_size_r, // left right
                frame_size_l + frame_size_s, // left side
                frame_size_s + frame_size_r, // side right
                frame_size_m + frame_size_s, // mid  side
            };
            result.stereo_auto.ch_type = switch (std.mem.indexOfMin(u64, &sum)) {
                0 => .indep(2),
                1...3 => |int| @enumFromInt(int + 7),
                else => unreachable,
            };

            return result;
        },
        else => {
            var result: SubframeType = .{ .indep = undefined };
            for (0..channels) |ch| {
                const samples = self.samples[ch][0..samples_count];
                const residuals = self.residuals[ch][0..samples_count];
                const waste_bits = calcWasteBits(.normal, samples, samples, bit_depth);
                _, result.indep[ch] = chooseSubframeEncoding(
                    .normal,
                    samples,
                    residuals,
                    self.config.feature.max_rice_order,
                    self.config.feature.max_rice_param,
                    self.rice_sum_buf,
                    self.rice_max_buf,
                    &self.rice_params[ch],
                    bit_depth,
                    waste_bits,
                );
            }
            return result;
        },
    }
}

/// Evaluate best encoding for a subframe
///
/// return `.{ bit_size, SubframeEncoding }`
fn chooseSubframeEncoding(
    comptime sv: SampleVariant,
    samples: []align(simd.VEC_ALIGN_OF(sv.T())) sv.T(),
    residuals_dst: []align(simd.VEC_ALIGN32) i32,
    rice_order_max: u4,
    rice_param_max: u5,
    rice_sum_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64,
    rice_max_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64,
    rice_params: *[rice.ORDER_MAX + 1][rice.PART_MAX]rice.Config.Param,
    bit_depth: u6,
    waste_bits: u6,
) @Tuple(&.{ u64, SubframeType.Encoding }) {
    const bps = bit_depth - waste_bits;
    // -- Constant -- (First priority)
    if (bps == 0) {
        return .{ bps, .{ .constant = .{ .waste_bits = waste_bits, .sample = undefined } } };
    }
    if (std.mem.allEqual(sv.T(), samples[1..], samples[0])) {
        return .{ bps, .{ .constant = .{ .waste_bits = waste_bits, .sample = samples[0] } } };
    }

    // Verbatim as default
    var subframe_type: SubframeType.Encoding =
        .{ .verbatim = .{
            .waste_bits = waste_bits,
            .samples = switch (sv) {
                .normal => .{ .normal = samples },
                .wide => .{ .wide = samples },
            },
        } };
    var bit_size: u64 = samples.len * bps;

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed.MAX_ORDER) return .{ bit_size, subframe_type };

    // -- Fixed Prediction --
    const best_fixed_order = if (bps < 28 and sv == .normal)
        fixed.bestOrder(sv, false, samples) orelse unreachable
    else
        fixed.bestOrder(sv, true, samples) orelse return .{ bit_size, subframe_type };

    // Prepare residuals
    if (bps < 28 and sv == .normal) {
        fixed.calcResiduals(sv, false, samples, residuals_dst, best_fixed_order);
    } else {
        fixed.calcResiduals(sv, true, samples, residuals_dst, best_fixed_order);
    }

    const fixed_size, const rice_config = rice.calcParams(
        residuals_dst,
        rice_order_max,
        rice_param_max,
        rice_sum_buf,
        rice_max_buf,
        rice_params,
        bps,
        best_fixed_order,
    );
    if (fixed_size < bit_size) {
        bit_size = fixed_size;
        subframe_type = .{ .fixed = .{
            .order = best_fixed_order,
            .residuals = residuals_dst,
            .rice_config = rice_config,
            .waste_bits = waste_bits,
            .warmup_samples = blk: {
                var warmup_samples: [4]i64 = undefined;
                for (0..4) |i| warmup_samples[i] = samples[i];
                break :blk warmup_samples;
            },
        } };
    }

    return .{ bit_size, subframe_type };
}

fn calcWasteBits(comptime sv: SampleVariant, samples: []sv.T(), wasted_dest: []i32, bps: u6) u6 {
    var or_all: sv.T() = 0;
    for (samples) |s| {
        or_all |= s;
    }
    const waste_bits = if (or_all == 0) bps else @ctz(or_all);

    if (waste_bits != 0 and waste_bits != bps) {
        for (samples, wasted_dest) |s, *dest| {
            dest.* = @intCast(s >> @intCast(waste_bits));
        }
    }

    return @intCast(waste_bits);
}

fn autoSamples(self: Encoder, channel: StereoChannel, len: usize) []align(simd.VEC_ALIGN32) i32 {
    std.debug.assert(self.config.feature.stereo_decorrelation == true);

    return switch (channel) {
        .left => self.samples[0][0..len],
        .right => self.samples[1][0..len],
        .mid => self.samples[2][0..len],
        .side => self.samples[3][0..len],
    };
}

fn maxFrameBytes(block_size: u16, bit_depth: u6, channels: u4, stereo_decorrelation: bool) usize {
    // header
    // 4 half bytes + frame_no + unusual blocksize + unusual samplerate + crc8
    const header_max: usize = 2 + 7 + 2 + 2 + 1;
    const subframe_header_max: usize = 8;
    // data (estimate verbatim as max, plus 1 more channel as free space)
    const bps: usize = if (channels == 2 and stereo_decorrelation) bit_depth + 1 else bit_depth;
    const byte_per_sample: usize = std.math.divCeil(usize, bps, 8) catch unreachable;
    const data_estimate = @as(usize, block_size) * byte_per_sample * (channels + 1);
    // footer (crc16)
    const footer = 2;
    return header_max + subframe_header_max * channels + data_estimate + footer;
}

fn autoResiduals(self: Encoder, channel: StereoChannel, len: usize) []align(simd.VEC_ALIGN32) i32 {
    std.debug.assert(self.config.feature.stereo_decorrelation == true);
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
    block_size: u16,
    bit_depth: u6,
    channels: u4,
    feature: Feature,

    pub const Feature = struct {
        prediction: Prediction,
        stereo_decorrelation: bool,
        compute_waste_bits: bool,
        /// Rice partition order: value [0, 15] ([0, 8] for subset)
        max_rice_order: u4,
        /// Rice param limit: value [0, 30] ([0, 14] for rice1 only)
        max_rice_param: u5,
    };

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
            .block_size = 4096,
            .bit_depth = bit_depth,
            .channels = channels,
            .feature = .{
                .prediction = .fixed,
                .stereo_decorrelation = true,
                .compute_waste_bits = true,
                .max_rice_order = 8,
                .max_rice_param = rice.MAX_PARAM,
            },
        };
    }
};

const FrameInfo = struct {
    bit_depth: u6,
    channels: u4,
    samples_count: u16,
    sample_rate: u20,
};

const StereoChannel = enum { left, right, mid, side };

const SubframeType = union(enum) {
    indep: [8]Encoding,
    stereo_auto: struct {
        ch_type: Channel,

        left: Encoding,
        right: Encoding,
        mid: Encoding,
        side: Encoding,
    },

    pub const Encoding = union(enum) {
        constant: struct {
            waste_bits: u6,
            sample: i64,
        },
        verbatim: struct {
            waste_bits: u6,
            samples: SampleT,
        },
        fixed: struct {
            waste_bits: u6,
            order: u8,
            residuals: []const i32,
            warmup_samples: [4]i64,
            rice_config: rice.Config,
        },
        // linear: struct {
        //     order: u8,
        //     rice_order: u8 = undefined,
        //     partition_order: u8 = undefined,
        //     residuals: []isize,
        // },

        pub const SampleT = union(enum) { normal: []const i32, wide: []const i64 };
    };
};
