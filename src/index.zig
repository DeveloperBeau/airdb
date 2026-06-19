const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Allocation = @import("arena.zig").Allocation;

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

// ---------------------------------------------------------------------------
// Inner-node encoding
// ---------------------------------------------------------------------------

pub fn encodeInner(buf: []u8, refs: []const u64, lows: []const u64) usize {
    std.debug.assert(refs.len == lows.len and refs.len <= FANOUT);
    buf[0] = kind_inner;
    std.mem.writeInt(u16, buf[1..3], @intCast(refs.len), .little);
    var off: usize = hdr;
    for (refs, lows) |r, l| {
        std.mem.writeInt(u64, buf[off..][0..8], r, .little);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], l, .little);
        off += 16;
    }
    return off;
}

pub const InnerView = struct {
    bytes: []const u8,
    child_count: u16,
    pub fn childRef(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 ..][0..8], .little);
    }
    pub fn lowKey(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 + 8 ..][0..8], .little);
    }
};

pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < hdr) return error.Corrupt;
    if (bytes[0] != kind_inner) return error.Corrupt;
    const child_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (child_count > FANOUT) return error.Corrupt;
    if (bytes.len < hdr + @as(usize, child_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .child_count = child_count };
}

fn childIndexForKey(v: InnerView, k: u64) usize {
    // Return the largest i with lowKey(i) <= k; fall back to 0 if k < lowKey(0).
    var best: usize = 0;
    var i: usize = 0;
    while (i < v.child_count) : (i += 1) {
        if (v.lowKey(i) <= k) {
            best = i;
        } else {
            break;
        }
    }
    return best;
}

/// Allocate a fresh node and copy the bytes of ref into it WITHOUT freeing ref.
/// Use this everywhere instead of txn.writableCopy so that an old Ref remains
/// a valid, readable snapshot after the copy is made.
fn cowCopy(txn: *WriteTxn, ref: Ref, len: usize) !Allocation {
    const old = try txn.deref(ref, len);
    const fresh = try txn.alloc(len);
    @memcpy(fresh.bytes, old);
    return fresh;
}

fn derefNode(txn: anytype, ref: Ref) ![]const u8 {
    const kind_bytes = try txn.deref(ref, 1);
    const kind = kind_bytes[0];
    if (kind == kind_leaf) {
        return txn.deref(ref, leaf_node_size);
    } else {
        return txn.deref(ref, inner_node_size);
    }
}

// Test-only helper: build an inner node from a slice of (ref, low) pairs.
pub fn makeInnerForTest(txn: *WriteTxn, children: []const struct { ref: u64, low: u64 }) !Ref {
    var refs: [FANOUT]u64 = undefined;
    var lows: [FANOUT]u64 = undefined;
    for (children, 0..) |c, i| {
        refs[i] = c.ref;
        lows[i] = c.low;
    }
    const a = try txn.alloc(inner_node_size);
    _ = encodeInner(a.bytes, refs[0..children.len], lows[0..children.len]);
    return a.ref;
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
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        const i = v.lowerBound(key);
        if (i < v.count and v.key(i) == key) return v.value(i);
        return null;
    }
    // Inner node: descend into the appropriate child.
    const v = try parseInner(bytes);
    const ci = childIndexForKey(v, key);
    const child_ref: Ref = v.childRef(ci);
    return get(txn, child_ref, key);
}

// ---------------------------------------------------------------------------
// B+tree insert with leaf/inner split and height growth (Task 4)
// ---------------------------------------------------------------------------

const Split = struct { ref: Ref, low: u64 };
const InsertResult = struct { ref: Ref, split: ?Split };

/// Descend the leftmost spine to the leftmost leaf and return its first key.
fn minKey(txn: anytype, ref: Ref) !u64 {
    const bytes = try derefNode(txn, ref);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        return v.key(0);
    }
    const v = try parseInner(bytes);
    return minKey(txn, v.childRef(0));
}

/// Recursive insert. Returns the (possibly new) node ref and an optional right
/// sibling produced by a midpoint split.
fn insertInto(txn: *WriteTxn, node_ref: Ref, key: u64, val: u64) !InsertResult {
    const node_bytes = try txn.deref(node_ref, 1);
    const kind = node_bytes[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = v.lowerBound(key);

        // Upsert: key already present.
        if (i < v.count and v.key(i) == key) {
            const a = try cowCopy(txn, node_ref, leaf_node_size);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            return InsertResult{ .ref = a.ref, .split = null };
        }

        // Not full: shift and insert.
        if (v.count < LEAF_CAP) {
            const a = try cowCopy(txn, node_ref, leaf_node_size);
            var j: usize = v.count;
            while (j > i) : (j -= 1) {
                const src = hdr + (j - 1) * 16;
                const dst = hdr + j * 16;
                @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
            }
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 ..][0..8], key, .little);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            std.mem.writeInt(u16, a.bytes[1..3], v.count + 1, .little);
            return InsertResult{ .ref = a.ref, .split = null };
        }

        // Full: build LEAF_CAP+1 sorted pairs, split at midpoint.
        const total_leaf: usize = @as(usize, LEAF_CAP) + 1;
        var keys_buf: [LEAF_CAP + 1]u64 = undefined;
        var vals_buf: [LEAF_CAP + 1]u64 = undefined;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            keys_buf[j] = v.key(j);
            vals_buf[j] = v.value(j);
        }
        keys_buf[i] = key;
        vals_buf[i] = val;
        j = i;
        while (j < v.count) : (j += 1) {
            keys_buf[j + 1] = v.key(j);
            vals_buf[j + 1] = v.value(j);
        }
        // Build buffer from v before cowCopy to avoid any aliasing concern.
        const m_leaf: usize = total_leaf / 2;
        const left_a = try cowCopy(txn, node_ref, leaf_node_size);
        std.mem.writeInt(u16, left_a.bytes[1..3], @intCast(m_leaf), .little);
        j = 0;
        while (j < m_leaf) : (j += 1) {
            std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 ..][0..8], keys_buf[j], .little);
            std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 + 8 ..][0..8], vals_buf[j], .little);
        }
        const right_a = try txn.alloc(leaf_node_size);
        _ = encodeLeaf(right_a.bytes, keys_buf[m_leaf..total_leaf], vals_buf[m_leaf..total_leaf]);
        return InsertResult{ .ref = left_a.ref, .split = Split{ .ref = right_a.ref, .low = keys_buf[m_leaf] } };
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = childIndexForKey(v, key);
    const r = try insertInto(txn, v.childRef(ci), key, val);

    // No split in child: just update the child ref.
    if (r.split == null) {
        const new_inner = try cowCopy(txn, node_ref, inner_node_size);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * 16 ..][0..8], r.ref, .little);
        return InsertResult{ .ref = new_inner.ref, .split = null };
    }

    const split = r.split.?;

    // Child split but this inner node is not full: shift and insert at ci+1.
    if (v.child_count < FANOUT) {
        const new_inner = try cowCopy(txn, node_ref, inner_node_size);
        // Update child ci's ref (low_key unchanged: left half keeps same minimum).
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * 16 ..][0..8], r.ref, .little);
        // Shift slots [ci+1, child_count) right by one.
        var j: usize = v.child_count;
        while (j > ci + 1) : (j -= 1) {
            const src = hdr + (j - 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(new_inner.bytes[dst..][0..16], new_inner.bytes[src..][0..16]);
        }
        std.mem.writeInt(u64, new_inner.bytes[hdr + (ci + 1) * 16 ..][0..8], split.ref, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + (ci + 1) * 16 + 8 ..][0..8], split.low, .little);
        std.mem.writeInt(u16, new_inner.bytes[1..3], v.child_count + 1, .little);
        return InsertResult{ .ref = new_inner.ref, .split = null };
    }

    // Child split AND this inner node is full: build FANOUT+1 entries, split at midpoint.
    // Read all entries from v before calling cowCopy.
    const total_inner: usize = @as(usize, FANOUT) + 1;
    var refs_buf: [FANOUT + 1]u64 = undefined;
    var lows_buf: [FANOUT + 1]u64 = undefined;
    var j: usize = 0;
    while (j < v.child_count) : (j += 1) {
        refs_buf[j] = v.childRef(j);
        lows_buf[j] = v.lowKey(j);
    }
    // Update ci's ref to the left half returned by the child split.
    refs_buf[ci] = r.ref;
    // Insert new right sibling immediately after ci.
    j = v.child_count; // = FANOUT
    while (j > ci + 1) : (j -= 1) {
        refs_buf[j] = refs_buf[j - 1];
        lows_buf[j] = lows_buf[j - 1];
    }
    refs_buf[ci + 1] = split.ref;
    lows_buf[ci + 1] = split.low;

    const m_inner: usize = total_inner / 2;
    const left_a = try cowCopy(txn, node_ref, inner_node_size);
    std.mem.writeInt(u16, left_a.bytes[1..3], @intCast(m_inner), .little);
    j = 0;
    while (j < m_inner) : (j += 1) {
        std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 ..][0..8], refs_buf[j], .little);
        std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 + 8 ..][0..8], lows_buf[j], .little);
    }
    const right_a = try txn.alloc(inner_node_size);
    _ = encodeInner(right_a.bytes, refs_buf[m_inner..total_inner], lows_buf[m_inner..total_inner]);
    return InsertResult{ .ref = left_a.ref, .split = Split{ .ref = right_a.ref, .low = lows_buf[m_inner] } };
}

/// Insert or update key->val in the tree rooted at root.
/// Returns the (possibly new) root Ref. Grows the tree height on root split.
pub fn insert(txn: *WriteTxn, root: Ref, key: u64, val: u64) !Ref {
    const r = try insertInto(txn, root, key, val);
    if (r.split == null) return r.ref;
    // Root was split: build a new two-child inner root.
    const left_min = try minKey(txn, r.ref);
    const new_root = try txn.alloc(inner_node_size);
    const root_refs = [_]u64{ r.ref, r.split.?.ref };
    const root_lows = [_]u64{ left_min, r.split.?.low };
    _ = encodeInner(new_root.bytes, &root_refs, &root_lows);
    return new_root.ref;
}

/// Recursive remove. Returns the (possibly new) node ref.
/// Returns node_ref unchanged when the key is absent (no COW on the path).
fn removeInto(txn: *WriteTxn, node_ref: Ref, key: u64) !Ref {
    const kind = (try txn.deref(node_ref, 1))[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = v.lowerBound(key);
        if (i >= v.count or v.key(i) != key) return node_ref; // no-op
        const a = try cowCopy(txn, node_ref, leaf_node_size);
        // Shift slots (i+1 .. count) left by one, overwriting slot i.
        var j: usize = i;
        while (j + 1 < v.count) : (j += 1) {
            const src = hdr + (j + 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
        }
        std.mem.writeInt(u16, a.bytes[1..3], v.count - 1, .little);
        return a.ref;
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = childIndexForKey(v, key);
    const old_child_ref: Ref = v.childRef(ci);
    const new_child = try removeInto(txn, old_child_ref, key);
    // No change in the subtree: skip COW on this inner node too.
    if (new_child == old_child_ref) return node_ref;
    const new_inner = try cowCopy(txn, node_ref, inner_node_size);
    std.mem.writeInt(u64, new_inner.bytes[hdr + ci * 16 ..][0..8], new_child, .little);
    return new_inner.ref;
}

/// Remove key from the tree rooted at root.
/// Returns the (possibly new) root Ref. No-op if key is absent.
pub fn remove(txn: *WriteTxn, root: Ref, key: u64) !Ref {
    return removeInto(txn, root, key);
}

/// Return the number of keys in the tree rooted at root.
pub fn count(txn: anytype, root: Ref) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        return v.count;
    }
    // Inner node: sum counts over all children.
    const v = try parseInner(bytes);
    var total: u64 = 0;
    var i: usize = 0;
    while (i < v.child_count) : (i += 1) {
        const child_ref: Ref = v.childRef(i);
        total += try count(txn, child_ref);
    }
    return total;
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

test "get and count traverse an inner node over two leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var a = try create(&w);
    a = try insert(&w, a, 1, 11);
    a = try insert(&w, a, 3, 33);
    var b = try create(&w);
    b = try insert(&w, b, 5, 55);
    b = try insert(&w, b, 7, 77);
    const inner = try makeInnerForTest(&w, &.{ .{ .ref = a, .low = 1 }, .{ .ref = b, .low = 5 } });
    try testing.expectEqual(@as(u64, 4), try count(&w, inner));
    try testing.expectEqual(@as(?u64, 11), try get(&w, inner, 1));
    try testing.expectEqual(@as(?u64, 55), try get(&w, inner, 5));
    try testing.expectEqual(@as(?u64, 77), try get(&w, inner, 7));
    try testing.expect((try get(&w, inner, 6)) == null);
    try testing.expect((try get(&w, inner, 0)) == null);
    w.deinit();
}

test "insert builds a balanced tree across many leaves and reads back correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    const N: u64 = 5000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003; // scattered keys force mid-splits
        root = try insert(&w, root, k, k +% 7);
    }
    var ref_map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer ref_map.deinit();
    i = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003;
        try ref_map.put(k, k +% 7);
    }
    try testing.expectEqual(@as(u64, ref_map.count()), try count(&w, root));
    var it = ref_map.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(@as(?u64, e.value_ptr.*), try get(&w, root, e.key_ptr.*));
    }
    w.deinit();
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

test "insert and remove preserve the old root as an unchanged snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    var i: u64 = 0;
    while (i < 2000) : (i += 1) root = try insert(&w, root, i, i * 10);
    const old_root = root;
    const after_insert = try insert(&w, root, 1234, 999999); // update existing key 1234
    const after_remove = try remove(&w, after_insert, 500);
    // Old snapshot unchanged.
    try testing.expectEqual(@as(?u64, 1234 * 10), try get(&w, old_root, 1234));
    try testing.expectEqual(@as(?u64, 500 * 10), try get(&w, old_root, 500));
    // New roots reflect the changes.
    try testing.expectEqual(@as(?u64, 999999), try get(&w, after_insert, 1234));
    try testing.expect((try get(&w, after_remove, 500)) == null);
    // remove only affected after_remove, not after_insert (shared subtrees not mutated).
    try testing.expectEqual(@as(?u64, 500 * 10), try get(&w, after_insert, 500));
    w.deinit();
}
