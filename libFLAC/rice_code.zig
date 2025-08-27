const std = @import("std");
const sample_iter = @import("samples.zig");
const FixedResidualIter = sample_iter.FixedResidualIter;

const MAX_PARAM_4BIT: u6 = std.math.maxInt(u4) - 1;
const MAX_PARAM_5BIT: u6 = std.math.maxInt(u5) - 1;
pub const MAX_PARAM = MAX_PARAM_5BIT;
pub const ESC_PART = std.math.maxInt(u5);
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
    method: enum(u6) { FOUR = 0, FIVE = 1 } = .FOUR,
    part_order: u6 = undefined,
    params: [MAX_PART]u6 = undefined,
};

// -- Functions --

pub fn calcRiceParamFixed(
    residuals: []i32,
    max_order: u8,
    max_param: u8,
    bit_depth: u8,
    pred_order: u8,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    std.debug.assert(residuals.len > pred_order);
    const pred_order_limited: usize = if (pred_order != 0)
        // log2(a / b)
        std.math.log2_int(usize, residuals.len) - std.math.log2_int(usize, pred_order)
    else
        std.math.maxInt(u6);

    const max: u6 = @intCast(@min(max_order, @ctz(residuals.len), pred_order_limited));
    const maximum_param: u6 = @intCast(@min(if (bit_depth > 16) MAX_PARAM_5BIT else MAX_PARAM_4BIT, max_param));

    return calcRiceParam(residuals, max, maximum_param, pred_order);
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcRiceParam(
    residuals: []i32,
    max_part: u6,
    max_param: u6,
    pred_order: u8,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    var sums: [MAX_ORDER + 1][MAX_PART]u64 = undefined;
    var optimal_bit_count: usize = std.math.maxInt(usize);
    var optimal_part_order: u6 = undefined;
    var optimal_config: RiceConfig = undefined;

    calcSums(residuals, max_part, pred_order, &sums);

    for (0..max_part + 1) |part_order| {
        const bit_count, const config = calcOptimalParams(
            @intCast(part_order),
            residuals.len,
            max_param,
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

inline fn calcZigzag(value: i64) u64 {
    return @bitCast(if (value < 0) value * -2 - 1 else value * 2);
}

// Copied from flake
/// Calculate "sum of zigzag" for each partition of each partition size \
/// Of course smallest sum of zigzag compressed the best by rice code
fn calcSums(
    residuals: []i32,
    max_part: u6,
    pred_order: u8,
    sums: *[MAX_ORDER + 1][MAX_PART]u64,
) void {
    std.debug.assert(sums.len > max_part);
    std.debug.assert(pred_order <= 4);

    // Sum for highest level
    var res = residuals;
    const part_size: usize = residuals.len >> max_part;
    @prefetch(residuals, .{ .locality = 3 });
    for (sums[max_part][0..(@as(usize, 1) << max_part)], 0..) |*sum, part| {
        sum.* = 0;
        for (res[part * part_size..][0..part_size]) |r|
            sum.* += calcZigzag(r);
    }
    for (0..pred_order) |i| {
        sums[max_part][0] -= calcZigzag(residuals[i]);
    }
    // Sum for lower levels
    // Continuously summing next 2 of previous partition size
    var i = max_part -% 1;
    while (true) : (i -= 1) {
        for (0..@as(usize, 1) << i) |j| {
            sums[i][j] = sums[i + 1][j * 2] + sums[i + 1][j * 2 + 1];
        }
        if (i == 0) break;
    }
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcOptimalParams(
    part_order: u6,
    blk_size: usize,
    max_param: u6,
    pred_order: u8,
    sums: *const [MAX_PART]u64,
) std.meta.Tuple(&.{ usize, RiceConfig }) {
    std.debug.assert(pred_order <= 4);

    const part_count: usize = @as(usize, 1) << part_order;
    var all_bits: usize = 0;
    var config: RiceConfig = .{.part_order = part_order};

    var part_size: usize = (blk_size >> part_order) - pred_order;
    for (0..part_count) |i| {
        const optimal_param, const optimal_bit_count =
            findOptimalParamSearch(sums[i], part_size, max_param);
        config.params[i] = optimal_param;
        all_bits += optimal_bit_count;

        part_size = blk_size >> part_order;
    }
    // Decide to extend rice method
    if (max_param > MAX_PARAM_4BIT) {
        for (config.params[0..part_count]) |param| {
            if (param <= MAX_PARAM_4BIT) continue;
            config.method = .FIVE;
        }
    }

    return .{ all_bits + (@intFromEnum(config.method) + 4) * part_count, config };
}

// Copied from Cuetools
/// Lower compression ratio but faster
/// return `.{ optimal_param, optimal_bit_count }`
pub fn findOptimalParamEstimate(part_sum: u64, part_size: usize) std.meta.Tuple(&.{u6, usize}) {
    std.debug.assert(part_size != 0);
    if (part_sum == 0) return .{ ESC_PART, 5 };
    const optimal_param = std.math.log2_int(u64, part_sum) -| std.math.log2_int(u64, part_size);
    const optimal_bit_count = partEncodeCount(part_sum, part_size, optimal_param);

    return .{ @intCast(optimal_param), optimal_bit_count };
}

// Copied from flake
/// Higher compression ratio but slower
/// return `.{ optimal_param, optimal_bit_count }`
pub fn findOptimalParamSearch(part_sum: u64, part_size: usize, max_param: u8) std.meta.Tuple(&.{ u6, usize }) {
    std.debug.assert(max_param == MAX_PARAM_4BIT or max_param == MAX_PARAM_5BIT);

    var bit_counts: [MAX_PARAM + 1]usize = undefined;
    const bit_counts_len: usize = max_param + 1;
    for (0..bit_counts_len) |param|
        bit_counts[param] = partEncodeCount(part_sum, part_size, @intCast(param));

    // Find best param among the bit counts
    const optimal_param: u6 = @intCast(std.mem.indexOfMin(usize, bit_counts[0..bit_counts_len]));
    const optimal_bit_count: usize = bit_counts[optimal_param];

    return .{ optimal_param, optimal_bit_count };
}

// Copied from flake
inline fn partEncodeCount(sum: u64, part_size: usize, param: u6) usize {
    return part_size * (param + 1) +% ((sum -% part_size / 2) >> param);
}
