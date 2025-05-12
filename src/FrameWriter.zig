const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");

writer: std.io.AnyWriter,

buffer: u64 = 0,
buffer_len: u8 = 0,

crc16: std.hash.crc.Crc(u16, .{
    .polynomial = 0x8005,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
}) = .init(),
crc8: std.hash.crc.Crc(u8, .{
    .polynomial = 0x07,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
}) = .init(),

pub fn init(writer: std.io.AnyWriter) @This() {
    return .{
        .writer = writer,
    };
}

// Write number of bits to the file
pub fn writeBits(self: *@This(), size: u8, value: u64, comptime calc_crc: CalcCrc) !void {
    self.buffer <<= @truncate(size);
    self.buffer |= value & ((@as(u64, 1) << @truncate(size)) - 1);
    self.buffer_len += size;

    while (self.buffer_len >= 8) {
        self.buffer_len -= 8;
        const byte: u8 = @truncate(self.buffer >> @truncate(self.buffer_len));
        self.calcCrc(calc_crc, byte);
        try self.writer.writeByte(byte);
    }
}

// Write bytes to the file
pub fn writeInt(self: *@This(), comptime T: type, value: T, comptime calc_crc: CalcCrc) !void {
    std.debug.assert(self.buffer_len == 0);
    switch (@typeInfo(T)) {
        .int => |t| if (t.bits % 8 != 0) @compileError("CrcWriter.writeInt: Int type must have bits power of 8."),
        else => @compileError("CrcWriter.writeInt: Unsupported type \"" ++ @typeName(T) ++ "\""),
    }

    const value_le = std.mem.nativeToLittle(T, value);
    const bytes: [@sizeOf(T)]u8 = @bitCast(value_le);
    for (bytes) |byte| {
        self.calcCrc(calc_crc, byte);
    }

    try self.writer.writeInt(T, value, .little);
}

// Flush remaining bits and align it to a byte
pub fn flushByte(self: *@This(), comptime calc_crc: CalcCrc) !void {
    if (self.buffer_len != 0) {
        try self.writeInt(u8, @truncate(self.buffer << @truncate(8 - self.buffer_len)), calc_crc);
    }
}

// Write Crc8 in frame header
pub inline fn writeCrc8(self: *@This()) !void {
    try self.writeInt(u8, self.crc8.final(), .only16);
}

// Write Crc16 in frame footer
pub inline fn writeCrc16(self: *@This()) !void {
    try self.writeInt(u16, std.mem.nativeToBig(u16, self.crc16.final()), .none);
}

/// Write frame header
pub fn writeHeader(
    self: *@This(),
    is_fixed_size: bool,
    block_size: u32,
    sample_rate: u24, // 0 if `Streaminfo.sample_rate` is consistant across the file
    channels: Channels,
    bit_depth: u8, // 0 if `Streaminfo.bit_depth` is consistant across the file
    frame_sample_number: usize,
) !void {
    // Frame sync header
    try self.writeInt(u16, std.mem.nativeToBig(u16, if (is_fixed_size) 0xFFF8 else 0xFFF9), .both);
    // Write block size
    var uncommon_block_size: enum(u8) { none, byte = 1, half = 2 } = .none;

    if (blk: {
        const ctz = @ctz(block_size);
        const clz = @clz(block_size);
        break :blk clz + ctz == @bitSizeOf(usize) - 1 and ctz <= 15 and ctz >= 8;
    }) {
        try self.writeBits(4, @ctz(block_size), .both);
    } else if (block_size == 192) {
        try self.writeBits(4, 1, .both);
    } else if (blk: {
        const rem = block_size / 144;
        break :blk @clz(rem) + @ctz(rem) == @bitSizeOf(usize) - 1 and @ctz(rem) <= 5 and @ctz(rem) >= 2;
    }) {
        try self.writeBits(4, @ctz(block_size / 144), .both);
    } else if (block_size <= 0x100) {
        try self.writeBits(4, 0b0110, .both);
        uncommon_block_size = .byte;
    } else {
        try self.writeBits(4, 0b0111, .both);
        uncommon_block_size = .half;
    }
    // Write sample rate
    var uncommon_sample_rate: enum { none, byte, half, half_tenth } = .none;
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
        .both,
    );
    // Write channels
    std.debug.assert(@as(u8, @intFromEnum(channels)) <= 10);
    try self.writeBits(4, @intFromEnum(channels), .both);
    // Write bit depth
    try self.writeBits(
        4,
        switch (bit_depth) {
            0 => 0,
            8 => 2,
            12 => 4,
            16 => 8,
            20 => 10,
            24 => 12,
            32 => 14,
            else => unreachable,
        },
        .both,
    );
    // Write frame/sample number
    if (frame_sample_number <= 0x7F) {
        try self.writeInt(u8, @truncate(frame_sample_number), .both);
    } else {
        std.debug.assert(frame_sample_number <= 0x000f_ffff_ffff);
        var buffer: u64 = 0;
        var i: u6 = 0;
        var first_byte_max: usize = 0b11111;
        var number: usize = frame_sample_number;
        while (number > first_byte_max) { // 0x10xxxxxx
            buffer |= (0b10000000 + (number & 0b111111)) << (8 * i);
            i += 1;
            number >>= 6;
            first_byte_max >>= 1;
        }
        buffer |= ((@as(u64, 0b11111110) << (6 - i)) | number) << (8 * i); // first byte
        try self.writeBits(8 * (i + 1), buffer, .both);
    }
    // Write uncommon block size
    std.debug.assert(!(uncommon_block_size == .half and block_size >= 65536));
    switch (uncommon_block_size) {
        .none => {},
        else => try self.writeBits(@intFromEnum(uncommon_block_size) * 8, block_size - 1, .both),
    }
    // Write uncommon sample rate
    switch (uncommon_sample_rate) {
        .none => {},
        .byte => try self.writeBits(8, block_size, .both),
        else => try self.writeBits(16, block_size * @as(u64, if (uncommon_sample_rate == .half) 1 else 10), .both),
    }
    // Write Crc8
    try self.writeCrc8();
}

pub fn writeVerbatimSubframe(self: *@This(), samples: [][4]u8, bit_depth: u8) !void {
    try self.writeInt(u8, 2, .only16); // Verbatim coding
    for (samples) |sample| {
        try self.writeBits(bit_depth, @as(u32, @as(u32, @bitCast(sample))), .only16);
    }
}

fn calcCrc(self: *@This(), calc_crc: CalcCrc, byte: u8) void {
    if (calc_crc == .both) self.crc8.update(&.{byte});
    if (calc_crc != .none) self.crc16.update(&.{byte});
}

pub const CalcCrc = enum {
    none,
    only16,
    both,
};

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
