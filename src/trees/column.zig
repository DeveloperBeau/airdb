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
const Ref = @import("../storage/reference.zig").Ref;
const node = @import("columnNode.zig");

// Local aliases for the on-disk node format, which lives in columnNode.zig.
const LEAF_CAP = node.LEAF_CAP;
const FANOUT = node.FANOUT;
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

/// Allocate an empty leaf column node and return its Ref.
pub fn create(txn: anytype) !Ref {
    const a = try txn.alloc(leaf_node_size);
    _ = encodeLeaf(a.bytes, &.{});
    return a.ref;
}

// A legal tree with fanout 64 covering 2^64 rows is at most ~11 levels deep, so
// any walk deeper than this is following a corrupt ref cycle. Every recursive
// walker carries a depth and fails with error.Corrupt instead of overflowing
// the stack.
pub const max_depth: usize = 16;

/// Deref a node by first reading its kind byte, then dereffing the full node.
fn derefNode(txn: anytype, ref: Ref) ![]const u8 {
    const kind_buf = try txn.deref(ref, 1);
    return switch (kind_buf[0]) {
        kind_leaf => txn.deref(ref, leaf_node_size),
        kind_inner => txn.deref(ref, inner_node_size),
        else => error.Corrupt,
    };
}

/// Return the number of values stored in the column rooted at root.
pub fn len(txn: anytype, root: Ref) !u64 {
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        return count;
    } else {
        const view = try parseInner(bytes);
        var total: u64 = 0;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            total += view.childCount(i);
        }
        return total;
    }
}

/// Return the value at index. Returns error.IndexOutOfBounds if out of range.
pub fn get(txn: anytype, root: Ref, index: u64) !u64 {
    return getAt(txn, root, index, 0);
}

fn getAt(txn: anytype, root: Ref, index: u64, depth: usize) !u64 {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, root);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const idx: usize = @intCast(index);
        const off: usize = leaf_header + idx * 8;
        return std.mem.readInt(u64, bytes[off..][0..8], .little);
    } else {
        const view = try parseInner(bytes);
        var idx = index;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            const cc = view.childCount(i);
            if (idx < cc) return getAt(txn, view.childRef(i), idx, depth + 1);
            idx -= cc;
        }
        return error.IndexOutOfBounds;
    }
}

const AppendResult = struct { ref: Ref, count: u64, split: ?Ref, split_count: u64 };

fn appendInto(txn: anytype, node_ref: Ref, value: u64, depth: usize) !AppendResult {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (count < LEAF_CAP) {
            const a = try txn.writableCopy(node_ref, leaf_node_size);
            std.mem.writeInt(u16, a.bytes[1..3], count + 1, .little);
            const off: usize = leaf_header + @as(usize, count) * 8;
            std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
            return .{ .ref = a.ref, .count = @as(u64, count) + 1, .split = null, .split_count = 0 };
        } else {
            // Full leaf: allocate a new leaf for the new value; leave the old leaf untouched.
            const a = try txn.alloc(leaf_node_size);
            _ = encodeLeaf(a.bytes, &.{value});
            return .{ .ref = node_ref, .count = LEAF_CAP, .split = a.ref, .split_count = 1 };
        }
    } else {
        const view = try parseInner(bytes);
        const child_count = view.child_count;
        const last_idx: usize = @as(usize, child_count) - 1;
        const last_ref = view.childRef(last_idx);
        // Capture old totals before recursion (bytes stay valid: mmap grows in place).
        var old_total: u64 = 0;
        {
            var i: usize = 0;
            while (i < child_count) : (i += 1) old_total += view.childCount(i);
        }
        const old_last_count = view.childCount(last_idx);
        const r = try appendInto(txn, last_ref, value, depth + 1);
        // COW the inner node and update the last child entry.
        const a = try txn.writableCopy(node_ref, inner_node_size);
        const last_off: usize = inner_header + last_idx * 16;
        std.mem.writeInt(u64, a.bytes[last_off..][0..8], r.ref, .little);
        std.mem.writeInt(u64, a.bytes[last_off + 8 ..][0..8], r.count, .little);
        if (r.split == null) {
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count, .split = null, .split_count = 0 };
        } else if (child_count < FANOUT) {
            // Room in this inner: append the new child.
            const new_off: usize = inner_header + @as(usize, child_count) * 16;
            std.mem.writeInt(u16, a.bytes[1..3], child_count + 1, .little);
            const split_ref = r.split.?;
            std.mem.writeInt(u64, a.bytes[new_off..][0..8], split_ref, .little);
            std.mem.writeInt(u64, a.bytes[new_off + 8 ..][0..8], r.split_count, .little);
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count + r.split_count, .split = null, .split_count = 0 };
        } else {
            // Inner full: create a new right inner holding just the split child.
            const new_inner = try txn.alloc(inner_node_size);
            const split_ref = r.split.?;
            _ = encodeInner(new_inner.bytes, &.{split_ref}, &.{r.split_count});
            return .{ .ref = a.ref, .count = old_total - old_last_count + r.count, .split = new_inner.ref, .split_count = r.split_count };
        }
    }
}

/// Append value to the column. Returns the new root Ref (copy-on-write).
/// Grows the tree through leaf splits and height increases as needed.
pub fn append(txn: anytype, root: Ref, value: u64) !Ref {
    const r = try appendInto(txn, root, value, 0);
    if (r.split == null) return r.ref;
    // Split propagated to the root: grow height by one.
    const a = try txn.alloc(inner_node_size);
    const split_ref = r.split.?;
    _ = encodeInner(a.bytes, &.{ r.ref, split_ref }, &.{ r.count, r.split_count });
    return a.ref;
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

/// Pack `values` into leaves filled to LEAF_CAP in row order. Returns the leaf
/// level: one Child per leaf, count == the number of values in that leaf.
pub fn packLeaves(
    txn: anytype,
    values: []const u64,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const cap: usize = LEAF_CAP;
    var i: usize = 0;
    while (i < values.len) {
        const end = @min(i + cap, values.len);
        const a = try txn.alloc(leaf_node_size);
        _ = encodeLeaf(a.bytes, values[i..end]);
        try out.append(allocator, .{ .ref = a.ref, .count = @intCast(end - i) });
        i = end;
    }
    return out;
}

/// Build one inner level over `children`, packed in runs of FANOUT. A column
/// inner node stores (child_ref, subtree_count); a parent's count is the SUM
/// of its children's counts, so each emitted node's count == the total of its
/// run.
pub fn stackInner(
    txn: anytype,
    children: []const Child,
    allocator: std.mem.Allocator,
) !std.ArrayList(Child) {
    var out = std.ArrayList(Child).empty;
    errdefer out.deinit(allocator);
    const fan: usize = FANOUT;
    var refs: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    var j: usize = 0;
    while (j < children.len) {
        const end = @min(j + fan, children.len);
        var total: u64 = 0;
        var k: usize = j;
        while (k < end) : (k += 1) {
            refs[k - j] = children[k].ref;
            counts[k - j] = children[k].count;
            total += children[k].count;
        }
        const cnt = end - j;
        const a = try txn.alloc(inner_node_size);
        _ = encodeInner(a.bytes, refs[0..cnt], counts[0..cnt]);
        try out.append(allocator, .{ .ref = a.ref, .count = total });
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

/// Descend the rightmost root-to-leaf path (always the last child), recording
/// each inner node and the index of its rightmost child, and return the
/// rightmost leaf's ref. No arena allocation occurs here, so the deref'd node
/// bytes stay valid for the duration of each iteration.
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
        const ri: usize = @as(usize, iv.child_count) - 1;
        const child = iv.childRef(ri);
        try path_refs.append(allocator, cur);
        try path_ridx.append(allocator, ri);
        cur = child;
    }
}

/// Gather the rightmost leaf's existing values followed by the run into a heap
/// buffer (heap allocation never remaps the arena, so the leaf bytes stay
/// valid while they are copied out). The caller owns the returned slice.
fn combineLeafAndRun(
    txn: anytype,
    leaf_ref: Ref,
    values: []const u64,
    allocator: std.mem.Allocator,
) ![]u64 {
    const lv = try parseLeaf(try derefNode(txn, leaf_ref));
    const total: usize = @as(usize, lv.count) + values.len;
    const cvals = try allocator.alloc(u64, total);
    var t: usize = 0;
    while (t < lv.count) : (t += 1) cvals[t] = lv.value(t);
    for (values) |v| {
        cvals[t] = v;
        t += 1;
    }
    return cvals;
}

/// Rebuild the rightmost inner spine bottom-up. At each recorded path level,
/// the shared LEFT children (all but the rightmost) are re-emitted unchanged
/// with their (ref, subtree_count), and the rightmost child is replaced by the
/// level rebuilt below, which may have grown into several nodes. Packing in
/// runs of FANOUT splits automatically on overflow; the extra nodes propagate
/// up as additional children of the next level. Replaces `level` in place.
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
            try full.append(allocator, .{ .ref = iv.childRef(j), .count = iv.childCount(j) });
        }
        for (level.items) |c| try full.append(allocator, c);
        const next = try stackInner(txn, full.items, allocator);
        level.deinit(allocator);
        level.* = next;
    }
}

/// Append a run of `values` to the RIGHT EDGE of the column rooted at `root`,
/// returning the new root Ref. Columns are keyed by row index, so a run always
/// lands at the end. Only the rightmost root-to-leaf path is rebuilt; every
/// left subtree is shared unchanged (copy-on-write: shared nodes are never
/// mutated). The result is logically identical to appending every value via
/// append. An empty run returns `root` unchanged.
pub fn appendRun(
    txn: anytype,
    root: Ref,
    values: []const u64,
    allocator: std.mem.Allocator,
) !Ref {
    if (values.len == 0) return root;

    // 1. Record the rightmost path: it is the only part of the tree rebuilt.
    var path_refs = std.ArrayList(Ref).empty;
    defer path_refs.deinit(allocator);
    var path_ridx = std.ArrayList(usize).empty;
    defer path_ridx.deinit(allocator);
    const leaf_ref = try descendRightEdge(txn, root, &path_refs, &path_ridx, allocator);

    // 2. Combine the rightmost leaf's values with the run, then pack the
    //    combined run into leaves filled to LEAF_CAP: the first new leaf reuses
    //    the old leaf's content topped up from the front of the run, the rest
    //    are full leaves.
    const cvals = try combineLeafAndRun(txn, leaf_ref, values, allocator);
    defer allocator.free(cvals);
    var level = try packLeaves(txn, cvals, allocator);
    errdefer level.deinit(allocator);

    // 3. Rebuild the rightmost inner spine bottom-up, then stack further inner
    //    levels until a single root remains (the rebuilt root level may have
    //    overflowed FANOUT into several nodes), growing the tree height by one
    //    or more as needed.
    try rebuildRightSpine(txn, path_refs.items, path_ridx.items, &level, allocator);
    try collapseToRoot(txn, &level, allocator);

    const result = level.items[0].ref;

    // 4. Free the replaced right-edge nodes (old rightmost leaf + old spine),
    //    exactly as the index appendRun does: they are unreferenced by the new
    //    tree. Frees run before the manual deinit so the errdefer never
    //    double-frees.
    try txn.free(leaf_ref, leaf_node_size);
    for (path_refs.items) |old_ref| try txn.free(old_ref, inner_node_size);

    level.deinit(allocator);
    return result;
}

/// Recursive copy-on-write set: copies only the nodes on the path from root to
/// the target leaf. Sibling subtrees are shared by reference, so the old root
/// remains a valid, unchanged snapshot after the call returns.
fn setInto(txn: anytype, node_ref: Ref, index: u64, value: u64, depth: usize) !Ref {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        const count = std.mem.readInt(u16, bytes[1..3], .little);
        if (index >= count) return error.IndexOutOfBounds;
        const a = try txn.writableCopy(node_ref, leaf_node_size);
        const idx: usize = @intCast(index);
        const off: usize = leaf_header + idx * 8;
        std.mem.writeInt(u64, a.bytes[off..][0..8], value, .little);
        return a.ref;
    } else {
        const view = try parseInner(bytes);
        var idx = index;
        var target_i: u16 = 0;
        var local_index: u64 = 0;
        var found = false;
        var i: u16 = 0;
        while (i < view.child_count) : (i += 1) {
            const cc = view.childCount(i);
            if (idx < cc) {
                target_i = i;
                local_index = idx;
                found = true;
                break;
            }
            idx -= cc;
        }
        if (!found) return error.IndexOutOfBounds;
        // Capture the child ref before the recursive call (bytes may alias mmap).
        const child_ref = view.childRef(target_i);
        const new_child = try setInto(txn, child_ref, local_index, value, depth + 1);
        // COW this inner node and patch only the updated child's ref (count unchanged).
        const a = try txn.writableCopy(node_ref, inner_node_size);
        const off: usize = inner_header + @as(usize, target_i) * 16;
        std.mem.writeInt(u64, a.bytes[off..][0..8], new_child, .little);
        return a.ref;
    }
}

/// Overwrite the value at index. Returns the new root Ref (copy-on-write).
/// Returns error.IndexOutOfBounds if out of range. Works on trees of any depth.
pub fn set(txn: anytype, root: Ref, index: u64, value: u64) !Ref {
    return setInto(txn, root, index, value, 0);
}

/// Recursively free every node in the subtree rooted at node_ref. Leaves and inner
/// nodes are freed at their respective on-disk sizes so the space becomes reclaimable.
pub fn freeTree(txn: anytype, node_ref: Ref) !void {
    return freeTreeAt(txn, node_ref, 0);
}

fn freeTreeAt(txn: anytype, node_ref: Ref, depth: usize) !void {
    if (depth >= max_depth) return error.Corrupt;
    const bytes = try derefNode(txn, node_ref);
    if (bytes[0] == kind_leaf) {
        try txn.free(node_ref, leaf_node_size);
    } else {
        const view = try parseInner(bytes);
        var i: u16 = 0;
        // Capture child refs before freeing: parsing reads from the mmap, which we do
        // not mutate here, so the view stays valid for the duration of the loop.
        while (i < view.child_count) : (i += 1) try freeTreeAt(txn, view.childRef(i), depth + 1);
        try txn.free(node_ref, inner_node_size);
    }
}

/// Shrink the column to new_len entries, dropping all trailing entries and freeing
/// every node of the old tree so the space becomes reclaimable. Returns the new root
/// Ref. new_len must be <= the current length.
///
/// Implemented by rebuilding: a fresh empty column is appended with entries 0..new_len
/// copied from the old column, then the old tree is freed. O(new_len); trimming only the
/// trailing nodes in place (instead of a full rebuild) is a deferred optimization.
pub fn truncate(txn: anytype, root: Ref, new_len: u64) !Ref {
    std.debug.assert(new_len <= try len(txn, root));
    var new_root = try create(txn);
    var i: u64 = 0;
    while (i < new_len) : (i += 1) {
        const value = try get(txn, root, i);
        new_root = try append(txn, new_root, value);
    }
    try freeTree(txn, root);
    return new_root;
}

/// Test-only helper: allocate an inner node over the given children and return its Ref.
pub fn makeInnerForTest(txn: anytype, children: []const struct { ref: u64, count: u64 }) !Ref {
    std.debug.assert(children.len <= FANOUT);
    var refs: [FANOUT]u64 = undefined;
    var counts: [FANOUT]u64 = undefined;
    for (children, 0..) |c, i| {
        refs[i] = c.ref;
        counts[i] = c.count;
    }
    const a = try txn.alloc(inner_node_size);
    _ = encodeInner(a.bytes, refs[0..children.len], counts[0..children.len]);
    return a.ref;
}

test {
    _ = @import("columnTests.zig");
}
