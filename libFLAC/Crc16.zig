/// Crc16 implementation using intel's
/// "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ Instruction"

const std = @import("std");
const builtin = @import("builtin");

const Crc = @This();

// -- Members --

crc: u16 = 0,

// -- Methods --

pub fn update(self: *Crc, data: []u8) void {
    if ((comptime !do_simd) or data.len < 64) {
        var table_crc: std.hash.crc.Crc16Umts = .{ .crc = self.crc };
        table_crc.update(data);
        self.crc = table_crc.final();
        return;
    }

    var blocks = data.len / 16;
    var i: usize = 0;

    // Load and byte-swap the first 16 bytes
    var acc = byteSwap(data[0..16].*);

    // XOR initial CRC into high 16 buts of high 64-bit lane
    // For non-reflected CRC, the CRC value is conceptually at the MSB end
    const wide_crc: u64 = @as(u64, self.crc) << 48;
    const crc_vec: Vec64 = loadVec64(wide_crc, 0);
    acc ^= @bitCast(crc_vec);

    i += 16;
    blocks -= 1;

    while (blocks > 0) : ({blocks -= 1; i += 16;}) {
        // Load the next 16 bytes
        const block: Vec = byteSwap(data[i..][0..16].*);
        // Fold Accumulator with new data
        acc = fold(acc, block);
    }

    // Store folded result (byte-swap back to original order
    const acc_swapped: Vec = byteSwap(acc);

    var final_buf: [32]u8 = undefined;
    final_buf[0..16].* = acc_swapped;

    const remaining = data.len - i;
    if (remaining != 0) @memcpy(final_buf[16..], data[i..]);

    var table_crc: std.hash.crc.Crc16Umts = .{ .crc = 0 };
    table_crc.update(final_buf[0..16 + remaining]);
    self.crc = table_crc.final();
}

fn loadVec64(hi: u64, lo: u64) Vec64 {
    return switch (builtin.cpu.arch.endian()) {
        .big => .{hi, lo},
        .little => .{lo, hi},
    };
}

fn byteSwap(mm: Vec) Vec {
    const mask: @Vector(16, u8) =
        .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    return @shuffle(u8, mm, undefined, mask);
}

fn fold(acc: Vec, data: Vec) Vec {
    const acc64: Vec64 = @bitCast(acc);
    const t1 = clmul(acc64, K, 0x11);
    const t2 = clmul(acc64, K, 0x00);
    return @as(Vec, @bitCast(t1 ^ t2)) ^ data;
}

fn clmul(a: Vec64, b: Vec64, comptime imm: u8) Vec64 {
    const cpu_family = builtin.cpu.arch.family();
    return switch (cpu_family) {
        .x86 => @"llvm.x86.pclmulqdq"(a, b, imm),
        .arm, .aarch64 => blk: {
            const endian = comptime builtin.cpu.arch.endian();
            const hi_qw = if (endian == .little) 1 else 0;
            const lo_qw = if (endian == .little) 0 else 1;
            const aq = if (imm & 0x10 != 0) a[hi_qw] else a[lo_qw];
            const bq = if (imm & 0x01 != 0) b[hi_qw] else b[lo_qw];
            break :blk @bitCast(@"llvm.aarch64.neon.pmull64"(aq, bq));
        },
        else => unreachable,
    };
}

extern fn @"llvm.x86.pclmulqdq"(a: Vec64, b: Vec64, imm: u8) Vec64;
extern fn @"llvm.aarch64.neon.pmull64"(a: u64, b: u64) Vec;

// -- Constants --

// Simd
const do_simd = std.simd.suggestVectorLength(u8) != null and builtin.mode != .Debug;
const Vec = @Vector(16, u8);
const Vec64 = @Vector(2, u64);

// Barrett reduction constants
const POLY = 0x18005;
const MU = calcMu();

// 128-bit blocks folding constants
const K: Vec64 = loadVec64(calcConst(128 + 64), calcConst(128));


fn calcConst(x: comptime_int) comptime_int {
    var c = 1;
    for (0..x) |_| {
        c <<= 1;
        if ((c & (1 << 16)) != 0)
            c ^= POLY;
    }
    return c & 0xffff;
}

fn calcMu() comptime_int {
    var mu = 0;
    var dividend = 1;
    for (0..32) |_| {
        dividend <<= 1;
        mu <<= 1;
        if (dividend >= POLY) {
            dividend -= POLY;
            mu |= 1;
        }
    }
    return mu;
}

