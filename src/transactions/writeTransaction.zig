// writeTransaction.zig -- WriteTransaction and the two-slot atomic durable commit.
//
// Slot A byte range in the header page: [64, 64+Slot.size).
// Slot B byte range in the header page: [128, 128+Slot.size).

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocation = @import("../storage/arena.zig").Allocation;
const Reference = @import("../storage/reference.zig").Reference;
const Slot = @import("../storage/slots.zig").Slot;
const FreeExtent = @import("../storage/freeList.zig").FreeExtent;
const FreeList = @import("../storage/freeList.zig").FreeList;
const Database = @import("../database.zig").Database;
const ring_head_off = @import("../database.zig").ring_head_off;
const ring_off = @import("../database.zig").ring_off;
const ring_capacity = @import("../database.zig").ring_capacity;

const slot_a_off: usize = 64;
const slot_b_off: usize = 128;

pub const WriteTransaction = struct {
    database: *Database,
    new_root: Reference,
    new_version: u64,
    in_flight_frees: std.ArrayList(FreeExtent),
    work_freelist: FreeList,
    /// Nodes allocated AND freed within this uncommitted transaction. They are private
    /// (no committed version or reader references them), so they are reused immediately
    /// within the same transaction instead of accumulating as copy-on-write garbage.
    transactionReuse: FreeList,
    /// arena.top at transaction start. A freed ref >= this was bump-allocated during this
    /// transaction and is transaction-private; a ref below it belongs to a committed version.
    transactionStartTop: u64,
    /// Pin/liveness part of the reclaim horizon, computed lazily on the first
    /// pool allocation and reused for the rest of the transaction. Computing
    /// it per allocation costs syscalls (pid liveness + incarnation checks per
    /// participant slot) on the hottest path in the engine. Caching THIS part
    /// is safe: every reusable extent has freed_version <= active_version, a
    /// latest reader pins >= the version it observed published (and beginRead
    /// re-validates after publishing its pin), and point-in-time readers are
    /// admitted only inside the shared retention window. The retention window
    /// itself is deliberately NOT cached -- see reclaimHorizon.
    cached_horizon: ?u64 = null,
    /// Set once the transaction has been concluded (committed, commit-failed,
    /// or aborted). Makes deinit a no-op afterwards, so callers may hold an
    /// `errdefer w.deinit()` across `commit()` without double-freeing the
    /// bookkeeping lists or double-unlocking the cross-process write lock.
    done: bool = false,

    pub fn deref(self: *WriteTransaction, ref: Reference, length: usize) ![]const u8 {
        return self.database.arena.deref(ref, length);
    }

    fn reclaimHorizon(self: *WriteTransaction) u64 {
        const horizon = self.cached_horizon orelse blk: {
            // Horizon-gated reuse is only safe when no reader in ANY live
            // process pins a version below the extent's freeing version.
            // globalHorizon = min of live processes' min-pinned versions,
            // clamped to this writer's active_version. Without a participant
            // slot this process cannot advertise its readers, so it stays
            // bump-only (Database.open/create refuse slotless attaches, so this is
            // pure defense).
            const globalHorizon: u64 = if (self.database.participant_slot == null) 0 else self.database.coord.globalHorizon(self.database.active_version);
            self.cached_horizon = globalHorizon;
            break :blk globalHorizon;
        };
        // Clamp by the retention window ON EVERY ALLOCATION (a single atomic
        // load from the shared header page). Another process may raise the
        // floor mid-transaction and immediately admit a point-in-time reader
        // under it; a cached window would let this writer keep reusing space
        // that reader's snapshot references.
        return @min(horizon, self.database.active_version -| self.database.retainVersions());
    }

    pub fn alloc(self: *WriteTransaction, size: usize) !Allocation {
        // 1. Reuse a transaction-private node first (allocated and freed within this same
        //    uncommitted transaction; no committed version or reader can reference it, so
        //    reusing it is always safe and keeps single-transaction bulk writes space-bounded).
        //    Exact-size match: no carving, so fixed-size node churn never fragments the pool.
        if (self.database.arena.allocFromPool(&self.transactionReuse, size, std.math.maxInt(u64))) |allocation| return allocation;
        // 2. Reuse a committed-free node, gated by the per-transaction reclaim horizon.
        if (self.database.arena.allocFromPool(&self.work_freelist, size, self.reclaimHorizon())) |allocation| return allocation;
        // 3. Bump-allocate, growing the file if the arena is full.
        return self.database.bumpGrowing(size);
    }

    pub fn setRoot(self: *WriteTransaction, ref: Reference) void {
        self.new_root = ref;
    }

    pub fn free(self: *WriteTransaction, ref: Reference, length: usize) !void {
        if (ref >= self.transactionStartTop) {
            // Allocated within this uncommitted transaction: private, immediately reusable.
            // (freed_version is irrelevant for the transaction-private pool; allocFromPool ignores it.)
            try self.transactionReuse.add(.{ .offset = ref, .len = @intCast(length), .freed_version = 0 });
        } else {
            // Belongs to a committed version a reader may still pin: defer reclamation to the
            // committed free list, tagged with this transaction's version (the freeing version).
            try self.in_flight_frees.append(self.database.store.allocator, .{
                .offset = ref,
                .len = @intCast(length),
                .freed_version = self.new_version,
            });
        }
    }

    pub fn writableCopy(self: *WriteTransaction, ref: Reference, length: usize) !Allocation {
        const old = try self.database.arena.deref(ref, length);
        const fresh = try self.alloc(length);
        @memcpy(fresh.bytes, old);
        try self.free(ref, length);
        return fresh;
    }

    pub fn deinit(self: *WriteTransaction) void {
        if (self.done) return; // already committed, commit-failed, or aborted
        self.conclude();
    }

    // Shared conclusion for abort, commit failure, and (minus the rollback)
    // the moment before a successful commit publishes. Rolls the bump pointer
    // back: no committed version references any ref >= transactionStartTop (they
    // were allocated by this uncommitted transaction only), so the rollback is
    // safe and prevents aborted/failed bytes from being folded into the next
    // commit's logical_size as permanently unreclaimable garbage. Extents this
    // transaction reused from the committed pool stay recorded in database.free_list
    // (untouched during the transaction), so they remain free as before.
    fn conclude(self: *WriteTransaction) void {
        self.done = true;
        self.database.arena.top = @intCast(self.transactionStartTop);
        self.in_flight_frees.deinit(self.database.store.allocator);
        self.work_freelist.deinit();
        self.transactionReuse.deinit();
        self.database.coord.unlock();
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
    /// so transferring ownership to database.free_list before returning is safe and
    /// cannot double-free.
    pub fn commit(self: *WriteTransaction) !u64 {
        // EVERY error exit -- allocation failure, disk-full growth, and both
        // durability-barrier failures -- concludes the transaction uniformly:
        // lists freed, uncommitted bump bytes rolled back, write lock
        // released, and `done` set so a caller's deferred deinit is a no-op.
        errdefer self.conclude();
        const database = self.database;
        const prev_active_slot = database.store.header.active_slot;
        const prev_logical_size = database.store.header.logical_size;

        // Protocol steps 1-2: build + encode the new persistent free list,
        // then write the new slot descriptor and ring entry. The errdefer
        // fires on any error return (including the two explicit
        // error.Durability returns below). It does NOT fire on the success
        // return, so ownership transfer to database.free_list at the end of the
        // success path is safe and double-free-free.
        var new_fl = try self.buildNewFreeList();
        errdefer new_fl.deinit();
        const chain = try self.encodeFreeListChain(&new_fl);
        const inactiveSlotIndex = self.writeSlotAndRing(prev_active_slot, chain.head_ref);

        // Step 3: flush new data + inactive slot to durable storage.
        // Failure here: old active slot is still valid; no in-memory state
        // changed. Cleanup (including the unlock) is the errdefer's job.
        database.store.syncer.flush(database.store.file) catch return error.Durability;

        // Steps 4-5: flip the header commit pointer and flush (commit point).
        try self.flipCommitPointer(inactiveSlotIndex, prev_active_slot, prev_logical_size);

        // Step 6: publish the new version in memory only after both flushes succeed.
        database.active_version = self.new_version;
        database.active_root = self.new_root;
        database.coord.setLatestVersion(self.new_version);
        // Install the new free list. errdefer for new_fl will NOT fire here
        // because we are on the success return path (return self.new_version below).
        database.free_list.deinit();
        database.free_list = new_fl; // ownership transferred; do not call new_fl.deinit()
        database.free_list_node_ref = chain.head_ref;
        database.free_list_node_len = chain.head_len;
        self.done = true; // a later deinit must not roll back the committed state
        self.in_flight_frees.deinit(self.database.store.allocator);
        self.work_freelist.deinit();
        self.transactionReuse.deinit();
        self.database.coord.unlock();
        return self.new_version;
    }

    /// Commit phase: build the new persistent free list from what this
    /// transaction left reusable -- the surviving work_freelist extents, the
    /// in-flight frees (tagged with new_version; not yet reusable), the OLD
    /// free-list chain's own chunks, and any leftover transaction-private
    /// nodes. The caller owns the returned list (register errdefer deinit
    /// immediately). O(extent count).
    fn buildNewFreeList(self: *WriteTransaction) !FreeList {
        const database = self.database;
        var new_fl = FreeList.init(database.store.allocator);
        errdefer new_fl.deinit();

        // Measurement only: time the O(extent count) rebuild of the new persistent
        // free list from work_freelist + in_flight_frees (+ reclaimed nodes). No
        // behavior change; counter lives on the Database.
        const rebuild_io = std.Io.Threaded.global_single_threaded.io();
        const rebuild_start = Io.Clock.now(.awake, rebuild_io).nanoseconds;
        // 1. Copy extents that work_freelist still holds (i.e. not reused this transaction).
        for (self.work_freelist.extents.items) |extent| {
            try new_fl.add(extent);
        }
        // 2. Append in-flight frees (tagged with new_version; not yet reusable).
        for (self.in_flight_frees.items) |extent| {
            try new_fl.add(extent);
        }
        // 3. Reclaim the OLD free-list chain so its space re-enters the free
        //    pool. Every chunk is walked: reclaiming only the head would leak
        //    the tail chunks on each commit.
        {
            var cref = database.free_list_node_ref;
            var hops: usize = 0;
            while (cref != 0) : (hops += 1) {
                if (hops >= FreeList.max_chunks) return error.Corrupt;
                const header = try self.deref(cref, FreeList.chunk_header_bytes);
                const extentCount = std.mem.readInt(u32, header[0..4], .little);
                const next = std.mem.readInt(u64, header[4..12], .little);
                // Legitimate chains strictly decrease (written back-to-front);
                // anything else is corruption and must not feed the free list.
                if (next != 0 and next >= cref) return error.Corrupt;
                try new_fl.add(.{
                    .offset = cref,
                    .len = @intCast(FreeList.chunkByteLen(extentCount)),
                    .freed_version = self.new_version,
                });
                cref = next;
            }
        }
        // 3b. Reclaim any leftover transaction-private nodes that were freed but not reused
        //     within this transaction. They are committed-but-unreferenced space; tag them
        //     with this version so the committed free list can reclaim them (no leak).
        for (self.transactionReuse.extents.items) |extent| {
            try new_fl.add(.{ .offset = extent.offset, .len = extent.len, .freed_version = self.new_version });
        }
        database.fl_rebuild_ns += @intCast(Io.Clock.now(.awake, rebuild_io).nanoseconds - rebuild_start);
        return new_fl;
    }

    /// The on-disk location of an encoded free-list chain: the head chunk's
    /// ref and byte length (0/0 for an empty chain of zero chunks -- never
    /// produced, a single empty chunk is always written).
    const FreeListChain = struct { head_ref: u64, head_len: usize };

    /// Commit phase: encode the new free list onto the arena via BUMP
    /// allocations (never reuse, to avoid recursion: the chunks must not
    /// reference themselves), growing the file if the arena is full. The list
    /// is persisted as a chain of bounded chunks -- a single node's size grows
    /// with the extent count, and past the section cap its allocation failed
    /// the commit outright with error.AllocTooLarge. Chunks are written
    /// back-to-front so each knows its successor. O(extent count) plus I/O.
    fn encodeFreeListChain(self: *WriteTransaction, new_fl: *const FreeList) !FreeListChain {
        const database = self.database;
        const enc_io = std.Io.Threaded.global_single_threaded.io();
        const enc_start = Io.Clock.now(.awake, enc_io).nanoseconds;
        const items = new_fl.extents.items;
        const chunkCount = @max(1, (items.len + FreeList.chunk_extent_cap - 1) / FreeList.chunk_extent_cap);
        var head_ref: u64 = 0;
        var head_len: usize = 0;
        {
            var chunkIndex = chunkCount;
            while (chunkIndex > 0) {
                chunkIndex -= 1;
                const chunkStart = chunkIndex * FreeList.chunk_extent_cap;
                const chunkEnd = @min(chunkStart + FreeList.chunk_extent_cap, items.len);
                const chunk_len = FreeList.chunkByteLen(chunkEnd - chunkStart);
                const node = try database.bumpGrowing(chunk_len);
                const written = FreeList.encodeChunk(items[chunkStart..chunkEnd], head_ref, node.bytes);
                std.debug.assert(written == chunk_len);
                head_ref = node.ref;
                head_len = chunk_len;
            }
        }
        database.fl_encode_ns += @intCast(Io.Clock.now(.awake, enc_io).nanoseconds - enc_start);
        database.fl_extents_encoded += items.len;
        database.commit_count += 1;
        return .{ .head_ref = head_ref, .head_len = head_len };
    }

    /// Commit phase (protocol step 2): write the new slot descriptor into
    /// the INACTIVE slot region and record (new_version, new_root) in the
    /// version->root ring. Mapped-memory writes only -- nothing is durable
    /// until the step-3 flush. Returns the inactive slot index for the
    /// commit-point flip.
    fn writeSlotAndRing(self: *WriteTransaction, prev_active_slot: u8, free_list_head_ref: u64) u8 {
        const database = self.database;

        // Determine the inactive slot and its byte offset.
        const inactiveSlotIndex: u8 = if (prev_active_slot == 0) 1 else 0;
        const inactive_off: usize = if (inactiveSlotIndex == 0) slot_a_off else slot_b_off;

        // Write the new slot descriptor into the inactive region.
        // logical_size is captured AFTER the node alloc so it covers the node bytes.
        const new_slot = Slot{
            .version = self.new_version,
            .root_ref = self.new_root,
            .free_list_ref = free_list_head_ref,
            .logical_size = @intCast(database.arena.top),
        };
        new_slot.encode(database.store.map[inactive_off..][0..Slot.size]);

        // Record (new_version, new_root) in the version->root ring, in the header page.
        // This lives in section 0 and is made durable by the Step 3 + Step 4 flushes, so
        // it is part of the same fsync barrier as the new slot. On a revert/failure path
        // the entry is harmless: its version was never published (active_slot not flipped),
        // so versionRoot's `version > active_version` guard ignores it. The ring is bounded
        // and self-overwriting, so we never revert it.
        const head = std.mem.readInt(u64, database.store.map[ring_head_off..][0..8], .little);
        const ringIndex: usize = @intCast(head % ring_capacity);
        const entryOffset = ring_off + ringIndex * 16;
        std.mem.writeInt(u64, database.store.map[entryOffset..][0..8], self.new_version, .little);
        std.mem.writeInt(u64, database.store.map[entryOffset + 8 ..][0..8], self.new_root, .little);
        std.mem.writeInt(u64, database.store.map[ring_head_off..][0..8], head + 1, .little);

        return inactiveSlotIndex;
    }

    /// Commit phase (protocol steps 4-5): flip header.active_slot to the
    /// newly-written slot and flush -- the commit point. On a failed flush,
    /// revert every in-memory header change so the old version stays live,
    /// poison the instance (the commit's on-disk fate is indeterminate), and
    /// return error.Durability.
    fn flipCommitPointer(self: *WriteTransaction, inactiveSlotIndex: u8, prev_active_slot: u8, prev_logical_size: u64) !void {
        const database = self.database;
        database.store.header.active_slot = inactiveSlotIndex;
        database.store.header.logical_size = @intCast(database.arena.top);
        database.store.persistHeader();
        database.store.syncer.flush(database.store.file) catch {
            // Revert every in-memory header change so the old version stays live.
            database.store.header.active_slot = prev_active_slot;
            database.store.header.logical_size = prev_logical_size;
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
