//! u64-keyed B+tree: the shared core of bTreeCore.zig
//! instantiated with inline numeric keys. The u64 stored in each key slot IS
//! the key, ordered numerically, so key duplication is identity and key
//! freeing is a no-op. See bTreeCore.zig for the transaction capability the
//! `transaction` parameters must satisfy (WriteTransaction in production; ReadTransaction for the
//! read-only subset).

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const node = @import("indexNode.zig");
const bTreeCore = @import("bTreeCore.zig");

// Local aliases for the on-disk node format, used by the numeric-only extras
// below (maxKey, range iteration, test helpers).
const fanout = node.fanout;
const kindLeaf = node.kindLeaf;
const leafNodeSize = node.leafNodeSize;
const innerNodeSize = node.innerNodeSize;
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
pub const maxDepth = bTreeCore.maxDepth;

/// Dereference a node, sizing the read by its kind byte (leaf vs inner).
pub const dereferenceNode = Tree.dereferenceNode;

/// Create a new empty leaf node and return its Reference.
pub const create = Tree.create;

/// Look up key in the tree rooted at root. Returns the associated value or null.
pub const get = Tree.get;

/// Insert or update key->val in the tree rooted at root.
/// Returns the (possibly new) root Reference. Grows the tree height on root split.
pub fn insert(transaction: anytype, root: Reference, key: u64, value: u64) !Reference {
    return Tree.insert(transaction, root, key, key, value);
}

/// Remove key from the tree rooted at root.
/// Returns the (possibly new) root Reference. No-op if key is absent.
pub const remove = Tree.remove;

/// Recursively free every node of the tree rooted at nodeReference so the space
/// becomes reclaimable. Only the NODES are freed; for trees whose leaf values
/// are references to other structures (e.g. value-index inner sets) the caller owns
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

/// Visit every key/value pair in ascending key order until onEntry returns
/// false. Returns whether the walk reached the end of the tree.
pub const forEachEntryWhile = Tree.forEachEntryWhile;

/// Return the largest key in the tree rooted at root, or null if the tree is
/// empty. Read-only, O(height). Descends the LAST NON-EMPTY child at each
/// level: removals never merge or drop leaves, so the rightmost leaf can be
/// empty while the tree still holds keys -- blindly following the rightmost
/// path would report a non-empty tree as empty, and bulkAppend would then
/// admit a batch whose keys do not clear the true maximum, corrupting the primaryKey
/// index with duplicates and broken ordering.
pub fn maxKey(transaction: anytype, root: Reference) !?u64 {
    var currentReference: Reference = root;
    var depth: usize = 0;
    while (depth < maxDepth) : (depth += 1) {
        const bytes = try dereferenceNode(transaction, currentReference);
        if (bytes[0] == kindLeaf) {
            const view = try parseLeaf(bytes);
            if (view.count == 0) return null; // only the empty root reaches here
            return view.key(view.count - 1);
        }
        const view = try parseInner(bytes);
        var childIndex: usize = view.childCount;
        currentReference = blk: {
            while (childIndex > 0) {
                childIndex -= 1;
                if (view.subtreeCount(childIndex) > 0) break :blk view.childReference(childIndex);
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

/// Pack strictly-ascending (keys, values) into leaves filled to leafCap.
pub const packLeaves = bulkBuild.packLeaves;

/// Build one inner level over a slice of children, packed in runs of fanout.
pub const stackInner = bulkBuild.stackInner;

/// Stack inner levels until a single root remains, replacing `level` in place.
pub const collapseToRoot = bulkBuild.collapseToRoot;

/// Append a sorted run of (keys, values), all above the current max key, to
/// the tree's right edge; only the rightmost path is rebuilt.
pub const appendRun = bulkBuild.appendRun;

/// Visit every key/value pair whose key lies in [low, high] in ascending key
/// order until `onEntry` returns false. Returns whether the walk ran to
/// completion (an empty range returns true; a callback stopping on the last
/// entry returns false). Routes into the child holding `low` via
/// childIndexForKey and starts each leaf at lowerBound(low), so no leaf outside
/// the range is visited. Read-only, O(log n + visited) with I/O; each inner
/// node costs one childIndexForKey scan over up to fanout children, so prefer
/// forEachEntryWhile when the whole tree is wanted.
pub fn forEachEntryInRangeWhile(
    transaction: anytype,
    root: Reference,
    low: u64,
    high: u64,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!bool,
) !bool {
    return forEachEntryInRangeWhileAt(transaction, root, low, high, context, onEntry, 0);
}

fn forEachEntryInRangeWhileAt(
    transaction: anytype,
    root: Reference,
    low: u64,
    high: u64,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!bool,
    depth: usize,
) !bool {
    if (root == 0 or low > high) return true;
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try dereferenceNode(transaction, root);
    if (bytes[0] == kindLeaf) {
        const leaf = try parseLeaf(bytes);
        var childIndex: usize = leaf.lowerBound(low);
        while (childIndex < leaf.count) : (childIndex += 1) {
            const key = leaf.key(childIndex);
            if (key > high) return true;
            if (!try onEntry(context, key, leaf.value(childIndex))) return false;
        }
        return true;
    }
    const inner = try parseInner(bytes);
    var childIndex: usize = try Tree.childIndexForKey(transaction, inner, low);
    while (childIndex < inner.childCount) : (childIndex += 1) {
        if (inner.lowKey(childIndex) > high) return true;
        if (!try forEachEntryInRangeWhileAt(transaction, inner.childReference(childIndex), low, high, context, onEntry, depth + 1)) return false;
    }
    return true;
}

/// Visit every key/value pair whose key lies in [low, high] in ascending key
/// order, calling onEntry(ctx, key, value) for each. The always-continuing
/// case of forEachEntryInRangeWhile. Read-only (no COW); O(log n + matches)
/// with I/O.
pub fn forEachEntryInRange(
    transaction: anytype,
    root: Reference,
    low: u64,
    high: u64,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    const Continuing = struct {
        inner: @TypeOf(ctx),
        fn onEntryContinuing(self: @This(), key: u64, value: u64) anyerror!bool {
            try onEntry(self.inner, key, value);
            return true;
        }
    };
    _ = try forEachEntryInRangeWhile(transaction, root, low, high, Continuing{ .inner = ctx }, Continuing.onEntryContinuing);
}

/// Visit every key/value pair whose key lies in [low, high] in DESCENDING key
/// order until `onEntry` returns false. Returns whether the walk ran to
/// completion. The mirror of forEachEntryInRangeWhile: routes into the child
/// holding `high`, starts each leaf at the last slot whose key is <= high, and
/// stops as soon as a key drops below `low`. An empty leaf or subtree is
/// skipped, which matters because removals never merge leaves. Read-only,
/// O(log n + visited) with I/O.
pub fn forEachEntryInRangeDescendingWhile(
    transaction: anytype,
    root: Reference,
    low: u64,
    high: u64,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!bool,
) !bool {
    return forEachEntryInRangeDescendingWhileAt(transaction, root, low, high, context, onEntry, 0);
}

fn forEachEntryInRangeDescendingWhileAt(
    transaction: anytype,
    root: Reference,
    low: u64,
    high: u64,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!bool,
    depth: usize,
) !bool {
    if (root == 0 or low > high) return true;
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try dereferenceNode(transaction, root);
    if (bytes[0] == kindLeaf) {
        const leaf = try parseLeaf(bytes);
        // Start just past the last key <= high, then walk down to low.
        var slot: usize = leaf.lowerBound(high);
        if (slot < leaf.count and leaf.key(slot) == high) slot += 1;
        while (slot > 0) {
            slot -= 1;
            const key = leaf.key(slot);
            if (key < low) return true;
            if (!try onEntry(context, key, leaf.value(slot))) return false;
        }
        return true;
    }
    const inner = try parseInner(bytes);
    // Enter the child holding `high`, then move left while a lower child can
    // still hold keys >= low.
    var childIndex: usize = try Tree.childIndexForKey(transaction, inner, high);
    while (true) {
        if (!try forEachEntryInRangeDescendingWhileAt(transaction, inner.childReference(childIndex), low, high, context, onEntry, depth + 1)) return false;
        if (childIndex == 0) break;
        if (inner.lowKey(childIndex) <= low) break;
        childIndex -= 1;
    }
    return true;
}

/// Test-only helper: build an inner node from a slice of (reference, low, count)
/// triples and return its reference.
pub fn makeInnerForTest(transaction: anytype, children: []const struct { reference: u64, low: u64, count: u64 }) !Reference {
    var references: [fanout]u64 = undefined;
    var lows: [fanout]u64 = undefined;
    var counts: [fanout]u64 = undefined;
    for (children, 0..) |child, childIndex| {
        references[childIndex] = child.reference;
        lows[childIndex] = child.low;
        counts[childIndex] = child.count;
    }
    const allocation = try transaction.alloc(innerNodeSize);
    _ = encodeInner(allocation.bytes, references[0..children.len], lows[0..children.len], counts[0..children.len]);
    return allocation.reference;
}

test "leaf encode/decode round-trips sorted pairs" {
    var buffer: [leafNodeSize]u8 = undefined;
    const keys = [_]u64{ 1, 5, 9 };
    const vals = [_]u64{ 10, 50, 90 };
    const encodedLength = encodeLeaf(&buffer, &keys, &vals);
    const view = try parseLeaf(buffer[0..encodedLength]);
    try std.testing.expectEqual(@as(u16, 3), view.count);
    try std.testing.expectEqual(@as(u64, 5), view.key(1));
    try std.testing.expectEqual(@as(u64, 90), view.value(2));
}

test "lowerBound finds the first index whose key is >= the search key" {
    var buffer: [leafNodeSize]u8 = undefined;
    const keys = [_]u64{ 2, 4, 6, 8 };
    const vals = [_]u64{ 0, 0, 0, 0 };
    const encodedLength = encodeLeaf(&buffer, &keys, &vals);
    const view = try parseLeaf(buffer[0..encodedLength]);
    try std.testing.expectEqual(@as(usize, 0), view.lowerBound(1));
    try std.testing.expectEqual(@as(usize, 1), view.lowerBound(4));
    try std.testing.expectEqual(@as(usize, 2), view.lowerBound(5));
    try std.testing.expectEqual(@as(usize, 4), view.lowerBound(9));
}

test {
    _ = @import("indexTests.zig");
}
