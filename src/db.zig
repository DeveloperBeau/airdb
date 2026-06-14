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

const slot_a_off: usize = 64;
const slot_b_off: usize = 128;

// ---------------------------------------------------------------------------
// Db
// ---------------------------------------------------------------------------

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

        return Db{
            .store = store,
            .arena = Arena.init(store.map, default_page_size),
            .active_version = 1,
            .active_root = 0,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = FreeList.init(allocator),
            .free_list_node_ref = 0,
            .free_list_node_len = 0,
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

        const active: Slot = if (store.header_checksum_ok) active_blk: {
            // The durable header.active_slot is the source of truth for which version is
            // committed. The max-version heuristic would wrongly resurrect an aborted
            // commit whose new slot was durably written in the data barrier but never
            // published (i.e., header flush failed after the data barrier succeeded).
            const primary_idx = store.header.active_slot;
            if (primary_idx > 1) return error.Corrupt;
            const primary_off: usize = if (primary_idx == 0) slot_a_off else slot_b_off;
            const other_off: usize = if (primary_idx == 0) slot_b_off else slot_a_off;

            // Try the primary slot first (normal path and correct crash-recovery path).
            // Fall back to the other slot only if the primary checksum is bad, which
            // indicates a crash mid-slot-write into the primary region itself.
            break :active_blk Slot.decode(store.map[primary_off..][0..Slot.size]) catch fallback: {
                break :fallback Slot.decode(store.map[other_off..][0..Slot.size]) catch
                    return error.Corrupt;
            };
        } else active_blk: {
            // Header checksum failed: the authoritative active_slot pointer is unreadable,
            // so fall back to the highest valid-version slot. This last-resort heuristic is
            // used ONLY when the header itself is corrupt.
            const maybe_a: ?Slot = Slot.decode(store.map[slot_a_off..][0..Slot.size]) catch null;
            const maybe_b: ?Slot = Slot.decode(store.map[slot_b_off..][0..Slot.size]) catch null;
            if (maybe_a != null and maybe_b != null) {
                break :active_blk if (maybe_a.?.version >= maybe_b.?.version) maybe_a.? else maybe_b.?;
            } else if (maybe_a != null) {
                break :active_blk maybe_a.?;
            } else if (maybe_b != null) {
                break :active_blk maybe_b.?;
            } else {
                return error.Corrupt;
            }
        };

        // Resume arena just past the last committed byte.
        var arena = Arena.init(store.map, default_page_size);
        arena.top = @intCast(active.logical_size);

        // Load the persisted free list if one was recorded in this slot.
        var free_list = FreeList.init(allocator);
        errdefer free_list.deinit();
        var free_list_node_ref: Ref = 0;
        var free_list_node_len: usize = 0;

        if (active.free_list_ref != 0) {
            // First read the 4-byte count prefix to know the full node size.
            const count_bytes = try arena.deref(active.free_list_ref, 4);
            const count = std.mem.readInt(u32, count_bytes[0..4], .little);
            const node_len = 4 + @as(usize, count) * 24;
            // Now read the full node and decode it.
            const node_bytes = try arena.deref(active.free_list_ref, node_len);
            try free_list.decode(node_bytes);
            free_list_node_ref = active.free_list_ref;
            free_list_node_len = node_len;
        }

        return Db{
            .store = store,
            .arena = arena,
            .active_version = active.version,
            .active_root = active.root_ref,
            .pins = std.AutoHashMap(u64, u32).init(allocator),
            .free_list = free_list,
            .free_list_node_ref = free_list_node_ref,
            .free_list_node_len = free_list_node_len,
        };
    }

    pub fn deinit(self: *Db) void {
        self.free_list.deinit();
        self.pins.deinit();
        self.store.deinit();
    }

    pub fn beginRead(self: *Db) !ReadTxn {
        const v = self.active_version;
        if (self.pins.getPtr(v)) |ptr| {
            ptr.* += 1;
        } else {
            try self.pins.put(v, 1);
        }
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

    pub fn beginWrite(self: *Db) !WriteTxn {
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

    /// Test-only accessor: number of extents in the committed free list.
    pub fn freeListLenForTest(self: *Db) usize {
        return self.free_list.extents.items.len;
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
        return self.db.arena.allocReusing(size, &self.work_freelist, self.db.horizon());
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
        const node_len = new_fl.byteLen();
        const node = try db.arena.alloc(node_len);
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
        db.store.syncer.flush(db.store.file) catch return error.Durability;

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
            return error.Durability;
        };

        // Step 5: publish the new version in memory only after both flushes succeed.
        db.active_version = self.new_version;
        db.active_root = self.new_root;
        // Install the new free list. errdefer for new_fl will NOT fire here
        // because we are on the success return path (return self.new_version below).
        db.free_list.deinit();
        db.free_list = new_fl; // ownership transferred; do not call new_fl.deinit()
        db.free_list_node_ref = node.ref;
        db.free_list_node_len = node_len;
        self.in_flight_frees.deinit(self.db.store.allocator);
        self.work_freelist.deinit();
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
