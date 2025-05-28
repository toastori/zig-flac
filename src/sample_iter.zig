const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const mode = @import("builtin").mode;

const WavReader = @import("WavReader.zig");

const LEN_PER_CHANNEL = std.math.maxInt(u16);

/// Iterator of multiple channel (for writing) \
/// Call `singleChannelIter()` for single channel reading
pub const MultiChannelIter = struct {
    /// Slice of allocated buffer
    big_samples: []i32,
    /// Channel separated samples in queue \
    /// Since flac's max channel count is 8, an array of 8 slice saved an allocation while sacrificing very little memory
    /// (since we don't need several instance of MultiChannelIter)
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

    /// Fill the iterator with WAV bytes reading from file \
    /// Assume file cursor aligned to the sample of first channel's first byte, and the file is a correct WAV file \
    /// \
    /// return `false` if reader reach end of stream
    pub fn wavFill(
        self: *@This(),
        wav: *WavReader,
        md5: *std.crypto.hash.Md5,
        channels_count: u8,
    ) !void {
        // Tracy
        const tracy_zone = tracy.beginZone(@src(), .{ .name = "MultiSampleIter.wavFill" });
        defer tracy_zone.end();

        if (mode == .Debug) std.debug.assert(self.channel_count == self.channel_count);

        while (self.len < LEN_PER_CHANNEL) : (self.len += 1) {
            for (0..channels_count) |i| {
                const sample = wav.nextSampleMd5(md5) orelse {
                    if (i != 0) {
                        @branchHint(.unlikely);
                        std.log.err("input: incomplete stream", .{});
                        std.process.exit(3);
                    }
                    return;
                };
                self.channel_samples[i][self.start +% self.len] = sample;
            }
        }
    }

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

/// Read residuals after FixedPrediction
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

        pub fn next(self: *@This()) ResidualRangeError!?i32 {
            const sample = self.iterator.next() orelse return null;
            const residual = fp.calcResidual(sample, self.prev_samples, self.order);
            self.prev_samples = std.simd.shiftElementsRight(self.prev_samples, 1, sample);
            if (residual <= std.math.minInt(i32) or residual > std.math.maxInt(i32))
                return ResidualRangeError.OutOfRange;
            return @intCast(residual);
        }

        pub fn peek(self: @This()) ?i32 {
            const sample = self.iterator.peek() orelse return null;
            return fp.calcResidual(sample, self.prev_samples, self.order);
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
