const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.addModule("airdb", .{
        .root_source_file = b.path("src/airdb.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const int_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/storage_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "airdb", .module = mod },
        },
    });
    const int_tests = b.addTest(.{
        .root_module = int_test_mod,
    });

    const run_lib = b.addRunArtifact(lib_tests);
    const run_int = b.addRunArtifact(int_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib.step);
    test_step.dependOn(&run_int.step);
}
