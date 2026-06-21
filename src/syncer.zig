// syncer.zig -- injectable durability-barrier interface and its implementations.
//
// The Syncer abstraction lets the storage layer depend on "flush this file to
// stable storage" without knowing how: production uses the platform barrier
// (RealSyncer), tests inject a controllable one (FailingSyncer) to simulate a
// crash at a precise commit step.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Injectable flush interface.
pub const Syncer = struct {
    ptr: *anyopaque,
    flushFn: *const fn (ptr: *anyopaque, file: Io.File) anyerror!void,

    pub fn flush(self: Syncer, file: Io.File) !void {
        return self.flushFn(self.ptr, file);
    }
};

/// Durability barrier: uses F_FULLFSYNC on Apple targets (forces drive write-cache flush),
/// plain fsync everywhere else.
///
/// In Zig 0.16, std.posix.fcntl does not exist. We call std.c.fcntl (the libc extern)
/// with std.c.F.FULLFSYNC (value 51, Darwin-only) and check the result via std.c.errno.
/// The comptime isDarwin() guard ensures the Darwin branch is never compiled on other targets.
fn fullSync(file: Io.File) !void {
    if (comptime builtin.target.os.tag.isDarwin()) {
        // F_FULLFSYNC (51) forces the drive's write cache to platter, unlike plain fsync.
        // Fall back to file.sync if the underlying filesystem does not support it (e.g. tmpfs).
        const rc = std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
        if (std.c.errno(rc) != .SUCCESS) {
            try file.sync(std.Io.Threaded.global_single_threaded.io());
        }
    } else {
        try file.sync(std.Io.Threaded.global_single_threaded.io());
    }
}

/// Production syncer that calls the platform durability barrier.
pub const RealSyncer = struct {
    var instance: RealSyncer = .{};

    fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        _ = ptr;
        try fullSync(file);
    }

    pub fn any() Syncer {
        return .{
            .ptr = &instance,
            .flushFn = flushImpl,
        };
    }
};

/// Test syncer that fails the Nth flush call (1-based) to simulate a crash
/// at a precise commit step. Non-failing calls perform the real sync.
pub const FailingSyncer = struct {
    count: usize = 0,
    fail_on: usize,

    pub fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        const self: *FailingSyncer = @ptrCast(@alignCast(ptr));
        self.count += 1;
        if (self.count == self.fail_on) return error.SimulatedCrash;
        try fullSync(file);
    }

    pub fn any(self: *FailingSyncer) Syncer {
        return .{ .ptr = self, .flushFn = &FailingSyncer.flushImpl };
    }
};
