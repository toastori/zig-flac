const std = @import("std");
const tracy = @import("tracy");
const metadata = @import("metadata.zig");
const rice_code = @import("rice_code.zig");
const fixed_prediction = @import("fixed_prediction.zig");

const FrameWriter = @import("FrameWriter.zig");
const MultiChannelIter = @import("sample_iter.zig").MultiChannelIter;
const SingleChannelIter = @import("sample_iter.zig").SingleChannelIter;
const SampleIter = @import("sample_iter.zig").SampleIter;

// -- Constants --

const FlacEncoder = @This();

/// Amount of bytes to skip when skipping Header
/// so you can seek to 0 and write it after calculating
/// MD5 checksums
// Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
pub const HEADER_SIZE = 4 + 1 + 3 + 34;

// -- Members --

// Settings
lpc: Setting.LPC = .fixed,
stereo: Setting.Stereo = .auto,
// value [1, 32] ([1, 12] for subset when sample_rate <= 48k)
min_lpc_order: u8 = 0,
max_lpc_order: u8 = 0,
// value [0, 30] (each increase oubles search time)
lpc_round_var: u8 = 0,
// value [0, 15] ([0, 8] for subset)
max_fixed_rice_order: u8 = 8,
max_lpc_rice_order: u8 = 8,

// Context
writer: std.io.AnyWriter,

// -- Initializer --

pub fn init(writer: std.io.AnyWriter) !@This() {
    return .{
        .writer = writer,
    };
}

// -- Methods --

/// Write a frame from `MultiChannelIter` with block__size specified \
/// \
/// return:
/// - `Bytes of frame` for updating stream info
/// - `Error` when writing
pub fn writeFrame(
    self: *@This(),
    allocator: std.mem.Allocator,
    samples_iter: MultiChannelIter,
    frame_idx: u36,
    streaminfo: metadata.StreamInfo,
    frame_size: u16,
) !u24 {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.writeFrame" });
    defer tracy_zone.end();

    std.debug.assert(frame_size != 0);
    std.debug.assert(samples_iter.len != 0);

    var fwriter: FrameWriter = .init(self.writer);

    const stereo_mode: StereoType = if (streaminfo.channels == 2 and self.stereo != .indep)
        chooseStereoMethod(samples_iter, frame_size)
    else
        .LeftRight;

    // Write header start
    try fwriter.writeHeader(
        true,
        frame_size,
        0,
        if (stereo_mode == .LeftRight)
            .simple(streaminfo.channels)
        else
            @enumFromInt(@intFromEnum(stereo_mode) + 7),
        0,
        frame_idx,
    );

    // Write a subframe per channel
    switch (stereo_mode) {
        .LeftRight => for (0..streaminfo.channels) |i| {
            var samples = samples_iter.singleChannelIter(@intCast(i), frame_size);
            try self.writeChannelSubframe(i32,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth);
        },
        .LeftSide => { // Left
            var samples = samples_iter.singleChannelIter(0, frame_size);
            try self.writeChannelSubframe(i32,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth);
        },
        .MidSide => { // Mid
            var samples = samples_iter.midChannelIter(frame_size);
            try self.writeChannelSubframe(i32,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth);
        },
        else => {},
    }

    if (stereo_mode != .LeftRight) { // Side
        if (streaminfo.bit_depth < 32) {
            var samples = samples_iter.sideChannelIter(i32, frame_size);
            try self.writeChannelSubframe(i32,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth + 1);
        } else {
            var samples = samples_iter.sideChannelIter(i64, frame_size);
            try self.writeChannelSubframe(i64,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth + 1);
        }
    }

    if (stereo_mode == .SideRight) { // Right
        var samples = samples_iter.singleChannelIter(1, frame_size);
        try self.writeChannelSubframe(i32,allocator,samples.sampleIter(),&fwriter,streaminfo.bit_depth);
    }

    try fwriter.flushBytes(.only16);

    // Close subframe
    try fwriter.writeCrc16();

    return fwriter.bytes_written;
}

fn writeChannelSubframe(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
    samples: SampleIter(SampleT),
    fwriter: *FrameWriter,
    sample_size: u6,
) !void {
    const subframe_type = try self.chooseSubframeEncoding(
    SampleT,
    allocator,
    sample_size,
    samples,
    );

    samples.reset();
    switch (subframe_type) {
        .Constant => try fwriter.writeConstantSubframe(sample_size, samples.peek().?),
        .Verbatim => try fwriter.writeVerbatimSubframe(SampleT, sample_size, samples),
        .Fixed => |f| {
            defer allocator.free(f.residuals);
            try fwriter.writeFixedSubframe(sample_size, f.residuals, f.order, f.rice_config);
        },
        // else => unreachable, // TODO
    }
}

// Copy from flake
/// Channels must be 2
fn chooseStereoMethod(
    samples: MultiChannelIter,
    frame_size: u16,
) StereoType {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.chooseStereoMethod" });
    defer tracy_zone.end();

    std.debug.assert(samples.channels == 2);

    var sum: [4]u64 = .{ 0, 0, 0, 0 };
    const LEFT, const RIGHT, const MID, const SIDE = .{ 0, 1, 2, 3 };

    var left_samples = samples.singleChannelIter(LEFT, frame_size);
    var right_samples = samples.singleChannelIter(RIGHT, frame_size);

    var left_preds = left_samples.sampleIter().fixedResidualIter(2).?;
    var right_preds = right_samples.sampleIter().fixedResidualIter(2).?;

    while (left_preds.next()) |left_tmp| {
        const left: i64 = left_tmp;
        const right: i64 = right_preds.next().?;

        sum[LEFT] += @abs(left);
        sum[RIGHT] += @abs(right);
        sum[MID] += @abs(left + right >> 1);
        sum[SIDE] += @abs(left - right);
    }
    for (&sum) |*s| {
        _, const bits = rice_code.findOptimalParamEstimate(2 * s.*, frame_size);
        s.* = bits;
    }

    const score: [4]u64 = .{
        sum[LEFT] + sum[RIGHT], // Left Right
        sum[LEFT] + sum[SIDE], // Left Side
        sum[RIGHT] + sum[SIDE], // Side Right
        sum[MID] + sum[SIDE], // Mid Side
    };

    return @enumFromInt(std.mem.indexOfMin(u64, &score));
}

fn chooseSubframeEncoding(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
    sample_size: u8,
    samples: SampleIter(SampleT),
) !SubframeType {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.chooseSingleChannelSubframeEncoding" });
    defer tracy_zone.end();

    // -- Constant -- (First priority)
    constant: {
        const first_sample: SampleT = samples.next().?;
        while (samples.next()) |sample| {
            if (sample != first_sample) break :constant;
        }
        return .{ .Constant = {} };
    }

    // -- Verbatim -- (Least priority)
    if (samples.len <= fixed_prediction.MAX_ORDER) return .{ .Verbatim = {} };

    const verbatim_size: usize = @as(usize, samples.len) * @bitSizeOf(SampleT);
    var subframe_type: SubframeType = .{ .Verbatim = {} }; // Default fallback to Verbatim

    // -- Fixed Prediction --
    samples.reset();
    const best_fixed_order = (if (sample_size < 28)
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            false,
        )
    else
        fixed_prediction.bestOrder(
            SampleT,
            samples,
            true,
        )) orelse return subframe_type;

    // Prepare residuals
    const residuals = try allocator.alloc(i32, samples.len);
    samples.reset();
    var res_iter = samples.fixedResidualIter(best_fixed_order).?;
    for (1..best_fixed_order + 1) |order| {
        residuals[order - 1] = @intCast(res_iter.prev_samples[best_fixed_order - order]);
    }
    var i: usize = best_fixed_order;
    while (res_iter.next()) |res| : (i += 1) {
        residuals[i] = res;
    }

    const fixed_size, const rice_config = rice_code.calcRiceParamFixed(
        residuals,
        0,
        self.max_fixed_rice_order,
        sample_size,
        best_fixed_order,
    );
    if (fixed_size < verbatim_size) {
        subframe_type = .{ .Fixed = .{
            .order = best_fixed_order,
            .residuals = residuals,
            .rice_config = rice_config,
        } };
    } else {
        allocator.free(residuals);
    }

    return subframe_type;
}

/// Skip signature and Streaminfo by writing 0s \
/// Expect file cursor at 0 \
/// Might be faster than `file.seekTo` while saving a syscall?
pub fn skipHeader(self: *@This()) !void {
    // Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
    try self.writer.writeByteNTimes(0, HEADER_SIZE);
}

/// Write Signature and Streaminfo \
/// Expect file cursor at 0
pub fn writeHeader(self: *@This(), streaminfo: metadata.StreamInfo, is_last_metadata: bool) !void {
    // Write Signature
    try self.writer.writeAll("fLaC");

    // Write Streaminfo Block Header
    try self.writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .StreamInfo });
    try self.writer.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try self.writer.writeAll(&streaminfo.bytes());
}

/// Write Vendor and Vorbis Comments
pub fn writeVorbisComment(self: *@This(), is_last_metadata: bool) !void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    // Write VorbisComment Block Header
    try self.writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .VorbisComment });
    try self.writer.writeInt(u24, @intCast(vendor.len + 8), .big); // vendor len + vendor_len len(4) + tags_len len(4)
    // Write vendor string
    try self.writer.writeInt(u32, @intCast(vendor.len), .little);
    try self.writer.writeAll(vendor);
    // Write comments
    try self.writer.writeInt(u32, 0, .little); // tags len (4 bytes) (no tag now)
}

// -- Types --

pub const Setting = struct {
    pub const LPC = enum {
        none, fixed, // TODO
    };

    pub const Stereo = enum {
        indep, mid_side, auto,
    };
};

const StereoType = enum(u8) {
    LeftRight = 0,
    LeftSide = 1,
    SideRight = 2,
    MidSide = 3,
};

const SubframeType = union(enum) {
    Constant: void,
    Verbatim: void,
    Fixed: struct {
        order: u8,
        residuals: []i32, // need free
        rice_config: rice_code.RiceConfig,
    },
    // Linear: struct {
    //     order: u8,
    //     rice_order: u8 = undefined,
    //     partition_order: u8 = undefined,
    //     residuals: []isize, // need free
    // },
};
