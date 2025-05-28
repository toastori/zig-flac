const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const FlacEncoder = @import("FlacEncoder.zig");
const metadata = @import("metadata.zig");

pub fn main() !void {
    // Tracy
    tracy.startupProfiler();
    defer tracy.shutdownProfiler();
    tracy.setThreadName("main");

    // Allocator
    var gpa = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}){} else {};
    defer if (@TypeOf(gpa) != void) std.log.info("gpa: {s}", .{@tagName(gpa.deinit())});
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

    // Args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip exe

    const input = args.next();
    const output = args.next();
    if (input == null or output == null) {
        std.log.err("usage: flac in_file.wav out_file.flac", .{});
        std.process.exit(1);
    }

    try encodeFile(allocator, input.?, output.?);
}

fn encodeFile(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    var wav = try @import("WavReader.zig").init(input);
    defer wav.deinit();

    var streaminfo = wav.flacStreaminfo() orelse {
        std.log.err("format: flac does not support this wav format", .{});
        std.process.exit(2);
    }; // Flac unsupported format

    var flac_encoder: FlacEncoder = .make(0, 4, 0, 0, 0, 8, 0);

    try flac_encoder.wavMain(output, allocator, &streaminfo, &wav);
}
