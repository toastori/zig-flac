
const std = @import("std");
const option = @import("option");

const flac = @import("flac");

const Md5 = @import("Md5.zig");
const WavReader = @import("WavReader.zig");

/// Main function for WAV to FLAC
pub fn main(
    allocator: std.mem.Allocator,
    io: std.Io,
    filename: []const u8,
    streaminfo: *flac.metadata.StreamInfo,
    wav: WavReader,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    
    var out_buf: [option.buffer_size]u8 = undefined;
    var file_writer = file.writer(io, &out_buf);

    // Flac File Writer
    // var flac_enc: flac.Encoder = .{ .writer = &file_writer.interface };
    // try flac_enc.initSamples(allocator, streaminfo.bit_depth, option.frame_size);
    const flac_enc: flac.Encoder = try .init(allocator, &file_writer.interface, .default(streaminfo.channels), streaminfo.bit_depth);
    defer flac_enc.deinit(allocator, streaminfo.bit_depth);

    // Skip Signature and Streaminfo
    try flac_enc.skipHeader();

    try flac_enc.writeVorbisComment(true);

    // Start Encoding flac
    var md5: Md5.Ctx = try switch (streaminfo.bit_depth) {
        4...32 => encode(allocator, streaminfo, wav, flac_enc),
        else => unreachable,
    };

    // Always flush BufferedWriter after writing
    try file_writer.interface.flush();
    // Seek back and write Signature and Streaminfo
    md5.final(&streaminfo.md5);
    try file_writer.seekTo(0);
    try flac_enc.writeHeader(streaminfo.*, false);
    try file_writer.interface.flush();
}

/// Encoding frames and samples
fn encode(
    allocator: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: WavReader,
    flac_enc: flac.Encoder,
) !Md5.Ctx {
    var md5: Md5.Ctx = Md5.init();

    const wav_sample_buf = try allocator.alloc(u8, option.frame_size * wav.channels * wav.bytes_per_sample);
    defer allocator.free(wav_sample_buf);

    var frame_idx: u36 = 0;
    var remain_samples_count: usize = wav.samples_count;
    while (remain_samples_count > 0) : (frame_idx += 1) {
        const read_samples = @min(option.frame_size, remain_samples_count);
        const samples_read = try wav.fillSamplesMd5(wav_sample_buf, read_samples, flac_enc.samples, &md5);
        if (samples_read == 0) break;
        remain_samples_count -= samples_read;

        const bytes_written =
            try flac_enc.writeFrame(samples_read, frame_idx, streaminfo.*);

        // Update min/max framesize in streaminfo
        streaminfo.updateFrameSize(bytes_written);
    }

    return md5;
}
