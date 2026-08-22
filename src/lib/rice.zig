const std = @import("std");

const simd = @import("simd.zig").rice;
const VecU64 = simd.VecU64;

// -- CONSTANTS --

const MAX_PARAM_4BIT: u5 = std.math.maxInt(u4) - 1;
const MAX_PARAM_5BIT: u5 = std.math.maxInt(u5) - 1;
pub const MAX_PARAM = MAX_PARAM_5BIT;
pub const ESC_PART = std.math.maxInt(u5);
pub const MAX_ORDER = 8; // Subset now
pub const MAX_PART = 1 << MAX_ORDER;

// -- Structs --

/// Bits are directly writable by FrameWriter
pub const Code = struct {
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

pub const Config = struct {
    method: Method = .FOUR,
    part_order: u4 = undefined,
    params: [MAX_PART]Param = undefined,

    pub const Method = enum(u6) {
        FOUR = 0,
        FIVE = 1,

        pub fn headerBits(self: Config.Method) u6 {
            return @intFromEnum(self) + 4;
        }
    };

    pub const Param = struct {
        p: u8,

        pub fn makeEscape(bits: u8) Config.Param {
            return .{ .p = bits | 0b1000_0000 };
        }

        pub fn isEscape(self: Config.Param) bool {
            return self.p >= 0b1000_0000;
        }

        pub fn isValidEscape(self: Config.Param) bool {
            std.debug.assert(self.isEscape());

            return self.escapeBits() <= 0b11111;
        }

        pub fn escapeBits(self: Config.Param) u8 {
            std.debug.assert(self.isEscape());

            return self.p & 0b0111_1111;
        }

        pub fn isRice2(self: Config.Param) bool {
            return !self.isEscape() and (self.p & 0b0111_1111) > MAX_PARAM_4BIT;
        }
    };

    pub fn partCounts(self: Config) usize {
        return @as(usize, 1) << self.part_order;
    }
};

// -- Functions --

/// return `.{bit_count, RiceConfig }`
pub fn calcParams(
    noalias residuals: []i32,
    max_part_order: u4,
    max_param: u5,
    noalias sum_buf: *[MAX_ORDER + 1][MAX_PART]u64,
    noalias max_buf: *[MAX_ORDER + 1][MAX_PART]u64,
    bit_depth: u8,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    std.debug.assert(residuals.len > pred_order);
    const pred_order_limited: u4 = if (pred_order != 0)
        // log2(a / b)
        std.math.log2_int(u16, @intCast(residuals.len)) - std.math.log2_int(u8, pred_order)
    else
        std.math.maxInt(u4);

    const maximum_part_order: u4 = @intCast(@min(max_part_order, @ctz(residuals.len), pred_order_limited));
    const maximum_param: u5 = @intCast(@min(if (bit_depth > 16) MAX_PARAM_5BIT else MAX_PARAM_4BIT, max_param));

    return calcParamEstimate(residuals, sum_buf, max_buf, maximum_part_order, maximum_param, pred_order);
}

/// return `.{ bit_count, RiceConfig }`
fn calcParamExact(
    residuals: []const i32,
    max_part_order: u4,
    max_param: u5,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    std.debug.assert(max_param == MAX_PARAM_4BIT or max_param == MAX_PARAM_5BIT);

    const steps: usize = if (max_param == MAX_PARAM_4BIT)
        std.math.divCeil(simd.CHUNK32, 2)
    else
        simd.CHUNK32;

    var bit_counts: [MAX_PART][simd.CHUNK32]VecU64 = undefined;
    var min_bit_count: u64 = 0;
    var best_rice_config: Config = .{ .part_order = max_part_order };

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
        const order_result = calcOtherPartBitCount(&bit_counts, part_order, max_param, steps);

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
) struct { bit_counts: [simd.CHUNK32]VecU64, bit_count: u64, param: u5 } {
    // Sum bit_counts up
    var bit_counts: [simd.CHUNK32]VecU64 = @splat(@splat(0));
    for (residuals) |res| {
        const zigzags: VecU64 = @splat(calcZigzag(res));
        for (0..steps) |step| {
            bit_counts[step] +|= (zigzags >> @intCast(simd.PARAMS[step])) + simd.PARAM_P1[step];
        }
    }

    // Find min bit_counts and param
    var min_bc = bit_counts[0];
    var min_param = simd.PARAMS[0];
    for (1..steps) |step| {
        const smaller = bit_counts[step] < min_bc;
        min_param = @select(u64, smaller, simd.PARAMS[step], min_param);
        min_bc = @min(bit_counts[step], min_bc);
    }

    const optimal_bit_count: u64 = @reduce(.Min, min_bc);
    const eq_opt_bc = min_bc == @as(VecU64, @splat(optimal_bit_count));
    const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, simd.ONES));

    return .{ .bit_counts = bit_counts, .bit_count = optimal_bit_count, .param = @intCast(optimal_param) };
}

fn calcOtherPartBitCount(
    bit_counts: *[MAX_PART][simd.CHUNK32]VecU64,
    part_order: u4,
    max_param: u5,
    steps: usize,
) struct { bit_count: u64, rice_config: Config } {
    var rice_config: Config = .{ .part_order = part_order };
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
        var min_bc: VecU64 = bit_counts[p][0];
        var min_param: VecU64 = simd.PARAMS[0];
        for (1..steps) |step| {
            const smaller = bit_counts[p][step] < min_bc;
            min_param = @select(u64, smaller, simd.PARAMS[step], min_param);
            min_bc = @min(bit_counts[p][step], min_bc);
        }
        const optimal_bit_count: u64 = @reduce(.Min, min_bc);
        const eq_opt_bc = min_bc == @as(VecU64, @splat(optimal_bit_count));
        const optimal_param: u64 = @reduce(.Min, @select(u64, eq_opt_bc, min_param, simd.ONES));

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

/// return `.{ bit_count, RiceConfig }`
fn calcParamEstimate(
    noalias residuals: []const i32,
    noalias sums: *[MAX_ORDER + 1][MAX_PART]u64,
    noalias maxs: *[MAX_ORDER + 1][MAX_PART]u64,
    max_part_order: u4,
    max_param: u5,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    var optimal_bit_count: u64 = std.math.maxInt(usize);
    var optimal_part_order: u6 = undefined;
    var optimal_config: Config = undefined;

    calcSums(residuals, sums, maxs, max_part_order, pred_order);

    for (0..max_part_order + 1) |part_order| {
        const bit_count, const config = calcOptimalParams(
            @intCast(part_order),
            @intCast(residuals.len),
            max_param,
            pred_order,
            &sums[part_order],
            &maxs[part_order],
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
    return if (value < 0) @as(u32, @bitCast(-value)) *% 2 - 1 else @as(u32, @bitCast(value)) *% 2;
    // return @bitCast((value << 1) ^ (value >> 31));
}

/// Calculate "sum of zigzag" for each partition of each partition size \
/// Of course smallest sum of zigzag compressed the best by rice code
fn calcSums(
    noalias residuals: []const i32,
    noalias sums: *[MAX_ORDER + 1][MAX_PART]u64,
    noalias maxs: *[MAX_ORDER + 1][MAX_PART]u64,
    max_part_order: u4,
    pred_order: u8,
) void {
    std.debug.assert(sums.len > max_part_order);
    std.debug.assert(pred_order <= 4);

    // Sum for highest level
    var res = residuals;
    const part_size: usize = residuals.len >> max_part_order;
    const part_count = @as(usize, 1) << max_part_order;

    { // 1st partition
        const sum = &(sums[max_part_order][0]);
        const max = &(maxs[max_part_order][0]);
        sum.* = 0;
        max.* = 0;
        for (res[pred_order..part_size]) |r| {
            const zigzag = calcZigzag(r);
            sum.* += @abs(r);
            max.* |= zigzag;
        }
        max.* = if (max.* == 0) 0 else (@bitSizeOf(@TypeOf(max.*)) - @clz(max.*));
    }
    for ( // Other partitions
        sums[max_part_order][1..part_count],
        maxs[max_part_order][1..part_count],
        1..,
    ) |*sum, *max, part| {
        sum.* = 0;
        max.* = 0;
        for (res[part * part_size ..][0..part_size]) |r| {
            const zigzag = calcZigzag(r);
            sum.* += @abs(r);
            max.* |= zigzag;
        }
        max.* = if (max.* == 0) 0 else (@bitSizeOf(@TypeOf(max.*)) - @clz(max.*));
    }
    // Sum for lower levels
    // Continuously summing next 2 of previous partition size
    if (max_part_order == 0) return;
    var i = max_part_order -% 1;
    while (true) : (i -= 1) {
        for (0..@as(usize, 1) << i) |j| {
            sums[i][j] = sums[i + 1][j * 2] + sums[i + 1][j * 2 + 1];
            maxs[i][j] = @max(maxs[i + 1][j * 2], maxs[i + 1][j * 2 + 1]);
        }
        if (i == 0) break;
    }
}

/// return `.{ bit_count, RiceConfig }`
fn calcOptimalParams(
    part_order: u4,
    blk_size: u16,
    max_param: u5,
    pred_order: u8,
    noalias sums: *const [MAX_PART]u64,
    noalias maxs: *[MAX_PART]u64, // reused for partition bit counts
) @Tuple(&.{ u64, Config }) {
    std.debug.assert(pred_order <= 4);

    const part_count: usize = @as(usize, 1) << part_order;
    var config: Config = .{ .part_order = part_order };

    const first_part_size = (blk_size >> part_order) - pred_order;
    const part_size = blk_size >> part_order;

    { // Calculate escaped partition's size
        const first_part_max = maxs[0];
        for (maxs[0..part_count], config.params[0..part_count]) |*max, *param| {
            param.* = .makeEscape(@intCast(max.*));
            // bits_per_residuals(5) + residuals(bpr) * part_size
            max.* = if (param.isValidEscape()) (5 + max.* * part_size) else std.math.maxInt(u64);
        }
        maxs[0] -= first_part_max * pred_order;
    }
    { // Calculate each param's partition size
        for (0..max_param) |param| {
            { // 1st partition
                const size = flacCalcPartSize(first_part_size, param, sums[0]);
                if (size < maxs[0]) config.params[0] = .{ .p = @intCast(param) };
                if (size < maxs[0]) maxs[0] = size;
            }
            for (1..part_count) |p| { // Other partitions
                const size = flacCalcPartSize(part_size, param, sums[p]);
                if (size < maxs[p]) config.params[p] = .{ .p = @intCast(param) };
                if (size < maxs[p]) maxs[p] = size;
            }
        }
    }
    // Decide to extend rice method
    if (max_param > MAX_PARAM_4BIT) {
        for (config.params[0..part_count]) |param| {
            if (param.isRice2()) config.method = .FIVE;
        }
    }
    // Sum bit_size of each partitions
    var data_bits_size: u64 = 0;
    for (maxs[0..part_count]) |bits| {
        data_bits_size += bits;
    }

    return .{ data_bits_size + (@as(u64, config.method.headerBits()) * part_count), config };
}

// Flake's algorithm
fn calcPartSize(part_size: u64, param: u64, sum: u64) u64 {
    return @as(u64, part_size) * @as(u64, param + 1) +% ((sum -% part_size / 2) >> @intCast(param));
}

fn flacCalcPartSize(part_size: u64, param: u64, abs_sum: u64) u64 {
    return (1 + param) * part_size +%
        if (param == 0) (abs_sum << 1) else (abs_sum >> @intCast(param - 1)) -% (part_size >> 1);
}

fn estimateBestParam(max_param: u5, part_size: u64, sum: u64) u5 {
    const mean = sum / part_size;
    if (mean == 0) std.debug.print("sum = {d} / partsize = {d}\n", .{ sum, part_size });
    const p = std.math.log2_int(u64, mean);
    return @min(p, max_param);
}
