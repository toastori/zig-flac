const std = @import("std");
const endian = @import("builtin").cpu.arch.endian();

const BLOCK_SIZE = @import("option").frame_size;

const FlacStreaminfo = @import("flac").metadata.StreamInfo;

// -- Members --

/// WAV file
reader: *std.Io.Reader,

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
pub inline fn init(reader: *std.Io.Reader) !@This() {
    var result: @This() = .{
        .reader = reader,
    };
    try result.getFmt();
    return result;
}

// -- Methods --

/// Fill dest with `samples` amount of samples on each channels
/// or less when reached end of stream \
/// Length of dest's referenced slice might be modified end of stream \
/// \
/// return:
/// - `dest` for easier to work with, since its length might be modified
/// - `null` when no samples to read
/// - `StreamError.IncompleteStream` when bytes of sample does not fill up all bytes of all channels
pub fn fillSamplesMd5(self: @This(), buffer: []u8, samples: usize, dest: [][]i32, md5: *std.crypto.hash.Md5) !?[][]i32 {
    std.debug.assert(dest[0].len >= samples);
    std.debug.assert(buffer.len >= samples * self.bytes_per_sample * self.channels);
    const shift_amt: u5 = @intCast(32 - self.bit_depth);

    const bytes_read = try self.reader.readSliceShort(buffer[0 .. samples * self.bytes_per_sample * self.channels]);
    if (bytes_read == 0) {
        return null;
    } else if (bytes_read % (self.channels * self.bytes_per_sample) != 0)
        return StreamError.IncompleteStream;

    const bytes = buffer[0..bytes_read];
    const samples_read = bytes_read / (self.bytes_per_sample * self.channels);

    md5.update(bytes);

    self.bytesToSample(bytes, dest);

    const result = dest;
    for (result) |*channel| {
        channel.* = channel.*[0..samples_read];
    }

    // Unsigned to signed
    if (self.bytes_per_sample == 1) {
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
    if (!std.mem.eql(u8, try self.reader.takeArray(4), "RIFF"))
        return EncodingError.NotRiffFile;
    try self.reader.discardAll(4); //Chunk Size
    if (!std.mem.eql(u8, try self.reader.takeArray(4), "WAVE"))
        return EncodingError.NotWaveFile;
    // Format info
    if (!std.mem.eql(u8, try self.reader.takeArray(4), "fmt "))
        return EncodingError.InvalidSubchunkHeader;
    try self.reader.discardAll(4); // fmt size
    const codec: enum(u16) { PCM = 1, PCM_EXTEND = 0xfffe } = switch (try self.reader.takeInt(u16, .little)) {
        1, 0xfffe => |c| @enumFromInt(c),
        else => return EncodingError.UnsupportCodec,
    };
    // Data spec
    self.channels = try self.reader.takeInt(u16, .little);
    self.sample_rate = try self.reader.takeInt(u32, .little);
    const byte_rate: u32 = try self.reader.takeInt(u32, .little);
    const block_align = try self.reader.takeInt(u16, .little);
    self.bit_depth = switch (try self.reader.takeInt(u16, .little)) {
        4...32 => |d| d,
        else => return EncodingError.UnsupportBitDepth,
    };
    self.bytes_per_sample = @intCast(block_align / self.channels);
    if (byte_rate != self.sample_rate * self.channels * self.bytes_per_sample)
        return EncodingError.BitRateUnmatch;
    if (codec == .PCM_EXTEND) {
        // Extension block size(2)
        try self.reader.discardAll(2);
        // Valid Bits per Sample(2)
        self.bit_depth = try self.reader.takeInt(u16, .little);
        // Channel Mask(4)
        // Subformat(16)
        try self.reader.discardAll(4 + 16);
    }
    // Skip unknown subchunks until "data"
    // 4 bytes tag always follow u32le length of subchunk
    while (!std.mem.eql(
        u8,
        self.reader.takeArray(4) catch return EncodingError.DataNotFound,
        "data",
    )) {
        try self.reader.discardAll(try self.reader.takeInt(u32, .little));
    }

    const data_len: u32 = try self.reader.takeInt(u32, .little);
    if (data_len % block_align != 0)
        return EncodingError.InvalidDataLen;

    self.samples_count = data_len / (self.channels * (self.bit_depth / 8));
}

fn bytesToSample(self: @This(), bytes: []const u8, dest: []const []i32) void {
    switch (self.bit_depth) {
        4, 8 => { // 1 byte
            switch (self.channels) {
                1 => _bytesToSamples(1, 1, bytes, dest),
                2 => _bytesToSamples(2, 1, bytes, dest),
                3 => _bytesToSamples(3, 1, bytes, dest),
                4 => _bytesToSamples(4, 1, bytes, dest),
                5 => _bytesToSamples(5, 1, bytes, dest),
                6 => _bytesToSamples(6, 1, bytes, dest),
                7 => _bytesToSamples(7, 1, bytes, dest),
                8 => _bytesToSamples(8, 1, bytes, dest),
                else => unreachable,
            }
        },
        12, 16 => { // 2 bytes
            switch (self.channels) {
                1 => _bytesToSamples(1, 2, bytes, dest),
                2 => _bytesToSamples(2, 2, bytes, dest),
                3 => _bytesToSamples(3, 2, bytes, dest),
                4 => _bytesToSamples(4, 2, bytes, dest),
                5 => _bytesToSamples(5, 2, bytes, dest),
                6 => _bytesToSamples(6, 2, bytes, dest),
                7 => _bytesToSamples(7, 2, bytes, dest),
                8 => _bytesToSamples(8, 2, bytes, dest),
                else => unreachable,
            }
        },
        20, 24 => { // 3 bytes
            switch (self.channels) {
                1 => _bytesToSamples(1, 3, bytes, dest),
                2 => _bytesToSamples(2, 3, bytes, dest),
                3 => _bytesToSamples(3, 3, bytes, dest),
                4 => _bytesToSamples(4, 3, bytes, dest),
                5 => _bytesToSamples(5, 3, bytes, dest),
                6 => _bytesToSamples(6, 3, bytes, dest),
                7 => _bytesToSamples(7, 3, bytes, dest),
                8 => _bytesToSamples(8, 3, bytes, dest),
                else => unreachable,
            }
        },
        32 => { // 4 bytes
            switch (self.channels) {
                1 => _bytesToSamples(1, 4, bytes, dest),
                2 => _bytesToSamples(2, 4, bytes, dest),
                3 => _bytesToSamples(3, 4, bytes, dest),
                4 => _bytesToSamples(4, 4, bytes, dest),
                5 => _bytesToSamples(5, 4, bytes, dest),
                6 => _bytesToSamples(6, 4, bytes, dest),
                7 => _bytesToSamples(7, 4, bytes, dest),
                8 => _bytesToSamples(8, 4, bytes, dest),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

fn _bytesToSamples (channels: comptime_int, bytes_depth: comptime_int, bytes: []const u8, dest: []const []i32) void {
    const samples_read = bytes.len / (bytes_depth * channels);
    const sample_bytes_start = 4 - bytes_depth;
    var b: usize = 0;
    for (0..samples_read) |i| {
        inline for (0..channels) |ch| {
            const sample_bytes: *[4]u8 = @alignCast(@ptrCast(&dest[ch][i]));
            inline for (sample_bytes_start..4) |s_b| {
                sample_bytes[s_b] = bytes[b];
                b += 1;
            }
            dest[ch][i] = std.mem.nativeToLittle(i32, dest[ch][i]);
        }
    }
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
