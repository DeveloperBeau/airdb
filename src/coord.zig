// coord.zig -- coordination file for multi-process attach/detach and latest-version signal.
//
// Layout (4096-byte mmap'd file):
//   [0..8]   magic        u64 LE  (coord_magic)
//   [8..12]  attach_count u32     (atomic, 4-aligned)
//   [12..16] reserved     (zero)
//   [16..24] latest_ver   u64     (atomic, 8-aligned)
//   [24..64] reserved     (zero)
//   [64..1088] participant slots  64 x 16 bytes each
//              slot layout: [pid u32 @+0][reserved u32 @+4][min_pinned u64 @+8]
//              pid==0 means slot is free; min_pinned==sentinel_max means "pins nothing"
//
// Zig 0.16 notes (same adaptations as file_store.zig):
//   - File I/O via std.Io.File and std.Io.Dir.*Absolute(io, path, .{})
//   - mmap PROT flags: .{ .READ = true, .WRITE = true }
//   - mmap flags:      .{ .TYPE = .SHARED }
//   - mmap return:     []align(std.heap.page_size_min) u8
//   - File.length(io), File.setLength(io, n), File.close(io)

const std = @import("std");
const platform = @import("platform.zig");

pub fn coordIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const coord_magic: u64 = 0x6169726462_4300;
const coord_size: usize = 4096;
const off_magic: usize = 0; // u64
const off_attach: usize = 8; // u32 atomic, 4-aligned
const off_latest: usize = 16; // u64 atomic, 8-aligned

pub const sentinel_max: u64 = std.math.maxInt(u64);
const participant_slots: usize = 64;
const participants_off: usize = 64;
const slot_stride: usize = 16;

fn currentPid() u32 {
    return platform.currentPid();
}

/// Returns true if the process with the given pid is alive.
/// pid==0 is always considered dead (free slot sentinel).
fn pidAlive(pid: u32) bool {
    return platform.processAlive(pid);
}

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

        const map = try platform.mapFixedSize(file, coord_size);
        errdefer platform.unmap(map);

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
        platform.unmap(self.map);
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
        _ = try platform.lockFileExclusive(self.file, true);
    }

    /// Non-blocking exclusive flock attempt.
    /// Returns error.WouldBlock immediately if another holder holds the lock.
    pub fn tryLockExclusive(self: *Coord) !void {
        if (!try platform.lockFileExclusive(self.file, false)) return error.WouldBlock;
    }

    /// Release the flock held by this file description.
    pub fn unlock(self: *Coord) void {
        platform.unlockFile(self.file);
    }

    fn slotPidPtr(self: *Coord, idx: usize) *u32 {
        return @ptrCast(@alignCast(&self.map[participants_off + idx * slot_stride]));
    }

    fn slotMinPtr(self: *Coord, idx: usize) *u64 {
        return @ptrCast(@alignCast(&self.map[participants_off + idx * slot_stride + 8]));
    }

    /// Claim a free participant slot. Returns the slot index on success,
    /// or null if all 64 slots are occupied. Uses CAS to avoid races.
    pub fn claimSlot(self: *Coord) !?usize {
        const my_pid: u32 = @intCast(currentPid());
        var i: usize = 0;
        while (i < participant_slots) : (i += 1) {
            const p = self.slotPidPtr(i);
            if (@cmpxchgStrong(u32, p, 0, my_pid, .seq_cst, .seq_cst) == null) {
                @atomicStore(u64, self.slotMinPtr(i), sentinel_max, .seq_cst);
                return i;
            }
        }
        return null;
    }

    /// Release a previously claimed slot. Zeros the pid last so no reader
    /// observes a stale min_pinned after the slot appears free.
    pub fn releaseSlot(self: *Coord, idx: usize) void {
        @atomicStore(u64, self.slotMinPtr(idx), sentinel_max, .seq_cst);
        @atomicStore(u32, self.slotPidPtr(idx), 0, .seq_cst);
    }

    /// Publish the minimum pinned version for this slot (release ordering).
    pub fn publishMinPinned(self: *Coord, idx: usize, v: u64) void {
        @atomicStore(u64, self.slotMinPtr(idx), v, .release);
    }

    pub fn slotMinPinnedForTest(self: *Coord, idx: usize) u64 {
        return @atomicLoad(u64, self.slotMinPtr(idx), .acquire);
    }

    pub fn slotPidForTest(self: *Coord, idx: usize) u32 {
        return @atomicLoad(u32, self.slotPidPtr(idx), .seq_cst);
    }

    /// Compute the global reclaim horizon: the minimum min_pinned across all
    /// live participant slots. Slots whose process no longer exists are
    /// reclaimed (pid zeroed) in the same pass. Returns `fallback` if no
    /// live slot publishes a pinned version below it.
    pub fn globalHorizon(self: *Coord, fallback: u64) u64 {
        var min_v: u64 = fallback;
        var i: usize = 0;
        while (i < participant_slots) : (i += 1) {
            const pid = @atomicLoad(u32, self.slotPidPtr(i), .seq_cst);
            if (pid == 0) continue;
            if (!pidAlive(pid)) {
                @atomicStore(u32, self.slotPidPtr(i), 0, .seq_cst); // reclaim dead slot
                continue;
            }
            const mp = @atomicLoad(u64, self.slotMinPtr(i), .acquire);
            if (mp < min_v) min_v = mp;
        }
        return min_v;
    }

    /// Test helper: write a slot directly without going through claimSlot.
    /// Allows tests to simulate a slot owned by an arbitrary (possibly dead) pid.
    pub fn forgeSlotForTest(self: *Coord, idx: usize, pid: u32, min_pinned: u64) void {
        @atomicStore(u64, self.slotMinPtr(idx), min_pinned, .seq_cst);
        @atomicStore(u32, self.slotPidPtr(idx), pid, .seq_cst);
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

test "claim returns a slot index, publish and read back min_pinned, release frees it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "p.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const idx = (try c.claimSlot()).?;
    c.publishMinPinned(idx, 7);
    try testing.expectEqual(@as(u64, 7), c.slotMinPinnedForTest(idx));
    c.releaseSlot(idx);
    try testing.expectEqual(@as(u32, 0), c.slotPidForTest(idx));
}

test "two claims get distinct slots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "p2.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const a = (try c.claimSlot()).?;
    const b = (try c.claimSlot()).?;
    try testing.expect(a != b);
    c.releaseSlot(a);
    c.releaseSlot(b);
}

test "globalHorizon is the min of live slots min_pinned, clamped to fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "gh.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const a = (try c.claimSlot()).?;
    c.publishMinPinned(a, 5);
    try testing.expectEqual(@as(u64, 5), c.globalHorizon(100));
    c.publishMinPinned(a, sentinel_max);
    try testing.expectEqual(@as(u64, 100), c.globalHorizon(100));
    c.releaseSlot(a);
}

test "globalHorizon ignores and reclaims a dead-pid slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "dead.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const live = (try c.claimSlot()).?;
    c.publishMinPinned(live, sentinel_max);
    c.forgeSlotForTest(1, 0x7fffffff, 3); // an almost-certainly-dead pid with a low min_pinned
    try testing.expectEqual(@as(u64, 50), c.globalHorizon(50));
    try testing.expectEqual(@as(u32, 0), c.slotPidForTest(1)); // reclaimed
    c.releaseSlot(live);
}
