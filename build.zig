const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip executable output (default: false)") orelse false;
    const full_debug = b.option(bool, "full_debug", "emit extreme code model") orelse false;

    // Define Options
    const option = b.addOptions();
    const link_ossl = b.option(bool, "link_ossl", "dynamically link openssl as dependency (default: false)") orelse false;
    const do_simd = b.option(bool, "simd", "compile with manual simd variant code if target accept (default: true)") orelse true;
    option.addOption(bool, "link_ossl", link_ossl);
    option.addOption(bool, "do_simd", do_simd);

    const option_mod = option.createModule();

    // Lib Module
    const libflac_mod = b.addModule(
        "libFLAC",
        .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = if (full_debug) .extreme else .default,
            .strip = strip,
        },
    );
    libflac_mod.addImport("option", option_mod);
    if (link_ossl) libflac_mod.linkSystemLibrary("crypto", .{});

    // Executable Module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = link_ossl,
    });
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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Check Step (no emit bin)
    const exe_check = b.addExecutable(.{
        .name = "flac",
        .root_module = exe_mod,
    });

    const check_exe = b.step("check", "Build on save check (no emit bin)");
    check_exe.dependOn(&exe_check.step);

    const exe_bc = b.addInstallFile(exe_check.getEmittedLlvmBc(), "llvm/llvm.bc");
    const exe_bc_step = b.step("llvm-bc", "Emit LLVM BC of entire exe");
    exe_bc_step.dependOn(&exe_bc.step);
}
