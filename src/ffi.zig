// C ABI surface for airdb. A thin auto-commit layer over the object store so
// language bindings (Swift, Kotlin, TS, Zig) can drive a single int-property
// object type without managing transactions or catalog refs directly.
//
// Each call is its own transaction: writes begin, apply, and commit before
// returning; reads take a fresh snapshot. Explicit multi-op transactions, blob
// values, links, and queries over this boundary are follow-on work.
//
// Convention: functions returning i64 use a non-negative value on success and a
// negative AIRDB_E_* code on failure. Handle-returning functions return null on
// failure.

const std = @import("std");
const Db = @import("db.zig").Db;
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const objects = @import("objects.zig");
const catalog = @import("catalog.zig");

pub const AIRDB_OK: i64 = 0;
pub const AIRDB_E_GENERIC: i64 = -1;
pub const AIRDB_E_NOT_FOUND: i64 = -2;
pub const AIRDB_E_BAD_ARGS: i64 = -3;
pub const AIRDB_E_CONFLICT: i64 = -4;
pub const AIRDB_E_DUPLICATE: i64 = -5;

const MAX_PROPS: usize = 256;

const Database = struct {
    db: Db,
    prop_count: u16,
};

const alloc = std.heap.c_allocator;

// Open the database at `path`, creating it with an int-property object type of
// `prop_count` properties (property 0 is the primary key) if it does not exist.
// On an existing database the stored property count is used. Returns null on
// failure.
export fn airdb_open(path_ptr: [*:0]const u8, prop_count: u16) ?*Database {
    const path = std.mem.span(path_ptr);
    // The storage layer requires an absolute path. Reject anything else here so
    // a relative path returns a clean error instead of aborting the host.
    if (!std.fs.path.isAbsolute(path)) return null;
    const self = alloc.create(Database) catch return null;

    if (Db.open(alloc, path)) |opened| {
        self.db = opened;
        // Adopt the stored property count from the catalog.
        var r = self.db.beginRead() catch {
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        const pc = catalog.propCount(&r, r.root()) catch {
            r.end();
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        r.end();
        self.prop_count = pc;
        return self;
    } else |_| {
        self.db = Db.create(alloc, path) catch {
            alloc.destroy(self);
            return null;
        };
        var w = self.db.beginWrite() catch {
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        const cat = catalog.create(&w, prop_count) catch {
            w.deinit();
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        w.setRoot(cat);
        _ = w.commit() catch {
            self.db.deinit();
            alloc.destroy(self);
            return null;
        };
        self.prop_count = prop_count;
        return self;
    }
}

// Close the database and free the handle. Safe to call with null.
export fn airdb_close(handle: ?*Database) void {
    const self = handle orelse return;
    self.db.deinit();
    alloc.destroy(self);
}

// Number of properties of the object type (property 0 is the primary key).
export fn airdb_prop_count(handle: ?*Database) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    return @intCast(self.prop_count);
}

// Insert a row of `len` u64 values (must equal prop_count; vals[0] is the
// primary key). Returns the new object key on success.
export fn airdb_insert(handle: ?*Database, vals: [*]const u64, len: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (len != self.prop_count) return AIRDB_E_BAD_ARGS;
    var w = self.db.beginWrite() catch return AIRDB_E_GENERIC;
    const r = objects.insert(&w, w.new_root, vals[0..len]) catch |e| {
        w.deinit();
        return if (e == error.DuplicateKey) AIRDB_E_DUPLICATE else AIRDB_E_GENERIC;
    };
    w.setRoot(r.cat);
    _ = w.commit() catch return AIRDB_E_GENERIC;
    return @intCast(r.row);
}

// Read the row with primary key `pk` into `out` (len must equal prop_count).
// Returns the row version (>= 1) on success, AIRDB_E_NOT_FOUND if absent.
export fn airdb_get(handle: ?*Database, pk: u64, out: [*]u64, len: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (len != self.prop_count) return AIRDB_E_BAD_ARGS;
    var r = self.db.beginRead() catch return AIRDB_E_GENERIC;
    defer r.end();
    const ver = objects.getByPk(&r, r.root(), pk, out[0..len]) catch return AIRDB_E_GENERIC;
    return if (ver) |v| @intCast(v) else AIRDB_E_NOT_FOUND;
}

// Number of live rows. Returns the count or a negative error code.
export fn airdb_count(handle: ?*Database) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    var r = self.db.beginRead() catch return AIRDB_E_GENERIC;
    defer r.end();
    const c = catalog.liveCount(&r, r.root()) catch return AIRDB_E_GENERIC;
    return @intCast(c);
}

// Update the row with primary key `pk` to `vals` (len must equal prop_count,
// vals[0] must equal pk). Auto-reads the current version, so it always applies
// (no optimistic check at this layer). Returns AIRDB_OK or an error code.
export fn airdb_update(handle: ?*Database, vals: [*]const u64, len: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (len != self.prop_count) return AIRDB_E_BAD_ARGS;
    const pk = vals[0];
    var w = self.db.beginWrite() catch return AIRDB_E_GENERIC;
    var cur: [MAX_PROPS]u64 = undefined;
    const ver = objects.getByPk(&w, w.new_root, pk, cur[0..len]) catch {
        w.deinit();
        return AIRDB_E_GENERIC;
    };
    if (ver == null) {
        w.deinit();
        return AIRDB_E_NOT_FOUND;
    }
    const res = objects.update(&w, w.new_root, pk, vals[0..len], ver.?) catch {
        w.deinit();
        return AIRDB_E_GENERIC;
    };
    switch (res) {
        .ok => |ok| {
            w.setRoot(ok.cat);
            _ = w.commit() catch return AIRDB_E_GENERIC;
            return AIRDB_OK;
        },
        .conflict => {
            w.deinit();
            return AIRDB_E_CONFLICT;
        },
        .not_found => {
            w.deinit();
            return AIRDB_E_NOT_FOUND;
        },
    }
}

// Delete the row with primary key `pk`. Returns AIRDB_OK or an error code.
export fn airdb_delete(handle: ?*Database, pk: u64) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    var w = self.db.beginWrite() catch return AIRDB_E_GENERIC;
    var cur: [MAX_PROPS]u64 = undefined;
    const ver = objects.getByPk(&w, w.new_root, pk, cur[0..self.prop_count]) catch {
        w.deinit();
        return AIRDB_E_GENERIC;
    };
    if (ver == null) {
        w.deinit();
        return AIRDB_E_NOT_FOUND;
    }
    const res = objects.delete(&w, w.new_root, pk, ver.?) catch {
        w.deinit();
        return AIRDB_E_GENERIC;
    };
    switch (res) {
        .ok => |new_cat| {
            w.setRoot(new_cat);
            _ = w.commit() catch return AIRDB_E_GENERIC;
            return AIRDB_OK;
        },
        .conflict => {
            w.deinit();
            return AIRDB_E_CONFLICT;
        },
        .not_found => {
            w.deinit();
            return AIRDB_E_NOT_FOUND;
        },
    }
}

// ---------------------------------------------------------------------------
// Explicit multi-operation write transactions.
//
// A Txn holds one open WriteTxn and threads the catalog ref across operations,
// so a burst of writes commits as a SINGLE durable barrier instead of one
// commit per call. The auto-commit functions above are unchanged.
//
// Lifecycle: a Txn handle returned by airdb_begin must be committed
// (airdb_commit) or aborted (airdb_abort) exactly once. Both paths free the
// handle and release the write lock; using the handle after either is undefined
// behavior. A handle is single-threaded: do not drive one Txn from two threads.
//
// The write lock is acquired in airdb_begin and released exactly once: by
// airdb_commit (via WriteTxn.commit, which unlocks on both its success and its
// own error/revert paths) or by airdb_abort (via WriteTxn.deinit). Operation
// errors leave the txn open and the catalog ref unadvanced, so a failed op
// never corrupts the batch -- the caller chooses to continue or abort.
// ---------------------------------------------------------------------------

const Txn = struct {
    dbh: *Database,
    w: WriteTxn,
    cat: Ref, // current catalog ref, threaded across operations
};

// Begin an explicit write transaction. Acquires the write lock. Returns null on
// failure (null handle, or the write lock / txn could not be started). The
// returned handle must be passed to exactly one of airdb_commit / airdb_abort.
export fn airdb_begin(handle: ?*Database) ?*Txn {
    const self = handle orelse return null;
    const t = alloc.create(Txn) catch return null;
    t.dbh = self;
    t.w = self.db.beginWrite() catch {
        alloc.destroy(t);
        return null;
    };
    t.cat = t.w.new_root;
    return t;
}

// Abort an open transaction: release the write lock without making anything
// durable, then free the handle. Safe to call with null (no-op).
export fn airdb_abort(txn: ?*Txn) void {
    const t = txn orelse return;
    t.w.deinit(); // releases the write lock; makes nothing durable
    alloc.destroy(t);
}

// Stage an insert in the open transaction (no commit). vals has `len` u64
// values (must equal prop_count; vals[0] is the primary key). Returns the new
// object key on success. On error the txn stays open and the catalog ref is not
// advanced, so the batch remains consistent.
export fn airdb_txn_insert(txn: ?*Txn, vals: [*]const u64, len: usize) i64 {
    const t = txn orelse return AIRDB_E_GENERIC;
    if (len != t.dbh.prop_count) return AIRDB_E_BAD_ARGS;
    const r = objects.insert(&t.w, t.cat, vals[0..len]) catch |e| {
        return if (e == error.DuplicateKey) AIRDB_E_DUPLICATE else AIRDB_E_GENERIC;
    };
    t.cat = r.cat; // thread the new catalog ref; do NOT commit
    return @intCast(r.row);
}

// Stage an update in the open transaction (no commit). Mirrors airdb_update
// against the threaded catalog ref. Returns AIRDB_OK or an error code; on error
// the txn stays open and the catalog ref is not advanced.
export fn airdb_txn_update(txn: ?*Txn, vals: [*]const u64, len: usize) i64 {
    const t = txn orelse return AIRDB_E_GENERIC;
    if (len != t.dbh.prop_count) return AIRDB_E_BAD_ARGS;
    const pk = vals[0];
    var cur: [MAX_PROPS]u64 = undefined;
    const ver = objects.getByPk(&t.w, t.cat, pk, cur[0..len]) catch return AIRDB_E_GENERIC;
    if (ver == null) return AIRDB_E_NOT_FOUND;
    const res = objects.update(&t.w, t.cat, pk, vals[0..len], ver.?) catch return AIRDB_E_GENERIC;
    switch (res) {
        .ok => |ok| {
            t.cat = ok.cat;
            return AIRDB_OK;
        },
        .conflict => return AIRDB_E_CONFLICT,
        .not_found => return AIRDB_E_NOT_FOUND,
    }
}

// Stage a delete in the open transaction (no commit). Mirrors airdb_delete
// against the threaded catalog ref. Returns AIRDB_OK or an error code; on error
// the txn stays open and the catalog ref is not advanced.
export fn airdb_txn_delete(txn: ?*Txn, pk: u64) i64 {
    const t = txn orelse return AIRDB_E_GENERIC;
    var cur: [MAX_PROPS]u64 = undefined;
    const ver = objects.getByPk(&t.w, t.cat, pk, cur[0..t.dbh.prop_count]) catch return AIRDB_E_GENERIC;
    if (ver == null) return AIRDB_E_NOT_FOUND;
    const res = objects.delete(&t.w, t.cat, pk, ver.?) catch return AIRDB_E_GENERIC;
    switch (res) {
        .ok => |new_cat| {
            t.cat = new_cat;
            return AIRDB_OK;
        },
        .conflict => return AIRDB_E_CONFLICT,
        .not_found => return AIRDB_E_NOT_FOUND,
    }
}

// Commit the open transaction: make the entire batch durable in one barrier and
// release the write lock, then free the handle. Returns AIRDB_OK on success or
// AIRDB_E_GENERIC if the durable commit failed. WriteTxn.commit already releases
// the lock on BOTH its success and its error/revert paths, so this must NOT
// unlock again; it only frees the handle. Safe with null (returns
// AIRDB_E_GENERIC).
export fn airdb_commit(txn: ?*Txn) i64 {
    const t = txn orelse return AIRDB_E_GENERIC;
    t.w.setRoot(t.cat);
    _ = t.w.commit() catch {
        // commit already released the lock per WriteTxn.commit's contract; just
        // free the handle. Do NOT double-unlock.
        alloc.destroy(t);
        return AIRDB_E_GENERIC;
    };
    alloc.destroy(t);
    return AIRDB_OK;
}

// ---------------------------------------------------------------------------
// Tests (exercise the C ABI surface directly)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn ffiTmpPathZ(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![:0]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    const joined = try std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
    defer allocator.free(joined);
    return allocator.dupeZ(u8, joined);
}

test "ffi: open, insert, get, count, update, delete, reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "ffi.airdb");
    defer testing.allocator.free(path);

    const h = airdb_open(path.ptr, 3) orelse return error.OpenFailed;
    try testing.expectEqual(@as(i64, 3), airdb_prop_count(h));

    // insert two rows
    try testing.expect(airdb_insert(h, &[_]u64{ 100, 7, 1 }, 3) >= 0);
    try testing.expect(airdb_insert(h, &[_]u64{ 200, 8, 0 }, 3) >= 0);
    try testing.expectEqual(@as(i64, 2), airdb_count(h));
    // duplicate pk rejected
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_insert(h, &[_]u64{ 100, 9, 9 }, 3));
    // bad arity
    try testing.expectEqual(AIRDB_E_BAD_ARGS, airdb_insert(h, &[_]u64{ 1, 2 }, 2));

    // get
    var out: [3]u64 = undefined;
    const ver = airdb_get(h, 200, &out, 3);
    try testing.expect(ver >= 1);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_get(h, 999, &out, 3));

    // update
    try testing.expectEqual(AIRDB_OK, airdb_update(h, &[_]u64{ 200, 88, 0 }, 3));
    _ = airdb_get(h, 200, &out, 3);
    try testing.expectEqual(@as(u64, 88), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_update(h, &[_]u64{ 555, 0, 0 }, 3));

    // delete
    try testing.expectEqual(AIRDB_OK, airdb_delete(h, 100));
    try testing.expectEqual(@as(i64, 1), airdb_count(h));
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_delete(h, 100));

    airdb_close(h);

    // reopen: data persisted, prop count adopted from catalog
    const h2 = airdb_open(path.ptr, 3) orelse return error.OpenFailed;
    defer airdb_close(h2);
    try testing.expectEqual(@as(i64, 3), airdb_prop_count(h2));
    try testing.expectEqual(@as(i64, 1), airdb_count(h2));
    _ = airdb_get(h2, 200, &out, 3);
    try testing.expectEqual(@as(u64, 88), out[1]);
}

test "ffi: null handle is safe" {
    airdb_close(null);
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_count(null));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_prop_count(null));
}

test "ffi: relative path is rejected without aborting" {
    try testing.expect(airdb_open("relative/path.airdb", 2) == null);
}

test "ffi txn: begin then abort releases the write lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_beginabort.airdb");
    defer testing.allocator.free(path);
    const h = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h);

    const txn = airdb_begin(h) orelse return error.BeginFailed;
    airdb_abort(txn); // must release the lock without crashing

    // A subsequent begin proves the lock was released.
    const txn2 = airdb_begin(h) orelse return error.BeginFailed;
    airdb_abort(txn2);
}

test "ffi txn: staged inserts are not durable after abort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_abort.airdb");
    defer testing.allocator.free(path);
    const h = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h);

    const txn = airdb_begin(h) orelse return error.BeginFailed;
    try testing.expect(airdb_txn_insert(txn, &[_]u64{ 1, 10 }, 2) >= 0);
    try testing.expect(airdb_txn_insert(txn, &[_]u64{ 2, 20 }, 2) >= 0);
    airdb_abort(txn);

    // Nothing was committed, so a fresh read sees zero rows.
    try testing.expectEqual(@as(i64, 0), airdb_count(h));
}

test "ffi txn: commit makes the whole batch durable in one commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_commit.airdb");
    defer testing.allocator.free(path);
    {
        const h = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
        defer airdb_close(h);

        const txn = airdb_begin(h) orelse return error.BeginFailed;
        try testing.expect(airdb_txn_insert(txn, &[_]u64{ 1, 10 }, 2) >= 0);
        try testing.expect(airdb_txn_insert(txn, &[_]u64{ 2, 20 }, 2) >= 0);
        try testing.expectEqual(AIRDB_OK, airdb_commit(txn));

        try testing.expectEqual(@as(i64, 2), airdb_count(h));
        var out: [2]u64 = undefined;
        try testing.expect(airdb_get(h, 1, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 10), out[1]);
        try testing.expect(airdb_get(h, 2, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 20), out[1]);
    }
    // Reopen from the same path: both rows persisted (durability).
    const h2 = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h2);
    try testing.expectEqual(@as(i64, 2), airdb_count(h2));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(h2, 1, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 10), out[1]);
    try testing.expect(airdb_get(h2, 2, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 20), out[1]);
}

test "ffi txn: update and delete apply within one batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_upddel.airdb");
    defer testing.allocator.free(path);
    const h = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h);

    // Seed two rows in one batch.
    {
        const txn = airdb_begin(h) orelse return error.BeginFailed;
        try testing.expect(airdb_txn_insert(txn, &[_]u64{ 1, 10 }, 2) >= 0);
        try testing.expect(airdb_txn_insert(txn, &[_]u64{ 2, 20 }, 2) >= 0);
        try testing.expectEqual(AIRDB_OK, airdb_commit(txn));
    }
    // Update row 1 and delete row 2 in a single batch.
    {
        const txn = airdb_begin(h) orelse return error.BeginFailed;
        try testing.expectEqual(AIRDB_OK, airdb_txn_update(txn, &[_]u64{ 1, 99 }, 2));
        try testing.expectEqual(AIRDB_OK, airdb_txn_delete(txn, 2));
        try testing.expectEqual(AIRDB_OK, airdb_commit(txn));
    }
    try testing.expectEqual(@as(i64, 1), airdb_count(h));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(h, 1, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 99), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_get(h, 2, &out, 2));
}

test "ffi txn: abort after a failed op releases the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_failop.airdb");
    defer testing.allocator.free(path);
    const h = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h);

    const txn = airdb_begin(h) orelse return error.BeginFailed;
    try testing.expect(airdb_txn_insert(txn, &[_]u64{ 1, 10 }, 2) >= 0);
    // Duplicate pk fails but leaves the txn open.
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_txn_insert(txn, &[_]u64{ 1, 11 }, 2));
    airdb_abort(txn);

    // The lock was released, so a new begin succeeds.
    const txn2 = airdb_begin(h) orelse return error.BeginFailed;
    airdb_abort(txn2);
    // And nothing was made durable.
    try testing.expectEqual(@as(i64, 0), airdb_count(h));
}

test "ffi txn: null handle is rejected, not crashed" {
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_insert(null, &[_]u64{ 1, 2 }, 2));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_update(null, &[_]u64{ 1, 2 }, 2));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_delete(null, 1));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_commit(null));
    airdb_abort(null); // no-op, must not crash
}
