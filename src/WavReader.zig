const std = @import("std");

const BLOCK_SIZE = 4096;

pub const BufferedReader = std.io.BufferedReader(4096, std.fs.File.Reader);
const FlacStreaminfo = @import("metadata.zig").StreamInfo;

// -- Members --

/// WAV file
file: std.fs.File,
/// BufferedReader of `file`
buffered_reader: BufferedReader,

// -- Initializer --

pub inline fn init(filename: []const u8) std.fs.File.OpenError!@This() {
    const file = try std.fs.cwd().openFile(filename, .{});
    return .{
        .file = file,
        .buffered_reader = std.io.bufferedReader(file.reader()),
    };
}

pub fn deinit(self: @This()) void {
    self.file.close();
}

// -- Methods --

/// Shorthand for `buffered_reader.reader()`
pub inline fn reader(self: *@This()) BufferedReader.Reader {
    return self.buffered_reader.reader();
}

pub const EncodingError = error{
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

/// Read WAV file header and return Flac metadata.Streaminfo without MD5 \
/// Assume file pointer is at the start of the file
pub fn readIntoFlacStreaminfo(self: *@This()) (std.fs.File.Reader.NoEofError || EncodingError)!FlacStreaminfo {
    // Format header
    if (!std.mem.eql(u8, &try self.reader().readBytesNoEof(4), "RIFF"))
        return EncodingError.invalid_riff_file_header;
    try self.reader().skipBytes(4, .{}); //Chunk Size
    if (!std.mem.eql(u8, &try self.reader().readBytesNoEof(4), "WAVE"))
        return EncodingError.invalid_wave_file_header;
    // Format info
    if (!std.mem.eql(u8, &try self.reader().readBytesNoEof(4), "fmt "))
        return EncodingError.unrecognized_wav_file_chunk;
    if (try self.reader().readInt(u32, .little) != 16)
        return EncodingError.unsupported_wav_file_type;
    if (try self.reader().readInt(u16, .little) != 1)
        return EncodingError.unsupported_wav_file_codec;
    // StreamInfo
    const channels: u16 = switch (try self.reader().readInt(u16, .little)) {
        1...7 => |c| c,
        else => return EncodingError.unsupported_channels,
    };
    const sample_rate: u32 = switch (try self.reader().readInt(u32, .little)) {
        0...(1 << 20) => |r| r,
        else => return EncodingError.invalid_sample_rate,
    };
    try self.reader().skipBytes(6, .{}); // bytesPerSec(4), blockAlign(2)
    const bit_depth: u16 = switch (try self.reader().readInt(u16, .little)) {
        8, 16, 24, 32 => |d| d,
        else => return EncodingError.unsupported_sample_depth,
    };
    { // skip until "data"
        const data = "data";
        var idx: u8 = 0;
        while (true) {
            const c = try self.reader().readByte();
            if (idx != 0) {
                if (c == data[idx]) idx += 1 else idx = 0;
            }
            if (idx == 4) break else if (idx == 0 and c == 'd') idx += 1;
        }
    }
    const data_len: u32 = try self.reader().readInt(u32, .little);
    if (data_len % (channels * (bit_depth / 8)) != 0)
        return EncodingError.invalid_sample_data_len;

    const samples_count: u32 = data_len / (channels * (bit_depth / 8));

    return FlacStreaminfo{
        .min_block_size = BLOCK_SIZE,
        .max_block_size = BLOCK_SIZE,
        .sample_rate = @intCast(sample_rate),
        .channels = @intCast(channels),
        .bit_depth = @intCast(bit_depth),
        .interchannel_samples = samples_count,
        .md5 = undefined,
    };
}
