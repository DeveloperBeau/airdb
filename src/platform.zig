// platform.zig -- OS-specific operations (memory mapping, file locking, process checks).
//
// This module isolates every syscall whose shape differs between POSIX and Windows
// so the rest of airdb can stay platform-neutral. Both paths are implemented; the
// branch is selected at comptime on builtin.os.tag.
//
// Zig 0.16 types mirror the call sites this replaced:
//   - std.Io.File for file handles (flock/mmap take file.handle / fd_t; on Windows
//     file.handle is a windows.HANDLE)
//   - page alignment via std.heap.page_size_min (compile-time lower bound)

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// Compile-time lower bound on the page size; the alignment the kernel guarantees
/// for mmap return pointers.
const page = std.heap.page_size_min;

/// Virtual address reservation, and so the per-open maximum file size for a growable
/// mapping. On POSIX it is never backed by physical pages beyond what the file covers
/// (PROT_NONE reservation; demand-paged) and the base never moves. On Windows there is
/// no reserve-and-grow-in-place, so this is only the per-open size cap.
/// 64-bit: 1 TiB. 32-bit: 1 GiB.
pub const max_reserved: usize = if (@bitSizeOf(usize) >= 64) (1 << 40) else (1 << 30);

// Windows API bindings, declared locally so the module is self-contained. Gated so
// the .winapi externs are only present when compiling for Windows.
const win = if (is_windows) struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;
    const DWORD = w.DWORD;
    // Win32 BOOL is a plain 32-bit int (std's Bool is a distinct enum; use the raw
    // ABI type so comparisons against 0 and passing 0/1 work directly).
    const BOOL = c_int;
    // Win32 OVERLAPPED (the Offset/OffsetHigh form of the leading union); declared
    // locally because this std.os.windows does not export it.
    const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: DWORD = 0,
        OffsetHigh: DWORD = 0,
        hEvent: ?HANDLE = null,
    };

    const PAGE_READWRITE: DWORD = 0x04;
    const FILE_MAP_WRITE: DWORD = 0x0002;
    const FILE_MAP_READ: DWORD = 0x0004;
    const LOCKFILE_FAIL_IMMEDIATELY: DWORD = 0x00000001;
    const LOCKFILE_EXCLUSIVE_LOCK: DWORD = 0x00000002;
    const SYNCHRONIZE: DWORD = 0x00100000;
    const WAIT_OBJECT_0: DWORD = 0x00000000;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    const lock_all_low: DWORD = 0xFFFFFFFF;
    const lock_all_high: DWORD = 0xFFFFFFFF;

    extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpAttrs: ?*anyopaque, flProtect: DWORD, dwMaxHigh: DWORD, dwMaxLow: DWORD, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hMap: HANDLE, access: DWORD, offHigh: DWORD, offLow: DWORD, bytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(base: ?*const anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn LockFileEx(h: HANDLE, flags: DWORD, reserved: DWORD, low: DWORD, high: DWORD, ov: *OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn UnlockFileEx(h: HANDLE, reserved: DWORD, low: DWORD, high: DWORD, ov: *OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
} else struct {};

// ---------------------------------------------------------------------------
// Memory mapping
// ---------------------------------------------------------------------------

/// Reserve-then-commit helper (POSIX): map `fd` at `reserved_ptr` with MAP_FIXED.
fn mapFileOver(reserved_ptr: [*]align(page) u8, fd: std.posix.fd_t, len: usize) ![]align(page) u8 {
    return std.posix.mmap(
        reserved_ptr,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    );
}

// Windows: create a file mapping covering the file and map a `len`-byte view.
fn winMapView(file: std.Io.File, len: usize) !struct { map: []align(page) u8, handle: win.HANDLE } {
    const h = win.CreateFileMappingW(file.handle, null, win.PAGE_READWRITE, 0, 0, null) orelse return error.MapFailed;
    errdefer _ = win.CloseHandle(h);
    const ptr = win.MapViewOfFile(h, win.FILE_MAP_READ | win.FILE_MAP_WRITE, 0, 0, len) orelse return error.MapFailed;
    const base: [*]align(page) u8 = @ptrCast(@alignCast(ptr));
    return .{ .map = base[0..len], .handle = h };
}

/// A growable, file-backed shared mapping.
///
/// On POSIX: an anonymous PROT_NONE reservation (`reserved`) with the file mapped over
/// its start with MAP_FIXED (`map`); `grow` re-maps a longer prefix in place at the same
/// base, so existing pointers stay valid.
/// On Windows: a file-mapping `handle` plus a mapped view (`map`); `grow` unmaps, closes,
/// and recreates a larger view (the base may move, which is fine: airdb refs are offsets
/// and the caller re-reads `current()` after a grow).
pub const Mapping = struct {
    map: []align(page) u8,
    reserved: if (is_windows) void else []align(page) u8,
    handle: if (is_windows) win.HANDLE else void,

    /// The live, file-backed `[0, len)` slice.
    pub fn current(self: *const Mapping) []align(page) u8 {
        return self.map;
    }

    /// Re-map the file for `new_len` bytes, updating `self.map`. The caller must have
    /// already extended the file to at least `new_len`.
    pub fn grow(self: *Mapping, file: std.Io.File, new_len: usize) !void {
        if (is_windows) {
            _ = win.UnmapViewOfFile(self.map.ptr);
            _ = win.CloseHandle(self.handle);
            const v = try winMapView(file, new_len);
            self.map = v.map;
            self.handle = v.handle;
        } else {
            self.map = try mapFileOver(self.reserved.ptr, file.handle, new_len);
        }
    }

    /// Release the mapping.
    pub fn deinit(self: *Mapping) void {
        if (is_windows) {
            _ = win.UnmapViewOfFile(self.map.ptr);
            _ = win.CloseHandle(self.handle);
        } else {
            std.posix.munmap(self.reserved);
        }
    }
};

/// Create a growable mapping: on POSIX reserve `max_reserved_len` bytes of address space
/// then map `file` for `len` over its start; on Windows map a `len`-byte view (the size
/// cap is enforced by the caller against `max_reserved`).
pub fn mapFile(file: std.Io.File, len: usize, max_reserved_len: usize) !Mapping {
    if (is_windows) {
        const v = try winMapView(file, len);
        return Mapping{ .map = v.map, .reserved = {}, .handle = v.handle };
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
        return Mapping{ .map = map, .reserved = reserved, .handle = {} };
    }
}

// ---------------------------------------------------------------------------
// File locking
// ---------------------------------------------------------------------------

/// Take an exclusive advisory lock on `file`.
/// Returns true once the lock is held. When `blocking` is false and another holder
/// owns the lock, returns false immediately instead of blocking. Other failures error.
pub fn lockFileExclusive(file: std.Io.File, blocking: bool) !bool {
    if (is_windows) {
        var ov = std.mem.zeroes(win.OVERLAPPED);
        var flags: win.DWORD = win.LOCKFILE_EXCLUSIVE_LOCK;
        if (!blocking) flags |= win.LOCKFILE_FAIL_IMMEDIATELY;
        if (win.LockFileEx(file.handle, flags, 0, win.lock_all_low, win.lock_all_high, &ov) != 0) return true;
        if (!blocking) return false; // contended (ERROR_LOCK_VIOLATION / IO_PENDING)
        return error.LockFailed;
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

/// Release the advisory lock held on `file`.
pub fn unlockFile(file: std.Io.File) void {
    if (is_windows) {
        var ov = std.mem.zeroes(win.OVERLAPPED);
        _ = win.UnlockFileEx(file.handle, 0, win.lock_all_low, win.lock_all_high, &ov);
    } else {
        _ = std.c.flock(file.handle, std.posix.LOCK.UN);
    }
}

// ---------------------------------------------------------------------------
// Process
// ---------------------------------------------------------------------------

/// The current process id.
pub fn currentPid() u32 {
    if (is_windows) {
        return @intCast(win.GetCurrentProcessId());
    } else {
        return @intCast(std.c.getpid());
    }
}

/// Returns true if the process with the given pid is alive.
/// pid==0 is always considered dead (free slot sentinel).
pub fn processAlive(pid: u32) bool {
    if (pid == 0) return false;
    if (is_windows) {
        const h = win.OpenProcess(win.SYNCHRONIZE, 0, pid) orelse return false; // gone
        defer _ = win.CloseHandle(h);
        // Alive if it has not become signaled (exited) within a 0ms wait.
        return win.WaitForSingleObject(h, 0) == win.WAIT_TIMEOUT;
    } else {
        // kill(pid, 0): success or EPERM means alive; ESRCH means dead.
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
