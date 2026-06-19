const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;

pub const LEAF_CAP: u16 = 64;
pub const FANOUT: u16 = 64;
const kind_leaf: u8 = 0;
const kind_inner: u8 = 1;
const hdr: usize = 3; // [kind u8][count u16]
pub const leaf_node_size: usize = hdr + @as(usize, LEAF_CAP) * 16; // (key,value)
pub const inner_node_size: usize = hdr + @as(usize, FANOUT) * 16; // (child_ref,low_key)

pub fn encodeLeaf(buf: []u8, keys: []const u64, vals: []const u64) usize {
    std.debug.assert(keys.len == vals.len and keys.len <= LEAF_CAP);
    buf[0] = kind_leaf;
    std.mem.writeInt(u16, buf[1..3], @intCast(keys.len), .little);
    var off: usize = hdr;
    for (keys, vals) |k, v| {
        std.mem.writeInt(u64, buf[off..][0..8], k, .little);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], v, .little);
        off += 16;
    }
    return off;
}

pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    pub fn key(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 ..][0..8], .little);
    }
    pub fn value(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 + 8 ..][0..8], .little);
    }
    pub fn lowerBound(self: LeafView, k: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.key(mid) < k) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < hdr) return error.Corrupt;
    if (bytes[0] != kind_leaf) return error.Corrupt;
    const leaf_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (leaf_count > LEAF_CAP) return error.Corrupt;
    if (bytes.len < hdr + @as(usize, leaf_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = leaf_count };
}

test "leaf encode/decode round-trips sorted pairs" {
    var buf: [leaf_node_size]u8 = undefined;
    const keys = [_]u64{ 1, 5, 9 };
    const vals = [_]u64{ 10, 50, 90 };
    const n = encodeLeaf(&buf, &keys, &vals);
    const v = try parseLeaf(buf[0..n]);
    try std.testing.expectEqual(@as(u16, 3), v.count);
    try std.testing.expectEqual(@as(u64, 5), v.key(1));
    try std.testing.expectEqual(@as(u64, 90), v.value(2));
}

test "lowerBound finds the first index whose key is >= the search key" {
    var buf: [leaf_node_size]u8 = undefined;
    const keys = [_]u64{ 2, 4, 6, 8 };
    const vals = [_]u64{ 0, 0, 0, 0 };
    const n = encodeLeaf(&buf, &keys, &vals);
    const v = try parseLeaf(buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), v.lowerBound(1));
    try std.testing.expectEqual(@as(usize, 1), v.lowerBound(4));
    try std.testing.expectEqual(@as(usize, 2), v.lowerBound(5));
    try std.testing.expectEqual(@as(usize, 4), v.lowerBound(9));
}

// ---------------------------------------------------------------------------
// Index operations
// ---------------------------------------------------------------------------

/// Create a new empty leaf node and return its Ref.
pub fn create(txn: *WriteTxn) !Ref {
    const a = try txn.alloc(leaf_node_size);
    _ = encodeLeaf(a.bytes, &.{}, &.{});
    return a.ref;
}

/// Return the kind byte (kind_leaf or kind_inner) of the node at ref.
fn nodeKind(txn: anytype, ref: Ref) !u8 {
    const bytes = try txn.deref(ref, 1);
    return bytes[0];
}

/// Look up key in the tree rooted at root. Returns the associated value or null.
pub fn get(txn: anytype, root: Ref, key: u64) !?u64 {
    const k = try nodeKind(txn, root);
    if (k == kind_leaf) {
        const bytes = try txn.deref(root, leaf_node_size);
        const v = try parseLeaf(bytes);
        const i = v.lowerBound(key);
        if (i < v.count and v.key(i) == key) return v.value(i);
        return null;
    }
    // Inner node handling: Task 3.
    return error.Unimplemented;
}

/// Insert or update key->val in the tree rooted at root.
/// Returns the (possibly new) root Ref.
pub fn insert(txn: *WriteTxn, root: Ref, key: u64, val: u64) !Ref {
    const k = try nodeKind(txn, root);
    if (k == kind_leaf) {
        const old_bytes = try txn.deref(root, leaf_node_size);
        const v = try parseLeaf(old_bytes);
        const i = v.lowerBound(key);
        if (i < v.count and v.key(i) == key) {
            // Upsert: overwrite existing value in place via a writable copy.
            const a = try txn.writableCopy(root, leaf_node_size);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            return a.ref;
        }
        // New key: leaf must not be full (split is Task 4).
        if (v.count >= LEAF_CAP) return error.LeafFull;
        const a = try txn.writableCopy(root, leaf_node_size);
        // Shift slots [i, count) right by one to make room at slot i.
        // Iterate from the end backward to avoid clobbering data.
        var j: usize = v.count;
        while (j > i) : (j -= 1) {
            const src = hdr + (j - 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
        }
        // Write (key, val) at slot i.
        std.mem.writeInt(u64, a.bytes[hdr + i * 16 ..][0..8], key, .little);
        std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
        // Update count.
        std.mem.writeInt(u16, a.bytes[1..3], v.count + 1, .little);
        return a.ref;
    }
    // Inner node handling: Task 3.
    return error.Unimplemented;
}

/// Remove key from the tree rooted at root.
/// Returns the (possibly new) root Ref. No-op if key is absent.
pub fn remove(txn: *WriteTxn, root: Ref, key: u64) !Ref {
    const k = try nodeKind(txn, root);
    if (k == kind_leaf) {
        const old_bytes = try txn.deref(root, leaf_node_size);
        const v = try parseLeaf(old_bytes);
        const i = v.lowerBound(key);
        if (!(i < v.count and v.key(i) == key)) return root; // no-op
        const a = try txn.writableCopy(root, leaf_node_size);
        // Shift slots (i, count) left by one, overwriting slot i.
        var j: usize = i;
        while (j + 1 < v.count) : (j += 1) {
            const src = hdr + (j + 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
        }
        // Update count.
        std.mem.writeInt(u16, a.bytes[1..3], v.count - 1, .little);
        return a.ref;
    }
    // Inner node handling: Task 3.
    return error.Unimplemented;
}

/// Return the number of keys in the tree rooted at root.
pub fn count(txn: anytype, root: Ref) !u64 {
    const k = try nodeKind(txn, root);
    if (k == kind_leaf) {
        const bytes = try txn.deref(root, leaf_node_size);
        const v = try parseLeaf(bytes);
        return v.count;
    }
    // Inner node handling: Task 3.
    return error.Unimplemented;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Db = @import("db.zig").Db;

fn idxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "single-leaf index: insert, get, upsert, remove, count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    try testing.expect((try get(&w, root, 5)) == null);
    root = try insert(&w, root, 5, 50);
    root = try insert(&w, root, 1, 10);
    root = try insert(&w, root, 9, 90);
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    try testing.expectEqual(@as(?u64, 50), try get(&w, root, 5));
    try testing.expectEqual(@as(?u64, 10), try get(&w, root, 1));
    root = try insert(&w, root, 5, 555);
    try testing.expectEqual(@as(?u64, 555), try get(&w, root, 5));
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    root = try remove(&w, root, 1);
    try testing.expect((try get(&w, root, 1)) == null);
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    w.deinit();
}
