const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const bindex = @import("../trees/byteKeyIndex.zig");
const blob = @import("blob.zig");
const catalog = @import("../schema/catalog.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const PropertyDefinition = catalog.PropertyDefinition;
const Value = catalog.Value;
const PropertyCount = catalog.PropertyCount;
const CatalogView = catalog.CatalogView;
const maxPropertyCount = catalog.maxPropertyCount;

/// Build a list-of-int tree holding `items` in order and return its root.
/// One tree append per item (O(m log m) total).
pub fn buildListInt(transaction: *WriteTransaction, items: []const u64) !Reference {
    var root = try Column.create(transaction);
    for (items) |item| root = try Column.append(transaction, root, item);
    return root;
}

/// Build a list-of-blob tree from `items` and return its root. Each element
/// is written to the blob heap and its ref appended (O(m log m) tree appends
/// plus one blob write per element).
pub fn buildListBlob(transaction: *WriteTransaction, items: []const []const u8) !Reference {
    var root = try Column.create(transaction);
    for (items) |item| {
        const blobRef = try blob.put(transaction, item);
        root = try Column.append(transaction, root, blobRef);
    }
    return root;
}

/// Build a set-of-int tree from `items` and return its root. Duplicate items
/// collapse to one member. One index insert per item (O(m log m) total).
pub fn buildSetInt(transaction: *WriteTransaction, items: []const u64) !Reference {
    var root = try Index.create(transaction);
    for (items) |key| root = try Index.insert(transaction, root, key, 1);
    return root;
}

/// Number of elements in list property `property` of the object identified by
/// `primaryKey`, or null when the object is absent or tombstoned. Two index
/// descents to resolve the row, then a column walk (O(log n)).
pub fn listLen(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const listRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try Column.length(transaction, listRoot);
}

/// The int element at `index` of list property `property`. Fails with
/// error.NotFound when the object is absent and error.IndexOutOfBounds when
/// `index` is past the end. Tree walks, O(log n).
pub fn listGetInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, index: u64) !u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const listRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try Column.get(transaction, listRoot, index);
}

/// The blob element at `index` of list property `property`, as a zero-copy
/// slice into mapped storage -- valid only until the next mutating call on
/// the same transaction; copy it out to keep it longer. Fails with
/// error.BlobChunked for an element over the inline cap. Tree walks, O(log n).
pub fn listGetBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, index: u64) ![]const u8 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const listRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const blobRef = try Column.get(transaction, listRoot, index);
    return try blob.get(transaction, blobRef);
}

/// Append `value` to list property `property` and return the new catalog ref,
/// which the caller must adopt (copy-on-write). Bumps the row's version
/// stamp. Tree walks, O(log n).
pub fn listAppendInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, value: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const newRoot = try Column.append(transaction, oldRoot, value);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Overwrite the element at `index` of list property `property` with `value`
/// and return the new catalog ref (copy-on-write). Bumps the row's version
/// stamp. Tree walks, O(log n).
pub fn listSetInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, index: u64, value: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const newRoot = try Column.set(transaction, oldRoot, index, value);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Append `bytes` as a new blob element of list property `property` and
/// return the new catalog ref (copy-on-write). Bumps the row's version stamp.
/// Tree walks plus the blob write, O(log n).
pub fn listAppendBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, bytes: []const u8) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const blobRef = try blob.put(transaction, bytes);
    const newRoot = try Column.append(transaction, oldRoot, blobRef);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Number of members in set property `property`, or null when the object is
/// absent or tombstoned. Two index descents to resolve the row, then a
/// single-node count read (O(log n)).
pub fn setCountInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try Index.count(transaction, setRoot);
}

/// True when `key` is a member of set property `property`. Fails with
/// error.NotFound when the object is absent. Tree walks, O(log n).
pub fn setContainsInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, key: u64) !bool {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return (try Index.get(transaction, setRoot, key)) != null;
}

/// Add `key` to set property `property` and return the new catalog ref
/// (copy-on-write). Adding an existing member is a no-op that returns
/// `catalogRef` unchanged, without bumping the row version. Tree walks,
/// O(log n).
pub fn setAddInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, key: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    if ((try Index.get(transaction, oldRoot, key)) != null) return catalogRef; // already a member, no version bump
    const newRoot = try Index.insert(transaction, oldRoot, key, 1);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Remove `key` from set property `property` and return the new catalog ref
/// (copy-on-write). Removing a non-member is a no-op that returns
/// `catalogRef` unchanged, without bumping the row version. Tree walks,
/// O(log n).
pub fn setRemoveInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, key: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    if ((try Index.get(transaction, oldRoot, key)) == null) return catalogRef; // not a member, no version bump
    const newRoot = try Index.remove(transaction, oldRoot, key);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Append every member of set property `property` to `out` in ascending
/// order. `out` grows with `allocator` and the caller owns it (deinit when
/// done). Walks the whole set tree, O(k) over the member count.
pub fn setCollectInt(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    property: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, setRoot, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// ---------------------------------------------------------------------------
// set of blob: byte-string members backed by the byte-keyed B+tree (bindex).
// Members are the bindex keys; the value column is an unused sentinel (1).
// ---------------------------------------------------------------------------

/// Build a set-of-blob tree from `items` and return its root. Members are the
/// byte-keyed B+tree's keys, so duplicate members dedup. One insert per item
/// (O(m log m) total).
pub fn buildSetBlob(transaction: *WriteTransaction, items: []const []const u8) !Reference {
    var root = try bindex.create(transaction);
    // bindex.insert overwrites an existing key, so duplicate members dedup.
    for (items) |member| root = try bindex.insert(transaction, root, member, 1);
    return root;
}

/// Number of members in blob-set property `property`, or null when the object
/// is absent or tombstoned. Two index descents to resolve the row, then a
/// single-node count read (O(log n)).
pub fn setCountBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try bindex.count(transaction, setRoot);
}

/// True when `member` is in blob-set property `property`. Fails with
/// error.NotFound when the object is absent. Tree walks, O(log n).
pub fn setContainsBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, member: []const u8) !bool {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return (try bindex.get(transaction, setRoot, member)) != null;
}

/// Add `member` to blob-set property `property` and return the new catalog
/// ref (copy-on-write). Adding an existing member is a no-op that returns
/// `catalogRef` unchanged, without bumping the row version. Tree walks,
/// O(log n).
pub fn setAddBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, member: []const u8) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    if ((try bindex.get(transaction, oldRoot, member)) != null) return catalogRef; // already a member, no version bump
    const newRoot = try bindex.insert(transaction, oldRoot, member, 1);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Remove `member` from blob-set property `property` and return the new
/// catalog ref (copy-on-write). Removing a non-member is a no-op that returns
/// `catalogRef` unchanged, without bumping the row version. Tree walks,
/// O(log n).
pub fn setRemoveBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, member: []const u8) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    if ((try bindex.get(transaction, oldRoot, member)) == null) return catalogRef; // not a member, no version bump
    const newRoot = try bindex.remove(transaction, oldRoot, member);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Append every member of blob-set property `property` to `out` in ascending
/// byte order. forEachEntry hands the callback a key slice that points into
/// mapped storage and is only valid for the duration of the call, so each
/// member is duped into `allocator`. The caller owns the result: it must free
/// every appended slice and then deinit the list. Walks the whole set tree,
/// O(k) over the member count.
pub fn setCollectBlob(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    property: usize,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const Sink = struct {
        list: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, value: u64) !void {
            _ = value;
            try self.list.append(self.alloc, try self.alloc.dupe(u8, key));
        }
    };
    try bindex.forEachEntry(transaction, setRoot, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

// ---------------------------------------------------------------------------
// dict: byte-string key -> u64 value, backed by the byte-keyed B+tree (bindex).
// ---------------------------------------------------------------------------

/// Build a dict tree (byte-string key -> u64 value) from `entries` and return
/// its root. A repeated key keeps the last value. One insert per entry
/// (O(m log m) total).
pub fn buildDict(transaction: *WriteTransaction, entries: []const catalog.DictEntry) !Reference {
    var root = try bindex.create(transaction);
    // bindex.insert overwrites an existing key, so a repeated key keeps the last value.
    for (entries) |entry| root = try bindex.insert(transaction, root, entry.key, entry.value);
    return root;
}

/// The value stored under `key` in dict property `property`, or null when the
/// key is absent. Fails with error.NotFound when the object is absent. Tree
/// walks, O(log n).
pub fn dictGet(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, key: []const u8) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const dictRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try bindex.get(transaction, dictRoot, key);
}

/// Number of entries in dict property `property`, or null when the object is
/// absent or tombstoned. Two index descents to resolve the row, then a
/// single-node count read (O(log n)).
pub fn dictCount(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const dictRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try bindex.count(transaction, dictRoot);
}

/// Insert or overwrite `key` -> `value` in dict property `property` and
/// return the new catalog ref (copy-on-write). Bumps the row's version stamp.
/// Tree walks, O(log n).
pub fn dictPut(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, key: []const u8, value: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const newRoot = try bindex.insert(transaction, oldRoot, key, value); // overwrites existing key
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Remove `key` from dict property `property` and return the new catalog ref
/// (copy-on-write). Removing an absent key is a no-op that returns
/// `catalogRef` unchanged, without bumping the row version. Tree walks,
/// O(log n).
pub fn dictRemove(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, key: []const u8) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    if ((try bindex.get(transaction, oldRoot, key)) == null) return catalogRef; // absent, no version bump
    const newRoot = try bindex.remove(transaction, oldRoot, key);
    return catalog.replaceCollRoot(transaction, catalogRef, resolved.row, property, newRoot);
}

/// Append every (key, value) entry of dict property `property` to `out` in
/// ascending byte-key order. The key slice handed to the callback is only
/// valid during the call, so each key is duped into `allocator`. The caller
/// owns the result: it must free every entry's key and then deinit the list.
/// Walks the whole dict tree, O(k) over the entry count.
pub fn dictCollect(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    property: usize,
    out: *std.ArrayList(catalog.DictEntry),
    allocator: std.mem.Allocator,
) !void {
    const resolved = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const dictRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const Sink = struct {
        list: *std.ArrayList(catalog.DictEntry),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, value: u64) !void {
            try self.list.append(self.alloc, .{ .key = try self.alloc.dupe(u8, key), .value = value });
        }
    };
    try bindex.forEachEntry(transaction, dictRoot, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

test {
    _ = @import("collectionsTests.zig");
}
