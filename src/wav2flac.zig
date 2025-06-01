const std = @import("std");
const tracy = @import("tracy");
const option = @import("option");

const flac = @import("flac");

const WavReader = @import("WavReader.zig");

pub const BufferedWriter = std.io.BufferedWriter(option.buffer_size, std.fs.File.Writer);

/// Main function for encoding flac from WAV file
pub fn main(
    filename: []const u8,
    allocator: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: *WavReader,
) !void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "FlacEncoder.wavMain" });
    defer tracy_zone.end();

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buffered_writer: BufferedWriter = .{.unbuffered_writer = file.writer()};

    // Flac File Writer
    var flac_enc = try flac.Encoder.init(buffered_writer.writer().any());

    // Skip Signature and Streaminfo
    try flac_enc.skipHeader();

    try flac_enc.writeVorbisComment(true);

    // Start Encoding flac
    var md5: std.crypto.hash.Md5 = try switch (streaminfo.bit_depth) {
        4...32 => encode(allocator, streaminfo, wav, &flac_enc),
        else => unreachable,
    };

    // Always flush BufferedWriter after writing
    try buffered_writer.flush();
    // Seek back and write Signature and Streaminfo
    md5.final(&streaminfo.md5);
    try file.seekTo(0);
    try flac_enc.writeHeader(streaminfo.*, false);
    try buffered_writer.flush();
}

/// Sample size independent encoding from WAV file
fn encode(
    allocator: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: *WavReader,
    flac_enc: *flac.Encoder,
) !std.crypto.hash.Md5 {
    var md5 = std.crypto.hash.Md5.init(.{});

    var samples_iter: flac.MultiChannelIter = try .init(allocator, streaminfo.channels);
    defer samples_iter.deinit(allocator);

    var frame_idx: u36 = 0;
    while (blk: {
        try samples_iter.iterFill(WavReader.nextSampleMd5, .{ wav, &md5 });
        break :blk samples_iter.len != 0;
    }) : (frame_idx += 1) {
        const blk_size = @min(4096, samples_iter.len);
        defer samples_iter.advanceStart(blk_size);

        const frame_size =
            try flac_enc.writeFrame(allocator, samples_iter, frame_idx, streaminfo.*, blk_size);

        // Update min/max framesize in streaminfo
        streaminfo.updateFrameSize(frame_size);
    }

    return md5;
}