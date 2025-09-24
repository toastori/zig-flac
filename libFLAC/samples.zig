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

    for (samples[0..order], dest[0..order]) |s, *d|
        d.* = @intCast(s);
    for (dest[order..], order..) |*d, i|
        d.* = fp.calcResidual(SampleT, i32, samples, i, order);
}
