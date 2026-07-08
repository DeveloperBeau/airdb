// coord.zig -- coordination file for multi-process attach/detach and latest-version signal.
//
// Layout (4096-byte mmap'd file):
//   [0..8]   magic        u64 LE  (coord_magic)
//   [8..12]  attach_count u32     (atomic, 4-aligned)
//   [12..16] reserved     (zero)
//   [16..24] latest_ver   u64     (atomic, 8-aligned)
//   [24..64] reserved     (zero)
//   [64..1088] participant slots  64 x 16 bytes each
//              slot layout: [pid u32 @+0][start_token u32 @+4][min_pinned u64 @+8]
//              pid==0 means slot is free; min_pinned==sentinel_max means "pins
//              nothing". start_token is the (truncated) process start time of
//              the claimer: a recycled pid alone cannot keep a dead reader's
//              slot alive, the incarnation must match too.
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
    section: platform.Section,
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

        // Fixed-size coord file: a single section covering the whole page. No growth.
        var section = try platform.mapSection(file, 0, coord_size);
        errdefer section.unmap();
        const map = section.map;

        // Initialize with double-checked locking. Two processes racing on a
        // brand-new coord file must not both see "magic absent" and zero the
        // page: the loser would wipe the winner's attach count, participant
        // slot, and published pins, letting a writer compute a reclaim horizon
        // that ignores live readers. The exclusive flock serializes the
        // check-then-init window; the magic is release-stored AFTER the zeroing
        // so any process that acquire-loads it is guaranteed to see a fully
        // initialized page without taking the lock. The lock is only touched on
        // the magic-absent path, so opening an existing database never blocks
        // behind a writer holding the same flock for a transaction.
        const magic_ptr: *u64 = @ptrCast(@alignCast(&map[off_magic]));
        if (@atomicLoad(u64, magic_ptr, .acquire) != coord_magic) {
            _ = try platform.lockFileExclusive(file, true);
            defer platform.unlockFile(file);
            if (@atomicLoad(u64, magic_ptr, .acquire) != coord_magic) {
                // New file: zero the entire page, then stamp the magic last.
                @memset(map[0..coord_size], 0);
                @atomicStore(u64, magic_ptr, coord_magic, .release);
            }
        }
        // Existing file with correct magic: leave all fields as-is.

        return Coord{ .file = file, .section = section, .map = map };
    }

    pub fn deinit(self: *Coord) void {
        self.section.unmap();
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

    fn slotTokenPtr(self: *Coord, idx: usize) *u32 {
        return @ptrCast(@alignCast(&self.map[participants_off + idx * slot_stride + 4]));
    }

    fn slotMinPtr(self: *Coord, idx: usize) *u64 {
        return @ptrCast(@alignCast(&self.map[participants_off + idx * slot_stride + 8]));
    }

    // The (pid, token) pair viewed as one aligned u64 (LE: low 32 bits pid,
    // high 32 bits token). Claiming publishes both fields in a SINGLE CAS: a
    // pid-first claim left a (live pid, token 0) window that a concurrent
    // globalHorizon read as a recycled pid and reclaimed -- after which a
    // third process could re-claim the slot and the two owners overwrote each
    // other's pins, hiding a live reader from the reclaim horizon.
    fn slotClaimPtr(self: *Coord, idx: usize) *u64 {
        return @ptrCast(@alignCast(&self.map[participants_off + idx * slot_stride]));
    }

    /// Claim a free participant slot. Returns the slot index on success,
    /// or null if all 64 slots are occupied. Uses CAS to avoid races.
    pub fn claimSlot(self: *Coord) !?usize {
        const my_pid: u32 = @intCast(currentPid());
        const my_token: u32 = @truncate(platform.processStartToken(my_pid) orelse 0);
        const claim: u64 = (@as(u64, my_token) << 32) | my_pid;
        var i: usize = 0;
        while (i < participant_slots) : (i += 1) {
            // The sentinel store below is LOAD-BEARING: a release-freed slot's
            // min is already sentinel, but a RECLAIM-freed slot keeps its dead
            // owner's min (reclaim touches only the claim word). Without the
            // store, inheriting such a slot would depress every process's
            // reclaim horizon with a stale low pin for as long as this claim
            // lives. Between the CAS and the store a horizon scan can read the
            // stale min -- a too-low horizon, which is merely conservative.
            if (@cmpxchgStrong(u64, self.slotClaimPtr(i), 0, claim, .seq_cst, .seq_cst) == null) {
                @atomicStore(u64, self.slotMinPtr(i), sentinel_max, .seq_cst);
                return i;
            }
        }
        return null;
    }

    /// Release a previously claimed slot. Resets min_pinned first, then clears
    /// pid+token in one store, so no reader observes a stale min_pinned after
    /// the slot appears free.
    pub fn releaseSlot(self: *Coord, idx: usize) void {
        @atomicStore(u64, self.slotMinPtr(idx), sentinel_max, .seq_cst);
        @atomicStore(u64, self.slotClaimPtr(idx), 0, .seq_cst);
    }

    /// Publish the minimum pinned version for this slot. seq_cst, not release:
    /// readers publish a pin and then VALIDATE by loading latest_version with
    /// no intervening syscall. That store->load sequence is the classic
    /// store-buffering pattern -- with a plain release store, x86 may order the
    /// validating load before the pin store drains, letting a concurrent
    /// writer's horizon miss the pin while the reader's validation misses the
    /// new version. The seq_cst store compiles to a fenced exchange on x86 and
    /// closes it. (The writer side is fenced by the lock/unlock syscalls.)
    pub fn publishMinPinned(self: *Coord, idx: usize, v: u64) void {
        @atomicStore(u64, self.slotMinPtr(idx), v, .seq_cst);
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
    // Free a dead or recycled slot, but ONLY if it still holds the exact
    // (pid, token) word the caller sampled. The liveness verdict spans
    // syscalls, and in that window the dead owner's slot can be released and
    // re-claimed by a live process; an unconditional clear wiped the new
    // owner's published pin and freed its slot for a second claimant -- two
    // processes then shared one slot and overwrote each other's pins, hiding
    // a live reader from the reclaim horizon. The CAS makes a re-claimed slot
    // fail the exchange and survive untouched. (The whole word must clear,
    // not just the pid half: a leftover token kept the u64 nonzero and the
    // packed claim CAS could never take the slot again.) min_pinned is left
    // alone: a free slot's min is never read (word == 0 is skipped), and the
    // next claimant sentinels it itself. Residual ABA -- the same pid AND the
    // same 32-bit start token re-claimed within the window -- is accepted.
    fn reclaimSlot(self: *Coord, idx: usize, sampled_word: u64) void {
        _ = @cmpxchgStrong(u64, self.slotClaimPtr(idx), sampled_word, 0, .seq_cst, .seq_cst);
    }

    pub fn globalHorizon(self: *Coord, fallback: u64) u64 {
        var min_v: u64 = fallback;
        var i: usize = 0;
        while (i < participant_slots) : (i += 1) {
            // Sample pid and token as ONE word so the liveness verdict and the
            // guarded reclaim below all refer to the same claim -- separate
            // loads could pair one owner's pid with its successor's token.
            const word = @atomicLoad(u64, self.slotClaimPtr(i), .seq_cst);
            if (word == 0) continue;
            const pid: u32 = @truncate(word);
            if (!pidAlive(pid)) {
                self.reclaimSlot(i, word);
                continue;
            }
            // The pid is alive, but pids are recycled: verify the incarnation.
            // A live unrelated process that inherited a dead reader's pid would
            // otherwise pin the horizon forever. Unavailable tokens on EITHER
            // side (query failed here, or the claimer could not obtain one and
            // stored 0) are treated as a match -- conservative, never unsafe.
            const stored_token: u32 = @truncate(word >> 32);
            if (stored_token != 0) {
                if (platform.processStartToken(pid)) |tok| {
                    if (@as(u32, @truncate(tok)) != stored_token) {
                        self.reclaimSlot(i, word); // recycled pid
                        continue;
                    }
                }
            }
            const mp = @atomicLoad(u64, self.slotMinPtr(i), .acquire);
            if (mp < min_v) min_v = mp;
        }
        return min_v;
    }

    /// Test helper: write a slot directly without going through claimSlot.
    /// Allows tests to simulate a slot owned by an arbitrary (possibly dead or
    /// recycled) pid with an arbitrary incarnation token.
    pub fn forgeSlotForTest(self: *Coord, idx: usize, pid: u32, token: u32, min_pinned: u64) void {
        @atomicStore(u64, self.slotMinPtr(idx), min_pinned, .seq_cst);
        @atomicStore(u32, self.slotTokenPtr(idx), token, .seq_cst);
        @atomicStore(u32, self.slotPidPtr(idx), pid, .seq_cst);
    }
};

// Tests of file-private invariants; the main suite lives in coordTests.zig.

const testing = std.testing;

test "claimSlot publishes pid and incarnation token in one atomic word" {
    // Regression: the pid was CAS'd first and the token stored after, leaving
    // a (live pid, token 0) window a concurrent globalHorizon could misread as
    // a recycled pid and reclaim -- a third process then re-claimed the slot
    // and the two owners overwrote each other's pins. The claim is now a
    // single u64 CAS of (token << 32) | pid; both fields must land together.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "packedclaim.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();

    const idx = (try c.claimSlot()).?;
    defer c.releaseSlot(idx);
    const my_pid: u32 = @intCast(platform.currentPid());
    const my_token: u32 = @truncate(platform.processStartToken(my_pid) orelse 0);
    const word = @atomicLoad(u64, c.slotClaimPtr(idx), .seq_cst);
    try testing.expectEqual((@as(u64, my_token) << 32) | my_pid, word);
    try testing.expectEqual(sentinel_max, @atomicLoad(u64, c.slotMinPtr(idx), .seq_cst));
}

test "a reclaimed slot becomes claimable again" {
    // Regression: reclaim cleared only the pid half of the claim word; the
    // stale incarnation token kept the slot's u64 nonzero, so the packed
    // claim CAS never matched it again -- every dead reader permanently
    // burned a slot until the table was exhausted.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "reclaimable.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();

    c.forgeSlotForTest(0, 0x7fffffff, 0xdead, 3); // dead pid, nonzero token
    try testing.expectEqual(@as(u64, 50), c.globalHorizon(50));
    try testing.expectEqual(@as(u64, 0), @atomicLoad(u64, c.slotClaimPtr(0), .seq_cst));
    // Fill the whole table: every slot, including the reclaimed one, must land.
    var claimed: [participant_slots]usize = undefined;
    for (&claimed) |*slot| slot.* = (try c.claimSlot()) orelse return error.SlotLeaked;
    try testing.expectEqual(@as(?usize, null), try c.claimSlot());
    for (claimed) |idx| c.releaseSlot(idx);
}

test "reclaim leaves a slot alone when its claim word changed since the sample" {
    // Regression: the liveness verdict spans syscalls; a slot released and
    // re-claimed inside that window was wiped unconditionally -- the new
    // owner's pin vanished and a second claimant took the same slot. Reclaim
    // now exchanges against the sampled word and must fail on a mismatch.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "guardedreclaim.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();

    c.forgeSlotForTest(2, 0x7fffffff, 0xbeef, 9); // the dead owner we sampled
    const sampled = @atomicLoad(u64, c.slotClaimPtr(2), .seq_cst);
    // The slot changes hands before the reclaim lands.
    const my_pid: u32 = @intCast(platform.currentPid());
    c.forgeSlotForTest(2, my_pid, 0xf00d, 5);
    c.reclaimSlot(2, sampled);
    try testing.expectEqual(my_pid, c.slotPidForTest(2)); // new owner intact
    try testing.expectEqual(@as(u64, 5), @atomicLoad(u64, c.slotMinPtr(2), .seq_cst));
    // With the matching word, the reclaim goes through.
    const word2 = @atomicLoad(u64, c.slotClaimPtr(2), .seq_cst);
    c.reclaimSlot(2, word2);
    try testing.expectEqual(@as(u64, 0), @atomicLoad(u64, c.slotClaimPtr(2), .seq_cst));
}

test {
    _ = @import("coordTests.zig");
}
