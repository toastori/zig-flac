const std = @import("std");
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
    if (T != i32 and T != i64) @compileError("neoCalcResidual: expect T as i32 or i64");
    if (R != i32 and R != i64) @compileError("neoCalcResidual: expect R as i32 or i64");
    std.debug.assert(n >= order);
    var prediction: T = 0;
    for (0..order, n - order..) |o, i| {
        prediction += samples[i] * NEO_COEFF[order][o];
    }
    return @intCast(samples[n] - prediction);
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
    comptime check_range: bool,
) ?u8 {
    // u64 is sufficient to store sum of all (65535) abs(i33) number <- i32 sample side channel
    // by the calculation: 33 + log2(65535) = 33 + 15.999 ~= 49

    var total_error: [5]u64 = @splat(0);
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
