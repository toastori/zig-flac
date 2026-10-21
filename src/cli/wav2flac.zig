const std = @import("std");
const Allocator = std.mem.Allocator;
const File = Io.File;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;

const flac = @import("flac");

const READ_SAMPLES = 4096;

/// Main function for WAV to FLAC
pub fn main(
    gpa: Allocator,
    io: std.Io,
    ifile_name: []const u8,
    ofile_name: []const u8,
) (Allocator.Error || File.OpenError || Reader.Error || Writer.Error || CodecError)!void {
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;

    const ifile = try std.Io.Dir.cwd().openFile(io, ifile_name, .{});
    defer ifile.close(io);
    var ireader = ifile.reader(io, &reader_buf);
    const reader = &ireader.interface;

    const format: WavFmt = try getWavFmt(reader);
    flac.Encoder.isFormatSupported(format.bit_depth, format.channels, format.sample_rate) catch
        return CodecError.UnsupportFormat;

    const ofile = try std.Io.Dir.cwd().createFile(io, ofile_name, .{});
    defer ofile.close(io);
    var owriter = ofile.writer(io, &writer_buf);
    const writer = &owriter.interface;

    // Flac File Writer
    var flac_enc: flac.Encoder = undefined;
    flac_enc.init(gpa, format.bit_depth, format.channels, format.sample_rate, .{}) catch unreachable;
    defer flac_enc.deinit();
    // Buffer reading WAV PCM
    const wav_data_buf = try gpa.alloc(u8, READ_SAMPLES * format.channels * format.bytes_per_sample);
    defer gpa.free(wav_data_buf);

    flac_enc.encodeStart(writer, &seekFn, &owriter) catch |err| return switch (err) {
        error.WrongState => @panic("wrong encoder state at encodeStart()"),
        else => |e| e,
    };
    encode(reader, wav_data_buf, &flac_enc, format) catch |err| return switch (err) {
        Reader.Error.EndOfStream => CodecError.IncompleteStream,
        error.WrongState => @panic("wrong encoder state at processWav()"),
        else => |e| e,
    };
    flac_enc.encodeFinish() catch |err| return switch (err) {
        error.WrongState => @panic("wrong encoder state at encodeFinish()"),
        else => |e| e,
    };
}

/// Encoding frames and samples
fn encode(
    reader: *Reader,
    wav_data_buf: []u8,
    flac_enc: *flac.Encoder,
    audio_format: WavFmt,
) !void {
    const bytes_per_sample = audio_format.bytes_per_sample;
    const channels = audio_format.channels;
    const samples_cnt = audio_format.sample_cnt;

    var remain_samples_count: usize = samples_cnt;
    while (remain_samples_count > 0) {
        const read_target: usize = @min(READ_SAMPLES, remain_samples_count);
        remain_samples_count -= read_target;

        const read_slice = wav_data_buf[0..read_target * channels * bytes_per_sample];
        try reader.readSliceAll(read_slice);

        flac_enc.processWav(read_slice, bytes_per_sample) catch |err| return switch (err) {
            error.InvalidBuffer => unreachable,
            else => |e| e,
        };
    }
}

fn seekFn(_: *flac.Encoder, offset: u64, ctx: *anyopaque) flac.Encoder.SeekResult {
    const file_writer: *File.Writer = @alignCast(@ptrCast(ctx));

    file_writer.seekTo(offset) catch |err| return switch (err) {
        error.Unseekable => flac.Encoder.SeekResult.unsupported,
        else => flac.Encoder.SeekResult.err,
    };
    return .ok;
}

pub const CodecError = error{
    NotRiffFile,
    NotWaveFile,
    IncompleteStream,
    /// First subchunk is not `"fmt "`
    InvalidSubchunkHeader,
    /// Data Length cannot divide by `channels * bytes_per_sample`
    InvalidDataLen,
    /// Non PCM format
    UnsupportCodec,
    /// 0 or >32 bits
    UnsupportBitDepth,
    UnsupportFormat,
    /// Either not aligned or missing
    DataNotFound,
    /// Unmatch to `sample_rate * channels * bit_depth / 8`
    BitRateUnmatch,
};

const WavFmt = struct {
    sample_cnt: u32 = undefined,
    sample_rate: u32 = undefined,
    bit_depth: u16 = undefined,
    channels: u16 = undefined,
    bytes_per_sample: u8 = undefined,
};

/// Read WAV file header and place reader at start of WAV stream \
/// Assume file pointer is at the start of the file \
/// \
/// return: \
/// - `EofError` while reading file (possibly)
fn getWavFmt(reader: *Reader) (Reader.Error || CodecError)!WavFmt {
    var wav_fmt: WavFmt = .{};
    // Format header
    if (!std.mem.eql(u8, try reader.takeArray(4), "RIFF"))
        return CodecError.NotRiffFile;
    try reader.discardAll(4); //Chunk Size
    if (!std.mem.eql(u8, try reader.takeArray(4), "WAVE"))
        return CodecError.NotWaveFile;
    // Format info
    while (!std.mem.eql(u8, try reader.take(4), "fmt ")) {
        const bytes = try reader.takeInt(u32, .little);
        try reader.discardAll(bytes);
    }
    try reader.discardAll(4); // fmt size
    const Codec = enum(u16) { PCM = 1, PCM_EXTEND = 0xfffe };
    const codec: Codec = switch (try reader.takeInt(u16, .little)) {
        1, 0xfffe => |c| @enumFromInt(c),
        else => return CodecError.UnsupportCodec,
    };
    // Data spec
    wav_fmt.channels = try reader.takeInt(u16, .little);
    wav_fmt.sample_rate = try reader.takeInt(u32, .little);
    const byte_rate: u32 = try reader.takeInt(u32, .little);
    const block_align = try reader.takeInt(u16, .little);
    wav_fmt.bit_depth = switch (try reader.takeInt(u16, .little)) {
        4...32 => |d| d,
        else => return CodecError.UnsupportBitDepth,
    };
    wav_fmt.bytes_per_sample = @intCast(@divExact(block_align, wav_fmt.channels));
    if (byte_rate != wav_fmt.sample_rate * wav_fmt.channels * wav_fmt.bytes_per_sample)
        return CodecError.BitRateUnmatch;
    if (codec == .PCM_EXTEND) {
        // Extension block size(2)
        try reader.discardAll(2);
        // Valid Bits per Sample(2)
        wav_fmt.bit_depth = try reader.takeInt(u16, .little);
        // Channel Mask(4)
        // Subformat(16)
        try reader.discardAll(4 + 16);
    }
    // Skip unknown subchunks until "data"
    // 4 bytes tag always follow u32le length of subchunk
    while (!std.mem.eql(
        u8,
        reader.takeArray(4) catch return CodecError.DataNotFound,
        "data",
    )) {
        try reader.discardAll(try reader.takeInt(u32, .little));
    }

    const data_len: u32 = try reader.takeInt(u32, .little);
    if (data_len % block_align != 0)
        return CodecError.InvalidDataLen;

    wav_fmt.sample_cnt = data_len / (wav_fmt.channels * (wav_fmt.bit_depth / 8));

    return wav_fmt;
}
