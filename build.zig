const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy_enable = b.option(bool, "tracy", "Enable tracy (default: false)") orelse false;

    if (target.result.cpu.arch.endian() == .big) {
        std.log.err("This program/library does not support big endian", .{});
        return;
    }

    // Define Options
    const option = b.addOptions();
    const d_buffer_size = b.option(usize, "buffer_size", "Set buffer size of reader and writer (default: 4096)") orelse 4096;
    option.addOption(usize, "buffer_size", d_buffer_size);

    // Executable Module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = tracy_enable,
    });
    exe_mod.addOptions("option", option);

    // Tracy Module
    const tracy_dep = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
        .tracy_enable = tracy_enable,
    });
    exe_mod.addImport("tracy", tracy_dep.module("tracy"));
    if (tracy_enable) exe_mod.linkLibrary(tracy_dep.artifact("tracy"));

    // Executable
    const exe = b.addExecutable(.{
        .name = "flac",
        .root_module = exe_mod,
        .strip = optimize != .Debug,
    });

    b.installArtifact(exe);

    // Run Executable
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
