// The `txn` parameter of every operation is `anytype`: a comptime duck-typed
// transaction capability, monomorphized at compile time (no vtable on this
// B+tree hot path). Read-only operations need only
//   deref(ref, len) ![]const u8
// and mutating operations additionally require
//   alloc(size) !Allocation, writableCopy(ref, len) !Allocation,
//   free(ref, len) !void
// where Allocation is arena.Allocation. WriteTxn is the production
// implementation; ReadTxn satisfies the read-only subset.

const std = @import("std");
const Ref = @import("ref.zig").Ref;
const node = @import("index_node.zig");

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

// A legal tree over 2^64 keys with fanout 64 is at most ~11 levels deep, so any
// walk deeper than this is following a corrupt ref cycle. Every recursive walker
// carries a depth and fails with error.Corrupt instead of overflowing the stack.
pub const max_depth: usize = 16;

fn derefNode(txn: anytype, ref: Ref) ![]const u8 {
    const kind_bytes = try txn.deref(ref, 1);
    return switch (kind_bytes[0]) {
        kind_leaf => txn.deref(ref, leaf_node_size),
        kind_inner => txn.deref(ref, inner_node_size),
        else => error.Corrupt,
    };
}

// Test-only helper: build an inner node from a slice of (ref, low, count) triples.
pub fn makeInnerForTest(txn: anytype, children: []const struct { ref: u64, low: u64, count: u64 }) !Ref {
    var refs: [FANOUT]u64 = undefined;
    var lows: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    for (children, 0..) |c, i| {
        refs[i] = c.ref;
        lows[i] = c.low;
        counts[i] = c.count;
    }
    const a = try txn.alloc(inner_node_size);
    _ = encodeInner(a.bytes, refs[0..children.len], lows[0..children.len], counts[0..children.len]);
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
pub fn create(txn: anytype) !Ref {
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
    return getAt(txn, root, key, 0);
}

fn getAt(txn: anytype, root: Ref, key: u64, depth: usize) !?u64 {
    if (depth >= max_depth) return error.Corrupt;
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
    return getAt(txn, child_ref, key, depth + 1);
}

/// Return the largest key in the tree rooted at root, or null if the tree is
/// empty. Read-only, O(height). Descends the LAST NON-EMPTY child at each
/// level: removals never merge or drop leaves, so the rightmost leaf can be
/// empty while the tree still holds keys -- blindly following the rightmost
/// path would report a non-empty tree as empty, and bulkAppend would then
/// admit a batch whose keys do not clear the true maximum, corrupting the pk
/// index with duplicates and broken ordering.
pub fn maxKey(txn: anytype, root: Ref) !?u64 {
    var cur: Ref = root;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const bytes = try derefNode(txn, cur);
        if (bytes[0] == kind_leaf) {
            const v = try parseLeaf(bytes);
            if (v.count == 0) return null; // only the empty root reaches here
            return v.key(v.count - 1);
        }
        const v = try parseInner(bytes);
        var i: usize = v.child_count;
        cur = blk: {
            while (i > 0) {
                i -= 1;
                if (v.subtreeCount(i) > 0) break :blk v.childRef(i);
            }
            return null; // every subtree is empty
        };
    }
    return error.Corrupt;
}

// ---------------------------------------------------------------------------
// B+tree insert with leaf/inner split and height growth (Task 4)
// ---------------------------------------------------------------------------

// A split's right sibling and an insert's resulting node both carry their
// subtree entry count so the parent can maintain the per-child counts that
// make Index.count a single-node read.
const Split = struct { ref: Ref, low: u64, count: u64 };
const InsertResult = struct { ref: Ref, count: u64, split: ?Split };

/// Descend the leftmost spine to the leftmost leaf and return its first key.
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

/// Recursive insert. Returns the (possibly new) node ref and an optional right
/// sibling produced by a midpoint split.
fn insertInto(txn: anytype, node_ref: Ref, key: u64, val: u64, depth: usize) !InsertResult {
    if (depth >= max_depth) return error.Corrupt;
    const node_bytes = try txn.deref(node_ref, 1);
    const kind = node_bytes[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = v.lowerBound(key);

        // Upsert: key already present.
        if (i < v.count and v.key(i) == key) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            return InsertResult{ .ref = a.ref, .count = v.count, .split = null };
        }

        // Not full: shift and insert.
        if (v.count < LEAF_CAP) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            var j: usize = v.count;
            while (j > i) : (j -= 1) {
                const src = hdr + (j - 1) * 16;
                const dst = hdr + j * 16;
                @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
            }
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 ..][0..8], key, .little);
            std.mem.writeInt(u64, a.bytes[hdr + i * 16 + 8 ..][0..8], val, .little);
            std.mem.writeInt(u16, a.bytes[1..3], v.count + 1, .little);
            return InsertResult{ .ref = a.ref, .count = @as(u64, v.count) + 1, .split = null };
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
        // Build buffer from v before writableCopy to avoid any aliasing concern.
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
        return InsertResult{
            .ref = left_a.ref,
            .count = m_leaf,
            .split = Split{ .ref = right_a.ref, .low = keys_buf[m_leaf], .count = total_leaf - m_leaf },
        };
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = childIndexForKey(v, key);
    const old_total = v.totalCount();
    const old_child_count = v.subtreeCount(ci);
    const r = try insertInto(txn, v.childRef(ci), key, val, depth + 1);

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
        // Update child ci's ref+count (low_key unchanged: left half keeps same minimum).
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride ..][0..8], r.ref, .little);
        std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride + 16 ..][0..8], r.count, .little);
        // Shift slots [ci+1, child_count) right by one.
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
    // Read all entries from v before calling writableCopy.
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
    // Update ci's ref/count to the left half returned by the child split.
    refs_buf[ci] = r.ref;
    counts_buf[ci] = r.count;
    // Insert new right sibling immediately after ci.
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

/// Insert or update key->val in the tree rooted at root.
/// Returns the (possibly new) root Ref. Grows the tree height on root split.
pub fn insert(txn: anytype, root: Ref, key: u64, val: u64) !Ref {
    const r = try insertInto(txn, root, key, val, 0);
    if (r.split == null) return r.ref;
    // Root was split: build a new two-child inner root.
    const left_min = try minKey(txn, r.ref);
    const new_root = try txn.alloc(inner_node_size);
    const root_refs = [_]u64{ r.ref, r.split.?.ref };
    const root_lows = [_]u64{ left_min, r.split.?.low };
    const root_counts = [_]u64{ r.count, r.split.?.count };
    _ = encodeInner(new_root.bytes, &root_refs, &root_lows, &root_counts);
    return new_root.ref;
}

const RemoveResult = struct { ref: Ref, count: u64 };

/// Recursive remove. Returns the (possibly new) node ref and its subtree count.
/// Returns node_ref unchanged when the key is absent (no COW on the path).
fn removeInto(txn: anytype, node_ref: Ref, key: u64, depth: usize) !RemoveResult {
    if (depth >= max_depth) return error.Corrupt;
    const kind = (try txn.deref(node_ref, 1))[0];

    // ---- LEAF ---------------------------------------------------------------
    if (kind == kind_leaf) {
        const leaf_bytes = try txn.deref(node_ref, leaf_node_size);
        const v = try parseLeaf(leaf_bytes);
        const i = v.lowerBound(key);
        if (i >= v.count or v.key(i) != key) return .{ .ref = node_ref, .count = v.count }; // no-op
        const a = try txn.writableCopy(node_ref, leaf_node_size);
        // Shift slots (i+1 .. count) left by one, overwriting slot i.
        var j: usize = i;
        while (j + 1 < v.count) : (j += 1) {
            const src = hdr + (j + 1) * 16;
            const dst = hdr + j * 16;
            @memcpy(a.bytes[dst..][0..16], a.bytes[src..][0..16]);
        }
        std.mem.writeInt(u16, a.bytes[1..3], v.count - 1, .little);
        return .{ .ref = a.ref, .count = @as(u64, v.count) - 1 };
    }

    // ---- INNER --------------------------------------------------------------
    const inner_bytes = try txn.deref(node_ref, inner_node_size);
    const v = try parseInner(inner_bytes);
    const ci = childIndexForKey(v, key);
    const old_child_ref: Ref = v.childRef(ci);
    // Capture BEFORE writableCopy: it frees node_ref into the reuse pool, so
    // v's bytes must not be read after it (the node can be reallocated).
    const old_total = v.totalCount();
    const old_child_count = v.subtreeCount(ci);
    const r = try removeInto(txn, old_child_ref, key, depth + 1);
    // No change in the subtree: skip COW on this inner node too.
    if (r.ref == old_child_ref) return .{ .ref = node_ref, .count = old_total };
    const new_inner = try txn.writableCopy(node_ref, inner_node_size);
    std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride ..][0..8], r.ref, .little);
    std.mem.writeInt(u64, new_inner.bytes[hdr + ci * inner_stride + 16 ..][0..8], r.count, .little);
    return .{ .ref = new_inner.ref, .count = old_total - old_child_count + r.count };
}

/// Remove key from the tree rooted at root.
/// Returns the (possibly new) root Ref. No-op if key is absent.
pub fn remove(txn: anytype, root: Ref, key: u64) !Ref {
    return (try removeInto(txn, root, key, 0)).ref;
}

/// Recursively free every node of the tree rooted at node_ref so the space
/// becomes reclaimable. Only the NODES are freed; for trees whose leaf values
/// are refs to other structures (e.g. value-index inner sets) the caller owns
/// those separately.
pub fn freeTree(txn: anytype, node_ref: Ref) !void {
    return freeTreeAt(txn, node_ref, 0);
}

fn freeTreeAt(txn: anytype, node_ref: Ref, depth: usize) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        try txn.free(node_ref, leaf_node_size);
        return;
    }
    const v = try parseInner(bytes);
    var i: usize = 0;
    while (i < v.child_count) : (i += 1) try freeTreeAt(txn, v.childRef(i), depth + 1);
    try txn.free(node_ref, inner_node_size);
}

/// Return the number of keys in the tree rooted at root. A single-node read:
/// leaves know their own count and inner nodes store per-child subtree counts.
pub fn count(txn: anytype, root: Ref) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const v = try parseLeaf(bytes);
        return v.count;
    }
    const v = try parseInner(bytes);
    return v.totalCount();
}

// Visit every key in ascending order, calling onKey(ctx, key) for each.
// Inner nodes are recursed left to right; leaf keys are already sorted.
pub fn forEachKey(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onKey: fn (@TypeOf(ctx), u64) anyerror!void,
) !void {
    return forEachKeyAt(txn, root, ctx, onKey, 0);
}

fn forEachKeyAt(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onKey: fn (@TypeOf(ctx), u64) anyerror!void,
    depth: usize,
) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const leaf = try parseLeaf(bytes);
        var i: usize = 0;
        while (i < leaf.count) : (i += 1) try onKey(ctx, leaf.key(i));
        return;
    }
    const inner = try parseInner(bytes);
    var i: usize = 0;
    while (i < inner.child_count) : (i += 1) {
        const child_ref: Ref = inner.childRef(i);
        try forEachKeyAt(txn, child_ref, ctx, onKey, depth + 1);
    }
}

// Visit every key/value pair in ascending key order, calling
// onEntry(ctx, key, value) for each. Same traversal as forEachKey, but also
// surfaces the value stored alongside each key in the leaf.
pub fn forEachEntry(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    return forEachEntryAt(txn, root, ctx, onEntry, 0);
}

fn forEachEntryAt(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
    depth: usize,
) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const leaf = try parseLeaf(bytes);
        var i: usize = 0;
        while (i < leaf.count) : (i += 1) try onEntry(ctx, leaf.key(i), leaf.value(i));
        return;
    }
    const inner = try parseInner(bytes);
    var i: usize = 0;
    while (i < inner.child_count) : (i += 1) {
        const child_ref: Ref = inner.childRef(i);
        try forEachEntryAt(txn, child_ref, ctx, onEntry, depth + 1);
    }
}

// Visit every key/value pair whose key lies in [lo, hi] in ascending key
// order, calling onEntry(ctx, key, value) for each. Same recursive descent as
// forEachEntry, but routes into the child holding lo via childIndexForKey and
// starts each leaf at lowerBound(lo), stopping as soon as a key exceeds hi so
// no leaf outside the range is visited. Read-only: no COW.
pub fn forEachEntryInRange(
    txn: anytype,
    root: Ref,
    lo: u64,
    hi: u64,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    return forEachEntryInRangeAt(txn, root, lo, hi, ctx, onEntry, 0);
}

fn forEachEntryInRangeAt(
    txn: anytype,
    root: Ref,
    lo: u64,
    hi: u64,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
    depth: usize,
) !void {
    if (root == 0 or lo > hi) return;
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const leaf = try parseLeaf(bytes);
        var i: usize = leaf.lowerBound(lo);
        while (i < leaf.count) : (i += 1) {
            const k = leaf.key(i);
            if (k > hi) return;
            try onEntry(ctx, k, leaf.value(i));
        }
        return;
    }
    const inner = try parseInner(bytes);
    var i: usize = childIndexForKey(inner, lo);
    while (i < inner.child_count) : (i += 1) {
        if (inner.lowKey(i) > hi) return;
        const child_ref: Ref = inner.childRef(i);
        try forEachEntryInRangeAt(txn, child_ref, lo, hi, ctx, onEntry, depth + 1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("indexTests.zig");
}
