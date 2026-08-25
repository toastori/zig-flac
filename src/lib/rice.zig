const std = @import("std");

const simd = @import("simd.zig").rice;
const VecU64 = simd.VecU64;

// -- CONSTANTS --

const PARAM4_MAX: u5 = std.math.maxInt(u4) - 1;
const PARAM5_MAX: u5 = std.math.maxInt(u5) - 1;
pub const MAX_PARAM = PARAM5_MAX;
pub const ORDER_MAX = 8; // Subset now
pub const PART_MAX = 1 << ORDER_MAX;

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
    params: []Param,
    part_order: u4,

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
            return !self.isEscape() and (self.p & 0b0111_1111) > PARAM4_MAX;
        }
    };

    pub fn partCounts(self: Config) usize {
        return @as(usize, 1) << self.part_order;
    }
};

pub inline fn calcZigzag(value: i32) u32 {
    return if (value < 0) @as(u32, @bitCast(-value)) *% 2 - 1 else @as(u32, @bitCast(value)) *% 2;
    // return @bitCast((value << 1) ^ (value >> 31));
}

// -- Rice Code Functions --

/// return `.{bit_count, RiceConfig }`
pub fn calcParams(
    noalias residuals: []i32,
    max_part_order: u4,
    max_param: u5,
    noalias sum_buf: *[ORDER_MAX + 1][PART_MAX]u64,
    noalias max_buf: *[ORDER_MAX + 1][PART_MAX]u64,
    noalias cfg_params: *[ORDER_MAX + 1][PART_MAX]Config.Param,
    bit_depth: u8,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    std.debug.assert(residuals.len > pred_order);
    const pred_order_limited: u4 = if (pred_order != 0)
        // log2(a / b)
        std.math.log2_int(u16, @intCast(residuals.len)) - std.math.log2_int(u8, pred_order)
    else
        std.math.maxInt(u4);

    const order_max: u4 = @intCast(
        @min(max_part_order, @ctz(residuals.len), pred_order_limited),
    );
    const param_max: u5 = @intCast(
        @min(if (bit_depth > 16) PARAM5_MAX else PARAM4_MAX, max_param),
    );

    return calcParamEstimate(
        residuals,
        sum_buf,
        max_buf,
        cfg_params,
        order_max,
        param_max,
        pred_order,
    );
}

// -- Exact --

/// return `.{ bit_count, RiceConfig }`
fn calcParamExact(
    residuals: []const i32,
    max_part_order: u4,
    max_param: u5,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    std.debug.assert(max_param == PARAM4_MAX or max_param == PARAM5_MAX);

    const steps: usize = if (max_param == PARAM4_MAX)
        std.math.divCeil(simd.CHUNK32, 2)
    else
        simd.CHUNK32;

    var bit_counts: [PART_MAX][simd.CHUNK32]VecU64 = undefined;
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
        if (max_param > PARAM4_MAX) {
            for (best_rice_config.params[0..part_counts]) |param| {
                if (param > PARAM4_MAX) best_rice_config.method = .FIVE;
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
    bit_counts: *[PART_MAX][simd.CHUNK32]VecU64,
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
    if (max_param > PARAM4_MAX) {
        for (rice_config.params[0..part_counts]) |param| {
            if (param > PARAM4_MAX) rice_config.method = .FIVE;
        }
    }
    bit_count +|= (@as(u64, @intFromEnum(rice_config.method)) + 4) * part_counts;

    // Update best setting if bit_count is smaller
    return .{ .bit_count = bit_count, .rice_config = rice_config };
}

// -- Estimate functions --

/// return `.{ bit_count, RiceConfig }`
fn calcParamEstimate(
    noalias residuals: []const i32,
    noalias sums: *[ORDER_MAX + 1][PART_MAX]u64,
    noalias maxs: *[ORDER_MAX + 1][PART_MAX]u64,
    noalias cfg_params: *[ORDER_MAX + 1][PART_MAX]Config.Param,
    order_max: u4,
    param_max: u5,
    pred_order: u8,
) @Tuple(&.{ u64, Config }) {
    const selectBestConfig = switch (comptime simd.do_simd) {
        true => selectBestConfig_vector,
        else => selectBestConfig_scalar,
    };

    calcSums(residuals, sums, maxs, order_max, pred_order);

    return selectBestConfig(
        sums,
        maxs,
        cfg_params,
        order_max,
        param_max,
        pred_order,
        @intCast(residuals.len),
    );
}

/// Calculate "sum of zigzag" for each partition of each partition size \
/// Of course smallest sum of zigzag compressed the best by rice code
fn calcSums(
    noalias residuals: []const i32,
    noalias sums: *[ORDER_MAX + 1][PART_MAX]u64,
    noalias maxs: *[ORDER_MAX + 1][PART_MAX]u64,
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
fn selectBestConfig_scalar(
    noalias sums: *const [ORDER_MAX + 1][PART_MAX]u64,
    noalias maxs: *[ORDER_MAX + 1][PART_MAX]u64, // reused for partition bit counts
    noalias cfg_params: *[ORDER_MAX + 1][PART_MAX]Config.Param,
    order_max: u4,
    param_max: u5,
    pred_order: u8,
    samples_cnt: u16,
) @Tuple(&.{ u64, Config }) {
    var opt_bits: u64 = std.math.maxInt(u64);
    var opt_cfg: Config = undefined;

    for (0..order_max + 1) |order| {
        const part_cnt = @as(u64, 1) << @intCast(order);
        const part_len = samples_cnt >> @intCast(order);
        const _sums = &sums[order];
        const _maxs = &maxs[order];
        const _params = &cfg_params[order];

        // Process rice params
        processEscape_scalar(_maxs, _params, part_cnt, part_len, pred_order);
        processParams_scalar(_sums, _maxs, _params, param_max, part_cnt, part_len, pred_order);

        // Evaluate rice method
        var method: Config.Method = .FOUR;
        if (param_max > PARAM4_MAX) {
            for (_params[0..part_cnt]) |param| {
                if (param.isRice2()) method = .FIVE;
            }
        }

        // Calculate total bits
        var bits: u64 = @as(u64, method.headerBits()) * part_cnt;
        for (_maxs[0..part_cnt]) |_bits| bits += _bits;

        // Update optimal
        if (bits < opt_bits) {
            opt_bits = bits;
            opt_cfg = .{
                .part_order = @intCast(order),
                .method = method,
                .params = _params[0..part_cnt],
            };
        }
    }

    return .{ opt_bits, opt_cfg };
}

fn selectBestConfig_vector(
    noalias sums: *const [ORDER_MAX + 1][PART_MAX]u64,
    noalias maxs: *[ORDER_MAX + 1][PART_MAX]u64, // reused for partition bit counts
    noalias cfg_params: *[ORDER_MAX + 1][PART_MAX]Config.Param,
    order_max: u4,
    param_max: u5,
    pred_order: u8,
    samples_cnt: u16,
) @Tuple(&.{ u64, Config }) {
    // Partition 0 backups for partition order 1..
    var sums0: [ORDER_MAX]u64 = undefined;
    var bits0: [ORDER_MAX]u64 = undefined;
    var params0: [ORDER_MAX]Config.Param = undefined;

    var opt_bits: u64 = std.math.maxInt(u64);
    var opt_cfg: Config = undefined;

    { // Partition order 0 (scalar)
        const _sums = &sums[0];
        const _maxs = &maxs[0];
        const _params = &cfg_params[0];
        // process rice params
        processEscape_scalar(_maxs, _params, 1, samples_cnt, pred_order);
        processParams_scalar(_sums, _maxs, _params, param_max, 1, samples_cnt, pred_order);
        // Apply as opt
        const method: Config.Method = if (_params[0].isRice2()) .FIVE else .FOUR;
        opt_bits = @as(u64, method.headerBits()) + _maxs[0];
        opt_cfg = .{ .method = method, .params = _params[0..1], .part_order = 0 };
    }
    // Partition order 1.. (vector)
    // Process partition 1.. first
    {
        var order: u4 = 1;
        while (order <= order_max) : (order += 1) {
            const part_cnt = @as(u64, 1) << order;
            const part_len = samples_cnt >> order;
            const _sums = &sums[order];
            const _maxs = &maxs[order];
            const _params = &cfg_params[order];

            bits0[order - 1] = processEscape_vector(_maxs, _params, part_cnt, part_len, pred_order);
            sums0[order - 1] = _sums[0];
            params0[order - 1] = _params[0];
            processParams_vector(_sums, _maxs, _params, param_max, part_cnt, part_len);
        }
    }
    // Partition order 1..
    // Process partition 0s
    processParamsP0_vector(&sums0, &bits0, &params0, order_max, param_max, pred_order, samples_cnt);
    // Calculate and compare bits for part order 1..
    {
        var order: u4 = 1;
        while (order <= order_max) : (order += 1) {
            const part_cnt = @as(u64, 1) << order;
            const _bits0 = bits0[order - 1];
            const _params0 = params0[order - 1];
            const _maxs = &maxs[order];
            const _params = &cfg_params[order];

            var method: Config.Method = if (_params0.isRice2()) .FIVE else .FOUR;
            if (param_max > PARAM4_MAX and method == .FOUR) {
                for (_params[1..part_cnt]) |param| {
                    if (param.isRice2()) method = .FIVE;
                }
            }

            var bits: u64 = @as(u64, method.headerBits()) * part_cnt + _bits0;
            for (_maxs[1..part_cnt]) |_bits| bits += _bits;

            if (bits < opt_bits) {
                _params[0] = _params0;
                opt_bits = bits;
                opt_cfg = .{
                    .part_order = order,
                    .method = method,
                    .params = _params[0..part_cnt],
                };
            }
        }
    }

    return .{ opt_bits, opt_cfg };
}

/// return `escape_bits[0]`
fn processEscape_scalar(
    escape_bits: *[PART_MAX]u64,
    rice_params: *[PART_MAX]Config.Param,
    part_cnt: usize,
    part_len: u16,
    pred_order: u8,
) void {
    const part_bits0 = escape_bits[0];
    for (escape_bits[0..part_cnt], rice_params[0..part_cnt]) |*max, *param| {
        param.* = .makeEscape(@intCast(max.*));
        // bits_per_residuals(5) + residuals(bpr) * part_size
        max.* = if (param.isValidEscape()) (5 + max.* * part_len) else std.math.maxInt(u64);
    }
    escape_bits[0] -= part_bits0 * pred_order;
}

/// return `escape_bits[0]`
fn processEscape_vector(
    escape_bits: *[PART_MAX]u64,
    rice_params: *[PART_MAX]Config.Param,
    part_cnt: usize,
    part_len: u16,
    pred_order: u8,
) u64 {
    const vlanes = @min(simd.LEN64R, PART_MAX);
    const V = @Vector(vlanes, u64);
    const VecU8 = @Vector(vlanes, u8);

    const intmaxV: V = @splat(std.math.maxInt(u64));
    const part_lenV: V = @splat(part_len);
    const param_mask: V = @splat(0b1000_0000);
    const valid_maxV: V = @splat(31);
    const header_size: V = @splat(5);

    const part_bits0 = escape_bits[0];
    var idx: usize = 0;
    while (idx < part_cnt) : (idx += vlanes) {
        // save params
        const bits: V = escape_bits[idx..][0..vlanes].*;
        const invalids = bits > valid_maxV;
        // rice_params are []u8 internally
        const rice_paramV: *[vlanes]u8 = std.mem.sliceAsBytes(rice_params)[idx..][0..vlanes];
        rice_paramV.* = @as(VecU8, @truncate(bits | param_mask));

        // compute size
        // use overdlow operators to deal with out of bounds values
        const part_bits = header_size +% bits *% part_lenV;
        escape_bits[idx..][0..vlanes].* = @select(u64, invalids, intmaxV, part_bits);
    }
    return escape_bits[0] - part_bits0 * pred_order;
}

fn processParams_scalar(
    noalias abs_sums: *const [PART_MAX]u64,
    noalias min_bits: *[PART_MAX]u64,
    noalias rice_params: *[PART_MAX]Config.Param,
    param_max: u5,
    part_cnt: usize,
    part_len: u16,
    pred_order: u8,
) void {
    const part_len0 = part_len - pred_order;

    var param: u5 = 0;
    while (param <= param_max) : (param += 1) {
        { // 1st partition
            const p = 0;
            const bits = calcPartSize(part_len0, param, abs_sums[p]);
            if (bits < min_bits[p]) rice_params[p] = .{ .p = @intCast(param) };
            if (bits < min_bits[p]) min_bits[p] = bits;
        }
        for (1..part_cnt) |p| { // Other partitions
            const bits = calcPartSize(part_len, param, abs_sums[p]);
            if (bits < min_bits[p]) rice_params[p] = .{ .p = @intCast(param) };
            if (bits < min_bits[p]) min_bits[p] = bits;
        }
    }
}

fn processParams_vector(
    noalias abs_sums: *const [PART_MAX]u64,
    noalias min_bits: *[PART_MAX]u64,
    noalias rice_params: *[PART_MAX]Config.Param,
    param_max: u5,
    part_cnt: usize,
    part_len: u16,
) void {
    const vlanes = @min(simd.LEN64R, PART_MAX);
    const V = @Vector(vlanes, u64);
    const VecU8 = @Vector(vlanes, u8);
    const VecU6 = @Vector(vlanes, u6);

    const ones: VecU6 = @splat(1);
    const part_lenV: V = @splat(part_len);
    const part_len_lsr1V: V = part_lenV >> ones;

    var paramV: V = @splat(0);
    var param_add1V: V = @splat(1);
    var param_sub1V: V = undefined;

    // Calculate all partitions with same length first
    { // param == 0
        const lhs = param_add1V *% part_lenV;

        var idx: usize = 0;
        while (idx < part_cnt) : (idx += vlanes) {
            const abs_sumV: V = abs_sums[idx..][0..vlanes].*;
            const min_bitsV: *[vlanes]u64 = min_bits[idx..][0..vlanes];
            const rice_paramsV: *[vlanes]u8 = std.mem.sliceAsBytes(rice_params)[idx..][0..vlanes];
            // Calculate bits first
            const bits: V = lhs +% (abs_sumV << ones) -% part_len_lsr1V;
            // Compare and store
            const smaller = bits < min_bitsV.*;
            rice_paramsV.* = @select(u8, smaller, @as(VecU8, @intCast(paramV)), rice_paramsV.*);
            min_bitsV.* = @select(u64, smaller, bits, min_bitsV.*);
        }
    }
    var param: u5 = 1;
    while (param <= param_max) : (param += 1) {
        param_sub1V = paramV;
        paramV = param_add1V;
        param_add1V += ones;

        const lhs = param_add1V *% part_lenV;

        var idx: usize = 0;
        while (idx < part_cnt) : (idx += vlanes) {
            const abs_sumV: V = abs_sums[idx..][0..vlanes].*;
            const min_bitsV: *[vlanes]u64 = min_bits[idx..][0..vlanes];
            const rice_paramsV: *[vlanes]u8 = std.mem.sliceAsBytes(rice_params)[idx..][0..vlanes];
            // Calculate bits first
            const bits: V = lhs +% (abs_sumV >> @intCast(param_sub1V)) -% part_len_lsr1V;
            // Compare and store
            const smaller = bits < min_bitsV.*;
            rice_paramsV.* = @select(u8, smaller, @as(VecU8, @intCast(paramV)), rice_paramsV.*);
            min_bitsV.* = @select(u64, smaller, bits, min_bitsV.*);
        }
    }

    // The real partition0 will be process much later
}

fn processParamsP0_vector(
    noalias abs_sums0: *const [ORDER_MAX]u64,
    noalias bits0: *[ORDER_MAX]u64,
    noalias params0: *[ORDER_MAX]Config.Param,
    order_max: u4,
    param_max: u5,
    pred_order: u8,
    samples_cnt: u16,
) void {
    const vlanes = @min(simd.LEN64R, ORDER_MAX);
    const V = @Vector(vlanes, u64);
    const VecU8 = @Vector(vlanes, u8);

    const ones: V = @splat(1);
    const vlanesV: V = @splat(vlanes);
    const pred_orderV: V = @splat(pred_order);
    const samples_cntV: V = @splat(samples_cnt);

    var ordersV: V = std.simd.iota(u64, vlanes) + ones;
    var part_lenV: V = (samples_cntV >> @intCast(ordersV)) - pred_orderV;
    var part_len_lsr1V: V = part_lenV >> @intCast(ones);

    var idx: usize = 0;
    while (true) {
        var paramV: V = @splat(0);
        var param_add1V: V = @splat(1);
        var param_sub1V: V = undefined;

        const abs_sumV: V = abs_sums0[idx..][0..vlanes].*;
        const min_bitsV: *[vlanes]u64 = bits0[idx..][0..vlanes];
        const rice_paramsV: *[vlanes]u8 = std.mem.sliceAsBytes(params0)[idx..][0..vlanes];

        { // param == 0
            const lhs = param_add1V *% part_lenV;
            // Calculate bits first
            const bits: V = lhs +% (abs_sumV << @intCast(ones)) -% part_len_lsr1V;
            const smaller = bits < min_bitsV.*;
            rice_paramsV.* = @select(u8, smaller, @as(VecU8, @intCast(paramV)), rice_paramsV.*);
            min_bitsV.* = @select(u64, smaller, bits, min_bitsV.*);
        }
        var param: u5 = 1;
        while (param <= param_max) : (param += 1) {
            param_sub1V = paramV;
            paramV = param_add1V;
            param_add1V += ones;

            const lhs = param_add1V *% part_lenV;
            // Calculate bits first
            const bits: V = lhs +% (abs_sumV >> @intCast(param_sub1V)) -% part_len_lsr1V;
            // Compare and store
            const smaller = bits < min_bitsV.*;
            rice_paramsV.* = @select(u8, smaller, @as(VecU8, @intCast(paramV)), rice_paramsV.*);
            min_bitsV.* = @select(u64, smaller, bits, min_bitsV.*);
        }

        idx += vlanes;
        if (idx >= order_max) break;
        ordersV += vlanesV;
        part_lenV = (samples_cntV >> @intCast(ordersV)) - pred_orderV;
        part_len_lsr1V = part_lenV >> @intCast(ones);
    }
}

// libFLAC's algorithm
fn calcPartSize(part_len: u64, param: u64, abs_sum: u64) u64 {
    return (1 + param) * part_len +%
        (if (param == 0) (abs_sum << 1) else (abs_sum >> @intCast(param - 1))) -% (part_len >> 1);
}

// -- UNUSED FUNCTIONS -- (impl references)

// Flake's algorithm
fn calcPartSize_flake(part_size: u64, param: u64, sum: u64) u64 { // zigzag sum
    return @as(u64, part_size) * @as(u64, param + 1) +% ((sum -% part_size / 2) >> @intCast(param));
}

fn estimateBestParam(max_param: u5, part_size: u64, sum: u64) u5 {
    const mean = sum / part_size;
    if (mean == 0) std.debug.print("sum = {d} / partsize = {d}\n", .{ sum, part_size });
    const p = std.math.log2_int(u64, mean);
    return @min(p, max_param);
}
