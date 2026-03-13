const std = @import("std");
const sample_iter = @import("samples.zig");
const FixedResidualIter = sample_iter.FixedResidualIter;

const MAX_PARAM_4BIT: u5 = std.math.maxInt(u4) - 1;
const MAX_PARAM_5BIT: u5 = std.math.maxInt(u5) - 1;
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

pub fn calcRiceParamFixed(
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

    return calcRiceParam(residuals, maximum_part_order, maximum_param, pred_order);
}

// Copied from flake
/// return `.{ bit_count, RiceConfig }`
fn calcRiceParam(
    residuals: []i32,
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
    residuals: []i32,
    max_part_order: u4,
    pred_order: u8,
    sums: *[MAX_ORDER + 1][MAX_PART]u64,
) void {
    std.debug.assert(sums.len > max_part_order);
    std.debug.assert(pred_order <= 4);

    // Sum for highest level
    var res = residuals;
    const part_size: usize = residuals.len >> max_part_order;
    @prefetch(residuals, .{ .locality = 3 });
    for (sums[max_part_order][0..(@as(usize, 1) << max_part_order)], 0..) |*sum, part| {
        sum.* = 0;
        for (res[part * part_size..][0..part_size]) |r|
            sum.* += calcZigzag(r);
    }
    for (0..pred_order) |i| {
        sums[max_part_order][0] -= calcZigzag(residuals[i]);
    }
    // Sum for lower levels
    // Continuously summing next 2 of previous partition size
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
    const mm_len = std.simd.suggestVectorLength(u64) orelse 1;
    const Vec = @Vector(mm_len, u64);

    if (part_sum == 0) { // very rare case that have a partition with all 0 (perfect prediction)
        @branchHint(.cold);
        return .{ @intCast(max_param + 1), 5 };
    }

    var min_bit_count: Vec = @splat(std.math.maxInt(u64));
    var min_param: Vec = @splat(std.math.maxInt(u64));

    const steps = (max_param + mm_len) / mm_len;

    var param: Vec = std.simd.iota(u64, mm_len);
    var param_p1: Vec = param + @as(Vec, @splat(1));

    const p_size: Vec = @splat(part_size);
    const ones: Vec = @splat(std.math.maxInt(u64));
    const lhs: Vec = @splat(part_sum -% part_size / 2);
    var temps: [2]Vec = undefined;


    for (0..steps) |_| {
        temps[0] = p_size * param_p1;
        temps[1] = lhs >> @intCast(param);
        const bit_counts = temps[0] +% temps[1];

        const smaller = bit_counts < min_bit_count;
        min_param = @select(u64, smaller, param, min_param);
        min_bit_count = @min(bit_counts, min_bit_count);

        param += @splat(mm_len);
        param_p1 += @splat(mm_len);
    }

    const optimal_bit_count: u64 = @reduce(.Min, min_bit_count);
    const eq_opt_bc: @Vector(mm_len, bool) = min_bit_count == @as(Vec, @splat(optimal_bit_count));
    const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, ones));

    return .{ @intCast(optimal_param), if (optimal_param == max_param + 1) (part_size * optimal_param) else optimal_bit_count };
}