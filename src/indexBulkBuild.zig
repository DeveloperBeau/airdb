// Bottom-up level builders and right-edge run append for the u64-keyed B+tree
// in index.zig, re-exported there as Index.packLeaves / Index.stackInner /
// Index.collapseToRoot / Index.appendRun.
//
// These build complete tree levels directly from sorted input rather than
// inserting one pair at a time. The produced nodes are byte-for-byte the same
// on-disk format the sequential readers expect, so a bulk-built tree is
// indistinguishable from one grown via the normal insert path.
//
// The `txn` parameter follows index.zig's convention: a comptime duck-typed
// transaction capability requiring deref(ref, len), alloc(size),
// writableCopy(ref, len), and free(ref, len).

const std = @import("std");
const Ref = @import("reference.zig").Ref;
const node = @import("indexNode.zig");
const index = @import("index.zig");

// Local aliases for the on-disk node format and the shared tree walkers.
const LEAF_CAP = node.LEAF_CAP;
const FANOUT = node.FANOUT;
const kind_leaf = node.kind_leaf;
const leaf_node_size = node.leaf_node_size;
const inner_node_size = node.inner_node_size;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const max_depth = index.max_depth;
const derefNode = index.derefNode;

/// A node together with the low key (smallest key in its subtree) and its
/// subtree entry count, both of which its parent records for it. The per-level
/// work item of the bottom-up builders (packLeaves, stackInner, appendRun).
pub const Child = struct { ref: u64, low: u64, count: u64 };

/// Pack strictly-ascending (keys, values) into leaves filled to LEAF_CAP in key
/// order. Returns the leaf level: one Child per leaf, low == its first key.
pub fn packLeaves(
    txn: anytype,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    std.debug.assert(keys.len == values.len);
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const cap: usize = LEAF_CAP;
    var i: usize = 0;
    while (i < keys.len) {
        const end = @min(i + cap, keys.len);
        const a = try txn.alloc(leaf_node_size);
        _ = encodeLeaf(a.bytes, keys[i..end], values[i..end]);
        try out.append(allocator, .{ .ref = a.ref, .low = keys[i], .count = @intCast(end - i) });
        i = end;
    }
    return out;
}

/// Build one inner level over `children`, packed in runs of FANOUT. An inner
/// node stores (child_ref, low_key, subtree_count); a parent's low key is the
/// low key of its first child and its count is the sum of its run.
pub fn stackInner(
    txn: anytype,
    children: []const Child,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const fan: usize = FANOUT;
    var refs: [FANOUT]u64 = undefined;
    var lows: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    var j: usize = 0;
    while (j < children.len) {
        const end = @min(j + fan, children.len);
        var total: u64 = 0;
        var k: usize = j;
        while (k < end) : (k += 1) {
            refs[k - j] = children[k].ref;
            lows[k - j] = children[k].low;
            counts[k - j] = children[k].count;
            total += children[k].count;
        }
        const cnt = end - j;
        const a = try txn.alloc(inner_node_size);
        _ = encodeInner(a.bytes, refs[0..cnt], lows[0..cnt], counts[0..cnt]);
        try out.append(allocator, .{ .ref = a.ref, .low = children[j].low, .count = total });
        j = end;
    }
    return out;
}

/// Stack inner levels over `level` until a single node remains, growing the
/// tree height as needed. Replaces `level` in place; the survivor is the root.
pub fn collapseToRoot(
    txn: anytype,
    level: *std.ArrayList(Child),
    allocator: std.mem.Allocator,
) !void {
    while (level.items.len > 1) {
        const next = try stackInner(txn, level.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Descend the rightmost root-to-leaf path, recording each inner node and the
/// index of its rightmost child, and return the rightmost leaf's ref. No arena
/// allocation occurs here, so the deref'd node bytes stay valid for the
/// duration of each iteration.
fn descendRightEdge(
    txn: anytype,
    root: Ref,
    path_refs: *std.ArrayList(Ref),
    path_ridx: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !Ref {
    var cur: Ref = root;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= max_depth) return error.Corrupt; // ref cycle guard
        const nb = try derefNode(txn, cur);
        if (nb[0] == kind_leaf) return cur;
        const iv = try parseInner(nb);
        const ri: usize = iv.child_count - 1;
        const child = iv.childRef(ri);
        try path_refs.append(allocator, cur);
        try path_ridx.append(allocator, ri);
        cur = child;
    }
}

/// The rightmost leaf's pairs followed by an appended run, gathered into heap
/// buffers ready for packLeaves. The caller owns both slices.
const CombinedRun = struct { keys: []u64, values: []u64 };

/// Gather the rightmost leaf's existing pairs followed by the run into heap
/// buffers (heap allocation never remaps the arena, so the leaf bytes stay
/// valid while they are copied out). Asserts under runtime safety that the
/// run's first key clears the leaf's current max.
fn combineLeafAndRun(
    txn: anytype,
    leaf_ref: Ref,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !CombinedRun {
    const lv = try parseLeaf(try derefNode(txn, leaf_ref));
    if (std.debug.runtime_safety and lv.count > 0) {
        std.debug.assert(keys[0] > lv.key(lv.count - 1));
    }
    const total: usize = @as(usize, lv.count) + keys.len;
    const ck = try allocator.alloc(u64, total);
    errdefer allocator.free(ck);
    const cv = try allocator.alloc(u64, total);
    var t: usize = 0;
    while (t < lv.count) : (t += 1) {
        ck[t] = lv.key(t);
        cv[t] = lv.value(t);
    }
    for (keys, values) |key, val| {
        ck[t] = key;
        cv[t] = val;
        t += 1;
    }
    return .{ .keys = ck, .values = cv };
}

/// Rebuild the rightmost inner spine bottom-up. At each recorded path level,
/// the shared LEFT children (all but the rightmost) are re-emitted unchanged
/// and the rightmost child is replaced by the level rebuilt below, which may
/// have grown into several nodes. Packing in runs of FANOUT splits
/// automatically when the child list overflows; the extra nodes propagate up
/// as additional children of the next level. Replaces `level` in place.
fn rebuildRightSpine(
    txn: anytype,
    path_refs: []const Ref,
    path_ridx: []const usize,
    level: *std.ArrayList(Child),
    allocator: std.mem.Allocator,
) !void {
    var i: usize = path_refs.len;
    while (i > 0) {
        i -= 1;
        const iv = try parseInner(try derefNode(txn, path_refs[i]));
        const ri = path_ridx[i];
        var full = std.ArrayList(Child).empty;
        defer full.deinit(allocator);
        var j: usize = 0;
        while (j < ri) : (j += 1) {
            try full.append(allocator, .{ .ref = iv.childRef(j), .low = iv.lowKey(j), .count = iv.subtreeCount(j) });
        }
        for (level.items) |c| try full.append(allocator, c);
        const next = try stackInner(txn, full.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Append a sorted run of (keys, values) whose keys ALL exceed the tree's
/// current max key to the RIGHT EDGE of the tree rooted at `root`, returning
/// the new root Ref. Only the rightmost root-to-leaf path is rebuilt; every
/// left subtree is shared unchanged (copy-on-write: shared nodes are never
/// mutated). The result is logically identical to inserting every pair via
/// insert.
///
/// Preconditions (asserted under runtime safety): keys.len == values.len, keys
/// are strictly ascending, and keys[0] is greater than the tree's current max
/// key. An empty run returns `root` unchanged.
pub fn appendRun(
    txn: anytype,
    root: Ref,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !Ref {
    std.debug.assert(keys.len == values.len);
    if (keys.len == 0) return root;
    if (std.debug.runtime_safety) {
        var q: usize = 1;
        while (q < keys.len) : (q += 1) std.debug.assert(keys[q] > keys[q - 1]);
    }

    // 1. Record the rightmost path: it is the only part of the tree rebuilt.
    var path_refs = std.ArrayList(Ref).empty;
    defer path_refs.deinit(allocator);
    var path_ridx = std.ArrayList(usize).empty;
    defer path_ridx.deinit(allocator);
    const leaf_ref = try descendRightEdge(txn, root, &path_refs, &path_ridx, allocator);

    // 2. Combine the rightmost leaf's pairs with the run, then pack the
    //    combined run into leaves filled to LEAF_CAP: the first new leaf reuses
    //    the old leaf's content topped up from the front of the run, the rest
    //    are full leaves.
    const combined = try combineLeafAndRun(txn, leaf_ref, keys, values, allocator);
    defer allocator.free(combined.keys);
    defer allocator.free(combined.values);
    var level = try packLeaves(txn, combined.keys, combined.values, allocator);
    errdefer level.deinit(allocator);

    // 3. Rebuild the rightmost inner spine bottom-up, then stack further inner
    //    levels until a single root remains (the rebuilt root level may have
    //    overflowed FANOUT into several nodes), growing the tree height by one
    //    or more as needed.
    try rebuildRightSpine(txn, path_refs.items, path_ridx.items, &level, allocator);
    try collapseToRoot(txn, &level, allocator);

    const result = level.items[0].ref;

    // 4. Free the replaced right-edge nodes: the old rightmost leaf and every
    //    inner node on the old rightmost path were rebuilt above and are no
    //    longer referenced by the new tree. Committed nodes route to deferred
    //    (MVCC-safe) reclaim; txn-private ones become immediately reusable.
    //    These frees are fallible, so they run BEFORE the manual level.deinit:
    //    the errdefer must never fire on an already-deinitialized list.
    try txn.free(leaf_ref, leaf_node_size);
    for (path_refs.items) |old_ref| try txn.free(old_ref, inner_node_size);

    level.deinit(allocator);
    return result;
}
