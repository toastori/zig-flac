const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = std.Io.Writer;

const fixed = @import("fixed.zig");
const flac_type = @import("type.zig");
const rice = @import("rice.zig");
const simd = @import("simd.zig");
const pcm = @import("pcm.zig");
const Channel = flac_type.Channel;
const FrameWriter = @import("frame_writer.zig");
const Md5 = @import("md5.zig").Md5;
const SampleVariant = flac_type.SampleVariant;
const Encoder = @This();

// -- struct Encoder

cfg: Config,
/// callback to seek file / change write pointer position,
/// callee handles buffer flush
seek_callback: ?SeekFn,
callback_ctx : ?*anyopaque,

// Internal states
state : State,
arena : ArenaAllocator,
md5   : Md5,
writer: *Writer,

frame_counter  : u36,
samples_filled : u16,
samples_written: u64,
frame_size_max : u24,
frame_size_min : u24,

frame_ctx: [1]FrameCtx,

const Config = struct {
    bit_depth  : u6,
    sample_rate: u20,
    channels   : u4,
    compression: Compression,

    pub fn default(channels: u4, bit_depth: u6, sample_rate: u20) Config {
        return .{
            .bit_depth   = bit_depth,
            .channels    = channels,
            .sample_rate = sample_rate,
            .compression = .{},
        };
    }
};
/// Encoder settings that affect encoding and compression performance
pub const Compression = struct {
    /// Samples per flac encoded frame (except last frame which might be smaller)
    block_size          : u16        = 4096,
    /// Level of linear prediction used for compression
    prediction          : Prediction = .fixed,
    /// Enable stereo decorrelation (ignored for non stereo audio)
    stereo_decorrelation: bool       = true,
    /// Enable check and eliminate waste bits
    compute_waste_bits  : bool       = true,
    /// Encoder calculate and write md5 checksum
    do_md5              : bool       = true,
    /// Rice partition order: value [0, 15] ([0, 8] for subset)
    max_rice_order      : u4         = 8,
    /// Rice parameter limit: value [0, 30] ([0, 14] for rice1 only)
    max_rice_param      : u5         = rice.MAX_PARAM,

    pub const Prediction = enum(u8) {
        fixed = 0,
        none = 0xFF,
        _,

        /// - Lax within range [1, 32]
        /// - Subset within range [1, 12] for sampling rates <= 48k
        fn linear(self: Prediction) u8 {
            return switch (@backingInt(self)) {
                1...32 => |i| i,
                else => unreachable,
            };
        }
    };
};
/// Tracking the state of the encoder,
/// use for state checking and hinting reallocation
const State = enum(u8) { ok, unalloc, uninit };
// For seek_callback
pub const SeekResult  = enum(u8) { ok, err, unsupported };
pub const SeekFn  = *const fn (enc: *Encoder, abs_byte_offset: u64,  ctx: *anyopaque) SeekResult;
/// struct to hold one time allocation buffers needed for encoding a frame
const FrameCtx = struct {
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
};

pub const StateError = error { WrongState };
pub const FormatError = error { UnsupportedBitDepth, UnsupportedChannels, UnsupportedSampleRate };
pub const BlockSizeError = error { InvalidBlockSize };

/// Check encoder's support for the audio format
pub fn isFormatSupported(bit_depth: u16, channels: u16, sample_rate: u32) FormatError!void {
    if (!isBitDepthSupported(bit_depth)) return FormatError.UnsupportedBitDepth;
    if (!isChannelSupported(channels)) return FormatError.UnsupportedChannels;
    if (!isSampleRateSupported(sample_rate)) return FormatError.UnsupportedSampleRate;
}
/// Check encoder's support for the audio bit_depth
pub fn isBitDepthSupported(bit_depth: u16) bool {
    return bit_depth == 16 or bit_depth == 24 or bit_depth == 32;
}
/// Check encoder's support for the audio channels count
pub fn isChannelSupported(channels: u16) bool {
    return channels != 0 and channels <= 8;
}
/// Check encoder's support for the audio sample_rate
pub fn isSampleRateSupported(sample_rate: u32) bool {
    return sample_rate < (1 << 20);
}

/// Apply basic initial settings to an Encoder
pub fn init(
    undefined_encoder: *Encoder,
    gpa              : Allocator,
    bit_depth        : u16,
    channels         : u16,
    sample_rate      : u32,
    compression      : Compression
) (FormatError || BlockSizeError) !void {
    try isFormatSupported(bit_depth, channels, sample_rate);
    if (compression.block_size == 0) return error.InvalidBlockSize;

    // fields commented out are not initialized here
    undefined_encoder.* = .{
        .seek_callback = null,
        .callback_ctx = null,

        .arena  = .init(gpa),
        .md5    = undefined,
        .writer = undefined,

        .state           = .unalloc,
        .frame_counter   = undefined,
        .samples_filled  = undefined,
        .samples_written = undefined,
        .frame_size_max  = undefined,
        .frame_size_min  = undefined,

        .frame_ctx       = undefined,

        .cfg = .{
            .bit_depth   = @intCast(bit_depth),
            .channels    = @intCast(channels),
            .sample_rate = @intCast(sample_rate),
            .compression = compression,
        },
    };
}

/// Destroy any allocation, if any
pub fn deinit(self: *Encoder) void {
    std.debug.assert(self.state == .unalloc or self.state == .uninit);
    self.state = .unalloc;
    self.arena.deinit();
}

pub const ChangeFormatOption = struct {
    /// Leave this field null if not changing it
    bit_depth: ?u16 = null,
    /// Leave this field null if not changing it
    channels: ?u16 = null,
    /// Leave this field null if not changing it
    sample_rate: ?u32 = null,
};
/// Change encoder's accepting audio format \
/// Checks if format is supported by FLAC, and if reallocation is needed
///
/// expect to call before encodeStart (or after finalized)
pub fn changeFormat(self: *Encoder, format: ChangeFormatOption) (FormatError || StateError)!void {
    if (self.state == .ok) return StateError.WrongState;

    if (format.bit_depth) |bit_depth| {
        if (!isBitDepthSupported(bit_depth)) return FormatError.UnsupportedBitRate;
        if (self.cfg.bit_depth != 32 and bit_depth == 32) self.state = .unalloc;
        self.bit_depth = bit_depth;
    }
    if (format.channels) |channels| {
        if (!isChannelSupported(channels)) return FormatError.UnsupportedChannels;
        if (self.cfg.channels != channels) self.state = .unalloc;
        self.cfg.channels = @intCast(channels);
    }
    if (format.sample_rate) |sample_rate| {
        if (!isSampleRateSupported(sample_rate)) return FormatError.UnsupportedSampleRate;
        self.cfg.sample_rate = @intCast(sample_rate);
    }
}
/// Change encoder's compression setting \
/// Checks if block_size is non zero, and if reallocation is needed
///
/// expect to call before encodeStart (or after finalized)
pub fn changeCompression(self: *Encoder, compression: Compression) (BlockSizeError || StateError)!void {
    if (self.state == .ok) return StateError.WrongState;
    if (compression.block_size == 0) return BlockSizeError.InvalidBlockSize;

    if (self.cfg.compression.block_size < compression.block_size) self.state == .unalloc;
    if (
        self.cfg.channels == 2 and compression.stereo_decorrelation == true and
        self.cfg.compression.stereo_decorrelation != compression.stereo_decorrelation
    ) self.state = .unalloc;

    self.cfg.compression = compression;
}

/// Encoder will reset internal states and counters for flac encoding
pub fn encodeStart(
    self: *Encoder,
    writer: *Writer,
    seek_callback: ?SeekFn,
    callback_ctx: ?*anyopaque,
) (Allocator.Error || Writer.Error || StateError)!void {
    if (self.state == .ok) return StateError.WrongState;

    if (self.state == .unalloc) try allocFrameCtx(self);
    self.md5 = .init(.{});
    self.frame_counter = 0;
    self.samples_filled = 0;
    self.samples_written = 0;
    self.frame_size_max = 0;
    self.frame_size_min = std.math.maxInt(u24);

    self.writer = writer;
    self.seek_callback = seek_callback;
    self.callback_ctx = callback_ctx;

    self.state = .ok;

    // Write Header anyways
    try writeHeader(self, false, false);
    // Write VorbisComment
    try writeVorbisComment(self.*, true);
}

// TODO
pub fn processInterleaved(self: *Encoder, buffer: []const i32) void {
    _ = self;
    _ = buffer;
    @panic("TODO: processInterleaved");
}

/// Fill samples from WAV style interleaved samples, in raw bytes
///
/// Require `buffer` to be samples aligned
/// (`buffer.len = channels * samples_count * bytes_per_sample`) \
/// otherwise return `error.InvalidBuffer`
///
/// `samples_count` does not need to matches block size
pub fn processWav(
    self: *Encoder,
    buffer: []const u8,
    bytes_per_sample: u8
) (error { InvalidBuffer } || Writer.Error || StateError)!void {
    if (self.state != .ok) return error.WrongState;

    // Validate buffer length
    if (buffer.len % (bytes_per_sample * self.cfg.channels) != 0) {
        return error.InvalidBuffer;
    }
    // Filling samples, then start encoding when filled to block_size
    var samples_left: usize = @divExact(buffer.len, (bytes_per_sample * self.cfg.channels));
    var buffer_start: usize = 0;
    while (samples_left != 0) {
        const samples_take = @min(samples_left, self.cfg.compression.block_size - self.samples_filled);
        // Fill samples
        pcm.samplesFromInterleaveRaw(
            buffer[buffer_start..][0..samples_take * bytes_per_sample * self.cfg.channels],
            &self.frame_ctx[0].samples,
            self.samples_filled,
            bytes_per_sample,
            self.cfg.bit_depth,
            self.cfg.channels,
            samples_take
        );
        // Samples are filled, start encoding frame
        if (self.cfg.compression.block_size == samples_take + self.samples_filled) {
            const frame_size = try writeFrame(
                self.frame_ctx[0],
                self.cfg,
                self.writer,
                self.frame_counter,
                self.cfg.compression.block_size,
            );

            self.frame_size_max = @max(frame_size, self.frame_size_max);
            self.frame_size_min = @min(frame_size, self.frame_size_min);
            self.samples_written += self.cfg.compression.block_size;

            self.frame_counter += 1;
            self.samples_filled = 0;
        } else {
            self.samples_filled += samples_take;
        }

        samples_left -= samples_take;
        buffer_start += samples_take * bytes_per_sample * self.cfg.channels;
    }
    // Update Md5 (if nothing goes wrong)
    if (self.cfg.compression.do_md5) self.md5.update(buffer);
}

/// Finish the file, flush remaining samples, and write header (if stream seekable)
///
/// Handles the final buffer flush
pub fn encodeFinish(self: *Encoder) (Writer.Error || StateError)!void {
    if (self.state != .ok) return error.WrongState;
    const frame_size = try writeFrame(
        self.frame_ctx[0],
        self.cfg,
        self.writer,
        self.frame_counter,
        self.samples_filled,
    );
    self.frame_size_max = @max(frame_size, self.frame_size_max);
    self.frame_size_min = @min(frame_size, self.frame_size_min);
    self.samples_written += self.samples_filled;

    // Write Header if seekable
    if (self.seek_callback != null and self.callback_ctx != null) {
        switch (self.seek_callback.?(self, 0, self.callback_ctx.?)) {
            .ok => try writeHeader(self, true, false),
            else => {},
        }
    }

    try self.writer.flush();
    self.state = .uninit;
}

const MetadataType = enum(u7) {
    stream_info = 0, // Implemented
    padding = 1,
    application = 2,
    seek_table = 3,
    vorbis_comment = 4, // Implemented (partially)
    cue_sheet = 5,
    picture = 6,
    forbidden = 127,
};
fn metadataHeader(metadata_type: MetadataType, last_metadata: bool) u8 {
    return (@as(u8, @intFromBool(last_metadata)) << 7) | @backingInt(metadata_type);
}
/// Write magical numbers and Streaminfo (BlockType 0)
/// Expect call at start of the FLAC file
fn writeHeader(self: *Encoder, stream_seekable: bool, last_metadata: bool) Writer.Error!void {
    // Write Signature
    try self.writer.writeAll("fLaC");
    // Write Streaminfo Block Header
    try self.writer.writeByte(metadataHeader(.stream_info, last_metadata));
    // bytes of metadata block
    try self.writer.writeInt(u24, 34, .big);
    { // Write Streaminfo Metadata
        // block sizes
        try self.writer.writeInt(u16, self.cfg.compression.block_size, .big); // min (16 bits)
        try self.writer.writeInt(u16, self.cfg.compression.block_size, .big); // max (16 bits)
        // frame sizes
        if (stream_seekable) {
            try self.writer.writeInt(u24, self.frame_size_min, .big); // min (24 bits)
            try self.writer.writeInt(u24, self.frame_size_max, .big); // max (24 bits)
        } else {
            try self.writer.splatByteAll(0, 6);
        }

        try self.writer.writeInt(u64, (
            @as(u64, self.cfg.sample_rate) << 3 << 5 << 36 | // sample rate (20 bits)
            @as(u64, self.cfg.channels - 1)     << 5 << 36 | // channels    ( 3 bits)
            @as(u64, self.cfg.bit_depth - 1)         << 36 | // bit depth   ( 5 bits)
            @as(u64, self.samples_written)                   // samples cnt (36 bits)
        ), .big);                                            // sum = 64 bits

        if (stream_seekable and self.cfg.compression.do_md5) {
            try self.writer.writeAll(&self.md5.finalResult()); // Md5 Checksum (128 bits)
        } else {
            try self.writer.splatByteAll(0, 16);
        }
    }
}
/// Write Vendor and Vorbis Comments (BlockType 4)
fn writeVorbisComment(self: Encoder, last_metadata: bool) Writer.Error!void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    // Write VorbisComment Block Header
    try self.writer.writeByte(metadataHeader(.vorbis_comment, last_metadata));
    // vendor len + vendor_len len(4) + tags_len len(4)
    try self.writer.writeInt(u24, @intCast(4 + vendor.len + 4), .big);
    // Write vendor string
    try self.writer.writeInt(u32, @intCast(vendor.len), .little);
    try self.writer.writeAll(vendor);
    // Write comments
    // tags len (4 bytes) (no tag now)
    try self.writer.writeInt(u32, 0, .little);
}


/// Write a frame
///
/// return bytes written for the frame
fn writeFrame(
    ctx: FrameCtx,
    cfg: Config,
    writer: *Writer,
    frame_id: u36,
    samples_cnt: u16
) Writer.Error!u24 {
    std.debug.assert(samples_cnt != 0);
    var fwriter: FrameWriter = .init(writer, ctx.fwriter_buf);

    const subframe_type = processChannels(ctx, cfg, samples_cnt);

    { // Write header start
        const channels: Channel = switch (subframe_type) {
            .indep => .indep(cfg.channels),
            .stereo_auto => |stereo| stereo.ch_type,
        };
        fwriter.writeHeader(frame_id, cfg.bit_depth, channels, samples_cnt, cfg.sample_rate, true);
    }

    // Write independent channels
    if (subframe_type == .indep) { // Indep Channels
        for (0..cfg.channels) |ch| writeSubframe(&fwriter, subframe_type.indep[ch], cfg.bit_depth);
    } else { // Stereo ever considering decorrelation
        const stereo_auto = subframe_type.stereo_auto;
        const ch_type = stereo_auto.ch_type; // l..r l.s. .ms. ..sr -> lmsr (sequence)
        if (ch_type == Channel.indep(2) or ch_type == .l_s) {
            writeSubframe(&fwriter, stereo_auto.left , cfg.bit_depth);   // left
        }
        if (ch_type == .m_s) {
            writeSubframe(&fwriter, stereo_auto.mid  , cfg.bit_depth);   // mid
        }
        if (ch_type != Channel.indep(2)) {
            writeSubframe(&fwriter, stereo_auto.side , cfg.bit_depth+1); // side
        }
        if (ch_type == Channel.indep(2) or ch_type == .s_r) {
            writeSubframe(&fwriter, stereo_auto.right, cfg.bit_depth);   // right
        }
    }

    // Close subframe (and return bytes written)
    return fwriter.flush();
}

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
/// Decide encoding of each channels, and ch_type for stereo audio
fn processChannels(
    ctx: FrameCtx,
    cfg: Config,
    samples_cnt: u16,
) SubframeType {
    blk: switch (cfg.channels) {
        2 => {
            if (cfg.compression.stereo_decorrelation == false) continue :blk 0;

            var result: SubframeType = .{ .stereo_auto = undefined };
            var frame_size_l: u64 = undefined;
            var frame_size_r: u64 = undefined;
            var frame_size_m: u64 = undefined;
            var frame_size_s: u64 = undefined;

            // Generate Mid and Side Channels
            if (cfg.bit_depth == 32) {
                for (
                    ctx.samples[@backingInt(StereoChannel.left )][0..samples_cnt],
                    ctx.samples[@backingInt(StereoChannel.right)][0..samples_cnt],
                    ctx.samples[@backingInt(StereoChannel.mid  )][0..samples_cnt],
                    ctx.samples64[0..samples_cnt], // Side
                ) |left, right, *mid, *side| {
                    mid.* = @intCast((@as(i64, left) + @as(i64, right)) >> 1);
                    side.* = @as(i64, left) - @as(i64, right);
                }
            } else {
                for (
                    ctx.samples[@backingInt(StereoChannel.left )][0..samples_cnt],
                    ctx.samples[@backingInt(StereoChannel.right)][0..samples_cnt],
                    ctx.samples[@backingInt(StereoChannel.mid  )][0..samples_cnt],
                    ctx.samples[@backingInt(StereoChannel.side )][0..samples_cnt],
                ) |left, right, *mid, *side| {
                    mid.* = (left + right) >> 1;
                    side.* = left - right;
                }
            }

            // Evaulate each channels
            { // Left
                const samples = ctx.samples[@backingInt(StereoChannel.left)][0..samples_cnt];
                const waste_bits = calcWasteBits(.normal, samples, samples, cfg.bit_depth);
                frame_size_l, result.stereo_auto.left = chooseSubframeEncoding(
                    .normal,
                    samples,
                    ctx.residuals[@backingInt(StereoChannel.left)][0..samples_cnt],
                    ctx.rice_sum_buf,
                    ctx.rice_max_buf,
                    &ctx.rice_params[@backingInt(StereoChannel.left)],
                    cfg.compression.max_rice_order,
                    cfg.compression.max_rice_param,
                    cfg.bit_depth,
                    waste_bits,
                );
            }
            { // Right
                const samples = ctx.samples[@backingInt(StereoChannel.right)][0..samples_cnt];
                const waste_bits = calcWasteBits(.normal, samples, samples, cfg.bit_depth);
                frame_size_r, result.stereo_auto.right = chooseSubframeEncoding(
                    .normal,
                    samples,
                    ctx.residuals[@backingInt(StereoChannel.right)][0..samples_cnt],
                    ctx.rice_sum_buf,
                    ctx.rice_max_buf,
                    &ctx.rice_params[@backingInt(StereoChannel.right)],
                    cfg.compression.max_rice_order,
                    cfg.compression.max_rice_param,
                    cfg.bit_depth,
                    waste_bits,
                );
            }
            { // Mid
                const samples = ctx.samples[@backingInt(StereoChannel.mid)][0..samples_cnt];
                const waste_bits = calcWasteBits(.normal, samples, samples, cfg.bit_depth);
                frame_size_m, result.stereo_auto.mid = chooseSubframeEncoding(
                    .normal,
                    samples,
                    ctx.residuals[@backingInt(StereoChannel.mid)][0..samples_cnt],
                    ctx.rice_sum_buf,
                    ctx.rice_max_buf,
                    &ctx.rice_params[@backingInt(StereoChannel.mid)],
                    cfg.compression.max_rice_order,
                    cfg.compression.max_rice_param,
                    cfg.bit_depth,
                    waste_bits,
                );
            }
            { // Side
                const channel_side = @backingInt(StereoChannel.side);
                const waste_bits = switch (cfg.bit_depth) {
                    32 => calcWasteBits(
                        .wide,
                        ctx.samples64[0..samples_cnt],
                        ctx.samples[channel_side][0..samples_cnt],
                        cfg.bit_depth + 1,
                    ),
                    else => calcWasteBits(
                        .normal,
                        ctx.samples[channel_side][0..samples_cnt],
                        ctx.samples[channel_side][0..samples_cnt],
                        cfg.bit_depth + 1,
                    ),
                };
                frame_size_s, result.stereo_auto.side =
                    if (cfg.bit_depth == 32 and waste_bits == 0) chooseSubframeEncoding(
                        .wide,
                        ctx.samples64[0..samples_cnt],
                        ctx.residuals[channel_side][0..samples_cnt],
                        ctx.rice_sum_buf,
                        ctx.rice_max_buf,
                        &ctx.rice_params[channel_side],
                        cfg.compression.max_rice_order,
                        cfg.compression.max_rice_param,
                        cfg.bit_depth + 1,
                        0,
                    )
                    else chooseSubframeEncoding(
                        .normal,
                        ctx.samples[channel_side][0..samples_cnt],
                        ctx.residuals[channel_side][0..samples_cnt],
                        ctx.rice_sum_buf,
                        ctx.rice_max_buf,
                        &ctx.rice_params[channel_side],
                        cfg.compression.max_rice_order,
                        cfg.compression.max_rice_param,
                        cfg.bit_depth + 1,
                        waste_bits,
                    );
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
            for (0..cfg.channels) |ch| {
                const samples = ctx.samples[ch][0..samples_cnt];
                const residuals = ctx.residuals[ch][0..samples_cnt];
                const waste_bits = calcWasteBits(.normal, samples, samples, cfg.bit_depth);
                _, result.indep[ch] = chooseSubframeEncoding(
                    .normal,
                    samples,
                    residuals,
                    ctx.rice_sum_buf,
                    ctx.rice_max_buf,
                    &ctx.rice_params[ch],
                    cfg.compression.max_rice_order,
                    cfg.compression.max_rice_param,
                    cfg.bit_depth,
                    waste_bits,
                );
            }
            return result;
        },
    }
}

/// Write subframe of a channel (any kind: single, mid, side)
fn writeSubframe(
    fwriter: *FrameWriter,
    subframe_type: SubframeType.Encoding,
    bit_depth: u6,
) void {
    switch (subframe_type) {
        .constant => |c| {
            const bps = bit_depth - c.waste_bits;
            fwriter.writeConstantSubframe(c.sample, bps, c.waste_bits);
        },
        .verbatim => |v| {
            const bps = bit_depth - v.waste_bits;
            switch (v.samples) {
                .normal => |samples| fwriter.writeVerbatimSubframe(i32, samples, bps, v.waste_bits),
                .wide => |samples| fwriter.writeVerbatimSubframe(i64, samples, bps, v.waste_bits),
            }
        },
        .fixed => |f| {
            const bps = bit_depth - f.waste_bits;
            fwriter.writeFixedSubframe(f.warmup_samples, f.residuals, f.order, f.rice_config, bps, f.waste_bits);
        },
        // else => unreachable, // TODO
    }
}

/// Calculate waste_bits and store the reduced version
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

/// Evaluate best encoding for a subframe
///
/// return `.{ bit_size, SubframeEncoding }`
fn chooseSubframeEncoding(
    comptime sv: SampleVariant,
    samples: []align(simd.VEC_ALIGN_OF(sv.T())) sv.T(),
    residuals_dst: []align(simd.VEC_ALIGN32) i32,
    rice_sum_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64,
    rice_max_buf: *[rice.ORDER_MAX + 1][rice.PART_MAX]u64,
    rice_params: *[rice.ORDER_MAX + 1][rice.PART_MAX]rice.Config.Param,
    rice_order_max: u4,
    rice_param_max: u5,
    bit_depth: u6,
    waste_bits: u6,
) struct { u64, SubframeType.Encoding } {
    const bps = bit_depth - waste_bits;
    // -- Constant -- (First priority)
    if (bps == 0) {
        return .{ bps, .{ .constant = .{ .waste_bits = waste_bits, .sample = 0 } } };
    }
    if (std.mem.allEqual(sv.T(), samples[1..], samples[0])) {
        return .{ bps, .{ .constant = .{ .waste_bits = waste_bits, .sample = samples[0] } } };
    }

    // -- Verbatim as default
    var subframe_type: SubframeType.Encoding = .{ .verbatim = .{
        .waste_bits = waste_bits,
        .samples = switch (sv) {
            .normal => .{ .normal = samples },
            .wide => .{ .wide = samples },
        },
    } };
    var bit_size: u64 = samples.len * bps;

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed.MAX_ORDER) return .{ bit_size, subframe_type };

    { // -- Fixed Prediction --
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
                .warmup_samples = warmup_samples: {
                    var warmup_samples: [4]i64 = undefined;
                    for (0..4) |i| warmup_samples[i] = samples[i];
                    break :warmup_samples warmup_samples;
                },
            } };
        }
    }

    return .{ bit_size, subframe_type };
}

/// Allocate one time allocated buffers used internally conditionally
fn allocFrameCtx(self: *Encoder) Allocator.Error!void {
    _ = self.arena.reset(.free_all);
    const ally = self.arena.allocator();
    errdefer _ = self.arena.reset(.free_all);

    // constants
    const guard_len32 = @max(simd.LEN32, 4);
    const guard_len64 = @max(simd.LEN64, 4);
        // currently have no difference due to no lpc support yet
    const guard_front32 = @max(simd.LEN32, 4);
        // currently have no difference due to no lpc support yet
    const guard_front64 = @max(simd.LEN64, 4);
    // increase block_size to the multiple of vector length
    const block_len32 = @divCeil(self.cfg.compression.block_size, simd.LEN32) * simd.LEN32;
    const block_len64 = @divCeil(self.cfg.compression.block_size, simd.LEN64) * simd.LEN64;
    const buf_count32 =
        if (self.cfg.compression.stereo_decorrelation == true and self.cfg.channels == 2)
            @max(self.cfg.channels, 4)
        else
            self.cfg.channels;

    for (&self.frame_ctx) |*ctx| {
        // frame writer buffer (allocate large enough so no checks during encoding)
        ctx.fwriter_buf = try ally.alloc(u64, @divCeil(maxFrameBytes(
            self.cfg.bit_depth,
            self.cfg.channels,
            self.cfg.compression.block_size,
            self.cfg.compression.stereo_decorrelation,
        ), 8));

        ctx.rice_sum_buf = try ally.create(@TypeOf(ctx.rice_sum_buf.*));
        ctx.rice_max_buf = try ally.create(@TypeOf(ctx.rice_max_buf.*));
        ctx.rice_params =
            (try ally.alloc(@typeInfo(@TypeOf(ctx.rice_params)).pointer.child, buf_count32)).ptr;

        // 32 bits raw samples buffers
        // [GUARD_FRONT] [[CH]...[CH]] [GUARD]
        const sample_buf_len = guard_front32 + block_len32 * buf_count32 + guard_len32;
        const sample_buf = try ally.alignedAlloc(i32, simd.ALIGNMENT32, sample_buf_len);
        for (0..buf_count32) |i| {
            ctx.samples[i] = @alignCast(sample_buf[block_len32 * i + guard_front32 ..].ptr);
        }

        // 32 bits residuals buffers
        // [GUARD_FRONT] [[CH][GUARD]..[CH][GUARD]]
        const res_buf_len = guard_front32 + (block_len32 + guard_len32) * buf_count32;
        const res_buf = try ally.alignedAlloc(i32, simd.ALIGNMENT32, res_buf_len);
        for (0..buf_count32) |i| {
            ctx.residuals[i] =
                @alignCast(res_buf[guard_front32 + (block_len32 + guard_len32) * i ..].ptr);
        }

        // 64 bits side samples buffer
        if (self.cfg.bit_depth == 32) {
            if (self.cfg.compression.stereo_decorrelation == true and self.cfg.channels != 1) {
                // [GUARD_FRONT] [CH] [GUARD]
                const wsample_buf_len = guard_front64 + block_len64 + guard_len64;
                const wsample_buf = try ally.alignedAlloc(i64, simd.ALIGNMENT64, wsample_buf_len);
                ctx.samples64 = @alignCast(wsample_buf[guard_front64..].ptr);
            }
        }
    }
}

/// Calculate guarenteed enough frame_writer buffer size for the encoder setting
fn maxFrameBytes(bit_depth: u6, channels: u4, block_size: u16, stereo_decorrelation: bool) usize {
    // header
    // 4 half bytes + frame_no + unusual blocksize + unusual samplerate + crc8
    const header_max: usize = 2 + 7 + 2 + 2 + 1;
    const subframe_header_max: usize = 8;
    // data (estimate verbatim as max, plus 1 more channel as free space)
    const bps: usize = if (channels == 2 and stereo_decorrelation) bit_depth + 1 else bit_depth;
    const byte_per_sample: usize = @divCeil(bps, 8);
    const data_estimate = @as(usize, block_size) * byte_per_sample * (channels + 1);
    // footer (crc16)
    const footer = 2;
    return header_max + subframe_header_max * channels + data_estimate + footer;
}

const StereoChannel = enum(u2) { left = 0, right = 1, mid = 2, side = 3 };
