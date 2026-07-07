const std = @import("std");
const Column = @import("column.zig");
const node = @import("columnNode.zig");
const Ref = @import("reference.zig").Ref;
const create = Column.create;
const len = Column.len;
const get = Column.get;
const append = Column.append;
const appendRun = Column.appendRun;
const set = Column.set;
const truncate = Column.truncate;
const makeInnerForTest = Column.makeInnerForTest;
const leaf_node_size = node.leaf_node_size;
const inner_node_size = node.inner_node_size;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const encodeInner = node.encodeInner;

const testing = std.testing;

const Db = @import("database.zig").Db;
const WriteTxn = @import("database.zig").WriteTxn;

fn colTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "leaf encode/decode round-trips values" {
    var buf: [leaf_node_size]u8 = undefined;
    const vals = [_]u64{ 10, 20, 30 };
    const n = encodeLeaf(&buf, &vals);
    const view = try parseLeaf(buf[0..n]);
    try testing.expectEqual(@as(u16, 3), view.count);
    try testing.expectEqual(@as(u64, 20), view.value(1));
}

test "parseLeaf rejects a buffer too small for its declared count" {
    var buf: [16]u8 = undefined;
    buf[0] = 0; // kind = leaf
    std.mem.writeInt(u16, buf[1..3], 100, .little); // claims 100 values
    try testing.expectError(error.Corrupt, parseLeaf(buf[0..16]));
}

test "a column ref cycle fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col_cycle.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    // Inner node whose only child is itself with a nonzero claimed count:
    // get/set/append must hit the depth cap, not overflow the stack.
    const a = try w.alloc(inner_node_size);
    _ = encodeInner(a.bytes, &.{a.ref}, &.{10});
    try testing.expectError(error.Corrupt, get(&w, a.ref, 0));
    try testing.expectError(error.Corrupt, set(&w, a.ref, 0, 1));
    try testing.expectError(error.Corrupt, append(&w, a.ref, 1));
}

test "single-leaf column: create, append, get, len, set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    try testing.expectEqual(@as(u64, 0), try len(&w, root));
    root = try append(&w, root, 100);
    root = try append(&w, root, 200);
    root = try append(&w, root, 300);
    try testing.expectEqual(@as(u64, 3), try len(&w, root));
    try testing.expectEqual(@as(u64, 200), try get(&w, root, 1));
    root = try set(&w, root, 1, 222);
    try testing.expectEqual(@as(u64, 222), try get(&w, root, 1));
    try testing.expectError(error.IndexOutOfBounds, get(&w, root, 3));
    w.deinit();
}

test "append grows the tree across many leaves and reads back correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    const N: u64 = 5000; // > LEAF_CAP and > LEAF_CAP*FANOUT (4096): forces >= 3 levels
    var i: u64 = 0;
    while (i < N) : (i += 1) root = try append(&w, root, i * 7);
    try testing.expectEqual(N, try len(&w, root));
    try testing.expectEqual(@as(u64, 0), try get(&w, root, 0));
    try testing.expectEqual(@as(u64, 4999 * 7), try get(&w, root, 4999));
    try testing.expectEqual(@as(u64, 2500 * 7), try get(&w, root, 2500));
    // spot-check several indices
    var k: u64 = 0;
    while (k < N) : (k += 137) try testing.expectEqual(k * 7, try get(&w, root, k));
    w.deinit();
}

test "get and len traverse an inner node over two leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var l0 = try create(&w);
    l0 = try append(&w, l0, 0);
    l0 = try append(&w, l0, 1);
    var l1 = try create(&w);
    l1 = try append(&w, l1, 2);
    l1 = try append(&w, l1, 3);
    const inner = try makeInnerForTest(&w, &.{ .{ .ref = l0, .count = 2 }, .{ .ref = l1, .count = 2 } });
    try testing.expectEqual(@as(u64, 4), try len(&w, inner));
    try testing.expectEqual(@as(u64, 0), try get(&w, inner, 0));
    try testing.expectEqual(@as(u64, 2), try get(&w, inner, 2));
    try testing.expectEqual(@as(u64, 3), try get(&w, inner, 3));
    try testing.expectError(error.IndexOutOfBounds, get(&w, inner, 4));
    w.deinit();
}

test "set on a multi-level column leaves the old root snapshot unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) root = try append(&w, root, i);
    const old_root = root;
    const new_root = try set(&w, root, 500, 999999);
    try testing.expectEqual(@as(u64, 500), try get(&w, old_root, 500)); // old snapshot unchanged
    try testing.expectEqual(@as(u64, 999999), try get(&w, new_root, 500)); // new root updated
    try testing.expectEqual(try len(&w, old_root), try len(&w, new_root));
    // a few other indices match between old and new (shared subtrees)
    try testing.expectEqual(try get(&w, old_root, 0), try get(&w, new_root, 0));
    try testing.expectEqual(try get(&w, old_root, 999), try get(&w, new_root, 999));
    w.deinit();
}

test "Column.truncate shrinks length and preserves head values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "coltrunc1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    const N: u64 = 1000;
    var i: u64 = 0;
    while (i < N) : (i += 1) root = try append(&w, root, i * 7);
    const M: u64 = 300;
    root = try truncate(&w, root, M);
    try testing.expectEqual(M, try len(&w, root));
    var k: u64 = 0;
    while (k < M) : (k += 1) try testing.expectEqual(k * 7, try get(&w, root, k));
    try testing.expectError(error.IndexOutOfBounds, get(&w, root, M));
    w.deinit();
}

test "Column.truncate to zero empties the column" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "coltrunc0.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    var i: u64 = 0;
    while (i < 1000) : (i += 1) root = try append(&w, root, i);
    root = try truncate(&w, root, 0);
    try testing.expectEqual(@as(u64, 0), try len(&w, root));
    // Reclamation note: truncate frees every dropped node via txn.free, which routes
    // them onto the transaction-private pool / committed free list (see WriteTxn.free).
    // column.zig exposes no in-transaction free-list hook, so reclamation is covered by
    // that mechanism rather than asserted here.
    w.deinit();
}

test "a column persisted as the root survives commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try colTmpPath(testing.allocator, &tmp, "col6.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var root = try create(&w);
        var i: u64 = 0;
        while (i < 2000) : (i += 1) root = try append(&w, root, i * 3);
        w.setRoot(root);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 2000), try len(&r, r.root()));
        try testing.expectEqual(@as(u64, 1999 * 3), try get(&r, r.root(), 1999));
        try testing.expectEqual(@as(u64, 0), try get(&r, r.root(), 0));
        try testing.expectEqual(@as(u64, 1000 * 3), try get(&r, r.root(), 1000));
        r.end();
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
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        // Commit an empty column as the root first.
        var root: Ref = undefined;
        {
            var w = try db.beginWrite();
            root = try create(&w);
            w.setRoot(root);
            _ = try w.commit();
        }
        // Build in batches; value at index i is i.
        var v: u64 = 0;
        while (v < N) {
            var w = try db.beginWrite();
            const end = @min(v + batch, N);
            while (v < end) : (v += 1) root = try append(&w, root, v);
            w.setRoot(root);
            _ = try w.commit();
        }
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(N, try len(&r, r.root()));
        // Strided spot-checks across the whole 2M range: get(i) must equal i.
        var i: u64 = 0;
        while (i < N) : (i += 50_000) try testing.expectEqual(i, try get(&r, r.root(), i));
        try testing.expectEqual(@as(u64, 0), try get(&r, r.root(), 0));
        try testing.expectEqual(N - 1, try get(&r, r.root(), N - 1));
        try testing.expectError(error.IndexOutOfBounds, get(&r, r.root(), N));
        r.end();
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
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var root = try create(&w);
        var v: u64 = 0;
        while (v < N) : (v += 1) root = try append(&w, root, v);
        w.setRoot(root);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(N, try len(&r, r.root()));
        var i: u64 = 0;
        while (i < N) : (i += 50_000) try testing.expectEqual(i, try get(&r, r.root(), i));
        try testing.expectEqual(N - 1, try get(&r, r.root(), N - 1));
        r.end();
    }
}

fn appendColVal(i: u64) u64 {
    return i *% 11 +% 5;
}

fn appendTmpDb(tmp: *testing.TmpDir, name: []const u8) !Db {
    const path = try colTmpPath(testing.allocator, tmp, name);
    defer testing.allocator.free(path);
    return Db.create(testing.allocator, path);
}

// Build a base column of `base` values via sequential append, append `run` more
// values via appendRun, and assert the result is logically identical to
// appending all base+run values sequentially: same length, and get(i) matches
// the sequential twin at every index.
fn checkColAppendEquiv(w: *WriteTxn, base: u64, run: u64) !void {
    var base_root = try create(w);
    var k: u64 = 0;
    while (k < base) : (k += 1) base_root = try append(w, base_root, appendColVal(k));

    const rv = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rv);
    var r: u64 = 0;
    while (r < run) : (r += 1) rv[r] = appendColVal(base + r);

    const appended = try appendRun(w, base_root, rv, testing.allocator);

    var expected = try create(w);
    k = 0;
    while (k < base + run) : (k += 1) expected = try append(w, expected, appendColVal(k));

    const total = base + run;
    try testing.expectEqual(total, try len(w, appended));
    try testing.expectEqual(try len(w, expected), try len(w, appended));

    var i: u64 = 0;
    while (i < total) : (i += 1) {
        try testing.expectEqual(try get(w, expected, i), try get(w, appended, i));
    }
    if (total > 0) try testing.expectError(error.IndexOutOfBounds, get(w, appended, total));
}

test "appendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend1.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 100, 200); // 100 % 64 == 36 in the last leaf
    w.deinit();
}

test "appendRun grows height" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend2.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    // Single-leaf base, run crossing FANOUT*LEAF_CAP (== 4096) so the result
    // must be three levels tall.
    try checkColAppendEquiv(&w, 50, 4200);
    w.deinit();
}

test "appendRun single-leaf base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend3.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 40, 50); // base < LEAF_CAP
    w.deinit();
}

test "appendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend4.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 10, 5000);
    w.deinit();
}

test "appendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend5.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    var base_root = try create(&w);
    var k: u64 = 0;
    while (k < 100) : (k += 1) base_root = try append(&w, base_root, appendColVal(k));
    const before = try len(&w, base_root);
    const appended = try appendRun(&w, base_root, &.{}, testing.allocator);
    try testing.expectEqual(base_root, appended); // same ref, unchanged
    try testing.expectEqual(before, try len(&w, appended));
    w.deinit();
}
