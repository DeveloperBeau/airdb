// platform.zig -- OS-specific operations (memory mapping, file locking, process checks).
//
// This module isolates every syscall whose shape differs between POSIX and Windows
// so the rest of airdb can stay platform-neutral. Only the POSIX path is implemented
// today; the Windows path is an explicit @compileError stub inside a comptime
// `builtin.os.tag == .windows` branch, so macOS/Linux compile and behave exactly as
// before while Windows compilation fails loudly until the Windows port lands.
//
// Zig 0.16 types mirror the call sites this replaced:
//   - std.Io.File for file handles (flock/mmap take file.handle / fd_t)
//   - page alignment via std.heap.page_size_min (compile-time lower bound)

const std = @import("std");
const builtin = @import("builtin");

/// Compile-time lower bound on the page size; the alignment the kernel guarantees
/// for mmap return pointers.
const page = std.heap.page_size_min;

/// Virtual address reservation, and so the per-open maximum file size for a growable
/// mapping. It is never backed by physical pages beyond what the file actually covers
/// (PROT_NONE reservation; the file mapping is demand-paged), and the base pointer
/// never moves after creation. 64-bit hosts reserve 1 TiB (negligible against a
/// ~128 TiB address space). 32-bit hosts reserve 1 GiB (a quarter of their ~4 GiB).
pub const max_reserved: usize = if (@bitSizeOf(usize) >= 64) (1 << 40) else (1 << 30);

// ---------------------------------------------------------------------------
// Memory mapping
// ---------------------------------------------------------------------------

/// Reserve-then-commit helper: map `fd` at `reserved_ptr` with MAP_FIXED.
/// The caller must already hold a `reserved_ptr` from an anonymous PROT_NONE
/// reservation large enough to hold `len` bytes.
fn mapFileOver(
    reserved_ptr: [*]align(page) u8,
    fd: std.posix.fd_t,
    len: usize,
) ![]align(page) u8 {
    return std.posix.mmap(
        reserved_ptr,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    );
}

/// A growable, file-backed mapping pinned at a stable base address.
///
/// On POSIX this is a contiguous anonymous PROT_NONE reservation (`reserved`) with the
/// file mapped over its start with MAP_FIXED (`map`). `grow` re-maps a longer prefix of
/// the file in place at the same base, so pointers into the existing mapping stay valid.
pub const Mapping = struct {
    /// The full virtual reservation; unmapped once in `deinit`. Unmapping it also
    /// unmaps the file-backed prefix at its start.
    reserved: []align(page) u8,
    /// File-backed prefix of the reservation: reserved.ptr[0..len].
    map: []align(page) u8,

    /// The live, file-backed `[0, len)` slice.
    pub fn current(self: *const Mapping) []align(page) u8 {
        return self.map;
    }

    /// Re-map the file for `new_len` bytes over the existing reservation (MAP_FIXED),
    /// updating `self.map`. The base pointer does not change.
    pub fn grow(self: *Mapping, file: std.Io.File, new_len: usize) !void {
        if (builtin.os.tag == .windows) {
            @compileError("platform.Mapping.grow: implemented in the Windows port");
        } else {
            self.map = try mapFileOver(self.reserved.ptr, file.handle, new_len);
        }
    }

    /// Unmap the full reservation (and, with it, the file-backed prefix).
    pub fn deinit(self: *Mapping) void {
        if (builtin.os.tag == .windows) {
            @compileError("platform.Mapping.deinit: implemented in the Windows port");
        } else {
            std.posix.munmap(self.reserved);
        }
    }
};

/// Create a growable mapping: reserve `max_reserved_len` bytes of address space, then
/// map `file` for `len` bytes over its start.
pub fn mapFile(file: std.Io.File, len: usize, max_reserved_len: usize) !Mapping {
    if (builtin.os.tag == .windows) {
        @compileError("platform.mapFile: implemented in the Windows port");
    } else {
        // Step 1: reserve a contiguous virtual range with PROT_NONE so the base
        // address is fixed for the lifetime of this mapping.
        const reserved = try std.posix.mmap(
            null,
            max_reserved_len,
            .{},
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(reserved);

        // Step 2: map the file over the start of the reservation with MAP_FIXED.
        const map = try mapFileOver(reserved.ptr, file.handle, len);
        return Mapping{ .reserved = reserved, .map = map };
    }
}

/// Map a fixed-size, file-backed region shared (no reservation, no grow).
pub fn mapFixedSize(file: std.Io.File, len: usize) ![]align(page) u8 {
    if (builtin.os.tag == .windows) {
        @compileError("platform.mapFixedSize: implemented in the Windows port");
    } else {
        return std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    }
}

/// Unmap a slice previously returned by `mapFixedSize`.
pub fn unmap(slice: []align(page) u8) void {
    if (builtin.os.tag == .windows) {
        @compileError("platform.unmap: implemented in the Windows port");
    } else {
        std.posix.munmap(slice);
    }
}

// ---------------------------------------------------------------------------
// File locking
// ---------------------------------------------------------------------------

/// Take an exclusive advisory lock on `file`.
/// Returns true once the lock is held. When `blocking` is false and another holder
/// owns the lock, returns false immediately instead of blocking. Other failures error.
pub fn lockFileExclusive(file: std.Io.File, blocking: bool) !bool {
    if (builtin.os.tag == .windows) {
        @compileError("platform.lockFileExclusive: implemented in the Windows port");
    } else {
        const operation: i32 = if (blocking)
            std.posix.LOCK.EX
        else
            std.posix.LOCK.EX | std.posix.LOCK.NB;
        const rc = std.c.flock(file.handle, operation);
        switch (std.c.errno(rc)) {
            .SUCCESS => return true,
            .AGAIN => return false, // only reachable in the non-blocking case
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

/// Release the advisory lock held on `file` by this open file description.
pub fn unlockFile(file: std.Io.File) void {
    if (builtin.os.tag == .windows) {
        @compileError("platform.unlockFile: implemented in the Windows port");
    } else {
        _ = std.c.flock(file.handle, std.posix.LOCK.UN);
    }
}

// ---------------------------------------------------------------------------
// Process
// ---------------------------------------------------------------------------

/// The current process id.
pub fn currentPid() u32 {
    if (builtin.os.tag == .windows) {
        @compileError("platform.currentPid: implemented in the Windows port");
    } else {
        return @intCast(std.c.getpid());
    }
}

/// Returns true if the process with the given pid is alive.
/// pid==0 is always considered dead (free slot sentinel).
/// Uses kill(pid, 0): success or EPERM means alive; ESRCH means dead.
pub fn processAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) {
        @compileError("platform.processAlive: implemented in the Windows port");
    } else {
        if (pid == 0) return false;
        std.posix.kill(
            @as(std.posix.pid_t, @intCast(pid)),
            @as(std.posix.SIG, @enumFromInt(0)),
        ) catch |e| switch (e) {
            error.ProcessNotFound => return false, // ESRCH: no such process
            error.PermissionDenied => return true, // EPERM: alive, not ours
            else => return true, // conservative: treat unknown errors as alive
        };
        return true;
    }
}
