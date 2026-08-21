const std = @import("std");
const builtin = @import("builtin");

const flac_type = @import("type.zig");
const metadata = @import("metadata.zig");
const rice = @import("rice.zig");
const Channel = flac_type.Channel;
const Crc16 = @import("crc16.zig");
const Writer = std.Io.Writer;
const FrameWriter = @This();

const W_BIT: u8 = 64;
const W_BYTE: u8 = 8;

// -- Members --

writer: *std.Io.Writer,

accu: u64 = undefined,
buffer: []u64,
end: usize = 0,
remain_bits: u8 = W_BIT,

crc16: Crc16 = .{},

bytes_written: u24 = 0,

// -- Initializer --

/// `writer`: underlying writer
/// `buffer`: bits buffer of length between 2 and 2^32
pub fn init(writer: *std.Io.Writer, buffer: []u64) FrameWriter {
    return .{ .writer = writer, .buffer = buffer };
}

// -- Methods --

/// Write number of bits to the file (big endian) \
/// Use `writeBitsWrapped()` if writing signed negative integers
fn writeBits(self: *FrameWriter, bits: u8, value: u64) Writer.Error!void {
    std.debug.assert(bits <= 64);
    if (bits == 0) return;

    if (bits <= self.remain_bits) {
        self.accu <<= @intCast(bits);
        self.accu |= value;
        self.remain_bits -= bits;
    } else { // if (self.remain_bits <= size)
        // write fitable bits
        const shift_amount = bits - self.remain_bits;
        self.accu <<= @intCast(self.remain_bits);
        self.accu |= value >> @intCast(shift_amount);
        self.buffer[self.end] = std.mem.nativeToBig(u64, self.accu);
        // write remaining bits anyways
        self.accu = value;
        self.remain_bits = W_BIT - shift_amount;
        self.end += 1;
    }
}

/// Should be used instead of `writeBits()` when writing signed negative integers
inline fn writeBitsSigned(self: *FrameWriter, size: u8, value: u64) Writer.Error!void {
    const bits = value & (@as(u64, std.math.maxInt(u64)) >> @truncate(64 - size));
    return self.writeBits(size, bits);
}

/// Write `bits` of zeros
fn writeZeros(self: *FrameWriter, bits: u32) Writer.Error!void {
    if (bits == 0) return;

    var remain = bits;

    // fill remain space first
    if (self.remain_bits != W_BIT) {
        const first_fill = @min(self.remain_bits, bits);
        self.accu <<= @intCast(first_fill);
        self.remain_bits -= first_fill;
        remain -= first_fill;

        if (self.remain_bits == 0) {
            self.buffer[self.end] = std.mem.nativeToBig(u64, self.accu);
            self.remain_bits = W_BIT;
            self.end += 1;
        }
        if (remain == 0) {
            return;
        }
    }

    // fill aligned 64bits zeros
    while (remain >= 64) : (remain -= 64) {
        self.buffer[self.end] = 0;
        self.end += 1;
    }

    // fill remaining
    if (remain != 0) {
        self.accu = 0;
        self.remain_bits = @intCast(W_BIT - remain);
    }
}

/// Flush all written bits aligned to bytes
pub fn flushAll(self: FrameWriter) Writer.Error!void {
    try self.flushAllNoBitEndReset();
    self.remain_bits = W_BYTE;
}

/// Flush all written bits aligned to bytes \
/// Does not reset `self.bit_end`
fn flushAllNoBitEndReset(self: *FrameWriter) Writer.Error!void {
    var byte_count = self.end * 8;
    // Byte align the last qword
    if (self.end < self.buffer.len and self.remain_bits != W_BIT) {
        self.buffer[self.end] = std.mem.nativeToBig(u64, self.accu << @intCast(self.remain_bits));
        byte_count += W_BYTE - @divFloor(self.remain_bits, 8);
    }
    // Crc16
    const stream: []u8 = std.mem.sliceAsBytes(self.buffer)[0..byte_count];
    self.crc16.update(stream);
    try self.writer.writeAll(stream);
    // update FrameWriter states
    self.bytes_written += @intCast(byte_count);
    self.end = 0;
}

/// Write Crc8 in frame header
pub fn writeCrc8(self: *FrameWriter) Writer.Error!void {
    const accu = std.mem.nativeToBig(u64, self.accu << @truncate(self.remain_bits));
    var words: [2]u64 = switch (self.end) {
        0 => .{ accu, undefined },
        1 => .{ self.buffer[0], accu },
        else => unreachable,
    };
    const byte_end = W_BYTE - @divFloor(self.remain_bits, 8);
    const bytes: []u8 = std.mem.asBytes(&words)[0 .. self.end * W_BYTE + byte_end];

    var crc8: std.hash.crc.Crc8Smbus = .init();
    crc8.update(bytes);
    try self.writeBits(8, crc8.final());
}

/// Write Crc16 in frame footer
pub inline fn writeCrc16(self: *FrameWriter) Writer.Error!void {
    if (self.end != 0 or self.remain_bits != W_BIT) try self.flushAllNoBitEndReset();
    self.bytes_written += 2;
    try self.writer.writeInt(u16, self.crc16.crc, .big);
}

/// Write frame header
pub fn writeHeader(
    self: *FrameWriter,
    frame_number: u36,
    bit_depth: u8, // 0 if `Streaminfo.bit_depth` is consistant across the file
    channels: Channel,
    block_size: u16,
    sample_rate: u24, // 0 if `Streaminfo.sample_rate` is consistant across the file
    is_fixed_size: bool,
) Writer.Error!void {
    std.debug.assert(self.remain_bits == W_BIT);
    std.debug.assert(block_size != 0);
    // Frame sync header
    try self.writeBits(16, if (is_fixed_size) 0xFFF8 else 0xFFF9);
    // Write block size
    var uncommon_block_size: enum(u6) { none, byte = 8, half = 16 } = .none;

    if (blk: { // 2^v
        const ctz = @ctz(block_size);
        break :blk std.math.isPowerOfTwo(block_size) and ctz <= 15 and ctz >= 8;
    }) {
        try self.writeBits(4, @ctz(block_size));
    } else if (block_size == 192) { // 192
        try self.writeBits(4, 1);
    } else if (blk: { // 144 * 2^v
        const ctz: u4 = @intCast(@ctz(block_size));
        break :blk (block_size >> ctz == 144) and ctz <= 5 and ctz >= 2;
    }) {
        try self.writeBits(4, @ctz(block_size));
    } else if (block_size < 0x100) { // 8bits uncommon block size
        try self.writeBits(4, 0b0110);
        uncommon_block_size = .byte;
    } else { // 16bits uncommon block size
        try self.writeBits(4, 0b0111);
        uncommon_block_size = .half;
    }
    // Write sample rate
    var uncommon_sample_rate: enum(u8) { none, byte = 4, half = 1, half_tenth = 10 } = .none;
    try self.writeBits(
        4,
        switch (sample_rate) {
            0 => 0,
            88200 => 1,
            176400 => 2,
            192000 => 3,
            8000 => 4,
            16000 => 5,
            22050 => 6,
            24000 => 7,
            32000 => 8,
            44100 => 9,
            48000 => 10,
            96000 => 11,
            else => blk: {
                uncommon_sample_rate = switch (sample_rate) {
                    0...255 => .byte,
                    256...65535 => .half,
                    else => .half_tenth,
                };
                break :blk switch (uncommon_sample_rate) {
                    .none => unreachable,
                    .byte => 12,
                    .half => 13,
                    .half_tenth => 14,
                };
            },
        },
    );
    // Write channels
    try self.writeBits(4, channels.get_int());
    // Write bit depth
    try self.writeBits(
        4,
        switch (bit_depth) {
            0 => 0,
            8 => 2,
            12 => unreachable, //4,
            16 => 8,
            20 => unreachable, //10,
            24 => 12,
            32 => 14,
            else => unreachable,
        },
    );
    // Write frame/sample number
    if (frame_number <= 0x7F) {
        try self.writeBits(8, @intCast(frame_number));
    } else {
        std.debug.assert(frame_number <= 0x000f_ffff_ffff);
        var buffer: u56 = 0;
        var i: u6 = 0;
        var first_byte_max: usize = 0b111111;
        var number = frame_number;
        while (number > first_byte_max) { // 0x10xxxxxx
            buffer |= (0b1000_0000 + (number & 0b111111)) << (8 * i);
            i += 1;
            number >>= 6;
            first_byte_max >>= 1;
        }
        buffer |= ((@as(u56, 0b11111110) << (6 - i)) | number) << (8 * i); // first byte
        try self.writeBitsSigned(8 * (i + 1), buffer);
    }
    // Write uncommon block size
    switch (uncommon_block_size) {
        .none => {},
        else => try self.writeBits(@intFromEnum(uncommon_block_size), block_size - 1),
    }
    // Write uncommon sample rate
    switch (uncommon_sample_rate) {
        .none => {},
        .byte => try self.writeBits(8, @intCast(block_size)),
        else => try self.writeBits(16, @intCast(block_size / @intFromEnum(uncommon_sample_rate))),
    }
    // Write Crc8
    try self.writeCrc8();
}

/// Write subframe in Constant encoding \
/// Wasted Bits in Constant Subframe makes no sense at all (?
pub fn writeConstantSubframe(
    self: *FrameWriter,
    sample: i64,
    bps: u6,
    waste_bits: u6,
) Writer.Error!void {
    // subframe Header: syncBit[0](1) + Constant Coding[000000](6) + WastedBits[0](1)
    try self.writeBits(8, 0);
    // Waste bits unary code takes the same digits as waste bits itself, doesn't worth one more call
    try self.writeBitsSigned(bps + waste_bits, @bitCast(sample << waste_bits));
}

/// Write subframe in Verbatim encoding
pub fn writeVerbatimSubframe(
    self: *FrameWriter,
    T: type,
    samples: []const T,
    bps: u6,
    waste_bits: u6,
) Writer.Error!void {
    if (T != i32 and T != i64) @compileError("expect T as i32 or i64, found " ++ @typeName(T));
    // Subframe Header: SyncBit[0](1) + Verbatim Coding[000001](6) + WastedBits[F](1)
    if (waste_bits == 0) {
        try self.writeBits(8, 0b10);
    } else {
        try self.writeBits(8, 0b11);
        try self.writeBits(waste_bits, 1);
    }

    for (samples) |sample| {
        try self.writeBitsSigned(bps, @bitCast(@as(i64, @intCast(sample))));
    }
}

pub fn writeFixedSubframe(
    self: *FrameWriter,
    warmup_samples: [4]i64,
    residuals: []const i32,
    order: u8,
    rice_config: rice.Config,
    bps: u6,
    waste_bits: u6,
) Writer.Error!void {
    const param_len: u6 = @intFromEnum(rice_config.method) + 4;
    const part_count = @as(usize, 1) << rice_config.part_order;
    const escape_code: u5 = if (rice_config.method == .FOUR) 0b1111 else 0b11111;

    // Subframe Header: SyncBit[0](1) + Fixed Coding[001NNN](6) + WastedBits[F](1)
    if (waste_bits == 0) {
        try self.writeBits(8, (8 | order) << 1);
    } else {
        try self.writeBits(8, ((8 | order) << 1) | 1);
        try self.writeBits(waste_bits, 1);
    }
    // Write unencoded warm-up samples
    for (0..order) |i| {
        try self.writeBitsSigned(bps, @bitCast(warmup_samples[i]));
    }

    // Rice code with N bits param(2) + Partition order(4)
    try self.writeBits(2 + 4, (@intFromEnum(rice_config.method) << 4) | rice_config.part_order);

    // Write Rice codes
    var remain_residuals = residuals[order..];
    var part_len = (residuals.len >> rice_config.part_order) - order;
    for (rice_config.params[0..part_count]) |param| { // Partition
        defer { // Update part_size and residual start after every iteration
            remain_residuals = remain_residuals[part_len..];
            part_len = residuals.len >> rice_config.part_order;
        }

        var part_param = param;
        const part_residuals = remain_residuals[0..part_len];

        if (param == escape_code) if_blk: { // Escaped
            @branchHint(.cold);
            // Calc minimum bits to store the numbers
            var res_max: i32 = 0;
            var or_all: i32 = 0;
            for (part_residuals) |r| {
                res_max |= r ^ (r >> 31);
                or_all |= r;
            }
            const bits_per_sample =
                if (or_all == 0) 0 else if (res_max == 0) 1 else (@clz(res_max) ^ 31) + 2;
            // Flac cannot hold 32bits escaped samples, so need to fall back to param=30
            if (bits_per_sample >= 32) {
                part_param = 30;
                break :if_blk;
            }
            // Write rice param
            try self.writeBits(param_len, part_param);
            // Write bits per sample (of escape partition)
            try self.writeBits(5, @intCast(bits_per_sample));
            // Write nothing if bits per sample is 0
            if (bits_per_sample == 0) continue;
            // Write escaped samples
            for (part_residuals) |r| {
                try self.writeBitsSigned(@intCast(bits_per_sample), @as(u32, @bitCast(r)));
            }
            continue;
        }
        // Rice Coded
        // Write rice param
        try self.writeBits(param_len, part_param);
        // Write rice coded residuals
        try self.writeRicePart(part_residuals, part_param);
    }
}

pub fn writeRicePart(self: *FrameWriter, residuals: []const i32, param: u5) Writer.Error!void {
    const mask = @as(u64, 1) << param;
    for (residuals) |res| {
        const rice_code: rice.Code = .make(param, res);
        // Write Quotient
        try self.writeZeros(rice_code.quo);
        // Write Remainder
        try self.writeBits(@as(u8, param) + 1, mask | rice_code.rem);
    }
}
