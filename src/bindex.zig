// bindex.zig -- byte-keyed ordered B+tree.
//
// Same on-disk node layout as index.zig (see index_node.zig): a leaf is a run
// of (u64, u64) pairs, an inner node is a run of (child_ref u64, low_key u64)
// pairs. The ONLY difference from index.zig: the first u64 of a leaf pair is a
// blob ref to the key bytes (not the key itself), and the "low_key" of an inner
// pair is a blob ref to the smallest key in that subtree. All ordering compares
// the dereferenced bytes with std.mem.order; keys live in the blob heap.

const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const node = @import("index_node.zig");
const blob = @import("blob.zig");

// Local aliases for the on-disk node format, which lives in index_node.zig.
const LEAF_CAP = node.LEAF_CAP;
const FANOUT = node.FANOUT;
const kind_leaf = node.kind_leaf;
const kind_inner = node.kind_inner;
const hdr = node.hdr;
const leaf_node_size = node.leaf_node_size;
const inner_node_size = node.inner_node_size;
const inner_stride = node.inner_stride;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const LeafView = node.LeafView;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const InnerView = node.InnerView;

/// Order the key stored at `stored_ref` (a blob ref) against `target` bytes.
/// Pure byte ordering via std.mem.order -- this is index ordering, not a secret
/// comparison, so constant-time is neither required nor wanted here.
fn keyOrder(txn: anytype, stored_ref: u64, target: []const u8) !std.math.Order {
    const stored = try blob.get(txn, stored_ref);
    return std.mem.order(u8, stored, target);
}

/// Return the largest i with lowKey(i) <= target (byte order); fall back to 0
/// if target < lowKey(0). Mirrors index.zig's childIndexForKey, but each
/// low_key is a blob ref that must be dereferenced and byte-compared.
fn childIndexForKey(txn: anytype, v: InnerView, target: []const u8) !usize {
    var best: usize = 0;
    var i: usize = 0;
    while (i < v.child_count) : (i += 1) {
        // lowKey(i) <= target  <=>  order(lowKey, target) is not .gt.
        if ((try keyOrder(txn, v.lowKey(i), target)) != .gt) {
            best = i;
        } else {
            break;
        }
    }
    return best;
}

/// First index whose stored key is >= target (byte order). Mirrors
/// LeafView.lowerBound, but compares dereferenced key blobs.
fn leafLowerBound(txn: anytype, v: LeafView, target: []const u8) !usize {
    var lo: usize = 0;
    var hi: usize = v.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((try keyOrder(txn, v.key(mid), target)) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// Same cycle guard as index.zig: any walk deeper than a legal tree's maximum
// height is following a corrupt ref cycle and fails instead of overflowing.
const max_depth = @import("index.zig").max_depth;

fn derefNode(txn: anytype, ref: Ref) ![]const u8 {
    const kind_bytes = try txn.deref(ref, 1);
    return switch (kind_bytes[0]) {
        kind_leaf => txn.deref(ref, leaf_node_size),
        kind_inner => txn.deref(ref, inner_node_size),
        else => error.Corrupt,
    };
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// Create a new empty leaf node and return its Ref.
pub fn create(txn: *WriteTxn) !Ref {
    const a = try txn.alloc(leaf_node_size);
    _ = encodeLeaf(a.bytes, &.{}, &.{});
    return a.ref;
}

/// Look up `key` in the tree rooted at `root`. Returns the value on exact
/// byte-equality, else null.
pub fn get(txn: anytype, root: Ref, key: []const u8) !?u64 {
    return getAt(txn, root, key, 0);
}

fn getAt(txn: anytype, root: Ref, key: []const u8, depth: usize) !?u64 {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        const i = try leafLowerBound(txn, v, key);
        if (i < v.count and (try keyOrder(txn, v.key(i), key)) == .eq) return v.value(i);
        return null;
    }
    const v = try parseInner(bytes);
    const ci = try childIndexForKey(txn, v, key);
    const child_ref: Ref = v.childRef(ci);
    return getAt(txn, child_ref, key, depth + 1);
}

// Same count-carrying result shapes as index.zig: parents maintain per-child
// subtree counts so bindex.count is a single-node read.
const Split = struct { ref: Ref, low: u64, count: u64 };
const InsertResult = struct { ref: Ref, count: u64, split: ?Split };

/// Descend the leftmost spine to the leftmost leaf and return the blob ref of
/// its first (smallest) key.
fn minKey(txn: anytype, ref: Ref) !u64 {
    var cur: Ref = ref;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const bytes = try derefNode(txn, cur);
        if (bytes[0] == kind_leaf) {
            const v = try parseLeaf(bytes);
            return v.key(0);
        }
        const v = try parseInner(bytes);
        cur = v.childRef(0);
    }
    return error.Corrupt;
}

/// Recursive insert. `key_ref` is the blob ref for `key` (pre-allocated by the
/// public insert). On an in-place overwrite the redundant `key_ref` blob is
/// freed here, since the existing entry already references the key bytes.
fn insertInto(txn: *WriteTxn, node_ref: Ref, key_ref: u64, key: []const u8, val: u64, depth: usize) !InsertResult {
    if (depth >= max_depth) return error.Corrupt;
    const node_bytes = try txn.deref(node_ref, 1);
    const kind = node_bytes[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = try leafLowerBound(txn, v, key);

        // Upsert: key already present (exact bytes). Overwrite value in place.
        if (i < v.count and (try keyOrder(txn, v.key(i), key)) == .eq) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            // The just-put key blob is redundant: the existing slot keeps its key.
            try blob.free(txn, key_ref);
            return InsertResult{ .ref = a.ref, .count = v.count, .split = null };
        }

        // Not full: shift and insert (key_ref, val) at slot i.
        if (v.count < LEAF_CAP) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            var j: usize = v.count;
            while (j > i) : (j -= 1) {
                const src = hdr + (j - 1) * 16;
                const dst = hdr + j * 16;
                @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
            }
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 ..][0..8], key_ref, .little);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            std.mem.writeInt(u16, a.bytes[1..3], v.count + 1, .little);
            return InsertResult{ .ref = a.ref, .count = @as(u64, v.count) + 1, .split = null };
        }

        // Full: build LEAF_CAP+1 sorted pairs (key refs + values), split at midpoint.
        const total_leaf: usize = @as(usize, LEAF_CAP) + 1;
        var keys_buf: [LEAF_CAP + 1]u64 = undefined; // blob refs
        var vals_buf: [LEAF_CAP + 1]u64 = undefined;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            keys_buf[j] = v.key(j);
            vals_buf[j] = v.value(j);
        }
        keys_buf[i] = key_ref;
        vals_buf[i] = val;
        j = i;
        while (j < v.count) : (j += 1) {
            keys_buf[j + 1] = v.key(j);
            vals_buf[j + 1] = v.value(j);
        }
        const m_leaf: usize = total_leaf / 2;
        const left_a = try txn.writableCopy(node_ref, leaf_node_size);
        std.mem.writeInt(u16, left_a.bytes[1..3], @intCast(m_leaf), .little);
        j = 0;
        while (j < m_leaf) : (j += 1) {
            std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 ..][0..8], keys_buf[j], .little);
            std.mem.writeInt(u64, left_a.bytes[hdr + j * 16 + 8 ..][0..8], vals_buf[j], .little);
        }
        const right_a = try txn.alloc(leaf_node_size);
        _ = encodeLeaf(right_a.bytes, keys_buf[m_leaf..total_leaf], vals_buf[m_leaf..total_leaf]);
        // The parent's low key must OWN its bytes: aliasing the right leaf's
        // slot-0 key blob would leave every ancestor dereferencing freed bytes
        // once that key is removed (removeInto frees leaf key blobs). Routing
        // separators are duplicated at split time and, like classic B+tree
        // separators, deliberately never freed -- one small blob per split.
        const boundary_bytes = try blob.get(txn, keys_buf[m_leaf]);
        const boundary_low = try blob.put(txn, boundary_bytes);
        return InsertResult{
            .ref = left_a.ref,
            .count = m_leaf,
            .split = Split{ .ref = right_a.ref, .low = boundary_low, .count = total_leaf - m_leaf },
        };
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = try childIndexForKey(txn, v, key);
    const old_total = v.totalCount();
    const old_child_count = v.subtreeCount(ci);
    const r = try insertInto(txn, v.childRef(ci), key_ref, key, val, depth + 1);

    // No split in child: update the child's ref and subtree count.
    if (r.split == null) {
        const new_inner = try txn.writableCopy(node_ref, inner_node_size);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride ..][0..8], r.ref, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride + 16 ..][0..8], r.count, .little);
        return InsertResult{ .ref = new_inner.ref, .count = old_total - old_child_count + r.count, .split = null };
    }

    const split = r.split.?;
    const new_total = old_total - old_child_count + r.count + split.count;

    // Child split but this inner node is not full: shift and insert at ci+1.
    if (v.child_count < FANOUT) {
        const new_inner = try txn.writableCopy(node_ref, inner_node_size);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride ..][0..8], r.ref, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride + 16 ..][0..8], r.count, .little);
        var j: usize = v.child_count;
        while (j > ci + 1) : (j -= 1) {
            const src = hdr + (j - 1) * inner_stride;
            const dst = hdr + j * inner_stride;
            @memcpy(new_inner.bytes[dst..][0..inner_stride], new_inner.bytes[src..][0..inner_stride]);
        }
        std.mem.writeInt(u64, new_inner.bytes[hdr + (ci + 1) * inner_stride ..][0..8], split.ref, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + (ci + 1) * inner_stride + 8 ..][0..8], split.low, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + (ci + 1) * inner_stride + 16 ..][0..8], split.count, .little);
        std.mem.writeInt(u16, new_inner.bytes[1..3], v.child_count + 1, .little);
        return InsertResult{ .ref = new_inner.ref, .count = new_total, .split = null };
    }

    // Child split AND this inner node is full: build FANOUT+1 entries, split at midpoint.
    const total_inner: usize = @as(usize, FANOUT) + 1;
    var refs_buf: [FANOUT + 1]u64 = undefined;
    var lows_buf: [FANOUT + 1]u64 = undefined;
    var counts_buf: [FANOUT + 1]u64 = undefined;
    var j: usize = 0;
    while (j < v.child_count) : (j += 1) {
        refs_buf[j] = v.childRef(j);
        lows_buf[j] = v.lowKey(j);
        counts_buf[j] = v.subtreeCount(j);
    }
    refs_buf[ci] = r.ref;
    counts_buf[ci] = r.count;
    j = v.child_count; // = FANOUT
    while (j > ci + 1) : (j -= 1) {
        refs_buf[j] = refs_buf[j - 1];
        lows_buf[j] = lows_buf[j - 1];
        counts_buf[j] = counts_buf[j - 1];
    }
    refs_buf[ci + 1] = split.ref;
    lows_buf[ci + 1] = split.low;
    counts_buf[ci + 1] = split.count;

    const m_inner: usize = total_inner / 2;
    const left_a = try txn.writableCopy(node_ref, inner_node_size);
    std.mem.writeInt(u16, left_a.bytes[1..3], @intCast(m_inner), .little);
    var left_count: u64 = 0;
    j = 0;
    while (j < m_inner) : (j += 1) {
        std.mem.writeInt(u64, left_a.bytes[hdr + j * inner_stride ..][0..8], refs_buf[j], .little);
        std.mem.writeInt(u64, left_a.bytes[hdr + j * inner_stride + 8 ..][0..8], lows_buf[j], .little);
        std.mem.writeInt(u64, left_a.bytes[hdr + j * inner_stride + 16 ..][0..8], counts_buf[j], .little);
        left_count += counts_buf[j];
    }
    var right_count: u64 = 0;
    j = m_inner;
    while (j < total_inner) : (j += 1) right_count += counts_buf[j];
    const right_a = try txn.alloc(inner_node_size);
    _ = encodeInner(right_a.bytes, refs_buf[m_inner..total_inner], lows_buf[m_inner..total_inner], counts_buf[m_inner..total_inner]);
    return InsertResult{
        .ref = left_a.ref,
        .count = left_count,
        .split = Split{ .ref = right_a.ref, .low = lows_buf[m_inner], .count = right_count },
    };
}

/// Insert or update key->val in the tree rooted at `root`. If `key` already
/// exists (exact bytes), its value is overwritten in place and no duplicate is
/// added; otherwise the key bytes are stored in the blob heap and a new entry
/// is inserted in byte-sorted order. Returns the (possibly new) root.
pub fn insert(txn: *WriteTxn, root: Ref, key: []const u8, val: u64) !Ref {
    const key_ref = try blob.put(txn, key);
    const r = try insertInto(txn, root, key_ref, key, val, 0);
    if (r.split == null) return r.ref;
    // Root was split: build a new two-child inner root. The left low is
    // duplicated for the same ownership reason as split boundaries: minKey
    // returns the leftmost LEAF's slot-0 key blob, which removeInto may free.
    const left_min_bytes = try blob.get(txn, try minKey(txn, r.ref));
    const left_low = try blob.put(txn, left_min_bytes);
    const new_root = try txn.alloc(inner_node_size);
    const root_refs = [_]u64{ r.ref, r.split.?.ref };
    const root_lows = [_]u64{ left_low, r.split.?.low };
    const root_counts = [_]u64{ r.count, r.split.?.count };
    _ = encodeInner(new_root.bytes, &root_refs, &root_lows, &root_counts);
    return new_root.ref;
}

const RemoveResult = struct { ref: Ref, count: u64 };

/// Recursive remove. Returns node_ref unchanged when the key is absent.
fn removeInto(txn: *WriteTxn, node_ref: Ref, key: []const u8, depth: usize) !RemoveResult {
    if (depth >= max_depth) return error.Corrupt;
    const kind = (try txn.deref(node_ref, 1))[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = try leafLowerBound(txn, v, key);
        if (i >= v.count or (try keyOrder(txn, v.key(i), key)) != .eq) {
            return .{ .ref = node_ref, .count = v.count }; // no-op
        }
        // Capture the key blob ref before COW so we can free it afterward.
        const removed_key_ref = v.key(i);
        const a = try txn.writableCopy(node_ref, leaf_node_size);
        var j: usize = i;
        while (j + 1 < v.count) : (j += 1) {
            const src = hdr + (j + 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
        }
        std.mem.writeInt(u16, a.bytes[1..3], v.count - 1, .little);
        try blob.free(txn, removed_key_ref);
        return .{ .ref = a.ref, .count = @as(u64, v.count) - 1 };
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = try childIndexForKey(txn, v, key);
    const old_child_ref: Ref = v.childRef(ci);
    // Capture BEFORE writableCopy: it frees node_ref into the reuse pool, so
    // v's bytes must not be read after it (the node can be reallocated).
    const old_total = v.totalCount();
    const old_child_count = v.subtreeCount(ci);
    const r = try removeInto(txn, old_child_ref, key, depth + 1);
    if (r.ref == old_child_ref) return .{ .ref = node_ref, .count = old_total };
    const new_inner = try txn.writableCopy(node_ref, inner_node_size);
    std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride ..][0..8], r.ref, .little);
    std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride + 16 ..][0..8], r.count, .little);
    return .{ .ref = new_inner.ref, .count = old_total - old_child_count + r.count };
}

/// Remove `key` from the tree rooted at `root`. Frees the key's blob node when
/// present. Returns the (possibly new) root; unchanged if the key is absent.
pub fn remove(txn: *WriteTxn, root: Ref, key: []const u8) !Ref {
    return (try removeInto(txn, root, key, 0)).ref;
}

/// Return the number of entries in the tree rooted at `root`. A single-node
/// read: inner nodes store per-child subtree counts.
pub fn count(txn: anytype, root: Ref) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        return v.count;
    }
    const v = try parseInner(bytes);
    return v.totalCount();
}

/// Visit every (key, value) entry in ascending byte-key order, dereferencing
/// each leaf entry's key blob and calling onEntry(ctx, key_bytes, value).
/// The key slice points into mapped storage and is only valid for the duration
/// of the callback; copy it if it must outlive the call.
pub fn forEachEntry(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), key: []const u8, val: u64) anyerror!void,
) !void {
    return forEachEntryAt(txn, root, ctx, onEntry, 0);
}

fn forEachEntryAt(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), key: []const u8, val: u64) anyerror!void,
    depth: usize,
) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const leaf = try parseLeaf(bytes);
        var i: usize = 0;
        while (i < leaf.count) : (i += 1) {
            const key_bytes = try blob.get(txn, leaf.key(i));
            try onEntry(ctx, key_bytes, leaf.value(i));
        }
        return;
    }
    const inner = try parseInner(bytes);
    var i: usize = 0;
    while (i < inner.child_count) : (i += 1) {
        const child_ref: Ref = inner.childRef(i);
        try forEachEntryAt(txn, child_ref, ctx, onEntry, depth + 1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Db = @import("db.zig").Db;

fn bidxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "a bindex ref cycle fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_cycle.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    // Inner node whose only child is itself; its low key is a real blob so the
    // ordering compare succeeds and the walk descends into the cycle.
    const key_ref = try blob.put(&w, "k");
    const a = try w.alloc(inner_node_size);
    _ = encodeInner(a.bytes, &.{a.ref}, &.{key_ref}, &.{1});
    try testing.expectError(error.Corrupt, get(&w, a.ref, "k"));
    try testing.expectError(error.Corrupt, insert(&w, a.ref, "x", 1));
    try testing.expectError(error.Corrupt, remove(&w, a.ref, "k"));
    const NopSink = struct {
        fn onEntry(_: @This(), _: []const u8, _: u64) !void {}
    };
    try testing.expectError(error.Corrupt, forEachEntry(&w, a.ref, NopSink{}, NopSink.onEntry));
}

test "removing split-boundary keys never dangles routing separators" {
    // Regression: parent low keys used to alias the right leaf's slot-0 key
    // blob; removing that key freed bytes every ancestor still dereferenced
    // for ordering, and the immediately-reused blob misrouted later lookups.
    // Churn removal+insert (same key sizes, so the freed blob is reused at
    // once) across a split tree must keep every lookup exact.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_boundary.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var root = try create(&w);
    var buf: [8]u8 = undefined;
    var i: u64 = 0;
    while (i < 200) : (i += 1) { // multiple leaf splits
        const key = try std.fmt.bufPrint(&buf, "k{d:0>5}", .{i});
        root = try insert(&w, root, key, i);
    }
    // Remove each key (any of them may be a split boundary) and immediately
    // insert a same-length replacement so the freed key blob is reused.
    i = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "k{d:0>5}", .{i});
        root = try remove(&w, root, key);
        const repl = try std.fmt.bufPrint(&buf, "z{d:0>5}", .{i});
        root = try insert(&w, root, repl, i);
        // Every surviving original key must still resolve exactly.
        var j: u64 = i + 1;
        while (j < 200) : (j += 17) {
            const probe = try std.fmt.bufPrint(&buf, "k{d:0>5}", .{j});
            try testing.expectEqual(@as(?u64, j), try get(&w, root, probe));
        }
    }
    // All replacements resolve; all originals are gone.
    i = 0;
    while (i < 200) : (i += 1) {
        const repl = try std.fmt.bufPrint(&buf, "z{d:0>5}", .{i});
        try testing.expectEqual(@as(?u64, i), try get(&w, root, repl));
        const orig = try std.fmt.bufPrint(&buf, "k{d:0>5}", .{i});
        try testing.expectEqual(@as(?u64, null), try get(&w, root, orig));
    }
    try testing.expectEqual(@as(u64, 200), try count(&w, root));
}

test "insert and get round-trip byte keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    // Scrambled insertion order.
    root = try insert(&w, root, "banana", 1);
    root = try insert(&w, root, "apple", 2);
    root = try insert(&w, root, "cherry", 3);
    root = try insert(&w, root, "app", 4);
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "banana"));
    try testing.expectEqual(@as(?u64, 2), try get(&w, root, "apple"));
    try testing.expectEqual(@as(?u64, 3), try get(&w, root, "cherry"));
    try testing.expectEqual(@as(?u64, 4), try get(&w, root, "app"));
    try testing.expect((try get(&w, root, "ap")) == null);
    try testing.expect((try get(&w, root, "")) == null);
    try testing.expect((try get(&w, root, "bananas")) == null);
    try testing.expectEqual(@as(u64, 4), try count(&w, root));
    w.deinit();
}

test "keys iterate in ascending byte order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "cherry", 30);
    root = try insert(&w, root, "app", 40);
    root = try insert(&w, root, "banana", 10);
    root = try insert(&w, root, "apple", 20);

    const Collector = struct {
        keys: *std.ArrayList([]u8),
        vals: *std.ArrayList(u64),
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.keys.append(testing.allocator, try testing.allocator.dupe(u8, key));
            try self.vals.append(testing.allocator, val);
        }
    };
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&w, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);

    // Expected ascending byte order: "app" < "apple" < "banana" < "cherry".
    const expect_keys = [_][]const u8{ "app", "apple", "banana", "cherry" };
    const expect_vals = [_]u64{ 40, 20, 10, 30 };
    try testing.expectEqual(expect_keys.len, keys.items.len);
    for (keys.items, vals.items, 0..) |k, val, idx| {
        try testing.expectEqualStrings(expect_keys[idx], k);
        try testing.expectEqual(expect_vals[idx], val);
    }
    // And explicitly assert the collected keys are sorted by std.mem.order.
    var i: usize = 1;
    while (i < keys.items.len) : (i += 1) {
        try testing.expect(std.mem.order(u8, keys.items[i - 1], keys.items[i]) == .lt);
    }
    w.deinit();
}

test "insert overwrites an existing key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "k", 1);
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "k"));
    root = try insert(&w, root, "k", 2);
    try testing.expectEqual(@as(?u64, 2), try get(&w, root, "k"));
    try testing.expectEqual(@as(u64, 1), try count(&w, root));
    w.deinit();
}

test "remove deletes a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "apple", 2);
    root = try insert(&w, root, "banana", 1);
    root = try insert(&w, root, "cherry", 3);
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    root = try remove(&w, root, "apple");
    try testing.expect((try get(&w, root, "apple")) == null);
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "banana"));
    try testing.expectEqual(@as(?u64, 3), try get(&w, root, "cherry"));
    // Removing an absent key is a no-op.
    root = try remove(&w, root, "apple");
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    w.deinit();
}

test "many keys across splits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);

    const N: u64 = 1000;
    var buf: [64]u8 = undefined;
    // Scrambled insertion order; varied lengths/zero-padding make byte order non-trivial.
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % N; // permutation of 0..N-1
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{k});
        root = try insert(&w, root, key, k +% 7);
    }
    try testing.expectEqual(N, try count(&w, root));

    // Get every key back.
    i = 0;
    while (i < N) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        try testing.expectEqual(@as(?u64, i +% 7), try get(&w, root, key));
    }

    // Iteration is sorted by std.mem.order and values match their keys.
    const Collector = struct {
        keys: *std.ArrayList([]u8),
        vals: *std.ArrayList(u64),
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.keys.append(testing.allocator, try testing.allocator.dupe(u8, key));
            try self.vals.append(testing.allocator, val);
        }
    };
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&w, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);
    try testing.expectEqual(@as(usize, N), keys.items.len);
    var j: usize = 1;
    while (j < keys.items.len) : (j += 1) {
        try testing.expect(std.mem.order(u8, keys.items[j - 1], keys.items[j]) == .lt);
    }
    // Each emitted key's value matches the number parsed from "key-{d}".
    for (keys.items, vals.items) |k, val| {
        const num = try std.fmt.parseInt(u64, k["key-".len..], 10);
        try testing.expectEqual(num +% 7, val);
    }
    w.deinit();
}
