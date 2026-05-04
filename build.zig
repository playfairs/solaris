const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const apple_runtime_translate_c = b.addTranslateC(.{ .link_libc = true, .target = target, .optimize = optimize, .root_source_file = b.path("./src/translate-c/apple-runtime.h") });

    const exe = b.addExecutable(.{
        .name = "solaris",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .link_libc = true, .optimize = optimize, .imports = &.{ .{ .name = "apl_runtime_trans_c", .module = apple_runtime_translate_c.createModule() }, .{ .name = "zigimg", .module = zigimg.module("zigimg") } } }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
