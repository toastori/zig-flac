const std = @import("std");
const option = @import("option");
const tracy = @import("tracy");
const metadata = @import("metadata.zig");
const rice_code = @import("rice_code.zig");
const fixed_prediction = @import("fixed_prediction.zig");

const MultiChannelIter = @import("sample_iter.zig").MultiChannelIter;
const SingleChannelIter = @import("sample_iter.zig").SingleChannelIter;
const SampleIter = @import("sample_iter.zig").SampleIter;

pub const BufferedWriter = std.io.BufferedWriter(option.buffer_size, std.fs.File.Writer);
pub const FileWriter = BufferedWriter.Writer;

// -- Members --

// Settings
// value [1, 32] ([1, 12] for subset when sample_rate <= 48k)
min_lpc_order: u8 = 0,
max_lpc_order: u8 = 0,
// value [0, 30] (each increase oubles search time)
lpc_round_var: u8 = 0,
// value [0, 15] ([0, 8] for subset)
max_fixed_rice_order: u8 = 8,
max_lpc_rice_order: u8 = 8,

// Context
file: std.fs.File,
buffered_writer: BufferedWriter,

// -- Initializer --

pub fn init(filename: []const u8) !@This() {
    const file = try std.fs.cwd().createFile(filename, .{});
    return .{
        .file = file,
        .buffered_writer = .{ .unbuffered_writer = file.writer() },
    };
}

// -- Methods --

/// Write a frame from `MultiChannelIter` with block__size specified
pub fn writeFrame(
    self: *@This(),
    allocator: std.mem.Allocator,
    samples_iter: MultiChannelIter,
    frame_idx: u36,
    streaminfo: metadata.StreamInfo,
    blk_size: u16,
) !void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.writeFrame" });
    defer tracy_zone.end();

    std.debug.assert(blk_size != 0);

    var fwriter = @import("FrameWriter.zig").init(self.buffered_writer.writer().any());

    // Write header start
    try fwriter.writeHeader(
        true,
        blk_size,
        0,
        .simple(streaminfo.channels),
        0,
        frame_idx,
    );

    // Write a subframe per channel
    for (0..streaminfo.channels) |i| {
        var iter = samples_iter.singleChannelIter(@intCast(i), blk_size);
        std.debug.assert(iter.len != 0);

        const subframe_type = try self.chooseSubframeEncoding(
            i32,
            allocator,
            streaminfo.bit_depth,
            iter.sampleIter(),
        );

        switch (subframe_type) {
            .Constant => try fwriter.writeConstantSubframe(streaminfo.bit_depth, iter.peek().?),
            .Verbatim => try fwriter.writeVerbatimSubframe(i32, streaminfo.bit_depth, iter.sampleIter()),
            .Fixed => |f| {
                defer allocator.free(f.residuals);
                try fwriter.writeFixedSubframe(streaminfo.bit_depth, f.residuals, f.order, f.rice_config);
            },
            // else => unreachable, // TODO
        }
    }
    try fwriter.flushBytes(.only16);

    // Close subframe
    try fwriter.writeCrc16();
}

fn chooseSubframeEncoding(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
    bits_per_sample: u8,
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
    const best_fixed_order = (if (bits_per_sample < 28)
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

/// Skip signature and Streaminfo
pub fn skipHeader(self: *@This()) std.fs.File.SeekError!void {
    // Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
    try self.file.seekTo(4 + 1 + 3 + 34);
}

/// Write Signature and Streaminfo
pub fn writeHeader(self: *@This(), streaminfo: metadata.StreamInfo, streaminfo_is_last: bool) FileWriter.Error!void {
    const writer = self.buffered_writer.writer();
    // Write Signature
    try writer.writeAll("fLaC");

    // Write Streaminfo Block Header
    try writer.writeStruct(metadata.BlockHeader{ .is_last_block = streaminfo_is_last, .block_type = .StreamInfo });
    try writer.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try writer.writeAll(&streaminfo.bytes());
}

/// Write Vendor and Vorbis Comments
pub fn writeVorbisComment(self: *@This(), is_last_metadata: bool) FileWriter.Error!void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    const writer = self.buffered_writer.writer();
    // Write VorbisComment Block Header
    try writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .VorbisComment });
    try writer.writeInt(u24, @intCast(vendor.len + 8), .big); // vendor len + vendor_len len(4) + tags_len len(4)
    // Write vendor string
    try writer.writeInt(u32, @intCast(vendor.len), .little);
    try writer.writeAll(vendor);
    // Write comments
    try writer.writeInt(u32, 0, .little); // tags len (4 bytes) (no tag now)
}

// -- Types --

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
