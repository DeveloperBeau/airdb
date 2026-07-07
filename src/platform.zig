//! OS-specific operations (memory mapping, file locking, process checks).
//!
//! This module isolates every syscall whose shape differs between POSIX and Windows
//! so the rest of airdb can stay platform-neutral. Both paths are implemented; the
//! branch is selected at comptime on builtin.os.tag.
//!
//! Zig 0.16 types mirror the call sites this replaced:
//!   - std.Io.File for file handles (flock/mmap take file.handle / fd_t; on Windows
//!     file.handle is a windows.HANDLE)
//!   - page alignment via std.heap.page_size_min (compile-time lower bound)

const std = @import("std");
const builtin = @import("builtin");

const isWindows = builtin.os.tag == .windows;

/// Compile-time lower bound on the page size; the alignment the kernel guarantees
/// for mmap return pointers.
const page = std.heap.page_size_min;

/// Per-open maximum file size. The file is mapped as a list of fixed-size sections;
/// this caps how many sections may be created (maxSections = maxReserved / sectionSize),
/// keeping the section array bounded.
/// 64-bit: 1 TiB. 32-bit: 1 GiB.
pub const maxReserved: usize = if (@bitSizeOf(usize) >= 64) (1 << 40) else (1 << 30);

/// The file is mapped in fixed-size sections. A ref (an absolute byte offset into the
/// logical arena) is translated to a pointer via the section it falls in:
///   sectionIndex   = ref >> sectionShift
///   offsetInSection = ref & sectionMask
/// Existing sections are never remapped or moved on growth (growth only ADDS sections),
/// so every live pointer stays valid. No single allocation may cross a section boundary,
/// which also makes sectionSize the maximum single allocation size.
pub const sectionShift: u6 = 24;
/// Bytes per mapped section (16 MiB) -- also the maximum single allocation.
pub const sectionSize: usize = 1 << sectionShift;
/// Mask extracting the within-section offset from a ref.
pub const sectionMask: usize = sectionSize - 1;

// Windows API bindings, declared locally so the module is self-contained. Gated so
// the .winapi externs are only present when compiling for Windows.
const win = if (isWindows) struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
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
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x00001000;

    const FILETIME = extern struct {
        dwLowDateTime: DWORD,
        dwHighDateTime: DWORD,
    };
    const WAIT_OBJECT_0: DWORD = 0x00000000;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    const lockAllLow: DWORD = 0xFFFFFFFF;
    const lockAllHigh: DWORD = 0xFFFFFFFF;

    extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpAttrs: ?*anyopaque, flProtect: DWORD, dwMaxHigh: DWORD, dwMaxLow: DWORD, lpName: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn MapViewOfFile(hMap: HANDLE, access: DWORD, offHigh: DWORD, offLow: DWORD, bytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(base: ?*const anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn LockFileEx(handle: HANDLE, flags: DWORD, reserved: DWORD, low: DWORD, high: DWORD, overlapped: *OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn UnlockFileEx(handle: HANDLE, reserved: DWORD, low: DWORD, high: DWORD, overlapped: *OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetProcessTimes(handle: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) BOOL;

    // PROCESS_MEMORY_COUNTERS: SIZE_T fields are usize; cb/PageFaultCount are DWORD.
    const PROCESS_MEMORY_COUNTERS = extern struct {
        byteCount: DWORD,
        PageFaultCount: DWORD,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    };
    extern "psapi" fn GetProcessMemoryInfo(process: HANDLE, counters: *PROCESS_MEMORY_COUNTERS, byteCount: DWORD) callconv(.winapi) BOOL;
} else struct {};

/// Windows peak working set size in bytes, from GetProcessMemoryInfo. Returns 0 if
/// the query fails (the caller treats that as "no signal").
fn windowsPeakWorkingSet() usize {
    var counters = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS);
    counters.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
    if (win.GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) == 0) return 0;
    return counters.PeakWorkingSetSize;
}

// ---------------------------------------------------------------------------
// Memory mapping
// ---------------------------------------------------------------------------

/// One file-backed shared mapping covering a single fixed-size section of the file.
/// The section's base address never moves for the section's lifetime; growth happens by
/// creating additional Sections, never by remapping or moving an existing one.
pub const Section = struct {
    map: []align(page) u8,
    handle: if (isWindows) win.HANDLE else void,

    /// Release this section's mapping.
    pub fn unmap(self: *Section) void {
        if (isWindows) {
            _ = win.UnmapViewOfFile(self.map.ptr);
            _ = win.CloseHandle(self.handle);
        } else {
            std.posix.munmap(self.map);
        }
    }
};

/// Map `[fileOffset, fileOffset + length)` of `file` as a shared, read/write section.
/// The caller guarantees the file is at least `fileOffset + length` bytes long and that
/// `fileOffset` is a multiple of the OS allocation granularity (it is: every caller
/// passes a multiple of `sectionSize`, which is 16 MiB).
pub fn mapSection(file: std.Io.File, fileOffset: u64, length: usize) !Section {
    if (isWindows) {
        // One file-mapping object per section. Passing max-size 0 makes the object track
        // the current file size; the view starts at the section's file offset. The file
        // has already been extended to cover this section, so the view is fully backed.
        const mappingHandle = win.CreateFileMappingW(file.handle, null, win.PAGE_READWRITE, 0, 0, null) orelse return error.MapFailed;
        errdefer _ = win.CloseHandle(mappingHandle);
        const offHigh: win.DWORD = @intCast(fileOffset >> 32);
        const offLow: win.DWORD = @intCast(fileOffset & 0xFFFFFFFF);
        const ptr = win.MapViewOfFile(mappingHandle, win.FILE_MAP_READ | win.FILE_MAP_WRITE, offHigh, offLow, length) orelse return error.MapFailed;
        const base: [*]align(page) u8 = @ptrCast(@alignCast(ptr));
        return .{ .map = base[0..length], .handle = mappingHandle };
    } else {
        const mapped = try std.posix.mmap(
            null,
            length,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            fileOffset,
        );
        return .{ .map = mapped, .handle = {} };
    }
}

// ---------------------------------------------------------------------------
// File locking
// ---------------------------------------------------------------------------

/// Take an exclusive advisory lock on `file`.
/// Returns true once the lock is held. When `blocking` is false and another holder
/// owns the lock, returns false immediately instead of blocking. Other failures error.
pub fn lockFileExclusive(file: std.Io.File, blocking: bool) !bool {
    if (isWindows) {
        var overlapped = std.mem.zeroes(win.OVERLAPPED);
        var flags: win.DWORD = win.LOCKFILE_EXCLUSIVE_LOCK;
        if (!blocking) flags |= win.LOCKFILE_FAIL_IMMEDIATELY;
        if (win.LockFileEx(file.handle, flags, 0, win.lockAllLow, win.lockAllHigh, &overlapped) != 0) return true;
        if (!blocking) return false; // contended (ERROR_LOCK_VIOLATION / IO_PENDING)
        return error.LockFailed;
    } else {
        const operation: i32 = if (blocking)
            std.posix.LOCK.EX
        else
            std.posix.LOCK.EX | std.posix.LOCK.NB;
        const resultCode = std.c.flock(file.handle, operation);
        switch (std.c.errno(resultCode)) {
            .SUCCESS => return true,
            .AGAIN => return false, // only reachable in the non-blocking case
            else => |errno| return std.posix.unexpectedErrno(errno),
        }
    }
}

/// Release the advisory lock held on `file`.
pub fn unlockFile(file: std.Io.File) void {
    if (isWindows) {
        var overlapped = std.mem.zeroes(win.OVERLAPPED);
        _ = win.UnlockFileEx(file.handle, 0, win.lockAllLow, win.lockAllHigh, &overlapped);
    } else {
        _ = std.c.flock(file.handle, std.posix.LOCK.UN);
    }
}

// ---------------------------------------------------------------------------
// Process
// ---------------------------------------------------------------------------

/// The current process id.
pub fn currentPid() u32 {
    if (isWindows) {
        return @intCast(win.GetCurrentProcessId());
    } else {
        return @intCast(std.c.getpid());
    }
}

/// A token identifying a specific INCARNATION of a process: its start time.
/// PIDs are recycled by every OS, so "pid is alive" cannot distinguish a
/// crashed reader from an unrelated new process that inherited its pid; the
/// start time can. Returns null when the query fails (callers treat that
/// conservatively). Truncated to u32 by the coordination layer -- a false match needs
/// a recycled pid AND a start-time collision in the same microsecond class.
pub fn processStartToken(pid: u32) ?u64 {
    if (pid == 0) return null;
    if (isWindows) {
        const processHandle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
        defer _ = win.CloseHandle(processHandle);
        var creation: win.FILETIME = undefined;
        var exit: win.FILETIME = undefined;
        var kernel: win.FILETIME = undefined;
        var user: win.FILETIME = undefined;
        if (win.GetProcessTimes(processHandle, &creation, &exit, &kernel, &user) == 0) return null;
        return (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
    } else if (comptime builtin.target.os.tag.isDarwin()) {
        // kinfo_proc's first field is the extern_proc union whose overlay is
        // p_starttime (a timeval), so the start time sits at offset 0 of the
        // sysctl result.
        var buffer: [1024]u8 align(8) = undefined;
        var length: usize = buffer.len;
        var mib = [4]c_int{ 1, 14, 1, @intCast(pid) }; // CTL_KERN, KERN_PROC, KERN_PROC_PID, pid
        const resultCode = std.c.sysctl(&mib, 4, &buffer, &length, null, 0);
        if (std.c.errno(resultCode) != .SUCCESS or length < 16) return null;
        const sec = std.mem.readInt(i64, buffer[0..8], .little);
        const usec = std.mem.readInt(i32, buffer[8..12], .little);
        return @as(u64, @bitCast(sec)) *% 1_000_000 +% @as(u32, @bitCast(usec));
    } else {
        // Linux: field 22 of /proc/<pid>/stat is starttime in clock ticks.
        var pathBuffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pathBuffer, "/proc/{d}/stat", .{pid}) catch return null;
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
        defer file.close(io);
        var statBuffer: [512]u8 = undefined;
        const bytesRead = file.readPositionalAll(io, &statBuffer, 0) catch return null;
        const content = statBuffer[0..bytesRead];
        // comm can contain spaces/parens: skip past the LAST ')'.
        const close = std.mem.lastIndexOfScalar(u8, content, ')') orelse return null;
        var iterator = std.mem.tokenizeScalar(u8, content[close + 1 ..], ' ');
        // The token after ')' is field 3 (state); starttime is field 22.
        var field: usize = 3;
        while (iterator.next()) |tok| : (field += 1) {
            if (field == 22) return std.fmt.parseInt(u64, tok, 10) catch null;
        }
        return null;
    }
}

/// Returns true if the process with the given pid is alive.
/// pid==0 is always considered dead (free slot sentinel).
pub fn processAlive(pid: u32) bool {
    if (pid == 0) return false;
    if (isWindows) {
        const processHandle = win.OpenProcess(win.SYNCHRONIZE, 0, pid) orelse return false; // gone
        defer _ = win.CloseHandle(processHandle);
        // Alive if it has not become signaled (exited) within a 0ms wait.
        return win.WaitForSingleObject(processHandle, 0) == win.WAIT_TIMEOUT;
    } else {
        // kill(pid, 0): success or EPERM means alive; ESRCH means dead.
        std.posix.kill(
            @as(std.posix.pid_t, @intCast(pid)),
            @as(std.posix.SIG, @enumFromInt(0)),
        ) catch |err| switch (err) {
            error.ProcessNotFound => return false, // ESRCH: no such process
            error.PermissionDenied => return true, // EPERM: alive, not ours
            else => return true, // conservative: treat unknown errors as alive
        };
        return true;
    }
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// Peak resident set size of the current process, in bytes; a syscall per
/// call. The bench harness uses this as its memory signal. getrusage reports
/// ru_maxrss in KiB on Linux and in bytes on Darwin; Windows reports
/// PeakWorkingSetSize in bytes.
pub fn peakResidentBytes() usize {
    if (isWindows) return windowsPeakWorkingSet();
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: usize = @intCast(usage.maxrss);
    return if (builtin.os.tag == .macos) maxrss else maxrss * 1024;
}

test "processStartToken identifies the current process incarnation" {
    const tok = processStartToken(currentPid());
    try std.testing.expect(tok != null);
    // Stable across repeated queries of the same incarnation.
    try std.testing.expectEqual(tok, processStartToken(currentPid()));
}

test "peakResidentBytes returns a plausible nonzero value" {
    const rss = peakResidentBytes();
    try std.testing.expect(rss > 64 * 1024);
}

/// Cumulative page-fault counts for the current process; a syscall per call.
/// `minor` is soft faults served without disk I/O (ru_minflt); `major` is
/// hard faults that required a disk read (ru_majflt). The bench harness
/// samples this before/after a phase and reports the delta as a
/// memory-latency signal. On Windows getrusage is not available, so this
/// reports the single PageFaultCount (which does not split minor/major) as
/// `minor` and 0 as `major`.
pub fn pageFaults() struct { minor: u64, major: u64 } {
    if (isWindows) {
        var counters = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS);
        counters.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
        if (win.GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) == 0) {
            return .{ .minor = 0, .major = 0 };
        }
        return .{ .minor = @intCast(counters.PageFaultCount), .major = 0 };
    }
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return .{ .minor = @intCast(usage.minflt), .major = @intCast(usage.majflt) };
}

test "pageFaults returns plausible values" {
    const faults = pageFaults();
    // A running process has taken at least some minor faults to map its image.
    try std.testing.expect(faults.minor > 0);
}
