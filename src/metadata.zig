const std = @import("std");

pub const BlockHeader = packed struct(u8) {
    block_type: BlockType,
    is_last_block: bool,

    pub const BlockType = enum(u7) {
        StreamInfo = 0,
        Padding = 1,
        Application = 2,
        SeekTable = 3,
        VorbisComment = 4,
        CueSheet = 5,
        Picture = 6,
        Forbidden = 127,
        _,
    };
};

pub const StreamInfo = struct {
    md5: [16]u8,
    interchannel_samples: u64, // real 36
    min_frame_size: u24 = 0,
    max_frame_size: u24 = 0,
    sample_rate: u20, // real 20
    min_block_size: u16,
    max_block_size: u16,
    channels: u4, // real 3
    bit_depth: u6, // real 5

    pub fn bytes(self: @This()) [34]u8 {
        const nativeToBig = std.mem.nativeToBig;

        const channels: u8 = self.channels;
        const bit_depth: u8 = self.bit_depth;
        const sample_rate: u24 = self.sample_rate;

        var result: [34]u8 = undefined;
        // block sizes
        @memcpy(result[0..2], &@as([2]u8, @bitCast(nativeToBig(u16, self.min_block_size))));
        @memcpy(result[2..4], &@as([2]u8, @bitCast(nativeToBig(u16, self.max_block_size))));
        // frame sizes
        @memcpy(result[4..7], &@as([3]u8, @bitCast(nativeToBig(u24, self.min_frame_size))));
        @memcpy(result[7..10], &@as([3]u8, @bitCast(nativeToBig(u24, self.max_frame_size))));
        // sample rate, channels and first bit of bit depth
        var sample_rate_be: [3]u8 = @bitCast(nativeToBig(u24, sample_rate << 4));
        sample_rate_be[2] |= (channels - 1) << 1;
        sample_rate_be[2] |= (bit_depth - 1) >> 4;
        @memcpy(result[10..13], &sample_rate_be);
        // lower 4 bits of bit depth and interchannel samples
        var interchannel_samples_be: [8]u8 = @bitCast(nativeToBig(u64, self.interchannel_samples << 24));
        interchannel_samples_be[0] |= (bit_depth - 1) << 4;
        @memcpy(result[13..18], interchannel_samples_be[0..5]);
        // md5
        @memcpy(result[18..], &self.md5);
        return result;
    }
};
