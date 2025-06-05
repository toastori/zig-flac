const std = @import("std");
const tracy = @import("tracy");
const endian = @import("builtin").cpu.arch.endian();

const BLOCK_SIZE = @import("option").frame_size;

const FlacStreaminfo = @import("flac").metadata.StreamInfo;

// -- Members --

/// WAV file
reader: std.io.AnyReader,

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
pub inline fn init(reader: std.io.AnyReader) !@This() {
    var result: @This() = .{
        .reader = reader,
    };
    try result.getFmt();
    return result;
}

// -- Methods --

/// Get next sample \
/// \
/// return:
/// - bit extended `i32`
/// - `null` when no more samples
pub fn nextSample(self: @This()) ?i32 {
    const shift_amt: u5 = @intCast(32 - self.bit_depth);

    var sample: i32 = undefined;
    const sample_bytes = std.mem.asBytes(&sample)[4-self.bytes_per_sample..];
    self.reader.readNoEof(sample_bytes) catch return null;
    sample = std.mem.littleToNative(i32, sample);
    // unsigned to signed
    if (self.bytes_per_sample == 1)
        sample -= @as(i32, 128) >> @intCast(8 - self.bit_depth);
    // sign extend
    sample >>= shift_amt;
    return sample;
}

/// Get next sample and update MD5 \
/// \
/// return:
/// - bit extended `i32`
/// - `null` when no more samples
pub fn nextSampleMd5(self: @This(), md5: *std.crypto.hash.Md5) ?i32 {
    const shift_amt: u5 = @intCast(32 - self.bit_depth);

    var sample: i32 = undefined;
    const sample_bytes = std.mem.asBytes(&sample)[4-self.bytes_per_sample..];
    self.reader.readNoEof(sample_bytes) catch return null;
    md5.update(sample_bytes);
    sample = std.mem.littleToNative(i32, sample);
    // unsigned to signed
    if (self.bytes_per_sample == 1)
        sample -= @as(i32, 128) >> @intCast(8 - self.bit_depth);
    // sign extend
    sample >>= shift_amt;
    return sample;
}

/// Fill dest with `samples` amount of samples on each channels
/// or less when reached end of stream \
/// Length of dest's referenced slice might be modified end of stream \
/// \
/// return:
/// - `dest` for easier to work with, since its length might be modified
/// - `null` when no samples to read
/// - `StreamError.IncompleteStream` when bytes of sample does not fill up all bytes of all channels
pub fn fillSamplesMd5(self: @This(), buffer: []u8, samples: usize, dest: [][]i32, md5: *std.crypto.hash.Md5) !?[][]i32 {
    const tracy_zone = tracy.beginZone(@src(), .{ .name = "WavReader.fillSamplesMd5" });
    defer tracy_zone.end();

    std.debug.assert(dest[0].len >= samples);
    std.debug.assert(buffer.len >= samples * self.bytes_per_sample * self.channels);
    const shift_amt: u5 = @intCast(32 - self.bit_depth);
    var buf = buffer;

    const bytes_read = try self.reader.readAll(buffer[0..samples * self.bytes_per_sample * self.channels]);
    if (bytes_read == 0) {
        return null;
    } else if (bytes_read % (self.channels * self.bytes_per_sample) != 0)
        return StreamError.IncompleteStream;

    const bytes = buffer[0..bytes_read];
    const samples_read = bytes_read / (self.bytes_per_sample * self.channels);

    const tracy_md5 = tracy.beginZone(@src(), .{ .name = "MD5" });
    md5.update(bytes);
    tracy_md5.end();

    for (0..samples_read) |i| {
        for (dest) |channel| {
            const sample_bytes: []u8 = std.mem.asBytes(&channel[i])[4-self.bytes_per_sample..];
            @memcpy(sample_bytes, buf[0..self.bytes_per_sample]);
            channel[i] = std.mem.littleToNative(i32, channel[i]);

            buf = buf[self.bytes_per_sample..];
        }
    }

    const result = dest;
    for (result) |*channel| {
        channel.* = channel.*[0..samples_read];
    }

    // Unsigned to signed
    if (self.bytes_per_sample == 1){
        const sub_amt = @as(i32, 128) >> @intCast(8 - self.bit_depth);
        for (result) |ch| {
            for (ch) |*sample| {
                sample.* -= sub_amt;
            }
        }
    }

    // Sign extend
    if (self.bit_depth != 32) {
        for (result) |ch| {
            for (ch) |*sample| {
                sample.* >>= shift_amt;
            }
        }
    }

    return result;
}

/// return: \
/// - `null` when flac unsupported format
pub fn flacStreaminfo(self: @This()) ?FlacStreaminfo {
    if (self.bit_depth < 4 or self.bit_depth > 32 or
        self.channels == 0 or self.channels > 8 or
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
    };
}

/// Read WAV file header and return Flac metadata.Streaminfo without MD5 \
/// Assume file pointer is at the start of the file \
/// \
/// return: \
/// - `EofError` while reading file (possibly)
fn getFmt(self: *@This()) !void {
    // Format header
    if (!std.mem.eql(u8, &try self.reader.readBytesNoEof(4), "RIFF"))
        return EncodingError.NotRiffFile;
    try self.reader.skipBytes(4, .{}); //Chunk Size
    if (!std.mem.eql(u8, &try self.reader.readBytesNoEof(4), "WAVE"))
        return EncodingError.NotWaveFile;
    // Format info
    if (!std.mem.eql(u8, &try self.reader.readBytesNoEof(4), "fmt "))
        return EncodingError.InvalidSubchunkHeader;
    try self.reader.skipBytes(4, .{}); // fmt size
    const codec: enum(u16) { PCM = 1, PCM_EXTEND = 0xfffe } = switch (try self.reader.readInt(u16, .little)) {
        1, 0xfffe => |c| @enumFromInt(c),
        else => return EncodingError.UnsupportCodec,
    };
    // Data spec
    self.channels = try self.reader.readInt(u16, .little);
    self.sample_rate = try self.reader.readInt(u32, .little);
    const byte_rate: u32 = try self.reader.readInt(u32, .little);
    const block_align = try self.reader.readInt(u16, .little);
    self.bit_depth = switch (try self.reader.readInt(u16, .little)) {
        4...32 => |d| d,
        else => return EncodingError.UnsupportBitDepth,
    };
    self.bytes_per_sample = @intCast(block_align / self.channels);
    if (byte_rate != self.sample_rate * self.channels * self.bytes_per_sample)
        return EncodingError.BitRateUnmatch;
    if (codec == .PCM_EXTEND) {
        // Extension block size(2)
        try self.reader.skipBytes(2, .{});
        // Valid Bits per Sample(2)
        self.bit_depth = try self.reader.readInt(u16, .little);
        // Channel Mask(4)
        // Subformat(16)
        try self.reader.skipBytes(4 + 16, .{});
    }
    // Skip unknown subchunks until "data"
    // 4 bytes tag always follow u32le length of subchunk
    while (!std.mem.eql(
        u8,
        &(self.reader.readBytesNoEof(4) catch return EncodingError.DataNotFound),
        "data",
    )) {
        try self.reader.skipBytes(try self.reader.readInt(u32, .little), .{});
    }

    const data_len: u32 = try self.reader.readInt(u32, .little);
    if (data_len % block_align != 0)
        return EncodingError.InvalidDataLen;

    self.samples_count = data_len / (self.channels * (self.bit_depth / 8));
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
    /// When `sample_count % channels != 0` or
    /// `bytes_count % (bytes_per_sample * channels) != 0`
    IncompleteStream,
};
