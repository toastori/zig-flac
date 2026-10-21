const std = @import("std");
const endian = @import("builtin").cpu.arch.endian();

const Md5 = @import("md5.zig").Md5;

/// Fill dst[*][dst_start..] with samples
pub fn samplesFromInterleaveRaw(
    src_raw: []const u8,
    dst: [*]const [*]i32,
    dst_start: u16,
    bytes_per_sample: u8,
    bitdepth: u16,
    channels: u16,
    samples_cnt: u16,
) void {
    std.debug.assert(src_raw.len == samples_cnt * bytes_per_sample * channels);

    bytesToSample(src_raw, dst, dst_start, bitdepth, channels);

    // Unsigned to signed
    if (bytes_per_sample == 1) {
        const sub_amt = @as(i32, 128) >> @intCast(8 - bitdepth);
        for (dst[0..channels]) |ch| {
            for (ch[dst_start..][0..samples_cnt]) |*sample| {
                sample.* -= sub_amt;
            }
        }
    }

    // Sign extend
    if (bitdepth != 32) {
        const shift_amt: u5 = @intCast(32 - bitdepth);
        for (dst[0..channels]) |ch| {
            for (ch[dst_start..][0..samples_cnt]) |*sample| {
                sample.* >>= shift_amt;
            }
        }
    }
}

fn bytesToSample(src: []const u8, dst: [*]const [*]i32, dst_start: u16, bps: u16, channels: u16) void {
    switch (bps) {
        4, 8 => { // 1 byte
            switch (channels) {
                1 => _bytesToSamples(1, 1, src, dst, dst_start),
                2 => _bytesToSamples(2, 1, src, dst, dst_start),
                3 => _bytesToSamples(3, 1, src, dst, dst_start),
                4 => _bytesToSamples(4, 1, src, dst, dst_start),
                5 => _bytesToSamples(5, 1, src, dst, dst_start),
                6 => _bytesToSamples(6, 1, src, dst, dst_start),
                7 => _bytesToSamples(7, 1, src, dst, dst_start),
                8 => _bytesToSamples(8, 1, src, dst, dst_start),
                else => unreachable,
            }
        },
        12, 16 => { // 2 bytes
            switch (channels) {
                1 => _bytesToSamples(1, 2, src, dst, dst_start),
                2 => _bytesToSamples(2, 2, src, dst, dst_start),
                3 => _bytesToSamples(3, 2, src, dst, dst_start),
                4 => _bytesToSamples(4, 2, src, dst, dst_start),
                5 => _bytesToSamples(5, 2, src, dst, dst_start),
                6 => _bytesToSamples(6, 2, src, dst, dst_start),
                7 => _bytesToSamples(7, 2, src, dst, dst_start),
                8 => _bytesToSamples(8, 2, src, dst, dst_start),
                else => unreachable,
            }
        },
        20, 24 => { // 3 bytes
            switch (channels) {
                1 => _bytesToSamples(1, 3, src, dst, dst_start),
                2 => _bytesToSamples(2, 3, src, dst, dst_start),
                3 => _bytesToSamples(3, 3, src, dst, dst_start),
                4 => _bytesToSamples(4, 3, src, dst, dst_start),
                5 => _bytesToSamples(5, 3, src, dst, dst_start),
                6 => _bytesToSamples(6, 3, src, dst, dst_start),
                7 => _bytesToSamples(7, 3, src, dst, dst_start),
                8 => _bytesToSamples(8, 3, src, dst, dst_start),
                else => unreachable,
            }
        },
        32 => { // 4 bytes
            switch (channels) {
                1 => _bytesToSamples(1, 4, src, dst, dst_start),
                2 => _bytesToSamples(2, 4, src, dst, dst_start),
                3 => _bytesToSamples(3, 4, src, dst, dst_start),
                4 => _bytesToSamples(4, 4, src, dst, dst_start),
                5 => _bytesToSamples(5, 4, src, dst, dst_start),
                6 => _bytesToSamples(6, 4, src, dst, dst_start),
                7 => _bytesToSamples(7, 4, src, dst, dst_start),
                8 => _bytesToSamples(8, 4, src, dst, dst_start),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

fn _bytesToSamples(
    channels: comptime_int,
    bytes_per_sample: comptime_int,
    src: []const u8,
    dst: [*]const [*]i32,
    dst_start: u16,
) void {
    const samples_cnt = src.len / (bytes_per_sample * channels);
    const sample_bytes_start = 4 - bytes_per_sample;
    var b: usize = 0;
    for (dst_start..dst_start + samples_cnt) |i| {
        inline for (0..channels) |ch| {
            const sample_bytes: *[4]u8 = @ptrCast(@alignCast(&dst[ch][i]));
            inline for (sample_bytes_start..4) |s_b| {
                sample_bytes[s_b] = src[b];
                b += 1;
            }
            dst[ch][i] = std.mem.nativeToLittle(i32, dst[ch][i]);
        }
    }
}
