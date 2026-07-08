const std = @import("std");
const Column = @import("column.zig");
const node = @import("columnNode.zig");
const Reference = @import("../storage/reference.zig").Reference;
const create = Column.create;
const length = Column.length;
const get = Column.get;
const append = Column.append;
const appendRun = Column.appendRun;
const set = Column.set;
const truncate = Column.truncate;
const makeInnerForTest = Column.makeInnerForTest;
const leafNodeSize = node.leafNodeSize;
const innerNodeSize = node.innerNodeSize;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const encodeInner = node.encodeInner;

const testing = std.testing;

const Database = @import("../database.zig").Database;
const WriteTransaction = @import("../database.zig").WriteTransaction;

fn colTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "leaf encode/decode round-trips values" {
    var buffer: [leafNodeSize]u8 = undefined;
    const vals = [_]u64{ 10, 20, 30 };
    const count = encodeLeaf(&buffer, &vals);
    const view = try parseLeaf(buffer[0..count]);
    try testing.expectEqual(@as(u16, 3), view.count);
    try testing.expectEqual(@as(u64, 20), view.value(1));
}

test "parseLeaf rejects a buffer too small for its declared count" {
    var buffer: [16]u8 = undefined;
    buffer[0] = 0; // kind = leaf
    std.mem.writeInt(u16, buffer[1..3], 100, .little); // claims 100 values
    try testing.expectError(error.Corrupt, parseLeaf(buffer[0..16]));
}

test "a column ref cycle fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // Inner node whose only child is itself with a nonzero claimed count:
    // get/set/append must hit the depth cap, not overflow the stack.
    const allocation = try writeTransaction.alloc(innerNodeSize);
    _ = encodeInner(allocation.bytes, &.{allocation.ref}, &.{10});
    try testing.expectError(error.Corrupt, get(&writeTransaction, allocation.ref, 0));
    try testing.expectError(error.Corrupt, set(&writeTransaction, allocation.ref, 0, 1));
    try testing.expectError(error.Corrupt, append(&writeTransaction, allocation.ref, 1));
}

test "single-leaf column: create, append, get, length, set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    try testing.expectEqual(@as(u64, 0), try length(&writeTransaction, root));
    root = try append(&writeTransaction, root, 100);
    root = try append(&writeTransaction, root, 200);
    root = try append(&writeTransaction, root, 300);
    try testing.expectEqual(@as(u64, 3), try length(&writeTransaction, root));
    try testing.expectEqual(@as(u64, 200), try get(&writeTransaction, root, 1));
    root = try set(&writeTransaction, root, 1, 222);
    try testing.expectEqual(@as(u64, 222), try get(&writeTransaction, root, 1));
    try testing.expectError(error.IndexOutOfBounds, get(&writeTransaction, root, 3));
    writeTransaction.deinit();
}

test "append grows the tree across many leaves and reads back correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    const N: u64 = 5000; // > leafCap and > leafCap*fanout (4096): forces >= 3 levels
    var index: u64 = 0;
    while (index < N) : (index += 1) root = try append(&writeTransaction, root, index * 7);
    try testing.expectEqual(N, try length(&writeTransaction, root));
    try testing.expectEqual(@as(u64, 0), try get(&writeTransaction, root, 0));
    try testing.expectEqual(@as(u64, 4999 * 7), try get(&writeTransaction, root, 4999));
    try testing.expectEqual(@as(u64, 2500 * 7), try get(&writeTransaction, root, 2500));
    // spot-check several indices
    var key: u64 = 0;
    while (key < N) : (key += 137) try testing.expectEqual(key * 7, try get(&writeTransaction, root, key));
    writeTransaction.deinit();
}

test "get and length traverse an inner node over two leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var column0 = try create(&writeTransaction);
    column0 = try append(&writeTransaction, column0, 0);
    column0 = try append(&writeTransaction, column0, 1);
    var column1 = try create(&writeTransaction);
    column1 = try append(&writeTransaction, column1, 2);
    column1 = try append(&writeTransaction, column1, 3);
    const inner = try makeInnerForTest(&writeTransaction, &.{ .{ .ref = column0, .count = 2 }, .{ .ref = column1, .count = 2 } });
    try testing.expectEqual(@as(u64, 4), try length(&writeTransaction, inner));
    try testing.expectEqual(@as(u64, 0), try get(&writeTransaction, inner, 0));
    try testing.expectEqual(@as(u64, 2), try get(&writeTransaction, inner, 2));
    try testing.expectEqual(@as(u64, 3), try get(&writeTransaction, inner, 3));
    try testing.expectError(error.IndexOutOfBounds, get(&writeTransaction, inner, 4));
    writeTransaction.deinit();
}

test "set on a multi-level column leaves the old root snapshot unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    var index: u64 = 0;
    while (index < 1000) : (index += 1) root = try append(&writeTransaction, root, index);
    const oldRoot = root;
    const newRoot = try set(&writeTransaction, root, 500, 999999);
    try testing.expectEqual(@as(u64, 500), try get(&writeTransaction, oldRoot, 500)); // old snapshot unchanged
    try testing.expectEqual(@as(u64, 999999), try get(&writeTransaction, newRoot, 500)); // new root updated
    try testing.expectEqual(try length(&writeTransaction, oldRoot), try length(&writeTransaction, newRoot));
    // a few other indices match between old and new (shared subtrees)
    try testing.expectEqual(try get(&writeTransaction, oldRoot, 0), try get(&writeTransaction, newRoot, 0));
    try testing.expectEqual(try get(&writeTransaction, oldRoot, 999), try get(&writeTransaction, newRoot, 999));
    writeTransaction.deinit();
}

test "Column.truncate shrinks length and preserves head values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "coltrunc1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    const N: u64 = 1000;
    var index: u64 = 0;
    while (index < N) : (index += 1) root = try append(&writeTransaction, root, index * 7);
    const M: u64 = 300;
    root = try truncate(&writeTransaction, root, M);
    try testing.expectEqual(M, try length(&writeTransaction, root));
    var key: u64 = 0;
    while (key < M) : (key += 1) try testing.expectEqual(key * 7, try get(&writeTransaction, root, key));
    try testing.expectError(error.IndexOutOfBounds, get(&writeTransaction, root, M));
    writeTransaction.deinit();
}

test "Column.truncate to zero empties the column" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "coltrunc0.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    var index: u64 = 0;
    while (index < 1000) : (index += 1) root = try append(&writeTransaction, root, index);
    root = try truncate(&writeTransaction, root, 0);
    try testing.expectEqual(@as(u64, 0), try length(&writeTransaction, root));
    // Reclamation note: truncate frees every dropped node via transaction.free, which routes
    // them onto the transaction-private pool / committed free list (see WriteTransaction.free).
    // column.zig exposes no in-transaction free-list hook, so reclamation is covered by
    // that mechanism rather than asserted here.
    writeTransaction.deinit();
}

test "a column persisted as the root survives commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col6.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var root = try create(&writeTransaction);
        var index: u64 = 0;
        while (index < 2000) : (index += 1) root = try append(&writeTransaction, root, index * 3);
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, 2000), try length(&readTransaction, readTransaction.root()));
        try testing.expectEqual(@as(u64, 1999 * 3), try get(&readTransaction, readTransaction.root(), 1999));
        try testing.expectEqual(@as(u64, 0), try get(&readTransaction, readTransaction.root(), 0));
        try testing.expectEqual(@as(u64, 1000 * 3), try get(&readTransaction, readTransaction.root(), 1000));
        readTransaction.end();
    }
}

test "two million element column builds, persists, and reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col2m.airdb");
    defer testing.allocator.free(path);
    const N: u64 = 2_000_000; // 2x the 1M headline target
    const batch: u64 = 16384; // commit periodically so freed COW nodes are reclaimed between batches

    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        // Commit an empty column as the root first.
        var root: Reference = undefined;
        {
            var writeTransaction = try database.beginWrite();
            root = try create(&writeTransaction);
            writeTransaction.setRoot(root);
            _ = try writeTransaction.commit();
        }
        // Build in batches; value at index i is i.
        var version: u64 = 0;
        while (version < N) {
            var writeTransaction = try database.beginWrite();
            const end = @min(version + batch, N);
            while (version < end) : (version += 1) root = try append(&writeTransaction, root, version);
            writeTransaction.setRoot(root);
            _ = try writeTransaction.commit();
        }
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(N, try length(&readTransaction, readTransaction.root()));
        // Strided spot-checks across the whole 2M range: get(i) must equal i.
        var index: u64 = 0;
        while (index < N) : (index += 50_000) try testing.expectEqual(index, try get(&readTransaction, readTransaction.root(), index));
        try testing.expectEqual(@as(u64, 0), try get(&readTransaction, readTransaction.root(), 0));
        try testing.expectEqual(N - 1, try get(&readTransaction, readTransaction.root(), N - 1));
        try testing.expectError(error.IndexOutOfBounds, get(&readTransaction, readTransaction.root(), N));
        readTransaction.end();
    }
}

test "two million element column built in a single transaction" {
    // All 2M appends happen in ONE write transaction. In-transaction node reuse keeps the
    // file bounded to roughly the live working set (the copy-on-write spine garbage produced
    // by each append is private to the uncommitted transaction and reused immediately),
    // instead of accumulating gigabytes of unreclaimed garbage.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col2m1txn.airdb");
    defer testing.allocator.free(path);
    const N: u64 = 2_000_000;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var root = try create(&writeTransaction);
        var version: u64 = 0;
        while (version < N) : (version += 1) root = try append(&writeTransaction, root, version);
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(N, try length(&readTransaction, readTransaction.root()));
        var index: u64 = 0;
        while (index < N) : (index += 50_000) try testing.expectEqual(index, try get(&readTransaction, readTransaction.root(), index));
        try testing.expectEqual(N - 1, try get(&readTransaction, readTransaction.root(), N - 1));
        readTransaction.end();
    }
}

fn appendColVal(index: u64) u64 {
    return index *% 11 +% 5;
}

fn appendTmpDatabase(tmp: *testing.TmpDir, name: []const u8) !Database {
    const path = try colTmpPath(testing.allocator, tmp, name);
    defer testing.allocator.free(path);
    return Database.create(testing.allocator, path);
}

// Build a base column of `base` values via sequential append, append `run` more
// values via appendRun, and assert the result is logically identical to
// appending all base+run values sequentially: same length, and get(i) matches
// the sequential twin at every index.
fn checkColAppendEquiv(writeTransaction: *WriteTransaction, base: u64, run: u64) !void {
    var baseRoot = try create(writeTransaction);
    var key: u64 = 0;
    while (key < base) : (key += 1) baseRoot = try append(writeTransaction, baseRoot, appendColVal(key));

    const runValues = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(runValues);
    var runIndex: u64 = 0;
    while (runIndex < run) : (runIndex += 1) runValues[runIndex] = appendColVal(base + runIndex);

    const appended = try appendRun(writeTransaction, baseRoot, runValues, testing.allocator);

    var expected = try create(writeTransaction);
    key = 0;
    while (key < base + run) : (key += 1) expected = try append(writeTransaction, expected, appendColVal(key));

    const total = base + run;
    try testing.expectEqual(total, try length(writeTransaction, appended));
    try testing.expectEqual(try length(writeTransaction, expected), try length(writeTransaction, appended));

    var index: u64 = 0;
    while (index < total) : (index += 1) {
        try testing.expectEqual(try get(writeTransaction, expected, index), try get(writeTransaction, appended, index));
    }
    if (total > 0) try testing.expectError(error.IndexOutOfBounds, get(writeTransaction, appended, total));
}

test "appendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "colappend1.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkColAppendEquiv(&writeTransaction, 100, 200); // 100 % 64 == 36 in the last leaf
    writeTransaction.deinit();
}

test "appendRun grows height" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "colappend2.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // Single-leaf base, run crossing fanout*leafCap (== 4096) so the result
    // must be three levels tall.
    try checkColAppendEquiv(&writeTransaction, 50, 4200);
    writeTransaction.deinit();
}

test "appendRun single-leaf base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "colappend3.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkColAppendEquiv(&writeTransaction, 40, 50); // base < leafCap
    writeTransaction.deinit();
}

test "appendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "colappend4.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkColAppendEquiv(&writeTransaction, 10, 5000);
    writeTransaction.deinit();
}

test "appendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "colappend5.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var baseRoot = try create(&writeTransaction);
    var key: u64 = 0;
    while (key < 100) : (key += 1) baseRoot = try append(&writeTransaction, baseRoot, appendColVal(key));
    const before = try length(&writeTransaction, baseRoot);
    const appended = try appendRun(&writeTransaction, baseRoot, &.{}, testing.allocator);
    try testing.expectEqual(baseRoot, appended); // same ref, unchanged
    try testing.expectEqual(before, try length(&writeTransaction, appended));
    writeTransaction.deinit();
}
