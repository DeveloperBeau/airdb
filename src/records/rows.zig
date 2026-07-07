// rows.zig -- raw row CRUD over the catalog's columns and indexes.
//
// This is the storage-level half of the object layer: insert/update/delete of
// raw u64 rows, reads by primary key or stable object key, per-property value
// index maintenance, and reclamation of a deleted row's blob/collection
// storage. Typed encode/decode orchestration (Values, backlinks, cascades)
// lives above this in objects.zig.

const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const bindex = @import("../trees/byteKeyIndex.zig");
const blob = @import("blob.zig");
const catalog = @import("../schema/catalog.zig");

const PropertyKind = catalog.PropertyKind;
const ElemKind = catalog.ElemKind;
const maxPropertyCount = catalog.maxPropertyCount;

const loadCatalog = catalog.loadCatalog;

// ---------------------------------------------------------------------------
// Per-property value index maintenance.
//
// A value index has the same shape as a backlink index: value -> set_root,
// where set_root is an index of objectKey -> 1. It is kept transactionally in sync
// with the base row on every insert, update, and delete of an indexed property,
// so an equality/range query reads from a view that can never diverge from the
// rows. These helpers mirror the backlink add/remove path in links.zig.
// ---------------------------------------------------------------------------

/// Add `objectKey` to the value-index inner set for `value`, returning the new index ref.
/// Pub: the migration backfill reuses it to index pre-migration rows.
pub fn valueIndexAdd(transaction: *WriteTransaction, valueIndexRef: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexRef, value);
    var set_root = existing orelse try Index.create(transaction);
    set_root = try Index.insert(transaction, set_root, objectKey, 1);
    return try Index.insert(transaction, valueIndexRef, value, set_root);
}

// Remove `objectKey` from the value-index inner set for `value`. No-op if absent.
// When the inner set empties, its outer entry is removed and the set's nodes
// freed: high-churn workloads would otherwise accumulate one empty set per
// distinct value ever indexed, reclaimable only by a full file copy.
fn valueIndexRemove(transaction: *WriteTransaction, valueIndexRef: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(transaction, valueIndexRef, value);
    const set_root = existing orelse return valueIndexRef;
    const new_set = try Index.remove(transaction, set_root, objectKey);
    if ((try Index.count(transaction, new_set)) == 0) {
        const new_vi = try Index.remove(transaction, valueIndexRef, value);
        try Index.freeTree(transaction, new_set);
        return new_vi;
    }
    return try Index.insert(transaction, valueIndexRef, value, new_set);
}

// Add objectKey->value to indexed property p's value index. Returns the new catalog.
fn addValueIndex(transaction: *WriteTransaction, catalogRef: Reference, p: usize, value: u64, objectKey: u64) !Reference {
    const v = try loadCatalog(transaction, catalogRef);
    const new_vi = try valueIndexAdd(transaction, v.valueIndexRef(p), value, objectKey);
    return try catalog.setValueIndexRef(transaction, catalogRef, p, new_vi);
}

// Remove objectKey from indexed property p's value-index set for `value`.
fn removeValueIndex(transaction: *WriteTransaction, catalogRef: Reference, p: usize, value: u64, objectKey: u64) !Reference {
    const v = try loadCatalog(transaction, catalogRef);
    const new_vi = try valueIndexRemove(transaction, v.valueIndexRef(p), value, objectKey);
    return try catalog.setValueIndexRef(transaction, catalogRef, p, new_vi);
}

/// Append a new row to all columns and update the primaryKey index.
/// values.len must equal the propertyCount stored in the catalog.
/// Returns error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(transaction: *WriteTransaction, catalogRef: Reference, values: []const u64) !struct { catalogRef: Reference, row: u64 } {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    std.debug.assert(values.len == s.propertyCount);
    const propertyCount = s.propertyCount;
    const row = s.next_row;
    const objectKey = s.next_key;

    const primaryKey = values[0];
    if ((try Index.get(transaction, s.primaryKeyIndexRef, primaryKey)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    {
        var i: usize = 0;
        while (i < propertyCount) : (i += 1) {
            s.properties[i].col = try Column.append(transaction, s.properties[i].col, values[i]);
        }
    }
    s.version_col_ref = try Column.append(transaction, s.version_col_ref, transaction.new_version);
    s.live_col_ref = try Column.append(transaction, s.live_col_ref, 1);
    // primaryKey index maps primaryKey -> objectKey; keyrow index maps objectKey -> physical row.
    s.primaryKeyIndexRef = try Index.insert(transaction, s.primaryKeyIndexRef, primaryKey, objectKey);
    s.keyrow_index_ref = try Index.insert(transaction, s.keyrow_index_ref, objectKey, row);
    s.next_row = row + 1;
    s.next_key = objectKey + 1;

    const newCatalog = try s.replace(transaction);
    // Maintain the value index for each indexed property: add this row's objectKey to
    // the inner set at its stored value, in the same transaction as the row.
    var updatedCatalog = newCatalog;
    {
        var p: usize = 0;
        while (p < propertyCount) : (p += 1) {
            if (s.properties[p].indexed) updatedCatalog = try addValueIndex(transaction, updatedCatalog, p, values[p], objectKey);
        }
    }
    return .{ .catalogRef = updatedCatalog, .row = objectKey };
}

/// The row's current version, reported when an optimistic write loses the race.
pub const Conflict = struct { current_version: u64 };
/// Outcome of a raw or typed update: new catalog + version, conflict, or absent.
pub const UpdateResult = union(enum) {
    ok: struct { catalogRef: Reference, version: u64 },
    conflict: Conflict,
    not_found,
};

/// Outcome of a raw or typed delete: new catalog, conflict, or absent.
pub const DeleteResult = union(enum) {
    ok: Reference, // new catalog
    conflict: Conflict,
    not_found,
};

/// Overwrite the row identified by `primaryKey` with `values`, guarded by the row's
/// expected version. Copy-on-writes only the columns whose value changed and
/// keeps every indexed property's value index in sync.
pub fn update(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, values: []const u64, expected_version: u64) !UpdateResult {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    std.debug.assert(values.len == s.propertyCount);
    std.debug.assert(values[0] == primaryKey); // primaryKey is identity, must not change
    const objectKey = (try Index.get(transaction, s.primaryKeyIndexRef, primaryKey)) orelse return .not_found;
    // The primaryKey index resolved but the key->row index did not: treat the divergence
    // as absent rather than crashing on corrupt data.
    const row = (try Index.get(transaction, s.keyrow_index_ref, objectKey)) orelse return .not_found;
    const cur = try Column.get(transaction, s.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };
    const propertyCount = s.propertyCount;

    // Snapshot the current value of each indexed property before overwriting the
    // column, so the value index can move the objectKey from its old to its new value.
    var old_vals: [maxPropertyCount]u64 = undefined;
    {
        var j: usize = 0;
        while (j < propertyCount) : (j += 1) {
            if (s.properties[j].indexed) old_vals[j] = try Column.get(transaction, s.properties[j].col, row);
        }
    }

    // Copy-on-write only the columns whose value actually changed: an O(height)
    // read is strictly cheaper than an O(height) path copy, so a one-field
    // update on a wide type no longer rewrites every property column.
    var i: usize = 0;
    while (i < propertyCount) : (i += 1) {
        const cur_val = try Column.get(transaction, s.properties[i].col, row);
        if (cur_val != values[i]) s.properties[i].col = try Column.set(transaction, s.properties[i].col, row, values[i]);
    }
    s.version_col_ref = try Column.set(transaction, s.version_col_ref, row, transaction.new_version);

    const newCatalog = try s.replace(transaction);
    // Re-point the value index for any indexed property whose value changed.
    var updatedCatalog = newCatalog;
    {
        var p: usize = 0;
        while (p < propertyCount) : (p += 1) {
            if (s.properties[p].indexed and old_vals[p] != values[p]) {
                updatedCatalog = try removeValueIndex(transaction, updatedCatalog, p, old_vals[p], objectKey);
                updatedCatalog = try addValueIndex(transaction, updatedCatalog, p, values[p], objectKey);
            }
        }
    }
    return .{ .ok = .{ .catalogRef = updatedCatalog, .version = transaction.new_version } };
}

/// Tombstone the row identified by `primaryKey`, guarded by the row's expected version.
/// Drops the primaryKey and key->row index entries and every value-index entry, but
/// leaves the physical column cells intact for pinned readers.
pub fn delete(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, expected_version: u64) !DeleteResult {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const objectKey = (try Index.get(transaction, s.primaryKeyIndexRef, primaryKey)) orelse return .not_found;
    const row = (try Index.get(transaction, s.keyrow_index_ref, objectKey)) orelse return .not_found;
    const cur = try Column.get(transaction, s.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };
    const propertyCount = s.propertyCount;

    // Read the value of each indexed property while the row is still readable,
    // so its objectKey can be dropped from the value index. Property columns are not
    // mutated by delete, so the snapshot's cols still address the current values.
    var old_vals: [maxPropertyCount]u64 = undefined;
    {
        var j: usize = 0;
        while (j < propertyCount) : (j += 1) {
            if (s.properties[j].indexed) old_vals[j] = try Column.get(transaction, s.properties[j].col, row);
        }
    }

    s.live_col_ref = try Column.set(transaction, s.live_col_ref, row, 0); // tombstone
    s.version_col_ref = try Column.set(transaction, s.version_col_ref, row, transaction.new_version); // bump version stamp
    s.primaryKeyIndexRef = try Index.remove(transaction, s.primaryKeyIndexRef, primaryKey); // remove primaryKey from the index
    // Drop the object key from the key->row index. Copy-on-write keeps the old
    // index version intact for any reader pinned to the prior snapshot, so this
    // is MVCC-safe; it prevents a stale key from aliasing a row a later
    // relocation reuses.
    s.keyrow_index_ref = try Index.remove(transaction, s.keyrow_index_ref, objectKey);

    const newCatalog = try s.replace(transaction);
    // Drop this row's objectKey from the value index for every indexed property.
    var updatedCatalog = newCatalog;
    {
        var p: usize = 0;
        while (p < propertyCount) : (p += 1) {
            if (s.properties[p].indexed) updatedCatalog = try removeValueIndex(transaction, updatedCatalog, p, old_vals[p], objectKey);
        }
    }
    return .{ .ok = updatedCatalog };
}

/// Read a row by primary key into `out` (raw u64 cells). Returns the row
/// version, or null when the key is not found or the row is tombstoned.
pub fn getByPrimaryKey(transaction: anytype, catalogRef: Reference, primaryKey: u64, out: []u64) !?u64 {
    const v = try loadCatalog(transaction, catalogRef);
    std.debug.assert(out.len == v.propertyCount);
    const objectKey = (try Index.get(transaction, v.primaryKeyIndexRef, primaryKey)) orelse return null;
    return getByObjectKey(transaction, catalogRef, objectKey, out);
}

/// Read a row by its stable object key. Resolves the objectKey to a physical row via
/// the key-to-row index. Returns the row version, or null if the objectKey is unknown
/// or the row is tombstoned.
pub fn getByObjectKey(transaction: anytype, catalogRef: Reference, objectKey: u64, out: []u64) !?u64 {
    const v = try loadCatalog(transaction, catalogRef);
    std.debug.assert(out.len == v.propertyCount);
    const row = (try catalog.objectKeyToRow(transaction, catalogRef, objectKey)) orelse return null;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var propertyRefs: [maxPropertyCount]Reference = undefined;
    {
        var j: usize = 0;
        while (j < v.propertyCount) : (j += 1) propertyRefs[j] = v.propertyColumnRef(j);
    }
    const propertyCount = v.propertyCount;
    if ((try Column.get(transaction, live_col_ref, row)) == 0) return null;
    var i: usize = 0;
    while (i < propertyCount) : (i += 1) out[i] = try Column.get(transaction, propertyRefs[i], row);
    return try Column.get(transaction, version_col_ref, row);
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
pub fn freeRowStorage(transaction: *WriteTransaction, kinds: []const PropertyKind, elems: []const ElemKind, raw: []const u64) !void {
    var i: usize = 0;
    while (i < kinds.len) : (i += 1) {
        if (raw[i] == 0) continue;
        switch (kinds[i]) {
            .blob => try blob.free(transaction, raw[i]),
            .list => {
                if (elems[i] == .blob) {
                    // Elements are blob refs: free each before the tree.
                    const n = try Column.len(transaction, raw[i]);
                    var e: u64 = 0;
                    while (e < n) : (e += 1) try blob.free(transaction, try Column.get(transaction, raw[i], e));
                }
                try Column.freeTree(transaction, raw[i]);
            },
            .set => switch (elems[i]) {
                .int => try Index.freeTree(transaction, raw[i]),
                .blob => try bindex.freeTree(transaction, raw[i]),
            },
            .dict => try bindex.freeTree(transaction, raw[i]),
            .link_set => try Index.freeTree(transaction, raw[i]),
            .int, .link => {},
        }
    }
}
