const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const mode = @import("builtin").mode;

const LEN_PER_CHANNEL = std.math.maxInt(u16);

/// Iterator of multiple channel (for writing)
/// implemented in circular buffer \
/// Call `singleChannelIter()` for single channel reading iterator
pub const MultiChannelIter = struct {
    /// Slice of allocated buffer
    big_samples: []i32,
    /// Channel separated samples in queue \
    /// Since flac's max channel count is 8,
    /// an array of 8 slice saved an allocation while sacrificing very little memory
    channel_samples: [8][*]i32,
    /// Head pointer of the queue
    start: u16 = 0,
    /// Length of queue
    len: u16 = 0,

    /// Debug Only: Channel count (for assert)
    channel_count: if (mode == .Debug) u8 else void,

    pub fn init(allocator: std.mem.Allocator, channels_count: u8) !@This() {
        std.debug.assert(channels_count <= 8);

        const big_samples: []i32 = try allocator.alloc(i32, (LEN_PER_CHANNEL + 1) * @as(usize, channels_count));
        var channel_samples: [8][*]i32 = undefined;
        for (0..channels_count) |i| channel_samples[i] = big_samples[i * (LEN_PER_CHANNEL + 1) ..][0..(LEN_PER_CHANNEL + 1)].ptr;
        return .{
            .big_samples = big_samples,
            .channel_samples = channel_samples,
            .channel_count = if (mode == .Debug) channels_count else {},
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.big_samples);
    }

    /// Return `SingleChannelIter` for specified channel
    pub fn singleChannelIter(self: @This(), channel: u8, len: u16) SingleChannelIter {
        if (mode == .Debug) std.debug.assert(channel < self.channel_count);

        std.debug.assert(len <= self.len);

        return .{
            .samples = self.channel_samples[channel],
            .start = self.start,
            .len = len,
        };
    }

    /// Supply a slice of samples with length of channels count \
    /// return true if there are still space in the iterator to fill
    pub fn addInterleavedSample(self: *@This(), samples: []i32) bool {
        std.debug.assert(if (mode == .Debug) samples.len == self.channel_count else true);
        for (samples, 0..) |sample, ch| {
            self.channel_samples[ch][self.start +% self.len] = sample;
        }
        self.len += 1;
        return self.len != LEN_PER_CHANNEL;
    }

    /// Fill the iterator with contineously calling `nextFn(nextFn_args...)` \
    /// Expect the return type of `nextFn` be !?iN or ?iN while N <= 32 (eg !?i32) \
    /// \
    /// Error return by `nextFn` will be returned for the caller to catch manually
    pub fn iterFill(
        self: *@This(),
        channels_count: u8,
        comptime nextFn: anytype,
        nextFn_args: anytype,
    ) !void {
        // -- Type Check --
        const IS_ERROR: bool, const IS_OPTIONAL: bool = comptime switch (@typeInfo(@TypeOf(nextFn))) {
            .@"fn" => |f| hav_err: {
                var is_error, var is_option = .{ false, false };
                r_ty: switch (@typeInfo(f.return_type.?)) {
                    .error_union => |eu| {
                        is_error = true;
                        continue :r_ty if (!is_option) @typeInfo(eu.payload) else .null;
                    },
                    .optional => |op| {
                        is_option = true;
                        continue :r_ty @typeInfo(op.child);
                    },
                    .int => |i| if (i.signedness == .unsigned or i.bits > 32) continue :r_ty .null,
                    else => {
                        is_error = false;
                        is_option = false;
                    },
                }
                if (!is_error and !is_option)
                    @compileError("nextFn: return type: expect either !?iN or ?iN while N <= 32 (eg !?i32), but " ++ @typeName(f.return_type) ++ " is found");
                break :hav_err .{ is_error, is_option };
            },
            else => @compileError("nextFn: expect *const fn (...) ?i32, but " ++ @typeName(@TypeOf(nextFn)) ++ " is found."),
        };

        // Tracy
        const tracy_zone = tracy.beginZone(@src(), .{ .name = "MultiSampleIter.wavFill" });
        defer tracy_zone.end();

        if (mode == .Debug) std.debug.assert(self.channel_count == self.channel_count);

        while (self.len < LEN_PER_CHANNEL) : (self.len += 1) {
            for (self.channel_samples[0..channels_count]) |ch| {
                const sample_1 = @call(.auto, nextFn, nextFn_args);
                const sample_2 = if (comptime !IS_ERROR) sample_1 else try sample_1;
                const sample: i32 = if (comptime !IS_OPTIONAL) sample_2 else sample_2 orelse {
                    if (@intFromPtr(ch) != @intFromPtr(self.big_samples.ptr)) { // not the first channel
                        @branchHint(.unlikely);
                        std.log.err("input: incomplete stream", .{});
                        std.process.exit(3);
                    }
                    return;
                };
                ch[self.start +% self.len] = sample;
            }
        }
    }

    /// Advance the `start` ptr by `amount` \
    /// Pop the first `amount` of samples from the iterator
    /// to leave spaces for new samples
    pub fn advanceStart(self: *@This(), amount: u16) void {
        std.debug.assert(amount <= LEN_PER_CHANNEL);

        self.start = self.start +% amount;
        self.len -= amount;
    }
};

/// Read raw samples of single channel
pub const SingleChannelIter = struct {
    /// Reference of samples from MultiChannelIter
    samples: [*]i32,
    /// Head pointer of the queue
    start: u16,
    /// Length of the queue
    len: u16,
    /// Index of progress
    idx: u16 = 0,

    /// Get generic sample iterator
    pub fn sampleIter(self: *@This()) SampleIter(i32) {
        return SampleIter(i32).init(
            @This(),
            self,
            next,
            peek,
            reset,
            self.len,
        );
    }

    pub fn next(self: *@This()) ?i32 {
        const sample = self.peek();
        if (sample != null) self.idx += 1;
        return sample;
    }

    pub fn peek(self: @This()) ?i32 {
        if (self.idx == self.len) return null;
        return self.samples[self.start +% self.idx];
    }

    pub fn reset(self: *@This()) void {
        self.idx = 0;
    }
};

/// Read residuals after FixedPrediction \
/// Residual range unchecked, should be checked while
/// selecting subframe method
pub fn FixedResidualIter(SampleT: type) type {
    std.debug.assert(SampleT == i32 or SampleT == i64);
    return struct {
        /// Underlying iterator that returns sample
        iterator: SampleIter(SampleT),

        prev_samples: @Vector(4, i64),
        order: usize,

        pub fn residualIter(self: *@This()) ResidualIter {
            return ResidualIter.init(
                @This(),
                self,
                next,
                peek,
            );
        }

        const fp = @import("fixed_prediction.zig");

        pub fn next(self: *@This()) ?i32 {
            const sample = self.iterator.next() orelse return null;
            const residual = fp.calcResidual(sample, self.prev_samples, self.order);
            self.prev_samples = std.simd.shiftElementsRight(self.prev_samples, 1, sample);
            return @intCast(residual);
        }

        pub fn peek(self: @This()) ?i32 {
            const sample = self.iterator.peek() orelse return null;
            return fp.calcResidual(sample, self.prev_samples, self.order);
        }
    };
}

/// Calculate order [0,4] all at once
pub fn MultiOrderFixedResidualIter(SampleT: type) type {
    std.debug.assert(SampleT == i32 or SampleT == i64);
    return struct {
        iterator: SampleIter(SampleT),

        prev_samples: @Vector(4, i64),

        const fp = @import("fixed_prediction.zig");

        /// Return an iterator and total_error for each order up to first 4 samples
        /// result `total_error` over maxInt(u49) means out of range,
        /// since the value will never be reached with all values in range
        pub fn init(iterator: SampleIter(SampleT), comptime check_range: bool) std.meta.Tuple(&.{ @This(), [fp.MAX_ORDER]u64 }) {
            std.debug.assert(iterator.len >= fp.MAX_ORDER);

            var result: [fp.MAX_ORDER]u64 = @splat(0);
            var result_iter: @This() = .{ .iterator = iterator, .prev_samples = undefined };

            if (!check_range) {
                for (0..fp.MAX_ORDER) |iteration| {
                    const sample = iterator.next().?;
                    result[0] += @abs(sample);
                    for (1..iteration + 1) |order|
                    result[order] += @abs(fp.calcResidual(sample, result_iter.prev_samples, order));
                    result_iter.prev_samples =
                    std.simd.shiftElementsRight(result_iter.prev_samples, 1, sample);
                }
            } else {
                for (0..fp.MAX_ORDER) |iteration| {
                    const sample = iterator.next().?;

                    if (fp.inRange(sample))
                        result[0] += @abs(sample)
                    else result[0] = std.math.maxInt(u49);

                    for (1..iteration + 1) |order| {
                        const residual = fp.calcResidual(sample, result_iter.prev_samples, order);
                        if (fp.inRange(residual))
                            result[order] += @abs(residual)
                        else result[order] = std.math.maxInt(u49);
                    }
                    result_iter.prev_samples =
                    std.simd.shiftElementsRight(result_iter.prev_samples, 1, sample);
                }
            }

            return .{ result_iter, result };
        }

        pub fn next(self: *@This(), comptime check_range: bool) ?[5]?i32 {
            const sample = self.iterator.next() orelse return null;
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

/// SampleIter interface \
/// \
/// implemented: \
/// `next(*self) ?SampleT` \
/// `peek(self) ?SampleT` \
/// `reset(*self) void` \
/// `len u16`
pub fn SampleIter(SampleT: type) type {
    std.debug.assert(SampleT == i32 or SampleT == i64);
    return struct {
        iterator: *anyopaque,
        nextFn: *const fn (*anyopaque) ?SampleT,
        peekFn: *const fn (*anyopaque) ?SampleT,
        resetFn: *const fn (*anyopaque) void,
        len: u16,

        /// Interface maker
        pub fn init(
            Iterator: type,
            iterator: *Iterator,
            comptime nextFn: *const fn (*Iterator) ?SampleT,
            comptime peekFn: *const fn (Iterator) ?SampleT,
            comptime resetFn: *const fn (*Iterator) void,
            len: u16,
        ) @This() {
            const Impl = struct {
                pub fn next(self: *anyopaque) ?SampleT {
                    const iter: *Iterator = @ptrCast(@alignCast(self));
                    return nextFn(iter);
                }
                pub fn peek(self: *anyopaque) ?SampleT {
                    const iter: *Iterator = @ptrCast(@alignCast(self));
                    return peekFn(iter.*);
                }

                pub fn reset(self: *anyopaque) void {
                    const iter: *Iterator = @ptrCast(@alignCast(self));
                    return resetFn(iter);
                }
            };

            return .{
                .iterator = @ptrCast(@alignCast(iterator)),
                .nextFn = Impl.next,
                .peekFn = Impl.peek,
                .resetFn = Impl.reset,
                .len = len,
            };
        }

        /// Return ResidualIter with applyed coefficients and prev_samples \
        /// return `null` when iterator's samples are less than `order`
        pub fn fixedResidualIter(self: @This(), order: u8) ?FixedResidualIter(SampleT) {
            std.debug.assert(self.len >= order);
            var prev_samples: @Vector(4, i64) = undefined;
            for (1..order + 1) |i| {
                prev_samples[order - i] = @intCast(self.next() orelse return null);
            }
            return .{
                .iterator = self,
                .prev_samples = prev_samples,
                .order = order,
            };
        }

        /// Retreive next sample and increment idx
        pub fn next(self: @This()) ?SampleT {
            return self.nextFn(self.iterator);
        }

        /// Peek next sample WITHOUT incrementing idx
        pub fn peek(self: @This()) ?SampleT {
            return self.peekFn(self.iterator.*);
        }

        pub fn reset(self: @This()) void {
            return self.resetFn(self.iterator);
        }
    };
}

/// ResidualIter interface \
/// \
/// implemented: \
/// `next(self) ResidualRangeError!?i32` \
/// `peek(self) ResidualRangeError!?i32`
pub const ResidualIter = struct {
    iterator: *anyopaque,
    nextFn: *const fn (*anyopaque) ResidualRangeError!?i32,
    peekFn: *const fn (*anyopaque) ResidualRangeError!?i32,

    pub fn init(
        Iterator: type,
        iterator: *Iterator,
        comptime nextFn: *const fn (*Iterator) ResidualRangeError!?i32,
        comptime peekFn: *const fn (Iterator) ResidualRangeError!?i32,
    ) @This() {
        const Impl = struct {
            pub fn next(self: *anyopaque) ResidualRangeError!?i32 {
                const iter: *Iterator = @ptrCast(@alignCast(self));
                return nextFn(iter);
            }

            pub fn peek(self: *anyopaque) ResidualRangeError!?i32 {
                const iter: *Iterator = @ptrCast(@alignCast(self));
                return peekFn(iter.*);
            }
        };

        return .{
            .iterator = @ptrCast(@alignCast(iterator)),
            .nextFn = Impl.next,
            .peekFn = Impl.peek,
        };
    }

    pub fn next(self: @This()) ResidualRangeError!?i32 {
        return self.nextFn(self.iterator);
    }

    pub fn peek(self: @This()) ResidualRangeError!?i32 {
        return self.peekFn(self.iterator);
    }
};

// -- Error --

const ResidualRangeError = error{
    /// When residual > maxInt(i32) or <= minInt(i32)
    OutOfRange,
};

test "u8 to i8" {
    const a_: i8 = @bitCast(@as(u8, 255));
    const a: i8 = @intCast(@as(i16, @as(u8, @bitCast(a_))) - 128);
    try std.testing.expectEqual(a, 127);

    const b_: i8 = @bitCast(@as(u8, 0));
    const b: i8 = @intCast(@as(i16, @as(u8, @bitCast(b_))) - 128);
    try std.testing.expectEqual(b, -128);

    const c_: i8 = @bitCast(@as(u8, 128));
    const c: i8 = @intCast(@as(i16, @as(u8, @bitCast(c_))) - 128);
    try std.testing.expectEqual(c, 0);
}
