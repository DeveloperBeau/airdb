// versioning.zig -- commit-slot selection, version adoption, reader pins, and
// the shared retention window for a Database.
//
// These free functions implement the version/pin machinery behind database.zig's
// public surface: which commit slot is authoritative after a crash, when an
// instance may adopt a newer published version, how reader pins are advertised
// to other processes, and how far back point-in-time reads may reach. database.zig
// keeps thin public delegates for the caller-facing pieces.

const std = @import("std");
const testing = std.testing;
const platform = @import("../platform.zig");
const databaseModule = @import("../database.zig");
const Database = databaseModule.Database;
const Reference = @import("../storage/reference.zig").Reference;
const Slot = @import("../storage/slots.zig").Slot;
const FreeList = @import("../storage/freeList.zig").FreeList;
const coordMod = @import("coordination.zig");
const freeListRecovery = @import("../storage/freeListRecovery.zig");
const defaultPageSize = @import("../storage/fileStore.zig").defaultPageSize;

const slotAOff = databaseModule.slotAOff;
const slotBOff = databaseModule.slotBOff;
const ringHeadOff = databaseModule.ringHeadOff;
const ringOff = databaseModule.ringOff;
const ringCapacity = databaseModule.ringCapacity;
const retainOff = databaseModule.retainOff;

/// Select the active Slot from the shared mapping.
/// Reads database.store.headerChecksumOk and database.store.header.activeSlot.
/// The caller must have called database.store.readHeader() before this when refreshing.
pub fn selectActiveSlot(database: *Database) !Slot {
    if (database.store.headerChecksumOk) {
        // The durable header.activeSlot is the source of truth for which version is
        // committed. The max-version heuristic would wrongly resurrect an aborted
        // commit whose new slot was durably written in the data barrier but never
        // published (i.e., header flush failed after the data barrier succeeded).
        const primarySlotIndex = database.store.header.activeSlot;
        if (primarySlotIndex > 1) return error.Corrupt;
        const primaryOff: usize = if (primarySlotIndex == 0) slotAOff else slotBOff;
        const otherOff: usize = if (primarySlotIndex == 0) slotBOff else slotAOff;

        // Try the primary slot first (normal path and correct crash-recovery path).
        // Fall back to the other slot only if the primary checksum is bad, which
        // indicates a crash mid-slot-write into the primary region itself. The
        // fallback silently resumes from the previous version, so it is recorded
        // on the Database and surfaced via metrics().
        return Slot.decode(database.store.map[primaryOff..][0..Slot.size]) catch {
            const slot = Slot.decode(database.store.map[otherOff..][0..Slot.size]) catch return error.Corrupt;
            database.recoveredFallback = true;
            return slot;
        };
    } else {
        // Header checksum failed: the authoritative activeSlot pointer is unreadable,
        // so fall back to the highest valid-version slot. This last-resort heuristic is
        // used ONLY when the header itself is corrupt, and is likewise surfaced.
        const maybeA: ?Slot = Slot.decode(database.store.map[slotAOff..][0..Slot.size]) catch null;
        const maybeB: ?Slot = Slot.decode(database.store.map[slotBOff..][0..Slot.size]) catch null;
        const chosen: Slot = blk: {
            if (maybeA != null and maybeB != null) {
                break :blk if (maybeA.?.version >= maybeB.?.version) maybeA.? else maybeB.?;
            } else if (maybeA != null) {
                break :blk maybeA.?;
            } else if (maybeB != null) {
                break :blk maybeB.?;
            } else {
                return error.Corrupt;
            }
        };
        database.recoveredFallback = true;
        return chosen;
    }
}

/// Select the highest-version slot that qualifies as published (version <= lv).
/// Decodes both slot A and slot B; among those that decode successfully and
/// have version <= lv, returns the one with the highest version. Returns null
/// if no qualifying slot exists. Slots with version > lv are in-flight or
/// aborted and must never be returned.
fn selectPublishedSlot(database: *Database, latestVersion: u64) ?Slot {
    const maybeA: ?Slot = Slot.decode(database.store.map[slotAOff..][0..Slot.size]) catch null;
    const maybeB: ?Slot = Slot.decode(database.store.map[slotBOff..][0..Slot.size]) catch null;
    var best: ?Slot = null;
    for ([_]?Slot{ maybeA, maybeB }) |maybeSlot| {
        const slot = maybeSlot orelse continue;
        if (slot.version > latestVersion) continue;
        if (best == null or slot.version > best.?.version) best = slot;
    }
    return best;
}

/// Refresh the instance's in-memory view from the shared memory mapping.
/// Gates advancement on coord.latestVersion() so that a slot written by an
/// aborted commit (durable data barrier but failed header flush) is never
/// observed. Only a version <= the published latestVersion may be adopted.
///
/// Safety: must only be called when no write transaction is in progress.
/// It is called at the start of beginRead and beginWrite (before any transaction
/// state is built), which is safe.
pub fn refreshToLatest(database: *Database) !void {
    const latestVersion = database.coord.latestVersion(); // acquire-load of the published version
    if (latestVersion <= database.activeVersion) return; // nothing newer has been published
    try database.store.readHeader(); // refresh headerChecksumOk / mapping view (for integrity use elsewhere)
    // If another process extended the file, map the new sections before dereferencing
    // slot descriptors or free-list nodes that may live in the grown region.
    const flen = try database.store.fileLen();
    const mapped = database.store.sectionsView().len * platform.sectionSize;
    if (flen > mapped) {
        try database.store.grow(@intCast(flen));
        database.arena.sections = database.store.sectionsView();
    }
    const published = selectPublishedSlot(database, latestVersion) orelse return; // no qualifying published slot visible yet
    if (published.version <= database.activeVersion) return;
    // Decode the published free list into a temporary FIRST. A decode
    // failure must leave this instance's committed state (version, root,
    // top, free list) fully intact: advancing the version with an empty
    // free list would make the next commit durably persist that empty list
    // and permanently drop every reclaimable-extent record.
    var newFl = FreeList.init(database.store.allocator);
    errdefer newFl.deinit();
    var nodeLen: usize = 0;
    if (published.freeListRef != 0) {
        nodeLen = try freeListRecovery.decodeFreeListNode(database, published.freeListRef, &newFl);
    }
    // All decoding succeeded: install everything together.
    database.activeVersion = published.version;
    database.activeRoot = published.rootRef;
    database.arena.top = @intCast(published.logicalSize);
    database.freeList.deinit();
    database.freeList = newFl;
    database.freeListNodeRef = published.freeListRef;
    database.freeListNodeLen = nodeLen;
}

/// Returns the minimum pinned version among all active readers, or sentinelMax if none.
fn localMinPinned(database: *Database) u64 {
    var min: ?u64 = null;
    var iterator = database.pins.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
    }
    return min orelse coordMod.sentinelMax;
}

/// Publish the local minimum pinned version to the instance's participant slot
/// (if it has one), making the pins visible to other processes' reclaim horizons.
pub fn publishPins(database: *Database) void {
    if (database.participantSlot) |slotIndex| database.coord.publishMinPinned(slotIndex, localMinPinned(database));
}

/// The minimum version pinned by a live reader in this process, or the active
/// version if no reader is open.
pub fn horizon(database: *Database) u64 {
    var min: ?u64 = null;
    var iterator = database.pins.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
    }
    return min orelse database.activeVersion;
}

fn retainPtr(database: *Database) *u64 {
    return @ptrCast(@alignCast(&database.store.map[retainOff]));
}

/// The shared retention window: recently-freed space is withheld from reuse
/// for the most recent `retainVersions()` versions, across ALL processes.
pub fn retainVersions(database: *Database) u64 {
    return @atomicLoad(u64, retainPtr(database), .acquire);
}

/// Withhold recently-freed space from reuse for the most recent `n` versions.
/// Shared and durable: the value lives in the header page, so every attached
/// process honors it immediately, and it is carried to disk by the next
/// commit's flush. Lowering the window while point-in-time readers are
/// active in other processes is unsafe; raise-only while readers may exist.
pub fn setRetainVersions(database: *Database, count: u64) void {
    @atomicStore(u64, retainPtr(database), count, .release);
}

/// Root ref for a committed version, or null if not retained / not yet committed.
/// The `version > activeVersion` guard rejects a ring entry written during a
/// commit that crashed/aborted before publishing (the slot flip never happened),
/// so a recorded-but-unpublished pair is never trusted.
///
/// The ring is scanned newest-to-oldest. A commit that failed its durability
/// barrier leaves its (version, root) entry behind, and the retry commit --
/// which reuses the same version number -- writes a second entry for that
/// version. The retry's entry is always written later, so the newest match is
/// the committed root and the aborted duplicate is never returned.
pub fn versionRoot(database: *Database, version: u64) ?u64 {
    if (version > database.activeVersion) return null;
    const map = database.store.map;
    const head = std.mem.readInt(u64, map[ringHeadOff..][0..8], .little);
    const entryCount = @min(head, ringCapacity);
    var entryIndex: u64 = 0;
    while (entryIndex < entryCount) : (entryIndex += 1) {
        const slotIndex: usize = @intCast((head - 1 - entryIndex) % ringCapacity);
        const entryOffset = ringOff + slotIndex * 16;
        const entryVersion = std.mem.readInt(u64, map[entryOffset..][0..8], .little);
        if (entryVersion == version) return std.mem.readInt(u64, map[entryOffset + 8 ..][0..8], .little);
    }
    return null;
}

/// Oldest version still recorded in the ring, or activeVersion if the ring is
/// empty. As the ring wraps, the recovery window's lower bound advances. Entries
/// above activeVersion (an unpublished/aborted commit) are ignored.
pub fn oldestRetainedVersion(database: *Database) u64 {
    const map = database.store.map;
    const head = std.mem.readInt(u64, map[ringHeadOff..][0..8], .little);
    const entryCount = @min(head, ringCapacity);
    var entryIndex: u64 = 0;
    var min: ?u64 = null;
    while (entryIndex < entryCount) : (entryIndex += 1) {
        const entryOffset = ringOff + @as(usize, @intCast(entryIndex)) * 16;
        const entryVersion = std.mem.readInt(u64, map[entryOffset..][0..8], .little);
        if (entryVersion > database.activeVersion) continue;
        if (min == null or entryVersion < min.?) min = entryVersion;
    }
    return min orelse database.activeVersion;
}

/// Oldest version `beginReadAt` can open: the later of the oldest ring entry
/// and the retention-window floor. Versions in [this, activeVersion] open.
pub fn oldestReadableVersion(database: *Database) u64 {
    const ringFloor = oldestRetainedVersion(database);
    const retain = retainVersions(database);
    if (retain == coordMod.sentinelMax) return ringFloor;
    return @max(ringFloor, database.activeVersion -| retain);
}

// Tests of this file's own invariants.

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

test "refresh does not advance to a durable-but-unpublished (aborted) slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "unpub.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "PUBLISH_");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit(); // publishes; coord.latestVersion advances to this version
    }
    const publishedVersion = database.activeVersion;
    // Forge a VALID slot with a much higher version into the inactive slot bytes,
    // WITHOUT advancing coord.latestVersion (simulates an aborted-but-durable commit).
    const forged = Slot{ .version = publishedVersion + 50, .rootRef = 0, .freeListRef = 0, .logicalSize = defaultPageSize };
    var buffer: [Slot.size]u8 = undefined;
    forged.encode(&buffer);
    // Write it into whichever slot is currently inactive. The active slot is header.activeSlot.
    const inactiveOff: usize = if (database.store.header.activeSlot == 0) slotBOff else slotAOff;
    @memcpy(database.store.map[inactiveOff .. inactiveOff + Slot.size], &buffer);
    // Refresh must NOT advance to the forged version (coord.latestVersion unchanged).
    try refreshToLatest(&database);
    try testing.expectEqual(publishedVersion, database.activeVersion);
}
test "recovery follows header activeSlot pointer, not max version" {
    // Regression test: after a crash where the data barrier (step 3 of commit) made
    // the new slot durable but the header flush (step 5) never completed, Database.open must
    // recover the version that header.activeSlot points to, not the highest-version
    // slot on disk.
    //
    // Setup: header.activeSlot=0 (slot A, version 1). We manually write a valid
    // higher-version slot (version 50) into slot B's byte range WITHOUT updating
    // header.activeSlot. This is exactly the dangerous on-disk state that a
    // max-version heuristic would mishandle.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "recovery.airdb");
    defer testing.allocator.free(path);

    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        // Inject a plausible-but-aborted slot into slot B without touching the header.
        const aborted = Slot{ .version = 50, .rootRef = 0, .freeListRef = 0, .logicalSize = defaultPageSize };
        aborted.encode(database.store.map[slotBOff..][0..Slot.size]);
        try database.store.syncer.flush(database.store.file);
        // header.activeSlot remains 0 (slot A, version 1).
    }

    // On reopen the correct recovery path must pick slot A (header.activeSlot=0,
    // version 1), not slot B (version 50).
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expectEqual(@as(u64, 1), database.activeVersion);
    }
}

test "falling back past a corrupt primary slot is surfaced in metrics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "fallback.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "VERSION2");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
        try testing.expect(!database.metrics().recoveredFallback); // clean session
        // Corrupt the PRIMARY (active) slot's checksum region on disk.
        const primaryOff: usize = if (database.store.header.activeSlot == 0) slotAOff else slotBOff;
        database.store.map[primaryOff + 4] ^= 0xFF;
        try database.store.syncer.flush(database.store.file);
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        // Recovery used the other slot (the previous version) and says so.
        try testing.expect(database.metrics().recoveredFallback);
        try testing.expectEqual(@as(u64, 1), database.activeVersion);
    }
}
