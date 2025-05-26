const std = @import("std");
const sample_iter = @import("sample_iter.zig");

const SampleIter = sample_iter.SampleIter;

// -- CONSTANT --

pub const COEFFICIENTS = [_]@Vector(4, i64){
    .{ 0, 0, 0, 0 }, // 0th order
    .{ 1, 0, 0, 0 }, // 1st order
    .{ 2, -1, 0, 0 }, // 2nd order
    .{ 3, -3, 1, 0 }, // 3rd order
    .{ 4, -6, 4, -1 }, // 4th order
};

// -- Functions --

pub fn calcResidual(sample: i64, prev_samples: @Vector(4, i64), order: usize) i64 {
    const prediction: i64 = @reduce(.Add, prev_samples * COEFFICIENTS[order]);
    return sample - prediction;
}

/// Remember to free the residuals slice
pub const OrderAndResiduals = struct {
    order: u8,
    residuals: []i32,
};

/// Find the best fixed prediction order by looking for smallest residuals sum
pub fn bestOrder(
    SampleT: type,
    allocator: std.mem.Allocator,
    samples: SampleIter(SampleT),
    min_order: u8,
    max_order: u8,
) !?OrderAndResiduals {
    var tmp_slice = try allocator.alloc(i32, samples.len);
    defer allocator.free(tmp_slice);
    var best_slice = try allocator.alloc(i32, samples.len);

    var best_order: u8 = 0;
    // u64 is sufficient to store sum of all (65535) abs(i33) number <- i32 sample side channel
    // by the calculation: 33 + log2(65535) = 33 + 15.999 ~= 49
    var best_sum: u64 = std.math.maxInt(u64);
    for (min_order..max_order) |order| {
        var sum: u64 = 0;

        samples.reset();
        var res_iter = samples.fixedResidualIter(@intCast(order)) orelse break;
        // Write to slice and add to sum for each residuals
        var idx: usize = order;
        while (res_iter.next() catch continue) |res| : (idx += 1) {
            sum += @abs(res);
            tmp_slice[idx] = res;
        }
        // If this is a better order
        if (sum < best_sum) {
            // Replace best record
            best_order = @intCast(order);
            best_sum = sum;
            // Swap best slice
            const tmp = best_slice;
            best_slice = tmp_slice;
            tmp_slice = tmp;
        }
    }
    if (best_sum == std.math.maxInt(u64)) {
        allocator.free(best_slice);
        return null;
    }
    samples.reset();
    for (0..best_order) |i| {
        best_slice[i] = samples.next().?;
    }
    return .{ .order = best_order, .residuals = best_slice };
}
