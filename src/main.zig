const std = @import("std");
const builtin = @import("builtin");
const option = @import("option");

const flac = @import("flac");

const wav2flac = @import("wav2flac.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Args
    var args = init.minimal.args.iterate();
    _ = args.next(); // skip exe

    const input = args.next();
    const output = args.next();
    if (input == null or output == null) {
        std.log.err("usage: flac in_file.wav out_file.flac", .{});
        std.process.exit(1);
    }

    try encodeFile(allocator, io, input.?, output.?);
}

fn encodeFile(gpa: std.mem.Allocator, io: std.Io, input: []const u8, output: []const u8) !void {
    const in_file = try std.Io.Dir.cwd().openFile(io, input, .{});
    defer in_file.close(io);
    
    var in_buf: [option.buffer_size]u8 = undefined;
    var file_reader = in_file.reader(io, &in_buf);

    const wav = try @import("WavReader.zig").init(&file_reader.interface);

    var streaminfo = wav.flacStreaminfo() orelse {
        std.log.err("format: flac does not support this wav format", .{});
        std.process.exit(2);
    }; // Flac unsupported format

    try wav2flac.main(gpa, io, output, &streaminfo, wav);
}
