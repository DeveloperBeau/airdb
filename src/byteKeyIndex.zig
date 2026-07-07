// byteKeyIndex.zig -- byte-keyed ordered B+tree: the shared core of bTreeCore.zig
// instantiated with blob-ref keys. Same on-disk node layout as index.zig
// (see indexNode.zig). The ONLY difference from index.zig: the u64 stored in
// a leaf key slot is a blob ref to the key bytes (not the key itself), and
// the "low_key" of an inner pair is a blob ref to the smallest key in that
// subtree. All ordering compares the dereferenced bytes with std.mem.order;
// keys live in the blob heap. See bTreeCore.zig for the transaction
// capability the `txn` parameters must satisfy (WriteTxn in production;
// ReadTxn for the read-only subset).

const std = @import("std");
const Ref = @import("reference.zig").Ref;
const blob = @import("blob.zig");
const bTreeCore = @import("bTreeCore.zig");

/// Keying for blob-ref keys: the stored u64 refs the key bytes in the blob
/// heap, and ordering dereferences and byte-compares them.
const BlobKeying = struct {
    /// Callers search with the key bytes.
    pub const ProbeKey = []const u8;

    /// Byte order of the stored key's blob against the probe bytes. Pure
    /// byte ordering via std.mem.order -- this is index ordering, not a
    /// secret comparison, so constant-time is neither required nor wanted.
    pub fn order(transaction: anytype, storedKeyRef: u64, probeKey: []const u8) !std.math.Order {
        const storedBytes = try blob.get(transaction, storedKeyRef);
        return std.mem.order(u8, storedBytes, probeKey);
    }

    /// Copy the referenced key bytes into a new blob the caller owns.
    /// Routing separators must OWN their bytes: aliasing a leaf's key blob
    /// would leave every ancestor dereferencing freed bytes once that key is
    /// removed (remove frees leaf key blobs), and aliasing the promoted low
    /// across sibling inner nodes would double-free in freeTree. Like classic
    /// B+tree separators, duplicated separator blobs are never freed by
    /// remove -- one small blob per split, released only by freeTree.
    pub fn duplicateKey(transaction: anytype, storedKeyRef: u64) !u64 {
        const keyBytes = try blob.get(transaction, storedKeyRef);
        return blob.put(transaction, keyBytes);
    }

    /// Release the key blob a slot owns.
    pub fn freeKey(transaction: anytype, storedKeyRef: u64) !void {
        return blob.free(transaction, storedKeyRef);
    }
};

const Tree = bTreeCore.BTreeCore(BlobKeying);

/// Create a new empty leaf node and return its Ref.
pub const create = Tree.create;

/// Look up `key` in the tree rooted at `root`. Returns the value on exact
/// byte-equality, else null.
pub const get = Tree.get;

/// Insert or update key->val in the tree rooted at `root`. If `key` already
/// exists (exact bytes), its value is overwritten in place and no duplicate is
/// added; otherwise the key bytes are stored in the blob heap and a new entry
/// is inserted in byte-sorted order. Returns the (possibly new) root.
pub fn insert(txn: anytype, root: Ref, key: []const u8, val: u64) !Ref {
    const key_ref = try blob.put(txn, key);
    return Tree.insert(txn, root, key, key_ref, val);
}

/// Remove `key` from the tree rooted at `root`. Frees the key's blob node when
/// present. Returns the (possibly new) root; unchanged if the key is absent.
pub const remove = Tree.remove;

/// Recursively free every node of the tree rooted at `root`, INCLUDING the
/// blobs the tree owns: leaf key blobs and inner low-key blobs (routing
/// separators are duplicated at split time, so the tree is their sole owner).
/// Values are NOT freed -- they are plain u64s at this layer.
pub const freeTree = Tree.freeTree;

/// Return the number of entries in the tree rooted at `root`. A single-node
/// read: inner nodes store per-child subtree counts.
pub const count = Tree.count;

/// Visit every (key, value) entry in ascending byte-key order, dereferencing
/// each leaf entry's key blob and calling onEntry(ctx, key_bytes, value).
/// The key slice points into mapped storage and is only valid for the duration
/// of the callback; copy it if it must outlive the call.
pub fn forEachEntry(
    txn: anytype,
    root: Ref,
    ctx: anytype,
    comptime onEntry: fn (@TypeOf(ctx), key: []const u8, val: u64) anyerror!void,
) !void {
    // Adapt the core's raw (storedKey, value) walker: each stored key is a
    // blob ref, dereferenced here before reaching the caller's callback.
    const KeyDereferencing = struct {
        transaction: @TypeOf(txn),
        context: @TypeOf(ctx),
        fn visit(self: @This(), storedKeyRef: u64, value: u64) anyerror!void {
            const keyBytes = try blob.get(self.transaction, storedKeyRef);
            return onEntry(self.context, keyBytes, value);
        }
    };
    return Tree.forEachEntry(
        txn,
        root,
        KeyDereferencing{ .transaction = txn, .context = ctx },
        KeyDereferencing.visit,
    );
}

test {
    _ = @import("byteKeyIndexTests.zig");
}
