const std = @import("std");
const option = @import("option");
const tracy = @import("tracy");
const metadata = @import("metadata.zig");
const rice_code = @import("rice_code.zig");
const fixed_prediction = @import("fixed_prediction.zig");

const WavReader = @import("WavReader.zig");
const MultiChannelIter = @import("sample_iter.zig").MultiChannelIter;
const SingleChannelIter = @import("sample_iter.zig").SingleChannelIter;
const SampleIter = @import("sample_iter.zig").SampleIter;

const BufferedWriter = std.io.BufferedWriter(option.buffer_size, std.fs.File.Writer);
const FileWriter = BufferedWriter.Writer;

// -- Members --

// Settings
// value [0, 4]
min_fixed_order: u8,
max_fixed_order: u8,
// value [1, 32] ([1, 12] for subset when sample_rate <= 48k)
min_lpc_order: u8,
max_lpc_order: u8,
// value [0, 30] (each increase oubles search time)
lpc_round_var: u8,
// value [0, 15] ([0, 8] for subset)
max_fixed_rice_order: u8,
max_lpc_rice_order: u8,

// -- Initializer --

pub fn make(min_fixed_order: u8, max_fixed_order: u8, min_lpc_order: u8, max_lpc_order: u8, lpc_round_var: u8, max_fixed_rice_order: u8, max_lpc_rice_order: u8) @This() {
    return .{
        .min_fixed_order = min_fixed_order,
        .max_fixed_order = max_fixed_order,
        .min_lpc_order = min_lpc_order,
        .max_lpc_order = max_lpc_order,
        .lpc_round_var = lpc_round_var,
        .max_fixed_rice_order = max_fixed_rice_order,
        .max_lpc_rice_order = max_lpc_rice_order,
    };
}

// -- Methods --

/// Main function for encoding flac from WAV file
pub fn wavMain(
    self: @This(),
    filename: []const u8,
    allocator: std.mem.Allocator,
    streaminfo: *metadata.StreamInfo,
    wav: *WavReader,
) !void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.wavMain" });
    defer tracy_zone.end();

    // Flac File Writer
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buffered_writer: BufferedWriter = .{ .unbuffered_writer = file.writer() };
    const writer = buffered_writer.writer();

    // Skip Signature and Streaminfo
    try skipHeader(file);

    try writeVorbisComment(writer, true);

    // Start Encoding flac
    var md5: std.crypto.hash.Md5 = try switch (streaminfo.bit_depth) {
        8, 16, 24, 32 => self.wavEncode(allocator, streaminfo, wav, writer),
        else => unreachable,
    };

    // Always flush BufferedWriter after writing
    try buffered_writer.flush();
    // Seek back and write Signature and Streaminfo
    md5.final(&streaminfo.md5);
    try file.seekTo(0);
    try writeHeader(writer, streaminfo.*, false);
    try buffered_writer.flush();
}

/// Sample size independent encoding from WAV file
fn wavEncode(
    self: @This(),
    allocator: std.mem.Allocator,
    streaminfo: *metadata.StreamInfo,
    wav: *WavReader,
    writer: BufferedWriter.Writer,
) !std.crypto.hash.Md5 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var md5 = std.crypto.hash.Md5.init(.{});

    var samples_iter: MultiChannelIter = try .init(allocator, streaminfo.channels);
    defer samples_iter.deinit(allocator);

    var frame_idx: u36 = 0;
    while (blk: {
        try samples_iter.wavFill(wav, &md5, streaminfo.channels);
        break :blk samples_iter.len != 0;
    }) : (frame_idx += 1) {
        const blk_size = @min(4096, samples_iter.len);
        defer samples_iter.advanceStart(blk_size);

        try self.writeFrame(alloc, samples_iter, frame_idx, writer.any(), streaminfo.*, blk_size);
    }

    return md5;
}

/// Write a frame from `MultiChannelIter` with block__size specified
fn writeFrame(
    self: @This(),
    allocator: std.mem.Allocator,
    samples_iter: MultiChannelIter,
    frame_idx: u36,
    out: std.io.AnyWriter,
    streaminfo: metadata.StreamInfo,
    blk_size: u16,
) !void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.writeFrame" });
    defer tracy_zone.end();

    var fwriter = @import("FrameWriter.zig").init(out);

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

        const subframe_type = try self.chooseSubframeEncoding(i32, allocator, iter.sampleIter());

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

fn chooseSubframeEncoding(
    self: @This(),
    SampleT: type,
    allocator: std.mem.Allocator,
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
    if (samples.len < 5) return .{ .Verbatim = {} };

    const verbatim_size: usize = @as(usize, samples.len) * @bitSizeOf(SampleT);
    var subframe_type: SubframeType = .{ .Verbatim = {} }; // Default fallback to Verbatim

    // -- Fixed Prediction --
    std.debug.assert(self.min_fixed_order <= self.max_fixed_order);
    std.debug.assert(self.max_fixed_order < 5);

    samples.reset();
    const best_fixed = try fixed_prediction.bestOrder(
        SampleT,
        allocator,
        samples,
        self.min_fixed_order,
        self.max_fixed_order,
    ) orelse return subframe_type;

    const fixed_size, const rice_config = rice_code.calcRiceParamFixed(
        best_fixed.residuals,
        0,
        self.max_fixed_rice_order,
        best_fixed.order,
    );
    if (fixed_size < verbatim_size) {
        subframe_type = .{ .Fixed = .{
            .order = best_fixed.order,
            .residuals = best_fixed.residuals,
            .rice_config = rice_config,
        } };
    } else {
        allocator.free(best_fixed.residuals);
    }

    return subframe_type;
}

// -- Functions --

/// Skip signature and Streaminfo
fn skipHeader(file: std.fs.File) std.fs.File.SeekError!void {
    // Skip fLaC(4) + BlockHeader(1) + BlockLength(3) + Streaminfo(34)
    try file.seekTo(4 + 1 + 3 + 34);
}

/// Write Signature and Streaminfo
fn writeHeader(writer: FileWriter, streaminfo: metadata.StreamInfo, streaminfo_is_last: bool) FileWriter.Error!void {
    // Write Signature
    try writer.writeAll("fLaC");

    // Write Streaminfo Block Header
    try writer.writeStruct(metadata.BlockHeader{ .is_last_block = streaminfo_is_last, .block_type = .StreamInfo });
    try writer.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try writer.writeAll(&streaminfo.bytes());
}

/// Write Vendor and Vorbis Comments
fn writeVorbisComment(writer: FileWriter, is_last_metadata: bool) FileWriter.Error!void {
    const vendor: []const u8 = "toastori FLAC 0.0.0";
    // Write VorbisComment Block Header
    try writer.writeStruct(metadata.BlockHeader{ .is_last_block = is_last_metadata, .block_type = .VorbisComment });
    try writer.writeInt(u24, @intCast(vendor.len + 8), .big); // vendor len + vendor_len len(4) + tags_len len(4)
    // Write vendor string
    try writer.writeInt(u32, @intCast(vendor.len), .little);
    try writer.writeAll(vendor);
    // Write comments
    try writer.writeInt(u32, 0, .little); // tags len (4 bytes) (no tag now)
}
