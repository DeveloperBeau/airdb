const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const node = @import("column_node.zig");

// Local aliases for the on-disk node format, which lives in column_node.zig.
const LEAF_CAP = node.LEAF_CAP;
const FANOUT = node.FANOUT;
const kind_leaf = node.kind_leaf;
const kind_inner = node.kind_inner;
const leaf_node_size = node.leaf_node_size;
const leaf_header = node.leaf_header;
const inner_node_size = node.inner_node_size;
const inner_header = node.inner_header;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const LeafView = node.LeafView;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const InnerView = node.InnerView;

// ---------------------------------------------------------------------------
// Column operations (Tasks 2-3)
// Task 4 will add leaf splitting.
// ---------------------------------------------------------------------------

/// Allocate an empty leaf column node and return its Ref.
pub fn create(txn: *WriteTxn) !Ref {
    const a = try txn.alloc(leaf_node_size);
    _ = encodeLeaf(a.bytes, &.{});
    return a.ref;
}

/// Deref a node by first reading its kind byte, then dereffing the full node.
fn derefNode(txn: anytype, ref: Ref) ![]const u8 {
    const kind_buf = try txn.deref(ref, 1);
    return switch (kind_buf[0]) {
        kind_leaf => txn.deref(ref, leaf_node_size),
        kind_inner => txn.deref(ref, inner_node_size),
        else => error.Corrupt,
    };
}

/// Return the number of values stored in the column rooted at root.
pub fn len(txn: anytype, root: Ref) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        return count;
    } else {
        const view = try parseInner(bytes);
        var total: u64 = 0;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            total += view.childCount(i);
        }
        return total;
    }
}

/// Return the value at index. Returns error.IndexOutOfBounds if out of range.
pub fn get(txn: anytype, root: Ref, index: u64) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const idx: usize = @intCast(index);
        const off: usize = leaf_header + idx * 8;
        return std.mem.readInt(u64, bytes[off..][0..8], .little);
    } else {
        const view = try parseInner(bytes);
        var idx = index;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            const cc = view.childCount(i);
            if (idx < cc) return get(txn, view.childRef(i), idx);
            idx -= cc;
        }
        return error.IndexOutOfBounds;
    }
}

const AppendResult = struct { ref: Ref, count: u64, split: ?Ref, split_count: u64 };

fn appendInto(txn: *WriteTxn, node_ref: Ref, value: u64) !AppendResult {
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (count < LEAF_CAP) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            std.mem.writeInt(u16, a.bytes[1..3], count + 1, .little);
            const off: usize = leaf_header + @as(usize, count) * 8;
            std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
            return .{ .ref = a.ref, .count = @as(u64, count) + 1, .split = null, .split_count = 0 };
        } else {
            // Full leaf: allocate a new leaf for the new value; leave the old leaf untouched.
            const a = try txn.alloc(leaf_node_size);
            _ = encodeLeaf(a.bytes, &.{value});
            return .{ .ref = node_ref, .count = LEAF_CAP, .split = a.ref, .split_count = 1 };
        }
    } else {
        const view = try parseInner(bytes);
        const child_count = view.child_count;
        const last_idx: usize = @as(usize, child_count) - 1;
        const last_ref = view.childRef(last_idx);
        // Capture old totals before recursion (bytes stay valid: mmap grows in place).
        var old_total: u64 = 0;
        {
            var i: usize = 0;
            while (i < child_count) : (i += 1) old_total += view.childCount(i);
        }
        const old_last_count = view.childCount(last_idx);
        const r = try appendInto(txn, last_ref, value);
        // COW the inner node and update the last child entry.
        const a = try txn.writableCopy(node_ref, inner_node_size);
        const last_off: usize = inner_header + last_idx * 16;
        std.mem.writeInt(u64, a.bytes[last_off..][0..8], r.ref, .little);
        std.mem.writeInt(u64, a.bytes[last_off + 8 ..][0..8], r.count, .little);
        if (r.split == null) {
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count, .split = null, .split_count = 0 };
        } else if (child_count < FANOUT) {
            // Room in this inner: append the new child.
            const new_off: usize = inner_header + @as(usize, child_count) * 16;
            std.mem.writeInt(u16, a.bytes[1..3], child_count + 1, .little);
            const split_ref = r.split.?;
            std.mem.writeInt(u64, a.bytes[new_off..][0..8], split_ref, .little);
            std.mem.writeInt(u64, a.bytes[new_off + 8 ..][0..8], r.split_count, .little);
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count + r.split_count, .split = null, .split_count = 0 };
        } else {
            // Inner full: create a new right inner holding just the split child.
            const new_inner = try txn.alloc(inner_node_size);
            const split_ref = r.split.?;
            _ = encodeInner(new_inner.bytes, &.{split_ref}, &.{r.split_count});
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count, .split = new_inner.ref, .split_count = r.split_count };
        }
    }
}

/// Append value to the column. Returns the new root Ref (copy-on-write).
/// Grows the tree through leaf splits and height increases as needed.
pub fn append(txn: *WriteTxn, root: Ref, value: u64) !Ref {
    const r = try appendInto(txn, root, value);
    if (r.split == null) return r.ref;
    // Split propagated to the root: grow height by one.
    const a = try txn.alloc(inner_node_size);
    const split_ref = r.split.?;
    _ = encodeInner(a.bytes, &.{ r.ref, split_ref }, &.{ r.count, r.split_count });
    return a.ref;
}

/// Recursive copy-on-write set: copies only the nodes on the path from root to
/// the target leaf. Sibling subtrees are shared by reference, so the old root
/// remains a valid, unchanged snapshot after the call returns.
fn setInto(txn: *WriteTxn, node_ref: Ref, index: u64, value: u64) !Ref {
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const a = try txn.writableCopy(node_ref, leaf_node_size);
        const idx: usize = @intCast(index);
        const off: usize = leaf_header + idx * 8;
        std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
        return a.ref;
    } else {
        const view = try parseInner(bytes);
        var idx = index;
        var target_i: u16 = 0;
        var local_index: u64 = 0;
        var found = false;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            const cc = view.childCount(i);
            if (idx < cc) {
                target_i = i;
                local_index = idx;
                found = true;
                break;
            }
            idx -= cc;
        }
        if (!found) return error.IndexOutOfBounds;
        // Capture the child ref before the recursive call (bytes may alias mmap).
        const child_ref = view.childRef(target_i);
        const new_child = try setInto(txn, child_ref, local_index, value);
        // COW this inner node and patch only the updated child's ref (count unchanged).
        const a = try txn.writableCopy(node_ref, inner_node_size);
        const off: usize = inner_header + @as(usize, target_i) * 16;
        std.mem.writeInt(u64, a.bytes[off..][0..8], new_child, .little);
        return a.ref;
    }
}

/// Overwrite the value at index. Returns the new root Ref (copy-on-write).
/// Returns error.IndexOutOfBounds if out of range. Works on trees of any depth.
pub fn set(txn: *WriteTxn, root: Ref, index: u64, value: u64) !Ref {
    return setInto(txn, root, index, value);
}

/// Test-only helper: allocate an inner node over the given children and return its Ref.
pub fn makeInnerForTest(txn: *WriteTxn, children: []const struct { ref: u64, count: u64 }) !Ref {
    std.debug.assert(children.len <= FANOUT);
    var refs: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    for (children, 0..) |c, i| {
        refs[i] = c.ref;
        counts[i] = c.count;
    }
    const a = try txn.alloc(inner_node_size);
    _ = encodeInner(a.bytes, refs[0..children.len], counts[0..children.len]);
    return a.ref;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;

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
