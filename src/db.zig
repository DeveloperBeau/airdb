// db.zig -- Db, ReadTxn, WriteTxn, and the two-slot atomic durable commit.
//
// Slot A byte range in the header page: [64, 64+Slot.size).
// Slot B byte range in the header page: [128, 128+Slot.size).
// Data arena starts at default_page_size.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("platform.zig");
const FileStore = @import("file_store.zig").FileStore;
const RealSyncer = @import("syncer.zig").RealSyncer;
const Syncer = @import("syncer.zig").Syncer;
const default_page_size = @import("file_store.zig").default_page_size;
const Arena = @import("arena.zig").Arena;
const Allocation = @import("arena.zig").Allocation;
const Ref = @import("ref.zig").Ref;
const Slot = @import("slots.zig").Slot;
const FreeExtent = @import("freelist.zig").FreeExtent;
const FreeList = @import("freelist.zig").FreeList;
const Coord = @import("coord.zig").Coord;
const coord_mod = @import("coord.zig");
const typedir = @import("typedir.zig");
const compaction = @import("compaction.zig");

const slot_a_off: usize = 64;
const slot_b_off: usize = 128;

// Version->root ring log, in the reserved header page (page 0, [0, default_page_size)).
// The arena's data starts at default_page_size, so the header page has free room past
// the FileStore header ([0,32)) and the two commit slots (A: [64,100), B: [128,164)).
//   ring_head_off: u32 LE, monotonically increasing count of entries ever written.
//                  The live head index is ring_head % ring_capacity.
//   ring_off:      ring_capacity entries, each 16 bytes [version u64 LE][root_ref u64 LE].
// End of ring = ring_off + ring_capacity*16 = 1024 + 128*16 = 3072 < 4096. No overlap.
pub const ring_head_off: usize = 1016;
pub const ring_off: usize = 1024;
pub const ring_capacity: u32 = 128;

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
    /// Retention window: committed-free space is withheld from reuse until it is
    /// older than `active_version - retain_versions`. 0 disables the window.
    retain_versions: u64 = 0,
    /// Opt-in: when set, the caller drives `maybeCompactStep` to amortize compaction.
    auto_compact: bool = false,

    /// Measurement-only counters accumulated since open. Updated by commit; never
    /// affect behavior. fl_encode_ns is the total nanoseconds spent encoding the
    /// persistent free list onto the arena (byteLen + bump alloc + encode), and
    /// fl_extents_encoded is the sum of free-list extent counts encoded across all
    /// commits. commit_count is the number of commits whose encode completed.
    fl_encode_ns: u64 = 0,
    fl_extents_encoded: u64 = 0,
    commit_count: u64 = 0,

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
        // Zero the version->root ring region so head starts at 0 and all entries are
        // empty. The ring is left empty; the first real commit populates it. A fresh
        // file is already zero-filled, but zero explicitly so create is self-contained.
        @memset(store.map[ring_head_off .. ring_off + @as(usize, ring_capacity) * 16], 0);
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
            .arena = Arena.init(store.sectionsView(), default_page_size),
            .active_version = 1,
            .active_root = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = FreeList.init(allocator),
            .free_list_node_ref = 0,
            .free_list_node_len = 0,
            .coord = coord,
            .participant_slot = slot,
            .retain_versions = 0,
            .auto_compact = false,
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
        // Capture the section table before store is copied into the partial Db below.
        // The slice points at heap memory owned by store.sections, which survives the
        // by-value move of store into db.store.
        const store_sections = store.sectionsView();

        // Build a partial Db so we can call selectActiveSlot and loadFreeList.
        // coord is left undefined; it is set at the very end.
        // On any error path, errdefer store.deinit() (above) frees the file+mmap,
        // and errdefer db.free_list.deinit() (below) frees any allocated extents.
        // db.pins is always empty here (no allocation), so it is safe to drop.
        var db: Db = .{
            .store = store,
            .arena = Arena.init(store_sections, default_page_size),
            .active_version = 0,
            .active_root = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = FreeList.init(allocator),
            .free_list_node_ref = 0,
            .free_list_node_len = 0,
            .coord = undefined,
            .participant_slot = null,
            .retain_versions = 0,
            .auto_compact = false,
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
        // If another process extended the file, map the new sections before dereferencing
        // slot descriptors or free-list nodes that may live in the grown region.
        const flen = try self.store.fileLen();
        const mapped = self.store.sectionsView().len * platform.section_size;
        if (flen > mapped) {
            try self.store.grow(@intCast(flen));
            self.arena.sections = self.store.sectionsView();
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
    pub fn publishPins(self: *Db) void {
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

    /// Open a read snapshot at a past committed `version`. Returns
    /// error.VersionUnavailable if the version is not in the durable ring or has
    /// aged out of the retention window (its nodes may have been reclaimed).
    /// Pins the version so its nodes are held for the life of the read.
    pub fn beginReadAt(self: *Db, version: u64) !ReadTxn {
        try self.refreshToLatest();
        if (version > self.active_version) return error.VersionUnavailable;
        // Must be inside the retention window: older versions' nodes may already
        // be reclaimed. maxInt retain_versions means "retain everything".
        if (self.retain_versions != std.math.maxInt(u64)) {
            if (version < self.active_version -| self.retain_versions) return error.VersionUnavailable;
        }
        const root = if (version == self.active_version)
            self.active_root
        else
            (self.versionRoot(version) orelse return error.VersionUnavailable);
        if (self.pins.getPtr(version)) |ptr| {
            ptr.* += 1;
        } else {
            try self.pins.put(version, 1);
        }
        self.publishPins();
        return ReadTxn{ .db = self, .root_ref = root, .version = version };
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

    /// Oldest version still pinned by a live reader in this process, or the
    /// active version if no reader is open.
    pub fn oldestPinnedVersion(self: *Db) u64 {
        return self.horizon();
    }

    /// Number of processes currently attached to this database.
    pub fn attachedProcesses(self: *Db) u32 {
        return self.coord.attachCount();
    }

    /// Logical size: the high-water mark of allocated arena bytes.
    pub fn logicalSize(self: *Db) u64 {
        return @intCast(self.arena.top);
    }

    /// Physical size of the backing file on disk.
    pub fn fileSize(self: *Db) !u64 {
        return self.store.fileLen();
    }

    /// Withhold recently-freed space from reuse for the most recent `n` versions.
    pub fn setRetainVersions(self: *Db, n: u64) void {
        self.retain_versions = n;
    }

    /// Perform at most one budgeted incremental-compaction step on `type_id`,
    /// committing the result in its own write transaction. Returns `ran = false`
    /// (a no-op) when the type does not yet warrant compaction; otherwise reports
    /// the rows moved this step and whether the type is now fully packed.
    ///
    /// Advisory and opt-in: this is never invoked from `commit` or any hot path.
    /// The `auto_compact` flag is consulted by callers to decide whether to drive
    /// this loop; the method itself does not check it.
    pub fn maybeCompactStep(self: *Db, type_id: u16, budget: usize) !struct { ran: bool, moved: usize, done: bool } {
        var w = try self.beginWrite();
        errdefer w.deinit();
        const dir = self.active_root;
        const cat = try typedir.catalogRef(&w, dir, type_id);
        if (!try compaction.shouldCompact(&w, cat)) {
            w.deinit();
            return .{ .ran = false, .moved = 0, .done = false };
        }
        const step = try compaction.compactStep(&w, cat, budget);
        const new_dir = try typedir.setCatalogRef(&w, dir, type_id, step.cat);
        w.setRoot(new_dir);
        _ = try w.commit();
        return .{ .ran = true, .moved = step.moved, .done = step.done };
    }

    /// Root ref for a committed version, or null if not retained / not yet committed.
    /// The `version > active_version` guard rejects a ring entry written during a
    /// commit that crashed/aborted before publishing (the slot flip never happened),
    /// so a recorded-but-unpublished pair is never trusted.
    pub fn versionRoot(self: *Db, version: u64) ?u64 {
        if (version > self.active_version) return null;
        const map = self.store.map;
        const head = std.mem.readInt(u32, map[ring_head_off..][0..4], .little);
        const n = @min(head, ring_capacity);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const e = ring_off + @as(usize, i) * 16;
            const v = std.mem.readInt(u64, map[e..][0..8], .little);
            if (v == version) return std.mem.readInt(u64, map[e + 8 ..][0..8], .little);
        }
        return null;
    }

    /// Oldest version still recorded in the ring, or active_version if the ring is
    /// empty. As the ring wraps, the recovery window's lower bound advances. Entries
    /// above active_version (an unpublished/aborted commit) are ignored.
    pub fn oldestRetainedVersion(self: *Db) u64 {
        const map = self.store.map;
        const head = std.mem.readInt(u32, map[ring_head_off..][0..4], .little);
        const n = @min(head, ring_capacity);
        var min: ?u64 = null;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const e = ring_off + @as(usize, i) * 16;
            const v = std.mem.readInt(u64, map[e..][0..8], .little);
            if (v > self.active_version) continue;
            if (min == null or v < min.?) min = v;
        }
        return min orelse self.active_version;
    }

    /// Oldest version `beginReadAt` can open: the later of the oldest ring entry
    /// and the retention-window floor. Versions in [this, active_version] open.
    pub fn oldestReadableVersion(self: *Db) u64 {
        const ring_floor = self.oldestRetainedVersion();
        if (self.retain_versions == std.math.maxInt(u64)) return ring_floor;
        return @max(ring_floor, self.active_version -| self.retain_versions);
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
            .txn_reuse = FreeList.init(self.store.allocator),
            .txn_start_top = self.arena.top,
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

    /// Bump-allocate `size` bytes, mapping additional sections if the arena is full.
    /// `error.AllocTooLarge` (size > section_size) is propagated; `error.OutOfSpace`
    /// maps one more section and retries. Each retry adds exactly one section, which is
    /// always enough: a single allocation never crosses more than one section boundary.
    pub fn bumpGrowing(self: *Db, size: usize) !Allocation {
        while (true) {
            if (self.arena.alloc(size)) |a| {
                return a;
            } else |e| switch (e) {
                error.AllocTooLarge => return e,
                error.OutOfSpace => {
                    const target = (self.store.sectionsView().len + 1) << platform.section_shift;
                    try self.store.ensureMapped(target);
                    self.arena.sections = self.store.sectionsView();
                },
            }
        }
    }

    /// Test-only accessor: number of extents in the committed free list.
    pub fn freeListLenForTest(self: *Db) usize {
        return self.free_list.extents.items.len;
    }

    pub const Metrics = struct {
        mapped_len: u64,
        latest_version: u64,
        oldest_pinned_version: u64,
        free_extent_count: usize,
        reclaimable_bytes: u64,
        // Measurement-only cost counters accumulated since open.
        fl_encode_ns: u64,
        fl_extents_encoded: u64,
        commit_count: u64,
        setlength_ns: u64,
        setlength_calls: u64,
    };

    pub fn metrics(self: *Db) Metrics {
        var reclaimable: u64 = 0;
        for (self.free_list.extents.items) |e| reclaimable += e.len;
        return .{
            .mapped_len = @intCast(self.store.sectionsView().len * platform.section_size),
            .latest_version = self.active_version,
            .oldest_pinned_version = self.horizon(),
            .free_extent_count = self.free_list.extents.items.len,
            .reclaimable_bytes = reclaimable,
            .fl_encode_ns = self.fl_encode_ns,
            .fl_extents_encoded = self.fl_extents_encoded,
            .commit_count = self.commit_count,
            .setlength_ns = self.store.setlength_ns,
            .setlength_calls = self.store.setlength_calls,
        };
    }

    pub fn verifyIntegrity(self: *Db) VerifyError!void {
        if (!self.store.header_checksum_ok) return error.HeaderCorrupt;

        const a_ok = Slot.decode(self.store.map[slot_a_off .. slot_a_off + Slot.size]) catch null;
        const b_ok = Slot.decode(self.store.map[slot_b_off .. slot_b_off + Slot.size]) catch null;
        if (a_ok == null and b_ok == null) return error.SlotCorrupt;

        const limit = self.store.sectionsView().len * platform.section_size;

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
// Transaction types (defined in their own modules; re-exported here so existing
// call sites that do @import("db.zig").ReadTxn / .WriteTxn keep working).
// ---------------------------------------------------------------------------

pub const ReadTxn = @import("read_txn.zig").ReadTxn;
pub const WriteTxn = @import("write_txn.zig").WriteTxn;

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

test "observability: pinned version and storage size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "obs.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // First write+commit advances active_version.
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRST!!!");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No open reader: the oldest pinned version is the active version.
    try testing.expectEqual(db.active_version, db.oldestPinnedVersion());

    // Hold a reader at the current version, then commit a newer version.
    var r = try db.beginRead();
    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "SECOND!!");
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    // The held reader pins the older version, below the new active version.
    try testing.expect(db.oldestPinnedVersion() < db.active_version);

    try testing.expectEqual(@as(u32, 1), db.attachedProcesses());
    try testing.expect(db.logicalSize() > 0);
    try testing.expect((try db.fileSize()) >= db.logicalSize());

    r.end();
    try testing.expectEqual(db.active_version, db.oldestPinnedVersion());
}

test "metrics report mapped length, versions, and reclaimable bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "metrics.airdb");
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

    const m = db.metrics();
    try testing.expect(m.mapped_len >= 4096 * 256);
    try testing.expectEqual(db.active_version, m.latest_version);
    try testing.expect(m.free_extent_count >= 1);
    try testing.expect(m.reclaimable_bytes >= 8);
    try testing.expectEqual(db.active_version, m.oldest_pinned_version); // no readers
}

test "version->root ring records committed versions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ring.airdb");
    defer testing.allocator.free(path);

    const k: u64 = 5;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        // Version 1 (the initial slot) was never written into the ring.
        try testing.expectEqual(@as(?u64, null), db.versionRoot(1));

        var i: u64 = 0;
        while (i < k) : (i += 1) {
            var w = try db.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "RINGDATA");
            w.setRoot(a.ref);
            _ = try w.commit();
        }

        // Each committed version (2..active_version) maps to a non-zero root.
        var v: u64 = 2;
        while (v <= db.active_version) : (v += 1) {
            const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
        }
        // A version that was never committed yet is null.
        try testing.expectEqual(@as(?u64, null), db.versionRoot(db.active_version + 1));
    }

    // The ring lives in the durable header page, so it survives reopen.
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expectEqual(@as(u64, 1 + k), db.active_version);
        var v: u64 = 2;
        while (v <= db.active_version) : (v += 1) {
            const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
        }
    }
}

test "ring wraps after capacity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ringwrap.airdb");
    defer testing.allocator.free(path);

    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Commit more than ring_capacity times so the ring wraps and evicts old entries.
    const total: u64 = @as(u64, ring_capacity) + 12;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "WRAPDATA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }

    const newest = db.active_version; // 1 + total
    const oldest_live = newest - @as(u64, ring_capacity) + 1;

    // The most recent ring_capacity versions are all present.
    try testing.expectEqual(oldest_live, db.oldestRetainedVersion());
    var v: u64 = oldest_live;
    while (v <= newest) : (v += 1) {
        const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
        try testing.expect(r != 0);
    }

    // Versions older than the live window were evicted.
    try testing.expectEqual(@as(?u64, null), db.versionRoot(oldest_live - 1));
    try testing.expectEqual(@as(?u64, null), db.versionRoot(2));
}

test "beginReadAt opens a past version within the retention window" {
    const objects = @import("objects.zig");
    const catalog = @import("catalog.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    db.setRetainVersions(std.math.maxInt(u64)); // retain everything

    // v_a: pk 1 ; v_b: + pk 2 ; v_c: + pk 3 (additive, so each version's live set differs)
    var va: u64 = undefined;
    var vb: u64 = undefined;
    var vc: u64 = undefined;
    {
        var w = try db.beginWrite();
        var cat = try catalog.create(&w, 2);
        cat = (try objects.insert(&w, cat, &.{ 1, 100 })).cat;
        w.setRoot(cat);
        va = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try objects.insert(&w, w.new_root, &.{ 2, 200 })).cat;
        w.setRoot(cat);
        vb = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try objects.insert(&w, w.new_root, &.{ 3, 300 })).cat;
        w.setRoot(cat);
        vc = try w.commit();
    }

    var out: [2]u64 = undefined;
    // Past snapshot at v_a: only pk 1 exists.
    {
        var r = try db.beginReadAt(va);
        defer r.end();
        try testing.expectEqual(@as(u64, 1), try compaction.liveCount(&r, r.root()));
        try testing.expect((try objects.getByPk(&r, r.root(), 1, &out)) != null);
        try testing.expectEqual(@as(?u64, null), try objects.getByPk(&r, r.root(), 2, &out));
    }
    // Past snapshot at v_b: pk 1 and 2.
    {
        var r = try db.beginReadAt(vb);
        defer r.end();
        try testing.expectEqual(@as(u64, 2), try compaction.liveCount(&r, r.root()));
    }
    // Latest: all three.
    {
        var r = try db.beginRead();
        defer r.end();
        try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, r.root()));
    }
    // A future version is unavailable.
    try testing.expectError(error.VersionUnavailable, db.beginReadAt(vc + 5));
}

test "beginReadAt rejects a version aged out of the retention window" {
    const objects = @import("objects.zig");
    const catalog = @import("catalog.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    // retain_versions defaults to 0: only the active version is readable.
    var va: u64 = undefined;
    {
        var w = try db.beginWrite();
        var cat = try catalog.create(&w, 2);
        cat = (try objects.insert(&w, cat, &.{ 1, 100 })).cat;
        w.setRoot(cat);
        va = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try objects.insert(&w, w.new_root, &.{ 2, 200 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    // v_a is older than active - retain_versions(0) -> aged out.
    try testing.expectError(error.VersionUnavailable, db.beginReadAt(va));
    try testing.expect(db.oldestReadableVersion() == db.active_version);
}

// Churn a single int-pk type at `path` with a steady live set: seed `live`
// rows, then on each iteration insert `live` fresh rows and delete the `live`
// oldest live rows (net-zero live count). Dead rows accumulate, so next_row
// grows without bound unless compaction reclaims it. When `auto` is set, the
// caller drives maybeCompactStep after each iteration until the type is packed.
// Returns the final next_row (physical row high-water) and live count.
fn churnNetZero(path: []const u8, live: u64, iters: u64, auto: bool) !struct { next_row: u64, live: u64 } {
    const catalog = @import("catalog.zig");
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    db.auto_compact = auto;
    const tid: u16 = 0;

    // Single type: int pk + one int prop.
    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Seed the live set (pks [0, live)).
    var hi: u64 = 0;
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
        while (hi < live) : (hi += 1) {
            dir = (try typedir.insert(&w, dir, tid, &.{ .{ .int = hi }, .{ .int = hi } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    var lo: u64 = 0;
    var iter: u64 = 0;
    while (iter < iters) : (iter += 1) {
        {
            var w = try db.beginWrite();
            var dir = db.active_root;
            // Insert `live` fresh rows.
            var k: u64 = 0;
            while (k < live) : (k += 1) {
                dir = (try typedir.insert(&w, dir, tid, &.{ .{ .int = hi }, .{ .int = hi } })).dir;
                hi += 1;
            }
            // Delete the `live` oldest live rows.
            k = 0;
            while (k < live) : (k += 1) {
                var out: [2]catalog.Value = undefined;
                const ver = (try typedir.get(&w, dir, tid, lo, &out)).?;
                dir = switch (try typedir.delete(&w, dir, tid, lo, ver)) {
                    .ok => |d| d,
                    else => unreachable,
                };
                lo += 1;
            }
            w.setRoot(dir);
            _ = try w.commit();
        }
        // Opt-in: drive the incremental step loop so the type stays packed.
        if (db.auto_compact) {
            while (true) {
                const res = try db.maybeCompactStep(tid, 4);
                if (!res.ran or res.done) break;
            }
        }
    }

    var r = try db.beginRead();
    defer r.end();
    const cat = try typedir.catalogRef(&r, r.root(), tid);
    return .{
        .next_row = (try catalog.loadCatalog(&r, cat)).next_row,
        .live = try compaction.liveCount(&r, cat),
    };
}

test "maybeCompactStep bounds dead rows under churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const off_path = try tmpFilePath(testing.allocator, &tmp, "churnoff.airdb");
    defer testing.allocator.free(off_path);
    const on_path = try tmpFilePath(testing.allocator, &tmp, "churnon.airdb");
    defer testing.allocator.free(on_path);

    // Identical churn, run twice: without auto-compaction, then with it.
    const without = try churnNetZero(off_path, 10, 40, false);
    const with = try churnNetZero(on_path, 10, 40, true);

    // Live data is preserved identically in both runs.
    try testing.expectEqual(without.live, with.live);
    // Compaction reclaims the dead-row space: the physical high-water is strictly
    // smaller when the step loop runs.
    try testing.expect(with.next_row < without.next_row);
}

test "maybeCompactStep is a no-op when nothing to compact" {
    const catalog = @import("catalog.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "nocompact.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    const tid: u16 = 0;
    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var pk: u64 = 0;
        while (pk < 3) : (pk += 1) {
            dir = (try typedir.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    const res = try db.maybeCompactStep(tid, 4);
    try testing.expect(!res.ran);
    try testing.expectEqual(@as(usize, 0), res.moved);
    try testing.expect(!res.done);

    // The type is untouched: all three rows remain live and packed.
    var r = try db.beginRead();
    defer r.end();
    const cat = try typedir.catalogRef(&r, r.root(), tid);
    try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, cat));
    try testing.expectEqual(@as(u64, 3), (try catalog.loadCatalog(&r, cat)).next_row);
}
