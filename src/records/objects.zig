// objects.zig -- typed encode/decode orchestration over the raw row layer.
//
// Encodes []Value rows into raw u64 storage (allocating blob and collection
// structures), decodes them back, and keeps the link graph consistent
// (backlinks, nullify-on-delete). The raw column/index CRUD it drives lives
// below this in rows.zig.

const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const blob = @import("blob.zig");
const catalog = @import("../schema/catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");
const rows = @import("rows.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const Value = catalog.Value;
const max_prop_count = catalog.max_prop_count;

const loadCatalog = catalog.loadCatalog;

/// Result types shared with the raw layer: the typed update/delete return the
/// same shapes rows.update/rows.delete produce.
pub const Conflict = rows.Conflict;
pub const UpdateResult = rows.UpdateResult;
pub const DeleteResult = rows.DeleteResult;

// insertTyped encodes a []Value row into raw u64 storage, allocating a blob
// node for each .blob property, then delegates to rows.insert.
pub fn insertTyped(txn: *WriteTransaction, cat: Reference, values: []const Value) !struct { cat: Reference, row: u64 } {
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
    const r = try rows.insert(txn, cat, raw[0..pc]);
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
pub fn getTyped(txn: anytype, cat: Reference, pk: u64, out: []Value) !?u64 {
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
    const ver = (try rows.getByPk(txn, cat, pk, raw[0..pc])) orelse return null;
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
pub fn getTypedByOkey(txn: anytype, cat: Reference, okey: u64, out: []Value) !?u64 {
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
    const ver = (try rows.getByObjectKey(txn, cat, okey, raw[0..pc])) orelse return null;
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
pub fn deleteAndNullify(txn: *WriteTransaction, cat: Reference, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const row = (try catalog.okeyToRow(txn, cat, okey)) orelse return .not_found;
    const cur_ver = try Column.get(txn, v.version_col_ref, row);
    if (cur_ver != expected_version) return .{ .conflict = .{ .current_version = cur_ver } };
    const fixed = try links.fixBacklinksForDelete(txn, cat, okey);
    return try rows.delete(txn, fixed, pk, expected_version);
}

// updateTyped is MVCC-safe: it does NOT free any blob unless the version check
// passes. Steps: read current row, check version, then on the apply path free
// old blobs and allocate new ones before delegating to rows.update.
// Deliberately one long function: the read/check/free/allocate/update sequence
// is one irreducible MVCC step -- splitting it would scatter the frees from
// the version check that alone makes them safe.
pub fn updateTyped(
    txn: *WriteTransaction,
    cat: Reference,
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
    const current_version = (try rows.getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
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
    const result = try rows.update(txn, cat, pk, new_raw[0..pc], expected_version);
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

// deleteTyped is MVCC-safe: blobs are freed only on the apply path, never on
// conflict or not_found.
pub fn deleteTyped(
    txn: *WriteTransaction,
    cat: Reference,
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
    const current_version = (try rows.getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
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
        .ok => try rows.freeRowStorage(txn, kinds[0..pc], elems[0..pc], cur_raw[0..pc]),
        else => {},
    }
    return result;
}

test {
    _ = @import("objectsTests.zig");
}
