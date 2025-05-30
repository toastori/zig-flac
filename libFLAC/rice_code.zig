const std = @import("std");
const tracy = @import("tracy");
const sample_iter = @import("sample_iter.zig");
const FixedResidualIter = sample_iter.FixedResidualIter;

const MAX_PARAM_4BIT = (1 << 4) - 2;
const MAX_PARAM_5BIT = (1 << 5) - 2;
pub const MAX_PARAM = MAX_PARAM_5BIT;
const MAX_ORDER = 8; // Subset now
const MAX_PART = 1 << MAX_ORDER;

// -- Structs --

/// Bits are directly writable by FrameWriter
pub const RiceCode = struct {
    /// Quotient of result
    quo: u32,
    /// 1 ++ remainder of result
    rem: u32,

    pub fn make(param: u6, value: i64) @This() {
        const zigzag: u64 = calcZigzag(value);
        return .{
            .quo = @intCast(zigzag >> param),
            .rem = @intCast(zigzag & ((@as(u64, 1) << param) - 1)),
        };
    }
};

pub const RiceConfig = struct {
    method: enum(u8) { FOUR = 0, FIVE = 1 } = .FOUR,
    part_order: u6 = undefined,
    params: [MAX_PART]u6 = undefined,
};

// -- Functions --

pub fn calcRiceParamFixed(
    residuals: []i32,
    min_part_order: u8,
    max_part_order: u8,
    pred_order: u8,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    const pred_order_limited: u6 = if (pred_order != 0)
        // log2(a / b)
        @intCast(std.math.log2_int(usize, residuals.len) - std.math.log2_int(usize, pred_order))
    else
        std.math.maxInt(u6);

    const max: u6 = @intCast(@min(max_part_order, @ctz(residuals.len), pred_order_limited));
    const min: u6 = @intCast(@min(min_part_order, max));
    return calcRiceParam(residuals, min, max, pred_order);
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcRiceParam(
    residuals: []i32,
    min_part: u6,
    max_part: u6,
    pred_order: u8,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "rice_code.calcRiceParam" });
    defer tracy_zone.end();

    var sums: [MAX_ORDER + 1][MAX_PART]u64 = undefined;
    var optimal_bit_count: usize = std.math.maxInt(usize);
    var optimal_part_order = min_part;
    var optimal_config: RiceConfig = undefined;

    calcSums(residuals, min_part, max_part, pred_order, &sums);

    for (min_part..max_part + 1) |part_order| {
        const bit_count, const config = calcOptimalParams(
            @intCast(part_order),
            residuals.len,
            pred_order,
            &sums[part_order],
        );
        if (bit_count <= optimal_bit_count) {
            optimal_part_order = @intCast(part_order);
            optimal_bit_count = bit_count;
            optimal_config = config;
        }
    }

    return .{ optimal_bit_count, optimal_config };
}

fn calcZigzag(value: i64) u64 {
    return @bitCast((value * 2) ^ (value >> 63));
}

// Copied from flake
fn partEncodeCount(sum: u64, part_size: usize, param: u6) usize {
    return part_size * (param + 1) + ((sum - part_size / 2) >> param);
}

// Copied from flake
/// Calculate "sum of zigzag" for each partition of each partition size \
/// Of course smallest sum of zigzag compressed the best by rice code
fn calcSums(
    residuals: []i32,
    min_part: u6,
    max_part: u6,
    pred_order: u8,
    sums: *[MAX_ORDER + 1][MAX_PART]u64,
) void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "rice_code.calcSums" });
    defer tracy_zone.end();

    std.debug.assert(sums.len > max_part);
    // Sum for highest level
    var res = residuals[pred_order..];
    var part_size: usize = (residuals.len >> max_part) - pred_order;
    for (sums[max_part][0..(@as(usize, 1) << max_part)]) |*sum| {
        sum.* = 0;
        for (0..part_size) |j| {
            sum.* += calcZigzag(res[j]);
        }
        res = res[part_size..];
        part_size = residuals.len >> max_part;
    }
    // Sum for lower levels
    // Contineously summing next 2 of previous partition size
    var i = max_part - 1;
    while (i >= min_part and i < max_part) : (i -%= 1) {
        for (0..(@as(usize, 1) << i)) |j| {
            sums[i][j] = sums[i + 1][j * 2] + sums[i + 1][j * 2 + 1];
        }
    }
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcOptimalParams(
    part_order: u6,
    blk_size: usize,
    pred_order: u8,
    sums: *[MAX_PART]u64,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "rice_code.calcOptimalParams" });
    tracy_zone.value(part_order);
    defer tracy_zone.end();

    const part_count: usize = @as(usize, 1) << part_order;
    var all_bits: usize = 0;
    var config: RiceConfig = .{};

    var part_size: usize = (blk_size >> part_order) - pred_order;
    for (0..part_count) |i| {
        // Tracy
        const tracy_zone_part = tracy.beginZone(@src(), .{ .name = "rice_code.findOptimalParam" });
        tracy_zone_part.value(i);
        defer tracy_zone_part.end();

        const optimal_param, const optimal_bit_count =
            findOptimalParam(sums[i], part_size);
        config.params[i] = optimal_param;
        all_bits += optimal_bit_count;

        if (optimal_param >= MAX_PARAM_4BIT and optimal_param != MAX_PARAM)
            config.method = .FIVE;

        part_size = blk_size >> part_order;
    }
    config.part_order = part_order;

    return .{ all_bits + 4 * part_count, config };
}

// Copied from flake
/// return `.{ optimal_param, optimal_bit_count }`
fn findOptimalParam(part_sum: u64, part_size: usize) std.meta.Tuple(&.{ u6, usize }) {
    var optimal_param: u8 = undefined;
    var optimal_bit_count: usize = std.math.maxInt(usize);

    for (0..MAX_PARAM + 1) |param| {
        const bit_count = partEncodeCount(part_sum, part_size, @intCast(param));
        if (bit_count < optimal_bit_count) {
            optimal_bit_count = bit_count;
            optimal_param = @intCast(param);
        }
    }
    return .{ @intCast(optimal_param), optimal_bit_count };
}
