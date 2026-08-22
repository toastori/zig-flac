const std = @import("std");

pub const LEN32 = std.simd.suggestVectorLength(i32) orelse 1;
pub const LEN64 = std.simd.suggestVectorLength(i64) orelse 1;

pub const VEC_BYTES32 = LEN32 * @sizeOf(i32);
pub const VEC_BYTES64 = LEN64 * @sizeOf(i64);

pub const VEC_ALIGN32 = VEC_BYTES32;
pub const VEC_ALIGN64 = VEC_BYTES64;

pub const ALIGNMENT32: std.mem.Alignment = .fromByteUnits(VEC_BYTES32);
pub const ALIGNMENT64: std.mem.Alignment = .fromByteUnits(VEC_BYTES64);

pub const VecI32 = @Vector(LEN32, i32);
pub const VecU32 = @Vector(LEN32, u32);
pub const VecI32s = @Vector(LEN64, i32);
pub const VecU32s = @Vector(LEN64, u32);
pub const VecI64 = @Vector(LEN64, i64);
pub const VecU64 = @Vector(LEN64, u64);

pub const rice = struct {
    pub const LEN64R = @min(32, LEN64);
    pub const CHUNK32 = std.math.divCeil(comptime_int, 32, LEN64R) catch unreachable;

    pub const VecI32s = @Vector(LEN64R, i32);
    pub const VecU32s = @Vector(LEN64R, u32);
    pub const VecI64 = @Vector(LEN64R, i64);
    pub const VecU64 = @Vector(LEN64R, u64);

    pub const ONES: rice.VecU64 = @splat(std.math.maxInt(u64));
    pub const PARAMS: [rice.CHUNK32]rice.VecU64 = blk: {
        var iotas: [rice.CHUNK32]rice.VecU64 = @splat(std.simd.iota(u64, rice.LEN64R));
        for (&iotas, 0..) |*iota, i| {
            iota.* += @splat(rice.LEN64R * i);
        }
        break :blk iotas;
    };
    pub const PARAM_P1: [rice.CHUNK32]rice.VecU64 = blk: {
        var iotas: [rice.CHUNK32]rice.VecU64 = @splat(std.simd.iota(u64, rice.LEN64R));
        for (&iotas, 0..) |*iota, i| {
            iota.* += @splat(rice.LEN64R * i + 1);
        }
        break :blk iotas;
    };
};

pub fn VEC_ALIGN_OF(T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .int => |int| switch (int.bits) {
            32 => VEC_ALIGN32,
            64 => VEC_ALIGN64,
            else => @compileError("simd.VEC_ALIGN_OF: expect integer of 32 or 64 bits")
        },
        else => @compileError("simd.VEC_ALIGN_OF: expect integer of 32 or 64 bits"),
    };
}
