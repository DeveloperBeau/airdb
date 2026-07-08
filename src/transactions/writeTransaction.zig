//! WriteTransaction and the two-slot atomic durable commit.
//!
//! Slot A byte range in the header page: [64, 64+Slot.size).
//! Slot B byte range in the header page: [128, 128+Slot.size).

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocation = @import("../storage/arena.zig").Allocation;
const Reference = @import("../storage/reference.zig").Reference;
const Slot = @import("../storage/slots.zig").Slot;
const FreeExtent = @import("../storage/freeList.zig").FreeExtent;
const FreeList = @import("../storage/freeList.zig").FreeList;
const Database = @import("../database.zig").Database;
const ringHeadOff = @import("../database.zig").ringHeadOff;
const ringOff = @import("../database.zig").ringOff;
const ringCapacity = @import("../database.zig").ringCapacity;

const slotAOff: usize = 64;
const slotBOff: usize = 128;

/// The single in-flight mutation over a Database (one writer at a time,
/// serialized by the cross-process lock): accumulates a new root and version,
/// the pending frees, and a transaction-private reuse pool, then concludes
/// with commit() or deinit() (abort).
pub const WriteTransaction = struct {
    database: *Database,
    newRoot: Reference,
    newVersion: u64,
    inFlightFrees: std.ArrayList(FreeExtent),
    workFreelist: FreeList,
    /// Nodes allocated AND freed within this uncommitted transaction. They are private
    /// (no committed version or reader references them), so they are reused immediately
    /// within the same transaction instead of accumulating as copy-on-write garbage.
    transactionReuse: FreeList,
    /// arena.top at transaction start. A freed reference >= this was bump-allocated during this
    /// transaction and is transaction-private; a reference below it belongs to a committed version.
    transactionStartTop: u64,
    /// Pin/liveness part of the reclaim horizon, computed lazily on the first
    /// pool allocation and reused for the rest of the transaction. Computing
    /// it per allocation costs syscalls (pid liveness + incarnation checks per
    /// participant slot) on the hottest path in the engine. Caching THIS part
    /// is safe: every reusable extent has freedVersion <= activeVersion, a
    /// latest reader pins >= the version it observed published (and beginRead
    /// re-validates after publishing its pin), and point-in-time readers are
    /// admitted only inside the shared retention window. The retention window
    /// itself is deliberately NOT cached -- see reclaimHorizon.
    cachedHorizon: ?u64 = null,
    /// Set once the transaction has been concluded (committed, commit-failed,
    /// or aborted). Makes deinit a no-op afterwards, so callers may hold an
    /// `errdefer w.deinit()` across `commit()` without double-freeing the
    /// bookkeeping lists or double-unlocking the cross-process write lock.
    done: bool = false,

    /// Read `length` bytes at `reference` as a zero-copy slice into mapped storage.
    /// Sections never move, so the slice stays addressable; its contents are
    /// stable only until this transaction frees the node (a private free is
    /// routed to the immediate-reuse pool and may be scribbled by the next
    /// allocation).
    pub fn dereference(self: *WriteTransaction, reference: Reference, length: usize) ![]const u8 {
        return self.database.arena.dereference(reference, length);
    }

    fn reclaimHorizon(self: *WriteTransaction) u64 {
        const horizon = self.cachedHorizon orelse blk: {
            // Horizon-gated reuse is only safe when no reader in ANY live
            // process pins a version below the extent's freeing version.
            // globalHorizon = min of live processes' min-pinned versions,
            // clamped to this writer's activeVersion. Without a participant
            // slot this process cannot advertise its readers, so it stays
            // bump-only (Database.open/create refuse slotless attaches, so this is
            // pure defense).
            const globalHorizon: u64 = if (self.database.participantSlot == null) 0 else self.database.coordination.globalHorizon(self.database.activeVersion);
            self.cachedHorizon = globalHorizon;
            break :blk globalHorizon;
        };
        // Clamp by the retention window ON EVERY ALLOCATION (a single atomic
        // load from the shared header page). Another process may raise the
        // floor mid-transaction and immediately admit a point-in-time reader
        // under it; a cached window would let this writer keep reusing space
        // that reader's snapshot references.
        return @min(horizon, self.database.activeVersion -| self.database.retainVersions());
    }

    /// Allocate `size` bytes for a new node: transaction-private reuse first,
    /// then horizon-gated reuse of committed-free space, then a bump
    /// allocation that may grow (and remap) the file. Amortized O(1); can
    /// issue file-growth I/O and, once per transaction, the horizon's
    /// per-slot liveness syscalls.
    pub fn alloc(self: *WriteTransaction, size: usize) !Allocation {
        // 1. Reuse a transaction-private node first (allocated and freed within this same
        //    uncommitted transaction; no committed version or reader can reference it, so
        //    reusing it is always safe and keeps single-transaction bulk writes space-bounded).
        //    Exact-size match: no carving, so fixed-size node churn never fragments the pool.
        if (self.database.arena.allocFromPool(&self.transactionReuse, size, std.math.maxInt(u64))) |allocation| return allocation;
        // 2. Reuse a committed-free node, gated by the per-transaction reclaim horizon.
        if (self.database.arena.allocFromPool(&self.workFreelist, size, self.reclaimHorizon())) |allocation| return allocation;
        // 3. Bump-allocate, growing the file if the arena is full.
        return self.database.bumpGrowing(size);
    }

    /// Record `reference` as the root commit() will publish.
    pub fn setRoot(self: *WriteTransaction, reference: Reference) void {
        self.newRoot = reference;
    }

    /// Mark the node at `reference` reclaimable. A node this transaction allocated
    /// returns to the private immediate-reuse pool; a committed node's extent
    /// is deferred to the committed free list, tagged with this version, so
    /// pinned readers keep their snapshot intact.
    pub fn free(self: *WriteTransaction, reference: Reference, length: usize) !void {
        if (reference >= self.transactionStartTop) {
            // Allocated within this uncommitted transaction: private, immediately reusable.
            // (freedVersion is irrelevant for the transaction-private pool; allocFromPool ignores it.)
            try self.transactionReuse.add(.{ .offset = reference, .len = @intCast(length), .freedVersion = 0 });
        } else {
            // Belongs to a committed version a reader may still pin: defer reclamation to the
            // committed free list, tagged with this transaction's version (the freeing version).
            try self.inFlightFrees.append(self.database.store.allocator, .{
                .offset = reference,
                .len = @intCast(length),
                .freedVersion = self.newVersion,
            });
        }
    }

    /// Copy-on-write step: allocate a fresh node, copy `length` bytes from
    /// `reference` into it, free the original, and return the writable copy.
    pub fn writableCopy(self: *WriteTransaction, reference: Reference, length: usize) !Allocation {
        const old = try self.database.arena.dereference(reference, length);
        const fresh = try self.alloc(length);
        @memcpy(fresh.bytes, old);
        try self.free(reference, length);
        return fresh;
    }

    /// Abort the transaction if it has not already concluded: roll the bump
    /// pointer back, drop the bookkeeping lists, and release the
    /// cross-process write lock. A no-op after commit(), a commit failure, or
    /// a prior deinit(), so it is safe to hold in an errdefer across commit().
    pub fn deinit(self: *WriteTransaction) void {
        if (self.done) return; // already committed, commit-failed, or aborted
        self.conclude();
    }

    // Shared conclusion for abort, commit failure, and (minus the rollback)
    // the moment before a successful commit publishes. Rolls the bump pointer
    // back: no committed version references any reference >= transactionStartTop (they
    // were allocated by this uncommitted transaction only), so the rollback is
    // safe and prevents aborted/failed bytes from being folded into the next
    // commit's logicalSize as permanently unreclaimable garbage. Extents this
    // transaction reused from the committed pool stay recorded in database.freeList
    // (untouched during the transaction), so they remain free as before.
    fn conclude(self: *WriteTransaction) void {
        self.done = true;
        self.database.arena.top = @intCast(self.transactionStartTop);
        self.inFlightFrees.deinit(self.database.store.allocator);
        self.workFreelist.deinit();
        self.transactionReuse.deinit();
        self.database.coordination.unlock();
    }

    /// Two-slot atomic durable commit.
    ///
    /// Protocol:
    ///   1. Build the new persistent free list and encode it onto the mmap.
    ///   2. Encode the new slot (including freeListReference) into the INACTIVE slot.
    ///   3. Flush -- ensures new data, free-list node, and slot descriptor are durable.
    ///      If this flush fails, return error.Durability immediately;
    ///      the old active slot is untouched and the old version remains live.
    ///   4. Flip header.activeSlot to the newly-written slot; persistHeader().
    ///   5. Flush -- this is the commit point.
    ///      If this flush fails, revert ALL in-memory header changes
    ///      (activeSlot and logicalSize) and return error.Durability.
    ///      The old active slot on disk is still valid, so crash recovery
    ///      will see the old version.
    ///   6. Only after both flushes succeed: install new free list, update
    ///      activeVersion / activeRoot.
    ///
    /// newFl ownership: errdefer newFl.deinit() is registered immediately after
    /// FreeList.init so all error returns (try-errors AND the two explicit
    /// error.Durability returns) clean up newFl. The errdefer does not fire on
    /// the success return (return self.newVersion) since that is not an error,
    /// so transferring ownership to database.freeList before returning is safe and
    /// cannot double-free.
    pub fn commit(self: *WriteTransaction) !u64 {
        // EVERY error exit -- allocation failure, disk-full growth, and both
        // durability-barrier failures -- concludes the transaction uniformly:
        // lists freed, uncommitted bump bytes rolled back, write lock
        // released, and `done` set so a caller's deferred deinit is a no-op.
        errdefer self.conclude();
        const database = self.database;
        const prevActiveSlot = database.store.header.activeSlot;
        const prevLogicalSize = database.store.header.logicalSize;

        // Protocol steps 1-2: build + encode the new persistent free list,
        // then write the new slot descriptor and ring entry. The errdefer
        // fires on any error return (including the two explicit
        // error.Durability returns below). It does NOT fire on the success
        // return, so ownership transfer to database.freeList at the end of the
        // success path is safe and double-free-free.
        var newFl = try self.buildNewFreeList();
        errdefer newFl.deinit();
        const chain = try self.encodeFreeListChain(&newFl);
        const inactiveSlotIndex = self.writeSlotAndRing(prevActiveSlot, chain.headReference);

        // Step 3: flush new data + inactive slot to durable storage.
        // Failure here: old active slot is still valid; no in-memory state
        // changed. Cleanup (including the unlock) is the errdefer's job.
        database.store.syncer.flush(database.store.file) catch return error.Durability;

        // Steps 4-5: flip the header commit pointer and flush (commit point).
        try self.flipCommitPointer(inactiveSlotIndex, prevActiveSlot, prevLogicalSize);

        // Step 6: publish the new version in memory only after both flushes succeed.
        database.activeVersion = self.newVersion;
        database.activeRoot = self.newRoot;
        database.coordination.setLatestVersion(self.newVersion);
        // Install the new free list. errdefer for newFl will NOT fire here
        // because we are on the success return path (return self.newVersion below).
        database.freeList.deinit();
        database.freeList = newFl; // ownership transferred; do not call newFl.deinit()
        database.freeListNodeReference = chain.headReference;
        database.freeListNodeLen = chain.headLen;
        self.done = true; // a later deinit must not roll back the committed state
        self.inFlightFrees.deinit(self.database.store.allocator);
        self.workFreelist.deinit();
        self.transactionReuse.deinit();
        self.database.coordination.unlock();
        return self.newVersion;
    }

    /// Commit phase: build the new persistent free list from what this
    /// transaction left reusable -- the surviving workFreelist extents, the
    /// in-flight frees (tagged with newVersion; not yet reusable), the OLD
    /// free-list chain's own chunks, and any leftover transaction-private
    /// nodes. The caller owns the returned list (register errdefer deinit
    /// immediately). O(extent count).
    fn buildNewFreeList(self: *WriteTransaction) !FreeList {
        const database = self.database;
        var newFl = FreeList.init(database.store.allocator);
        errdefer newFl.deinit();

        // Measurement only: time the O(extent count) rebuild of the new persistent
        // free list from workFreelist + inFlightFrees (+ reclaimed nodes). No
        // behavior change; counter lives on the Database.
        const rebuildIo = std.Io.Threaded.global_single_threaded.io();
        const rebuildStart = Io.Clock.now(.awake, rebuildIo).nanoseconds;
        // 1. Copy extents that workFreelist still holds (i.e. not reused this transaction).
        for (self.workFreelist.extents.items) |extent| {
            try newFl.add(extent);
        }
        // 2. Append in-flight frees (tagged with newVersion; not yet reusable).
        for (self.inFlightFrees.items) |extent| {
            try newFl.add(extent);
        }
        // 3. Reclaim the OLD free-list chain so its space re-enters the free
        //    pool. Every chunk is walked: reclaiming only the head would leak
        //    the tail chunks on each commit.
        {
            var catalogReference = database.freeListNodeReference;
            var hops: usize = 0;
            while (catalogReference != 0) : (hops += 1) {
                if (hops >= FreeList.maxChunks) return error.Corrupt;
                const header = try self.dereference(catalogReference, FreeList.chunkHeaderBytes);
                const extentCount = std.mem.readInt(u32, header[0..4], .little);
                const next = std.mem.readInt(u64, header[4..12], .little);
                // Legitimate chains strictly decrease (written back-to-front);
                // anything else is corruption and must not feed the free list.
                if (next != 0 and next >= catalogReference) return error.Corrupt;
                try newFl.add(.{
                    .offset = catalogReference,
                    .len = @intCast(FreeList.chunkByteLength(extentCount)),
                    .freedVersion = self.newVersion,
                });
                catalogReference = next;
            }
        }
        // 3b. Reclaim any leftover transaction-private nodes that were freed but not reused
        //     within this transaction. They are committed-but-unreferenced space; tag them
        //     with this version so the committed free list can reclaim them (no leak).
        for (self.transactionReuse.extents.items) |extent| {
            try newFl.add(.{ .offset = extent.offset, .len = extent.len, .freedVersion = self.newVersion });
        }
        database.flRebuildNs += @intCast(Io.Clock.now(.awake, rebuildIo).nanoseconds - rebuildStart);
        return newFl;
    }

    /// The on-disk location of an encoded free-list chain: the head chunk's
    /// reference and byte length (0/0 for an empty chain of zero chunks -- never
    /// produced, a single empty chunk is always written).
    const FreeListChain = struct { headReference: u64, headLen: usize };

    /// Commit phase: encode the new free list onto the arena via BUMP
    /// allocations (never reuse, to avoid recursion: the chunks must not
    /// reference themselves), growing the file if the arena is full. The list
    /// is persisted as a chain of bounded chunks -- a single node's size grows
    /// with the extent count, and past the section cap its allocation failed
    /// the commit outright with error.AllocTooLarge. Chunks are written
    /// back-to-front so each knows its successor. O(extent count) plus I/O.
    fn encodeFreeListChain(self: *WriteTransaction, newFl: *const FreeList) !FreeListChain {
        const database = self.database;
        const encIo = std.Io.Threaded.global_single_threaded.io();
        const encStart = Io.Clock.now(.awake, encIo).nanoseconds;
        const items = newFl.extents.items;
        const chunkCount = @max(1, (items.len + FreeList.chunkExtentCap - 1) / FreeList.chunkExtentCap);
        var headReference: u64 = 0;
        var headLen: usize = 0;
        {
            var chunkIndex = chunkCount;
            while (chunkIndex > 0) {
                chunkIndex -= 1;
                const chunkStart = chunkIndex * FreeList.chunkExtentCap;
                const chunkEnd = @min(chunkStart + FreeList.chunkExtentCap, items.len);
                const chunkLen = FreeList.chunkByteLength(chunkEnd - chunkStart);
                const node = try database.bumpGrowing(chunkLen);
                const written = FreeList.encodeChunk(items[chunkStart..chunkEnd], headReference, node.bytes);
                std.debug.assert(written == chunkLen);
                headReference = node.reference;
                headLen = chunkLen;
            }
        }
        database.flEncodeNs += @intCast(Io.Clock.now(.awake, encIo).nanoseconds - encStart);
        database.flExtentsEncoded += items.len;
        database.commitCount += 1;
        return .{ .headReference = headReference, .headLen = headLen };
    }

    /// Commit phase (protocol step 2): write the new slot descriptor into
    /// the INACTIVE slot region and record (newVersion, newRoot) in the
    /// version->root ring. Mapped-memory writes only -- nothing is durable
    /// until the step-3 flush. Returns the inactive slot index for the
    /// commit-point flip.
    fn writeSlotAndRing(self: *WriteTransaction, prevActiveSlot: u8, freeListHeadReference: u64) u8 {
        const database = self.database;

        // Determine the inactive slot and its byte offset.
        const inactiveSlotIndex: u8 = if (prevActiveSlot == 0) 1 else 0;
        const inactiveOff: usize = if (inactiveSlotIndex == 0) slotAOff else slotBOff;

        // Write the new slot descriptor into the inactive region.
        // logicalSize is captured AFTER the node alloc so it covers the node bytes.
        const newSlot = Slot{
            .version = self.newVersion,
            .rootReference = self.newRoot,
            .freeListReference = freeListHeadReference,
            .logicalSize = @intCast(database.arena.top),
        };
        newSlot.encode(database.store.map[inactiveOff..][0..Slot.size]);

        // Record (newVersion, newRoot) in the version->root ring, in the header page.
        // This lives in section 0 and is made durable by the Step 3 + Step 4 flushes, so
        // it is part of the same fsync barrier as the new slot. On a revert/failure path
        // the entry is harmless: its version was never published (activeSlot not flipped),
        // so versionRoot's `version > activeVersion` guard ignores it. The ring is bounded
        // and self-overwriting, so we never revert it.
        const head = std.mem.readInt(u64, database.store.map[ringHeadOff..][0..8], .little);
        const ringIndex: usize = @intCast(head % ringCapacity);
        const entryOffset = ringOff + ringIndex * 16;
        std.mem.writeInt(u64, database.store.map[entryOffset..][0..8], self.newVersion, .little);
        std.mem.writeInt(u64, database.store.map[entryOffset + 8 ..][0..8], self.newRoot, .little);
        std.mem.writeInt(u64, database.store.map[ringHeadOff..][0..8], head + 1, .little);

        return inactiveSlotIndex;
    }

    /// Commit phase (protocol steps 4-5): flip header.activeSlot to the
    /// newly-written slot and flush -- the commit point. On a failed flush,
    /// revert every in-memory header change so the old version stays live,
    /// poison the instance (the commit's on-disk fate is indeterminate), and
    /// return error.Durability.
    fn flipCommitPointer(self: *WriteTransaction, inactiveSlotIndex: u8, prevActiveSlot: u8, prevLogicalSize: u64) !void {
        const database = self.database;
        database.store.header.activeSlot = inactiveSlotIndex;
        database.store.header.logicalSize = @intCast(database.arena.top);
        database.store.persistHeader();
        database.store.syncer.flush(database.store.file) catch {
            // Revert every in-memory header change so the old version stays live.
            database.store.header.activeSlot = prevActiveSlot;
            database.store.header.logicalSize = prevLogicalSize;
            // Restore the mmap bytes to match the reverted header so a future
            // open reads the right value. Cleanup (unlock etc.) is the
            // errdefer's job. The flipped pointer was in the mapped page before
            // the failed barrier, so async writeback may have persisted it
            // anyway: this commit's on-disk fate is INDETERMINATE. Poison the
            // instance -- further writes could scribble the maybe-published
            // version's nodes; a reopen resolves which side won.
            database.store.persistHeader();
            database.poisoned = true;
            return error.Durability;
        };
    }
};

test {
    _ = @import("writeTransactionTests.zig");
}
