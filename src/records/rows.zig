//! Raw row CRUD over the catalog's columns and indexes.
//!
//! This is the storage-level half of the object layer: insert/update/delete of
//! raw u64 rows, reads by primary key or stable object key, per-property value
//! index maintenance, and reclamation of a deleted row's blob/collection
//! storage. Typed encode/decode orchestration (Values, backlinks, cascades)
//! lives above this in objects.zig.

const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const byteKeyIndex = @import("../trees/byteKeyIndex.zig");
const blob = @import("blob.zig");
const blobIndexKey = @import("blobIndexKey.zig");
const catalog = @import("../schema/catalog.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const maxPropertyCount = catalog.maxPropertyCount;

const loadCatalog = catalog.loadCatalog;

// ---------------------------------------------------------------------------
// Per-property value index maintenance.
//
// A value index has the same shape as a backlink index: value -> setRoot,
// where setRoot is an index of objectKey -> 1. It is kept transactionally in sync
// with the base row on every insert, update, and delete of an indexed property,
// so an equality/range query reads from a view that can never diverge from the
// rows. These helpers mirror the backlink add/remove path in links.zig.
// ---------------------------------------------------------------------------

/// Add `objectKey` to the int-keyed value-index inner set for `value`,
/// returning the new index reference.
/// Pub: the migration backfill reuses it to index pre-migration rows.
pub fn intValueIndexAdd(transaction: *WriteTransaction, valueIndexReference: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexReference, value);
    var setRoot = existing orelse try Index.create(transaction);
    setRoot = try Index.insert(transaction, setRoot, objectKey, 1);
    return try Index.insert(transaction, valueIndexReference, value, setRoot);
}

/// Add `objectKey` to the byte-keyed value-index inner set for `key`,
/// returning the new index reference. `key` is already truncated by
/// `blobIndexKey`; this function does not truncate.
/// Pub: the migration backfill and the compaction copy reuse it.
pub fn blobValueIndexAdd(transaction: *WriteTransaction, valueIndexReference: Reference, key: []const u8, objectKey: u64) !Reference {
    const existing = try byteKeyIndex.get(transaction, valueIndexReference, key);
    var setRoot = existing orelse try Index.create(transaction);
    setRoot = try Index.insert(transaction, setRoot, objectKey, 1);
    return try byteKeyIndex.insert(transaction, valueIndexReference, key, setRoot);
}

// Remove `objectKey` from the int-keyed value-index inner set for `value`. No-op if absent.
// When the inner set empties, its outer entry is removed and the set's nodes
// freed: high-churn workloads would otherwise accumulate one empty set per
// distinct value ever indexed, reclaimable only by a full file copy.
fn intValueIndexRemove(transaction: *WriteTransaction, valueIndexReference: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexReference, value);
    const setRoot = existing orelse return valueIndexReference;
    const newSet = try Index.remove(transaction, setRoot, objectKey);
    if ((try Index.count(transaction, newSet)) == 0) {
        const newVi = try Index.remove(transaction, valueIndexReference, value);
        try Index.freeTree(transaction, newSet);
        return newVi;
    }
    return try Index.insert(transaction, valueIndexReference, value, newSet);
}

// Remove `objectKey` from the byte-keyed value-index inner set for `key`. No-op if absent.
// Mirrors intValueIndexRemove's empty-set pruning: byteKeyIndex.remove frees
// the key's own blob, so nothing else is needed to reclaim it.
fn blobValueIndexRemove(transaction: *WriteTransaction, valueIndexReference: Reference, key: []const u8, objectKey: u64) !Reference {
    const existing = try byteKeyIndex.get(transaction, valueIndexReference, key);
    const setRoot = existing orelse return valueIndexReference;
    const newSet = try Index.remove(transaction, setRoot, objectKey);
    if ((try Index.count(transaction, newSet)) == 0) {
        const newVi = try byteKeyIndex.remove(transaction, valueIndexReference, key);
        try Index.freeTree(transaction, newSet);
        return newVi;
    }
    return try byteKeyIndex.insert(transaction, valueIndexReference, key, newSet);
}

// Add objectKey under indexed property propertyIndex's key for `raw`, returning
// the new catalog. The property's kind decides the keying: an int or link
// property keys on the column word itself; a `.blob` property keys on the
// stored bytes truncated to blobIndexKey.maxLength, which makes the index a
// CANDIDATE index (see blobIndexKey.zig) rather than a covering one.
// One catalog load, one index descent and one insert; a blob property adds
// one blob prefix read. I/O.
fn addToValueIndex(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, raw: u64, objectKey: u64) !Reference {
    const view = try loadCatalog(transaction, catalogReference);
    const valueIndexReference = view.valueIndexReference(propertyIndex);
    const newValueIndex = switch (view.kind(propertyIndex)) {
        .blob => blk: {
            var keyBuffer: [blobIndexKey.maxLength]u8 = undefined;
            const key = try blobIndexKey.read(transaction, raw, &keyBuffer);
            break :blk try blobValueIndexAdd(transaction, valueIndexReference, key, objectKey);
        },
        else => try intValueIndexAdd(transaction, valueIndexReference, raw, objectKey),
    };
    return try catalog.setValueIndexReference(transaction, catalogReference, propertyIndex, newValueIndex);
}

// The exact mirror of addToValueIndex: removes objectKey from indexed
// property propertyIndex's key for `raw`, keyed the same way addToValueIndex
// keys it.
fn removeFromValueIndex(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, raw: u64, objectKey: u64) !Reference {
    const view = try loadCatalog(transaction, catalogReference);
    const valueIndexReference = view.valueIndexReference(propertyIndex);
    const newValueIndex = switch (view.kind(propertyIndex)) {
        .blob => blk: {
            var keyBuffer: [blobIndexKey.maxLength]u8 = undefined;
            const key = try blobIndexKey.read(transaction, raw, &keyBuffer);
            break :blk try blobValueIndexRemove(transaction, valueIndexReference, key, objectKey);
        },
        else => try intValueIndexRemove(transaction, valueIndexReference, raw, objectKey),
    };
    return try catalog.setValueIndexReference(transaction, catalogReference, propertyIndex, newValueIndex);
}

/// Append a new row to all columns and update the primaryKey index.
/// values.len must equal the propertyCount stored in the catalog.
/// Returns the new catalog reference and the row's stable object key, or
/// error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(transaction: *WriteTransaction, catalogReference: Reference, values: []const u64) !struct { catalogReference: Reference, objectKey: u64 } {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    std.debug.assert(values.len == snapshot.propertyCount);
    const propertyCount = snapshot.propertyCount;
    const row = snapshot.nextRow;
    const objectKey = snapshot.nextKey;

    const primaryKey = values[0];
    if ((try Index.get(transaction, snapshot.primaryKeyIndexReference, primaryKey)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            snapshot.properties[propertyIndex].column = try Column.append(transaction, snapshot.properties[propertyIndex].column, values[propertyIndex]);
        }
    }
    snapshot.versionColumnReference = try Column.append(transaction, snapshot.versionColumnReference, transaction.newVersion);
    snapshot.liveColumnReference = try Column.append(transaction, snapshot.liveColumnReference, 1);
    // primaryKey index maps primaryKey -> objectKey; key-to-row index maps objectKey -> physical row.
    snapshot.primaryKeyIndexReference = try Index.insert(transaction, snapshot.primaryKeyIndexReference, primaryKey, objectKey);
    snapshot.keyToRowIndexReference = try Index.insert(transaction, snapshot.keyToRowIndexReference, objectKey, row);
    snapshot.nextRow = row + 1;
    snapshot.nextKey = objectKey + 1;

    const newCatalog = try snapshot.replace(transaction);
    // Maintain the value index for each indexed property: add this row's objectKey to
    // the inner set at its stored value, in the same transaction as the row.
    var updatedCatalog = newCatalog;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) updatedCatalog = try addToValueIndex(transaction, updatedCatalog, propertyIndex, values[propertyIndex], objectKey);
        }
    }
    return .{ .catalogReference = updatedCatalog, .objectKey = objectKey };
}

/// The row's current version, reported when an optimistic write loses the race.
pub const Conflict = struct { currentVersion: u64 };
/// Outcome of a raw or typed update: new catalog + version, conflict, or absent.
pub const UpdateResult = union(enum) {
    ok: struct { catalogReference: Reference, version: u64 },
    conflict: Conflict,
    notFound,
};

/// Outcome of a raw or typed delete: new catalog, conflict, or absent.
pub const DeleteResult = union(enum) {
    ok: Reference, // new catalog
    conflict: Conflict,
    notFound,
};

/// Overwrite the row identified by `primaryKey` with `values`, guarded by the row's
/// expected version. Copy-on-writes only the columns whose value changed and
/// keeps every indexed property's value index in sync.
pub fn update(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, values: []const u64, expectedVersion: u64) !UpdateResult {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    std.debug.assert(values.len == snapshot.propertyCount);
    std.debug.assert(values[0] == primaryKey); // primaryKey is identity, must not change
    const objectKey = (try Index.get(transaction, snapshot.primaryKeyIndexReference, primaryKey)) orelse return .notFound;
    // The primaryKey index resolved but the key->row index did not: treat the divergence
    // as absent rather than crashing on corrupt data.
    const row = (try Index.get(transaction, snapshot.keyToRowIndexReference, objectKey)) orelse return .notFound;
    const currentVersion = try Column.get(transaction, snapshot.versionColumnReference, row);
    if (currentVersion != expectedVersion) return .{ .conflict = .{ .currentVersion = currentVersion } };
    const propertyCount = snapshot.propertyCount;

    // Snapshot the current value of each indexed property before overwriting the
    // column, so the value index can move the objectKey from its old to its new value.
    var oldValues: [maxPropertyCount]u64 = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) oldValues[propertyIndex] = try Column.get(transaction, snapshot.properties[propertyIndex].column, row);
        }
    }

    // Copy-on-write only the columns whose value actually changed: an O(height)
    // read is strictly cheaper than an O(height) path copy, so a one-field
    // update on a wide type no longer rewrites every property column.
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        const currentValue = try Column.get(transaction, snapshot.properties[propertyIndex].column, row);
        if (currentValue != values[propertyIndex]) snapshot.properties[propertyIndex].column = try Column.set(transaction, snapshot.properties[propertyIndex].column, row, values[propertyIndex]);
    }
    snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, row, transaction.newVersion);

    const newCatalog = try snapshot.replace(transaction);
    // Re-point the value index for any indexed property whose value changed.
    var updatedCatalog = newCatalog;
    {
        var reindexIndex: usize = 0;
        while (reindexIndex < propertyCount) : (reindexIndex += 1) {
            if (snapshot.properties[reindexIndex].indexed and oldValues[reindexIndex] != values[reindexIndex]) {
                updatedCatalog = try removeFromValueIndex(transaction, updatedCatalog, reindexIndex, oldValues[reindexIndex], objectKey);
                updatedCatalog = try addToValueIndex(transaction, updatedCatalog, reindexIndex, values[reindexIndex], objectKey);
            }
        }
    }
    return .{ .ok = .{ .catalogReference = updatedCatalog, .version = transaction.newVersion } };
}

/// Tombstone the row identified by `primaryKey`, guarded by the row's expected version.
/// Drops the primaryKey and key->row index entries and every value-index entry, but
/// leaves the physical column cells intact for pinned readers.
pub fn delete(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, expectedVersion: u64) !DeleteResult {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    const objectKey = (try Index.get(transaction, snapshot.primaryKeyIndexReference, primaryKey)) orelse return .notFound;
    const row = (try Index.get(transaction, snapshot.keyToRowIndexReference, objectKey)) orelse return .notFound;
    const currentVersion = try Column.get(transaction, snapshot.versionColumnReference, row);
    if (currentVersion != expectedVersion) return .{ .conflict = .{ .currentVersion = currentVersion } };
    const propertyCount = snapshot.propertyCount;

    // Read the value of each indexed property while the row is still readable,
    // so its objectKey can be dropped from the value index. Property columns are not
    // mutated by delete, so the snapshot's columns still address the current values.
    var oldValues: [maxPropertyCount]u64 = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) oldValues[propertyIndex] = try Column.get(transaction, snapshot.properties[propertyIndex].column, row);
        }
    }

    snapshot.liveColumnReference = try Column.set(transaction, snapshot.liveColumnReference, row, 0); // tombstone
    snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, row, transaction.newVersion); // bump version stamp
    snapshot.primaryKeyIndexReference = try Index.remove(transaction, snapshot.primaryKeyIndexReference, primaryKey); // remove primaryKey from the index
    // Drop the object key from the key->row index. Copy-on-write keeps the old
    // index version intact for any reader pinned to the prior snapshot, so this
    // is MVCC-safe; it prevents a stale key from aliasing a row a later
    // relocation reuses.
    snapshot.keyToRowIndexReference = try Index.remove(transaction, snapshot.keyToRowIndexReference, objectKey);

    const newCatalog = try snapshot.replace(transaction);
    // Drop this row's objectKey from the value index for every indexed property.
    var updatedCatalog = newCatalog;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) updatedCatalog = try removeFromValueIndex(transaction, updatedCatalog, propertyIndex, oldValues[propertyIndex], objectKey);
        }
    }
    return .{ .ok = updatedCatalog };
}

/// Read a row by primary key into `out` (raw u64 cells). Returns the row
/// version, or null when the key is not found or the row is tombstoned.
pub fn getByPrimaryKey(transaction: anytype, catalogReference: Reference, primaryKey: u64, out: []u64) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    std.debug.assert(out.len == view.propertyCount);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexReference, primaryKey)) orelse return null;
    return getByObjectKey(transaction, catalogReference, objectKey, out);
}

/// Read a row by its stable object key. Resolves the objectKey to a physical row via
/// the key-to-row index. Returns the row version, or null if the objectKey is unknown
/// or the row is tombstoned.
pub fn getByObjectKey(transaction: anytype, catalogReference: Reference, objectKey: u64, out: []u64) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    std.debug.assert(out.len == view.propertyCount);
    const row = (try catalog.objectKeyToRow(transaction, catalogReference, objectKey)) orelse return null;
    const liveColumnReference = view.liveColumnReference;
    const versionColumnReference = view.versionColumnReference;
    var propertyReferences: [maxPropertyCount]Reference = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) propertyReferences[propertyIndex] = view.propertyColumnReference(propertyIndex);
    }
    const propertyCount = view.propertyCount;
    if ((try Column.get(transaction, liveColumnReference, row)) == 0) return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) out[propertyIndex] = try Column.get(transaction, propertyReferences[propertyIndex], row);
    return try Column.get(transaction, versionColumnReference, row);
}

/// Free the blob and collection storage held in a deleted row's columns.
/// `raw` holds the row's column values captured before the tombstone (the
/// tombstone leaves the physical columns intact, so a pre-delete read stays
/// accurate). Shared by objects.deleteTyped and the directory-level delete
/// (typeRouting.deleteWorker); before that sharing, every row deleted through the
/// directory path -- including every cascade-deleted child -- leaked its blobs
/// and list/set/dict trees permanently. A raw of 0 (no storage, e.g. a row
/// written with caller-supplied raws or a dead-row migration backfill) frees
/// nothing rather than erroring mid-delete.
pub fn freeRowStorage(transaction: *WriteTransaction, kinds: []const PropertyKind, elements: []const ElementKind, raw: []const u64) !void {
    var propertyIndex: usize = 0;
    while (propertyIndex < kinds.len) : (propertyIndex += 1) {
        if (raw[propertyIndex] == 0) continue;
        switch (kinds[propertyIndex]) {
            .blob => try blob.free(transaction, raw[propertyIndex]),
            .list => {
                if (elements[propertyIndex] == .blob) {
                    // Elements are blob references: free each before the tree.
                    const elementCount = try Column.length(transaction, raw[propertyIndex]);
                    var elementIndex: u64 = 0;
                    while (elementIndex < elementCount) : (elementIndex += 1) try blob.free(transaction, try Column.get(transaction, raw[propertyIndex], elementIndex));
                }
                try Column.freeTree(transaction, raw[propertyIndex]);
            },
            .set => switch (elements[propertyIndex]) {
                .int => try Index.freeTree(transaction, raw[propertyIndex]),
                .blob => try byteKeyIndex.freeTree(transaction, raw[propertyIndex]),
            },
            .dict => try byteKeyIndex.freeTree(transaction, raw[propertyIndex]),
            .linkSet => try Index.freeTree(transaction, raw[propertyIndex]),
            .int, .link => {},
        }
    }
}
