//! Database, ReadTransaction, WriteTransaction, and the two-slot atomic durable commit.
//!
//! Slot A byte range in the header page: [64, 64+Slot.size).
//! Slot B byte range in the header page: [128, 128+Slot.size).
//! Data arena starts at defaultPageSize.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("platform.zig");
const FileStore = @import("storage/fileStore.zig").FileStore;
const FileSyncer = @import("storage/syncer.zig").FileSyncer;
const Syncing = @import("storage/syncer.zig").Syncing;
const defaultPageSize = @import("storage/fileStore.zig").defaultPageSize;
const Arena = @import("storage/arena.zig").Arena;
const Allocation = @import("storage/arena.zig").Allocation;
const Reference = @import("storage/reference.zig").Reference;
const Slot = @import("storage/slots.zig").Slot;
const FreeList = @import("storage/freeList.zig").FreeList;
const Coordination = @import("transactions/coordination.zig").Coordination;
const coordMod = @import("transactions/coordination.zig");
const versioning = @import("transactions/versioning.zig");
const freeListRecovery = @import("storage/freeListRecovery.zig");

/// Byte offset of commit slot A in the header page.
pub const slotAOff: usize = 64;
/// Byte offset of commit slot B in the header page.
pub const slotBOff: usize = 128;

// Version->root ring log, in the reserved header page (page 0, [0, defaultPageSize)).
// The arena's data starts at defaultPageSize, so the header page has free room past
// the FileStore header ([0,32)) and the two commit slots (A: [64,100), B: [128,164)).
// End of ring = ringOff + ringCapacity*16 = 1024 + 128*16 = 3072 < 4096. No overlap.

/// Byte offset of the ring head: a u64 LE monotonically increasing count of
/// entries ever written. The live head index is ringHead % ringCapacity. u64
/// so the counter cannot overflow within any plausible commit volume (a u32
/// wraps after ~4 billion commits and would panic mid-commit).
pub const ringHeadOff: usize = 1016;
/// Byte offset of the ring entries: ringCapacity entries of 16 bytes each,
/// [version u64 LE][rootRef u64 LE].
pub const ringOff: usize = 1024;
/// Number of (version, root) entries the ring log retains; older versions'
/// roots are overwritten and become unreadable for point-in-time reads.
pub const ringCapacity: u32 = 128;

/// Byte offset of the retention window, persisted in the header page so EVERY
/// process honors the same reclaim floor: committed-free space is withheld
/// from reuse until it is older than `activeVersion - retain`. A per-instance
/// in-memory setting would let a default-configured writer in another process
/// reuse space under a point-in-time reader that relies on the window. u64 LE
/// at [192, 200); 8-aligned, clear of slot B ([128, 164)) and the ring head
/// (1016). Zero on a fresh (zero-filled) file, matching the old default.
/// maxInt means "retain everything". Read/written atomically through the
/// shared mapping.
pub const retainOff: usize = 192;

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

/// Two-pointer packing cursor for one in-flight incremental-compaction run.
/// Owned by the Database (it persists across the write transactions that drive the
/// run) but read and advanced exclusively by compaction.compactStep, which
/// documents the resume/reset rules. liveCount and nextRow pin the run to a
/// specific catalog shape; holeLo scans upward for dead relocation targets
/// and highHi scans downward for live rows that must move.
pub const CompactCursor = struct {
    /// The TYPE this cursor belongs to plus the catalog ref it was persisted
    /// against. Both are required for a resume: liveCount/nextRow are a
    /// heuristic two different types can momentarily share, and the catalog
    /// ref ALONE is recyclable (freed catalog nodes are exact-size-class
    /// reused, so another type's catalog can land on the same ref). Resuming
    /// a foreign cursor would leave rows unexamined ahead of the tail
    /// truncate -- silent live-row loss in release builds.
    typeId: u16,
    catalogRef: Reference,
    liveCount: u64,
    nextRow: u64,
    holeLo: u64,
    highHi: u64,
};

/// One process's handle to a database file: the mapped store and arena, the
/// currently adopted version and root, this instance's reader pins, the
/// committed free list, and the cross-process coordination state. Create/open
/// via create()/open(); read via beginRead()/beginReadAt(); mutate via
/// beginWrite().
pub const Database = struct {
    store: FileStore,
    arena: Arena,
    activeVersion: u64,
    activeRoot: Reference,
    pins: std.AutoHashMap(u64, u32),
    /// Currently-committed free list. Owns its memory; deinit'd in Database.deinit.
    freeList: FreeList,
    /// Offset of the live free-list node on disk (0 if none).
    freeListNodeRef: Reference,
    /// Byte length of the live free-list node on disk (0 if none).
    freeListNodeLen: usize,
    /// Coordination file for multi-process attach count and latest-version signal.
    coord: Coordination,
    /// Index into the coord participant slot array claimed by this Database instance, or null
    /// if all 64 slots were occupied at open/create time.
    participantSlot: ?usize,
    // NOTE: the retention window is NOT an in-memory field. It lives in the
    // header page (see retainOff) so all attached processes share one floor;
    // read it with retainVersions() and set it with setRetainVersions().
    /// Opt-in: when set, the caller drives `maintenance.maybeCompactStep` to
    /// amortize compaction.
    autoCompact: bool = false,
    /// In-flight cursor for budget-proportional packing. Holds the two-pointer
    /// state for the type currently being compacted across successive
    /// `compactStep` calls; null between runs (and reset on any churn that moves
    /// the type's liveCount/nextRow). See `compaction.compactStep`.
    compactCursor: ?CompactCursor = null,
    /// Set when recovery could not use the primary commit slot (its checksum or
    /// the header's was bad) and fell back to the other slot -- i.e. the database
    /// silently resumed from the previous version. Surfaced via metrics() so
    /// callers can log/alert on it; never set on a clean open.
    recoveredFallback: bool = false,
    /// Set when a commit's HEADER flush (the commit point) failed. The flipped
    /// commit pointer was already in the mapped header page before the failed
    /// barrier, so async writeback may persist it regardless -- the commit's
    /// on-disk fate is indeterminate. Further writes from this instance could
    /// scribble the maybe-published version's nodes, so beginWrite refuses
    /// until the database is reopened (open re-reads the header and resolves
    /// which side won).
    poisoned: bool = false,

    /// Measurement-only counters accumulated since open. Updated by commit; never
    /// affect behavior. flEncodeNs is the total nanoseconds spent encoding the
    /// persistent free list onto the arena (byteLen + bump alloc + encode), and
    /// flExtentsEncoded is the sum of free-list extent counts encoded across all
    /// commits. commitCount is the number of commits whose encode completed.
    /// flRebuildNs is the total nanoseconds spent rebuilding the new persistent
    /// free list from workFreelist + inFlightFrees in commit (the O(extent count)
    /// copy loops). flCloneNs is the total nanoseconds spent cloning the committed
    /// free list into workFreelist in beginWriteLocked (also O(extent count)).
    flEncodeNs: u64 = 0,
    flExtentsEncoded: u64 = 0,
    commitCount: u64 = 0,
    flRebuildNs: u64 = 0,
    flCloneNs: u64 = 0,

    /// Create a new database file at the given absolute path.
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Database {
        return createWith(allocator, path, FileSyncer.any());
    }

    /// Like create, but with an injectable Syncing (used for testing).
    pub fn createWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncing) !Database {
        var store = try FileStore.create(allocator, path, syncer);
        errdefer store.deinit();

        // Write version-1 into slot A; mark it active.
        const initial = Slot{
            .version = 1,
            .rootRef = 0,
            .freeListRef = 0,
            .logicalSize = defaultPageSize,
        };
        initial.encode(store.map[slotAOff..][0..Slot.size]);
        store.header.activeSlot = 0;
        // Zero the version->root ring region so head starts at 0 and all entries are
        // empty. The ring is left empty; the first real commit populates it. A fresh
        // file is already zero-filled, but zero explicitly so create is self-contained.
        @memset(store.map[ringHeadOff .. ringOff + @as(usize, ringCapacity) * 16], 0);
        store.persistHeader();
        try store.syncer.flush(store.file);

        // Coord setup -- done last so the errdefer has no further try-s after it.
        const coordPath = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
        defer allocator.free(coordPath);
        var coord = try Coordination.openOrCreate(coordPath);
        var slot: ?usize = null;
        errdefer {
            if (slot) |claimed| coord.releaseSlot(claimed);
            _ = coord.detach();
            coord.deinit();
        }
        _ = coord.attach();
        // A participant slot is MANDATORY: without one this instance's reader
        // pins are invisible to other processes' reclaim horizons, so any
        // snapshot it opened could be scribbled by a concurrent writer. Refuse
        // the attach rather than silently degrade to corruptible reads.
        slot = (try coord.claimSlot()) orelse return error.TooManyAttachments;

        return Database{
            .store = store,
            .arena = Arena.init(store.sectionsView(), defaultPageSize),
            .activeVersion = 1,
            .activeRoot = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .freeList = FreeList.init(allocator),
            .freeListNodeRef = 0,
            .freeListNodeLen = 0,
            .coord = coord,
            .participantSlot = slot,
            .autoCompact = false,
        };
    }

    /// Open an existing database file at the given absolute path.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        return openWith(allocator, path, FileSyncer.any());
    }

    /// Like open, but with an injectable Syncing (used for testing).
    pub fn openWith(allocator: std.mem.Allocator, path: []const u8, syncer: Syncing) !Database {
        var store = try FileStore.open(allocator, path, syncer);
        errdefer store.deinit();
        // Capture the section table before store is copied into the partial Database below.
        // The slice points at heap memory owned by store.sections, which survives the
        // by-value move of store into database.store.
        const storeSections = store.sectionsView();

        // Build a partial Database so versioning.selectActiveSlot and
        // freeListRecovery.loadFreeList can run against it.
        // coord is left undefined; it is set at the very end.
        // On any error path, errdefer store.deinit() (above) frees the file+mmap,
        // and errdefer database.freeList.deinit() (below) frees any allocated extents.
        // database.pins is always empty here (no allocation), so it is safe to drop.
        var database: Database = .{
            .store = store,
            .arena = Arena.init(storeSections, defaultPageSize),
            .activeVersion = 0,
            .activeRoot = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .freeList = FreeList.init(allocator),
            .freeListNodeRef = 0,
            .freeListNodeLen = 0,
            .coord = undefined,
            .participantSlot = null,
            .autoCompact = false,
        };
        errdefer database.freeList.deinit();

        const active = try versioning.selectActiveSlot(&database);
        database.activeVersion = active.version;
        database.activeRoot = active.rootRef;
        database.arena.top = @intCast(active.logicalSize);
        if (active.freeListRef != 0) try freeListRecovery.loadFreeList(&database, active.freeListRef);

        // Coord setup -- done last so the errdefer has no further try-s after it.
        const coordPath = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
        defer allocator.free(coordPath);
        var coord = try Coordination.openOrCreate(coordPath);
        var slot: ?usize = null;
        errdefer {
            if (slot) |claimed| coord.releaseSlot(claimed);
            _ = coord.detach();
            coord.deinit();
        }
        _ = coord.attach();
        // Mandatory for the same reason as in createWith: invisible pins mean
        // corruptible snapshots.
        slot = (try coord.claimSlot()) orelse return error.TooManyAttachments;

        database.coord = coord;
        database.participantSlot = slot;
        return database;
    }

    /// Detach from the database: release this instance's participant slot,
    /// decrement the attach count, and unmap/close the coord and data files.
    pub fn deinit(self: *Database) void {
        if (self.participantSlot) |slotIndex| self.coord.releaseSlot(slotIndex);
        _ = self.coord.detach();
        self.coord.deinit();
        self.freeList.deinit();
        self.pins.deinit();
        self.store.deinit();
    }

    /// Publish the local minimum pinned version to our participant slot (if we have one).
    pub fn publishPins(self: *Database) void {
        versioning.publishPins(self);
    }

    /// Begin a read snapshot of the latest committed version, refreshing to
    /// any newer version another process published. Pins the version (and
    /// publishes the pin to the coord file) so its nodes cannot be reused
    /// until end().
    pub fn beginRead(self: *Database) !ReadTransaction {
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
        var prevV: ?u64 = null;
        while (true) {
            try versioning.refreshToLatest(self);
            const activeVersion = self.activeVersion;
            const root = self.activeRoot;
            // A retry that made no progress means the published version keeps
            // running ahead of anything this instance can adopt (e.g. newer
            // slots do not decode). Fail rather than spin forever.
            if (prevV != null and prevV.? == activeVersion) return error.Corrupt;
            prevV = activeVersion;
            if (self.pins.getPtr(activeVersion)) |ptr| {
                ptr.* += 1;
            } else {
                try self.pins.put(activeVersion, 1);
            }
            self.publishPins();
            const latestVersion = self.coord.latestVersion();
            const retain = self.retainVersions();
            const floor = if (retain == coordMod.sentinelMax) 0 else latestVersion -| retain;
            if (activeVersion >= floor) {
                return ReadTransaction{ .database = self, .rootRef = root, .version = activeVersion };
            }
            // The pin landed too late; release it and pin the newer version.
            var stale = ReadTransaction{ .database = self, .rootRef = root, .version = activeVersion };
            stale.end();
        }
    }

    /// Open a read snapshot at a past committed `version`. Returns
    /// error.VersionUnavailable if the version is not in the durable ring or has
    /// aged out of the retention window (its nodes may have been reclaimed).
    /// Pins the version so its nodes are held for the life of the read.
    pub fn beginReadAt(self: *Database, version: u64) !ReadTransaction {
        try versioning.refreshToLatest(self);
        if (version > self.activeVersion) return error.VersionUnavailable;
        // Must be inside the retention window: older versions' nodes may already
        // be reclaimed. maxInt means "retain everything".
        const retain = self.retainVersions();
        if (retain != coordMod.sentinelMax) {
            if (version < self.activeVersion -| retain) return error.VersionUnavailable;
        }
        const root = if (version == self.activeVersion)
            self.activeRoot
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
        // above `version` -- but only extents with freedVersion <= its
        // activeVersion - retain. So once the pin is published, re-read the
        // published latest version: if `version` still clears the shared
        // retention floor of the newest possible in-flight writer, no such
        // writer can have reused a node this snapshot references. Otherwise
        // unpin and refuse the read rather than risk a corrupt snapshot.
        if (retain != coordMod.sentinelMax) {
            const latestVersion = self.coord.latestVersion();
            if (version < latestVersion -| retain) {
                var transaction = ReadTransaction{ .database = self, .rootRef = root, .version = version };
                transaction.end(); // unpin
                return error.VersionUnavailable;
            }
        }
        return ReadTransaction{ .database = self, .rootRef = root, .version = version };
    }

    /// The minimum version pinned by a live reader in this process, or the
    /// active version if no reader is open.
    pub fn horizon(self: *Database) u64 {
        return versioning.horizon(self);
    }

    /// Oldest version still pinned by a live reader in this process, or the
    /// active version if no reader is open.
    pub fn oldestPinnedVersion(self: *Database) u64 {
        return self.horizon();
    }

    /// Number of processes currently attached to this database.
    pub fn attachedProcesses(self: *Database) u32 {
        return self.coord.attachCount();
    }

    /// Logical size: the high-water mark of allocated arena bytes.
    pub fn logicalSize(self: *Database) u64 {
        return @intCast(self.arena.top);
    }

    /// Physical size of the backing file on disk.
    pub fn fileSize(self: *Database) !u64 {
        return self.store.fileLen();
    }

    /// The shared retention window: recently-freed space is withheld from reuse
    /// for the most recent `retainVersions()` versions, across ALL processes.
    pub fn retainVersions(self: *Database) u64 {
        return versioning.retainVersions(self);
    }

    /// Withhold recently-freed space from reuse for the most recent `n` versions.
    /// Shared and durable; see versioning.setRetainVersions for the safety rules.
    pub fn setRetainVersions(self: *Database, count: u64) void {
        versioning.setRetainVersions(self, count);
    }

    /// Root ref for a committed version, or null if not retained / not yet
    /// committed. See versioning.versionRoot for the ring-scan rules.
    pub fn versionRoot(self: *Database, version: u64) ?u64 {
        return versioning.versionRoot(self, version);
    }

    /// Oldest version still recorded in the ring, or activeVersion if the
    /// ring is empty.
    pub fn oldestRetainedVersion(self: *Database) u64 {
        return versioning.oldestRetainedVersion(self);
    }

    /// Oldest version `beginReadAt` can open: the later of the oldest ring
    /// entry and the retention-window floor.
    pub fn oldestReadableVersion(self: *Database) u64 {
        return versioning.oldestReadableVersion(self);
    }

    /// Shared body for beginWrite and beginWriteTry. Caller must hold the coord
    /// lock before calling; an errdefer in the caller releases the lock if this
    /// function returns an error.
    fn beginWriteLocked(self: *Database) !WriteTransaction {
        // A failed commit-point flush left the on-disk header indeterminate;
        // writing further could corrupt the version that may in fact have been
        // published. Reopen to resolve.
        if (self.poisoned) return error.CommitIndeterminate;
        // Refresh under the lock so the writer sees the truly-latest committed version.
        try versioning.refreshToLatest(self);
        // Clone the committed free list into workFreelist so the transaction
        // can reuse extents from it. database.freeList is untouched during the transaction;
        // workFreelist is the mutable clone that reuse() shrinks.
        var workFreelist = FreeList.init(self.store.allocator);
        errdefer workFreelist.deinit();
        // Measurement only: time the O(extent count) clone of the committed free
        // list. No behavior change; counter lives on the Database.
        const cloneIo = std.Io.Threaded.global_single_threaded.io();
        const cloneStart = Io.Clock.now(.awake, cloneIo).nanoseconds;
        for (self.freeList.extents.items) |extent| {
            try workFreelist.add(extent);
        }
        self.flCloneNs += @intCast(Io.Clock.now(.awake, cloneIo).nanoseconds - cloneStart);
        return WriteTransaction{
            .database = self,
            .newRoot = self.activeRoot,
            .newVersion = self.activeVersion + 1,
            .inFlightFrees = .empty,
            .workFreelist = workFreelist,
            .transactionReuse = FreeList.init(self.store.allocator),
            .transactionStartTop = self.arena.top,
        };
    }

    /// Begin a write transaction, blocking until the cross-process write lock is
    /// acquired. The lock is released when the returned WriteTransaction is committed or
    /// abandoned via deinit.
    pub fn beginWrite(self: *Database) !WriteTransaction {
        try self.coord.lockExclusive();
        errdefer self.coord.unlock(); // release if refresh or setup fails
        return self.beginWriteLocked();
    }

    /// Like beginWrite but returns error.WouldBlock immediately if another writer
    /// currently holds the lock.
    pub fn beginWriteTry(self: *Database) !WriteTransaction {
        try self.coord.tryLockExclusive();
        errdefer self.coord.unlock(); // release if refresh or setup fails
        return self.beginWriteLocked();
    }

    /// Bump-allocate `size` bytes, mapping additional sections if the arena is full.
    /// `error.AllocTooLarge` (size > sectionSize) is propagated; `error.OutOfSpace`
    /// maps one more section and retries. Each retry adds exactly one section, which is
    /// always enough: a single allocation never crosses more than one section boundary.
    pub fn bumpGrowing(self: *Database, size: usize) !Allocation {
        while (true) {
            if (self.arena.alloc(size)) |allocation| {
                return allocation;
            } else |err| switch (err) {
                error.AllocTooLarge => return err,
                error.OutOfSpace => {
                    const target = (self.store.sectionsView().len + 1) << platform.sectionShift;
                    try self.store.ensureMapped(target);
                    self.arena.sections = self.store.sectionsView();
                },
            }
        }
    }

    /// Test-only accessor: number of extents in the committed free list.
    pub fn freeListLenForTest(self: *Database) usize {
        return self.freeList.extents.items.len;
    }

    /// A point-in-time observability snapshot: sizes, versions, free-space
    /// totals, measurement-only cost counters, and the two recovery flags.
    /// Produced by metrics(); never affects behavior.
    pub const Metrics = struct {
        mappedLen: u64,
        latestVersion: u64,
        oldestPinnedVersion: u64,
        freeExtentCount: usize,
        reclaimableBytes: u64,
        // Measurement-only cost counters accumulated since open.
        flEncodeNs: u64,
        flExtentsEncoded: u64,
        commitCount: u64,
        flRebuildNs: u64,
        flCloneNs: u64,
        setlengthNs: u64,
        setlengthCalls: u64,
        /// True when open had to fall back past a corrupt primary slot or header
        /// and resumed from the previous version. Worth logging/alerting on.
        recoveredFallback: bool,
        /// True when a commit-point flush failed and the instance refuses
        /// writes until reopen. Strictly more alarming than recoveredFallback.
        poisoned: bool,
    };

    /// Collect the current Metrics snapshot. O(free extents) to total the
    /// reclaimable bytes, plus the per-slot liveness syscalls of the horizon
    /// scan.
    pub fn metrics(self: *Database) Metrics {
        var reclaimable: u64 = 0;
        for (self.freeList.extents.items) |extent| reclaimable += extent.len;
        return .{
            .mappedLen = @intCast(self.store.sectionsView().len * platform.sectionSize),
            .latestVersion = self.activeVersion,
            .oldestPinnedVersion = self.horizon(),
            .freeExtentCount = self.freeList.extents.items.len,
            .reclaimableBytes = reclaimable,
            .flEncodeNs = self.flEncodeNs,
            .flExtentsEncoded = self.flExtentsEncoded,
            .commitCount = self.commitCount,
            .flRebuildNs = self.flRebuildNs,
            .flCloneNs = self.flCloneNs,
            .setlengthNs = self.store.setlengthNs,
            .setlengthCalls = self.store.setlengthCalls,
            .recoveredFallback = self.recoveredFallback,
            .poisoned = self.poisoned,
        };
    }
};

// ---------------------------------------------------------------------------
// Transaction types (defined in their own modules; re-exported here so existing
// call sites that do @import("database.zig").ReadTransaction / .WriteTransaction keep working).
// ---------------------------------------------------------------------------

/// A pinned read snapshot (defined in transactions/readTransaction.zig).
pub const ReadTransaction = @import("transactions/readTransaction.zig").ReadTransaction;
/// The single in-flight mutation (defined in transactions/writeTransaction.zig).
pub const WriteTransaction = @import("transactions/writeTransaction.zig").WriteTransaction;

test {
    _ = @import("databaseTests.zig");
}
