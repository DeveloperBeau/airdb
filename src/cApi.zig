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
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;
const Reference = @import("storage/reference.zig").Reference;
const rows = @import("records/rows.zig");
const catalog = @import("schema/catalog.zig");
const bulk = @import("records/bulk.zig");

pub const AIRDB_OK: i64 = 0;
pub const AIRDB_E_GENERIC: i64 = -1;
pub const AIRDB_E_NOT_FOUND: i64 = -2;
pub const AIRDB_E_BAD_ARGS: i64 = -3;
pub const AIRDB_E_CONFLICT: i64 = -4;
pub const AIRDB_E_DUPLICATE: i64 = -5;
pub const AIRDB_E_NOT_EMPTY: i64 = -6;
pub const AIRDB_E_UNSUPPORTED: i64 = -7;
/// A commit-point flush failed: the commit's on-disk fate is indeterminate and
/// the handle refuses further writes. Close and reopen the database to resolve.
pub const AIRDB_E_INDETERMINATE: i64 = -8;

const maxProperties: usize = catalog.maxPropertyCount;

const DatabaseHandle = struct {
    database: Database,
    propertyCount: u16,
};

const allocator = std.heap.c_allocator;

// Distinguish a retryable commit failure from an indeterminate one (the
// commit-point flush failed and the instance is poisoned until reopen).
fn commitErrCode(self: *DatabaseHandle) i64 {
    return if (self.database.poisoned) AIRDB_E_INDETERMINATE else AIRDB_E_GENERIC;
}

// Open the database at `path`, creating it with an int-property object type of
// `propertyCount` properties (property 0 is the primary key) if it does not exist.
// On an existing database the stored property count is used. Returns null on
// failure.
export fn airdb_open(pathPtr: [*:0]const u8, propertyCount: u16) ?*DatabaseHandle {
    const path = std.mem.span(pathPtr);
    // The storage layer requires an absolute path. Reject anything else here so
    // a relative path returns a clean error instead of aborting the host.
    if (!std.fs.path.isAbsolute(path)) return null;
    // A C ABI must not trust its arguments: propertyCount 0 trips an internal
    // assert (abort in safe builds), and > 256 would overflow fixed-size
    // per-property buffers in release builds. Reject both cleanly.
    if (propertyCount == 0 or propertyCount > maxProperties) return null;
    const self = allocator.create(DatabaseHandle) catch return null;

    if (Database.open(allocator, path)) |opened| {
        return adoptExisting(self, opened);
    } else |openErr| {
        // Create only when the file genuinely does not exist. Any other open
        // failure (corruption, resources, permissions) must NOT fall through to
        // create: FileStore.create truncates, which would destroy a database
        // that may still be recoverable.
        if (openErr != error.FileNotFound) {
            allocator.destroy(self);
            return null;
        }
        return createFresh(self, path, propertyCount);
    }
}

// Tear down a partially-opened handle after a failed open/create step and
// return the null that airdb_open reports to the host.
fn abandonHandle(self: *DatabaseHandle) ?*DatabaseHandle {
    self.database.deinit();
    allocator.destroy(self);
    return null;
}

// airdb_open, existing-file path: adopt the opened database and read the
// stored property count from its catalog. Any failure tears the handle down
// and returns null.
fn adoptExisting(self: *DatabaseHandle, opened: Database) ?*DatabaseHandle {
    self.database = opened;
    var readTransaction = self.database.beginRead() catch return abandonHandle(self);
    const propertyCount = catalog.loadPropertyCount(&readTransaction, readTransaction.root()) catch {
        readTransaction.end();
        return abandonHandle(self);
    };
    readTransaction.end();
    self.propertyCount = propertyCount;
    return self;
}

// airdb_open, fresh-file path: create the database and commit an int-property
// object type of `propertyCount` properties. Any failure tears the handle down
// and returns null.
fn createFresh(self: *DatabaseHandle, path: []const u8, propertyCount: u16) ?*DatabaseHandle {
    self.database = Database.create(allocator, path) catch {
        allocator.destroy(self);
        return null;
    };
    var writeTransaction = self.database.beginWrite() catch return abandonHandle(self);
    const catalogRef = catalog.create(&writeTransaction, propertyCount) catch {
        writeTransaction.deinit();
        return abandonHandle(self);
    };
    writeTransaction.setRoot(catalogRef);
    _ = writeTransaction.commit() catch return abandonHandle(self);
    self.propertyCount = propertyCount;
    return self;
}

// Close the database and free the handle. Safe to call with null.
export fn airdb_close(handle: ?*DatabaseHandle) void {
    const self = handle orelse return;
    self.database.deinit();
    allocator.destroy(self);
}

// Number of properties of the object type (property 0 is the primary key).
export fn airdb_prop_count(handle: ?*DatabaseHandle) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    return @intCast(self.propertyCount);
}

// Insert a row of `length` u64 values (must equal propertyCount; vals[0] is the
// primary key). Returns the new object key on success.
export fn airdb_insert(handle: ?*DatabaseHandle, values: [*]const u64, length: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (length != self.propertyCount) return AIRDB_E_BAD_ARGS;
    var writeTransaction = self.database.beginWrite() catch return commitErrCode(self);
    const result = rows.insert(&writeTransaction, writeTransaction.newRoot, values[0..length]) catch |err| {
        writeTransaction.deinit();
        return if (err == error.DuplicateKey) AIRDB_E_DUPLICATE else AIRDB_E_GENERIC;
    };
    writeTransaction.setRoot(result.catalogRef);
    _ = writeTransaction.commit() catch return commitErrCode(self);
    return @intCast(result.row);
}

// Read the row with primary key `primaryKey` into `out` (length must equal propertyCount).
// Returns the row version (>= 1) on success, AIRDB_E_NOT_FOUND if absent.
export fn airdb_get(handle: ?*DatabaseHandle, primaryKey: u64, out: [*]u64, length: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (length != self.propertyCount) return AIRDB_E_BAD_ARGS;
    var readTransaction = self.database.beginRead() catch return AIRDB_E_GENERIC;
    defer readTransaction.end();
    const version = rows.getByPrimaryKey(&readTransaction, readTransaction.root(), primaryKey, out[0..length]) catch return AIRDB_E_GENERIC;
    return if (version) |found| @intCast(found) else AIRDB_E_NOT_FOUND;
}

// Number of live rows. Returns the count or a negative error code.
export fn airdb_count(handle: ?*DatabaseHandle) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    var readTransaction = self.database.beginRead() catch return AIRDB_E_GENERIC;
    defer readTransaction.end();
    const count = catalog.liveCount(&readTransaction, readTransaction.root()) catch return AIRDB_E_GENERIC;
    return @intCast(count);
}

// Update the row with primary key `primaryKey` to `vals` (length must equal propertyCount,
// vals[0] must equal primaryKey). Auto-reads the current version, so it always applies
// (no optimistic check at this layer). Returns AIRDB_OK or an error code.
export fn airdb_update(handle: ?*DatabaseHandle, values: [*]const u64, length: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (length != self.propertyCount) return AIRDB_E_BAD_ARGS;
    const primaryKey = values[0];
    var writeTransaction = self.database.beginWrite() catch return commitErrCode(self);
    var currentValues: [maxProperties]u64 = undefined;
    const version = rows.getByPrimaryKey(&writeTransaction, writeTransaction.newRoot, primaryKey, currentValues[0..length]) catch {
        writeTransaction.deinit();
        return AIRDB_E_GENERIC;
    };
    if (version == null) {
        writeTransaction.deinit();
        return AIRDB_E_NOT_FOUND;
    }
    const result = rows.update(&writeTransaction, writeTransaction.newRoot, primaryKey, values[0..length], version.?) catch {
        writeTransaction.deinit();
        return AIRDB_E_GENERIC;
    };
    switch (result) {
        .ok => |ok| {
            writeTransaction.setRoot(ok.catalogRef);
            _ = writeTransaction.commit() catch return commitErrCode(self);
            return AIRDB_OK;
        },
        .conflict => {
            writeTransaction.deinit();
            return AIRDB_E_CONFLICT;
        },
        .notFound => {
            writeTransaction.deinit();
            return AIRDB_E_NOT_FOUND;
        },
    }
}

// Delete the row with primary key `primaryKey`. Returns AIRDB_OK or an error code.
export fn airdb_delete(handle: ?*DatabaseHandle, primaryKey: u64) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    var writeTransaction = self.database.beginWrite() catch return commitErrCode(self);
    var currentValues: [maxProperties]u64 = undefined;
    const version = rows.getByPrimaryKey(&writeTransaction, writeTransaction.newRoot, primaryKey, currentValues[0..self.propertyCount]) catch {
        writeTransaction.deinit();
        return AIRDB_E_GENERIC;
    };
    if (version == null) {
        writeTransaction.deinit();
        return AIRDB_E_NOT_FOUND;
    }
    const result = rows.delete(&writeTransaction, writeTransaction.newRoot, primaryKey, version.?) catch {
        writeTransaction.deinit();
        return AIRDB_E_GENERIC;
    };
    switch (result) {
        .ok => |newCatalog| {
            writeTransaction.setRoot(newCatalog);
            _ = writeTransaction.commit() catch return commitErrCode(self);
            return AIRDB_OK;
        },
        .conflict => {
            writeTransaction.deinit();
            return AIRDB_E_CONFLICT;
        },
        .notFound => {
            writeTransaction.deinit();
            return AIRDB_E_NOT_FOUND;
        },
    }
}

// Bulk-load `rowCount` rows of `propertyCount` u64 values each from the flat,
// row-major buffer `rowsFlat` (row i occupies rowsFlat[i*propertyCount ..][0..
// propertyCount]; element 0 of each row is the primary key) into an EMPTY type, in
// a single durable commit. The whole import succeeds atomically or nothing
// becomes durable. Returns the number of rows loaded on success, or a negative
// error code: AIRDB_E_NOT_EMPTY if the type already holds rows, AIRDB_E_DUPLICATE
// on a repeated primary key, AIRDB_E_UNSUPPORTED for a type bulk import cannot
// build (e.g. links), AIRDB_E_BAD_ARGS on a propertyCount mismatch. On every error
// the write lock is released and nothing is made durable.
export fn airdb_bulk_insert(handle: ?*DatabaseHandle, rowsFlat: [*]const u64, rowCount: usize, propertyCount: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (propertyCount != self.propertyCount) return AIRDB_E_BAD_ARGS;
    if (rowCount > std.math.maxInt(i64)) return AIRDB_E_BAD_ARGS; // return value is i64

    // Build a []const []const u64 view over the flat buffer: each row slice
    // points at its propertyCount-wide window. Freed regardless of outcome.
    const rowsSlices = allocator.alloc([]const u64, rowCount) catch return AIRDB_E_GENERIC;
    defer allocator.free(rowsSlices);
    for (rowsSlices, 0..) |*row, rowIndex| {
        row.* = rowsFlat[rowIndex * propertyCount ..][0..propertyCount];
    }

    var writeTransaction = self.database.beginWrite() catch return commitErrCode(self);
    const newCatalog = bulk.bulkImport(&writeTransaction, writeTransaction.newRoot, rowsSlices, .{}) catch |err| {
        writeTransaction.deinit(); // releases the write lock; nothing was made durable
        return switch (err) {
            error.TypeNotEmpty => AIRDB_E_NOT_EMPTY,
            error.DuplicateKey => AIRDB_E_DUPLICATE,
            error.UnsupportedForBulk => AIRDB_E_UNSUPPORTED,
            error.BadRow => AIRDB_E_BAD_ARGS,
            else => AIRDB_E_GENERIC,
        };
    };
    writeTransaction.setRoot(newCatalog);
    // commit releases the lock on BOTH its success and its own error paths, so
    // do not unlock again here.
    _ = writeTransaction.commit() catch return commitErrCode(self);
    return @intCast(rowCount);
}

// Append `rowCount` rows of `propertyCount` u64 values each from the flat,
// row-major buffer `rowsFlat` (row i occupies rowsFlat[i*propertyCount ..][0..
// propertyCount]; element 0 of each row is the primary key) to a POPULATED type in
// a single durable commit. A batch whose primary keys are strictly ascending and
// all clear the type's current max key lands on the right edge via the fast path;
// any other shape falls back to a row-by-row insert. The whole batch becomes
// durable atomically or nothing does. Returns the number of rows appended on
// success, or a negative error code: AIRDB_E_DUPLICATE on a repeated primary key
// (from the fallback), AIRDB_E_BAD_ARGS on a propertyCount mismatch. On every error
// the write lock is released and nothing is made durable. A rowCount of 0 is a
// no-op that commits no change and returns 0.
export fn airdb_bulk_append(handle: ?*DatabaseHandle, rowsFlat: [*]const u64, rowCount: usize, propertyCount: usize) i64 {
    const self = handle orelse return AIRDB_E_GENERIC;
    if (propertyCount != self.propertyCount) return AIRDB_E_BAD_ARGS;
    if (rowCount > std.math.maxInt(i64)) return AIRDB_E_BAD_ARGS; // return value is i64

    // Build a []const []const u64 view over the flat buffer: each row slice
    // points at its propertyCount-wide window. Freed regardless of outcome.
    const rowsSlices = allocator.alloc([]const u64, rowCount) catch return AIRDB_E_GENERIC;
    defer allocator.free(rowsSlices);
    for (rowsSlices, 0..) |*row, rowIndex| {
        row.* = rowsFlat[rowIndex * propertyCount ..][0..propertyCount];
    }

    var writeTransaction = self.database.beginWrite() catch return commitErrCode(self);
    const newCatalog = bulk.bulkAppendOrInsert(&writeTransaction, writeTransaction.newRoot, rowsSlices) catch |err| {
        writeTransaction.deinit(); // releases the write lock; nothing was made durable
        return switch (err) {
            error.BadRow => AIRDB_E_BAD_ARGS,
            error.DuplicateKey => AIRDB_E_DUPLICATE,
            else => AIRDB_E_GENERIC,
        };
    };
    writeTransaction.setRoot(newCatalog);
    // commit releases the lock on BOTH its success and its own error paths, so
    // do not unlock again here.
    _ = writeTransaction.commit() catch return commitErrCode(self);
    return @intCast(rowCount);
}

// ---------------------------------------------------------------------------
// Explicit multi-operation write transactions.
//
// A Transaction holds one open WriteTransaction and threads the catalog ref across operations,
// so a burst of writes commits as a SINGLE durable barrier instead of one
// commit per call. The auto-commit functions above are unchanged.
//
// Lifecycle: a Transaction handle returned by airdb_begin must be committed
// (airdb_commit) or aborted (airdb_abort) exactly once. Both paths free the
// handle and release the write lock; using the handle after either is undefined
// behavior. A handle is single-threaded: do not drive one Transaction from two threads.
//
// The write lock is acquired in airdb_begin and released exactly once: by
// airdb_commit (via WriteTransaction.commit, which unlocks on both its success and its
// own error/revert paths) or by airdb_abort (via WriteTransaction.deinit).
//
// BENIGN op results (duplicate, not-found, conflict) are decided before any
// mutation and leave the transaction fully usable. A STRUCTURAL op failure (generic
// error mid-mutation) is different: the op may have freed tree nodes that the
// unadvanced catalog ref still references, so committing afterwards would hand
// live nodes to the free list. Such a failure poisons the transaction -- only
// airdb_abort is accepted; airdb_commit refuses and aborts instead.
// ---------------------------------------------------------------------------

const Transaction = struct {
    databaseHandle: *DatabaseHandle,
    writeTransaction: WriteTransaction,
    catalogRef: Reference, // current catalog ref, threaded across operations
    poisoned: bool = false, // structural op failure: commit must not proceed
};

// Begin an explicit write transaction. Acquires the write lock. Returns null on
// failure (null handle, or the write lock / transaction could not be started). The
// returned handle must be passed to exactly one of airdb_commit / airdb_abort.
export fn airdb_begin(handle: ?*DatabaseHandle) ?*Transaction {
    const self = handle orelse return null;
    const created = allocator.create(Transaction) catch return null;
    created.databaseHandle = self;
    created.writeTransaction = self.database.beginWrite() catch {
        allocator.destroy(created);
        return null;
    };
    created.catalogRef = created.writeTransaction.newRoot;
    created.poisoned = false;
    return created;
}

// Abort an open transaction: release the write lock without making anything
// durable, then free the handle. Safe to call with null (no-op).
export fn airdb_abort(transaction: ?*Transaction) void {
    const handle = transaction orelse return;
    handle.writeTransaction.deinit(); // releases the write lock; makes nothing durable
    allocator.destroy(handle);
}

// Stage an insert in the open transaction (no commit). vals has `length` u64
// values (must equal propertyCount; vals[0] is the primary key). Returns the new
// object key on success. On error the transaction stays open and the catalog ref is not
// advanced, so the batch remains consistent.
export fn airdb_txn_insert(transaction: ?*Transaction, values: [*]const u64, length: usize) i64 {
    const handle = transaction orelse return AIRDB_E_GENERIC;
    if (handle.poisoned) return AIRDB_E_GENERIC;
    if (length != handle.databaseHandle.propertyCount) return AIRDB_E_BAD_ARGS;
    const result = rows.insert(&handle.writeTransaction, handle.catalogRef, values[0..length]) catch |err| {
        if (err == error.DuplicateKey) return AIRDB_E_DUPLICATE; // pre-mutation check: transaction stays usable
        handle.poisoned = true; // mid-mutation failure: the batch may reference freed nodes
        return AIRDB_E_GENERIC;
    };
    handle.catalogRef = result.catalogRef; // thread the new catalog ref; do NOT commit
    return @intCast(result.row);
}

// Stage an update in the open transaction (no commit). Mirrors airdb_update
// against the threaded catalog ref. Returns AIRDB_OK or an error code; on error
// the transaction stays open and the catalog ref is not advanced.
export fn airdb_txn_update(transaction: ?*Transaction, values: [*]const u64, length: usize) i64 {
    const handle = transaction orelse return AIRDB_E_GENERIC;
    if (handle.poisoned) return AIRDB_E_GENERIC;
    if (length != handle.databaseHandle.propertyCount) return AIRDB_E_BAD_ARGS;
    const primaryKey = values[0];
    var currentValues: [maxProperties]u64 = undefined;
    const version = rows.getByPrimaryKey(&handle.writeTransaction, handle.catalogRef, primaryKey, currentValues[0..length]) catch return AIRDB_E_GENERIC;
    if (version == null) return AIRDB_E_NOT_FOUND;
    const result = rows.update(&handle.writeTransaction, handle.catalogRef, primaryKey, values[0..length], version.?) catch {
        handle.poisoned = true; // mid-mutation failure
        return AIRDB_E_GENERIC;
    };
    switch (result) {
        .ok => |ok| {
            handle.catalogRef = ok.catalogRef;
            return AIRDB_OK;
        },
        .conflict => return AIRDB_E_CONFLICT,
        .notFound => return AIRDB_E_NOT_FOUND,
    }
}

// Stage a delete in the open transaction (no commit). Mirrors airdb_delete
// against the threaded catalog ref. Returns AIRDB_OK or an error code; on error
// the transaction stays open and the catalog ref is not advanced.
export fn airdb_txn_delete(transaction: ?*Transaction, primaryKey: u64) i64 {
    const handle = transaction orelse return AIRDB_E_GENERIC;
    if (handle.poisoned) return AIRDB_E_GENERIC;
    var currentValues: [maxProperties]u64 = undefined;
    const version = rows.getByPrimaryKey(&handle.writeTransaction, handle.catalogRef, primaryKey, currentValues[0..handle.databaseHandle.propertyCount]) catch return AIRDB_E_GENERIC;
    if (version == null) return AIRDB_E_NOT_FOUND;
    const result = rows.delete(&handle.writeTransaction, handle.catalogRef, primaryKey, version.?) catch {
        handle.poisoned = true; // mid-mutation failure
        return AIRDB_E_GENERIC;
    };
    switch (result) {
        .ok => |newCatalog| {
            handle.catalogRef = newCatalog;
            return AIRDB_OK;
        },
        .conflict => return AIRDB_E_CONFLICT,
        .notFound => return AIRDB_E_NOT_FOUND,
    }
}

// Commit the open transaction: make the entire batch durable in one barrier and
// release the write lock, then free the handle. Returns AIRDB_OK on success or
// AIRDB_E_GENERIC if the durable commit failed. WriteTransaction.commit already releases
// the lock on BOTH its success and its error/revert paths, so this must NOT
// unlock again; it only frees the handle. Safe with null (returns
// AIRDB_E_GENERIC).
export fn airdb_commit(transaction: ?*Transaction) i64 {
    const handle = transaction orelse return AIRDB_E_GENERIC;
    if (handle.poisoned) {
        // A structural op failure may have freed nodes the batch's tree still
        // references; committing would hand live nodes to the durable free
        // list. Abort on the caller's behalf.
        handle.writeTransaction.deinit();
        allocator.destroy(handle);
        return AIRDB_E_GENERIC;
    }
    handle.writeTransaction.setRoot(handle.catalogRef);
    _ = handle.writeTransaction.commit() catch {
        // commit already released the lock per WriteTransaction.commit's contract; just
        // free the handle. Do NOT double-unlock.
        const code = commitErrCode(handle.databaseHandle);
        allocator.destroy(handle);
        return code;
    };
    allocator.destroy(handle);
    return AIRDB_OK;
}

// ---------------------------------------------------------------------------
// Tests (exercise the C ABI surface directly)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn ffiTmpPathZ(pathAllocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![:0]u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const joined = try std.fs.path.join(pathAllocator, &.{ pathBuffer[0..dlen], name });
    defer pathAllocator.free(joined);
    return pathAllocator.dupeZ(u8, joined);
}

test "ffi: open, insert, get, count, update, delete, reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "ffi.airdb");
    defer testing.allocator.free(path);

    const handle = airdb_open(path.ptr, 3) orelse return error.OpenFailed;
    try testing.expectEqual(@as(i64, 3), airdb_prop_count(handle));

    // insert two rows
    try testing.expect(airdb_insert(handle, &[_]u64{ 100, 7, 1 }, 3) >= 0);
    try testing.expect(airdb_insert(handle, &[_]u64{ 200, 8, 0 }, 3) >= 0);
    try testing.expectEqual(@as(i64, 2), airdb_count(handle));
    // duplicate primaryKey rejected
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_insert(handle, &[_]u64{ 100, 9, 9 }, 3));
    // bad arity
    try testing.expectEqual(AIRDB_E_BAD_ARGS, airdb_insert(handle, &[_]u64{ 1, 2 }, 2));

    // get
    var out: [3]u64 = undefined;
    const version = airdb_get(handle, 200, &out, 3);
    try testing.expect(version >= 1);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_get(handle, 999, &out, 3));

    // update
    try testing.expectEqual(AIRDB_OK, airdb_update(handle, &[_]u64{ 200, 88, 0 }, 3));
    _ = airdb_get(handle, 200, &out, 3);
    try testing.expectEqual(@as(u64, 88), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_update(handle, &[_]u64{ 555, 0, 0 }, 3));

    // delete
    try testing.expectEqual(AIRDB_OK, airdb_delete(handle, 100));
    try testing.expectEqual(@as(i64, 1), airdb_count(handle));
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_delete(handle, 100));

    airdb_close(handle);

    // reopen: data persisted, property count adopted from catalog
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

test "ffi: hostile propertyCount is rejected without aborting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "badpc.airdb");
    defer testing.allocator.free(path);
    // 0 used to trip an internal assert (host abort); >256 overflowed
    // fixed-size per-property buffers in release builds.
    try testing.expect(airdb_open(path.ptr, 0) == null);
    try testing.expect(airdb_open(path.ptr, 300) == null);
}

test "ffi: open of a corrupt database returns null and never truncates the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "corrupt_open.airdb");
    defer testing.allocator.free(path);

    // Create a real database with one row, then close it.
    {
        const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
        try testing.expect(airdb_insert(handle, &[_]u64{ 1, 42 }, 2) >= 0);
        airdb_close(handle);
    }

    // Corrupt the magic so Database.open fails with something other than FileNotFound.
    const io = std.Io.Threaded.global_single_threaded.io();
    var lenBefore: u64 = 0;
    {
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);
        lenBefore = try file.length(io);
        try file.writePositionalAll(io, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF }, 0);
        try file.sync(io);
    }

    // Open must fail cleanly -- and must NOT truncate/recreate the file.
    try testing.expect(airdb_open(path.ptr, 2) == null);

    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    try testing.expectEqual(lenBefore, try file.length(io));
    var magic: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &magic, 0);
    // The corrupted magic is still there: nothing rewrote the header.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF }, &magic);
}

test "ffi transaction: begin then abort releases the write lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_beginabort.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const transaction = airdb_begin(handle) orelse return error.BeginFailed;
    airdb_abort(transaction); // must release the lock without crashing

    // A subsequent begin proves the lock was released.
    const transaction2 = airdb_begin(handle) orelse return error.BeginFailed;
    airdb_abort(transaction2);
}

test "ffi transaction: staged inserts are not durable after abort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_abort.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const transaction = airdb_begin(handle) orelse return error.BeginFailed;
    try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 1, 10 }, 2) >= 0);
    try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 2, 20 }, 2) >= 0);
    airdb_abort(transaction);

    // Nothing was committed, so a fresh read sees zero rows.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));
}

test "ffi transaction: commit makes the whole batch durable in one commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_commit.airdb");
    defer testing.allocator.free(path);
    {
        const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
        defer airdb_close(handle);

        const transaction = airdb_begin(handle) orelse return error.BeginFailed;
        try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 1, 10 }, 2) >= 0);
        try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 2, 20 }, 2) >= 0);
        try testing.expectEqual(AIRDB_OK, airdb_commit(transaction));

        try testing.expectEqual(@as(i64, 2), airdb_count(handle));
        var out: [2]u64 = undefined;
        try testing.expect(airdb_get(handle, 1, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 10), out[1]);
        try testing.expect(airdb_get(handle, 2, &out, 2) >= 1);
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

test "ffi transaction: update and delete apply within one batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_upddel.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    // Seed two rows in one batch.
    {
        const transaction = airdb_begin(handle) orelse return error.BeginFailed;
        try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 1, 10 }, 2) >= 0);
        try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 2, 20 }, 2) >= 0);
        try testing.expectEqual(AIRDB_OK, airdb_commit(transaction));
    }
    // Update row 1 and delete row 2 in a single batch.
    {
        const transaction = airdb_begin(handle) orelse return error.BeginFailed;
        try testing.expectEqual(AIRDB_OK, airdb_txn_update(transaction, &[_]u64{ 1, 99 }, 2));
        try testing.expectEqual(AIRDB_OK, airdb_txn_delete(transaction, 2));
        try testing.expectEqual(AIRDB_OK, airdb_commit(transaction));
    }
    try testing.expectEqual(@as(i64, 1), airdb_count(handle));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(handle, 1, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 99), out[1]);
    try testing.expectEqual(AIRDB_E_NOT_FOUND, airdb_get(handle, 2, &out, 2));
}

test "ffi transaction: abort after a failed op releases the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "txn_failop.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const transaction = airdb_begin(handle) orelse return error.BeginFailed;
    try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 1, 10 }, 2) >= 0);
    // Duplicate primaryKey fails but leaves the transaction open.
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_txn_insert(transaction, &[_]u64{ 1, 11 }, 2));
    airdb_abort(transaction);

    // The lock was released, so a new begin succeeds.
    const transaction2 = airdb_begin(handle) orelse return error.BeginFailed;
    airdb_abort(transaction2);
    // And nothing was made durable.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));
}

test "ffi transaction: null handle is rejected, not crashed" {
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_insert(null, &[_]u64{ 1, 2 }, 2));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_update(null, &[_]u64{ 1, 2 }, 2));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_txn_delete(null, 1));
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_commit(null));
    airdb_abort(null); // no-op, must not crash
}

test "airdb_bulk_insert loads a flat buffer in one commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_load.airdb");
    defer testing.allocator.free(path);
    {
        const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
        defer airdb_close(handle);

        const flat = [_]u64{ 1, 10, 2, 20, 3, 30 };
        try testing.expectEqual(@as(i64, 3), airdb_bulk_insert(handle, &flat, 3, 2));
        try testing.expectEqual(@as(i64, 3), airdb_count(handle));

        var out: [2]u64 = undefined;
        try testing.expect(airdb_get(handle, 1, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 10), out[1]);
        try testing.expect(airdb_get(handle, 2, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 20), out[1]);
        try testing.expect(airdb_get(handle, 3, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 30), out[1]);
    }
    // Reopen from the same path: all rows persisted (durability).
    const h2 = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h2);
    try testing.expectEqual(@as(i64, 3), airdb_count(h2));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(h2, 3, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 30), out[1]);
}

test "airdb_bulk_insert on a non-empty type returns AIRDB_E_NOT_EMPTY" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_nonempty.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    // Seed one row so the type is non-empty.
    try testing.expect(airdb_insert(handle, &[_]u64{ 1, 10 }, 2) >= 0);

    const flat = [_]u64{ 2, 20, 3, 30 };
    try testing.expectEqual(AIRDB_E_NOT_EMPTY, airdb_bulk_insert(handle, &flat, 2, 2));

    // Existing data is intact.
    try testing.expectEqual(@as(i64, 1), airdb_count(handle));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(handle, 1, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 10), out[1]);

    // The write lock was released: a subsequent insert succeeds.
    try testing.expect(airdb_insert(handle, &[_]u64{ 4, 40 }, 2) >= 0);
    try testing.expectEqual(@as(i64, 2), airdb_count(handle));
}

test "airdb_bulk_insert wrong propertyCount returns AIRDB_E_BAD_ARGS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_badargs.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const flat = [_]u64{ 1, 10, 100, 2, 20, 200 };
    try testing.expectEqual(AIRDB_E_BAD_ARGS, airdb_bulk_insert(handle, &flat, 2, 3));
    // Nothing was written and the lock is free.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));
    try testing.expect(airdb_insert(handle, &[_]u64{ 1, 10 }, 2) >= 0);
}

test "airdb_bulk_insert duplicate primaryKey returns AIRDB_E_DUPLICATE, type still empty, lock released" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_dup.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const flat = [_]u64{ 5, 50, 6, 60, 5, 55 };
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_bulk_insert(handle, &flat, 3, 2));

    // Nothing was committed: the type is still empty.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));

    // The write lock was released: a subsequent insert succeeds.
    try testing.expect(airdb_insert(handle, &[_]u64{ 1, 10 }, 2) >= 0);
    try testing.expectEqual(@as(i64, 1), airdb_count(handle));
}

test "airdb_bulk_append appends a contiguous batch in one commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_append.airdb");
    defer testing.allocator.free(path);
    {
        const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
        defer airdb_close(handle);

        // Seed a populated type with primaryKeys 0,1,2.
        const seed = [_]u64{ 0, 0, 1, 10, 2, 20 };
        try testing.expectEqual(@as(i64, 3), airdb_bulk_insert(handle, &seed, 3, 2));

        // Append a contiguous, strictly-ascending batch above the current max primaryKey.
        const batch = [_]u64{ 3, 30, 4, 40, 5, 50 };
        try testing.expectEqual(@as(i64, 3), airdb_bulk_append(handle, &batch, 3, 2));
        try testing.expectEqual(@as(i64, 6), airdb_count(handle));

        var out: [2]u64 = undefined;
        try testing.expect(airdb_get(handle, 3, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 30), out[1]);
        try testing.expect(airdb_get(handle, 4, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 40), out[1]);
        try testing.expect(airdb_get(handle, 5, &out, 2) >= 1);
        try testing.expectEqual(@as(u64, 50), out[1]);
    }
    // Reopen: the appended rows persisted (durability).
    const h2 = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(h2);
    try testing.expectEqual(@as(i64, 6), airdb_count(h2));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(h2, 5, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 50), out[1]);
}

test "airdb_bulk_append falls back for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_append_scatter.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    // Seed primaryKeys 0,1,2 (current max primaryKey is 2).
    const seed = [_]u64{ 0, 0, 1, 10, 2, 20 };
    try testing.expectEqual(@as(i64, 3), airdb_bulk_insert(handle, &seed, 3, 2));

    // A descending batch does not qualify for the right-edge fast path, but both
    // primaryKeys are fresh, so the row-by-row fallback inserts them successfully.
    const scattered = [_]u64{ 5, 50, 4, 40 };
    try testing.expectEqual(@as(i64, 2), airdb_bulk_append(handle, &scattered, 2, 2));
    try testing.expectEqual(@as(i64, 5), airdb_count(handle));
    var out: [2]u64 = undefined;
    try testing.expect(airdb_get(handle, 4, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 40), out[1]);
    try testing.expect(airdb_get(handle, 5, &out, 2) >= 1);
    try testing.expectEqual(@as(u64, 50), out[1]);

    // A non-qualifying batch carrying an existing primaryKey surfaces the fallback's
    // DuplicateKey as AIRDB_E_DUPLICATE; nothing is made durable.
    const dup = [_]u64{ 6, 60, 1, 11 };
    try testing.expectEqual(AIRDB_E_DUPLICATE, airdb_bulk_append(handle, &dup, 2, 2));
    try testing.expectEqual(@as(i64, 5), airdb_count(handle));

    // The write lock was released: a subsequent insert succeeds.
    try testing.expect(airdb_insert(handle, &[_]u64{ 7, 70 }, 2) >= 0);
    try testing.expectEqual(@as(i64, 6), airdb_count(handle));
}

test "airdb_bulk_append wrong propertyCount returns AIRDB_E_BAD_ARGS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "bulk_append_badargs.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const flat = [_]u64{ 1, 10, 100, 2, 20, 200 };
    try testing.expectEqual(AIRDB_E_BAD_ARGS, airdb_bulk_append(handle, &flat, 2, 3));
    // Nothing was written and the lock is free.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));
    try testing.expect(airdb_insert(handle, &[_]u64{ 1, 10 }, 2) >= 0);
}

test "ffi transaction: a poisoned transaction refuses commit and releases the lock" {
    // Regression: a structural op failure mid-batch can free tree nodes the
    // unadvanced catalog ref still references; committing such a transaction handed
    // live nodes to the durable free list. Commit must abort instead.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "poisontxn.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    const transaction = airdb_begin(handle) orelse return error.BeginFailed;
    try testing.expect(airdb_txn_insert(transaction, &[_]u64{ 1, 10 }, 2) >= 0);
    transaction.poisoned = true; // simulate a structural op failure
    try testing.expectEqual(AIRDB_E_GENERIC, airdb_commit(transaction));
    // Nothing became durable and the write lock was released.
    try testing.expectEqual(@as(i64, 0), airdb_count(handle));
    const t2 = airdb_begin(handle) orelse return error.BeginFailed;
    airdb_abort(t2);
}

test "ffi: a poisoned handle reports AIRDB_E_INDETERMINATE, not generic failure" {
    // Regression: only the failing commit itself returned -8; every later
    // write on the poisoned handle collapsed to AIRDB_E_GENERIC, so a caller
    // who missed the one -8 could never learn the handle needs a reopen.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try ffiTmpPathZ(testing.allocator, &tmp, "poisonedh.airdb");
    defer testing.allocator.free(path);
    const handle = airdb_open(path.ptr, 2) orelse return error.OpenFailed;
    defer airdb_close(handle);

    handle.database.poisoned = true; // simulate a failed commit-point flush
    try testing.expectEqual(AIRDB_E_INDETERMINATE, airdb_insert(handle, &[_]u64{ 1, 10 }, 2));
    try testing.expectEqual(AIRDB_E_INDETERMINATE, airdb_update(handle, &[_]u64{ 1, 11 }, 2));
    try testing.expectEqual(AIRDB_E_INDETERMINATE, airdb_delete(handle, 1));
}
