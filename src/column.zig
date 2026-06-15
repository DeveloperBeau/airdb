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

// ---------------------------------------------------------------------------
// Single-leaf column operations (Task 2)
// Task 3 will add inner-node dispatch; Task 4 will add leaf splitting.
// ---------------------------------------------------------------------------

/// Allocate an empty leaf column node and return its Ref.
pub fn create(txn: *WriteTxn) !Ref {
    const a = try txn.alloc(leaf_node_size);
    _ = encodeLeaf(a.bytes, &.{});
    return a.ref;
}

/// Return the kind byte for the node at ref (used by Task 3 for inner-node dispatch).
fn nodeKind(txn: anytype, ref: Ref) !u8 {
    const b = try txn.deref(ref, 1);
    return b[0];
}

/// Return the number of values stored in the column rooted at root.
pub fn len(txn: anytype, root: Ref) !u64 {
    const hdr = try txn.deref(root, leaf_header);
    const count = std.mem.readInt(u16, hdr[1..3], .little);
    return count;
}

/// Return the value at index. Returns error.IndexOutOfBounds if out of range.
pub fn get(txn: anytype, root: Ref, index: u64) !u64 {
    const hdr = try txn.deref(root, leaf_header);
    const count = std.mem.readInt(u16, hdr[1..3], .little);
    if (index >= count) return error.IndexOutOfBounds;
    const idx: usize = @intCast(index);
    const off: usize = leaf_header + idx * 8;
    const bytes = try txn.deref(root, off + 8);
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
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
