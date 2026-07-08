// Bottom-up level builders and right-edge run append for the u64-keyed B+tree
// in index.zig, re-exported there as Index.packLeaves / Index.stackInner /
// Index.collapseToRoot / Index.appendRun.
//
// These build complete tree levels directly from sorted input rather than
// inserting one pair at a time. The produced nodes are byte-for-byte the same
// on-disk format the sequential readers expect, so a bulk-built tree is
// indistinguishable from one grown via the normal insert path.
//
// The `transaction` parameter follows index.zig's convention: a comptime duck-typed
// transaction capability requiring deref(ref, length), alloc(size),
// writableCopy(ref, length), and free(ref, length).

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const node = @import("indexNode.zig");
const index = @import("index.zig");

// Local aliases for the on-disk node format and the shared tree walkers.
const leafCap = node.leafCap;
const fanout = node.fanout;
const kindLeaf = node.kindLeaf;
const leafNodeSize = node.leafNodeSize;
const innerNodeSize = node.innerNodeSize;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const maxDepth = index.maxDepth;
const derefNode = index.derefNode;

/// A node together with the low key (smallest key in its subtree) and its
/// subtree entry count, both of which its parent records for it. The per-level
/// work item of the bottom-up builders (packLeaves, stackInner, appendRun).
pub const Child = struct { ref: u64, low: u64, count: u64 };

/// Pack strictly-ascending (keys, values) into leaves filled to leafCap in key
/// order. Returns the leaf level: one Child per leaf, low == its first key.
pub fn packLeaves(
    transaction: anytype,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    std.debug.assert(keys.len == values.len);
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const capacity: usize = leafCap;
    var start: usize = 0;
    while (start < keys.len) {
        const end = @min(start + capacity, keys.len);
        const allocation = try transaction.alloc(leafNodeSize);
        _ = encodeLeaf(allocation.bytes, keys[start..end], values[start..end]);
        try out.append(allocator, .{ .ref = allocation.ref, .low = keys[start], .count = @intCast(end - start) });
        start = end;
    }
    return out;
}

/// Build one inner level over `children`, packed in runs of fanout. An inner
/// node stores (childRef, lowKey, subtreeCount); a parent's low key is the
/// low key of its first child and its count is the sum of its run.
pub fn stackInner(
    transaction: anytype,
    children: []const Child,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const width: usize = fanout;
    var refs: [fanout]u64 = undefined;
    var lows: [fanout]u64 = undefined;
    var counts: [fanout]u64 = undefined;
    var runStart: usize = 0;
    while (runStart < children.len) {
        const end = @min(runStart + width, children.len);
        var total: u64 = 0;
        var childPosition: usize = runStart;
        while (childPosition < end) : (childPosition += 1) {
            refs[childPosition - runStart] = children[childPosition].ref;
            lows[childPosition - runStart] = children[childPosition].low;
            counts[childPosition - runStart] = children[childPosition].count;
            total += children[childPosition].count;
        }
        const runLength = end - runStart;
        const allocation = try transaction.alloc(innerNodeSize);
        _ = encodeInner(allocation.bytes, refs[0..runLength], lows[0..runLength], counts[0..runLength]);
        try out.append(allocator, .{ .ref = allocation.ref, .low = children[runStart].low, .count = total });
        runStart = end;
    }
    return out;
}

/// Stack inner levels over `level` until a single node remains, growing the
/// tree height as needed. Replaces `level` in place; the survivor is the root.
pub fn collapseToRoot(
    transaction: anytype,
    level: *std.ArrayList(Child),
    allocator: std.mem.Allocator,
) !void {
    while (level.items.len > 1) {
        const next = try stackInner(transaction, level.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Descend the rightmost root-to-leaf path, recording each inner node and the
/// index of its rightmost child, and return the rightmost leaf's ref. No arena
/// allocation occurs here, so the deref'd node bytes stay valid for the
/// duration of each iteration.
fn descendRightEdge(
    transaction: anytype,
    root: Reference,
    pathRefs: *std.ArrayList(Reference),
    pathRightmost: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !Reference {
    var currentRef: Reference = root;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= maxDepth) return error.Corrupt; // ref cycle guard
        const nodeBytes = try derefNode(transaction, currentRef);
        if (nodeBytes[0] == kindLeaf) return currentRef;
        const innerView = try parseInner(nodeBytes);
        const rightmostIndex: usize = innerView.childCount - 1;
        const child = innerView.childRef(rightmostIndex);
        try pathRefs.append(allocator, currentRef);
        try pathRightmost.append(allocator, rightmostIndex);
        currentRef = child;
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
    transaction: anytype,
    leafRef: Reference,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !CombinedRun {
    const leafView = try parseLeaf(try derefNode(transaction, leafRef));
    if (std.debug.runtime_safety and leafView.count > 0) {
        std.debug.assert(keys[0] > leafView.key(leafView.count - 1));
    }
    const total: usize = @as(usize, leafView.count) + keys.len;
    const combinedKeys = try allocator.alloc(u64, total);
    errdefer allocator.free(combinedKeys);
    const combinedValues = try allocator.alloc(u64, total);
    var cursor: usize = 0;
    while (cursor < leafView.count) : (cursor += 1) {
        combinedKeys[cursor] = leafView.key(cursor);
        combinedValues[cursor] = leafView.value(cursor);
    }
    for (keys, values) |key, value| {
        combinedKeys[cursor] = key;
        combinedValues[cursor] = value;
        cursor += 1;
    }
    return .{ .keys = combinedKeys, .values = combinedValues };
}

/// Rebuild the rightmost inner spine bottom-up. At each recorded path level,
/// the shared LEFT children (all but the rightmost) are re-emitted unchanged
/// and the rightmost child is replaced by the level rebuilt below, which may
/// have grown into several nodes. Packing in runs of fanout splits
/// automatically when the child list overflows; the extra nodes propagate up
/// as additional children of the next level. Replaces `level` in place.
fn rebuildRightSpine(
    transaction: anytype,
    pathRefs: []const Reference,
    pathRightmost: []const usize,
    level: *std.ArrayList(Child),
    allocator: std.mem.Allocator,
) !void {
    var levelIndex: usize = pathRefs.len;
    while (levelIndex > 0) {
        levelIndex -= 1;
        const innerView = try parseInner(try derefNode(transaction, pathRefs[levelIndex]));
        const rightmostIndex = pathRightmost[levelIndex];
        var full = std.ArrayList(Child).empty;
        defer full.deinit(allocator);
        var childIndex: usize = 0;
        while (childIndex < rightmostIndex) : (childIndex += 1) {
            try full.append(allocator, .{ .ref = innerView.childRef(childIndex), .low = innerView.lowKey(childIndex), .count = innerView.subtreeCount(childIndex) });
        }
        for (level.items) |child| try full.append(allocator, child);
        const next = try stackInner(transaction, full.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Append a sorted run of (keys, values) whose keys ALL exceed the tree's
/// current max key to the RIGHT EDGE of the tree rooted at `root`, returning
/// the new root Reference. Only the rightmost root-to-leaf path is rebuilt; every
/// left subtree is shared unchanged (copy-on-write: shared nodes are never
/// mutated). The result is logically identical to inserting every pair via
/// insert.
///
/// Preconditions (asserted under runtime safety): keys.len == values.len, keys
/// are strictly ascending, and keys[0] is greater than the tree's current max
/// key. An empty run returns `root` unchanged.
pub fn appendRun(
    transaction: anytype,
    root: Reference,
    keys: []const u64,
    values: []const u64,
    allocator: std.mem.Allocator,
) !Reference {
    std.debug.assert(keys.len == values.len);
    if (keys.len == 0) return root;
    if (std.debug.runtime_safety) {
        var keyIndex: usize = 1;
        while (keyIndex < keys.len) : (keyIndex += 1) std.debug.assert(keys[keyIndex] > keys[keyIndex - 1]);
    }

    // 1. Record the rightmost path: it is the only part of the tree rebuilt.
    var pathRefs = std.ArrayList(Reference).empty;
    defer pathRefs.deinit(allocator);
    var pathRightmost = std.ArrayList(usize).empty;
    defer pathRightmost.deinit(allocator);
    const leafRef = try descendRightEdge(transaction, root, &pathRefs, &pathRightmost, allocator);

    // 2. Combine the rightmost leaf's pairs with the run, then pack the
    //    combined run into leaves filled to leafCap: the first new leaf reuses
    //    the old leaf's content topped up from the front of the run, the rest
    //    are full leaves.
    const combined = try combineLeafAndRun(transaction, leafRef, keys, values, allocator);
    defer allocator.free(combined.keys);
    defer allocator.free(combined.values);
    var level = try packLeaves(transaction, combined.keys, combined.values, allocator);
    errdefer level.deinit(allocator);

    // 3. Rebuild the rightmost inner spine bottom-up, then stack further inner
    //    levels until a single root remains (the rebuilt root level may have
    //    overflowed fanout into several nodes), growing the tree height by one
    //    or more as needed.
    try rebuildRightSpine(transaction, pathRefs.items, pathRightmost.items, &level, allocator);
    try collapseToRoot(transaction, &level, allocator);

    const result = level.items[0].ref;

    // 4. Free the replaced right-edge nodes: the old rightmost leaf and every
    //    inner node on the old rightmost path were rebuilt above and are no
    //    longer referenced by the new tree. Committed nodes route to deferred
    //    (MVCC-safe) reclaim; transaction-private ones become immediately reusable.
    //    These frees are fallible, so they run BEFORE the manual level.deinit:
    //    the errdefer must never fire on an already-deinitialized list.
    try transaction.free(leafRef, leafNodeSize);
    for (pathRefs.items) |oldRef| try transaction.free(oldRef, innerNodeSize);

    level.deinit(allocator);
    return result;
}
