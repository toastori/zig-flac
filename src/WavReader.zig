const std = @import("std");
const option = @import("option");
const tracy = @import("tracy");

const BLOCK_SIZE = 4096;

pub const BufferedReader = std.io.BufferedReader(option.buffer_size, std.fs.File.Reader);
const NoEofError = BufferedReader.Reader.NoEofError;
const FlacStreaminfo = @import("flac").metadata.StreamInfo;

// -- Members --

/// WAV file
file: std.fs.File,
/// BufferedReader of `file`
buffered_reader: BufferedReader,

/// Wav formats
/// Samples per channel
samples_count: u32 = undefined,
sample_rate: u32 = undefined,
bit_depth: u16 = undefined,
channels: u16 = undefined,
bytes_per_sample: u8 = undefined,

// -- Initializer --

/// The file pointer will automatically skip to "data ready",
/// which the next byte read will be part of first sample
pub inline fn init(filename: []const u8) !@This() {
    const file = try std.fs.cwd().openFile(filename, .{});
    var result: @This() = .{
        .file = file,
        .buffered_reader = .{ .unbuffered_reader = file.reader() },
    };
    try result.getFmt();
    return result;
}

pub fn deinit(self: @This()) void {
    self.file.close();
}

// -- Methods --

/// Get next sample \
/// Samples are read as bit extended `i32`
pub fn nextSample(self: *@This()) ?i32 {
    const shift_amt: u5 = @intCast(32 - self.bit_depth);

    var sample: i32 = undefined;
    const sample_bytes = std.mem.asBytes(&sample)[4-self.bytes_per_sample..];
    self.read(sample_bytes) catch return null;
    sample = std.mem.littleToNative(i32, sample);
    // unsigned to signed
    if (self.bytes_per_sample == 1)
        sample -= @as(i32, 128) >> @intCast(8 - self.bit_depth);
    // sign extend
    sample >>= shift_amt;
    return sample;
}

/// Get next sample and update MD5 \
/// Samples are read as bit extended `i32`
pub fn nextSampleMd5(self: *@This(), md5: *std.crypto.hash.Md5) ?i32 {
    const shift_amt: u5 = @intCast(32 - self.bit_depth);

    var sample: i32 = undefined;
    const sample_bytes = std.mem.asBytes(&sample)[4-self.bytes_per_sample..];
    self.read(sample_bytes) catch return null;
    md5.update(sample_bytes);
    sample = std.mem.littleToNative(i32, sample);
    // unsigned to signed
    if (self.bytes_per_sample == 1)
        sample -= @as(i32, 128) >> @intCast(8 - self.bit_depth);
    // sign extend
    sample >>= shift_amt;
    return sample;
}

/// Return null when flac unsupported format
pub fn flacStreaminfo(self: @This()) ?FlacStreaminfo {
    if (self.bit_depth > 32 or
        self.channels > 8 or
        self.sample_rate >= 1 << 20 or
        self.samples_count >= 1 << 36) return null;
    return .{
        .sample_rate = @intCast(self.sample_rate),
        .channels = @intCast(self.channels),
        .bit_depth = @intCast(self.bit_depth),
        .interchannel_samples = self.samples_count,
        .md5 = undefined,
        .min_block_size = BLOCK_SIZE,
        .max_block_size = BLOCK_SIZE,
        .min_frame_size = 0,
        .max_frame_size = 0,
    };
}

/// Read WAV file header and return Flac metadata.Streaminfo without MD5 \
/// Assume file pointer is at the start of the file
fn getFmt(self: *@This()) (std.fs.File.Reader.NoEofError || EncodingError)!void {
    // Tracy
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "WavReader.readIntoFlacStreaminfo" });
    defer tracy_zone.end();

    // Format header
    if (!std.mem.eql(u8, &try self.readBytes(4), "RIFF"))
        return EncodingError.NotRiffFile;
    try self.skipBytes(4); //Chunk Size
    if (!std.mem.eql(u8, &try self.readBytes(4), "WAVE"))
        return EncodingError.NotWaveFile;
    // Format info
    if (!std.mem.eql(u8, &try self.readBytes(4), "fmt "))
        return EncodingError.InvalidSubchunkHeader;
    try self.skipBytes(4); // fmt size
    const codec: enum(u16) { PCM = 1, PCM_EXTEND = 0xfffe } = switch (try self.readInt(u16, .little)) {
        1, 0xfffe => |c| @enumFromInt(c),
        else => return EncodingError.UnsupportCodec,
    };
    // Data spec
    self.channels = try self.readInt(u16, .little);
    self.sample_rate = try self.readInt(u32, .little);
    const byte_rate: u32 = try self.readInt(u32, .little);
    const block_align = try self.readInt(u16, .little);
    self.bit_depth = switch (try self.readInt(u16, .little)) {
        1...32 => |d| d,
        else => return EncodingError.UnsupportBitDepth,
    };
    self.bytes_per_sample = @intCast(block_align / self.channels);
    if (byte_rate != self.sample_rate * self.channels * self.bytes_per_sample)
        return EncodingError.BitRateUnmatch;
    if (codec == .PCM_EXTEND) {
        // Extension block size(2)
        try self.skipBytes(2);
        // Valid Bits per Sample(2)
        self.bit_depth = try self.readInt(u16, .little);
        // Channel Mask(4)
        // Subformat(16)
        try self.skipBytes(4 + 16);
    }
    // Skip unknown subchunks until "data"
    // 4 bytes tag always follow u32le length of subchunk
    while (!std.mem.eql(
        u8,
        &(self.readBytes(4) catch return EncodingError.DataNotFound),
        "data",
    )) {
        try self.skipBytes(try self.readInt(u32, .little));
    }

    const data_len: u32 = try self.readInt(u32, .little);
    if (data_len % block_align != 0)
        return EncodingError.InvalidDataLen;

    self.samples_count = data_len / (self.channels * (self.bit_depth / 8));
}

// -- Reader methods --

inline fn readInt(self: *@This(), T: type, endian: std.builtin.Endian) NoEofError!T {
    return self.buffered_reader.reader().readInt(T, endian);
}

inline fn read(self: *@This(), buf: []u8) NoEofError!void {
    return self.buffered_reader.reader().readNoEof(buf);
}

inline fn readByte(self: *@This()) NoEofError!void {
    return self.buffered_reader.reader().readByte();
}

inline fn readBytes(self: *@This(), comptime num_bytes: usize) NoEofError![num_bytes]u8 {
    return self.buffered_reader.reader().readBytesNoEof(num_bytes);
}

inline fn skipBytes(self: *@This(), num_bytes: u64) NoEofError!void {
    return self.buffered_reader.reader().skipBytes(num_bytes, .{});
}

// -- Error --

pub const EncodingError = error{
    NotRiffFile,
    NotWaveFile,
    /// First subchunk is not `"fmt "`
    InvalidSubchunkHeader,
    /// Data Length cannot divide by `channels * bytes_per_sample`
    InvalidDataLen,
    /// Non PCM format
    UnsupportCodec,
    /// 0 or >32 bits
    UnsupportBitDepth,
    /// Either not aligned or missing
    DataNotFound,
    /// Unmatch to `sample_rate * channels * bit_depth / 8`
    BitRateUnmatch,
};

pub const StreamError = error{
    // When `sample_count % channel_count != 0`
    IncompleteStream,
};
