const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Release builds pass the tag, e.g. -Dversion=v0.2.0.
    const version = b.option([]const u8, "version", "Version string shown by --version") orelse "dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const sqlite_dep = b.dependency("sqlite", .{});

    const sqlite_c = b.addTranslateC(.{
        .root_source_file = sqlite_dep.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "sqlite_c", .module = sqlite_c.createModule() },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    root_mod.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_MATH_FUNCTIONS",
        },
    });

    const exe = b.addExecutable(.{
        .name = "zpeek",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zpeek");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tests = b.addTest(.{ .root_module = root_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
