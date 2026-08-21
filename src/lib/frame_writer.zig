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

buffer: []u64,
end: usize = 0,
remain_bits: u8 = W_BIT,

crc16: Crc16 = .{},

bytes_written: u24 = 0,

// -- Initializer --

/// `writer`: underlying writer
/// `buffer`: bits buffer of length between 2 and 2^32
pub fn init(writer: *std.Io.Writer, buffer: []u64) FrameWriter {
    @memset(buffer, 0);
    return .{ .writer = writer, .buffer = buffer };
}

// -- Methods --

/// Write number of bits to the file (big endian) \
/// Use `writeBitsWrapped()` if writing signed negative integers
pub fn writeBits(self: *FrameWriter, size: u8, value: u64) Writer.Error!void {
    std.debug.assert(size <= 64);
    if (size == 0) return;

    if (self.remain_bits >= size) {
        @branchHint(.likely);
        const shift_amount = self.remain_bits - size;
        self.buffer[self.end] |= value << @intCast(shift_amount);
        self.remain_bits -= size;
        return;
    }
    // if (self.remain_bits <= size)
    const first_shift_amount = size - self.remain_bits;
    const second_shift_amount = W_BIT - first_shift_amount;
    self.buffer[self.end] |= value >> @intCast(first_shift_amount);
    self.remain_bits = second_shift_amount;
    self.end += 1;

    // if (first_shift_amount == 0) return;

    if (self.end == self.buffer.len) {
        @branchHint(.cold);
        try self.flushAllNoBitEndReset();
    }

    if (first_shift_amount != 0) self.buffer[self.end] = value << @intCast(second_shift_amount);
}

/// Should be used instead of `writeBits()` when writing signed negative integers
pub inline fn writeBitsSigned(self: *FrameWriter, size: u8, value: u64) Writer.Error!void {
    const bits = value & (@as(u64, std.math.maxInt(u64)) >> @truncate(64 - size));
    return self.writeBits(size, bits);
}

pub fn writeZeros(self: *FrameWriter, size: usize) Writer.Error!void {
    if (self.remain_bits >= size) {
        @branchHint(.likely);
        self.remain_bits -= @intCast(size);
        return;
    }
    const remain_size = size - self.remain_bits;
    var advance_word = remain_size / W_BIT + 1;
    const remain_bits = W_BIT - (remain_size % W_BIT);

    if (self.end + advance_word >= self.buffer.len) {
        @branchHint(.cold);
        advance_word -= self.buffer.len - self.end;
        self.end = self.buffer.len;
        try self.flushAllNoBitEndReset();
    }
    self.end += advance_word;
    self.remain_bits = @intCast(remain_bits);
}

/// Flush all written bits aligned to bytes
pub fn flushAll(self: FrameWriter) Writer.Error!void {
    try self.flushAllNoBitEndReset();
    self.remain_bits = W_BYTE;
}

/// Flush all written bits aligned to bytes \
/// Does not reset `self.bit_end`
fn flushAllNoBitEndReset(self: *FrameWriter) Writer.Error!void {
    // Little to Big Endian
    const byte_swap_len =
        if (self.remain_bits != W_BIT and self.end != self.buffer.len) self.end + 1 else self.end;
    for (0..byte_swap_len) |i| {
        self.buffer[i] = std.mem.nativeToBig(u64, self.buffer[i]);
    }

    // Crc16
    const byte_end = if (self.end == self.buffer.len) 0 else W_BYTE - (self.remain_bits / 8);
    const stream: []u8 = std.mem.sliceAsBytes(self.buffer)[0 .. self.end * W_BYTE + byte_end];
    self.crc16.update(stream);
    try self.writer.writeAll(stream);

    self.bytes_written += @intCast(self.end * W_BYTE + byte_end);
    self.end = 0;
    @memset(self.buffer, 0);
}

/// Write Crc8 in frame header
pub fn writeCrc8(self: *FrameWriter) Writer.Error!void {
    var words: [2]u64 = self.buffer[0..2].*;
    inline for (&words) |*w| w.* = std.mem.nativeToBig(u64, w.*);
    const byte_end = W_BYTE - (self.remain_bits / 8);
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
    residuals: []i32,
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
        // Calculate zigzags for the partition
        var zigzags: []u32 = @ptrCast(part_residuals);
        for (0..zigzags.len) |i| zigzags[i] = rice.calcZigzag(part_residuals[i]);
        // Write rice param
        try self.writeBits(param_len, part_param);
        // Write rice coded residuals
        try self.writeRicePart(zigzags, part_param);
    }
}

pub fn writeRicePart(self: *FrameWriter, zigzags: []u32, param: u5) Writer.Error!void {
    const mask = @as(u64, 1) << param;
    for (zigzags) |zz| {
        const rice_code: rice.Code = .makeFromZz(param, zz);
        // Write Quotient
        try self.writeZeros(rice_code.quo);
        // Write Remainder
        try self.writeBits(@as(u8, param) + 1, mask | rice_code.rem);
    }
}
