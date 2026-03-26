const std = @import("std");

pub const V_LEN_32 = std.simd.suggestVectorLength(i32) orelse 1;
pub const V_LEN_64 = std.simd.suggestVectorLength(i64) orelse 1;

pub const V_ALIGN_32 = V_LEN_32 * @sizeOf(i32);
pub const V_ALIGN_64 = V_LEN_64 * @sizeOf(i64);

pub const ALIGNMENT_32: std.mem.Alignment = .fromByteUnits(V_ALIGN_32);
pub const ALIGNMENT_64: std.mem.Alignment = .fromByteUnits(V_ALIGN_64);

pub const V_BYTE_32 = V_ALIGN_32;
pub const V_BYTE_64 = V_ALIGN_64;

pub const VecI32 = @Vector(V_LEN_32, i32);
pub const VecU32 = @Vector(V_LEN_32, u32);
pub const VecI64 = @Vector(V_LEN_64, i64);
pub const VecU64 = @Vector(V_LEN_64, u64);

pub fn V_ALIGN_OF(T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .int => |int| switch (int.bits) {
            32 => V_ALIGN_32,
            64 => V_ALIGN_64,
            else => @compileError("simd.V_ALIGN_OF: expect integer of 32 or 64 bits")
        },
        else => @compileError("simd.V_ALIGN_OF: expect integer of 32 or 64 bits"),
    };
}
