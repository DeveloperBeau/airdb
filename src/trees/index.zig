// index.zig -- u64-keyed B+tree: the shared core of bTreeCore.zig
// instantiated with inline numeric keys. The u64 stored in each key slot IS
// the key, ordered numerically, so key duplication is identity and key
// freeing is a no-op. See bTreeCore.zig for the transaction capability the
// `transaction` parameters must satisfy (WriteTransaction in production; ReadTransaction for the
// read-only subset).

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const node = @import("indexNode.zig");
const bTreeCore = @import("bTreeCore.zig");

// Local aliases for the on-disk node format, used by the numeric-only extras
// below (maxKey, range iteration, test helpers).
const FANOUT = node.FANOUT;
const kind_leaf = node.kind_leaf;
const leaf_node_size = node.leaf_node_size;
const inner_node_size = node.inner_node_size;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;

/// Keying for inline numeric keys: the stored u64 IS the search key.
const NumericKeying = struct {
    /// Callers search with the key itself.
    pub const ProbeKey = u64;

    /// Numeric order of the stored key relative to the probe key.
    pub fn order(transaction: anytype, storedKey: u64, probeKey: u64) !std.math.Order {
        _ = transaction;
        return std.math.order(storedKey, probeKey);
    }

    /// Identity: an inline key needs no independently owned copy.
    pub fn duplicateKey(transaction: anytype, storedKey: u64) !u64 {
        _ = transaction;
        return storedKey;
    }

    /// No-op: an inline key owns no material outside the node.
    pub fn freeKey(transaction: anytype, storedKey: u64) !void {
        _ = transaction;
        _ = storedKey;
    }
};

const Tree = bTreeCore.BTreeCore(NumericKeying);

/// Corrupt-cycle guard shared by every recursive walker (see bTreeCore.zig).
pub const max_depth = bTreeCore.maxDepth;

/// Deref a node, sizing the read by its kind byte (leaf vs inner).
pub const derefNode = Tree.derefNode;

/// Create a new empty leaf node and return its Reference.
pub const create = Tree.create;

/// Look up key in the tree rooted at root. Returns the associated value or null.
pub const get = Tree.get;

/// Insert or update key->val in the tree rooted at root.
/// Returns the (possibly new) root Reference. Grows the tree height on root split.
pub fn insert(transaction: anytype, root: Reference, key: u64, val: u64) !Reference {
    return Tree.insert(transaction, root, key, key, val);
}

/// Remove key from the tree rooted at root.
/// Returns the (possibly new) root Reference. No-op if key is absent.
pub const remove = Tree.remove;

/// Recursively free every node of the tree rooted at node_ref so the space
/// becomes reclaimable. Only the NODES are freed; for trees whose leaf values
/// are refs to other structures (e.g. value-index inner sets) the caller owns
/// those separately.
pub const freeTree = Tree.freeTree;

/// Return the number of keys in the tree rooted at root. A single-node read:
/// leaves know their own count and inner nodes store per-child subtree counts.
pub const count = Tree.count;

/// Visit every key in ascending order, calling onKey(ctx, key) for each.
/// Inner nodes are recursed left to right; leaf keys are already sorted.
pub const forEachKey = Tree.forEachKey;

/// Visit every key/value pair in ascending key order, calling
/// onEntry(ctx, key, value) for each. Same traversal as forEachKey, but also
/// surfaces the value stored alongside each key in the leaf.
pub const forEachEntry = Tree.forEachEntry;

/// Return the largest key in the tree rooted at root, or null if the tree is
/// empty. Read-only, O(height). Descends the LAST NON-EMPTY child at each
/// level: removals never merge or drop leaves, so the rightmost leaf can be
/// empty while the tree still holds keys -- blindly following the rightmost
/// path would report a non-empty tree as empty, and bulkAppend would then
/// admit a batch whose keys do not clear the true maximum, corrupting the pk
/// index with duplicates and broken ordering.
pub fn maxKey(transaction: anytype, root: Reference) !?u64 {
    var cur: Reference = root;
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const bytes = try derefNode(transaction, cur);
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

// Bottom-up level builders and right-edge run append (one abstraction, housed
// in its own file; re-exported here so callers keep the Index.* surface).
const bulkBuild = @import("indexBulkBuild.zig");

/// A node together with the low key and subtree count its parent records for
/// it; the per-level work item of packLeaves/stackInner/appendRun.
pub const Child = bulkBuild.Child;

/// Pack strictly-ascending (keys, values) into leaves filled to LEAF_CAP.
pub const packLeaves = bulkBuild.packLeaves;

/// Build one inner level over a slice of children, packed in runs of FANOUT.
pub const stackInner = bulkBuild.stackInner;

/// Stack inner levels until a single root remains, replacing `level` in place.
pub const collapseToRoot = bulkBuild.collapseToRoot;

/// Append a sorted run of (keys, values), all above the current max key, to
/// the tree's right edge; only the rightmost path is rebuilt.
pub const appendRun = bulkBuild.appendRun;

// Visit every key/value pair whose key lies in [lo, hi] in ascending key
// order, calling onEntry(ctx, key, value) for each. Same recursive descent as
// forEachEntry, but routes into the child holding lo via childIndexForKey and
// starts each leaf at lowerBound(lo), stopping as soon as a key exceeds hi so
// no leaf outside the range is visited. Read-only: no COW.
pub fn forEachEntryInRange(
    transaction: anytype,
    root: Reference,
    lo: u64,
    hi: u64,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    return forEachEntryInRangeAt(transaction, root, lo, hi, ctx, onEntry, 0);
}

fn forEachEntryInRangeAt(
    transaction: anytype,
    root: Reference,
    lo: u64,
    hi: u64,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
    depth: usize,
) !void {
    if (root == 0 or lo > hi) return;
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(transaction, root);
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
    var i: usize = try Tree.childIndexForKey(transaction, inner, lo);
    while (i < inner.child_count) : (i += 1) {
        if (inner.lowKey(i) > hi) return;
        const child_ref: Reference = inner.childRef(i);
        try forEachEntryInRangeAt(transaction, child_ref, lo, hi, ctx, onEntry, depth + 1);
    }
}

// Test-only helper: build an inner node from a slice of (ref, low, count) triples.
pub fn makeInnerForTest(transaction: anytype, children: []const struct { ref: u64, low: u64, count: u64 }) !Reference {
    var refs: [FANOUT]u64 = undefined;
    var lows: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    for (children, 0..) |c, i| {
        refs[i] = c.ref;
        lows[i] = c.low;
        counts[i] = c.count;
    }
    const a = try transaction.alloc(inner_node_size);
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

test {
    _ = @import("indexTests.zig");
}
