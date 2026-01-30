const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================================================
    // Dependencies
    // ==========================================================================

    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });
    const gooey_mod = gooey_dep.module("gooey");

    // TigerbeetleDB client bindings (vendored)
    const tb_mod = b.addModule("tigerbeetle", .{
        .root_source_file = b.path("vendor/tigerbeetle/tb_client.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // TigersEye Executable
    // ==========================================================================

    const exe = b.addExecutable(.{
        .name = "tigerseye",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_mod },
                .{ .name = "tigerbeetle", .module = tb_mod },
            },
        }),
    });

    // Link TigerbeetleDB client library
    // Check for dynamic library first, then static
    const dylib_path = b.path("vendor/tigerbeetle/lib/libtb_client.dylib");
    const static_path = b.path("vendor/tigerbeetle/lib/libtb_client.a");

    const dylib_exists = std.fs.cwd().access(dylib_path.getPath(b), .{}) catch null;
    const static_exists = std.fs.cwd().access(static_path.getPath(b), .{}) catch null;

    if (dylib_exists != null or static_exists != null) {
        exe.addLibraryPath(b.path("vendor/tigerbeetle/lib"));
        exe.linkSystemLibrary("tb_client");
        exe.linkLibC();
    } else {
        std.log.warn(
            \\TigerbeetleDB client library not found!
            \\
            \\Please place libtb_client.dylib (macOS) or libtb_client.a in:
            \\  vendor/tigerbeetle/lib/
            \\
            \\You can get it from:
            \\  - TigerbeetleDB releases: https://github.com/tigerbeetle/tigerbeetle/releases
            \\  - Or build from source
            \\
        , .{});
    }

    // macOS frameworks (required by Gooey)
    if (target.result.os.tag == .macos) {
        exe.linkFramework("Cocoa");
        exe.linkFramework("Metal");
        exe.linkFramework("MetalKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("CoreText");
        exe.linkFramework("CoreGraphics");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("Foundation");
        exe.linkFramework("AppKit");
    }

    b.installArtifact(exe);

    // ==========================================================================
    // Run Step
    // ==========================================================================

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run TigersEye");
    run_step.dependOn(&run_cmd.step);

    // ==========================================================================
    // Test Step
    // ==========================================================================

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_mod },
                .{ .name = "tigerbeetle", .module = tb_mod },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
