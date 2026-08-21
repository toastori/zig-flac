const std = @import("std");
const builtin = @import("builtin");

const flac_type = @import("type.zig");
const simd = @import("simd.zig");
const SampleVariant = flac_type.SampleVariant;

// -- CONSTANT --

pub const MAX_ORDER = 4;

const COEFF_SCALAR: [5][4]i32 = .{
    .{ 0, 0, 0, 0 }, // 0th order
    .{ 1, 0, 0, 0 }, // 1st order
    .{ -1, 2, 0, 0 }, // 2nd order
    .{ 1, -3, 3, 0 }, // 3rd order
    .{ -1, 4, -6, 4 }, // 4th order
};

const COEFF_VECTOR: [4]@Vector(4, i64) = .{
    .{ 1, 2, 3, 4 }, // n - 1 coeffss
    .{ 0, -1, -3, -6 }, // n - 2 coeff
    .{ 0, 0, 1, 4 }, // n - 3 coeff
    .{ 0, 0, 0, -1 }, // n - 4 coeff
    // 1  2  3  4  order
};

// -- Functions --

pub fn calcResiduals(
    comptime sv: SampleVariant,
    comptime wide_accumulator: bool,
    samples: []const align(simd.VEC_ALIGN_OF(sv.T())) sv.T(),
    dest: []align(simd.VEC_ALIGN32) i32,
    order: usize,
) void {
    if (sv == .wide and !wide_accumulator) @compileError("non wide accumulator shouldn't compile.");
    std.debug.assert(samples.len == dest.len);

    const Vec = if (wide_accumulator) simd.VecI64 else simd.VecI32;
    const V_LEN = if (wide_accumulator) simd.LEN64 else simd.LEN32;

    const offset_samples: [*]const sv.T() =
        @ptrFromInt(@intFromPtr(samples.ptr) - order * @sizeOf(sv.T()));

    if (order == 0) {
        if (sv == .normal) {
            @memcpy(dest, samples);
        } else {
            for (dest, samples) |*d, s| d.* = @intCast(s);
        }
        return;
    }

    const coeff: [4]Vec = .{
        @splat(COEFF_SCALAR[order][0]),
        @splat(COEFF_SCALAR[order][1]),
        @splat(COEFF_SCALAR[order][2]),
        @splat(COEFF_SCALAR[order][3]),
    };

    var i: usize = 0;
    while (i < samples.len) : (i += V_LEN) {
        const result =
            calcResidualVec(sv, wide_accumulator, samples, offset_samples, i, coeff);

        if (!wide_accumulator) {
            dest[i..].ptr[0..V_LEN].* = result;
        } else {
            const result_32: simd.VecI32 = @bitCast(result);
            const di_result: [2][V_LEN]i32 = @bitCast(std.simd.deinterlace(2, result_32));
            const di_target = if (comptime builtin.cpu.arch.endian() == .little) 0 else 1;
            dest[i..].ptr[0..V_LEN].* = di_result[di_target];
        }
    }
}

/// Check if the residual is in range
inline fn inRange(num: u64) bool {
    return num <= std.math.maxInt(i32);
}

/// Find the best fixed prediction order by looking for smallest residuals sum \
/// return `null` if any residual is out of i32 range
pub fn bestOrder(
    comptime sv: SampleVariant,
    comptime wide_accumulator: bool,
    samples: []const sv.T(),
) ?u8 {
    if (sv == .wide and !wide_accumulator) @compileError("non wide accumulator shouldn't compile.");
    std.debug.assert(samples.len > MAX_ORDER);

    const INVALID_ORDER = std.math.maxInt(u64);

    // u64 is sufficient to store sum of all (65535) abs(i33) number <- i32 sample side channel
    // by the calculation: 33 + log2(65535) = 33 + 15.999 ~= 49
    var total_error: [5]u64 = @splat(0);
    var abs_or_all:  [5]u64 = @splat(0);

    var prev_error: [4] i64 = @splat (0);

    for (0..4) |i| {
        const err0: i64 = samples[i];
        const err1: i64 = if (i < 1) 0 else err0 - prev_error[0];
        const err2: i64 = if (i < 2) 0 else err1 - prev_error[1];
        const err3: i64 = if (i < 3) 0 else err2 - prev_error[2];

        const abs0: u64 = @abs(err0);
        const abs1: u64 = @abs(err1);
        const abs2: u64 = @abs(err2);
        const abs3: u64 = @abs(err3);

        prev_error[0] = err0;
        prev_error[1] = err1;
        prev_error[2] = err2;
        prev_error[3] = err3;

        total_error[0] += @abs(abs0);
        total_error[1] += @abs(abs1);
        total_error[2] += @abs(abs2);
        total_error[3] += @abs(abs3);

        if (wide_accumulator) abs_or_all[0] |= abs0;
        if (wide_accumulator) abs_or_all[1] |= abs1;
        if (wide_accumulator) abs_or_all[2] |= abs2;
        if (wide_accumulator) abs_or_all[3] |= abs3;
    }

    for (4..samples.len) |i| {
        const err0: i64 = samples[i];
        const err1: i64 = err0 - prev_error[0];
        const err2: i64 = err1 - prev_error[1];
        const err3: i64 = err2 - prev_error[2];
        const err4: i64 = err3 - prev_error[3];

        const abs0: u64 = @abs(err0);
        const abs1: u64 = @abs(err1);
        const abs2: u64 = @abs(err2);
        const abs3: u64 = @abs(err3);
        const abs4: u64 = @abs(err4);

        prev_error[0] = err0;
        prev_error[1] = err1;
        prev_error[2] = err2;
        prev_error[3] = err3;

        total_error[0] += @abs(abs0);
        total_error[1] += @abs(abs1);
        total_error[2] += @abs(abs2);
        total_error[3] += @abs(abs3);
        total_error[4] += @abs(abs4);

        if (wide_accumulator) abs_or_all[0] |= abs0;
        if (wide_accumulator) abs_or_all[1] |= abs1;
        if (wide_accumulator) abs_or_all[2] |= abs2;
        if (wide_accumulator) abs_or_all[3] |= abs3;
        if (wide_accumulator) abs_or_all[4] |= abs4;
    }

    inline for (&total_error, abs_or_all) |*err, orall| {
        if (wide_accumulator and !inRange(orall)) err.* = INVALID_ORDER;
    }

    const best_order: u8 = @intCast(std.mem.indexOfMin(u64, &total_error));

    return if (!wide_accumulator or total_error[best_order] != INVALID_ORDER) best_order else null;
}

inline fn calcResidualVec(
    comptime sv: SampleVariant,
    comptime wide_accumulator: bool,
    samples: []const align(simd.VEC_ALIGN_OF(sv.T())) sv.T(),
    offset_samples: [*]const sv.T(),
    idx: usize,
    coeff: [4] if (wide_accumulator) simd.VecI64 else simd.VecI32,
) if (wide_accumulator) simd.VecI64 else simd.VecI32 {
    const Vec = if (wide_accumulator) simd.VecI64 else simd.VecI32;

    const V_LEN = if (Vec == simd.VecI32) simd.LEN32 else simd.LEN64;
    const VecSampT = @Vector(V_LEN, sv.T());

    var curr_samples: Vec = undefined;
    var prev_samples: [4]Vec = @splat(@splat(0));
    var mul_samples: [4]Vec = undefined;
    var sums_temps: [2]Vec = undefined;
    var prediction: Vec = undefined;

    // load previous samples
    for (&prev_samples, idx..) |*p, start|
        p.* = @as(VecSampT, offset_samples[start..][0..V_LEN].*);
    // load samples
    curr_samples = @as(VecSampT, samples.ptr[idx..][0..V_LEN].*);
    // multiply prev samples by coefficient
    for (&mul_samples, prev_samples, coeff) |*m, p, c| m.* = p *% c;
    // sum up to prediction
    sums_temps[0] = mul_samples[0] +% mul_samples[1];
    sums_temps[1] = mul_samples[2] +% mul_samples[3];
    prediction = sums_temps[0] +% sums_temps[1];
    //result
    return curr_samples -% prediction;
}
