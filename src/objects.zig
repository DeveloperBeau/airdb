const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("bindex.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

const loadCatalog = catalog.loadCatalog;
const writeCatalog = catalog.writeCatalog;

// ---------------------------------------------------------------------------
// Per-property value index maintenance.
//
// A value index has the same shape as a backlink index: value -> set_root,
// where set_root is an index of okey -> 1. It is kept transactionally in sync
// with the base row on every insert, update, and delete of an indexed property,
// so an equality/range query reads from a view that can never diverge from the
// rows. These helpers mirror the backlink add/remove path in links.zig.
// ---------------------------------------------------------------------------

// Add `okey` to the value-index inner set for `value`, returning the new index ref.
// Pub: the migration backfill reuses it to index pre-migration rows.
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

// insert appends a new row to all columns and updates the pk index.
// values.len must equal the prop_count stored in the catalog.
// Returns error.DuplicateKey if values[0] (the primary key) already exists.
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

pub const Conflict = struct { current_version: u64 };
pub const UpdateResult = union(enum) {
    ok: struct { cat: Ref, version: u64 },
    conflict: Conflict,
    not_found,
};

pub const DeleteResult = union(enum) {
    ok: Ref, // new catalog
    conflict: Conflict,
    not_found,
};

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

pub fn getByPk(txn: anytype, cat: Ref, pk: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return null;
    return getByObjectKey(txn, cat, okey, out);
}

// Read a row by its stable object key. Resolves the okey to a physical row via
// the key-to-row index. Returns the row version, or null if the okey is unknown
// or the row is tombstoned.
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

// insertTyped encodes a []Value row into raw u64 storage, allocating a blob
// node for each .blob property, then delegates to insert.
pub fn insertTyped(txn: *WriteTxn, cat: Ref, values: []const Value) !struct { cat: Ref, row: u64 } {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(values.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds and elems into local buffers before any mutation that could
    // invalidate the deref slice backing CatalogView.
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
        }
    }
    var raw: [max_prop_count]u64 = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        raw[i] = switch (kinds[i]) {
            .int => values[i].int,
            .blob => try blob.put(txn, values[i].bytes),
            .list => switch (elems[i]) {
                .int => try collections.buildListInt(txn, values[i].list_int),
                .blob => try collections.buildListBlob(txn, values[i].list_blob),
            },
            .set => switch (elems[i]) {
                .int => try collections.buildSetInt(txn, values[i].set_int),
                .blob => try collections.buildSetBlob(txn, values[i].set_blob),
            },
            .dict => try collections.buildDict(txn, values[i].dict_int),
            .link => if (values[i].link) |k| k + 1 else 0,
            .link_set => try collections.buildSetInt(txn, values[i].link_set),
        };
    }
    const r = try insert(txn, cat, raw[0..pc]);
    // Maintain backlinks for any links the new row carries.
    var cat_ref = r.cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            switch (kinds[p]) {
                .link => {
                    if (values[p].link) |target| {
                        cat_ref = try links.addBacklink(txn, cat_ref, p, target, r.row);
                    }
                },
                .link_set => {
                    for (values[p].link_set) |target| {
                        cat_ref = try links.addBacklink(txn, cat_ref, p, target, r.row);
                    }
                },
                else => {},
            }
        }
    }
    return .{ .cat = cat_ref, .row = r.row };
}

// getTyped reads a row by primary key and decodes each property into a Value.
// A small .blob property decodes to a zero-copy .bytes slice into the mapped
// storage; a blob larger than the inline cap (stored chunked) decodes to a
// .blob_ref the caller materializes with blob.getAlloc.
// Returns the row version, or null when the key is not found.
pub fn getTyped(txn: anytype, cat: Ref, pk: u64, out: []Value) !?u64 {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(out.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds before the getByPk call may touch other catalog nodes.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    var raw: [max_prop_count]u64 = undefined;
    const ver = (try getByPk(txn, cat, pk, raw[0..pc])) orelse return null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        out[i] = switch (kinds[i]) {
            .int => .{ .int = raw[i] },
            .blob => if (blob.get(txn, raw[i])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blob_ref = raw[i] },
                else => |e| return e,
            },
            .list, .set, .dict, .link_set => .{ .coll_root = raw[i] },
            .link => .{ .link = if (raw[i] == 0) null else raw[i] - 1 },
        };
    }
    return ver;
}

// getTypedByOkey decodes a row addressed by stable object key into Values.
pub fn getTypedByOkey(txn: anytype, cat: Ref, okey: u64, out: []Value) !?u64 {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(out.len == pc);
    std.debug.assert(pc <= max_prop_count);
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    var raw: [max_prop_count]u64 = undefined;
    const ver = (try getByObjectKey(txn, cat, okey, raw[0..pc])) orelse return null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        out[i] = switch (kinds[i]) {
            .int => .{ .int = raw[i] },
            .blob => if (blob.get(txn, raw[i])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blob_ref = raw[i] },
                else => |e| return e,
            },
            .list, .set, .dict, .link_set => .{ .coll_root = raw[i] },
            .link => .{ .link = if (raw[i] == 0) null else raw[i] - 1 },
        };
    }
    return ver;
}

// Delete an object and keep the graph consistent: nullify inbound links and
// clean the deleted object's outbound backlink entries.
pub fn deleteAndNullify(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const row = (try catalog.okeyToRow(txn, cat, okey)) orelse return .not_found;
    const cur_ver = try Column.get(txn, v.version_col_ref, row);
    if (cur_ver != expected_version) return .{ .conflict = .{ .current_version = cur_ver } };
    const fixed = try links.fixBacklinksForDelete(txn, cat, okey);
    return try delete(txn, fixed, pk, expected_version);
}

// updateTyped is MVCC-safe: it does NOT free any blob unless the version check
// passes. Steps: read current row, check version, then on the apply path free
// old blobs and allocate new ones before delegating to update.
pub fn updateTyped(
    txn: *WriteTxn,
    cat: Ref,
    pk: u64,
    values: []const Value,
    expected_version: u64,
) !UpdateResult {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(values.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds before any mutation.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    // Step 1: read the current row into cur_raw.
    var cur_raw: [max_prop_count]u64 = undefined;
    const current_version = (try getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
    // Step 2: version check BEFORE freeing or allocating any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: apply path -- free old blobs and allocate new ones. Collection
    // properties are CARRIED THROUGH unchanged (mutate them via their own
    // APIs): updating any row of a collection-bearing type must not require
    // the caller to re-supply roots, and must never crash.
    var new_raw: [max_prop_count]u64 = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        new_raw[i] = switch (kinds[i]) {
            .int => values[i].int,
            .blob => blk: {
                try blob.free(txn, cur_raw[i]);
                break :blk try blob.put(txn, values[i].bytes);
            },
            .list, .set, .dict, .link_set => cur_raw[i],
            .link => if (values[i].link) |k| k + 1 else 0,
        };
    }
    // Step 4: delegate to the core update; it will re-check the version (match).
    const result = try update(txn, cat, pk, new_raw[0..pc], expected_version);
    // Step 5: maintain backlinks for any changed to-one link, mirroring
    // setLink. Skipping this left the old target's backlink set naming this
    // source forever and the new target's set missing it -- corrupting
    // nullify/cascade/block enforcement. The backlink source is the okey.
    switch (result) {
        .ok => |ok| {
            var cat_out = ok.cat;
            var changed = false;
            var p: usize = 0;
            while (p < pc) : (p += 1) {
                if (kinds[p] != .link or cur_raw[p] == new_raw[p]) continue;
                // The row was just updated successfully, so its pk must
                // resolve; anything else is index divergence, and bailing
                // mid-loop would leave the backlinks half-moved.
                const okey = (try catalog.pkToOkey(txn, cat_out, pk)) orelse return error.Corrupt;
                if (cur_raw[p] != 0) cat_out = try links.removeBacklink(txn, cat_out, p, cur_raw[p] - 1, okey);
                if (new_raw[p] != 0) cat_out = try links.addBacklink(txn, cat_out, p, new_raw[p] - 1, okey);
                changed = true;
            }
            if (changed) return .{ .ok = .{ .cat = cat_out, .version = ok.version } };
            return result;
        },
        else => return result,
    }
}

// Free the blob and collection storage held in a deleted row's columns.
// `raw` holds the row's column values captured before the tombstone (the
// tombstone leaves the physical columns intact, so a pre-delete read stays
// accurate). Shared by deleteTyped and the directory-level delete
// (typedir.deleteWorker); before that sharing, every row deleted through the
// directory path -- including every cascade-deleted child -- leaked its blobs
// and list/set/dict trees permanently. A raw of 0 (no storage, e.g. a row
// written with caller-supplied raws or a dead-row migration backfill) frees
// nothing rather than erroring mid-delete.
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

// deleteTyped is MVCC-safe: blobs are freed only on the apply path, never on
// conflict or not_found.
pub fn deleteTyped(
    txn: *WriteTxn,
    cat: Ref,
    pk: u64,
    expected_version: u64,
) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds/elems before any mutation.
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
        }
    }
    // Step 1: read the current row.
    var cur_raw: [max_prop_count]u64 = undefined;
    const current_version = (try getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
    // Step 2: version check BEFORE freeing any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: delegate to the graph-safe delete (nullifies inbound links).
    const result = try deleteAndNullify(txn, cat, pk, expected_version);
    // Step 4: on the apply path, free the row's blob and collection storage.
    // This runs AFTER deleteAndNullify because the outbound backlink cleanup
    // reads the link_set roots; the tombstoned row's columns still hold the
    // roots, so cur_raw stays accurate. Without this every deleted row leaked
    // its blobs and list/set/dict trees (and their element/key blobs)
    // permanently. MVCC-safe: a conflict or not_found result frees nothing.
    switch (result) {
        .ok => try freeRowStorage(txn, kinds[0..pc], elems[0..pc], cur_raw[0..pc]),
        else => {},
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("objectsTests.zig");
}
