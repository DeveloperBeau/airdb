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
const default_page_size = @import("file_store.zig").default_page_size;
const Arena = @import("arena.zig").Arena;
const Allocation = @import("arena.zig").Allocation;
const Ref = @import("ref.zig").Ref;
const Slot = @import("slots.zig").Slot;

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

    /// Create a new database file at the given absolute path.
    pub fn create(allocator: std.mem.Allocator, path: []const u8) !Db {
        var store = try FileStore.create(allocator, path, RealSyncer.any());
        errdefer store.deinit();

        // Write version-1 into slot A; mark it active.
        const initial = Slot{
            .version = 1,
            .root_ref = 0,
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
        };
    }

    /// Open an existing database file at the given absolute path.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        var store = try FileStore.open(allocator, path, RealSyncer.any());
        errdefer store.deinit();

        // The durable header.active_slot is the source of truth for which version is
        // committed. selectActive's max-version heuristic would wrongly resurrect an
        // aborted commit whose new slot was durably written in the data barrier but
        // never published (i.e., header flush failed after the data barrier succeeded).
        const primary_idx = store.header.active_slot;
        const primary_off: usize = if (primary_idx == 0) slot_a_off else slot_b_off;
        const other_off: usize = if (primary_idx == 0) slot_b_off else slot_a_off;

        // Try the primary slot first (normal path and correct crash-recovery path).
        // Fall back to the other slot only if the primary checksum is bad, which
        // indicates a crash mid-slot-write into the primary region itself.
        const active: Slot = Slot.decode(store.map[primary_off..][0..Slot.size]) catch blk: {
            break :blk Slot.decode(store.map[other_off..][0..Slot.size]) catch
                return error.Corrupt;
        };

        // Resume arena just past the last committed byte.
        var arena = Arena.init(store.map, default_page_size);
        arena.top = @intCast(active.logical_size);

        return Db{
            .store = store,
            .arena = arena,
            .active_version = active.version,
            .active_root = active.root_ref,
        };
    }

    pub fn deinit(self: *Db) void {
        self.store.deinit();
    }

    pub fn beginRead(self: *Db) ReadTxn {
        return .{ .db = self, .root_ref = self.active_root };
    }

    pub fn beginWrite(self: *Db) !WriteTxn {
        return WriteTxn{
            .db = self,
            .new_root = self.active_root,
            .new_version = self.active_version + 1,
        };
    }
};

// ---------------------------------------------------------------------------
// ReadTxn
// ---------------------------------------------------------------------------

pub const ReadTxn = struct {
    db: *Db,
    root_ref: Ref,

    pub fn root(self: ReadTxn) Ref {
        return self.root_ref;
    }

    pub fn deref(self: *ReadTxn, ref: Ref, len: usize) ![]const u8 {
        return self.db.arena.deref(ref, len);
    }
};

// ---------------------------------------------------------------------------
// WriteTxn
// ---------------------------------------------------------------------------

pub const WriteTxn = struct {
    db: *Db,
    new_root: Ref,
    new_version: u64,

    pub fn alloc(self: *WriteTxn, size: usize) !Allocation {
        return self.db.arena.alloc(size);
    }

    pub fn setRoot(self: *WriteTxn, ref: Ref) void {
        self.new_root = ref;
    }

    /// Two-slot atomic durable commit.
    ///
    /// Protocol:
    ///   1. Encode the new slot into the currently-INACTIVE slot byte range.
    ///   2. Flush -- ensures new data and the slot descriptor are durable.
    ///      If this flush fails, return error.Durability immediately;
    ///      the old active slot is untouched and the old version remains live.
    ///   3. Flip header.active_slot to the newly-written slot; persistHeader().
    ///   4. Flush -- this is the commit point.
    ///      If this flush fails, revert ALL in-memory header changes
    ///      (active_slot and logical_size) and return error.Durability.
    ///      The old active slot on disk is still valid, so crash recovery
    ///      will see the old version.
    ///   5. Only after both flushes succeed: update active_version / active_root.
    pub fn commit(self: *WriteTxn) !u64 {
        const db = self.db;
        const prev_active_slot = db.store.header.active_slot;
        const prev_logical_size = db.store.header.logical_size;

        // Step 1: determine the inactive slot and its byte offset.
        const inactive_idx: u8 = if (prev_active_slot == 0) 1 else 0;
        const inactive_off: usize = if (inactive_idx == 0) slot_a_off else slot_b_off;

        // Step 2: write the new slot descriptor into the inactive region.
        const new_slot = Slot{
            .version = self.new_version,
            .root_ref = self.new_root,
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
        const aborted = Slot{ .version = 50, .root_ref = 0, .logical_size = default_page_size };
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
        var r = db.beginRead();
        const root_ref = r.root();
        try testing.expect(root_ref != 0);
        const bytes = try r.deref(root_ref, 8);
        try testing.expectEqualStrings("HELLOAID", bytes);
    }
}
