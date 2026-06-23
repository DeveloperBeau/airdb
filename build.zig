const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.addModule("airdb", .{
        .root_source_file = b.path("src/airdb.zig"),
        .target = target,
        .optimize = optimize,
        // The storage engine calls libc directly for durability and
        // multi-process coordination: fcntl(F_FULLFSYNC) on Darwin, plus
        // flock/getpid. macOS links libc implicitly; Linux requires it to be
        // requested explicitly.
        .link_libc = true,
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const int_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/storage_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
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

    // Static library exposing the C ABI for language bindings. The library's
    // root is ffi.zig so its top-level `export fn` symbols are emitted (they
    // would be tree-shaken if reached only through a re-export).
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "airdb",
        .root_module = ffi_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // C smoke test: compile tests/ffi_smoke.c against include/airdb.h, link the
    // static library, and run it. Proves the C ABI is callable end to end. Its
    // fixed "/tmp/..." path is POSIX-only, so the run is skipped on Windows (the
    // ABI logic it exercises is platform-neutral).
    if (target.result.os.tag != .windows) {
        const c_smoke_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        c_smoke_mod.addCSourceFile(.{ .file = b.path("tests/ffi_smoke.c") });
        c_smoke_mod.addIncludePath(b.path("include"));
        c_smoke_mod.linkLibrary(lib);
        const c_smoke = b.addExecutable(.{
            .name = "ffi_smoke",
            .root_module = c_smoke_mod,
        });
        const run_c_smoke = b.addRunArtifact(c_smoke);
        test_step.dependOn(&run_c_smoke.step);
    }
}
