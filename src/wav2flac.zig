const std = @import("std");
const tracy = @import("tracy");
const option = @import("option");

const flac = @import("flac");

const WavReader = @import("WavReader.zig");

pub const BufferedWriter = std.io.BufferedWriter(option.buffer_size, std.fs.File.Writer);

/// Main function for WAV to FLAC
pub fn main(
    filename: []const u8,
    allocator: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: WavReader,
) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buffered_writer: BufferedWriter = .{.unbuffered_writer = file.writer()};

    // Flac File Writer
    var flac_enc: flac.Encoder = .{ .writer = buffered_writer.writer().any() };
    try flac_enc.initSamples(allocator, streaminfo.bit_depth, option.frame_size);
    defer flac_enc.deinit(allocator, streaminfo.bit_depth);

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

/// Encoding frames and samples
fn encode(
    allocator: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: WavReader,
    flac_enc: *flac.Encoder,
) !std.crypto.hash.Md5 {
    var md5 = std.crypto.hash.Md5.init(.{});

    const wav_sample_buf = try allocator.alloc(u8, option.frame_size * wav.channels * wav.bytes_per_sample);
    defer allocator.free(wav_sample_buf);
    const big_samples = try allocator.alloc(i32, option.frame_size * wav.channels);
    defer allocator.free(big_samples);
    var arr_samples = blk: {
        var result: [8][]i32 = undefined;
        for (0..wav.channels) |i|
            result[i] = big_samples[(i * option.frame_size)..(i + 1) * option.frame_size];
        break :blk result;
    };
    const samples = arr_samples[0..wav.channels];

    var frame_idx: u36 = 0;
    while (true) : (frame_idx += 1) {
        const samples_read = (try wav.fillSamplesMd5(wav_sample_buf, option.frame_size, samples, &md5)) orelse break;

        const frame_bytes =
            try flac_enc.writeFrame(allocator, samples_read, frame_idx, streaminfo.*);

        // Update min/max framesize in streaminfo
        streaminfo.updateFrameSize(frame_bytes);
    }

    return md5;
}