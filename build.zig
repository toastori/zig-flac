const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define Options
    const option = b.addOptions();
    const d_buffer_size = b.option(usize, "buffer_size", "Set buffer size of reader and writer (default: 4096)") orelse 4096;
    const d_frame_size = b.option(usize, "frame_size", "Set frame size of encoder (default: 4096)") orelse 4096;
    option.addOption(usize, "buffer_size", d_buffer_size);
    option.addOption(usize, "frame_size", d_frame_size);

    const option_mod = option.createModule();

    // Lib Module
    const libflac_mod = b.addModule(
        "libFLAC",
        .{
            .root_source_file = b.path("libFLAC/root.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        },
    );

    // Executable Module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    exe_mod.addImport("option", option_mod);
    exe_mod.addImport("flac", libflac_mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "flac",
        .root_module = exe_mod,
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

    const test_step = b.step(".test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Check Step (no emit bin)
    const exe_check = b.addExecutable(.{
        .name = "flac",
        .root_module = exe_mod,
    });

    const check_exe = b.step("check", "Build on save check (no emit bin)");
    check_exe.dependOn(&exe_check.step);
}
