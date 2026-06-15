// coord.zig -- coordination file for multi-process attach/detach and latest-version signal.
//
// Layout (4096-byte mmap'd file):
//   [0..8]   magic        u64 LE  (coord_magic)
//   [8..12]  attach_count u32     (atomic, 4-aligned)
//   [12..16] reserved     (zero)
//   [16..24] latest_ver   u64     (atomic, 8-aligned)
//   [24..]   reserved     (zero)
//
// Zig 0.16 notes (same adaptations as file_store.zig):
//   - File I/O via std.Io.File and std.Io.Dir.*Absolute(io, path, .{})
//   - mmap PROT flags: .{ .READ = true, .WRITE = true }
//   - mmap flags:      .{ .TYPE = .SHARED }
//   - mmap return:     []align(std.heap.page_size_min) u8
//   - File.length(io), File.setLength(io, n), File.close(io)

const std = @import("std");

pub fn coordIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const coord_magic: u64 = 0x6169726462_4300;
const coord_size: usize = 4096;
const off_magic: usize = 0; // u64
const off_attach: usize = 8; // u32 atomic, 4-aligned
const off_latest: usize = 16; // u64 atomic, 8-aligned

pub const Coord = struct {
    file: std.Io.File,
    map: []align(std.heap.page_size_min) u8,

    /// Open an existing coord file or create one if it does not exist.
    /// Does not truncate an existing file.
    /// If the file is new (magic absent), zeroes the mapping and writes the magic.
    /// If the file already has the magic, leaves all fields intact.
    pub fn openOrCreate(path: []const u8) !Coord {
        const io = coordIo();

        // Try open first; create only on FileNotFound.
        // This avoids any risk of truncating an existing coord file.
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close(io);

        const len = try file.length(io);
        if (len < coord_size) try file.setLength(io, coord_size);

        const map = try std.posix.mmap(
            null,
            coord_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(map);

        const magic = std.mem.readInt(u64, map[off_magic..][0..8], .little);
        if (magic != coord_magic) {
            // New file: zero the entire page and stamp the magic.
            @memset(map[0..coord_size], 0);
            std.mem.writeInt(u64, map[off_magic..][0..8], coord_magic, .little);
        }
        // Existing file with correct magic: leave all fields as-is.

        return Coord{ .file = file, .map = map };
    }

    pub fn deinit(self: *Coord) void {
        std.posix.munmap(self.map);
        self.file.close(coordIo());
    }

    fn attachPtr(self: *Coord) *u32 {
        return @ptrCast(@alignCast(&self.map[off_attach]));
    }

    fn latestPtr(self: *Coord) *u64 {
        return @ptrCast(@alignCast(&self.map[off_latest]));
    }

    /// Atomically increment attach count, return new value.
    pub fn attach(self: *Coord) u32 {
        return @atomicRmw(u32, self.attachPtr(), .Add, 1, .seq_cst) + 1;
    }

    /// Atomically decrement attach count, return new value.
    pub fn detach(self: *Coord) u32 {
        return @atomicRmw(u32, self.attachPtr(), .Sub, 1, .seq_cst) - 1;
    }

    /// Read the current attach count.
    pub fn attachCount(self: *Coord) u32 {
        return @atomicLoad(u32, self.attachPtr(), .seq_cst);
    }

    /// Store the latest committed version (release ordering).
    pub fn setLatestVersion(self: *Coord, v: u64) void {
        @atomicStore(u64, self.latestPtr(), v, .release);
    }

    /// Load the latest committed version (acquire ordering).
    pub fn latestVersion(self: *Coord) u64 {
        return @atomicLoad(u64, self.latestPtr(), .acquire);
    }

    /// Block until this process/thread holds an exclusive flock on the coord file.
    pub fn lockExclusive(self: *Coord) !void {
        const rc = std.c.flock(self.file.handle, std.posix.LOCK.EX);
        switch (std.c.errno(rc)) {
            .SUCCESS => {},
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }

    /// Non-blocking exclusive flock attempt.
    /// Returns error.WouldBlock immediately if another holder holds the lock.
    pub fn tryLockExclusive(self: *Coord) !void {
        const rc = std.c.flock(self.file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (std.c.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WouldBlock,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }

    /// Release the flock held by this file description.
    pub fn unlock(self: *Coord) void {
        _ = std.c.flock(self.file.handle, std.posix.LOCK.UN);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "coord create initializes magic and zero attach count, reopen reads them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "x.coord" });
    defer testing.allocator.free(cpath);

    var c1 = try Coord.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 1), c1.attach());
    var c2 = try Coord.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 2), c2.attach());
    try testing.expectEqual(@as(u32, 1), c2.detach());
    c2.deinit();
    _ = c1.detach();
    c1.deinit();
}

test "latest_version round-trips through the mapping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "y.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    c.setLatestVersion(42);
    try testing.expectEqual(@as(u64, 42), c.latestVersion());
}

test "exclusive lock blocks a second holder via the same coord file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "z.coord" });
    defer testing.allocator.free(cpath);

    var a = try Coord.openOrCreate(cpath);
    defer a.deinit();
    var b = try Coord.openOrCreate(cpath); // separate open file description -> independent flock that contends
    defer b.deinit();

    try a.lockExclusive();
    try testing.expectError(error.WouldBlock, b.tryLockExclusive());
    a.unlock();
    try b.tryLockExclusive();
    b.unlock();
}
