const std = @import("std");
const builtin = @import("builtin");

const mm_len_32 = std.simd.suggestVectorLength(i32) orelse 1;
const mm_len_64 = std.simd.suggestVectorLength(i64) orelse 1;
const VecNormal = @Vector(mm_len_32, i32);
const VecWide = @Vector(mm_len_64, i64);

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

pub fn calcResiduals(SampleT: type, comptime wide: Wide, samples: []const SampleT, dest: []i32, order: usize) void {
    if (SampleT != i32 and SampleT != i64) @compileError("calcResiduals: expect T as i32 or i64");
    if (SampleT == i64 and wide == .normal) @compileError("calcResiduals: expect wide == .wide for SampleT == i64");
    std.debug.assert(samples.len == dest.len);

    const Vec = if (wide == .wide) VecWide else VecNormal;
    const mm_len = @typeInfo(Vec).vector.len;

    if (order == 0) {
        if (SampleT == i32) {
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

    var i = order;
    while (i + mm_len < samples.len) : (i += mm_len) {
        const result =
            calcResidualVec(SampleT, Vec, samples, i, order, coeff);

        if (wide == .normal) {
            dest[i..][0..mm_len].* = result;
        } else {
            const result_32: VecNormal = @bitCast(result);
            const di_result: [2][mm_len]i32 = @bitCast(std.simd.deinterlace(2, result_32));
            const di_target = if (comptime builtin.cpu.arch.endian() == .little) 0 else 1;
            dest[i..][0..mm_len].* = di_result[di_target];
        }
    }
    while (i < samples.len) : (i += 1) {
        dest[i] = @intCast(calcResidual(SampleT, if (wide == .wide) i64 else i32, samples, i, order));
    }
}

/// Check if the residual is in range
inline fn inRange(num: u64) bool {
    return num <= std.math.maxInt(i32);
}

inline fn inRangeVec(nums: @Vector(4, u64)) @Vector(4, u64) {
    const limit: @Vector(4, u64) = @splat(std.math.maxInt(i32));
    return nums <= limit;
}

/// Find the best fixed prediction order by looking for smallest residuals sum \
/// return `null` if any residual is out of i32 range
pub fn bestOrder(
    SampleT: type,
    comptime wide: Wide,
    samples: []const SampleT,
) ?u8 {
    if (SampleT == i64 and wide != .wide) @compileError("fixed_prediction.bestOrder: unexpected SampleT == i64 with wide != .wide");
    std.debug.assert(samples.len > MAX_ORDER);

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

        if (wide == .wide) abs_or_all[0] |= abs0;
        if (wide == .wide) abs_or_all[1] |= abs1;
        if (wide == .wide) abs_or_all[2] |= abs2;
        if (wide == .wide) abs_or_all[3] |= abs3;
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

        if (wide == .wide) abs_or_all[0] |= abs0;
        if (wide == .wide) abs_or_all[1] |= abs1;
        if (wide == .wide) abs_or_all[2] |= abs2;
        if (wide == .wide) abs_or_all[3] |= abs3;
        if (wide == .wide) abs_or_all[4] |= abs4;
    }

    inline for (&total_error, abs_or_all) |*err, orall| {
        if (wide == .wide and !inRange(orall)) err.* = std.math.maxInt(u64);
    }

    const best_order: u8 = @intCast(std.mem.indexOfMin(u64, &total_error));

    return if (wide == .normal or total_error[best_order] != std.math.maxInt(u64)) best_order else null;
}

/// Calculate the n-th residual
pub fn calcResidual(T: type, R: type, samples: []const T, n: usize, order: usize) R {
    if (T != i32 and T != i64) @compileError("calcResidual: expect T as i32 or i64");
    if (R != i32 and R != i64) @compileError("calcResidual: expect R as i32 or i64");
    std.debug.assert(n >= order);
    var prediction: R = 0;
    for (0..order, n - order..) |o, i| {
        prediction += @as(R, samples[i]) * @as(R, COEFF_SCALAR[order][o]);
    }
    return @intCast(@as(R, samples[n]) - prediction);
}

inline fn calcResidualVec(
    SampleT: type,
    Vec: type,
    samples: []const SampleT,
    idx: usize,
    order: usize,
    coeff: [4]Vec,
) Vec {
    if (SampleT != i32 and SampleT != i64) @compileError("calcResidualVec: expect SampleT == i32 or i64");
    if (Vec != VecNormal and Vec != VecWide) @compileError("calcResidualVec: expect Vec == VecWide or VecNormal");

    const mm_len = @typeInfo(Vec).vector.len;
    const VecSampT = @Vector(mm_len, SampleT);

    var curr_samples: Vec = undefined;
    var prev_samples: [4]Vec = @splat(@splat(0));
    var mul_samples: [4]Vec = undefined;
    var sums_temps: [2]Vec = undefined;
    var prediction: Vec = undefined;

    // load previous samples
    for (&prev_samples, idx - order..) |*p, start|
        p.* = @as(VecSampT, samples.ptr[start..][0..mm_len].*);
    // load samples
    curr_samples = @as(VecSampT, samples.ptr[idx..][0..mm_len].*);

    for (&mul_samples, prev_samples, coeff) |*m, p, c| m.* = p * c; // multiply prev samples by coefficient
    // sum up to prediction
    sums_temps[0] = mul_samples[0] + mul_samples[1];
    sums_temps[1] = mul_samples[2] + mul_samples[3];
    prediction = sums_temps[0] + sums_temps[1];
    //result
    return curr_samples - prediction;
}

// -- Enums --
pub const Wide = enum { wide, normal };
