const std = @import("std");
const builtin = @import("builtin");
const option = @import("option");

const wav2flac = @import("cli/wav2flac.zig");

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
    try wav2flac.main(gpa, io, input, output);
}
