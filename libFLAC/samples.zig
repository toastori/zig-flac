const std = @import("std");
const builtin = @import("builtin");
const mode = @import("builtin").mode;

const LEN_PER_CHANNEL = std.math.maxInt(u16);
const SIZE_PER_CHANNEL = LEN_PER_CHANNEL + 1;

/// Produce slices of mid_channel and side_channel \
/// \
/// return:
/// - `.{ mid, side }`
pub fn midSideChannels(
    SampleT: type,
    left: []const i32,
    right: []const i32,
    mid_dest: []i32,
    side_dest: []SampleT,
) std.meta.Tuple(&.{[]const i32, []const SampleT}) {
    std.debug.assert(left.len == right.len and right.len == mid_dest.len and mid_dest.len == side_dest.len);
    for (left, right, mid_dest, side_dest) |l, r, *m, *s| {
        m.* = midSample(l, r);
        s.* = sideSample(SampleT, l, r);
    }
    return .{mid_dest, side_dest};
}
/// Produce a slice of mid_channel \
/// \
/// return:
/// - `.{ mid }`
pub fn midChannel(left: []const i32, right: []const i32, dest: []i32) []const i32 {
    std.debug.assert(left.len == right.len and right.len == dest.len);
    for (left, right, dest) |l, r, *d|
        d.* = midSample(l, r);
    return dest;
}

/// Produce a slice of side_channel \
/// \
/// return:
/// - `.{ side }`
pub fn sideChannel(SampleT: type, left: []const i32, right: []const i32, dest: []SampleT) []const SampleT {
    std.debug.assert(left.len == right.len and right.len == dest.len);
    for (left, right, dest) |l, r, *d|
        d.* = sideSample(SampleT, l, r);
    return dest;
}

/// Calculate a mid sample
inline fn midSample(left: i32, right: i32) i32 {
    return (left + right) >> 1;
}

/// Calculate a side sample
inline fn sideSample(SampleT: type, left: i32, right: i32) SampleT {
    return left - right;
}

/// Produce a slice of fixed prediction residuals
pub fn fixedResiduals(SampleT: type, order: u8, samples: []const SampleT, dest: []i32) void {
    const fp = @import("fixed_prediction.zig");
    if (SampleT != i32 and SampleT != i64) @compileError("fixedResiduals: expect SampleT as i32 or i64");
    std.debug.assert(samples.len == dest.len);

    var prev: @Vector(4, i64) = undefined;
    for (1..order + 1, samples[0..order], dest[0..order]) |i, s, *d| {
        prev[order - i] = s;
        d.* = @intCast(s);
    }
    for (samples[order..], dest[order..]) |s, *d| {
        d.* = @intCast(fp.calcResidual(s, prev, order));
        prev =
            std.simd.shiftElementsRight(prev, 1, s);
    }
}

/// Calculate order [0,4] all at once
pub fn MultiOrderFixedResidualIter(SampleT: type) type {
    std.debug.assert(SampleT == i32 or SampleT == i64);
    return struct {
        samples: []const SampleT,

        prev_samples: @Vector(4, i64),

        const fp = @import("fixed_prediction.zig");

        /// Return an iterator and total_error for each order up to first 4 samples
        /// result `total_error` over maxInt(u49) means out of range,
        /// since the value will never be reached with all values in range
        pub fn init(samples: []const SampleT, comptime check_range: bool) std.meta.Tuple(&.{ @This(), [fp.MAX_ORDER]u64 }) {
            std.debug.assert(samples.len >= fp.MAX_ORDER);

            var result: [fp.MAX_ORDER]u64 = @splat(0);
            var result_iter: @This() = .{ .samples = samples[fp.MAX_ORDER..], .prev_samples = undefined };

            if (!check_range) {
                for (samples[0..fp.MAX_ORDER], 0..) |sample, iteration| {
                    result[0] += @abs(sample);
                    for (1..iteration + 1) |order|
                        result[order] += @abs(fp.calcResidual(sample, result_iter.prev_samples, order));
                    result_iter.prev_samples =
                        std.simd.shiftElementsRight(result_iter.prev_samples, 1, sample);
                }
            } else {
                for (samples[0..fp.MAX_ORDER], 0..) |sample, iteration| {
                    if (fp.inRange(sample))
                        result[0] += @abs(sample)
                    else
                        result[0] = std.math.maxInt(u49);

                    for (1..iteration + 1) |order| {
                        const residual = fp.calcResidual(sample, result_iter.prev_samples, order);
                        if (fp.inRange(residual))
                            result[order] += @abs(residual)
                        else
                            result[order] = std.math.maxInt(u49);
                    }
                    result_iter.prev_samples =
                        std.simd.shiftElementsRight(result_iter.prev_samples, 1, sample);
                }
            }

            return .{ result_iter, result };
        }

        /// Get all 5 orders' residuals for next sample
        pub fn next(self: *@This(), comptime check_range: bool) ?[5]?i32 {
            if (self.samples.len == 0) return null;
            const sample = self.samples[0];
            self.samples = self.samples[1..];
            var result: [5]?i32 = undefined;
            if (comptime !check_range) {
                result[0] = @intCast(sample);
                for (1..fp.MAX_ORDER + 1) |order|
                    result[order] = @intCast(fp.calcResidual(sample, self.prev_samples, order));
                self.prev_samples =
                    std.simd.shiftElementsRight(self.prev_samples, 1, sample);
            } else {
                if (result[0]) |_|
                    result[0] = if (fp.inRange(sample)) null else @as(i32, @intCast(sample));

                for (1..fp.MAX_ORDER + 1) |order| {
                    const residual = fp.calcResidual(sample, self.prev_samples, order);
                    if (result[order]) |_|
                        result[order] = if (fp.inRange(residual)) null else @intCast(residual);
                }
            }
            return result;
        }
    };
}