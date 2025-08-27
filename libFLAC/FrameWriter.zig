const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");
const rice_code = @import("rice_code.zig");

const RiceCode = rice_code.RiceCode;
const RiceConfig = rice_code.RiceConfig;

const W_BIT: u8 = 64;
const W_BYTE: u8 = 8;

// -- Members --

writer: *std.Io.Writer,

buffer: []u64,
end: usize = 0,
bit_end: u8 = 0,

crc16: std.hash.crc.Crc16Umts = .init(),

bytes_written: u24 = 0,

// -- Initializer --

/// `writer`: underlying writer
/// `buffer`: bits buffer of length between 2 and 2^32
pub fn init(writer: *std.Io.Writer, buffer: []u64) @This() {
    return .{ .writer = writer, .buffer = buffer };
}

// -- Methods --

/// Write number of bits to the file (big endian) \
/// Use `writeBitsWrapped()` if writing signed negative integers
pub fn writeBits(self: *@This(), size: u8, value: u64) error{WriteFailed}!void {
    std.debug.assert(size != 0 and size <= 64);
    
    const remain_bits = W_BIT - self.bit_end;
    if (size < remain_bits) {
        self.buffer[self.end] <<= @intCast(size);
        self.buffer[self.end] |= value;
        self.bit_end += @intCast(size);
        return;
    }
    self.bit_end = size - remain_bits;
    self.buffer[self.end] <<= @truncate(remain_bits);
    self.buffer[self.end] |= value >> @intCast(self.bit_end);
    self.end += 1;

    if (self.end == self.buffer.len) {
        @branchHint(.cold);
        try self.flushAllNoBitEndReset();
    }

    self.buffer[self.end] = value;
}

/// Should be used instead of `writeBits()` when writing signed negative integers
pub inline fn writeBitsWrapped(self: *@This(), size: u7, value: u64) error{WriteFailed}!void {
    const bits = value & (@as(u64, std.math.maxInt(u64)) >> @intCast(64 - size));
    return self.writeBits(size, bits);
}

/// Flush all written bits aligned to bytes
pub fn flushAll(self: *@This()) error{WriteFailed}!void {
    try self.flushAllNoBitEndReset();
    self.bit_end = 0;
}

/// Flush all written bits aligned to bytes \
/// Does not reset `self.bit_end`
fn flushAllNoBitEndReset(self: *@This()) error{WriteFailed}!void {
    if (self.end != self.buffer.len) try self.flushWord();
    const bit_end: u8 = if (self.end == self.buffer.len) 0 else self.bit_end;
    const byte_end = bit_end / 8;

    for (0..self.buffer.len) |i| { // byteSwap
        self.buffer[i] = std.mem.nativeToBig(u64, self.buffer[i]);
    }
    const stream: []u8 = std.mem.sliceAsBytes(self.buffer)[0..self.end * W_BYTE + byte_end];
    self.crc16.update(stream);
    try self.writer.writeAll(stream);

    self.bytes_written += @intCast(self.end * W_BYTE + byte_end);
    self.end = 0;
}

/// Padding zeros behind to align written bits to head of word \
/// Only use for `flushAll...`
fn flushWord(self: *@This()) error{WriteFailed}!void {
    if (self.bit_end == 0) return;
    const shift_amt: u8 = W_BIT - self.bit_end;
    self.buffer[self.end] <<= @intCast(shift_amt);
    self.bit_end += shift_amt % 8;
}

/// Write Crc8 in frame header
pub fn writeCrc8(self: *@This()) error{WriteFailed}!void {
    var words: [2]u64 = self.buffer[0..2].*;
    const word_shift_amt: u8 = W_BIT - self.bit_end;
    words[self.end] = words[self.end] << @intCast(word_shift_amt);
    inline for (&words) |*w| w.* = std.mem.nativeToBig(u64, w.*);
    const bytes: []u8 = std.mem.asBytes(&words)[0..self.end * W_BYTE + (self.bit_end + 7) / 8];
    
    var crc8: std.hash.crc.Crc8Smbus = .init();
    crc8.update(bytes);
    try self.writeBits(8, crc8.final());
}

/// Write Crc16 in frame footer
pub inline fn writeCrc16(self: *@This()) error{WriteFailed}!void {
    if (self.end != 0 or self.bit_end != 0) try self.flushAllNoBitEndReset();
    self.bytes_written += 2;
    try self.writer.writeInt(u16, self.crc16.final(), .big);
}

/// Write frame header
pub fn writeHeader(
    self: *@This(),
    is_fixed_size: bool,
    block_size: u32,
    sample_rate: u24, // 0 if `Streaminfo.sample_rate` is consistant across the file
    channels: Channels,
    bit_depth: u8, // 0 if `Streaminfo.bit_depth` is consistant across the file
    frame_sample_number: u36,
) error{WriteFailed}!void {
    std.debug.assert(self.bit_end == 0);
    // Frame sync header
    try self.writeBits(16, if (is_fixed_size) 0xFFF8 else 0xFFF9);
    // Write block size
    var uncommon_block_size: enum(u6) { none, byte = 8, half = 16 } = .none;

    if (blk: {
        const ctz = @ctz(block_size);
        break :blk std.math.isPowerOfTwo(block_size) and ctz <= 15 and ctz >= 8;
    }) {
        try self.writeBits(4, @ctz(block_size));
    } else if (block_size == 192) {
        try self.writeBits(4, 1);
    } else if (blk: {
        const rem = block_size / 144;
        break :blk std.math.isPowerOfTwo(rem) and @ctz(rem) <= 5 and @ctz(rem) >= 2;
    }) {
        try self.writeBits(4, @ctz(block_size / 144));
    } else if (block_size <= 0x100) {
        try self.writeBits(4, 0b0110);
        uncommon_block_size = .byte;
    } else {
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
                uncommon_sample_rate = if (sample_rate <= 255) .byte else if (sample_rate <= 65535) .half else .half_tenth;
                break :blk switch (uncommon_sample_rate) {
                    .byte => 12,
                    .half => 13,
                    .half_tenth => 14,
                    else => unreachable,
                };
            },
        },
    );
    // Write channels
    std.debug.assert(@as(u8, @intFromEnum(channels)) <= 10);
    try self.writeBits(4, @intFromEnum(channels));
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
    if (frame_sample_number <= 0x7F) {
        try self.writeBits(8, @intCast(frame_sample_number));
    } else {
        std.debug.assert(frame_sample_number <= 0x000f_ffff_ffff);
        var buffer: u56 = 0;
        var i: u6 = 0;
        var first_byte_max: usize = 0b111111;
        var number = frame_sample_number;
        while (number > first_byte_max) { // 0x10xxxxxx
            buffer |= (0b1000_0000 + (number & 0b111111)) << (8 * i);
            i += 1;
            number >>= 6;
            first_byte_max >>= 1;
        }
        buffer |= ((@as(u56, 0b11111110) << (6 - i)) | number) << (8 * i); // first byte
        try self.writeBitsWrapped(8 * (i + 1), buffer);
    }
    // Write uncommon block size
    std.debug.assert(!(uncommon_block_size == .half and block_size >= 65536));
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
pub fn writeConstantSubframe(self: *@This(), sample_size: u6, sample: i64) error{WriteFailed}!void {
    // subframe Header: syncBit[0](1) + Constant Coding[000000](6) + WastedBits[0](1)
    try self.writeBits(8, 0);
    try self.writeBitsWrapped(sample_size, @bitCast(sample));
}

/// Write subframe in Verbatim encoding
pub fn writeVerbatimSubframe(
    self: *@This(),
    SampleT: type,
    sample_size: u6,
    samples: []const SampleT,
) error{WriteFailed}!void {
    // Subframe Header: SyncBit[0](1) + Verbatim Coding[000001](6) + WastedBits[0](1)
    try self.writeBits(8, 1 << 1);

    for (samples) |sample| {
        const sample_u: std.meta.Int(.unsigned, @bitSizeOf(SampleT)) = @bitCast(sample);
        try self.writeBitsWrapped(sample_size, sample_u);
    }
}

pub fn writeFixedSubframe(
    self: *@This(),
    sample_size: u6,
    residuals: []i32,
    order: u8,
    rice_config: RiceConfig,
) error{WriteFailed}!void {
    const param_len: u6 = @intFromEnum(rice_config.method) + 4;
    const part_count = @as(usize, 1) << rice_config.part_order;

    // Bug writing subframe header?
    try self.writeBits(8, (8 | order) << 1); // N-th order Fixed coding

    // Write Unencoded warm-up samples
    for (0..order) |i| {
        try self.writeBitsWrapped(sample_size, @as(u32, @bitCast(residuals[i])));
    }

    // Rice code with N bits param(2) + Partition order(4)
    try self.writeBits(2 + 4, (@intFromEnum(rice_config.method) << 4) | rice_config.part_order);

    // Write Rice codes
    var remain_residuals = residuals[order..];
    var part_size = (residuals.len >> rice_config.part_order) - order;
    for (rice_config.params[0..part_count]) |param| { // Partition
        // Write rice param
        try self.writeBits(param_len, param);

        const part_residuals = remain_residuals[0..part_size];

        if (param == rice_code.ESC_PART) { // Escaped
            // Calc minimum bits to store the numbers
            // var min_digits: u6 = 0;
            // for (part_residuals) |r| {
            //     const digits: u6 = 32 - @as(u6, @intCast(@clz(@abs(r)))) + 1;
            //     if (digits > min_digits) min_digits = digits;
            // }
            // try self.writeBits(5, min_digits);
            // for (part_residuals) |r| {
            //     try self.writeBits(min_digits, @as(u32, @bitCast(r)));
            // }

            // Currently is just 0
            // try self.writeBits(5, 0);
            //
            // std.debug.print("ESCAPE!!!\n", .{});
            unreachable;
        } else { // Normal
            try self.writeRicePart(part_residuals, param);
        }
        remain_residuals = remain_residuals[part_size..];
        part_size = residuals.len >> rice_config.part_order;
    }
}

pub fn writeRicePart(self: *@This(), residuals: []i32, param: u6) error{WriteFailed}!void {
    for (residuals) |res| {
        var rice: RiceCode = .make(param, res);
        // Write Quotient
        while (rice.quo > 63) : (rice.quo -= 64) {
            @branchHint(.unlikely);
            try self.writeBits(64, 0);
        }
        try self.writeBits(@intCast(rice.quo + 1), 1);
        // Write Remainder
        try self.writeBits(param, rice.rem);
    }
}

// -- Enums --

pub const Channels = enum(u8) {
    stereo_left_side = 8,
    stereo_side_right = 9,
    stereo_mid_side = 10,
    _,

    pub fn simple(channels: u8) Channels {
        return switch (channels) {
            1...8 => @enumFromInt(channels - 1),
            else => unreachable,
        };
    }
};
