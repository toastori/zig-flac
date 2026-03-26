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
    SideT: type,
    block_size: u16,
    left: [*]const i32,
    right: [*]const i32,
    mid_dest: []i32,
    side_dest: []SideT,
) void {
    for (left[0..block_size], right[0..block_size], mid_dest, side_dest) |l, r, *m, *s| {
        m.* = midSample(SideT, l, r);
        s.* = sideSample(SideT, l, r);
    }
}
/// Produce a slice of mid_channel \
/// \
/// return:
/// - `.{ mid }`
pub fn midChannel(block_size: u16, left: [*]const i32, right: [*]const i32, dest: []i32) []const i32 {
    std.debug.assert(left.len == right.len and right.len == dest.len);
    for (left[0..block_size], right[0..block_size], dest) |l, r, *d|
        d.* = midSample(l, r);
    return dest;
}

/// Produce a slice of side_channel \
/// \
/// return:
/// - `.{ side }`
pub fn sideChannel(SampleT: type, block_size: u16, left: [*]const i32, right: [*]const i32, dest: []SampleT) []const SampleT {
    for (left[0..block_size], right[0..block_size], dest) |l, r, *d|
        d.* = sideSample(SampleT, l, r);
    return dest;
}

/// Calculate a mid sample
inline fn midSample(SampleT: type, left: SampleT, right: SampleT) i32 {
    return @intCast((left + right) >> 1);
}

/// Calculate a side sample
inline fn sideSample(SampleT: type, left: SampleT, right: SampleT) SampleT {
    return left - right;
}
