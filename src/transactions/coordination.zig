//! Coordination file for multi-process attach/detach and latest-version signal.
//!
//! Layout (4096-byte mmap'd file):
//!   [0..8]   magic        u64 LE  (coordMagic)
//!   [8..12]  attachCount u32     (atomic, 4-aligned)
//!   [12..16] reserved     (zero)
//!   [16..24] latestVersion   u64     (atomic, 8-aligned)
//!   [24..64] reserved     (zero)
//!   [64..1088] participant slots  64 x 16 bytes each
//!              slot layout: [pid u32 @+0][startToken u32 @+4][minPinned u64 @+8]
//!              pid==0 means slot is free; minPinned==sentinelMax means "pins
//!              nothing". startToken is the (truncated) process start time of
//!              the claimer: a recycled pid alone cannot keep a dead reader's
//!              slot alive, the incarnation must match too.
//!
//! Zig 0.16 notes (same adaptations as fileStore.zig):
//!   - File I/O via std.Io.File and std.Io.Dir.*Absolute(io, path, .{})
//!   - mmap PROT flags: .{ .READ = true, .WRITE = true }
//!   - mmap flags:      .{ .TYPE = .SHARED }
//!   - mmap return:     []align(std.heap.page_size_min) u8
//!   - File.length(io), File.setLength(io, n), File.close(io)

const std = @import("std");
const platform = @import("../platform.zig");

/// The blocking Io instance used for all coord-file operations.
pub fn coordIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Magic stamped at offset 0 once a coord file is fully initialized.
pub const coordMagic: u64 = 0x6169726462_4300;
const coordSize: usize = 4096;
const offMagic: usize = 0; // u64
const offAttach: usize = 8; // u32 atomic, 4-aligned
const offLatest: usize = 16; // u64 atomic, 8-aligned

/// "Pins nothing" sentinel for a participant slot's minPinned field.
pub const sentinelMax: u64 = std.math.maxInt(u64);
const participantSlots: usize = 64;
const participantsOff: usize = 64;
const slotStride: usize = 16;

fn currentPid() u32 {
    return platform.currentPid();
}

/// Returns true if the process with the given pid is alive.
/// pid==0 is always considered dead (free slot sentinel).
fn pidAlive(pid: u32) bool {
    return platform.processAlive(pid);
}

/// The mmap'd coordination page shared by every process attached to one
/// database: attach count, latest committed version, the cross-process write
/// lock, and 64 participant slots publishing reader pins for the reclaim
/// horizon.
pub const Coordination = struct {
    file: std.Io.File,
    section: platform.Section,
    map: []align(std.heap.page_size_min) u8,

    /// Open an existing coord file or create one if it does not exist.
    /// Does not truncate an existing file.
    /// If the file is new (magic absent), zeroes the mapping and writes the magic.
    /// If the file already has the magic, leaves all fields intact.
    pub fn openOrCreate(path: []const u8) !Coordination {
        const io = coordIo();

        // Try open first; create only on FileNotFound.
        // This avoids any risk of truncating an existing coord file.
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.Io.Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close(io);

        const length = try file.length(io);
        if (length < coordSize) try file.setLength(io, coordSize);

        // Fixed-size coord file: a single section covering the whole page. No growth.
        var section = try platform.mapSection(file, 0, coordSize);
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
        const magicPtr: *u64 = @ptrCast(@alignCast(&map[offMagic]));
        if (@atomicLoad(u64, magicPtr, .acquire) != coordMagic) {
            _ = try platform.lockFileExclusive(file, true);
            defer platform.unlockFile(file);
            if (@atomicLoad(u64, magicPtr, .acquire) != coordMagic) {
                // New file: zero the entire page, then stamp the magic last.
                @memset(map[0..coordSize], 0);
                @atomicStore(u64, magicPtr, coordMagic, .release);
            }
        }
        // Existing file with correct magic: leave all fields as-is.

        return Coordination{ .file = file, .section = section, .map = map };
    }

    /// Unmap the coord page and close the file.
    pub fn deinit(self: *Coordination) void {
        self.section.unmap();
        self.file.close(coordIo());
    }

    fn attachPtr(self: *Coordination) *u32 {
        return @ptrCast(@alignCast(&self.map[offAttach]));
    }

    fn latestPtr(self: *Coordination) *u64 {
        return @ptrCast(@alignCast(&self.map[offLatest]));
    }

    /// Atomically increment attach count, return new value.
    pub fn attach(self: *Coordination) u32 {
        return @atomicRmw(u32, self.attachPtr(), .Add, 1, .seq_cst) + 1;
    }

    /// Atomically decrement attach count, return new value.
    pub fn detach(self: *Coordination) u32 {
        return @atomicRmw(u32, self.attachPtr(), .Sub, 1, .seq_cst) - 1;
    }

    /// Read the current attach count.
    pub fn attachCount(self: *Coordination) u32 {
        return @atomicLoad(u32, self.attachPtr(), .seq_cst);
    }

    /// Store the latest committed version (release ordering).
    pub fn setLatestVersion(self: *Coordination, version: u64) void {
        @atomicStore(u64, self.latestPtr(), version, .release);
    }

    /// Load the latest committed version (acquire ordering).
    pub fn latestVersion(self: *Coordination) u64 {
        return @atomicLoad(u64, self.latestPtr(), .acquire);
    }

    /// Block until this process/thread holds an exclusive flock on the coord file.
    pub fn lockExclusive(self: *Coordination) !void {
        _ = try platform.lockFileExclusive(self.file, true);
    }

    /// Non-blocking exclusive flock attempt.
    /// Returns error.WouldBlock immediately if another holder holds the lock.
    pub fn tryLockExclusive(self: *Coordination) !void {
        if (!try platform.lockFileExclusive(self.file, false)) return error.WouldBlock;
    }

    /// Release the flock held by this file description.
    pub fn unlock(self: *Coordination) void {
        platform.unlockFile(self.file);
    }

    fn slotPidPtr(self: *Coordination, slotIndex: usize) *u32 {
        return @ptrCast(@alignCast(&self.map[participantsOff + slotIndex * slotStride]));
    }

    fn slotTokenPtr(self: *Coordination, slotIndex: usize) *u32 {
        return @ptrCast(@alignCast(&self.map[participantsOff + slotIndex * slotStride + 4]));
    }

    fn slotMinPtr(self: *Coordination, slotIndex: usize) *u64 {
        return @ptrCast(@alignCast(&self.map[participantsOff + slotIndex * slotStride + 8]));
    }

    // The (pid, token) pair viewed as one aligned u64 (LE: low 32 bits pid,
    // high 32 bits token). Claiming publishes both fields in a SINGLE CAS: a
    // pid-first claim left a (live pid, token 0) window that a concurrent
    // globalHorizon read as a recycled pid and reclaimed -- after which a
    // third process could re-claim the slot and the two owners overwrote each
    // other's pins, hiding a live reader from the reclaim horizon.
    fn slotClaimPtr(self: *Coordination, slotIndex: usize) *u64 {
        return @ptrCast(@alignCast(&self.map[participantsOff + slotIndex * slotStride]));
    }

    /// Claim a free participant slot. Returns the slot index on success,
    /// or null if all 64 slots are occupied. Uses CAS to avoid races.
    pub fn claimSlot(self: *Coordination) !?usize {
        const myPid: u32 = @intCast(currentPid());
        const myToken: u32 = @truncate(platform.processStartToken(myPid) orelse 0);
        const claim: u64 = (@as(u64, myToken) << 32) | myPid;
        var slotIndex: usize = 0;
        while (slotIndex < participantSlots) : (slotIndex += 1) {
            // The sentinel store below is LOAD-BEARING: a release-freed slot's
            // min is already sentinel, but a RECLAIM-freed slot keeps its dead
            // owner's min (reclaim touches only the claim word). Without the
            // store, inheriting such a slot would depress every process's
            // reclaim horizon with a stale low pin for as long as this claim
            // lives. Between the CAS and the store a horizon scan can read the
            // stale min -- a too-low horizon, which is merely conservative.
            if (@cmpxchgStrong(u64, self.slotClaimPtr(slotIndex), 0, claim, .seq_cst, .seq_cst) == null) {
                @atomicStore(u64, self.slotMinPtr(slotIndex), sentinelMax, .seq_cst);
                return slotIndex;
            }
        }
        return null;
    }

    /// Release a previously claimed slot. Resets minPinned first, then clears
    /// pid+token in one store, so no reader observes a stale minPinned after
    /// the slot appears free.
    pub fn releaseSlot(self: *Coordination, slotIndex: usize) void {
        @atomicStore(u64, self.slotMinPtr(slotIndex), sentinelMax, .seq_cst);
        @atomicStore(u64, self.slotClaimPtr(slotIndex), 0, .seq_cst);
    }

    /// Publish the minimum pinned version for this slot. seq_cst, not release:
    /// readers publish a pin and then VALIDATE by loading latestVersion with
    /// no intervening syscall. That store->load sequence is the classic
    /// store-buffering pattern -- with a plain release store, x86 may order the
    /// validating load before the pin store drains, letting a concurrent
    /// writer's horizon miss the pin while the reader's validation misses the
    /// new version. The seq_cst store compiles to a fenced exchange on x86 and
    /// closes it. (The writer side is fenced by the lock/unlock syscalls.)
    pub fn publishMinPinned(self: *Coordination, slotIndex: usize, version: u64) void {
        @atomicStore(u64, self.slotMinPtr(slotIndex), version, .seq_cst);
    }

    /// Test-only: the raw minPinned published by slot `slotIndex`.
    pub fn slotMinPinnedForTest(self: *Coordination, slotIndex: usize) u64 {
        return @atomicLoad(u64, self.slotMinPtr(slotIndex), .acquire);
    }

    /// Test-only: the raw pid recorded in slot `slotIndex` (0 when free).
    pub fn slotPidForTest(self: *Coordination, slotIndex: usize) u32 {
        return @atomicLoad(u32, self.slotPidPtr(slotIndex), .seq_cst);
    }

    // Free a dead or recycled slot, but ONLY if it still holds the exact
    // (pid, token) word the caller sampled. The liveness verdict spans
    // syscalls, and in that window the dead owner's slot can be released and
    // re-claimed by a live process; an unconditional clear wiped the new
    // owner's published pin and freed its slot for a second claimant -- two
    // processes then shared one slot and overwrote each other's pins, hiding
    // a live reader from the reclaim horizon. The CAS makes a re-claimed slot
    // fail the exchange and survive untouched. (The whole word must clear,
    // not just the pid half: a leftover token kept the u64 nonzero and the
    // packed claim CAS could never take the slot again.) minPinned is left
    // alone: a free slot's min is never read (word == 0 is skipped), and the
    // next claimant sentinels it itself. Residual ABA -- the same pid AND the
    // same 32-bit start token re-claimed within the window -- is accepted.
    fn reclaimSlot(self: *Coordination, slotIndex: usize, sampledWord: u64) void {
        _ = @cmpxchgStrong(u64, self.slotClaimPtr(slotIndex), sampledWord, 0, .seq_cst, .seq_cst);
    }

    /// Compute the global reclaim horizon: the minimum minPinned across all
    /// live participant slots, or `fallback` if no live slot publishes a
    /// pinned version below it. Slots whose process no longer exists are
    /// reclaimed in the same pass. O(slots), with a pid-liveness (and
    /// possibly incarnation) syscall per occupied slot.
    pub fn globalHorizon(self: *Coordination, fallback: u64) u64 {
        var minV: u64 = fallback;
        var slotIndex: usize = 0;
        while (slotIndex < participantSlots) : (slotIndex += 1) {
            // Sample pid and token as ONE word so the liveness verdict and the
            // guarded reclaim below all refer to the same claim -- separate
            // loads could pair one owner's pid with its successor's token.
            const word = @atomicLoad(u64, self.slotClaimPtr(slotIndex), .seq_cst);
            if (word == 0) continue;
            const pid: u32 = @truncate(word);
            if (!pidAlive(pid)) {
                self.reclaimSlot(slotIndex, word);
                continue;
            }
            // The pid is alive, but pids are recycled: verify the incarnation.
            // A live unrelated process that inherited a dead reader's pid would
            // otherwise pin the horizon forever. Unavailable tokens on EITHER
            // side (query failed here, or the claimer could not obtain one and
            // stored 0) are treated as a match -- conservative, never unsafe.
            const storedToken: u32 = @truncate(word >> 32);
            if (storedToken != 0) {
                if (platform.processStartToken(pid)) |tok| {
                    if (@as(u32, @truncate(tok)) != storedToken) {
                        self.reclaimSlot(slotIndex, word); // recycled pid
                        continue;
                    }
                }
            }
            const minPinned = @atomicLoad(u64, self.slotMinPtr(slotIndex), .acquire);
            if (minPinned < minV) minV = minPinned;
        }
        return minV;
    }

    /// Test helper: write a slot directly without going through claimSlot.
    /// Allows tests to simulate a slot owned by an arbitrary (possibly dead or
    /// recycled) pid with an arbitrary incarnation token.
    pub fn forgeSlotForTest(self: *Coordination, slotIndex: usize, pid: u32, token: u32, minPinned: u64) void {
        @atomicStore(u64, self.slotMinPtr(slotIndex), minPinned, .seq_cst);
        @atomicStore(u32, self.slotTokenPtr(slotIndex), token, .seq_cst);
        @atomicStore(u32, self.slotPidPtr(slotIndex), pid, .seq_cst);
    }
};

// Tests of file-private invariants; the main suite lives in coordinationTests.zig.

const testing = std.testing;

test "claimSlot publishes pid and incarnation token in one atomic word" {
    // Regression: the pid was CAS'd first and the token stored after, leaving
    // a (live pid, token 0) window a concurrent globalHorizon could misread as
    // a recycled pid and reclaim -- a third process then re-claimed the slot
    // and the two owners overwrote each other's pins. The claim is now a
    // single u64 CAS of (token << 32) | pid; both fields must land together.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const coordinationPath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "packedclaim.coord" });
    defer testing.allocator.free(coordinationPath);
    var coordination = try Coordination.openOrCreate(coordinationPath);
    defer coordination.deinit();

    const slotIndex = (try coordination.claimSlot()).?;
    defer coordination.releaseSlot(slotIndex);
    const myPid: u32 = @intCast(platform.currentPid());
    const myToken: u32 = @truncate(platform.processStartToken(myPid) orelse 0);
    const word = @atomicLoad(u64, coordination.slotClaimPtr(slotIndex), .seq_cst);
    try testing.expectEqual((@as(u64, myToken) << 32) | myPid, word);
    try testing.expectEqual(sentinelMax, @atomicLoad(u64, coordination.slotMinPtr(slotIndex), .seq_cst));
}

test "a reclaimed slot becomes claimable again" {
    // Regression: reclaim cleared only the pid half of the claim word; the
    // stale incarnation token kept the slot's u64 nonzero, so the packed
    // claim CAS never matched it again -- every dead reader permanently
    // burned a slot until the table was exhausted.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const coordinationPath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "reclaimable.coord" });
    defer testing.allocator.free(coordinationPath);
    var coordination = try Coordination.openOrCreate(coordinationPath);
    defer coordination.deinit();

    coordination.forgeSlotForTest(0, 0x7fffffff, 0xdead, 3); // dead pid, nonzero token
    try testing.expectEqual(@as(u64, 50), coordination.globalHorizon(50));
    try testing.expectEqual(@as(u64, 0), @atomicLoad(u64, coordination.slotClaimPtr(0), .seq_cst));
    // Fill the whole table: every slot, including the reclaimed one, must land.
    var claimed: [participantSlots]usize = undefined;
    for (&claimed) |*slot| slot.* = (try coordination.claimSlot()) orelse return error.SlotLeaked;
    try testing.expectEqual(@as(?usize, null), try coordination.claimSlot());
    for (claimed) |slotIndex| coordination.releaseSlot(slotIndex);
}

test "reclaim leaves a slot alone when its claim word changed since the sample" {
    // Regression: the liveness verdict spans syscalls; a slot released and
    // re-claimed inside that window was wiped unconditionally -- the new
    // owner's pin vanished and a second claimant took the same slot. Reclaim
    // now exchanges against the sampled word and must fail on a mismatch.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const coordinationPath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "guardedreclaim.coord" });
    defer testing.allocator.free(coordinationPath);
    var coordination = try Coordination.openOrCreate(coordinationPath);
    defer coordination.deinit();

    coordination.forgeSlotForTest(2, 0x7fffffff, 0xbeef, 9); // the dead owner we sampled
    const sampled = @atomicLoad(u64, coordination.slotClaimPtr(2), .seq_cst);
    // The slot changes hands before the reclaim lands.
    const myPid: u32 = @intCast(platform.currentPid());
    coordination.forgeSlotForTest(2, myPid, 0xf00d, 5);
    coordination.reclaimSlot(2, sampled);
    try testing.expectEqual(myPid, coordination.slotPidForTest(2)); // new owner intact
    try testing.expectEqual(@as(u64, 5), @atomicLoad(u64, coordination.slotMinPtr(2), .seq_cst));
    // With the matching word, the reclaim goes through.
    const word2 = @atomicLoad(u64, coordination.slotClaimPtr(2), .seq_cst);
    coordination.reclaimSlot(2, word2);
    try testing.expectEqual(@as(u64, 0), @atomicLoad(u64, coordination.slotClaimPtr(2), .seq_cst));
}

test {
    _ = @import("coordinationTests.zig");
}
