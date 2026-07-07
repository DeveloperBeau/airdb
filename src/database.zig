// database.zig -- Db, ReadTransaction, WriteTransaction, and the two-slot atomic durable commit.
//
// Slot A byte range in the header page: [64, 64+Slot.size).
// Slot B byte range in the header page: [128, 128+Slot.size).
// Data arena starts at default_page_size.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("platform.zig");
const FileStore = @import("storage/fileStore.zig").FileStore;
const FileSyncer = @import("storage/syncer.zig").FileSyncer;
const Syncing = @import("storage/syncer.zig").Syncing;
const default_page_size = @import("storage/fileStore.zig").default_page_size;
const Arena = @import("storage/arena.zig").Arena;
const Allocation = @import("storage/arena.zig").Allocation;
const Reference = @import("storage/reference.zig").Reference;
const Slot = @import("storage/slots.zig").Slot;
const FreeList = @import("storage/freeList.zig").FreeList;
const Coord = @import("transactions/coordination.zig").Coord;
const coord_mod = @import("transactions/coordination.zig");
const versioning = @import("transactions/versioning.zig");
const freeListRecovery = @import("storage/freeListRecovery.zig");

/// Byte offset of commit slot A in the header page.
pub const slot_a_off: usize = 64;
/// Byte offset of commit slot B in the header page.
pub const slot_b_off: usize = 128;

// Version->root ring log, in the reserved header page (page 0, [0, default_page_size)).
// The arena's data starts at default_page_size, so the header page has free room past
// the FileStore header ([0,32)) and the two commit slots (A: [64,100), B: [128,164)).
//   ring_head_off: u64 LE, monotonically increasing count of entries ever written.
//                  The live head index is ring_head % ring_capacity. u64 so the
//                  counter cannot overflow within any plausible commit volume (a
//                  u32 wraps after ~4 billion commits and would panic mid-commit).
//   ring_off:      ring_capacity entries, each 16 bytes [version u64 LE][root_ref u64 LE].
// End of ring = ring_off + ring_capacity*16 = 1024 + 128*16 = 3072 < 4096. No overlap.
pub const ring_head_off: usize = 1016;
pub const ring_off: usize = 1024;
pub const ring_capacity: u32 = 128;

// Retention window, persisted in the header page so EVERY process honors the
// same reclaim floor: committed-free space is withheld from reuse until it is
// older than `active_version - retain`. A per-instance in-memory setting would
// let a default-configured writer in another process reuse space under a
// point-in-time reader that relies on the window. u64 LE at [192, 200);
// 8-aligned, clear of slot B ([128, 164)) and the ring head (1016). Zero on a
// fresh (zero-filled) file, matching the old default. maxInt means "retain
// everything". Read/written atomically through the shared mapping.
pub const retain_off: usize = 192;

// ---------------------------------------------------------------------------
// Db
// ---------------------------------------------------------------------------

/// Two-pointer packing cursor for one in-flight incremental-compaction run.
/// Owned by the Db (it persists across the write transactions that drive the
/// run) but read and advanced exclusively by compaction.compactStep, which
/// documents the resume/reset rules. live_count and next_row pin the run to a
/// specific catalog shape; hole_lo scans upward for dead relocation targets
/// and high_hi scans downward for live rows that must move.
pub const CompactCursor = struct {
    /// The TYPE this cursor belongs to plus the catalog ref it was persisted
    /// against. Both are required for a resume: live_count/next_row are a
    /// heuristic two different types can momentarily share, and the catalog
    /// ref ALONE is recyclable (freed catalog nodes are exact-size-class
    /// reused, so another type's catalog can land on the same ref). Resuming
    /// a foreign cursor would leave rows unexamined ahead of the tail
    /// truncate -- silent live-row loss in release builds.
    type_id: u16,
    cat: Reference,
    live_count: u64,
    next_row: u64,
    hole_lo: u64,
    high_hi: u64,
};

pub const Db = struct {
    store: FileStore,
    arena: Arena,
    active_version: u64,
    active_root: Reference,
    pins: std.AutoHashMap(u64, u32),
    /// Currently-committed free list. Owns its memory; deinit'd in Db.deinit.
    free_list: FreeList,
    /// Offset of the live free-list node on disk (0 if none).
    free_list_node_ref: Reference,
    /// Byte length of the live free-list node on disk (0 if none).
    free_list_node_len: usize,
    /// Coordination file for multi-process attach count and latest-version signal.
    coord: Coord,
    /// Index into the coord participant slot array claimed by this Db instance, or null
    /// if all 64 slots were occupied at open/create time.
    participant_slot: ?usize,
    // NOTE: the retention window is NOT an in-memory field. It lives in the
    // header page (see retain_off) so all attached processes share one floor;
    // read it with retainVersions() and set it with setRetainVersions().
    /// Opt-in: when set, the caller drives `maintenance.maybeCompactStep` to
    /// amortize compaction.
    auto_compact: bool = false,
    /// In-flight cursor for budget-proportional packing. Holds the two-pointer
    /// state for the type currently being compacted across successive
    /// `compactStep` calls; null between runs (and reset on any churn that moves
    /// the type's live_count/next_row). See `compaction.compactStep`.
    compact_cursor: ?CompactCursor = null,
    /// Set when recovery could not use the primary commit slot (its checksum or
    /// the header's was bad) and fell back to the other slot -- i.e. the database
    /// silently resumed from the previous version. Surfaced via metrics() so
    /// callers can log/alert on it; never set on a clean open.
    recovered_fallback: bool = false,
    /// Set when a commit's HEADER flush (the commit point) failed. The flipped
    /// commit pointer was already in the mapped header page before the failed
    /// barrier, so async writeback may persist it regardless -- the commit's
    /// on-disk fate is indeterminate. Further writes from this instance could
    /// scribble the maybe-published version's nodes, so beginWrite refuses
    /// until the database is reopened (open re-reads the header and resolves
    /// which side won).
    poisoned: bool = false,

    /// Measurement-only counters accumulated since open. Updated by commit; never
    /// affect behavior. fl_encode_ns is the total nanoseconds spent encoding the
    /// persistent free list onto the arena (byteLen + bump alloc + encode), and
    /// fl_extents_encoded is the sum of free-list extent counts encoded across all
    /// commits. commit_count is the number of commits whose encode completed.
    /// fl_rebuild_ns is the total nanoseconds spent rebuilding the new persistent
    /// free list from work_freelist + in_flight_frees in commit (the O(extent count)
    /// copy loops). fl_clone_ns is the total nanoseconds spent cloning the committed
    /// free list into work_freelist in beginWriteLocked (also O(extent count)).
    fl_encode_ns: u64 = 0,
    fl_extents_encoded: u64 = 0,
    commit_count: u64 = 0,
    fl_rebuild_ns: u64 = 0,
    fl_clone_ns: u64 = 0,

    /// Create a new database file at the given absolute path.
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Db {
        return createWith(allocator, path, FileSyncer.any());
    }

    /// Like create, but with an injectable Syncing (used for testing).
    pub fn createWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncing) !Db {
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
        // A participant slot is MANDATORY: without one this instance's reader
        // pins are invisible to other processes' reclaim horizons, so any
        // snapshot it opened could be scribbled by a concurrent writer. Refuse
        // the attach rather than silently degrade to corruptible reads.
        slot = (try coord.claimSlot()) orelse return error.TooManyAttachments;

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
            .auto_compact = false,
        };
    }

    /// Open an existing database file at the given absolute path.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        return openWith(allocator, path, FileSyncer.any());
    }

    /// Like open, but with an injectable Syncing (used for testing).
    pub fn openWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncing) !Db {
        var store = try FileStore.open(allocator, path, syncer);
        errdefer store.deinit();
        // Capture the section table before store is copied into the partial Db below.
        // The slice points at heap memory owned by store.sections, which survives the
        // by-value move of store into db.store.
        const store_sections = store.sectionsView();

        // Build a partial Db so versioning.selectActiveSlot and
        // freeListRecovery.loadFreeList can run against it.
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
            .auto_compact = false,
        };
        errdefer db.free_list.deinit();

        const active = try versioning.selectActiveSlot(&db);
        db.active_version = active.version;
        db.active_root = active.root_ref;
        db.arena.top = @intCast(active.logical_size);
        if (active.free_list_ref != 0) try freeListRecovery.loadFreeList(&db, active.free_list_ref);

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
        // Mandatory for the same reason as in createWith: invisible pins mean
        // corruptible snapshots.
        slot = (try coord.claimSlot()) orelse return error.TooManyAttachments;

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

    /// Publish the local minimum pinned version to our participant slot (if we have one).
    pub fn publishPins(self: *Db) void {
        versioning.publishPins(self);
    }

    pub fn beginRead(self: *Db) !ReadTransaction {
        // Pin-then-validate loop. Between refreshing to the latest published
        // version and this process's pin becoming visible in the coord slot, a
        // writer in another process may commit a NEWER version and compute a
        // reclaim horizon that does not include the pin -- admitting reuse of
        // exactly the nodes this snapshot references (with a zero retention
        // window, the previous version's replaced spine). Publishing the pin
        // FIRST and then re-reading the published latest version closes the
        // window: if the world moved past the pinned version while it was in
        // flight, unpin and chase the new version. The loop terminates because
        // versions only move forward and each retry pins the newest one seen.
        var prev_v: ?u64 = null;
        while (true) {
            try versioning.refreshToLatest(self);
            const v = self.active_version;
            const root = self.active_root;
            // A retry that made no progress means the published version keeps
            // running ahead of anything this instance can adopt (e.g. newer
            // slots do not decode). Fail rather than spin forever.
            if (prev_v != null and prev_v.? == v) return error.Corrupt;
            prev_v = v;
            if (self.pins.getPtr(v)) |ptr| {
                ptr.* += 1;
            } else {
                try self.pins.put(v, 1);
            }
            self.publishPins();
            const lv = self.coord.latestVersion();
            const retain = self.retainVersions();
            const floor = if (retain == coord_mod.sentinel_max) 0 else lv -| retain;
            if (v >= floor) {
                return ReadTransaction{ .db = self, .root_ref = root, .version = v };
            }
            // The pin landed too late; release it and pin the newer version.
            var stale = ReadTransaction{ .db = self, .root_ref = root, .version = v };
            stale.end();
        }
    }

    /// Open a read snapshot at a past committed `version`. Returns
    /// error.VersionUnavailable if the version is not in the durable ring or has
    /// aged out of the retention window (its nodes may have been reclaimed).
    /// Pins the version so its nodes are held for the life of the read.
    pub fn beginReadAt(self: *Db, version: u64) !ReadTransaction {
        try versioning.refreshToLatest(self);
        if (version > self.active_version) return error.VersionUnavailable;
        // Must be inside the retention window: older versions' nodes may already
        // be reclaimed. maxInt means "retain everything".
        const retain = self.retainVersions();
        if (retain != coord_mod.sentinel_max) {
            if (version < self.active_version -| retain) return error.VersionUnavailable;
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
        // Pin-then-validate. A writer in another process whose reclaim-horizon
        // load happened BEFORE our pin became visible may reuse extents freed
        // above `version` -- but only extents with freed_version <= its
        // active_version - retain. So once the pin is published, re-read the
        // published latest version: if `version` still clears the shared
        // retention floor of the newest possible in-flight writer, no such
        // writer can have reused a node this snapshot references. Otherwise
        // unpin and refuse the read rather than risk a corrupt snapshot.
        if (retain != coord_mod.sentinel_max) {
            const lv = self.coord.latestVersion();
            if (version < lv -| retain) {
                var transaction = ReadTransaction{ .db = self, .root_ref = root, .version = version };
                transaction.end(); // unpin
                return error.VersionUnavailable;
            }
        }
        return ReadTransaction{ .db = self, .root_ref = root, .version = version };
    }

    /// The minimum version pinned by a live reader in this process, or the
    /// active version if no reader is open.
    pub fn horizon(self: *Db) u64 {
        return versioning.horizon(self);
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

    /// The shared retention window: recently-freed space is withheld from reuse
    /// for the most recent `retainVersions()` versions, across ALL processes.
    pub fn retainVersions(self: *Db) u64 {
        return versioning.retainVersions(self);
    }

    /// Withhold recently-freed space from reuse for the most recent `n` versions.
    /// Shared and durable; see versioning.setRetainVersions for the safety rules.
    pub fn setRetainVersions(self: *Db, n: u64) void {
        versioning.setRetainVersions(self, n);
    }

    /// Root ref for a committed version, or null if not retained / not yet
    /// committed. See versioning.versionRoot for the ring-scan rules.
    pub fn versionRoot(self: *Db, version: u64) ?u64 {
        return versioning.versionRoot(self, version);
    }

    /// Oldest version still recorded in the ring, or active_version if the
    /// ring is empty.
    pub fn oldestRetainedVersion(self: *Db) u64 {
        return versioning.oldestRetainedVersion(self);
    }

    /// Oldest version `beginReadAt` can open: the later of the oldest ring
    /// entry and the retention-window floor.
    pub fn oldestReadableVersion(self: *Db) u64 {
        return versioning.oldestReadableVersion(self);
    }

    /// Shared body for beginWrite and beginWriteTry. Caller must hold the coord
    /// lock before calling; an errdefer in the caller releases the lock if this
    /// function returns an error.
    fn beginWriteLocked(self: *Db) !WriteTransaction {
        // A failed commit-point flush left the on-disk header indeterminate;
        // writing further could corrupt the version that may in fact have been
        // published. Reopen to resolve.
        if (self.poisoned) return error.CommitIndeterminate;
        // Refresh under the lock so the writer sees the truly-latest committed version.
        try versioning.refreshToLatest(self);
        // Clone the committed free list into work_freelist so the transaction
        // can reuse extents from it. db.free_list is untouched during the transaction;
        // work_freelist is the mutable clone that reuse() shrinks.
        var work_freelist = FreeList.init(self.store.allocator);
        errdefer work_freelist.deinit();
        // Measurement only: time the O(extent count) clone of the committed free
        // list. No behavior change; counter lives on the Db.
        const clone_io = std.Io.Threaded.global_single_threaded.io();
        const clone_start = Io.Clock.now(.awake, clone_io).nanoseconds;
        for (self.free_list.extents.items) |e| {
            try work_freelist.add(e);
        }
        self.fl_clone_ns += @intCast(Io.Clock.now(.awake, clone_io).nanoseconds - clone_start);
        return WriteTransaction{
            .db = self,
            .new_root = self.active_root,
            .new_version = self.active_version + 1,
            .in_flight_frees = .empty,
            .work_freelist = work_freelist,
            .transactionReuse = FreeList.init(self.store.allocator),
            .transactionStartTop = self.arena.top,
        };
    }

    /// Begin a write transaction, blocking until the cross-process write lock is
    /// acquired. The lock is released when the returned WriteTransaction is committed or
    /// abandoned via deinit.
    pub fn beginWrite(self: *Db) !WriteTransaction {
        try self.coord.lockExclusive();
        errdefer self.coord.unlock(); // release if refresh or setup fails
        return self.beginWriteLocked();
    }

    /// Like beginWrite but returns error.WouldBlock immediately if another writer
    /// currently holds the lock.
    pub fn beginWriteTry(self: *Db) !WriteTransaction {
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
        fl_rebuild_ns: u64,
        fl_clone_ns: u64,
        setlength_ns: u64,
        setlength_calls: u64,
        /// True when open had to fall back past a corrupt primary slot or header
        /// and resumed from the previous version. Worth logging/alerting on.
        recovered_fallback: bool,
        /// True when a commit-point flush failed and the instance refuses
        /// writes until reopen. Strictly more alarming than recovered_fallback.
        poisoned: bool,
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
            .fl_rebuild_ns = self.fl_rebuild_ns,
            .fl_clone_ns = self.fl_clone_ns,
            .setlength_ns = self.store.setlength_ns,
            .setlength_calls = self.store.setlength_calls,
            .recovered_fallback = self.recovered_fallback,
            .poisoned = self.poisoned,
        };
    }
};

// ---------------------------------------------------------------------------
// Transaction types (defined in their own modules; re-exported here so existing
// call sites that do @import("database.zig").ReadTransaction / .WriteTransaction keep working).
// ---------------------------------------------------------------------------

pub const ReadTransaction = @import("transactions/readTransaction.zig").ReadTransaction;
pub const WriteTransaction = @import("transactions/writeTransaction.zig").WriteTransaction;

test {
    _ = @import("databaseTests.zig");
}
