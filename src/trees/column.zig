// The `transaction` parameter of every operation is `anytype`: a comptime duck-typed
// transaction capability, monomorphized at compile time (no vtable on this
// B+tree hot path). Read-only operations need only
//   deref(ref, length) ![]const u8
// and mutating operations additionally require
//   alloc(size) !Allocation, writableCopy(ref, length) !Allocation,
//   free(ref, length) !void
// where Allocation is arena.Allocation. WriteTransaction is the production
// implementation; ReadTransaction satisfies the read-only subset.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const node = @import("columnNode.zig");

// Local aliases for the on-disk node format, which lives in columnNode.zig.
const leafCap = node.leafCap;
const fanout = node.fanout;
const kind_leaf = node.kind_leaf;
const kind_inner = node.kind_inner;
const leaf_node_size = node.leaf_node_size;
const leaf_header = node.leaf_header;
const inner_node_size = node.inner_node_size;
const inner_header = node.inner_header;
const encodeLeaf = node.encodeLeaf;
const parseLeaf = node.parseLeaf;
const LeafView = node.LeafView;
const encodeInner = node.encodeInner;
const parseInner = node.parseInner;
const InnerView = node.InnerView;

// ---------------------------------------------------------------------------
// Column operations (Tasks 2-3)
// Task 4 will add leaf splitting.
// ---------------------------------------------------------------------------

/// Allocate an empty leaf column node and return its Reference.
pub fn create(transaction: anytype) !Reference {
    const allocation = try transaction.alloc(leaf_node_size);
    _ = encodeLeaf(allocation.bytes, &.{});
    return allocation.ref;
}

// A legal tree with fanout 64 covering 2^64 rows is at most ~11 levels deep, so
// any walk deeper than this is following a corrupt ref cycle. Every recursive
// walker carries a depth and fails with error.Corrupt instead of overflowing
// the stack.
pub const max_depth: usize = 16;

/// Deref a node by first reading its kind byte, then dereffing the full node.
fn derefNode(transaction: anytype, ref: Reference) ![]const u8 {
    const kindBuffer = try transaction.deref(ref, 1);
    return switch (kindBuffer[0]) {
        kind_leaf => transaction.deref(ref, leaf_node_size),
        kind_inner => transaction.deref(ref, inner_node_size),
        else => error.Corrupt,
    };
}

/// Return the number of values stored in the column rooted at root.
pub fn length(transaction: anytype, root: Reference) !u64 {
    const bytes = try derefNode(transaction, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        return count;
    } else {
        const view = try parseInner(bytes);
        var total: u64 = 0;
        var childIndex: u16 = 0;
        while (childIndex < view.child_count) : (childIndex += 1) {
            total += view.childCount(childIndex);
        }
        return total;
    }
}

/// Return the value at index. Returns error.IndexOutOfBounds if out of range.
pub fn get(transaction: anytype, root: Reference, index: u64) !u64 {
    return getAt(transaction, root, index, 0);
}

fn getAt(transaction: anytype, root: Reference, index: u64, depth: usize) !u64 {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(transaction, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const position: usize = @intCast(index);
        const offset: usize = leaf_header + position * 8;
        return std.mem.readInt(u64, bytes[offset..][0..8], .little);
    } else {
        const view = try parseInner(bytes);
        var remaining = index;
        var childIndex: u16 = 0;
        while (childIndex < view.child_count) : (childIndex += 1) {
            const childTotal = view.childCount(childIndex);
            if (remaining < childTotal) return getAt(transaction, view.childRef(childIndex), remaining, depth + 1);
            remaining -= childTotal;
        }
        return error.IndexOutOfBounds;
    }
}

const AppendResult = struct { ref: Reference, count: u64, split: ?Reference, split_count: u64 };

fn appendInto(transaction: anytype, node_ref: Reference, value: u64, depth: usize) !AppendResult {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(transaction, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (count < leafCap) {
            const allocation = try transaction.writableCopy(node_ref, leaf_node_size);
            std.mem.writeInt(u16, allocation.bytes[1..3], count + 1, .little);
            const offset: usize = leaf_header + @as(usize, count) * 8;
            std.mem.writeInt(u64, allocation.bytes[offset..][0..8], value, .little);
            return .{ .ref = allocation.ref, .count = @as(u64, count) + 1, .split = null, .split_count = 0 };
        } else {
            // Full leaf: allocate a new leaf for the new value; leave the old leaf untouched.
            const allocation = try transaction.alloc(leaf_node_size);
            _ = encodeLeaf(allocation.bytes, &.{value});
            return .{ .ref = node_ref, .count = leafCap, .split = allocation.ref, .split_count = 1 };
        }
    } else {
        const view = try parseInner(bytes);
        const child_count = view.child_count;
        const lastChildIndex: usize = @as(usize, child_count) - 1;
        const last_ref = view.childRef(lastChildIndex);
        // Capture old totals before recursion (bytes stay valid: mmap grows in place).
        var old_total: u64 = 0;
        {
            var childIndex: usize = 0;
            while (childIndex < child_count) : (childIndex += 1) old_total += view.childCount(childIndex);
        }
        const old_last_count = view.childCount(lastChildIndex);
        const result = try appendInto(transaction, last_ref, value, depth + 1);
        // COW the inner node and update the last child entry.
        const allocation = try transaction.writableCopy(node_ref, inner_node_size);
        const last_off: usize = inner_header + lastChildIndex * 16;
        std.mem.writeInt(u64, allocation.bytes[last_off..][0..8], result.ref, .little);
        std.mem.writeInt(u64, allocation.bytes[last_off + 8 ..][0..8], result.count, .little);
        if (result.split == null) {
            return .{ .ref = allocation.ref, .count = old_total - old_last_count + result.count, .split = null, .split_count = 0 };
        } else if (child_count < fanout) {
            // Room in this inner: append the new child.
            const new_off: usize = inner_header + @as(usize, child_count) * 16;
            std.mem.writeInt(u16, allocation.bytes[1..3], child_count + 1, .little);
            const split_ref = result.split.?;
            std.mem.writeInt(u64, allocation.bytes[new_off..][0..8], split_ref, .little);
            std.mem.writeInt(u64, allocation.bytes[new_off + 8 ..][0..8], result.split_count, .little);
            return .{ .ref = allocation.ref, .count = old_total - old_last_count + result.count + result.split_count, .split = null, .split_count = 0 };
        } else {
            // Inner full: create a new right inner holding just the split child.
            const new_inner = try transaction.alloc(inner_node_size);
            const split_ref = result.split.?;
            _ = encodeInner(new_inner.bytes, &.{split_ref}, &.{result.split_count});
            return .{ .ref = allocation.ref, .count = old_total - old_last_count + result.count, .split = new_inner.ref, .split_count = result.split_count };
        }
    }
}

/// Append value to the column. Returns the new root Reference (copy-on-write).
/// Grows the tree through leaf splits and height increases as needed.
pub fn append(transaction: anytype, root: Reference, value: u64) !Reference {
    const result = try appendInto(transaction, root, value, 0);
    if (result.split == null) return result.ref;
    // Split propagated to the root: grow height by one.
    const allocation = try transaction.alloc(inner_node_size);
    const split_ref = result.split.?;
    _ = encodeInner(allocation.bytes, &.{ result.ref, split_ref }, &.{ result.count, result.split_count });
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
/// (which carries a low key), a column inner node stores (child_ref,
/// subtree_count) and a parent's own count is the SUM of its children's counts.
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
        const allocation = try transaction.alloc(leaf_node_size);
        _ = encodeLeaf(allocation.bytes, values[start..end]);
        try out.append(allocator, .{ .ref = allocation.ref, .count = @intCast(end - start) });
        start = end;
    }
    return out;
}

/// Build one inner level over `children`, packed in runs of fanout. A column
/// inner node stores (child_ref, subtree_count); a parent's count is the SUM
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
        const allocation = try transaction.alloc(inner_node_size);
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
    path_refs: *std.ArrayList(Reference),
    path_rightmost: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !Reference {
    var currentRef: Reference = root;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= max_depth) return error.Corrupt; // ref cycle guard
        const nodeBytes = try derefNode(transaction, currentRef);
        if (nodeBytes[0] == kind_leaf) return currentRef;
        const innerView = try parseInner(nodeBytes);
        const rightmostIndex: usize = @as(usize, innerView.child_count) - 1;
        const child = innerView.childRef(rightmostIndex);
        try path_refs.append(allocator, currentRef);
        try path_rightmost.append(allocator, rightmostIndex);
        currentRef = child;
    }
}

/// Gather the rightmost leaf's existing values followed by the run into a heap
/// buffer (heap allocation never remaps the arena, so the leaf bytes stay
/// valid while they are copied out). The caller owns the returned slice.
fn combineLeafAndRun(
    transaction: anytype,
    leaf_ref: Reference,
    values: []const u64,
    allocator: std.mem.Allocator,
) ![]u64 {
    const leafView = try parseLeaf(try derefNode(transaction, leaf_ref));
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
/// with their (ref, subtree_count), and the rightmost child is replaced by the
/// level rebuilt below, which may have grown into several nodes. Packing in
/// runs of fanout splits automatically on overflow; the extra nodes propagate
/// up as additional children of the next level. Replaces `level` in place.
fn rebuildRightSpine(
    transaction: anytype,
    path_refs: []const Reference,
    path_rightmost: []const usize,
    level: *std.ArrayList(Child),
    allocator: std.mem.Allocator,
) !void {
    var levelIndex: usize = path_refs.len;
    while (levelIndex > 0) {
        levelIndex -= 1;
        const innerView = try parseInner(try derefNode(transaction, path_refs[levelIndex]));
        const rightmostIndex = path_rightmost[levelIndex];
        var full = std.ArrayList(Child).empty;
        defer full.deinit(allocator);
        var childIndex: usize = 0;
        while (childIndex < rightmostIndex) : (childIndex += 1) {
            try full.append(allocator, .{ .ref = innerView.childRef(childIndex), .count = innerView.childCount(childIndex) });
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
    var path_refs = std.ArrayList(Reference).empty;
    defer path_refs.deinit(allocator);
    var path_rightmost = std.ArrayList(usize).empty;
    defer path_rightmost.deinit(allocator);
    const leaf_ref = try descendRightEdge(transaction, root, &path_refs, &path_rightmost, allocator);

    // 2. Combine the rightmost leaf's values with the run, then pack the
    //    combined run into leaves filled to leafCap: the first new leaf reuses
    //    the old leaf's content topped up from the front of the run, the rest
    //    are full leaves.
    const combinedValues = try combineLeafAndRun(transaction, leaf_ref, values, allocator);
    defer allocator.free(combinedValues);
    var level = try packLeaves(transaction, combinedValues, allocator);
    errdefer level.deinit(allocator);

    // 3. Rebuild the rightmost inner spine bottom-up, then stack further inner
    //    levels until a single root remains (the rebuilt root level may have
    //    overflowed fanout into several nodes), growing the tree height by one
    //    or more as needed.
    try rebuildRightSpine(transaction, path_refs.items, path_rightmost.items, &level, allocator);
    try collapseToRoot(transaction, &level, allocator);

    const result = level.items[0].ref;

    // 4. Free the replaced right-edge nodes (old rightmost leaf + old spine),
    //    exactly as the index appendRun does: they are unreferenced by the new
    //    tree. Frees run before the manual deinit so the errdefer never
    //    double-frees.
    try transaction.free(leaf_ref, leaf_node_size);
    for (path_refs.items) |old_ref| try transaction.free(old_ref, inner_node_size);

    level.deinit(allocator);
    return result;
}

/// Recursive copy-on-write set: copies only the nodes on the path from root to
/// the target leaf. Sibling subtrees are shared by reference, so the old root
/// remains a valid, unchanged snapshot after the call returns.
fn setInto(transaction: anytype, node_ref: Reference, index: u64, value: u64, depth: usize) !Reference {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(transaction, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const allocation = try transaction.writableCopy(node_ref, leaf_node_size);
        const position: usize = @intCast(index);
        const offset: usize = leaf_header + position * 8;
        std.mem.writeInt(u64, allocation.bytes[offset..][0..8], value, .little);
        return allocation.ref;
    } else {
        const view = try parseInner(bytes);
        var remaining = index;
        var target_i: u16 = 0;
        var local_index: u64 = 0;
        var found = false;
        var childIndex: u16 = 0;
        while (childIndex < view.child_count) : (childIndex += 1) {
            const childTotal = view.childCount(childIndex);
            if (remaining < childTotal) {
                target_i = childIndex;
                local_index = remaining;
                found = true;
                break;
            }
            remaining -= childTotal;
        }
        if (!found) return error.IndexOutOfBounds;
        // Capture the child ref before the recursive call (bytes may alias mmap).
        const child_ref = view.childRef(target_i);
        const new_child = try setInto(transaction, child_ref, local_index, value, depth + 1);
        // COW this inner node and patch only the updated child's ref (count unchanged).
        const allocation = try transaction.writableCopy(node_ref, inner_node_size);
        const offset: usize = inner_header + @as(usize, target_i) * 16;
        std.mem.writeInt(u64, allocation.bytes[offset..][0..8], new_child, .little);
        return allocation.ref;
    }
}

/// Overwrite the value at index. Returns the new root Reference (copy-on-write).
/// Returns error.IndexOutOfBounds if out of range. Works on trees of any depth.
pub fn set(transaction: anytype, root: Reference, index: u64, value: u64) !Reference {
    return setInto(transaction, root, index, value, 0);
}

/// Recursively free every node in the subtree rooted at node_ref. Leaves and inner
/// nodes are freed at their respective on-disk sizes so the space becomes reclaimable.
pub fn freeTree(transaction: anytype, node_ref: Reference) !void {
    return freeTreeAt(transaction, node_ref, 0);
}

fn freeTreeAt(transaction: anytype, node_ref: Reference, depth: usize) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(transaction, node_ref);
    if (bytes[0] == kind_leaf) {
        try transaction.free(node_ref, leaf_node_size);
    } else {
        const view = try parseInner(bytes);
        var childIndex: u16 = 0;
        // Capture child refs before freeing: parsing reads from the mmap, which we do
        // not mutate here, so the view stays valid for the duration of the loop.
        while (childIndex < view.child_count) : (childIndex += 1) try freeTreeAt(transaction, view.childRef(childIndex), depth + 1);
        try transaction.free(node_ref, inner_node_size);
    }
}

/// Shrink the column to new_len entries, dropping all trailing entries and freeing
/// every node of the old tree so the space becomes reclaimable. Returns the new root
/// Reference. new_len must be <= the current length.
///
/// Implemented by rebuilding: a fresh empty column is appended with entries 0..new_len
/// copied from the old column, then the old tree is freed. O(new_len); trimming only the
/// trailing nodes in place (instead of a full rebuild) is a deferred optimization.
pub fn truncate(transaction: anytype, root: Reference, new_len: u64) !Reference {
    std.debug.assert(new_len <= try length(transaction, root));
    var new_root = try create(transaction);
    var childIndex: u64 = 0;
    while (childIndex < new_len) : (childIndex += 1) {
        const value = try get(transaction, root, childIndex);
        new_root = try append(transaction, new_root, value);
    }
    try freeTree(transaction, root);
    return new_root;
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
    const allocation = try transaction.alloc(inner_node_size);
    _ = encodeInner(allocation.bytes, refs[0..children.len], counts[0..children.len]);
    return allocation.ref;
}

test {
    _ = @import("columnTests.zig");
}
