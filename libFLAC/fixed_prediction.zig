const std = @import("std");
const builtin = @import("builtin");
const sample_iter = @import("samples.zig");

const SampleIter = sample_iter.SampleIter;
const MultiOrderFixedResidualIter = sample_iter.MultiOrderFixedResidualIter;

// -- CONSTANT --

pub const MAX_ORDER = 4;

pub const NEO_COEFF: [5][4]i32 = .{
    .{ 0, 0, 0, 0 }, // 0th order
    .{ 1, 0, 0, 0 }, // 1st order
    .{ -1, 2, 0, 0 }, // 2nd order
    .{ 1, -3, 3, 0 }, // 3rd order
    .{ -1, 4, -6, 4 }, // 4th order
};

// -- Functions --

/// Calculate the n-th residual
pub fn calcResidual(T: type, R: type, samples: []const T, n: usize, order: usize) R {
    if (T != i32 and T != i64) @compileError("calcResidual: expect T as i32 or i64");
    if (R != i32 and R != i64) @compileError("calcResidual: expect R as i32 or i64");
    std.debug.assert(n >= order);
    var prediction: T = 0;
    for (0..order, n - order..) |o, i| {
        prediction += samples[i] * NEO_COEFF[order][o];
    }
    return @intCast(samples[n] - prediction);
}

pub fn calcResiduals(SampleT: type, samples: []const SampleT, dest: []i32, order: usize) void {
    if (SampleT != i32 and SampleT != i64) @compileError("calcResiduals: expect T as i32 or i64");
    std.debug.assert(samples.len == dest.len);
    const mm_len = std.simd.suggestVectorLength(SampleT) orelse 1;
    const Vec = @Vector(mm_len, SampleT);

    const coeff: [4]Vec = .{
        @splat(NEO_COEFF[order][0]),
        @splat(NEO_COEFF[order][1]),
        @splat(NEO_COEFF[order][2]),
        @splat(NEO_COEFF[order][3]),
    };
    var curr_samples: Vec = undefined;
    var prev_samples: [4]Vec = @splat(@splat(0));
    var mul_samples: [4]Vec = undefined;
    var sums_temps: [2]Vec = undefined;
    var prediction: Vec = undefined;

    for (0..order) |o| dest[o] = @intCast(samples[o]);

    var i = order;
    while (i < samples.len) : (i += mm_len) {
        for (&prev_samples, i - order..) |*p, s| p.* = samples.ptr[s..][0..mm_len].*; // load prev samples
        curr_samples = samples.ptr[i..][0..mm_len].*; // load samples

        for (&mul_samples, prev_samples, coeff) |*m, p, c| m.* = p *% c; // multiply prev samples by coefficient
        // sum up to prediction
        sums_temps[0] = mul_samples[0] +% mul_samples[1];
        sums_temps[1] = mul_samples[2] +% mul_samples[3];
        prediction = sums_temps[0] +% sums_temps[1];
        //result
        const result = curr_samples -% prediction;

        if (SampleT == i32) {
            if (mm_len == 1 or samples.len - i > mm_len) {
                dest[i..][0..mm_len].* = result;
            } else {
                const array_form: [mm_len]SampleT = @bitCast(result);
                @memcpy(dest[i..][0..samples.len - i], array_form[0..samples.len - i]);
            }
        } else {
            const mm_len_32 = std.simd.suggestVectorLength(i32) orelse 1;
            const result_32: @Vector(mm_len_32, i32) = @bitCast(result);
            const di_result: [2][mm_len]i32 = @bitCast(std.simd.deinterlace(2, result_32));
            const di_target = if (comptime builtin.cpu.arch.endian() == .little) 0 else 1;
            if (mm_len == 1 or samples.len - i > mm_len) {
                dest[i..][0..mm_len].* = di_result[di_target];
            } else {
                @memcpy(dest[i..][0..samples.len - i], di_result[di_target][0..samples.len - i]);
            }
        }
    }
}

/// Check if the residual is in range
pub inline fn inRange(num: i64) bool {
    return num <= std.math.maxInt(i32) or num > std.math.minInt(i32);
}

/// Find the best fixed prediction order by looking for smallest residuals sum \
/// return `null` if any residual is out of i32 range
pub fn bestOrder(
    SampleT: type,
    samples: []const SampleT,
    sample_size: usize,
    comptime check_range: bool,
) ?u8 {
    // u64 is sufficient to store sum of all (65535) abs(i33) number <- i32 sample side channel
    // by the calculation: 33 + log2(65535) = 33 + 15.999 ~= 49

    var total_error: [5]u64 = .{ 0, sample_size, sample_size * 2, sample_size * 3, sample_size * 4 };
    for (0..5) |order| {
        var i: usize = order;
        while (i < samples.len) : (i += 1) {
            const res = calcResidual(SampleT, i64, samples, i, order);
            if (!check_range or inRange(res)) total_error[order] += @abs(res)
            else total_error[order] = std.math.maxInt(u49);
        }
    }

    const best_order: u8 = @intCast(std.mem.indexOfMin(u64, &total_error));

    return if (!check_range and total_error[best_order] < std.math.maxInt(u49)) best_order else null;
}
