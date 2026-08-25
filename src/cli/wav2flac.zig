const std = @import("std");

const flac = @import("flac");

const Md5 = flac.Md5;
const WavReader = flac.WavReader;

/// Main function for WAV to FLAC
pub fn main(
    gpa: std.mem.Allocator,
    io: std.Io,
    input: []const u8,
    output: []const u8,
) !void {
    const in_file = try std.Io.Dir.cwd().openFile(io, input, .{});
    defer in_file.close(io);

    var in_buf: [4096]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    const wav: flac.WavReader = try .init(&in_reader.interface);

    var streaminfo = wav.flacStreaminfo() orelse {
        std.log.err("format: flac does not support this wav format", .{});
        std.process.exit(2);
    };

    const out_file = try std.Io.Dir.cwd().createFile(io, output, .{});
    defer out_file.close(io);

    var out_buf: [4096]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    // Flac File Writer
    // var flac_enc: flac.Encoder = .{ .writer = &out_writer.interface };
    // try flac_enc.initSamples(gpa, streaminfo.bit_depth, option.frame_size);
    var flac_enc: flac.Encoder = try .init(
        gpa,
        &out_writer.interface,
        .default(streaminfo.channels, streaminfo.bit_depth),
    );
    defer flac_enc.deinit(gpa);

    // Skip Signature and Streaminfo
    try flac_enc.skipHeader();

    try flac_enc.writeVorbisComment(true);

    // Start Encoding flac
    try switch (streaminfo.bit_depth) {
        4...32 => encode(gpa, &streaminfo, wav, &flac_enc),
        else => unreachable,
    };

    // Always flush BufferedWriter after writing
    try out_writer.interface.flush();
    // Seek back and write Signature and Streaminfo
    flac_enc.finalizeStreamInfoMd5(&streaminfo);
    try out_writer.seekTo(0);
    try flac_enc.writeHeader(streaminfo, false);
    try out_writer.interface.flush();
}

/// Encoding frames and samples
fn encode(
    gpa: std.mem.Allocator,
    streaminfo: *flac.metadata.StreamInfo,
    wav: WavReader,
    flac_enc: *flac.Encoder,
) !void {
    const frame_size = 4096;

    const sample_buf = try gpa.alloc(u8, frame_size * wav.channels * wav.bytes_per_sample);
    defer gpa.free(sample_buf);

    var frame_idx: u36 = 0;
    var remain_samples_count: usize = wav.samples_count;
    while (remain_samples_count > 0) : (frame_idx += 1) {
        const read_count = @min(frame_size, remain_samples_count);
        const samples_read = try wav.fillSamples(sample_buf, read_count, flac_enc.samples, &flac_enc.md5);
        if (samples_read == 0) break;
        remain_samples_count -= samples_read;

        const bytes_written =
            try flac_enc.writeFrame(
                frame_idx,
                .{
                    .bit_depth = streaminfo.bit_depth,
                    .channels = streaminfo.channels,
                    .samples_count = @intCast(samples_read),
                    .sample_rate = streaminfo.sample_rate,
                },
            );

        // Update min/max framesize in streaminfo
        streaminfo.updateFrameSize(bytes_written);
    }
}
