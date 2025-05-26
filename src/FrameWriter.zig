const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");
const rice_code = @import("rice_code.zig");
const SingleChannelIter = @import("sample_iter.zig").SingleChannelIter;
const RiceCode = rice_code.RiceCode;
const RiceConfig = rice_code.RiceConfig;

// -- Members --

writer: std.io.AnyWriter,

buffer: u64 = 0,
buffer_len: u6 = 0,

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

// -- Initializer --

pub fn init(writer: std.io.AnyWriter) @This() {
    return .{
        .writer = writer,
    };
}

// -- Methods --

/// Write number of bits to the file (big endian)
/// Remember to shrink bytes manually when writing negative numbers,
/// or when byte_count exceeds `size` specified
pub fn writeBits(self: *@This(), size: u7, value: u64, comptime calc_crc: CalcCrc) !void {
    std.debug.assert(size <= 64);

    const remain_bits: u7 = 64 - @as(u7, self.buffer_len);
    if (remain_bits <= size) {
        self.buffer <<= if (builtin.mode == .Debug) @truncate(remain_bits) else @intCast(remain_bits);
        self.buffer |= value >> @intCast(size - remain_bits);

        self.calcCrc(calc_crc, &std.mem.toBytes(std.mem.nativeToBig(u64, self.buffer)));
        try self.writer.writeInt(u64, self.buffer, .big);
        self.buffer_len = 0;

        self.buffer_len = @intCast(size - remain_bits);
        self.buffer = value;
    } else {
        @branchHint(.likely);
        self.buffer <<= @intCast(size);
        self.buffer |= value;
        self.buffer_len += @intCast(size);
    }
}

pub fn writeRiceQuo(self: *@This(), quotient: u32) !void {
    var quo = quotient;
    while (quo > 63) : (quo -= 64) {
        @branchHint(.unlikely);
        try self.writeBits(64, 0, .only16);
    }
    try self.writeBits(@intCast(quo + 1), 1, .only16);
}

pub fn writeRice(self: *@This(), rice: RiceCode, param: u6) !void {
    // Write Quotient
    var quo = rice.quo;
    while (quo > 63) : (quo -= 64) {
        @branchHint(.unlikely);
        try self.writeBits(64, 0, .only16);
    }
    try self.writeBits(@intCast(quo + 1), 1, .only16);
    // Write Remainder
    try self.writeBits(param, rice.rem, .only16);
}

/// Flush remaining bits and align it to a byte
pub fn flushBytes(self: *@This(), comptime calc_crc: CalcCrc) !void {
    var len = self.buffer_len;
    self.buffer_len = 0;
    while (len >= 8) {
        len -= 8;
        const byte: u8 = @truncate(self.buffer >> len);
        self.calcCrc(calc_crc, &.{byte});
        try self.writer.writeByte(byte);
    }
    if (len != 0) {
        const byte: u8 = @truncate(self.buffer << @intCast(8 - @as(u8, @intCast(len))));
        self.calcCrc(calc_crc, &.{byte});
        try self.writer.writeByte(byte);
    }
}

/// Write Crc8 in frame header \
/// Make sure to call `flushByte()` before this
pub inline fn writeCrc8(self: *@This()) !void {
    const value = self.crc8.final();
    self.calcCrc(.only16, &std.mem.toBytes(value));
    try self.writer.writeInt(u8, value, .little);
}

/// Write Crc16 in frame footer \
/// Make sure to call `flushByte()` before this
pub inline fn writeCrc16(self: *@This()) !void {
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
) !void {
    std.debug.assert(self.buffer_len == 0);
    // Frame sync header
    try self.writeBits(16, if (is_fixed_size) 0xFFF8 else 0xFFF9, .both);
    // Write block size
    var uncommon_block_size: enum(u6) { none, byte = 8, half = 16 } = .none;

    if (blk: {
        const ctz = @ctz(block_size);
        const clz = @clz(block_size);
        break :blk clz + ctz == @bitSizeOf(u32) - 1 and ctz <= 15 and ctz >= 8;
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
            12 => unreachable, //4,
            16 => 8,
            20 => unreachable, //10,
            24 => 12,
            32 => 14,
            else => unreachable,
        },
        .both,
    );
    // Write frame/sample number
    if (frame_sample_number <= 0x7F) {
        try self.writeBits(8, @intCast(frame_sample_number), .both);
    } else {
        std.debug.assert(frame_sample_number <= 0x000f_ffff_ffff);
        var buffer: u56 = 0;
        var i: u6 = 0;
        var first_byte_max: usize = 0b11111;
        var number = frame_sample_number;
        while (number > first_byte_max) { // 0x10xxxxxx
            buffer |= (0b10000000 + (number & 0b111111)) << (8 * i);
            i += 1;
            number >>= 6;
            first_byte_max >>= 1; // --endian, --sign, --channels, --bps, and --sample-rate
        }
        buffer |= ((@as(u56, 0b11111110) << (6 - i)) | number) << (8 * i); // first byte
        try self.writeBits(8 * (i + 1), buffer & (@as(u64, 0xffffffffffffffff) >> @intCast(@as(u7, 64) - 8 * (i + 1))), .both);
    }
    // Write uncommon block size
    std.debug.assert(!(uncommon_block_size == .half and block_size >= 65536));
    switch (uncommon_block_size) {
        .none => {},
        else => try self.writeBits(@intFromEnum(uncommon_block_size), block_size - 1, .both),
    }
    // Write uncommon sample rate
    switch (uncommon_sample_rate) {
        .none => {},
        .byte => try self.writeBits(8, @intCast(block_size), .both),
        else => try self.writeBits(16, @intCast(block_size * @intFromEnum(uncommon_sample_rate)), .both),
    }
    try self.flushBytes(.both);
    // Write Crc8
    try self.writeCrc8();
}

/// Write subframe in Constant encoding
pub fn writeConstantsubframe(self: *@This(), sample_size: u6, sample: usize) !void {
    try self.writeBits(8, 0, .only16); // Constant coding
    try self.writeBits(sample_size, sample, .only16);
}

/// Write subframe in Verbatim encoding
pub fn writeVerbatimSubframe(
    self: *@This(),
    SampleT: type,
    sample_size: u6,
    wasted_bits: u6,
    samples_iter: *SingleChannelIter(SampleT),
) !void {
    try self.writeBits(8, if (wasted_bits == 0) 2 else 3, .only16); // Verbatim coding
    if (wasted_bits != 0) try self.writeBits(wasted_bits + 1, 1, .only16); // Write wasted_bits

    const real_sample_size = sample_size - wasted_bits;

    while (samples_iter.next()) |sample| {
        const sample_u: std.meta.Int(.unsigned, @bitSizeOf(SampleT)) = @bitCast(sample >> @intCast(wasted_bits));
        try self.writeBits(real_sample_size, sample_u, .only16);
    }
}

pub fn writeFixedSubframe(
    self: *@This(),
    sample_size: u6,
    residuals: []i32,
    order: u8,
    rice_config: RiceConfig,
) !void {
    // Bug writing subframe header?
    try self.writeBits(8, (8 | order) << 1, .only16); // N-th order Fixed coding

    // Write Unencoded warm-up samples
    for (0..order) |i| {
        try self.writeBits(sample_size, @as(u32, @bitCast(residuals[i])) & (@as(u32, 0xffffffff) >> @intCast(32 - sample_size)), .only16);
    }

    // Rice code with N nits param
    try self.writeBits(2, @intFromEnum(rice_config.method), .only16);
    // Partition order
    try self.writeBits(4, rice_config.part_order, .only16);

    const part_count = @as(usize, 1) << rice_config.part_order;
    const param_len: u6 = @intCast(@intFromEnum(rice_config.method) + 4);

    // Write Rice codes
    var res = residuals[order..];
    var part_size = (residuals.len >> rice_config.part_order) - order;
    for (rice_config.params[0..part_count]) |param| { // Partition
        // Write rice param
        try self.writeBits(param_len, param & @as(u6, 0x3f) >> (@intCast(6 - param_len)), .only16);

        if (param == rice_code.MAX_PARAM) { // Escaped
            // Calc minimum bits to store the numbers
            var min_digits: u6 = 0;
            for (res[0..part_size]) |r| {
                const least_digits: u6 = (sample_size - @as(u6, @intCast(@clz(@abs(r))))) + 1;
                if (least_digits > min_digits) min_digits = least_digits;
            }
            try self.writeBits(5, min_digits, .only16);
            for (res[0..part_size]) |r| {
                try self.writeBits(min_digits, @as(u32, @bitCast(r)), .only16);
            }
        } else { // Normal
            @branchHint(.likely);
            for (res[0..part_size]) |r| { // Residuals
                const rice: rice_code.RiceCode = .make(param, r);
                try self.writeRice(rice, param);
            }
        }
        res = res[part_size..];
        part_size = residuals.len >> rice_config.part_order;
    }
}

fn calcCrc(self: *@This(), comptime calc_crc: CalcCrc, bytes: []const u8) void {
    if (calc_crc == .both) self.crc8.update(bytes);
    if (calc_crc != .none) self.crc16.update(bytes);
}

// -- Enums --

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
