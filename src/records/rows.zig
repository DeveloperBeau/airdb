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
const bindex = @import("../trees/byteKeyIndex.zig");
const blob = @import("blob.zig");
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

/// Add `objectKey` to the value-index inner set for `value`, returning the new index ref.
/// Pub: the migration backfill reuses it to index pre-migration rows.
pub fn valueIndexAdd(transaction: *WriteTransaction, valueIndexRef: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexRef, value);
    var setRoot = existing orelse try Index.create(transaction);
    setRoot = try Index.insert(transaction, setRoot, objectKey, 1);
    return try Index.insert(transaction, valueIndexRef, value, setRoot);
}

// Remove `objectKey` from the value-index inner set for `value`. No-op if absent.
// When the inner set empties, its outer entry is removed and the set's nodes
// freed: high-churn workloads would otherwise accumulate one empty set per
// distinct value ever indexed, reclaimable only by a full file copy.
fn valueIndexRemove(transaction: *WriteTransaction, valueIndexRef: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexRef, value);
    const setRoot = existing orelse return valueIndexRef;
    const newSet = try Index.remove(transaction, setRoot, objectKey);
    if ((try Index.count(transaction, newSet)) == 0) {
        const newVi = try Index.remove(transaction, valueIndexRef, value);
        try Index.freeTree(transaction, newSet);
        return newVi;
    }
    return try Index.insert(transaction, valueIndexRef, value, newSet);
}

// Add objectKey->value to indexed property p's value index. Returns the new catalog.
fn addValueIndex(transaction: *WriteTransaction, catalogRef: Reference, propertyIndex: usize, value: u64, objectKey: u64) !Reference {
    const view = try loadCatalog(transaction, catalogRef);
    const newVi = try valueIndexAdd(transaction, view.valueIndexRef(propertyIndex), value, objectKey);
    return try catalog.setValueIndexRef(transaction, catalogRef, propertyIndex, newVi);
}

// Remove objectKey from indexed property p's value-index set for `value`.
fn removeValueIndex(transaction: *WriteTransaction, catalogRef: Reference, propertyIndex: usize, value: u64, objectKey: u64) !Reference {
    const view = try loadCatalog(transaction, catalogRef);
    const newVi = try valueIndexRemove(transaction, view.valueIndexRef(propertyIndex), value, objectKey);
    return try catalog.setValueIndexRef(transaction, catalogRef, propertyIndex, newVi);
}

/// Append a new row to all columns and update the primaryKey index.
/// values.len must equal the propertyCount stored in the catalog.
/// Returns error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(transaction: *WriteTransaction, catalogRef: Reference, values: []const u64) !struct { catalogRef: Reference, row: u64 } {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    std.debug.assert(values.len == snapshot.propertyCount);
    const propertyCount = snapshot.propertyCount;
    const row = snapshot.nextRow;
    const objectKey = snapshot.nextKey;

    const primaryKey = values[0];
    if ((try Index.get(transaction, snapshot.primaryKeyIndexRef, primaryKey)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            snapshot.properties[propertyIndex].col = try Column.append(transaction, snapshot.properties[propertyIndex].col, values[propertyIndex]);
        }
    }
    snapshot.versionColRef = try Column.append(transaction, snapshot.versionColRef, transaction.newVersion);
    snapshot.liveColRef = try Column.append(transaction, snapshot.liveColRef, 1);
    // primaryKey index maps primaryKey -> objectKey; keyrow index maps objectKey -> physical row.
    snapshot.primaryKeyIndexRef = try Index.insert(transaction, snapshot.primaryKeyIndexRef, primaryKey, objectKey);
    snapshot.keyrowIndexRef = try Index.insert(transaction, snapshot.keyrowIndexRef, objectKey, row);
    snapshot.nextRow = row + 1;
    snapshot.nextKey = objectKey + 1;

    const newCatalog = try snapshot.replace(transaction);
    // Maintain the value index for each indexed property: add this row's objectKey to
    // the inner set at its stored value, in the same transaction as the row.
    var updatedCatalog = newCatalog;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) updatedCatalog = try addValueIndex(transaction, updatedCatalog, propertyIndex, values[propertyIndex], objectKey);
        }
    }
    return .{ .catalogRef = updatedCatalog, .row = objectKey };
}

/// The row's current version, reported when an optimistic write loses the race.
pub const Conflict = struct { currentVersion: u64 };
/// Outcome of a raw or typed update: new catalog + version, conflict, or absent.
pub const UpdateResult = union(enum) {
    ok: struct { catalogRef: Reference, version: u64 },
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
pub fn update(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, values: []const u64, expectedVersion: u64) !UpdateResult {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    std.debug.assert(values.len == snapshot.propertyCount);
    std.debug.assert(values[0] == primaryKey); // primaryKey is identity, must not change
    const objectKey = (try Index.get(transaction, snapshot.primaryKeyIndexRef, primaryKey)) orelse return .notFound;
    // The primaryKey index resolved but the key->row index did not: treat the divergence
    // as absent rather than crashing on corrupt data.
    const row = (try Index.get(transaction, snapshot.keyrowIndexRef, objectKey)) orelse return .notFound;
    const currentVersion = try Column.get(transaction, snapshot.versionColRef, row);
    if (currentVersion != expectedVersion) return .{ .conflict = .{ .currentVersion = currentVersion } };
    const propertyCount = snapshot.propertyCount;

    // Snapshot the current value of each indexed property before overwriting the
    // column, so the value index can move the objectKey from its old to its new value.
    var oldValues: [maxPropertyCount]u64 = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) oldValues[propertyIndex] = try Column.get(transaction, snapshot.properties[propertyIndex].col, row);
        }
    }

    // Copy-on-write only the columns whose value actually changed: an O(height)
    // read is strictly cheaper than an O(height) path copy, so a one-field
    // update on a wide type no longer rewrites every property column.
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        const currentValue = try Column.get(transaction, snapshot.properties[propertyIndex].col, row);
        if (currentValue != values[propertyIndex]) snapshot.properties[propertyIndex].col = try Column.set(transaction, snapshot.properties[propertyIndex].col, row, values[propertyIndex]);
    }
    snapshot.versionColRef = try Column.set(transaction, snapshot.versionColRef, row, transaction.newVersion);

    const newCatalog = try snapshot.replace(transaction);
    // Re-point the value index for any indexed property whose value changed.
    var updatedCatalog = newCatalog;
    {
        var reindexIndex: usize = 0;
        while (reindexIndex < propertyCount) : (reindexIndex += 1) {
            if (snapshot.properties[reindexIndex].indexed and oldValues[reindexIndex] != values[reindexIndex]) {
                updatedCatalog = try removeValueIndex(transaction, updatedCatalog, reindexIndex, oldValues[reindexIndex], objectKey);
                updatedCatalog = try addValueIndex(transaction, updatedCatalog, reindexIndex, values[reindexIndex], objectKey);
            }
        }
    }
    return .{ .ok = .{ .catalogRef = updatedCatalog, .version = transaction.newVersion } };
}

/// Tombstone the row identified by `primaryKey`, guarded by the row's expected version.
/// Drops the primaryKey and key->row index entries and every value-index entry, but
/// leaves the physical column cells intact for pinned readers.
pub fn delete(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, expectedVersion: u64) !DeleteResult {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const objectKey = (try Index.get(transaction, snapshot.primaryKeyIndexRef, primaryKey)) orelse return .notFound;
    const row = (try Index.get(transaction, snapshot.keyrowIndexRef, objectKey)) orelse return .notFound;
    const currentVersion = try Column.get(transaction, snapshot.versionColRef, row);
    if (currentVersion != expectedVersion) return .{ .conflict = .{ .currentVersion = currentVersion } };
    const propertyCount = snapshot.propertyCount;

    // Read the value of each indexed property while the row is still readable,
    // so its objectKey can be dropped from the value index. Property columns are not
    // mutated by delete, so the snapshot's cols still address the current values.
    var oldValues: [maxPropertyCount]u64 = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) oldValues[propertyIndex] = try Column.get(transaction, snapshot.properties[propertyIndex].col, row);
        }
    }

    snapshot.liveColRef = try Column.set(transaction, snapshot.liveColRef, row, 0); // tombstone
    snapshot.versionColRef = try Column.set(transaction, snapshot.versionColRef, row, transaction.newVersion); // bump version stamp
    snapshot.primaryKeyIndexRef = try Index.remove(transaction, snapshot.primaryKeyIndexRef, primaryKey); // remove primaryKey from the index
    // Drop the object key from the key->row index. Copy-on-write keeps the old
    // index version intact for any reader pinned to the prior snapshot, so this
    // is MVCC-safe; it prevents a stale key from aliasing a row a later
    // relocation reuses.
    snapshot.keyrowIndexRef = try Index.remove(transaction, snapshot.keyrowIndexRef, objectKey);

    const newCatalog = try snapshot.replace(transaction);
    // Drop this row's objectKey from the value index for every indexed property.
    var updatedCatalog = newCatalog;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (snapshot.properties[propertyIndex].indexed) updatedCatalog = try removeValueIndex(transaction, updatedCatalog, propertyIndex, oldValues[propertyIndex], objectKey);
        }
    }
    return .{ .ok = updatedCatalog };
}

/// Read a row by primary key into `out` (raw u64 cells). Returns the row
/// version, or null when the key is not found or the row is tombstoned.
pub fn getByPrimaryKey(transaction: anytype, catalogRef: Reference, primaryKey: u64, out: []u64) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
    std.debug.assert(out.len == view.propertyCount);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexRef, primaryKey)) orelse return null;
    return getByObjectKey(transaction, catalogRef, objectKey, out);
}

/// Read a row by its stable object key. Resolves the objectKey to a physical row via
/// the key-to-row index. Returns the row version, or null if the objectKey is unknown
/// or the row is tombstoned.
pub fn getByObjectKey(transaction: anytype, catalogRef: Reference, objectKey: u64, out: []u64) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
    std.debug.assert(out.len == view.propertyCount);
    const row = (try catalog.objectKeyToRow(transaction, catalogRef, objectKey)) orelse return null;
    const liveColRef = view.liveColRef;
    const versionColRef = view.versionColRef;
    var propertyRefs: [maxPropertyCount]Reference = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) propertyRefs[propertyIndex] = view.propertyColumnRef(propertyIndex);
    }
    const propertyCount = view.propertyCount;
    if ((try Column.get(transaction, liveColRef, row)) == 0) return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) out[propertyIndex] = try Column.get(transaction, propertyRefs[propertyIndex], row);
    return try Column.get(transaction, versionColRef, row);
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
                    // Elements are blob refs: free each before the tree.
                    const elementCount = try Column.length(transaction, raw[propertyIndex]);
                    var elementIndex: u64 = 0;
                    while (elementIndex < elementCount) : (elementIndex += 1) try blob.free(transaction, try Column.get(transaction, raw[propertyIndex], elementIndex));
                }
                try Column.freeTree(transaction, raw[propertyIndex]);
            },
            .set => switch (elements[propertyIndex]) {
                .int => try Index.freeTree(transaction, raw[propertyIndex]),
                .blob => try bindex.freeTree(transaction, raw[propertyIndex]),
            },
            .dict => try bindex.freeTree(transaction, raw[propertyIndex]),
            .linkSet => try Index.freeTree(transaction, raw[propertyIndex]),
            .int, .link => {},
        }
    }
}
