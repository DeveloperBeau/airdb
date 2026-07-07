// bTreeCore.zig -- the comptime-generic B+tree shared by index.zig (inline
// numeric keys) and byteKeyIndex.zig (blob-ref byte keys). Both trees use the
// on-disk node layout of indexNode.zig; the only difference between them is
// how the u64 stored in a key slot relates to the key a caller searches with.
// That difference is captured by the comptime `Keying` capability, so every
// operation here is monomorphized per instantiation: no function pointers and
// no vtables on this hot path.
//
// The `transaction` parameter of every operation is `anytype`: a comptime
// duck-typed transaction capability, monomorphized at compile time.
// Read-only operations need only
//   deref(ref, len) ![]const u8
// and mutating operations additionally require
//   alloc(size) !Allocation, writableCopy(ref, len) !Allocation,
//   free(ref, len) !void
// where Allocation is arena.Allocation. WriteTransaction is the production
// implementation; ReadTransaction satisfies the read-only subset.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const indexNode = @import("indexNode.zig");

// Local aliases for the on-disk node format, which lives in indexNode.zig.
const leafCapacity = indexNode.LEAF_CAP;
const fanout = indexNode.FANOUT;
const kindLeaf = indexNode.kind_leaf;
const kindInner = indexNode.kind_inner;
const headerSize = indexNode.hdr;
const leafNodeSize = indexNode.leaf_node_size;
const innerNodeSize = indexNode.inner_node_size;
const innerStride = indexNode.inner_stride;
const encodeLeaf = indexNode.encodeLeaf;
const parseLeaf = indexNode.parseLeaf;
const LeafView = indexNode.LeafView;
const encodeInner = indexNode.encodeInner;
const parseInner = indexNode.parseInner;
const InnerView = indexNode.InnerView;

/// Corrupt-cycle guard for every recursive walker: a legal tree over 2^64
/// keys with fanout 64 is at most ~11 levels deep, so any walk deeper than
/// this is following a corrupt ref cycle. Walkers carry a depth and fail with
/// error.Corrupt instead of overflowing the stack.
pub const maxDepth: usize = 16;

// A split's right sibling and an insert's resulting node both carry their
// subtree entry count so the parent can maintain the per-child counts that
// make count a single-node read.
const Split = struct { ref: Reference, low: u64, count: u64 };
const InsertResult = struct { ref: Reference, count: u64, split: ?Split };
const RemoveResult = struct { ref: Reference, count: u64 };

/// Shared B+tree operations over the indexNode.zig layout, specialized by a
/// comptime `Keying` capability that decides how the u64 stored in each key
/// slot is ordered against a caller-supplied probe key and how key material
/// is duplicated and freed. `Keying` must declare:
///   ProbeKey
///     the caller-facing search-key type;
///   order(transaction, storedKey, probeKey) !std.math.Order
///     order of the stored key relative to the probe key;
///   duplicateKey(transaction, storedKey) !u64
///     an independently owned copy of a stored key, for routing separators;
///   freeKey(transaction, storedKey) !void
///     release of any key material a slot owns.
/// For inline keys, order is numeric, duplicateKey is identity, and freeKey
/// is a no-op; for out-of-node keys (blob refs) they dereference, copy, and
/// release the referenced bytes.
pub fn BTreeCore(comptime Keying: type) type {
    return struct {
        /// Create a new empty leaf node and return its Reference.
        pub fn create(transaction: anytype) !Reference {
            const allocation = try transaction.alloc(leafNodeSize);
            _ = encodeLeaf(allocation.bytes, &.{}, &.{});
            return allocation.ref;
        }

        /// Deref a node, sizing the read by its kind byte (leaf vs inner).
        pub fn derefNode(transaction: anytype, ref: Reference) ![]const u8 {
            const kindBytes = try transaction.deref(ref, 1);
            return switch (kindBytes[0]) {
                kindLeaf => transaction.deref(ref, leafNodeSize),
                kindInner => transaction.deref(ref, innerNodeSize),
                else => error.Corrupt,
            };
        }

        /// Return the largest child index whose low key is <= probeKey, or 0
        /// if probeKey precedes every low key: the child whose key range
        /// holds probeKey during descent.
        pub fn childIndexForKey(transaction: anytype, inner: InnerView, probeKey: Keying.ProbeKey) !usize {
            var best: usize = 0;
            var childIndex: usize = 0;
            while (childIndex < inner.child_count) : (childIndex += 1) {
                // lowKey <= probeKey  <=>  order(lowKey, probeKey) is not .gt.
                if ((try Keying.order(transaction, inner.lowKey(childIndex), probeKey)) != .gt) {
                    best = childIndex;
                } else {
                    break;
                }
            }
            return best;
        }

        /// First leaf-slot index whose stored key is >= probeKey.
        fn leafLowerBound(transaction: anytype, leaf: LeafView, probeKey: Keying.ProbeKey) !usize {
            var low: usize = 0;
            var high: usize = leaf.count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if ((try Keying.order(transaction, leaf.key(middle), probeKey)) == .lt) {
                    low = middle + 1;
                } else {
                    high = middle;
                }
            }
            return low;
        }

        /// Look up probeKey in the tree rooted at root. Returns the value on
        /// an exactly-equal stored key, else null. O(height) with I/O.
        pub fn get(transaction: anytype, root: Reference, probeKey: Keying.ProbeKey) !?u64 {
            return getAt(transaction, root, probeKey, 0);
        }

        fn getAt(transaction: anytype, root: Reference, probeKey: Keying.ProbeKey, depth: usize) !?u64 {
            if (depth >= maxDepth) return error.Corrupt;
            const bytes = try derefNode(transaction, root);
            if (bytes[0] == kindLeaf) {
                const leaf = try parseLeaf(bytes);
                const slot = try leafLowerBound(transaction, leaf, probeKey);
                if (slot < leaf.count and (try Keying.order(transaction, leaf.key(slot), probeKey)) == .eq) {
                    return leaf.value(slot);
                }
                return null;
            }
            // Inner node: descend into the child whose range holds probeKey.
            const inner = try parseInner(bytes);
            const childIndex = try childIndexForKey(transaction, inner, probeKey);
            return getAt(transaction, inner.childRef(childIndex), probeKey, depth + 1);
        }

        /// Descend the leftmost spine to the leftmost leaf and return its
        /// first (smallest) stored key. O(height) with I/O.
        fn minKey(transaction: anytype, ref: Reference) !u64 {
            var current: Reference = ref;
            var depth: usize = 0;
            while (depth < maxDepth) : (depth += 1) {
                const bytes = try derefNode(transaction, current);
                if (bytes[0] == kindLeaf) {
                    const leaf = try parseLeaf(bytes);
                    return leaf.key(0);
                }
                const inner = try parseInner(bytes);
                current = inner.childRef(0);
            }
            return error.Corrupt;
        }

        /// Recursive insert. Returns the (possibly new) node ref and an
        /// optional right sibling produced by a midpoint split. Deliberately
        /// one long function: it is a single-pass B+tree insert whose
        /// leaf/inner upsert, shift, and midpoint-split cases all share the
        /// split-propagation state -- one irreducible algorithm rather than
        /// separable steps.
        fn insertInto(transaction: anytype, nodeRef: Reference, probeKey: Keying.ProbeKey, storedKey: u64, value: u64, depth: usize) !InsertResult {
            if (depth >= maxDepth) return error.Corrupt;
            const kind = (try transaction.deref(nodeRef, 1))[0];

            // ---- LEAF -----------------------------------------------------
            if (kind == kindLeaf) {
                const leafBytes = try transaction.deref(nodeRef, leafNodeSize);
                const leaf = try parseLeaf(leafBytes);
                const slot = try leafLowerBound(transaction, leaf, probeKey);

                // Upsert: key already present. The existing slot keeps its
                // stored key, so the caller's storedKey is redundant and any
                // key material it owns is released.
                if (slot < leaf.count and (try Keying.order(transaction, leaf.key(slot), probeKey)) == .eq) {
                    const updated = try transaction.writableCopy(nodeRef, leafNodeSize);
                    std.mem.writeInt(u64, updated.bytes[headerSize + slot * 16 + 8 ..][0..8], value, .little);
                    try Keying.freeKey(transaction, storedKey);
                    return InsertResult{ .ref = updated.ref, .count = leaf.count, .split = null };
                }

                // Not full: shift the tail right and insert at slot.
                if (leaf.count < leafCapacity) {
                    const updated = try transaction.writableCopy(nodeRef, leafNodeSize);
                    var moveSlot: usize = leaf.count;
                    while (moveSlot > slot) : (moveSlot -= 1) {
                        const source = headerSize + (moveSlot - 1) * 16;
                        const destination = headerSize + moveSlot * 16;
                        @memcpy(updated.bytes[destination..][0..16], updated.bytes[source..][0..16]);
                    }
                    std.mem.writeInt(u64, updated.bytes[headerSize + slot * 16 ..][0..8], storedKey, .little);
                    std.mem.writeInt(u64, updated.bytes[headerSize + slot * 16 + 8 ..][0..8], value, .little);
                    std.mem.writeInt(u16, updated.bytes[1..3], leaf.count + 1, .little);
                    return InsertResult{ .ref = updated.ref, .count = @as(u64, leaf.count) + 1, .split = null };
                }

                // Full: build leafCapacity+1 sorted pairs, split at the
                // midpoint. Buffers are filled from `leaf` before writableCopy
                // to avoid any aliasing concern.
                const totalPairs: usize = @as(usize, leafCapacity) + 1;
                var keySlots: [leafCapacity + 1]u64 = undefined;
                var valueSlots: [leafCapacity + 1]u64 = undefined;
                var copySlot: usize = 0;
                while (copySlot < slot) : (copySlot += 1) {
                    keySlots[copySlot] = leaf.key(copySlot);
                    valueSlots[copySlot] = leaf.value(copySlot);
                }
                keySlots[slot] = storedKey;
                valueSlots[slot] = value;
                copySlot = slot;
                while (copySlot < leaf.count) : (copySlot += 1) {
                    keySlots[copySlot + 1] = leaf.key(copySlot);
                    valueSlots[copySlot + 1] = leaf.value(copySlot);
                }
                const midpoint: usize = totalPairs / 2;
                const left = try transaction.writableCopy(nodeRef, leafNodeSize);
                std.mem.writeInt(u16, left.bytes[1..3], @intCast(midpoint), .little);
                copySlot = 0;
                while (copySlot < midpoint) : (copySlot += 1) {
                    std.mem.writeInt(u64, left.bytes[headerSize + copySlot * 16 ..][0..8], keySlots[copySlot], .little);
                    std.mem.writeInt(u64, left.bytes[headerSize + copySlot * 16 + 8 ..][0..8], valueSlots[copySlot], .little);
                }
                const right = try transaction.alloc(leafNodeSize);
                _ = encodeLeaf(right.bytes, keySlots[midpoint..totalPairs], valueSlots[midpoint..totalPairs]);
                // The separator handed to the parent must be independently
                // owned when key material lives outside the node: aliasing
                // the right leaf's slot-0 stored key would leave every
                // ancestor referencing key material that removeInto may
                // free. Keying decides -- identity for inline keys.
                const boundaryLow = try Keying.duplicateKey(transaction, keySlots[midpoint]);
                return InsertResult{
                    .ref = left.ref,
                    .count = midpoint,
                    .split = Split{ .ref = right.ref, .low = boundaryLow, .count = totalPairs - midpoint },
                };
            }

            // ---- INNER ----------------------------------------------------
            const innerBytes = try transaction.deref(nodeRef, innerNodeSize);
            const inner = try parseInner(innerBytes);
            const childIndex = try childIndexForKey(transaction, inner, probeKey);
            const oldTotal = inner.totalCount();
            const oldChildCount = inner.subtreeCount(childIndex);
            const childResult = try insertInto(transaction, inner.childRef(childIndex), probeKey, storedKey, value, depth + 1);

            // No split in the child: update the child's ref and subtree count.
            if (childResult.split == null) {
                const updated = try transaction.writableCopy(nodeRef, innerNodeSize);
                std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride ..][0..8], childResult.ref, .little);
                std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride + 16 ..][0..8], childResult.count, .little);
                return InsertResult{ .ref = updated.ref, .count = oldTotal - oldChildCount + childResult.count, .split = null };
            }

            const childSplit = childResult.split.?;
            const newTotal = oldTotal - oldChildCount + childResult.count + childSplit.count;

            // Child split but this inner node is not full: shift and insert
            // the new right sibling at childIndex+1.
            if (inner.child_count < fanout) {
                const updated = try transaction.writableCopy(nodeRef, innerNodeSize);
                // Update the split child's ref+count (its low key is
                // unchanged: the left half keeps the same minimum).
                std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride ..][0..8], childResult.ref, .little);
                std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride + 16 ..][0..8], childResult.count, .little);
                // Shift slots [childIndex+1, child_count) right by one.
                var moveSlot: usize = inner.child_count;
                while (moveSlot > childIndex + 1) : (moveSlot -= 1) {
                    const source = headerSize + (moveSlot - 1) * innerStride;
                    const destination = headerSize + moveSlot * innerStride;
                    @memcpy(updated.bytes[destination..][0..innerStride], updated.bytes[source..][0..innerStride]);
                }
                std.mem.writeInt(u64, updated.bytes[headerSize + (childIndex + 1) * innerStride ..][0..8], childSplit.ref, .little);
                std.mem.writeInt(u64, updated.bytes[headerSize + (childIndex + 1) * innerStride + 8 ..][0..8], childSplit.low, .little);
                std.mem.writeInt(u64, updated.bytes[headerSize + (childIndex + 1) * innerStride + 16 ..][0..8], childSplit.count, .little);
                std.mem.writeInt(u16, updated.bytes[1..3], inner.child_count + 1, .little);
                return InsertResult{ .ref = updated.ref, .count = newTotal, .split = null };
            }

            // Child split AND this inner node is full: build fanout+1
            // entries, split at the midpoint. All entries are read from
            // `inner` before writableCopy.
            const totalChildren: usize = @as(usize, fanout) + 1;
            var childRefs: [fanout + 1]u64 = undefined;
            var lowKeys: [fanout + 1]u64 = undefined;
            var subtreeCounts: [fanout + 1]u64 = undefined;
            var copySlot: usize = 0;
            while (copySlot < inner.child_count) : (copySlot += 1) {
                childRefs[copySlot] = inner.childRef(copySlot);
                lowKeys[copySlot] = inner.lowKey(copySlot);
                subtreeCounts[copySlot] = inner.subtreeCount(copySlot);
            }
            // Update the split child's ref/count to the left half.
            childRefs[childIndex] = childResult.ref;
            subtreeCounts[childIndex] = childResult.count;
            // Insert the new right sibling immediately after childIndex.
            copySlot = inner.child_count; // = fanout
            while (copySlot > childIndex + 1) : (copySlot -= 1) {
                childRefs[copySlot] = childRefs[copySlot - 1];
                lowKeys[copySlot] = lowKeys[copySlot - 1];
                subtreeCounts[copySlot] = subtreeCounts[copySlot - 1];
            }
            childRefs[childIndex + 1] = childSplit.ref;
            lowKeys[childIndex + 1] = childSplit.low;
            subtreeCounts[childIndex + 1] = childSplit.count;

            const midpoint: usize = totalChildren / 2;
            const left = try transaction.writableCopy(nodeRef, innerNodeSize);
            std.mem.writeInt(u16, left.bytes[1..3], @intCast(midpoint), .little);
            var leftCount: u64 = 0;
            copySlot = 0;
            while (copySlot < midpoint) : (copySlot += 1) {
                std.mem.writeInt(u64, left.bytes[headerSize + copySlot * innerStride ..][0..8], childRefs[copySlot], .little);
                std.mem.writeInt(u64, left.bytes[headerSize + copySlot * innerStride + 8 ..][0..8], lowKeys[copySlot], .little);
                std.mem.writeInt(u64, left.bytes[headerSize + copySlot * innerStride + 16 ..][0..8], subtreeCounts[copySlot], .little);
                leftCount += subtreeCounts[copySlot];
            }
            var rightCount: u64 = 0;
            copySlot = midpoint;
            while (copySlot < totalChildren) : (copySlot += 1) rightCount += subtreeCounts[copySlot];
            const right = try transaction.alloc(innerNodeSize);
            _ = encodeInner(right.bytes, childRefs[midpoint..totalChildren], lowKeys[midpoint..totalChildren], subtreeCounts[midpoint..totalChildren]);
            // Duplicate the promoted low for the parent: the right inner node
            // keeps lowKeys[midpoint] as its own slot-0 low, and freeTree
            // releases every node's owned key material exactly once --
            // aliasing the two would double-free out-of-node keys. Identity
            // for inline keys.
            const promotedLow = try Keying.duplicateKey(transaction, lowKeys[midpoint]);
            return InsertResult{
                .ref = left.ref,
                .count = leftCount,
                .split = Split{ .ref = right.ref, .low = promotedLow, .count = rightCount },
            };
        }

        /// Insert or update probeKey->value in the tree rooted at root,
        /// storing storedKey in the new key slot. Returns the (possibly new)
        /// root Reference and grows the tree height on a root split. On an upsert
        /// the value is overwritten in place and storedKey's key material is
        /// released via Keying.freeKey.
        pub fn insert(transaction: anytype, root: Reference, probeKey: Keying.ProbeKey, storedKey: u64, value: u64) !Reference {
            const result = try insertInto(transaction, root, probeKey, storedKey, value, 0);
            if (result.split == null) return result.ref;
            // Root was split: build a new two-child inner root. The left low
            // is duplicated for the same ownership reason as split
            // separators: minKey returns the leftmost LEAF's slot-0 stored
            // key, which removeInto may free.
            const leftLow = try Keying.duplicateKey(transaction, try minKey(transaction, result.ref));
            const newRoot = try transaction.alloc(innerNodeSize);
            const rootRefs = [_]u64{ result.ref, result.split.?.ref };
            const rootLows = [_]u64{ leftLow, result.split.?.low };
            const rootCounts = [_]u64{ result.count, result.split.?.count };
            _ = encodeInner(newRoot.bytes, &rootRefs, &rootLows, &rootCounts);
            return newRoot.ref;
        }

        /// Remove probeKey from the tree rooted at root, releasing the
        /// matched slot's key material via Keying.freeKey. Returns the
        /// (possibly new) root Reference; unchanged if the key is absent.
        pub fn remove(transaction: anytype, root: Reference, probeKey: Keying.ProbeKey) !Reference {
            return (try removeInto(transaction, root, probeKey, 0)).ref;
        }

        /// Recursive remove. Returns the (possibly new) node ref and its
        /// subtree count. Returns nodeRef unchanged when the key is absent
        /// (no COW on the path).
        fn removeInto(transaction: anytype, nodeRef: Reference, probeKey: Keying.ProbeKey, depth: usize) !RemoveResult {
            if (depth >= maxDepth) return error.Corrupt;
            const kind = (try transaction.deref(nodeRef, 1))[0];

            // ---- LEAF -----------------------------------------------------
            if (kind == kindLeaf) {
                const leafBytes = try transaction.deref(nodeRef, leafNodeSize);
                const leaf = try parseLeaf(leafBytes);
                const slot = try leafLowerBound(transaction, leaf, probeKey);
                if (slot >= leaf.count or (try Keying.order(transaction, leaf.key(slot), probeKey)) != .eq) {
                    return .{ .ref = nodeRef, .count = leaf.count }; // no-op
                }
                // Capture the stored key before COW so its key material can
                // be freed afterward.
                const removedKey = leaf.key(slot);
                const updated = try transaction.writableCopy(nodeRef, leafNodeSize);
                // Shift slots (slot+1 .. count) left by one, overwriting slot.
                var moveSlot: usize = slot;
                while (moveSlot + 1 < leaf.count) : (moveSlot += 1) {
                    const source = headerSize + (moveSlot + 1) * 16;
                    const destination = headerSize + moveSlot * 16;
                    @memcpy(updated.bytes[destination..][0..16], updated.bytes[source..][0..16]);
                }
                std.mem.writeInt(u16, updated.bytes[1..3], leaf.count - 1, .little);
                try Keying.freeKey(transaction, removedKey);
                return .{ .ref = updated.ref, .count = @as(u64, leaf.count) - 1 };
            }

            // ---- INNER ----------------------------------------------------
            const innerBytes = try transaction.deref(nodeRef, innerNodeSize);
            const inner = try parseInner(innerBytes);
            const childIndex = try childIndexForKey(transaction, inner, probeKey);
            const oldChildRef: Reference = inner.childRef(childIndex);
            // Capture BEFORE writableCopy: it frees nodeRef into the reuse
            // pool, so inner's bytes must not be read after it (the node can
            // be reallocated).
            const oldTotal = inner.totalCount();
            const oldChildCount = inner.subtreeCount(childIndex);
            const childResult = try removeInto(transaction, oldChildRef, probeKey, depth + 1);
            // No change in the subtree: skip COW on this inner node too.
            if (childResult.ref == oldChildRef) return .{ .ref = nodeRef, .count = oldTotal };
            const updated = try transaction.writableCopy(nodeRef, innerNodeSize);
            std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride ..][0..8], childResult.ref, .little);
            std.mem.writeInt(u64, updated.bytes[headerSize + childIndex * innerStride + 16 ..][0..8], childResult.count, .little);
            return .{ .ref = updated.ref, .count = oldTotal - oldChildCount + childResult.count };
        }

        /// Recursively free every node of the tree rooted at root so the
        /// space becomes reclaimable, releasing each slot's owned key
        /// material (leaf stored keys and inner low keys) via Keying.freeKey
        /// -- a no-op for inline keys. Values are NOT freed; for trees whose
        /// leaf values are refs to other structures the caller owns those
        /// separately. O(nodes) with I/O.
        pub fn freeTree(transaction: anytype, root: Reference) !void {
            return freeTreeAt(transaction, root, 0);
        }

        fn freeTreeAt(transaction: anytype, nodeRef: Reference, depth: usize) !void {
            if (depth >= maxDepth) return error.Corrupt;
            const bytes = try derefNode(transaction, nodeRef);
            if (bytes[0] == kindLeaf) {
                const leaf = try parseLeaf(bytes);
                var slot: usize = 0;
                while (slot < leaf.count) : (slot += 1) try Keying.freeKey(transaction, leaf.key(slot));
                try transaction.free(nodeRef, leafNodeSize);
                return;
            }
            const inner = try parseInner(bytes);
            var childIndex: usize = 0;
            while (childIndex < inner.child_count) : (childIndex += 1) {
                try freeTreeAt(transaction, inner.childRef(childIndex), depth + 1);
                try Keying.freeKey(transaction, inner.lowKey(childIndex));
            }
            try transaction.free(nodeRef, innerNodeSize);
        }

        /// Return the number of keys in the tree rooted at root. A
        /// single-node read: leaves know their own count and inner nodes
        /// store per-child subtree counts.
        pub fn count(transaction: anytype, root: Reference) !u64 {
            const bytes = try derefNode(transaction, root);
            if (bytes[0] == kindLeaf) {
                const leaf = try parseLeaf(bytes);
                return leaf.count;
            }
            const inner = try parseInner(bytes);
            return inner.totalCount();
        }

        /// Visit every stored key in ascending order, calling
        /// onKey(context, storedKey) for each. Inner nodes are recursed left
        /// to right; leaf keys are already sorted. O(nodes) with I/O.
        pub fn forEachKey(
            transaction: anytype,
            root: Reference,
            context: anytype,
            comptime onKey: fn (@TypeOf(context), u64) anyerror!void,
        ) !void {
            return forEachKeyAt(transaction, root, context, onKey, 0);
        }

        fn forEachKeyAt(
            transaction: anytype,
            root: Reference,
            context: anytype,
            comptime onKey: fn (@TypeOf(context), u64) anyerror!void,
            depth: usize,
        ) !void {
            if (depth >= maxDepth) return error.Corrupt;
            const bytes = try derefNode(transaction, root);
            if (bytes[0] == kindLeaf) {
                const leaf = try parseLeaf(bytes);
                var slot: usize = 0;
                while (slot < leaf.count) : (slot += 1) try onKey(context, leaf.key(slot));
                return;
            }
            const inner = try parseInner(bytes);
            var childIndex: usize = 0;
            while (childIndex < inner.child_count) : (childIndex += 1) {
                try forEachKeyAt(transaction, inner.childRef(childIndex), context, onKey, depth + 1);
            }
        }

        /// Visit every (storedKey, value) pair in ascending key order,
        /// calling onEntry(context, storedKey, value) for each. Same
        /// traversal as forEachKey, but also surfaces the value stored
        /// alongside each key in the leaf. O(nodes) with I/O.
        pub fn forEachEntry(
            transaction: anytype,
            root: Reference,
            context: anytype,
            comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!void,
        ) !void {
            return forEachEntryAt(transaction, root, context, onEntry, 0);
        }

        fn forEachEntryAt(
            transaction: anytype,
            root: Reference,
            context: anytype,
            comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!void,
            depth: usize,
        ) !void {
            if (depth >= maxDepth) return error.Corrupt;
            const bytes = try derefNode(transaction, root);
            if (bytes[0] == kindLeaf) {
                const leaf = try parseLeaf(bytes);
                var slot: usize = 0;
                while (slot < leaf.count) : (slot += 1) try onEntry(context, leaf.key(slot), leaf.value(slot));
                return;
            }
            const inner = try parseInner(bytes);
            var childIndex: usize = 0;
            while (childIndex < inner.child_count) : (childIndex += 1) {
                try forEachEntryAt(transaction, inner.childRef(childIndex), context, onEntry, depth + 1);
            }
        }
    };
}
