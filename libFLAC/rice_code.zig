const std = @import("std");
const sample_iter = @import("samples.zig");
const FixedResidualIter = sample_iter.FixedResidualIter;

const MAX_PARAM_4BIT: u5 = std.math.maxInt(u4) - 1;
const MAX_PARAM_5BIT: u5 = std.math.maxInt(u5) - 1;
pub const MAX_PARAM = MAX_PARAM_5BIT;
pub const ESC_PART = std.math.maxInt(u5);
const MAX_ORDER = 8; // Subset now
const MAX_PART = 1 << MAX_ORDER;

// -- Constants --

const mm_len = blk: {
    const len = std.simd.suggestVectorLength(u64) orelse 1;
    break :blk if (len > 32) 32 else len;
};
const mm_to_32 = 32 / mm_len;
const Vec = @Vector(mm_len, u64);

const ones: Vec = @splat(std.math.maxInt(u64));
const params: [mm_to_32]Vec = blk: {
    var iota: [mm_to_32]Vec = @splat(std.simd.iota(u64, mm_len));
    for (1..mm_to_32) |i| {
        iota[i] += @splat(mm_len * i);
    }
    break :blk iota;
};

const params_p1: [mm_to_32]Vec = blk: {
    var iota: [mm_to_32]Vec = @splat(std.simd.iota(u64, mm_len));
    for (0..mm_to_32) |i| {
        iota[i] += @splat(mm_len * i + 1);
    }
    break :blk iota;
};

// -- Structs --

/// Bits are directly writable by FrameWriter
pub const RiceCode = struct {
    /// Quotient of result
    quo: u32,
    /// 1 ++ remainder of result
    rem: u32,

    pub fn make(param: u5, value: i32) @This() {
        const zigzag: u32 = calcZigzag(value);
        return makeFromZz(param, zigzag);
    }

    pub fn makeFromZz(param: u5, zigzag: u32) @This() {
        return .{
            .quo = @intCast(zigzag >> param),
            .rem = @intCast(zigzag & ((@as(u32, 1) << param) - 1)),
        };
    }
};

pub const RiceConfig = struct {
    method: enum(u6) { FOUR = 0, FIVE = 1 } = .FOUR,
    part_order: u4 = undefined,
    params: [MAX_PART]u5 = undefined,
};

// -- Functions --

pub fn calcRiceParams(
    residuals: []i32,
    max_part_order: u4,
    max_param: u5,
    bit_depth: u8,
    pred_order: u8,
) std.meta.Tuple(&.{ u64, RiceConfig }) {
    std.debug.assert(residuals.len > pred_order);
    const pred_order_limited: u4 = if (pred_order != 0)
        // log2(a / b)
        std.math.log2_int(u16, @intCast(residuals.len)) - std.math.log2_int(u8, pred_order)
    else
        std.math.maxInt(u4);

    const maximum_part_order: u4 = @intCast(@min(max_part_order, @ctz(residuals.len), pred_order_limited));
    const maximum_param: u5 = @intCast(@min(if (bit_depth > 16) MAX_PARAM_5BIT else MAX_PARAM_4BIT, max_param));

    return calcRiceParamEstimate(residuals, maximum_part_order, maximum_param, pred_order);
}

/// return `.{ bit_count, RiceConfig }`
fn calcRiceParamExact(
    residuals: []const i32,
    max_part_order: u4,
    max_param: u5,
    pred_order: u8,
) std.meta.Tuple(&.{ u64, RiceConfig }) {
    std.debug.assert(max_param == MAX_PARAM_4BIT or max_param == MAX_PARAM_5BIT);

    const steps: usize = if (MAX_PARAM == MAX_PARAM_4BIT)
        std.math.divCeil(mm_to_32, 2)
    else
        mm_to_32;

    var bit_counts: [MAX_PART][mm_to_32]Vec = undefined;
    var min_bit_count: u64 = 0;
    var best_rice_config: RiceConfig = .{ .part_order = max_part_order };

    { // Sum residual rice code length into their smallest partition
        const part_counts = @as(usize, 1) << max_part_order;
        const part_size = residuals.len >> max_part_order;
        { // First partition
            const result = sumFirstPartBitCounts(residuals[pred_order..part_size], steps);
            bit_counts[0] = result.bit_counts;
            min_bit_count = result.bit_count;
            best_rice_config.params[0] = result.param;
        }
        // Remaining partitions
        var residuals_inc: []const i32 = residuals[part_size..];
        for (1..part_counts) |part_i| {
            const result = sumFirstPartBitCounts(residuals_inc[0..part_size], steps);
            bit_counts[part_i] = result.bit_counts;
            min_bit_count +|= result.bit_count;
            best_rice_config.params[part_i] = result.param;
            residuals_inc = residuals_inc[part_size..];
        }
        // Decide to extend rice method
        if (max_param > MAX_PARAM_4BIT) {
            for (best_rice_config.params[0..part_counts]) |param| {
                if (param > MAX_PARAM_4BIT) best_rice_config.method = .FIVE;
            }
        }
        min_bit_count += (@as(u64, @intFromEnum(best_rice_config.method)) + 4) * part_counts;
    }

    // Test other partition orders
    var part_order = max_part_order -% 1;
    while (max_part_order != 0) : (part_order -= 1) {
        const order_result = calcOtherPartBitCount(
            &bit_counts,
            part_order,
            max_param,
            steps
        );

        // Update best setting if bit_count is smaller
        if (order_result.bit_count < min_bit_count) {
            min_bit_count = order_result.bit_count;
            best_rice_config = order_result.rice_config;
        }

        if (part_order == 0) break;
    }

    return .{ min_bit_count, best_rice_config };
}

/// Sum up bit_counts of a partition for each param
fn sumFirstPartBitCounts(
    residuals: []const i32,
    steps: usize,
) struct { bit_counts: [mm_to_32]Vec, bit_count: u64, param: u5} {
    // Sum bit_counts up
    var bit_counts: [mm_to_32]Vec = @splat(@splat(0));
    for (residuals) |res| {
        const zigzags: Vec = @splat(calcZigzag(res));
        for (0..steps) |step| {
            bit_counts[step] +|= (zigzags >> @intCast(params[step])) + params_p1[step];
        }
    }

    // Find min bit_counts and param
    var min_bc = bit_counts[0];
    var min_param = params[0];
    for (1..steps) |step| {
        const smaller = bit_counts[step] < min_bc;
        min_param = @select(u64, smaller, params[step], min_param);
        min_bc = @min(bit_counts[step], min_bc);
    }

    const optimal_bit_count: u64 = @reduce(.Min, min_bc);
    const eq_opt_bc = min_bc == @as(Vec, @splat(optimal_bit_count));
    const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, ones));

    return .{
        .bit_counts = bit_counts,
        .bit_count = optimal_bit_count,
        .param = @intCast(optimal_param)
    };
}

fn calcOtherPartBitCount(
    bit_counts: *[MAX_PART][mm_to_32]Vec,
    part_order: u4,
    max_param: u5,
    steps: usize,
) struct { bit_count: u64, rice_config: RiceConfig } {
    var rice_config: RiceConfig = .{ .part_order = part_order };
    var bit_count: u64 = 0;

    const part_counts = @as(usize, 1) << part_order;
    // Sum 2 parts into 1
    for (0..part_counts) |p| {
        for (0..steps) |step| {
            bit_counts[p][step] = bit_counts[p * 2][step] +| bit_counts[p * 2 + 1][step];
        }
    }

    // Find optimal bit_count and param for each partition
    for (0..part_counts) |p| {
        var min_bc: Vec = bit_counts[p][0];
        var min_param: Vec = params[0];
        for (1..steps) |step| {
            const smaller = bit_counts[p][step] < min_bc;
            min_param = @select(u64, smaller, params[step], min_param);
            min_bc = @min(bit_counts[p][step], min_bc);
        }
        const optimal_bit_count: u64 = @reduce(.Min, min_bc);
        const eq_opt_bc = min_bc == @as(Vec, @splat(optimal_bit_count));
        const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, ones));

        bit_count +|= optimal_bit_count;
        rice_config.params[p] = @intCast(optimal_param);
    }

    // Decide to extend rice method
    if (max_param > MAX_PARAM_4BIT) {
        for (rice_config.params[0..part_counts]) |param| {
            if (param > MAX_PARAM_4BIT) rice_config.method = .FIVE;
        }
    }
    bit_count +|= (@as(u64, @intFromEnum(rice_config.method)) + 4) * part_counts;

    // Update best setting if bit_count is smaller
    return .{ .bit_count = bit_count, .rice_config = rice_config };
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcRiceParamEstimate(
    residuals: []const i32,
    max_part_order: u4,
    max_param: u5,
    pred_order: u8,
) std.meta.Tuple(&.{ u64, RiceConfig }) {
    var sums: [MAX_ORDER + 1][MAX_PART]u64 = undefined;
    var optimal_bit_count: u64 = std.math.maxInt(usize);
    var optimal_part_order: u6 = undefined;
    var optimal_config: RiceConfig = undefined;

    calcSums(residuals, max_part_order, pred_order, &sums);

    for (0..max_part_order + 1) |part_order| {
        const bit_count, const config = calcOptimalParams(
            @intCast(part_order),
            @intCast(residuals.len),
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

pub inline fn calcZigzag(value: i32) u32 {
    // return if (value < 0) @as(u32, @bitCast(value)) *% 2 - 1 else @as(u32, @bitCast(value)) *% 2;
    return @bitCast((value << 1) ^ (value >> 31));
}

// Copied from flake
/// Calculate "sum of zigzag" for each partition of each partition size \
/// Of course smallest sum of zigzag compressed the best by rice code
fn calcSums(
    residuals: []const i32,
    max_part_order: u4,
    pred_order: u8,
    sums: *[MAX_ORDER + 1][MAX_PART]u64,
) void {
    std.debug.assert(sums.len > max_part_order);
    std.debug.assert(pred_order <= 4);

    // Sum for highest level
    var res = residuals;
    const part_size: usize = residuals.len >> max_part_order;
    const part_count = @as(usize, 1) << max_part_order;
    @prefetch(residuals, .{ .locality = 3 });
    for (sums[max_part_order][0..part_count], 0..) |*sum, part| {
        sum.* = 0;
        for (res[part * part_size..][0..part_size]) |r|
            sum.* += calcZigzag(r);
    }
    for (0..pred_order) |i| {
        sums[max_part_order][0] -= calcZigzag(residuals[i]);
    }
    // Sum for lower levels
    // Continuously summing next 2 of previous partition size
    if (max_part_order == 0) return;
    var i = max_part_order -% 1;
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
    part_order: u4,
    blk_size: u16,
    max_param: u5,
    pred_order: u8,
    sums: *const [MAX_PART]u64,
) std.meta.Tuple(&.{ u64, RiceConfig }) {
    std.debug.assert(pred_order <= 4);

    const part_count: usize = @as(usize, 1) << part_order;
    var all_bits: u64 = 0;
    var config: RiceConfig = .{.part_order = part_order};

    var part_size: u16 = (blk_size >> part_order) - pred_order;
    for (0..part_count) |i| {
        const optimal_param, const optimal_bit_count =
            findOptimalParam(sums[i], part_size, max_param);
        config.params[i] = optimal_param;
        all_bits += optimal_bit_count;

        part_size = blk_size >> part_order;
    }
    // Decide to extend rice method
    if (max_param > MAX_PARAM_4BIT) {
        for (config.params[0..part_count]) |param| {
            if (param > MAX_PARAM_4BIT) config.method = .FIVE;
        }
    }

    return .{ all_bits + (@intFromEnum(config.method) + 4) * part_count, config };
}

pub fn findOptimalParam(part_sum: u64, part_size: u64, max_param: usize) std.meta.Tuple(&.{u5, u64}) {
    std.debug.assert(max_param == MAX_PARAM_4BIT or max_param == MAX_PARAM_5BIT);

    if (part_sum == 0) { // very rare case that have a partition with all 0 (perfect prediction)
        @branchHint(.cold);
        return .{ @intCast(max_param + 1), 5 };
    }

    var min_bit_count: Vec = @splat(std.math.maxInt(u64));
    var min_param: Vec = @splat(std.math.maxInt(u64));

    const steps = (max_param + mm_len) / mm_len;

    const p_size: Vec = @splat(part_size);
    const lhs: Vec = @splat(part_sum -% part_size / 2);

    for (0..steps) |step| {
        const left = p_size * params_p1[step];
        const right = lhs >> @intCast(params[step]);
        const bit_counts = left +% right;

        const smaller = bit_counts < min_bit_count;
        min_param = @select(u64, smaller, params[step], min_param);
        min_bit_count = @min(bit_counts, min_bit_count);
    }

    const optimal_bit_count: u64 = @reduce(.Min, min_bit_count);
    const eq_opt_bc = min_bit_count == @as(Vec, @splat(optimal_bit_count));
    const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, ones));

    return .{ @intCast(optimal_param), if (optimal_param == max_param + 1) (part_size * optimal_param) else optimal_bit_count };
}
