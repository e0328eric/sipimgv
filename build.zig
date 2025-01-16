const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_lib = b.dependency("raylib", .{});
    b.addTranslateC(.{
        .root_source_file = .{ .dependency = .{
            .dependency = raylib_lib,
            .sub_path = ".",
        } },
        .target = target,
        .optimize = optimize,
    }).defineCMacro("SUPPORT_FILEFORMAT_JPG", "");
    const zlap = b.dependency("zlap", .{}).module("zlap");

    const exe = b.addExecutable(.{
        .name = "siv",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("zlap", zlap);
    exe.linkLibrary(raylib_lib.artifact("raylib"));
    if (target.query.os_tag == null or target.query.os_tag == .windows) {
        exe.addIncludePath(b.path("./vcpkg_installed/x64-mingw-static/include"));
        exe.addLibraryPath(b.path("./vcpkg_installed/x64-mingw-static/lib"));
        exe.linkSystemLibrary("webp");
        exe.linkSystemLibrary("webpdecoder");
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const vcpkg_step = b.step("vcpkg", "run vcpkg to download dependencies");
    const vcpkg_substep = b.addSystemCommand(&[_][]const u8{
        "vcpkg",
        "install",
        "--triplet=x64-mingw-static",
    });
    vcpkg_step.dependOn(&vcpkg_substep.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
