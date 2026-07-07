// rows.zig -- raw row CRUD over the catalog's columns and indexes.
//
// This is the storage-level half of the object layer: insert/update/delete of
// raw u64 rows, reads by primary key or stable object key, per-property value
// index maintenance, and reclamation of a deleted row's blob/collection
// storage. Typed encode/decode orchestration (Values, backlinks, cascades)
// lives above this in objects.zig.

const std = @import("std");
const WriteTxn = @import("writeTransaction.zig").WriteTxn;
const Ref = @import("reference.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("byteKeyIndex.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const max_prop_count = catalog.max_prop_count;

const loadCatalog = catalog.loadCatalog;

// ---------------------------------------------------------------------------
// Per-property value index maintenance.
//
// A value index has the same shape as a backlink index: value -> set_root,
// where set_root is an index of okey -> 1. It is kept transactionally in sync
// with the base row on every insert, update, and delete of an indexed property,
// so an equality/range query reads from a view that can never diverge from the
// rows. These helpers mirror the backlink add/remove path in links.zig.
// ---------------------------------------------------------------------------

/// Add `okey` to the value-index inner set for `value`, returning the new index ref.
/// Pub: the migration backfill reuses it to index pre-migration rows.
pub fn viAdd(txn: *WriteTxn, vi_ref: Ref, value: u64, okey: u64) !Ref {
    const existing = try Index.get(txn, vi_ref, value);
    var set_root = existing orelse try Index.create(txn);
    set_root = try Index.insert(txn, set_root, okey, 1);
    return try Index.insert(txn, vi_ref, value, set_root);
}

// Remove `okey` from the value-index inner set for `value`. No-op if absent.
// When the inner set empties, its outer entry is removed and the set's nodes
// freed: high-churn workloads would otherwise accumulate one empty set per
// distinct value ever indexed, reclaimable only by a full file copy.
fn viRemove(txn: *WriteTxn, vi_ref: Ref, value: u64, okey: u64) !Ref {
    const existing = try Index.get(txn, vi_ref, value);
    const set_root = existing orelse return vi_ref;
    const new_set = try Index.remove(txn, set_root, okey);
    if ((try Index.count(txn, new_set)) == 0) {
        const new_vi = try Index.remove(txn, vi_ref, value);
        try Index.freeTree(txn, new_set);
        return new_vi;
    }
    return try Index.insert(txn, vi_ref, value, new_set);
}

// Add okey->value to indexed property p's value index. Returns the new catalog.
fn addValueIndex(txn: *WriteTxn, cat: Ref, p: usize, value: u64, okey: u64) !Ref {
    const v = try loadCatalog(txn, cat);
    const new_vi = try viAdd(txn, v.valueIndexRef(p), value, okey);
    return try catalog.setValueIndexRef(txn, cat, p, new_vi);
}

// Remove okey from indexed property p's value-index set for `value`.
fn removeValueIndex(txn: *WriteTxn, cat: Ref, p: usize, value: u64, okey: u64) !Ref {
    const v = try loadCatalog(txn, cat);
    const new_vi = try viRemove(txn, v.valueIndexRef(p), value, okey);
    return try catalog.setValueIndexRef(txn, cat, p, new_vi);
}

/// Append a new row to all columns and update the pk index.
/// values.len must equal the prop_count stored in the catalog.
/// Returns error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(txn: *WriteTxn, cat: Ref, values: []const u64) !struct { cat: Ref, row: u64 } {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    std.debug.assert(values.len == s.prop_count);
    const prop_count = s.prop_count;
    const row = s.next_row;
    const okey = s.next_key;

    const pk = values[0];
    if ((try Index.get(txn, s.pk_index_ref, pk)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    {
        var i: usize = 0;
        while (i < prop_count) : (i += 1) {
            s.props[i].col = try Column.append(txn, s.props[i].col, values[i]);
        }
    }
    s.version_col_ref = try Column.append(txn, s.version_col_ref, txn.new_version);
    s.live_col_ref = try Column.append(txn, s.live_col_ref, 1);
    // pk index maps pk -> okey; keyrow index maps okey -> physical row.
    s.pk_index_ref = try Index.insert(txn, s.pk_index_ref, pk, okey);
    s.keyrow_index_ref = try Index.insert(txn, s.keyrow_index_ref, okey, row);
    s.next_row = row + 1;
    s.next_key = okey + 1;

    const new_cat = try s.replace(txn);
    // Maintain the value index for each indexed property: add this row's okey to
    // the inner set at its stored value, in the same transaction as the row.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            if (s.props[p].indexed) cat_out = try addValueIndex(txn, cat_out, p, values[p], okey);
        }
    }
    return .{ .cat = cat_out, .row = okey };
}

/// The row's current version, reported when an optimistic write loses the race.
pub const Conflict = struct { current_version: u64 };
/// Outcome of a raw or typed update: new catalog + version, conflict, or absent.
pub const UpdateResult = union(enum) {
    ok: struct { cat: Ref, version: u64 },
    conflict: Conflict,
    not_found,
};

/// Outcome of a raw or typed delete: new catalog, conflict, or absent.
pub const DeleteResult = union(enum) {
    ok: Ref, // new catalog
    conflict: Conflict,
    not_found,
};

/// Overwrite the row identified by `pk` with `values`, guarded by the row's
/// expected version. Copy-on-writes only the columns whose value changed and
/// keeps every indexed property's value index in sync.
pub fn update(txn: *WriteTxn, cat: Ref, pk: u64, values: []const u64, expected_version: u64) !UpdateResult {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    std.debug.assert(values.len == s.prop_count);
    std.debug.assert(values[0] == pk); // pk is identity, must not change
    const okey = (try Index.get(txn, s.pk_index_ref, pk)) orelse return .not_found;
    // The pk index resolved but the key->row index did not: treat the divergence
    // as absent rather than crashing on corrupt data.
    const row = (try Index.get(txn, s.keyrow_index_ref, okey)) orelse return .not_found;
    const cur = try Column.get(txn, s.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };
    const pc = s.prop_count;

    // Snapshot the current value of each indexed property before overwriting the
    // column, so the value index can move the okey from its old to its new value.
    var old_vals: [max_prop_count]u64 = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            if (s.props[j].indexed) old_vals[j] = try Column.get(txn, s.props[j].col, row);
        }
    }

    // Copy-on-write only the columns whose value actually changed: an O(height)
    // read is strictly cheaper than an O(height) path copy, so a one-field
    // update on a wide type no longer rewrites every property column.
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        const cur_val = try Column.get(txn, s.props[i].col, row);
        if (cur_val != values[i]) s.props[i].col = try Column.set(txn, s.props[i].col, row, values[i]);
    }
    s.version_col_ref = try Column.set(txn, s.version_col_ref, row, txn.new_version);

    const new_cat = try s.replace(txn);
    // Re-point the value index for any indexed property whose value changed.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            if (s.props[p].indexed and old_vals[p] != values[p]) {
                cat_out = try removeValueIndex(txn, cat_out, p, old_vals[p], okey);
                cat_out = try addValueIndex(txn, cat_out, p, values[p], okey);
            }
        }
    }
    return .{ .ok = .{ .cat = cat_out, .version = txn.new_version } };
}

/// Tombstone the row identified by `pk`, guarded by the row's expected version.
/// Drops the pk and key->row index entries and every value-index entry, but
/// leaves the physical column cells intact for pinned readers.
pub fn delete(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const okey = (try Index.get(txn, s.pk_index_ref, pk)) orelse return .not_found;
    const row = (try Index.get(txn, s.keyrow_index_ref, okey)) orelse return .not_found;
    const cur = try Column.get(txn, s.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };
    const pc = s.prop_count;

    // Read the value of each indexed property while the row is still readable,
    // so its okey can be dropped from the value index. Property columns are not
    // mutated by delete, so the snapshot's cols still address the current values.
    var old_vals: [max_prop_count]u64 = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            if (s.props[j].indexed) old_vals[j] = try Column.get(txn, s.props[j].col, row);
        }
    }

    s.live_col_ref = try Column.set(txn, s.live_col_ref, row, 0); // tombstone
    s.version_col_ref = try Column.set(txn, s.version_col_ref, row, txn.new_version); // bump version stamp
    s.pk_index_ref = try Index.remove(txn, s.pk_index_ref, pk); // remove pk from the index
    // Drop the object key from the key->row index. Copy-on-write keeps the old
    // index version intact for any reader pinned to the prior snapshot, so this
    // is MVCC-safe; it prevents a stale key from aliasing a row a later
    // relocation reuses.
    s.keyrow_index_ref = try Index.remove(txn, s.keyrow_index_ref, okey);

    const new_cat = try s.replace(txn);
    // Drop this row's okey from the value index for every indexed property.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            if (s.props[p].indexed) cat_out = try removeValueIndex(txn, cat_out, p, old_vals[p], okey);
        }
    }
    return .{ .ok = cat_out };
}

/// Read a row by primary key into `out` (raw u64 cells). Returns the row
/// version, or null when the key is not found or the row is tombstoned.
pub fn getByPk(txn: anytype, cat: Ref, pk: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return null;
    return getByObjectKey(txn, cat, okey, out);
}

/// Read a row by its stable object key. Resolves the okey to a physical row via
/// the key-to-row index. Returns the row version, or null if the okey is unknown
/// or the row is tombstoned.
pub fn getByObjectKey(txn: anytype, cat: Ref, okey: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    const row = (try catalog.okeyToRow(txn, cat, okey)) orelse return null;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    if ((try Column.get(txn, live_col_ref, row)) == 0) return null;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) out[i] = try Column.get(txn, prop_refs[i], row);
    return try Column.get(txn, version_col_ref, row);
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
pub fn freeRowStorage(txn: *WriteTxn, kinds: []const PropKind, elems: []const ElemKind, raw: []const u64) !void {
    var i: usize = 0;
    while (i < kinds.len) : (i += 1) {
        if (raw[i] == 0) continue;
        switch (kinds[i]) {
            .blob => try blob.free(txn, raw[i]),
            .list => {
                if (elems[i] == .blob) {
                    // Elements are blob refs: free each before the tree.
                    const n = try Column.len(txn, raw[i]);
                    var e: u64 = 0;
                    while (e < n) : (e += 1) try blob.free(txn, try Column.get(txn, raw[i], e));
                }
                try Column.freeTree(txn, raw[i]);
            },
            .set => switch (elems[i]) {
                .int => try Index.freeTree(txn, raw[i]),
                .blob => try bindex.freeTree(txn, raw[i]),
            },
            .dict => try bindex.freeTree(txn, raw[i]),
            .link_set => try Index.freeTree(txn, raw[i]),
            .int, .link => {},
        }
    }
}
