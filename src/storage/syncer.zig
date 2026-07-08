//! Injectable durability-barrier interface and its implementations.
//!
//! The Syncing abstraction lets the storage layer depend on "flush this file to
//! stable storage" without knowing how: production uses the platform barrier
//! (FileSyncer), tests inject a controllable one (FailingSyncer) to simulate a
//! crash at a precise commit step.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Injectable flush interface.
pub const Syncing = struct {
    ptr: *anyopaque,
    flushFn: *const fn (ptr: *anyopaque, file: Io.File) anyerror!void,

    /// Flush `file` to stable storage through the injected implementation.
    /// Issues a durability barrier (fsync or stronger) -- blocking I/O.
    pub fn flush(self: Syncing, file: Io.File) !void {
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
        const resultCode = std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
        if (std.c.errno(resultCode) != .SUCCESS) {
            try file.sync(std.Io.Threaded.global_single_threaded.io());
        }
    } else {
        try file.sync(std.Io.Threaded.global_single_threaded.io());
    }
}

/// Production syncer that calls the platform durability barrier.
pub const FileSyncer = struct {
    var instance: FileSyncer = .{};

    fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        _ = ptr;
        try fullSync(file);
    }

    /// The shared FileSyncer as a Syncing capability.
    pub fn any() Syncing {
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
    failOn: usize,

    /// Vtable target: fails the failOn-th call (1-based) with
    /// error.SimulatedCrash; every other call performs the real barrier.
    pub fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        const self: *FailingSyncer = @ptrCast(@alignCast(ptr));
        self.count += 1;
        if (self.count == self.failOn) return error.SimulatedCrash;
        try fullSync(file);
    }

    /// This FailingSyncer as a Syncing capability.
    pub fn any(self: *FailingSyncer) Syncing {
        return .{ .ptr = self, .flushFn = &FailingSyncer.flushImpl };
    }
};
