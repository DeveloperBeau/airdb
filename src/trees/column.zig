//! Column tree: a counted B+tree mapping a dense row index to a u64 value,
//! the storage behind every property/version/live column.
//!
//! The `transaction` parameter of every operation is `anytype`: a comptime duck-typed
//! transaction capability, monomorphized at compile time (no vtable on this
//! B+tree hot path). Read-only operations need only
//!   deref(ref, length) ![]const u8
//! and mutating operations additionally require
//!   alloc(size) !Allocation, writableCopy(ref, length) !Allocation,
//!   free(ref, length) !void
//! where Allocation is arena.Allocation. WriteTransaction is the production
//! implementation; ReadTransaction satisfies the read-only subset.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const node = @import("columnNode.zig");

// Local aliases for the on-disk node format, which lives in columnNode.zig.
const leafCap = node.leafCap;
const fanout = node.fanout;
const kindLeaf = node.kindLeaf;
const kindInner = node.kindInner;
const leafNodeSize = node.leafNodeSize;
const leafHeader = node.leafHeader;
const innerNodeSize = node.innerNodeSize;
const innerHeader = node.innerHeader;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const LeafView = node.LeafView;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const InnerView = node.InnerView;

// ---------------------------------------------------------------------------
// Column operations
// ---------------------------------------------------------------------------

/// Allocate an empty leaf column node and return its Reference.
pub fn create(transaction: anytype) !Reference {
    const allocation = try transaction.alloc(leafNodeSize);
    _ = encodeLeaf(allocation.bytes, &.{});
    return allocation.ref;
}

/// Corrupt-cycle guard for every recursive walker: a legal tree with fanout
/// 64 covering 2^64 rows is at most ~11 levels deep, so any walk deeper than
/// this is following a corrupt ref cycle. Walkers carry a depth and fail with
/// error.Corrupt instead of overflowing the stack.
pub const maxDepth: usize = 16;

/// Deref a node by first reading its kind byte, then dereffing the full node.
fn derefNode(transaction: anytype, ref: Reference) ![]const u8 {
    const kindBuffer = try transaction.deref(ref, 1);
    return switch (kindBuffer[0]) {
        kindLeaf => transaction.deref(ref, leafNodeSize),
        kindInner => transaction.deref(ref, innerNodeSize),
        else => error.Corrupt,
    };
}

/// Return the number of values stored in the column rooted at root.
pub fn length(transaction: anytype, root: Reference) !u64 {
    const bytes = try derefNode(transaction, root);
    if (bytes[0] == kindLeaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        return count;
    } else {
        const view = try parseInner(bytes);
        var total: u64 = 0;
        var childIndex: u16 = 0;
        while (childIndex < view.childCount) : (childIndex += 1) {
            total += view.subtreeCount(childIndex);
        }
        return total;
    }
}

/// Return the value at index. Returns error.IndexOutOfBounds if out of range.
pub fn get(transaction: anytype, root: Reference, index: u64) !u64 {
    return getAt(transaction, root, index, 0);
}

fn getAt(transaction: anytype, root: Reference, index: u64, depth: usize) !u64 {
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try derefNode(transaction, root);
    if (bytes[0] == kindLeaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const position: usize = @intCast(index);
        const offset: usize = leafHeader + position * 8;
        return std.mem.readInt(u64, bytes[offset..][0..8], .little);
    } else {
        const view = try parseInner(bytes);
        var remaining = index;
        var childIndex: u16 = 0;
        while (childIndex < view.childCount) : (childIndex += 1) {
            const childTotal = view.subtreeCount(childIndex);
            if (remaining < childTotal) return getAt(transaction, view.childRef(childIndex), remaining, depth + 1);
            remaining -= childTotal;
        }
        return error.IndexOutOfBounds;
    }
}

const AppendResult = struct { ref: Reference, count: u64, split: ?Reference, splitCount: u64 };

fn appendInto(transaction: anytype, nodeRef: Reference, value: u64, depth: usize) !AppendResult {
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try derefNode(transaction, nodeRef);
    if (bytes[0] == kindLeaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (count < leafCap) {
            const allocation = try transaction.writableCopy(nodeRef, leafNodeSize);
            std.mem.writeInt(u16, allocation.bytes[1..3], count + 1, .little);
            const offset: usize = leafHeader + @as(usize, count) * 8;
            std.mem.writeInt(u64, allocation.bytes[offset..][0..8], value, .little);
            return .{ .ref = allocation.ref, .count = @as(u64, count) + 1, .split = null, .splitCount = 0 };
        } else {
            // Full leaf: allocate a new leaf for the new value; leave the old leaf untouched.
            const allocation = try transaction.alloc(leafNodeSize);
            _ = encodeLeaf(allocation.bytes, &.{value});
            return .{ .ref = nodeRef, .count = leafCap, .split = allocation.ref, .splitCount = 1 };
        }
    } else {
        const view = try parseInner(bytes);
        const childCount = view.childCount;
        const lastChildIndex: usize = @as(usize, childCount) - 1;
        const lastRef = view.childRef(lastChildIndex);
        // Capture old totals before recursion (bytes stay valid: mmap grows in place).
        var oldTotal: u64 = 0;
        {
            var childIndex: usize = 0;
            while (childIndex < childCount) : (childIndex += 1) oldTotal += view.subtreeCount(childIndex);
        }
        const oldLastCount = view.subtreeCount(lastChildIndex);
        const result = try appendInto(transaction, lastRef, value, depth + 1);
        // COW the inner node and update the last child entry.
        const allocation = try transaction.writableCopy(nodeRef, innerNodeSize);
        const lastOff: usize = innerHeader + lastChildIndex * 16;
        std.mem.writeInt(u64, allocation.bytes[lastOff..][0..8], result.ref, .little);
        std.mem.writeInt(u64, allocation.bytes[lastOff + 8 ..][0..8], result.count, .little);
        if (result.split == null) {
            return .{ .ref = allocation.ref, .count = oldTotal - oldLastCount + result.count, .split = null, .splitCount = 0 };
        } else if (childCount < fanout) {
            // Room in this inner: append the new child.
            const newOff: usize = innerHeader + @as(usize, childCount) * 16;
            std.mem.writeInt(u16, allocation.bytes[1..3], childCount + 1, .little);
            const splitRef = result.split.?;
            std.mem.writeInt(u64, allocation.bytes[newOff..][0..8], splitRef, .little);
            std.mem.writeInt(u64, allocation.bytes[newOff + 8 ..][0..8], result.splitCount, .little);
            return .{ .ref = allocation.ref, .count = oldTotal - oldLastCount + result.count + result.splitCount, .split = null, .splitCount = 0 };
        } else {
            // Inner full: create a new right inner holding just the split child.
            const newInner = try transaction.alloc(innerNodeSize);
            const splitRef = result.split.?;
            _ = encodeInner(newInner.bytes, &.{splitRef}, &.{result.splitCount});
            return .{ .ref = allocation.ref, .count = oldTotal - oldLastCount + result.count, .split = newInner.ref, .splitCount = result.splitCount };
        }
    }
}

/// Append value to the column. Returns the new root Reference (copy-on-write).
/// Grows the tree through leaf splits and height increases as needed.
pub fn append(transaction: anytype, root: Reference, value: u64) !Reference {
    const result = try appendInto(transaction, root, value, 0);
    if (result.split == null) return result.ref;
    // Split propagated to the root: grow height by one.
    const allocation = try transaction.alloc(innerNodeSize);
    const splitRef = result.split.?;
    _ = encodeInner(allocation.bytes, &.{ result.ref, splitRef }, &.{ result.count, result.splitCount });
    return allocation.ref;
}

// ---------------------------------------------------------------------------
// Bottom-up level builders and right-edge run append.
//
// These build complete tree levels directly from input values rather than
// appending one value at a time. The produced nodes are byte-for-byte the same
// on-disk format the sequential readers expect, so a bulk-built tree is
// indistinguishable from one grown via the normal append path.
// ---------------------------------------------------------------------------

/// A node together with the value count of its subtree, which its parent
/// records alongside the child ref. The per-level work item of the bottom-up
/// builders (packLeaves, stackInner, appendRun). Unlike the index's Child
/// (which carries a low key), a column inner node stores (childRef,
/// subtreeCount) and a parent's own count is the SUM of its children's counts.
pub const Child = struct { ref: u64, count: u64 };

/// Pack `values` into leaves filled to leafCap in row order. Returns the leaf
/// level: one Child per leaf, count == the number of values in that leaf.
pub fn packLeaves(
    transaction: anytype,
    values: []const u64,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const capacity: usize = leafCap;
    var start: usize = 0;
    while (start < values.len) {
        const end = @min(start + capacity, values.len);
        const allocation = try transaction.alloc(leafNodeSize);
        _ = encodeLeaf(allocation.bytes, values[start..end]);
        try out.append(allocator, .{ .ref = allocation.ref, .count = @intCast(end - start) });
        start = end;
    }
    return out;
}

/// Build one inner level over `children`, packed in runs of fanout. A column
/// inner node stores (childRef, subtreeCount); a parent's count is the SUM
/// of its children's counts, so each emitted node's count == the total of its
/// run.
pub fn stackInner(
    transaction: anytype,
    children: []const Child,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const width: usize = fanout;
    var refs: [fanout]u64 = undefined;
    var counts: [fanout]u64 = undefined;
    var runStart: usize = 0;
    while (runStart < children.len) {
        const end = @min(runStart + width, children.len);
        var total: u64 = 0;
        var childPosition: usize = runStart;
        while (childPosition < end) : (childPosition += 1) {
            refs[childPosition - runStart] = children[childPosition].ref;
            counts[childPosition - runStart] = children[childPosition].count;
            total += children[childPosition].count;
        }
        const runLength = end - runStart;
        const allocation = try transaction.alloc(innerNodeSize);
        _ = encodeInner(allocation.bytes, refs[0..runLength], counts[0..runLength]);
        try out.append(allocator, .{ .ref = allocation.ref, .count = total });
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

/// Descend the rightmost root-to-leaf path (always the last child), recording
/// each inner node and the index of its rightmost child, and return the
/// rightmost leaf's ref. No arena allocation occurs here, so the deref'd node
/// bytes stay valid for the duration of each iteration.
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
        const rightmostIndex: usize = @as(usize, innerView.childCount) - 1;
        const child = innerView.childRef(rightmostIndex);
        try pathRefs.append(allocator, currentRef);
        try pathRightmost.append(allocator, rightmostIndex);
        currentRef = child;
    }
}

/// Gather the rightmost leaf's existing values followed by the run into a heap
/// buffer (heap allocation never remaps the arena, so the leaf bytes stay
/// valid while they are copied out). The caller owns the returned slice.
fn combineLeafAndRun(
    transaction: anytype,
    leafRef: Reference,
    values: []const u64,
    allocator: std.mem.Allocator,
) ![]u64 {
    const leafView = try parseLeaf(try derefNode(transaction, leafRef));
    const total: usize = @as(usize, leafView.count) + values.len;
    const combinedValues = try allocator.alloc(u64, total);
    var cursor: usize = 0;
    while (cursor < leafView.count) : (cursor += 1) combinedValues[cursor] = leafView.value(cursor);
    for (values) |value| {
        combinedValues[cursor] = value;
        cursor += 1;
    }
    return combinedValues;
}

/// Rebuild the rightmost inner spine bottom-up. At each recorded path level,
/// the shared LEFT children (all but the rightmost) are re-emitted unchanged
/// with their (ref, subtreeCount), and the rightmost child is replaced by the
/// level rebuilt below, which may have grown into several nodes. Packing in
/// runs of fanout splits automatically on overflow; the extra nodes propagate
/// up as additional children of the next level. Replaces `level` in place.
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
            try full.append(allocator, .{ .ref = innerView.childRef(childIndex), .count = innerView.subtreeCount(childIndex) });
        }
        for (level.items) |child| try full.append(allocator, child);
        const next = try stackInner(transaction, full.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Append a run of `values` to the RIGHT EDGE of the column rooted at `root`,
/// returning the new root Reference. Columns are keyed by row index, so a run always
/// lands at the end. Only the rightmost root-to-leaf path is rebuilt; every
/// left subtree is shared unchanged (copy-on-write: shared nodes are never
/// mutated). The result is logically identical to appending every value via
/// append. An empty run returns `root` unchanged.
pub fn appendRun(
    transaction: anytype,
    root: Reference,
    values: []const u64,
    allocator: std.mem.Allocator,
) !Reference {
    if (values.len == 0) return root;

    // 1. Record the rightmost path: it is the only part of the tree rebuilt.
    var pathRefs = std.ArrayList(Reference).empty;
    defer pathRefs.deinit(allocator);
    var pathRightmost = std.ArrayList(usize).empty;
    defer pathRightmost.deinit(allocator);
    const leafRef = try descendRightEdge(transaction, root, &pathRefs, &pathRightmost, allocator);

    // 2. Combine the rightmost leaf's values with the run, then pack the
    //    combined run into leaves filled to leafCap: the first new leaf reuses
    //    the old leaf's content topped up from the front of the run, the rest
    //    are full leaves.
    const combinedValues = try combineLeafAndRun(transaction, leafRef, values, allocator);
    defer allocator.free(combinedValues);
    var level = try packLeaves(transaction, combinedValues, allocator);
    errdefer level.deinit(allocator);

    // 3. Rebuild the rightmost inner spine bottom-up, then stack further inner
    //    levels until a single root remains (the rebuilt root level may have
    //    overflowed fanout into several nodes), growing the tree height by one
    //    or more as needed.
    try rebuildRightSpine(transaction, pathRefs.items, pathRightmost.items, &level, allocator);
    try collapseToRoot(transaction, &level, allocator);

    const result = level.items[0].ref;

    // 4. Free the replaced right-edge nodes (old rightmost leaf + old spine),
    //    exactly as the index appendRun does: they are unreferenced by the new
    //    tree. Frees run before the manual deinit so the errdefer never
    //    double-frees.
    try transaction.free(leafRef, leafNodeSize);
    for (pathRefs.items) |oldRef| try transaction.free(oldRef, innerNodeSize);

    level.deinit(allocator);
    return result;
}

/// Recursive copy-on-write set: copies only the nodes on the path from root to
/// the target leaf. Sibling subtrees are shared by reference, so the old root
/// remains a valid, unchanged snapshot after the call returns.
fn setInto(transaction: anytype, nodeRef: Reference, index: u64, value: u64, depth: usize) !Reference {
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try derefNode(transaction, nodeRef);
    if (bytes[0] == kindLeaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const allocation = try transaction.writableCopy(nodeRef, leafNodeSize);
        const position: usize = @intCast(index);
        const offset: usize = leafHeader + position * 8;
        std.mem.writeInt(u64, allocation.bytes[offset..][0..8], value, .little);
        return allocation.ref;
    } else {
        const view = try parseInner(bytes);
        var remaining = index;
        var targetI: u16 = 0;
        var localIndex: u64 = 0;
        var found = false;
        var childIndex: u16 = 0;
        while (childIndex < view.childCount) : (childIndex += 1) {
            const childTotal = view.subtreeCount(childIndex);
            if (remaining < childTotal) {
                targetI = childIndex;
                localIndex = remaining;
                found = true;
                break;
            }
            remaining -= childTotal;
        }
        if (!found) return error.IndexOutOfBounds;
        // Capture the child ref before the recursive call (bytes may alias mmap).
        const childRef = view.childRef(targetI);
        const newChild = try setInto(transaction, childRef, localIndex, value, depth + 1);
        // COW this inner node and patch only the updated child's ref (count unchanged).
        const allocation = try transaction.writableCopy(nodeRef, innerNodeSize);
        const offset: usize = innerHeader + @as(usize, targetI) * 16;
        std.mem.writeInt(u64, allocation.bytes[offset..][0..8], newChild, .little);
        return allocation.ref;
    }
}

/// Overwrite the value at index. Returns the new root Reference (copy-on-write).
/// Returns error.IndexOutOfBounds if out of range. Works on trees of any depth.
pub fn set(transaction: anytype, root: Reference, index: u64, value: u64) !Reference {
    return setInto(transaction, root, index, value, 0);
}

/// Recursively free every node in the subtree rooted at nodeRef. Leaves and inner
/// nodes are freed at their respective on-disk sizes so the space becomes reclaimable.
pub fn freeTree(transaction: anytype, nodeRef: Reference) !void {
    return freeTreeAt(transaction, nodeRef, 0);
}

fn freeTreeAt(transaction: anytype, nodeRef: Reference, depth: usize) !void {
    if (depth >= maxDepth) return error.Corrupt;
    const bytes = try derefNode(transaction, nodeRef);
    if (bytes[0] == kindLeaf) {
        try transaction.free(nodeRef, leafNodeSize);
    } else {
        const view = try parseInner(bytes);
        var childIndex: u16 = 0;
        // Capture child refs before freeing: parsing reads from the mmap, which we do
        // not mutate here, so the view stays valid for the duration of the loop.
        while (childIndex < view.childCount) : (childIndex += 1) try freeTreeAt(transaction, view.childRef(childIndex), depth + 1);
        try transaction.free(nodeRef, innerNodeSize);
    }
}

/// Shrink the column to newLen entries, dropping all trailing entries and freeing
/// every node of the old tree so the space becomes reclaimable. Returns the new root
/// Reference. newLen must be <= the current length.
///
/// Implemented by rebuilding: a fresh empty column is appended with entries 0..newLen
/// copied from the old column, then the old tree is freed. O(newLen); trimming only the
/// trailing nodes in place (instead of a full rebuild) is a deferred optimization.
pub fn truncate(transaction: anytype, root: Reference, newLen: u64) !Reference {
    std.debug.assert(newLen <= try length(transaction, root));
    var newRoot = try create(transaction);
    var childIndex: u64 = 0;
    while (childIndex < newLen) : (childIndex += 1) {
        const value = try get(transaction, root, childIndex);
        newRoot = try append(transaction, newRoot, value);
    }
    try freeTree(transaction, root);
    return newRoot;
}

/// Test-only helper: allocate an inner node over the given children and return its Reference.
pub fn makeInnerForTest(transaction: anytype, children: []const struct { ref: u64, count: u64 }) !Reference {
    std.debug.assert(children.len <= fanout);
    var refs: [fanout]u64 = undefined;
    var counts: [fanout]u64 = undefined;
    for (children, 0..) |child, childIndex| {
        refs[childIndex] = child.ref;
        counts[childIndex] = child.count;
    }
    const allocation = try transaction.alloc(innerNodeSize);
    _ = encodeInner(allocation.bytes, refs[0..children.len], counts[0..children.len]);
    return allocation.ref;
}

test {
    _ = @import("columnTests.zig");
}
