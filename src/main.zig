const std = @import("std");
const builtin = @import("builtin");
const option = @import("option");

const flac = @import("flac");

const wav2flac = @import("wav2flac.zig");

pub fn main() !void {
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
    const in_file = try std.fs.cwd().openFile(input, .{});
    defer in_file.close();
    var in_buf: [option.buffer_size]u8 = undefined;
    var file_reader: std.fs.File.Reader = in_file.reader(&in_buf);

    const wav = try @import("WavReader.zig").init(&file_reader.interface);

    var streaminfo = wav.flacStreaminfo() orelse {
        std.log.err("format: flac does not support this wav format", .{});
        std.process.exit(2);
    }; // Flac unsupported format

    try wav2flac.main(output, allocator, &streaminfo, wav);
}
