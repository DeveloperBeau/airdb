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
const node = @import("column_node.zig");

// Local aliases for the on-disk node format, which lives in column_node.zig.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("columnTests.zig");
}
