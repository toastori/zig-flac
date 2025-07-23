const std = @import("std");
const tracy = @import("tracy");
const sample_iter = @import("samples.zig");

const SampleIter = sample_iter.SampleIter;
const MultiOrderFixedResidualIter = sample_iter.MultiOrderFixedResidualIter;

// -- CONSTANT --

pub const MAX_ORDER = 4;

pub const COEFFICIENTS = [_]@Vector(4, i64){
    .{ 0, 0, 0, 0 }, // 0th order
    .{ 1, 0, 0, 0 }, // 1st order
    .{ 2, -1, 0, 0 }, // 2nd order
    .{ 3, -3, 1, 0 }, // 3rd order
    .{ 4, -6, 4, -1 }, // 4th order
};

// -- Functions --

/// Calculate prediction residuals
pub fn calcResidual(sample: i64, prev_samples: @Vector(4, i64), order: usize) i64 {
    const prediction: i64 = @reduce(.Add, prev_samples * COEFFICIENTS[order]);
    return sample - prediction;
}

/// Check if the residual is in range
pub inline fn inRange(num: i64) bool {
    return num <= std.math.maxInt(i32) or num > std.math.minInt(i32);
}

/// Find the best fixed prediction order by looking for smallest residuals sum
pub fn bestOrder(
    SampleT: type,
    samples: []const SampleT,
    comptime check_range: bool,
) ?u8 {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "fixed_prediction.bestOrder" });
    defer tracy_zone.end();

    // u64 is sufficient to store sum of all (65535) abs(i33) number <- i32 sample side channel
    // by the calculation: 33 + log2(65535) = 33 + 15.999 ~= 49
    var iter, const tmp_total_error = MultiOrderFixedResidualIter(SampleT).init(samples, check_range);
    var total_error = tmp_total_error ++ [_]u64{0};

    while (iter.next(check_range)) |residuals| {
        for (residuals, &total_error) |res, *err| {
            if (!check_range or inRange(res.?))
                err.* += @abs(res.?)
            // u49 is used because its the value never be reached
            // when all values are in range
            else err.* = std.math.maxInt(u49);
        }
    }

    const best_order: u8 = @intCast(std.mem.indexOfMin(u64, &total_error));

    return if (!check_range and total_error[best_order] < std.math.maxInt(u49)) best_order else null;
}
