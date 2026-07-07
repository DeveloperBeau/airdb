// versioning.zig -- commit-slot selection, version adoption, reader pins, and
// the shared retention window for a Db.
//
// These free functions implement the version/pin machinery behind database.zig's
// public surface: which commit slot is authoritative after a crash, when an
// instance may adopt a newer published version, how reader pins are advertised
// to other processes, and how far back point-in-time reads may reach. database.zig
// keeps thin public delegates for the caller-facing pieces.

const std = @import("std");
const testing = std.testing;
const platform = @import("../platform.zig");
const dbModule = @import("../database.zig");
const Db = dbModule.Db;
const Reference = @import("../storage/reference.zig").Reference;
const Slot = @import("../storage/slots.zig").Slot;
const FreeList = @import("../storage/freeList.zig").FreeList;
const coord_mod = @import("coordination.zig");
const freeListRecovery = @import("../storage/freeListRecovery.zig");
const default_page_size = @import("../storage/fileStore.zig").default_page_size;

const slot_a_off = dbModule.slot_a_off;
const slot_b_off = dbModule.slot_b_off;
const ring_head_off = dbModule.ring_head_off;
const ring_off = dbModule.ring_off;
const ring_capacity = dbModule.ring_capacity;
const retain_off = dbModule.retain_off;

/// Select the active Slot from the shared mapping.
/// Reads db.store.header_checksum_ok and db.store.header.active_slot.
/// The caller must have called db.store.readHeader() before this when refreshing.
pub fn selectActiveSlot(db: *Db) !Slot {
    if (db.store.header_checksum_ok) {
        // The durable header.active_slot is the source of truth for which version is
        // committed. The max-version heuristic would wrongly resurrect an aborted
        // commit whose new slot was durably written in the data barrier but never
        // published (i.e., header flush failed after the data barrier succeeded).
        const primary_idx = db.store.header.active_slot;
        if (primary_idx > 1) return error.Corrupt;
        const primary_off: usize = if (primary_idx == 0) slot_a_off else slot_b_off;
        const other_off: usize = if (primary_idx == 0) slot_b_off else slot_a_off;

        // Try the primary slot first (normal path and correct crash-recovery path).
        // Fall back to the other slot only if the primary checksum is bad, which
        // indicates a crash mid-slot-write into the primary region itself. The
        // fallback silently resumes from the previous version, so it is recorded
        // on the Db and surfaced via metrics().
        return Slot.decode(db.store.map[primary_off..][0..Slot.size]) catch {
            const s = Slot.decode(db.store.map[other_off..][0..Slot.size]) catch return error.Corrupt;
            db.recovered_fallback = true;
            return s;
        };
    } else {
        // Header checksum failed: the authoritative active_slot pointer is unreadable,
        // so fall back to the highest valid-version slot. This last-resort heuristic is
        // used ONLY when the header itself is corrupt, and is likewise surfaced.
        const maybe_a: ?Slot = Slot.decode(db.store.map[slot_a_off..][0..Slot.size]) catch null;
        const maybe_b: ?Slot = Slot.decode(db.store.map[slot_b_off..][0..Slot.size]) catch null;
        const chosen: Slot = blk: {
            if (maybe_a != null and maybe_b != null) {
                break :blk if (maybe_a.?.version >= maybe_b.?.version) maybe_a.? else maybe_b.?;
            } else if (maybe_a != null) {
                break :blk maybe_a.?;
            } else if (maybe_b != null) {
                break :blk maybe_b.?;
            } else {
                return error.Corrupt;
            }
        };
        db.recovered_fallback = true;
        return chosen;
    }
}

/// Select the highest-version slot that qualifies as published (version <= lv).
/// Decodes both slot A and slot B; among those that decode successfully and
/// have version <= lv, returns the one with the highest version. Returns null
/// if no qualifying slot exists. Slots with version > lv are in-flight or
/// aborted and must never be returned.
fn selectPublishedSlot(db: *Db, lv: u64) ?Slot {
    const maybe_a: ?Slot = Slot.decode(db.store.map[slot_a_off..][0..Slot.size]) catch null;
    const maybe_b: ?Slot = Slot.decode(db.store.map[slot_b_off..][0..Slot.size]) catch null;
    var best: ?Slot = null;
    for ([_]?Slot{ maybe_a, maybe_b }) |ms| {
        const s = ms orelse continue;
        if (s.version > lv) continue;
        if (best == null or s.version > best.?.version) best = s;
    }
    return best;
}

/// Refresh the instance's in-memory view from the shared memory mapping.
/// Gates advancement on coord.latestVersion() so that a slot written by an
/// aborted commit (durable data barrier but failed header flush) is never
/// observed. Only a version <= the published latest_version may be adopted.
///
/// Safety: must only be called when no write transaction is in progress.
/// It is called at the start of beginRead and beginWrite (before any txn
/// state is built), which is safe.
pub fn refreshToLatest(db: *Db) !void {
    const lv = db.coord.latestVersion(); // acquire-load of the published version
    if (lv <= db.active_version) return; // nothing newer has been published
    try db.store.readHeader(); // refresh header_checksum_ok / mapping view (for integrity use elsewhere)
    // If another process extended the file, map the new sections before dereferencing
    // slot descriptors or free-list nodes that may live in the grown region.
    const flen = try db.store.fileLen();
    const mapped = db.store.sectionsView().len * platform.section_size;
    if (flen > mapped) {
        try db.store.grow(@intCast(flen));
        db.arena.sections = db.store.sectionsView();
    }
    const published = selectPublishedSlot(db, lv) orelse return; // no qualifying published slot visible yet
    if (published.version <= db.active_version) return;
    // Decode the published free list into a temporary FIRST. A decode
    // failure must leave this instance's committed state (version, root,
    // top, free list) fully intact: advancing the version with an empty
    // free list would make the next commit durably persist that empty list
    // and permanently drop every reclaimable-extent record.
    var new_fl = FreeList.init(db.store.allocator);
    errdefer new_fl.deinit();
    var node_len: usize = 0;
    if (published.free_list_ref != 0) {
        node_len = try freeListRecovery.decodeFreeListNode(db, published.free_list_ref, &new_fl);
    }
    // All decoding succeeded: install everything together.
    db.active_version = published.version;
    db.active_root = published.root_ref;
    db.arena.top = @intCast(published.logical_size);
    db.free_list.deinit();
    db.free_list = new_fl;
    db.free_list_node_ref = published.free_list_ref;
    db.free_list_node_len = node_len;
}

/// Returns the minimum pinned version among all active readers, or sentinel_max if none.
fn localMinPinned(db: *Db) u64 {
    var min: ?u64 = null;
    var it = db.pins.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
    }
    return min orelse coord_mod.sentinel_max;
}

/// Publish the local minimum pinned version to the instance's participant slot
/// (if it has one), making the pins visible to other processes' reclaim horizons.
pub fn publishPins(db: *Db) void {
    if (db.participant_slot) |idx| db.coord.publishMinPinned(idx, localMinPinned(db));
}

/// The minimum version pinned by a live reader in this process, or the active
/// version if no reader is open.
pub fn horizon(db: *Db) u64 {
    var min: ?u64 = null;
    var it = db.pins.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
    }
    return min orelse db.active_version;
}

fn retainPtr(db: *Db) *u64 {
    return @ptrCast(@alignCast(&db.store.map[retain_off]));
}

/// The shared retention window: recently-freed space is withheld from reuse
/// for the most recent `retainVersions()` versions, across ALL processes.
pub fn retainVersions(db: *Db) u64 {
    return @atomicLoad(u64, retainPtr(db), .acquire);
}

/// Withhold recently-freed space from reuse for the most recent `n` versions.
/// Shared and durable: the value lives in the header page, so every attached
/// process honors it immediately, and it is carried to disk by the next
/// commit's flush. Lowering the window while point-in-time readers are
/// active in other processes is unsafe; raise-only while readers may exist.
pub fn setRetainVersions(db: *Db, n: u64) void {
    @atomicStore(u64, retainPtr(db), n, .release);
}

/// Root ref for a committed version, or null if not retained / not yet committed.
/// The `version > active_version` guard rejects a ring entry written during a
/// commit that crashed/aborted before publishing (the slot flip never happened),
/// so a recorded-but-unpublished pair is never trusted.
///
/// The ring is scanned newest-to-oldest. A commit that failed its durability
/// barrier leaves its (version, root) entry behind, and the retry commit --
/// which reuses the same version number -- writes a second entry for that
/// version. The retry's entry is always written later, so the newest match is
/// the committed root and the aborted duplicate is never returned.
pub fn versionRoot(db: *Db, version: u64) ?u64 {
    if (version > db.active_version) return null;
    const map = db.store.map;
    const head = std.mem.readInt(u64, map[ring_head_off..][0..8], .little);
    const n = @min(head, ring_capacity);
    var j: u64 = 0;
    while (j < n) : (j += 1) {
        const slot_idx: usize = @intCast((head - 1 - j) % ring_capacity);
        const e = ring_off + slot_idx * 16;
        const v = std.mem.readInt(u64, map[e..][0..8], .little);
        if (v == version) return std.mem.readInt(u64, map[e + 8 ..][0..8], .little);
    }
    return null;
}

/// Oldest version still recorded in the ring, or active_version if the ring is
/// empty. As the ring wraps, the recovery window's lower bound advances. Entries
/// above active_version (an unpublished/aborted commit) are ignored.
pub fn oldestRetainedVersion(db: *Db) u64 {
    const map = db.store.map;
    const head = std.mem.readInt(u64, map[ring_head_off..][0..8], .little);
    const n = @min(head, ring_capacity);
    var i: u64 = 0;
    var min: ?u64 = null;
    while (i < n) : (i += 1) {
        const e = ring_off + @as(usize, @intCast(i)) * 16;
        const v = std.mem.readInt(u64, map[e..][0..8], .little);
        if (v > db.active_version) continue;
        if (min == null or v < min.?) min = v;
    }
    return min orelse db.active_version;
}

/// Oldest version `beginReadAt` can open: the later of the oldest ring entry
/// and the retention-window floor. Versions in [this, active_version] open.
pub fn oldestReadableVersion(db: *Db) u64 {
    const ring_floor = oldestRetainedVersion(db);
    const retain = retainVersions(db);
    if (retain == coord_mod.sentinel_max) return ring_floor;
    return @max(ring_floor, db.active_version -| retain);
}

// Tests of this file's own invariants.

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..path_len], name });
}

test "refresh does not advance to a durable-but-unpublished (aborted) slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "unpub.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "PUBLISH_");
        w.setRoot(a.ref);
        _ = try w.commit(); // publishes; coord.latest_version advances to this version
    }
    const published_version = db.active_version;
    // Forge a VALID slot with a much higher version into the inactive slot bytes,
    // WITHOUT advancing coord.latest_version (simulates an aborted-but-durable commit).
    const forged = Slot{ .version = published_version + 50, .root_ref = 0, .free_list_ref = 0, .logical_size = default_page_size };
    var buf: [Slot.size]u8 = undefined;
    forged.encode(&buf);
    // Write it into whichever slot is currently inactive. The active slot is header.active_slot.
    const inactive_off: usize = if (db.store.header.active_slot == 0) slot_b_off else slot_a_off;
    @memcpy(db.store.map[inactive_off .. inactive_off + Slot.size], &buf);
    // Refresh must NOT advance to the forged version (coord.latest_version unchanged).
    try refreshToLatest(&db);
    try testing.expectEqual(published_version, db.active_version);
}
test "recovery follows header active_slot pointer, not max version" {
    // Regression test: after a crash where the data barrier (step 3 of commit) made
    // the new slot durable but the header flush (step 5) never completed, Db.open must
    // recover the version that header.active_slot points to, not the highest-version
    // slot on disk.
    //
    // Setup: header.active_slot=0 (slot A, version 1). We manually write a valid
    // higher-version slot (version 50) into slot B's byte range WITHOUT updating
    // header.active_slot. This is exactly the dangerous on-disk state that a
    // max-version heuristic would mishandle.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "recovery.airdb");
    defer testing.allocator.free(path);

    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        // Inject a plausible-but-aborted slot into slot B without touching the header.
        const aborted = Slot{ .version = 50, .root_ref = 0, .free_list_ref = 0, .logical_size = default_page_size };
        aborted.encode(db.store.map[slot_b_off..][0..Slot.size]);
        try db.store.syncer.flush(db.store.file);
        // header.active_slot remains 0 (slot A, version 1).
    }

    // On reopen the correct recovery path must pick slot A (header.active_slot=0,
    // version 1), not slot B (version 50).
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expectEqual(@as(u64, 1), db.active_version);
    }
}

test "falling back past a corrupt primary slot is surfaced in metrics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "fallback.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "VERSION2");
        w.setRoot(a.ref);
        _ = try w.commit();
        try testing.expect(!db.metrics().recovered_fallback); // clean session
        // Corrupt the PRIMARY (active) slot's checksum region on disk.
        const primary_off: usize = if (db.store.header.active_slot == 0) slot_a_off else slot_b_off;
        db.store.map[primary_off + 4] ^= 0xFF;
        try db.store.syncer.flush(db.store.file);
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        // Recovery used the other slot (the previous version) and says so.
        try testing.expect(db.metrics().recovered_fallback);
        try testing.expectEqual(@as(u64, 1), db.active_version);
    }
}
