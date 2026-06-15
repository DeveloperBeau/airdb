// db.zig -- Db, ReadTxn, WriteTxn, and the two-slot atomic durable commit.
//
// Slot A byte range in the header page: [64, 64+Slot.size).
// Slot B byte range in the header page: [128, 128+Slot.size).
// Data arena starts at default_page_size.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const FileStore = @import("file_store.zig").FileStore;
const RealSyncer = @import("file_store.zig").RealSyncer;
const Syncer = @import("file_store.zig").Syncer;
const default_page_size = @import("file_store.zig").default_page_size;
const Arena = @import("arena.zig").Arena;
const Allocation = @import("arena.zig").Allocation;
const Ref = @import("ref.zig").Ref;
const Slot = @import("slots.zig").Slot;
const FreeExtent = @import("freelist.zig").FreeExtent;
const FreeList = @import("freelist.zig").FreeList;
const Coord = @import("coord.zig").Coord;
const coord_mod = @import("coord.zig");

const slot_a_off: usize = 64;
const slot_b_off: usize = 128;

// ---------------------------------------------------------------------------
// Db
// ---------------------------------------------------------------------------

pub const VerifyError = error{
    HeaderCorrupt,
    SlotCorrupt,
    FreeListCorrupt,
    FreeExtentOutOfBounds,
    RootRefOutOfBounds,
};

pub const Db = struct {
    store: FileStore,
    arena: Arena,
    active_version: u64,
    active_root: Ref,
    pins: std.AutoHashMap(u64, u32),
    /// Currently-committed free list. Owns its memory; deinit'd in Db.deinit.
    free_list: FreeList,
    /// Offset of the live free-list node on disk (0 if none).
    free_list_node_ref: Ref,
    /// Byte length of the live free-list node on disk (0 if none).
    free_list_node_len: usize,
    /// Coordination file for multi-process attach count and latest-version signal.
    coord: Coord,
    /// Index into the coord participant slot array claimed by this Db instance, or null
    /// if all 64 slots were occupied at open/create time.
    participant_slot: ?usize,

    /// Create a new database file at the given absolute path.
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Db {
        return createWith(allocator, path, RealSyncer.any());
    }

    /// Like create, but with an injectable Syncer (used for testing).
    pub fn createWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncer) !Db {
        var store = try FileStore.create(allocator, path, syncer);
        errdefer store.deinit();

        // Write version-1 into slot A; mark it active.
        const initial = Slot{
            .version = 1,
            .root_ref = 0,
            .free_list_ref = 0,
            .logical_size = default_page_size,
        };
        initial.encode(store.map[slot_a_off..][0..Slot.size]);
        store.header.active_slot = 0;
        store.persistHeader();
        try store.syncer.flush(store.file);

        // Coord setup -- done last so the errdefer has no further try-s after it.
        const coord_path = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
        defer allocator.free(coord_path);
        var coord = try Coord.openOrCreate(coord_path);
        var slot: ?usize = null;
        errdefer {
            if (slot) |s| coord.releaseSlot(s);
            _ = coord.detach();
            coord.deinit();
        }
        _ = coord.attach();
        slot = try coord.claimSlot();

        return Db{
            .store = store,
            .arena = Arena.init(store.map, default_page_size),
            .active_version = 1,
            .active_root = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = FreeList.init(allocator),
            .free_list_node_ref = 0,
            .free_list_node_len = 0,
            .coord = coord,
            .participant_slot = slot,
        };
    }

    /// Open an existing database file at the given absolute path.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        return openWith(allocator, path, RealSyncer.any());
    }

    /// Like open, but with an injectable Syncer (used for testing).
    pub fn openWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncer) !Db {
        var store = try FileStore.open(allocator, path, syncer);
        errdefer store.deinit();
        // Capture the map slice before store is copied into the partial Db below.
        const store_map = store.map;

        // Build a partial Db so we can call selectActiveSlot and loadFreeList.
        // coord is left undefined; it is set at the very end.
        // On any error path, errdefer store.deinit() (above) frees the file+mmap,
        // and errdefer db.free_list.deinit() (below) frees any allocated extents.
        // db.pins is always empty here (no allocation), so it is safe to drop.
        var db: Db = .{
            .store = store,
            .arena = Arena.init(store_map, default_page_size),
            .active_version = 0,
            .active_root = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = FreeList.init(allocator),
            .free_list_node_ref = 0,
            .free_list_node_len = 0,
            .coord = undefined,
            .participant_slot = null,
        };
        errdefer db.free_list.deinit();

        const active = try db.selectActiveSlot();
        db.active_version = active.version;
        db.active_root = active.root_ref;
        db.arena.top = @intCast(active.logical_size);
        if (active.free_list_ref != 0) try db.loadFreeList(active.free_list_ref);

        // Coord setup -- done last so the errdefer has no further try-s after it.
        const coord_path = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
        defer allocator.free(coord_path);
        var coord = try Coord.openOrCreate(coord_path);
        var slot: ?usize = null;
        errdefer {
            if (slot) |s| coord.releaseSlot(s);
            _ = coord.detach();
            coord.deinit();
        }
        _ = coord.attach();
        slot = try coord.claimSlot();

        db.coord = coord;
        db.participant_slot = slot;
        return db;
    }

    pub fn deinit(self: *Db) void {
        if (self.participant_slot) |idx| self.coord.releaseSlot(idx);
        _ = self.coord.detach();
        self.coord.deinit();
        self.free_list.deinit();
        self.pins.deinit();
        self.store.deinit();
    }

    /// Select the active Slot from the shared mapping.
    /// Reads self.store.header_checksum_ok and self.store.header.active_slot.
    /// The caller must have called self.store.readHeader() before this when refreshing.
    fn selectActiveSlot(self: *Db) !Slot {
        if (self.store.header_checksum_ok) {
            // The durable header.active_slot is the source of truth for which version is
            // committed. The max-version heuristic would wrongly resurrect an aborted
            // commit whose new slot was durably written in the data barrier but never
            // published (i.e., header flush failed after the data barrier succeeded).
            const primary_idx = self.store.header.active_slot;
            if (primary_idx > 1) return error.Corrupt;
            const primary_off: usize = if (primary_idx == 0) slot_a_off else slot_b_off;
            const other_off: usize = if (primary_idx == 0) slot_b_off else slot_a_off;

            // Try the primary slot first (normal path and correct crash-recovery path).
            // Fall back to the other slot only if the primary checksum is bad, which
            // indicates a crash mid-slot-write into the primary region itself.
            return Slot.decode(self.store.map[primary_off..][0..Slot.size]) catch
                Slot.decode(self.store.map[other_off..][0..Slot.size]) catch
                return error.Corrupt;
        } else {
            // Header checksum failed: the authoritative active_slot pointer is unreadable,
            // so fall back to the highest valid-version slot. This last-resort heuristic is
            // used ONLY when the header itself is corrupt.
            const maybe_a: ?Slot = Slot.decode(self.store.map[slot_a_off..][0..Slot.size]) catch null;
            const maybe_b: ?Slot = Slot.decode(self.store.map[slot_b_off..][0..Slot.size]) catch null;
            if (maybe_a != null and maybe_b != null) {
                return if (maybe_a.?.version >= maybe_b.?.version) maybe_a.? else maybe_b.?;
            } else if (maybe_a != null) {
                return maybe_a.?;
            } else if (maybe_b != null) {
                return maybe_b.?;
            } else {
                return error.Corrupt;
            }
        }
    }

    /// Decode the persisted free-list node at free_list_ref into self.free_list.
    /// Sets self.free_list_node_ref and self.free_list_node_len.
    /// self.free_list must already be initialized (possibly empty).
    fn loadFreeList(self: *Db, free_list_ref: Ref) !void {
        // First read the 4-byte count prefix to know the full node size.
        const count_bytes = try self.arena.deref(free_list_ref, 4);
        const count = std.mem.readInt(u32, count_bytes[0..4], .little);
        const node_len = 4 + @as(usize, count) * 24;
        // Now read the full node and decode it.
        const node_bytes = try self.arena.deref(free_list_ref, node_len);
        try self.free_list.decode(node_bytes);
        self.free_list_node_ref = free_list_ref;
        self.free_list_node_len = node_len;
    }

    /// Select the highest-version slot that qualifies as published (version <= lv).
    /// Decodes both slot A and slot B; among those that decode successfully and
    /// have version <= lv, returns the one with the highest version. Returns null
    /// if no qualifying slot exists. Slots with version > lv are in-flight or
    /// aborted and must never be returned.
    fn selectPublishedSlot(self: *Db, lv: u64) ?Slot {
        const maybe_a: ?Slot = Slot.decode(self.store.map[slot_a_off..][0..Slot.size]) catch null;
        const maybe_b: ?Slot = Slot.decode(self.store.map[slot_b_off..][0..Slot.size]) catch null;
        var best: ?Slot = null;
        for ([_]?Slot{ maybe_a, maybe_b }) |ms| {
            const s = ms orelse continue;
            if (s.version > lv) continue;
            if (best == null or s.version > best.?.version) best = s;
        }
        return best;
    }

    /// Refresh this instance's in-memory view from the shared memory mapping.
    /// Gates advancement on coord.latestVersion() so that a slot written by an
    /// aborted commit (durable data barrier but failed header flush) is never
    /// observed. Only a version <= the published latest_version may be adopted.
    ///
    /// Safety: must only be called when no write transaction is in progress.
    /// It is called at the start of beginRead and beginWrite (before any txn
    /// state is built), which is safe.
    fn refreshToLatest(self: *Db) !void {
        const lv = self.coord.latestVersion(); // acquire-load of the published version
        if (lv <= self.active_version) return; // nothing newer has been published
        try self.store.readHeader(); // refresh header_checksum_ok / mapping view (for integrity use elsewhere)
        // If another process extended the file, grow our mapping before dereferencing
        // slot descriptors or free-list nodes that may live in the grown region.
        const flen = try self.store.fileLen();
        if (flen > self.store.map.len) {
            try self.store.grow(flen);
            self.arena.map = self.store.map;
        }
        const published = self.selectPublishedSlot(lv) orelse return; // no qualifying published slot visible yet
        if (published.version <= self.active_version) return;
        self.active_version = published.version;
        self.active_root = published.root_ref;
        self.arena.top = @intCast(published.logical_size);
        self.free_list.deinit();
        self.free_list = FreeList.init(self.store.allocator);
        self.free_list_node_ref = 0;
        self.free_list_node_len = 0;
        if (published.free_list_ref != 0) try self.loadFreeList(published.free_list_ref);
    }

    /// Returns the minimum pinned version among all active readers, or sentinel_max if none.
    fn localMinPinned(self: *Db) u64 {
        var min: ?u64 = null;
        var it = self.pins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == 0) continue;
            if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
        }
        return min orelse coord_mod.sentinel_max;
    }

    /// Publish the local minimum pinned version to our participant slot (if we have one).
    fn publishPins(self: *Db) void {
        if (self.participant_slot) |idx| self.coord.publishMinPinned(idx, self.localMinPinned());
    }

    pub fn beginRead(self: *Db) !ReadTxn {
        // Refresh from the shared mapping before pinning. Safe here because no
        // write transaction is in progress when beginRead is called.
        try self.refreshToLatest();
        const v = self.active_version;
        if (self.pins.getPtr(v)) |ptr| {
            ptr.* += 1;
        } else {
            try self.pins.put(v, 1);
        }
        self.publishPins();
        return ReadTxn{ .db = self, .root_ref = self.active_root, .version = v };
    }

    pub fn horizon(self: *Db) u64 {
        var min: ?u64 = null;
        var it = self.pins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == 0) continue;
            if (min == null or entry.key_ptr.* < min.?) min = entry.key_ptr.*;
        }
        return min orelse self.active_version;
    }

    /// Shared body for beginWrite and beginWriteTry. Caller must hold the coord
    /// lock before calling; an errdefer in the caller releases the lock if this
    /// function returns an error.
    fn beginWriteLocked(self: *Db) !WriteTxn {
        // Refresh under the lock so the writer sees the truly-latest committed version.
        try self.refreshToLatest();
        // Clone the committed free list into work_freelist so the transaction
        // can reuse extents from it. db.free_list is untouched during the txn;
        // work_freelist is the mutable clone that reuse() shrinks.
        var work_freelist = FreeList.init(self.store.allocator);
        errdefer work_freelist.deinit();
        for (self.free_list.extents.items) |e| {
            try work_freelist.add(e);
        }
        return WriteTxn{
            .db = self,
            .new_root = self.active_root,
            .new_version = self.active_version + 1,
            .in_flight_frees = .empty,
            .work_freelist = work_freelist,
        };
    }

    /// Begin a write transaction, blocking until the cross-process write lock is
    /// acquired. The lock is released when the returned WriteTxn is committed or
    /// abandoned via deinit.
    pub fn beginWrite(self: *Db) !WriteTxn {
        try self.coord.lockExclusive();
        errdefer self.coord.unlock(); // release if refresh or setup fails
        return self.beginWriteLocked();
    }

    /// Like beginWrite but returns error.WouldBlock immediately if another writer
    /// currently holds the lock.
    pub fn beginWriteTry(self: *Db) !WriteTxn {
        try self.coord.tryLockExclusive();
        errdefer self.coord.unlock(); // release if refresh or setup fails
        return self.beginWriteLocked();
    }

    /// Bump-allocate `size` bytes, growing the file if the arena is full.
    /// After any grow, re-syncs arena.map to the new (larger) mapping slice.
    fn bumpGrowing(self: *Db, size: usize) !Allocation {
        return self.arena.alloc(size) catch {
            const needed = self.arena.top + std.mem.alignForward(usize, size, 8);
            const target = @max(needed, self.store.map.len * 2);
            try self.store.grow(target);
            self.arena.map = self.store.map;
            return self.arena.alloc(size);
        };
    }

    /// Test-only accessor: number of extents in the committed free list.
    pub fn freeListLenForTest(self: *Db) usize {
        return self.free_list.extents.items.len;
    }

    pub fn verifyIntegrity(self: *Db) VerifyError!void {
        if (!self.store.header_checksum_ok) return error.HeaderCorrupt;

        const a_ok = Slot.decode(self.store.map[slot_a_off .. slot_a_off + Slot.size]) catch null;
        const b_ok = Slot.decode(self.store.map[slot_b_off .. slot_b_off + Slot.size]) catch null;
        if (a_ok == null and b_ok == null) return error.SlotCorrupt;

        const limit = self.store.map.len;

        if (self.active_root != 0) {
            const r: usize = @intCast(self.active_root);
            if (r % 8 != 0 or r >= limit) return error.RootRefOutOfBounds;
        }

        if (self.free_list_node_ref != 0) {
            const n: usize = @intCast(self.free_list_node_ref);
            if (n % 8 != 0 or n + self.free_list_node_len > limit) return error.FreeListCorrupt;
        }

        for (self.free_list.extents.items) |e| {
            const eoff: usize = @intCast(e.offset);
            if (e.len == 0) return error.FreeExtentOutOfBounds;
            if (eoff % 8 != 0) return error.FreeExtentOutOfBounds;
            const elen: usize = @intCast(e.len);
            if (eoff > limit or elen > limit - eoff) return error.FreeExtentOutOfBounds;
        }
    }
};

// ---------------------------------------------------------------------------
// ReadTxn
// ---------------------------------------------------------------------------

pub const ReadTxn = struct {
    db: *Db,
    root_ref: Ref,
    version: u64,

    pub fn root(self: ReadTxn) Ref {
        return self.root_ref;
    }

    pub fn deref(self: *ReadTxn, ref: Ref, len: usize) ![]const u8 {
        return self.db.arena.deref(ref, len);
    }

    pub fn end(self: *ReadTxn) void {
        if (self.db.pins.getPtr(self.version)) |ptr| {
            if (ptr.* > 0) ptr.* -= 1;
            if (ptr.* == 0) _ = self.db.pins.remove(self.version);
        }
        self.db.publishPins();
    }
};

// ---------------------------------------------------------------------------
// WriteTxn
// ---------------------------------------------------------------------------

pub const WriteTxn = struct {
    db: *Db,
    new_root: Ref,
    new_version: u64,
    in_flight_frees: std.ArrayList(FreeExtent),
    work_freelist: FreeList,

    pub fn alloc(self: *WriteTxn, size: usize) !Allocation {
        // A freed extent is reusable only when no reader in ANY live process pins a version
        // below its freeing-version. globalHorizon = min of live processes' min-pinned versions,
        // clamped to this writer's active_version (the fallback when no reader constrains it).
        // If this process could not claim a participant slot, it cannot advertise its own readers,
        // so it stays conservative (horizon 0 = bump-only).
        const h: u64 = if (self.db.participant_slot == null) 0 else self.db.coord.globalHorizon(self.db.active_version);
        return self.db.arena.allocReusing(size, &self.work_freelist, h) catch {
            const needed = self.db.arena.top + std.mem.alignForward(usize, size, 8);
            const target = @max(needed, self.db.store.map.len * 2);
            try self.db.store.grow(target);
            self.db.arena.map = self.db.store.map;
            return self.db.arena.allocReusing(size, &self.work_freelist, h);
        };
    }

    pub fn setRoot(self: *WriteTxn, ref: Ref) void {
        self.new_root = ref;
    }

    pub fn free(self: *WriteTxn, ref: Ref, len: usize) !void {
        try self.in_flight_frees.append(self.db.store.allocator, .{
            .offset = ref,
            .len = @intCast(len),
            .freed_version = self.new_version,
        });
    }

    pub fn writableCopy(self: *WriteTxn, ref: Ref, len: usize) !Allocation {
        const old = try self.db.arena.deref(ref, len);
        const fresh = try self.alloc(len);
        @memcpy(fresh.bytes, old);
        try self.free(ref, len);
        return fresh;
    }

    pub fn deinit(self: *WriteTxn) void {
        self.in_flight_frees.deinit(self.db.store.allocator);
        self.work_freelist.deinit();
        self.db.coord.unlock();
    }

    /// Two-slot atomic durable commit.
    ///
    /// Protocol:
    ///   1. Build the new persistent free list and encode it onto the mmap.
    ///   2. Encode the new slot (including free_list_ref) into the INACTIVE slot.
    ///   3. Flush -- ensures new data, free-list node, and slot descriptor are durable.
    ///      If this flush fails, return error.Durability immediately;
    ///      the old active slot is untouched and the old version remains live.
    ///   4. Flip header.active_slot to the newly-written slot; persistHeader().
    ///   5. Flush -- this is the commit point.
    ///      If this flush fails, revert ALL in-memory header changes
    ///      (active_slot and logical_size) and return error.Durability.
    ///      The old active slot on disk is still valid, so crash recovery
    ///      will see the old version.
    ///   6. Only after both flushes succeed: install new free list, update
    ///      active_version / active_root.
    ///
    /// new_fl ownership: errdefer new_fl.deinit() is registered immediately after
    /// FreeList.init so all error returns (try-errors AND the two explicit
    /// error.Durability returns) clean up new_fl. The errdefer does not fire on
    /// the success return (return self.new_version) since that is not an error,
    /// so transferring ownership to db.free_list before returning is safe and
    /// cannot double-free.
    pub fn commit(self: *WriteTxn) !u64 {
        // Free in_flight_frees and work_freelist on every error path; explicit deinits cover success.
        errdefer self.in_flight_frees.deinit(self.db.store.allocator);
        errdefer self.work_freelist.deinit();
        const db = self.db;
        const prev_active_slot = db.store.header.active_slot;
        const prev_logical_size = db.store.header.logical_size;

        // --- Build the new persistent free list ---
        //
        // errdefer fires on any error return (including the two explicit error.Durability
        // returns below). It does NOT fire on the success return, so ownership transfer
        // to db.free_list at the end of the success path is safe and double-free-free.
        var new_fl = FreeList.init(db.store.allocator);
        errdefer new_fl.deinit();

        // 1. Copy extents that work_freelist still holds (i.e. not reused this txn).
        for (self.work_freelist.extents.items) |e| {
            try new_fl.add(e);
        }
        // 2. Append in-flight frees (tagged with new_version; not yet reusable).
        for (self.in_flight_frees.items) |e| {
            try new_fl.add(e);
        }
        // 3. Reclaim the OLD free-list node so its space re-enters the free pool.
        if (db.free_list_node_ref != 0) {
            try new_fl.add(.{
                .offset = db.free_list_node_ref,
                .len = @intCast(db.free_list_node_len),
                .freed_version = self.new_version,
            });
        }

        // 4. Encode the new free list onto the arena via a BUMP allocation (never
        //    reuse, to avoid recursion: the free-list node must not reference itself).
        //    Use bumpGrowing so the file is extended if the arena is full.
        const node_len = new_fl.byteLen();
        const node = try db.bumpGrowing(node_len);
        const written = new_fl.encode(node.bytes);
        std.debug.assert(written == node_len);

        // --- Two-slot atomic durable commit ---

        // Step 1: determine the inactive slot and its byte offset.
        const inactive_idx: u8 = if (prev_active_slot == 0) 1 else 0;
        const inactive_off: usize = if (inactive_idx == 0) slot_a_off else slot_b_off;

        // Step 2: write the new slot descriptor into the inactive region.
        // logical_size is captured AFTER the node alloc so it covers the node bytes.
        const new_slot = Slot{
            .version = self.new_version,
            .root_ref = self.new_root,
            .free_list_ref = node.ref,
            .logical_size = @intCast(db.arena.top),
        };
        new_slot.encode(db.store.map[inactive_off..][0..Slot.size]);

        // Step 3: flush new data + inactive slot to durable storage.
        // Failure here: old active slot is still valid; no in-memory state changed.
        db.store.syncer.flush(db.store.file) catch {
            self.db.coord.unlock();
            return error.Durability;
        };

        // Step 4: flip the header commit pointer and flush (commit point).
        db.store.header.active_slot = inactive_idx;
        db.store.header.logical_size = @intCast(db.arena.top);
        db.store.persistHeader();
        db.store.syncer.flush(db.store.file) catch {
            // Revert every in-memory header change so the old version stays live.
            db.store.header.active_slot = prev_active_slot;
            db.store.header.logical_size = prev_logical_size;
            // Restore the mmap bytes to match the reverted header so subsequent
            // persistHeader calls (from the next commit attempt) write the right value.
            db.store.persistHeader();
            self.db.coord.unlock();
            return error.Durability;
        };

        // Step 5: publish the new version in memory only after both flushes succeed.
        db.active_version = self.new_version;
        db.active_root = self.new_root;
        db.coord.setLatestVersion(self.new_version);
        // Install the new free list. errdefer for new_fl will NOT fire here
        // because we are on the success return path (return self.new_version below).
        db.free_list.deinit();
        db.free_list = new_fl; // ownership transferred; do not call new_fl.deinit()
        db.free_list_node_ref = node.ref;
        db.free_list_node_len = node_len;
        self.in_flight_frees.deinit(self.db.store.allocator);
        self.work_freelist.deinit();
        self.db.coord.unlock();
        return self.new_version;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    return std.fs.path.join(allocator, &.{ dir_path, name });
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

test "writableCopy allocates a new node, copies bytes, and records the old as freed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cow.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "ORIGINAL");
    const copy = try w.writableCopy(a.ref, 8);
    try testing.expect(copy.ref != a.ref);
    try testing.expectEqualStrings("ORIGINAL", copy.bytes);
    try testing.expectEqual(@as(usize, 1), w.in_flight_frees.items.len);
    try testing.expectEqual(a.ref, w.in_flight_frees.items[0].offset);
    w.deinit(); // releases the in-flight list without committing
}

test "commit then reopen sees the committed root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "db.airdb");
    defer testing.allocator.free(path);

    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "HELLOAID");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const root_ref = r.root();
        try testing.expect(root_ref != 0);
        const bytes = try r.deref(root_ref, 8);
        try testing.expectEqualStrings("HELLOAID", bytes);
    }
}

test "version horizon tracks the oldest live reader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "horizon.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    try testing.expectEqual(db.active_version, db.horizon());

    var r1 = try db.beginRead();
    const v = db.active_version;
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "NEWDATA_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    try testing.expectEqual(v, db.horizon()); // r1 still pinned at v
    r1.end();
    try testing.expectEqual(db.active_version, db.horizon());
}

test "free list persists across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "fl.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRSTVAL");
        const b = try w.writableCopy(a.ref, 8); // frees the old node at this version
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expect(db.freeListLenForTest() >= 1);
    }
}

test "verifyIntegrity passes on a freshly committed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    try db.verifyIntegrity(); // void on clean db
}

test "verifyIntegrity detects a root reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.active_root = db.store.map.len + 8; // point past the mapped region
    try testing.expectError(error.RootRefOutOfBounds, db.verifyIntegrity());
}

test "verifyIntegrity detects a corrupt header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_hdr.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.store.header_checksum_ok = false; // simulate an unreadable header
    try testing.expectError(error.HeaderCorrupt, db.verifyIntegrity());
}

test "verifyIntegrity detects both slots corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_slot.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    // Corrupt the checksum bytes of BOTH slot regions so neither decodes. Header stays valid.
    db.store.map[slot_a_off + 4] ^= 0xFF;
    db.store.map[slot_b_off + 4] ^= 0xFF;
    try testing.expectError(error.SlotCorrupt, db.verifyIntegrity());
}

test "verifyIntegrity detects a free-list node reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_fln.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.free_list_node_ref = @intCast(db.store.map.len + 8); // past the mapped region (8-aligned)
    db.free_list_node_len = 16;
    try testing.expectError(error.FreeListCorrupt, db.verifyIntegrity());
}

test "verifyIntegrity detects a free extent out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_ext.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    // Inject an extent whose offset is past the mapped region.
    try db.free_list.extents.append(db.store.allocator, .{ .offset = @intCast(db.store.map.len + 8), .len = 8, .freed_version = 1 });
    try testing.expectError(error.FreeExtentOutOfBounds, db.verifyIntegrity());
}

test "two Db instances on one file share a coordination attach count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "share.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
    defer b.deinit();
    try testing.expectEqual(@as(u32, 2), a.coord.attachCount());
}

test "a second Db instance sees a commit made by the first after refresh-on-read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vis.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
    defer b.deinit();
    {
        var w = try a.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "SHARED!!");
        w.setRoot(x.ref);
        _ = try w.commit();
    }
    var r = try b.beginRead();
    try testing.expectEqualStrings("SHARED!!", try r.deref(r.root(), 8));
    r.end();
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
    try db.refreshToLatest();
    try testing.expectEqual(published_version, db.active_version);
}

test "a second writer is excluded while the first holds the write lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "excl.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
    defer b.deinit();
    var wa = try a.beginWrite();
    try testing.expectError(error.WouldBlock, b.beginWriteTry());
    const x = try wa.alloc(8);
    @memcpy(x.bytes, "FIRST!!!");
    wa.setRoot(x.ref);
    _ = try wa.commit();
    var wb = try b.beginWriteTry();
    wb.deinit();
}

test "single instance reuse works through the global horizon" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ghreuse.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const old_root = db.active_root;
    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(old_root, 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const c = try w.alloc(8);
        try testing.expectEqual(old_root, c.ref);
        w.deinit();
    }
}

test "Db publishes its minimum pinned version to its participant slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pub.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "VERSION2");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No readers: this process publishes the sentinel (imposes no horizon constraint).
    try testing.expectEqual(coord_mod.sentinel_max, db.coord.slotMinPinnedForTest(db.participant_slot.?));
    var r = try db.beginRead(); // pins the current version
    try testing.expectEqual(db.active_version, db.coord.slotMinPinnedForTest(db.participant_slot.?));
    r.end();
    try testing.expectEqual(coord_mod.sentinel_max, db.coord.slotMinPinnedForTest(db.participant_slot.?));
}

test "allocations beyond the initial mapping grow the file and data survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "biggrow.airdb");
    defer testing.allocator.free(path);
    var last_ref: Ref = 0;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            const a = try w.alloc(4096);
            a.bytes[0] = @intCast(i & 0xff);
            last_ref = a.ref;
        }
        w.setRoot(last_ref);
        _ = try w.commit();
        try testing.expect(db.store.map.len > 4096 * 256);
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const got = try r.deref(r.root(), 4096);
        try testing.expectEqual(@as(u8, @intCast(399 & 0xff)), got[0]);
        r.end();
    }
}
