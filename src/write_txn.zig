// write_txn.zig -- WriteTxn and the two-slot atomic durable commit.
//
// Slot A byte range in the header page: [64, 64+Slot.size).
// Slot B byte range in the header page: [128, 128+Slot.size).

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocation = @import("arena.zig").Allocation;
const Ref = @import("ref.zig").Ref;
const Slot = @import("slots.zig").Slot;
const FreeExtent = @import("freelist.zig").FreeExtent;
const FreeList = @import("freelist.zig").FreeList;
const Db = @import("db.zig").Db;
const ring_head_off = @import("db.zig").ring_head_off;
const ring_off = @import("db.zig").ring_off;
const ring_capacity = @import("db.zig").ring_capacity;

const slot_a_off: usize = 64;
const slot_b_off: usize = 128;

pub const WriteTxn = struct {
    db: *Db,
    new_root: Ref,
    new_version: u64,
    in_flight_frees: std.ArrayList(FreeExtent),
    work_freelist: FreeList,
    /// Nodes allocated AND freed within this uncommitted transaction. They are private
    /// (no committed version or reader references them), so they are reused immediately
    /// within the same transaction instead of accumulating as copy-on-write garbage.
    txn_reuse: FreeList,
    /// arena.top at transaction start. A freed ref >= this was bump-allocated during this
    /// transaction and is txn-private; a ref below it belongs to a committed version.
    txn_start_top: u64,

    pub fn deref(self: *WriteTxn, ref: Ref, len: usize) ![]const u8 {
        return self.db.arena.deref(ref, len);
    }

    pub fn alloc(self: *WriteTxn, size: usize) !Allocation {
        // 1. Reuse a transaction-private node first (allocated and freed within this same
        //    uncommitted transaction; no committed version or reader can reference it, so
        //    reusing it is always safe and keeps single-transaction bulk writes space-bounded).
        //    Exact-size match: no carving, so fixed-size node churn never fragments the pool.
        if (self.db.arena.allocFromPool(&self.txn_reuse, size, std.math.maxInt(u64))) |a| return a;
        // 2. Reuse a committed-free node, horizon-gated: only safe when no reader in ANY live
        //    process pins a version below its freeing-version. globalHorizon = min of live
        //    processes' min-pinned versions, clamped to this writer's active_version. Without a
        //    participant slot this process cannot advertise its readers, so it stays bump-only.
        const h: u64 = if (self.db.participant_slot == null) 0 else self.db.coord.globalHorizon(self.db.active_version);
        // Clamp by the retention window: withhold space freed within the most recent
        // `retain_versions` versions. With retain_versions == 0, eff == h (h is already
        // <= active_version), so behavior is unchanged.
        const eff = @min(h, self.db.active_version -| self.db.retain_versions);
        if (self.db.arena.allocFromPool(&self.work_freelist, size, eff)) |a| return a;
        // 3. Bump-allocate, growing the file if the arena is full.
        return self.db.bumpGrowing(size);
    }

    pub fn setRoot(self: *WriteTxn, ref: Ref) void {
        self.new_root = ref;
    }

    pub fn free(self: *WriteTxn, ref: Ref, len: usize) !void {
        if (ref >= self.txn_start_top) {
            // Allocated within this uncommitted transaction: private, immediately reusable.
            // (freed_version is irrelevant for the txn-private pool; allocFromPool ignores it.)
            try self.txn_reuse.add(.{ .offset = ref, .len = @intCast(len), .freed_version = 0 });
        } else {
            // Belongs to a committed version a reader may still pin: defer reclamation to the
            // committed free list, tagged with this transaction's version (the freeing version).
            try self.in_flight_frees.append(self.db.store.allocator, .{
                .offset = ref,
                .len = @intCast(len),
                .freed_version = self.new_version,
            });
        }
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
        self.txn_reuse.deinit();
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
        // Free in_flight_frees, work_freelist, and txn_reuse on every error path; explicit deinits cover success.
        errdefer self.in_flight_frees.deinit(self.db.store.allocator);
        errdefer self.work_freelist.deinit();
        errdefer self.txn_reuse.deinit();
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
        // 3b. Reclaim any leftover transaction-private nodes that were freed but not reused
        //     within this transaction. They are committed-but-unreferenced space; tag them
        //     with this version so the committed free list can reclaim them (no leak).
        for (self.txn_reuse.extents.items) |e| {
            try new_fl.add(.{ .offset = e.offset, .len = e.len, .freed_version = self.new_version });
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

        // Record (new_version, new_root) in the version->root ring, in the header page.
        // This lives in section 0 and is made durable by the Step 3 + Step 4 flushes, so
        // it is part of the same fsync barrier as the new slot. On a revert/failure path
        // the entry is harmless: its version was never published (active_slot not flipped),
        // so versionRoot's `version > active_version` guard ignores it. The ring is bounded
        // and self-overwriting, so we never revert it.
        const head = std.mem.readInt(u32, db.store.map[ring_head_off..][0..4], .little);
        const idx = head % ring_capacity;
        const e = ring_off + @as(usize, idx) * 16;
        std.mem.writeInt(u64, db.store.map[e..][0..8], self.new_version, .little);
        std.mem.writeInt(u64, db.store.map[e + 8 ..][0..8], self.new_root, .little);
        std.mem.writeInt(u32, db.store.map[ring_head_off..][0..4], head + 1, .little);

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
        self.txn_reuse.deinit();
        self.db.coord.unlock();
        return self.new_version;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const catalog = @import("catalog.zig");
const objects = @import("objects.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    return std.fs.path.join(allocator, &.{ dir_path, name });
}

// Churn a single-row int type across `n` commits: each iteration commits an insert
// then commits a delete, so every cycle frees committed nodes into the free pool.
// Returns the final logical size (arena high-water).
fn churnLogicalSize(path: []const u8, retain: u64, n: u64) !u64 {
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    db.setRetainVersions(retain);

    var cat: Ref = blk: {
        var w = try db.beginWrite();
        const c = try catalog.create(&w, 1);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        {
            var w = try db.beginWrite();
            cat = db.active_root; // reload the committed catalog ref
            const r = try objects.insert(&w, cat, &.{i});
            cat = r.cat;
            w.setRoot(cat);
            _ = try w.commit();
        }
        {
            var w = try db.beginWrite();
            cat = db.active_root;
            var out: [1]u64 = undefined;
            const ver = (try objects.getByPk(&w, cat, i, &out)).?;
            cat = switch (try objects.delete(&w, cat, i, ver)) {
                .ok => |c| c,
                else => unreachable,
            };
            w.setRoot(cat);
            _ = try w.commit();
        }
    }
    return db.logicalSize();
}

test "retention window withholds recently freed space from reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const p0 = try tmpFilePath(testing.allocator, &tmp, "retain0.airdb");
    defer testing.allocator.free(p0);
    const p1 = try tmpFilePath(testing.allocator, &tmp, "retainmax.airdb");
    defer testing.allocator.free(p1);

    const n: u64 = 200;
    const size0 = try churnLogicalSize(p0, 0, n); // reuse freed space
    const size1 = try churnLogicalSize(p1, 1_000_000, n); // retain everything -> no reuse

    // Retaining all recently-freed space prevents reuse, so the arena must grow
    // strictly larger than the reuse-enabled run.
    try testing.expect(size1 > size0);
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
    // The old node was allocated within this same uncommitted transaction, so freeing it
    // routes to the transaction-private reuse pool (immediately reusable), not in_flight_frees.
    try testing.expectEqual(@as(usize, 0), w.in_flight_frees.items.len);
    try testing.expectEqual(@as(usize, 1), w.txn_reuse.extents.items.len);
    try testing.expectEqual(a.ref, w.txn_reuse.extents.items[0].offset);
    w.deinit(); // releases the transaction-private pools without committing
}

test "a node freed within a transaction is reused by the next allocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "txnreuse.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(64);
    try w.free(a.ref, 64);
    const b = try w.alloc(64);
    // Reused the just-freed transaction-private node; no file growth, no committed garbage.
    try testing.expectEqual(a.ref, b.ref);
    w.deinit();
}

test "a committed node freed within a transaction is not reused mid-transaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "committedsafe.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    { // commit a node so it belongs to a committed version
        var w0 = try db.beginWrite();
        const a = try w0.alloc(64);
        w0.setRoot(a.ref);
        _ = try w0.commit();
    }
    const committed_ref = db.active_root;
    var w = try db.beginWrite();
    try w.free(committed_ref, 64); // committed node -> deferred reclaim, NOT txn-private
    const b = try w.alloc(64);
    // A committed node a reader might still pin must not be reused within this transaction.
    try testing.expect(b.ref != committed_ref);
    try testing.expectEqual(@as(usize, 0), w.txn_reuse.extents.items.len);
    try testing.expectEqual(@as(usize, 1), w.in_flight_frees.items.len);
    w.deinit();
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
