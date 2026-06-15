const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;

pub const LEAF_CAP: u16 = 64;
pub const FANOUT: u16 = 64;
const kind_leaf: u8 = 0;
const kind_inner: u8 = 1;

// Leaf layout: [kind u8][count u16 LE][count * u64 LE]
pub const leaf_node_size: usize = 1 + 2 + @as(usize, LEAF_CAP) * 8;
const leaf_header: usize = 3;

// Inner layout: [kind u8][child_count u16 LE][child_count * (child_ref u64 LE, subtree_count u64 LE)]
pub const inner_node_size: usize = 1 + 2 + @as(usize, FANOUT) * 16;
const inner_header: usize = 3;

pub fn encodeLeaf(buf: []u8, values: []const u64) usize {
    std.debug.assert(values.len <= LEAF_CAP);
    buf[0] = kind_leaf;
    std.mem.writeInt(u16, buf[1..3], @intCast(values.len), .little);
    var off: usize = leaf_header;
    for (values) |v| {
        std.mem.writeInt(u64, buf[off..][0..8], v, .little);
        off += 8;
    }
    return off;
}

pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    pub fn value(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[leaf_header + i * 8 ..][0..8], .little);
    }
};

pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < leaf_header) return error.Corrupt;
    if (bytes[0] != kind_leaf) return error.Corrupt;
    const count = std.mem.readInt(u16, bytes[1..3], .little);
    if (count > LEAF_CAP) return error.Corrupt;
    if (bytes.len < leaf_header + @as(usize, count) * 8) return error.Corrupt;
    return .{ .bytes = bytes, .count = count };
}

pub fn encodeInner(buf: []u8, child_refs: []const u64, child_counts: []const u64) usize {
    std.debug.assert(child_refs.len == child_counts.len);
    std.debug.assert(child_refs.len <= FANOUT);
    buf[0] = kind_inner;
    std.mem.writeInt(u16, buf[1..3], @intCast(child_refs.len), .little);
    var off: usize = inner_header;
    for (child_refs, child_counts) |r, c| {
        std.mem.writeInt(u64, buf[off..][0..8], r, .little);
        off += 8;
        std.mem.writeInt(u64, buf[off..][0..8], c, .little);
        off += 8;
    }
    return off;
}

pub const InnerView = struct {
    bytes: []const u8,
    child_count: u16,
    pub fn childRef(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[inner_header + i * 16 ..][0..8], .little);
    }
    pub fn childCount(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[inner_header + i * 16 + 8 ..][0..8], .little);
    }
};

pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < inner_header) return error.Corrupt;
    if (bytes[0] != kind_inner) return error.Corrupt;
    const child_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (child_count > FANOUT) return error.Corrupt;
    if (bytes.len < inner_header + @as(usize, child_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .child_count = child_count };
}

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

/// Append value to the column. Returns the new root Ref (copy-on-write).
/// Returns error.LeafFull when the leaf is at capacity; Task 4 handles splitting.
pub fn append(txn: *WriteTxn, root: Ref, value: u64) !Ref {
    const hdr = try txn.deref(root, leaf_header);
    const count = std.mem.readInt(u16, hdr[1..3], .little);
    if (count >= LEAF_CAP) return error.LeafFull;
    const a = try txn.writableCopy(root, leaf_node_size);
    std.mem.writeInt(u16, a.bytes[1..3], count + 1, .little);
    const off: usize = leaf_header + @as(usize, count) * 8;
    std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
    return a.ref;
}

/// Overwrite the value at index. Returns the new root Ref (copy-on-write).
/// Returns error.IndexOutOfBounds if out of range.
pub fn set(txn: *WriteTxn, root: Ref, index: u64, value: u64) !Ref {
    const hdr = try txn.deref(root, leaf_header);
    const count = std.mem.readInt(u16, hdr[1..3], .little);
    if (index >= count) return error.IndexOutOfBounds;
    const a = try txn.writableCopy(root, leaf_node_size);
    const idx: usize = @intCast(index);
    const off: usize = leaf_header + idx * 8;
    std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
    return a.ref;
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
