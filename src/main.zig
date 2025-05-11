const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");

const BLOCK_SIZE = 4096;

pub fn main() !void {
    var gpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}){} else {};
    defer if (@TypeOf(gpa) != void) std.log.info("gpa: {s}", .{@tagName(gpa.deinit())});
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const input = args.next();
    const output = args.next();
    if (input == null or output == null) {
        std.log.err("usage: flac in_file.wav out_file.flac", .{});
        std.process.exit(1);
    }

    try encodeFile(allocator, input.?, output.?);
}

const EncodingError = error{
    invalid_riff_file_header,
    invalid_wave_file_header,
    unrecognized_wav_file_chunk,
    unsupported_wav_file_type,
    unsupported_wav_file_codec,
    unsupported_channels,
    invalid_sample_rate,
    unsupported_sample_depth,
    invalid_sample_data_len,
};

fn encodeFile(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    const in_file = try std.fs.cwd().openFile(input, .{});
    defer in_file.close();
    const out_file = try std.fs.cwd().createFile(output, .{});
    defer out_file.close();
    var i_br = std.io.bufferedReader(in_file.reader());
    var o_bw = std.io.bufferedWriter(out_file.writer());
    const in = i_br.reader();
    const out = o_bw.writer();

    if (!std.mem.eql(u8, &try in.readBytesNoEof(4), "RIFF"))
        return error.invalid_riff_file_header;
    try in.skipBytes(4, .{}); //Chunk Size
    if (!std.mem.eql(u8, &try in.readBytesNoEof(4), "WAVE"))
        return error.invalid_wave_file_header;

    if (!std.mem.eql(u8, &try in.readBytesNoEof(4), "fmt "))
        return error.unrecognized_wav_file_chunk;
    if (try in.readInt(u32, .little) != 16)
        return error.unsupported_wav_file_type;
    if (try in.readInt(u16, .little) != 1)
        return error.unsupported_wav_file_codec;
    const channels: u16 = switch (try in.readInt(u16, .little)) {
        1...7 => |c| c,
        else => return error.unsupported_channels,
    };
    const sample_rate: u32 = switch (try in.readInt(u32, .little)) {
        0...(1 << 20) => |r| r,
        else => return error.invalid_sample_rate,
    };
    try in.skipBytes(6, .{}); // bytesPerSec(4), blockAlign(2)
    const bit_depth: u16 = switch (try in.readInt(u16, .little)) {
        8, 16, 24, 32 => |d| d,
        else => return error.unsupported_sample_depth,
    };
    while (true) {
        if (try in.readByte() != 'd') continue;
        if (std.mem.eql(u8, &try in.readBytesNoEof(3), "ata")) break;
    }
    const data_len: u32 = try in.readInt(u32, .little);
    if (data_len % (channels * (bit_depth / 8)) != 0)
        return error.invalid_sample_data_len;

    var samples_count: u64 = data_len / (channels * (bit_depth / 8));
    const streaminfo: metadata.StreamInfo = .{
        .min_block_size = BLOCK_SIZE,
        .max_block_size = BLOCK_SIZE,
        .sample_rate = @truncate(sample_rate),
        .channels = @truncate(channels),
        .bit_depth = @truncate(bit_depth),
        .interchannel_samples = samples_count,
        .md5 = 0,
    };

    // Write Signature
    try out.writeAll("fLaC");
    // Write Metadata block header
    try out.writeStruct(metadata.BlockHeader{ .is_last_block = false, .block_type = .StreamInfo });
    try out.writeInt(u24, 34, .big); // bytes of metadata block
    // Write Streaminfo Metadata
    try out.writeAll(&streaminfo.bytes());

    // Write Vorbis comment
    const vendor: []const u8 = "toastori  flac v0.0";
    try out.writeStruct(metadata.BlockHeader{.is_last_block = true, .block_type = .VorbisComment});
    try out.writeInt(u24, @truncate(vendor.len + 8), .big); // vendor len + vendor_len len(4) + tags_len len(4)
    //Write vendor string
    try out.writeInt(u32, @truncate(vendor.len), .little);
    try out.writeAll(vendor);
    try out.writeInt(u32, 0, .little); // tags len (4 bytes) (no tag now)

    var md5 = std.crypto.hash.Md5.init(.{});

    // Write frames
    var idx: usize = 0;
    while (samples_count > 0) : (idx += 1) {
        const block_size = @min(BLOCK_SIZE, samples_count);
        samples_count -= block_size;
        // std.debug.print("frame#: {d}, samples count: {d}, blk_size: {d}\n", .{ idx, samples_count, block_size });
        try writeFrame(idx, in.any(), out.any(), streaminfo, block_size, allocator, &md5);
    }

    try o_bw.flush();

    // Write MD5
    var md5_bytes: [16]u8 = undefined;
    md5.final(&md5_bytes);
    try out_file.seekTo(26); // seek to start of md5 hash
    try out.writeAll(&md5_bytes);

    try o_bw.flush();
}

fn writeFrame(
    frame_idx: usize,
    in: std.io.AnyReader,
    out: std.io.AnyWriter,
    streaminfo: metadata.StreamInfo,
    blk_size: usize,
    allocator: std.mem.Allocator,
    md5: *std.crypto.hash.Md5,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arenalloc = arena.allocator();
    defer arena.deinit();

    var big_channel_samples: [8][][4]u8 = undefined; // [channels][sample]
    const channel_samples = big_channel_samples[0..streaminfo.channels];
    const big_samples = try arenalloc.alloc([4]u8, streaminfo.channels * blk_size);
    for (0..streaminfo.channels) |c| {
        big_channel_samples[c] = big_samples[c * blk_size .. (c + 1) * blk_size];
    }

    const bytes_per_sample = streaminfo.bit_depth / 8;
    for (0..blk_size) |i| {
        for (0..streaminfo.channels) |channel| {
            for (0..bytes_per_sample) |byte_idx| {
                big_channel_samples[channel][i][byte_idx] = try in.readByte();
            }
            md5.update(channel_samples[channel][i][0..bytes_per_sample]);
        }
    }

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
    for (channel_samples) |channel| {
        try fwriter.writeVerbatimSubframe(channel, streaminfo.bit_depth);
    }
    try fwriter.flushByte(.only16);

    // Close subframe
    try fwriter.writeCrc16();
}
