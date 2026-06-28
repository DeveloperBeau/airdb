const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
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
fn viAdd(txn: *WriteTxn, vi_ref: Ref, value: u64, okey: u64) !Ref {
    const existing = try Index.get(txn, vi_ref, value);
    var set_root = existing orelse try Index.create(txn);
    set_root = try Index.insert(txn, set_root, okey, 1);
    return try Index.insert(txn, vi_ref, value, set_root);
}

// Remove `okey` from the value-index inner set for `value`. No-op if absent.
fn viRemove(txn: *WriteTxn, vi_ref: Ref, value: u64, okey: u64) !Ref {
    const existing = try Index.get(txn, vi_ref, value);
    const set_root = existing orelse return vi_ref;
    const new_set = try Index.remove(txn, set_root, okey);
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
    const v = try loadCatalog(txn, cat);
    std.debug.assert(values.len == v.prop_count);

    // Capture all refs from the view into locals before any mutation so the
    // bytes slice backing CatalogView cannot be invalidated by file growth.
    const old_keyrow = v.keyrow_index_ref;
    const old_next_key = v.next_key;
    const old_pk_index_ref = v.pk_index_ref;
    const old_version_col_ref = v.version_col_ref;
    const old_live_col_ref = v.live_col_ref;
    var old_prop_refs: [max_prop_count]Ref = undefined;
    var old_kinds: [max_prop_count]PropKind = undefined;
    var old_elems: [max_prop_count]ElemKind = undefined;
    var old_backlinks: [max_prop_count]Ref = undefined;
    var old_targets: [max_prop_count]u16 = undefined;
    var old_rules: [max_prop_count]catalog.DeletionRule = undefined;
    var old_vidx: [max_prop_count]Ref = undefined;
    var old_idxf: [max_prop_count]bool = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            old_prop_refs[j] = v.propColRef(j);
            old_kinds[j] = v.kind(j);
            old_elems[j] = v.elemKind(j);
            old_backlinks[j] = v.backlinkRef(j);
            old_targets[j] = v.linkTarget(j);
            old_rules[j] = v.delRule(j);
            old_vidx[j] = v.valueIndexRef(j);
            old_idxf[j] = v.indexed(j);
        }
    }
    const prop_count = v.prop_count;
    const row = v.next_row;
    const okey = old_next_key;

    const pk = values[0];
    if ((try Index.get(txn, old_pk_index_ref, pk)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    var new_prop_refs: [max_prop_count]Ref = undefined;
    {
        var i: usize = 0;
        while (i < prop_count) : (i += 1) {
            new_prop_refs[i] = try Column.append(txn, old_prop_refs[i], values[i]);
        }
    }
    const new_version_col = try Column.append(txn, old_version_col_ref, txn.new_version);
    const new_live_col = try Column.append(txn, old_live_col_ref, 1);
    // pk index maps pk -> okey; keyrow index maps okey -> physical row.
    const new_index = try Index.insert(txn, old_pk_index_ref, pk, okey);
    const new_keyrow = try Index.insert(txn, old_keyrow, okey, row);

    const new_cat = try writeCatalog(
        txn,
        prop_count,
        row + 1,
        new_keyrow,
        old_next_key + 1,
        new_index,
        new_version_col,
        new_live_col,
        new_prop_refs[0..prop_count],
        old_kinds[0..prop_count],
        old_elems[0..prop_count],
        old_backlinks[0..prop_count],
        old_targets[0..prop_count],
        old_rules[0..prop_count],
        old_vidx[0..prop_count],
        old_idxf[0..prop_count],
    );
    // Maintain the value index for each indexed property: add this row's okey to
    // the inner set at its stored value, in the same transaction as the row.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            if (old_idxf[p]) cat_out = try addValueIndex(txn, cat_out, p, values[p], okey);
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
    const v = try loadCatalog(txn, cat);
    std.debug.assert(values.len == v.prop_count);
    std.debug.assert(values[0] == pk); // pk is identity, must not change
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const row = (try catalog.okeyToRow(txn, cat, okey)).?;
    const cur = try Column.get(txn, v.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };

    // Capture refs into locals before mutating (avoid relying on the catalog deref slice).
    const pc = v.prop_count;
    const idx_ref = v.pk_index_ref;
    const live_ref = v.live_col_ref;
    const next_row = v.next_row;
    var prop_refs: [256]Ref = undefined;
    var kinds: [256]PropKind = undefined;
    var elems_buf: [max_prop_count]ElemKind = undefined;
    var bl_buf: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]catalog.DeletionRule = undefined;
    var vidx_buf: [max_prop_count]Ref = undefined;
    var idxf_buf: [max_prop_count]bool = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
            bl_buf[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
            vidx_buf[j] = v.valueIndexRef(j);
            idxf_buf[j] = v.indexed(j);
        }
    }
    var ver_ref = v.version_col_ref;

    // Snapshot the current value of each indexed property before overwriting the
    // column, so the value index can move the okey from its old to its new value.
    var old_vals: [max_prop_count]u64 = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            if (idxf_buf[j]) old_vals[j] = try Column.get(txn, prop_refs[j], row);
        }
    }

    var i: usize = 0;
    while (i < pc) : (i += 1) prop_refs[i] = try Column.set(txn, prop_refs[i], row, values[i]);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);

    const new_cat = try writeCatalog(txn, pc, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc], bl_buf[0..pc], targets_buf[0..pc], rules_buf[0..pc], vidx_buf[0..pc], idxf_buf[0..pc]);
    // Re-point the value index for any indexed property whose value changed.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            if (idxf_buf[p] and old_vals[p] != values[p]) {
                cat_out = try removeValueIndex(txn, cat_out, p, old_vals[p], okey);
                cat_out = try addValueIndex(txn, cat_out, p, values[p], okey);
            }
        }
    }
    return .{ .ok = .{ .cat = cat_out, .version = txn.new_version } };
}

pub fn delete(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const row = (try catalog.okeyToRow(txn, cat, okey)).?;
    const cur = try Column.get(txn, v.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };

    // Capture refs into locals before mutating.
    const pc = v.prop_count;
    const next_row = v.next_row;
    var prop_refs: [256]Ref = undefined;
    var kinds: [256]PropKind = undefined;
    var elems_buf: [max_prop_count]ElemKind = undefined;
    var bl_buf: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]catalog.DeletionRule = undefined;
    var vidx_buf: [max_prop_count]Ref = undefined;
    var idxf_buf: [max_prop_count]bool = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
            bl_buf[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
            vidx_buf[j] = v.valueIndexRef(j);
            idxf_buf[j] = v.indexed(j);
        }
    }
    var live_ref = v.live_col_ref;
    var ver_ref = v.version_col_ref;
    var idx_ref = v.pk_index_ref;
    var keyrow_ref = v.keyrow_index_ref;

    // Read the value of each indexed property while the row is still readable,
    // so its okey can be dropped from the value index. Property columns are not
    // mutated by delete, so prop_refs still address the row's current values.
    var old_vals: [max_prop_count]u64 = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            if (idxf_buf[j]) old_vals[j] = try Column.get(txn, prop_refs[j], row);
        }
    }

    live_ref = try Column.set(txn, live_ref, row, 0); // tombstone
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version); // bump version stamp
    idx_ref = try Index.remove(txn, idx_ref, pk); // remove pk from the index
    // Drop the object key from the key->row index. Copy-on-write keeps the old
    // index version intact for any reader pinned to the prior snapshot, so this
    // is MVCC-safe; it prevents a stale key from aliasing a row a later
    // relocation reuses.
    keyrow_ref = try Index.remove(txn, keyrow_ref, okey);

    const new_cat = try writeCatalog(txn, pc, next_row, keyrow_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc], bl_buf[0..pc], targets_buf[0..pc], rules_buf[0..pc], vidx_buf[0..pc], idxf_buf[0..pc]);
    // Drop this row's okey from the value index for every indexed property.
    var cat_out = new_cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            if (idxf_buf[p]) cat_out = try removeValueIndex(txn, cat_out, p, old_vals[p], okey);
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
    const row = (try catalog.okeyToRow(txn, cat, okey)).?;
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
    // Step 3: apply path -- free old blobs and allocate new ones.
    var new_raw: [max_prop_count]u64 = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        new_raw[i] = switch (kinds[i]) {
            .int => values[i].int,
            .blob => blk: {
                try blob.free(txn, cur_raw[i]);
                break :blk try blob.put(txn, values[i].bytes);
            },
            .list, .set, .dict, .link_set => unreachable, // collection update not yet implemented
            .link => if (values[i].link) |k| k + 1 else 0,
        };
    }
    // Step 4: delegate to the core update; it will re-check the version (match).
    return try update(txn, cat, pk, new_raw[0..pc], expected_version);
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
    // Capture kinds before any mutation.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    // Step 1: read the current row.
    var cur_raw: [max_prop_count]u64 = undefined;
    const current_version = (try getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
    // Step 2: version check BEFORE freeing any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: apply path -- free all blob props.
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        if (kinds[i] == .blob) try blob.free(txn, cur_raw[i]);
    }
    // Step 4: delegate to the graph-safe delete (nullifies inbound links).
    return try deleteAndNullify(txn, cat, pk, expected_version);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const create = catalog.create;
const createTyped = catalog.createTyped;
const propCount = catalog.propCount;
const liveCount = catalog.liveCount;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "insert appends a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_append.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    const r1 = try insert(&w, cat, &.{ 100, 7, 1 });
    cat = r1.cat;
    const r2 = try insert(&w, cat, &.{ 200, 8, 0 });
    cat = r2.cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    w.deinit();
}

test "insert rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_dup.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    try testing.expectError(error.DuplicateKey, insert(&w, cat, &.{ 100, 9, 1 }));
    w.deinit();
}

test "getByPk reads property values and the row version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;

    var out: [3]u64 = undefined;
    const ver = try getByPk(&w, cat, 200, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(u64, 0), out[2]);
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 999, &out));
    w.deinit();
}

test "update applies on a matching version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_apply.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var cat: Ref = undefined;
    var fetched_version: u64 = undefined;
    {
        var w = try db.beginWrite();
        cat = try create(&w, 3);
        cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        fetched_version = (try getByPk(&r, r.root(), 100, &out)).?;
        r.end();
    }
    {
        var w = try db.beginWrite();
        const res = try update(&w, w.new_root, 100, &.{ 100, 77, 1 }, fetched_version);
        try testing.expect(res == .ok);
        cat = res.ok.cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        _ = try getByPk(&r, r.root(), 100, &out);
        try testing.expectEqual(@as(u64, 77), out[1]);
        r.end();
    }
}

test "update conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_conflict.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var cat: Ref = undefined;
    var fetched_version: u64 = undefined;
    {
        var w = try db.beginWrite();
        cat = try create(&w, 3);
        cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        fetched_version = (try getByPk(&r, r.root(), 100, &out)).?;
        r.end();
    }
    {
        var w = try db.beginWrite();
        const res = try update(&w, w.new_root, 100, &.{ 100, 77, 1 }, fetched_version);
        try testing.expect(res == .ok);
        cat = res.ok.cat;
        const res2 = try update(&w, cat, 100, &.{ 100, 88, 1 }, fetched_version); // stale now
        try testing.expect(res2 == .conflict);
        w.deinit();
    }
}

test "delete conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_conflict.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    const stale = try delete(&w, cat, 100, v100 + 1);
    try testing.expect(stale == .conflict);
    w.deinit();
}

test "delete tombstones a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_tombstone.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    const ok = try delete(&w, cat, 100, v100);
    try testing.expect(ok == .ok);
    cat = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, cat));
    w.deinit();
}

test "a deleted primary key can be reinserted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_reinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    cat = (try delete(&w, cat, 100, v100)).ok;
    // pk 100 can be reinserted after deletion
    cat = (try insert(&w, cat, &.{ 100, 70, 1 })).cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    w.deinit();
}

test "objects persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj6.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2); // pk + one value
        var i: u64 = 0;
        while (i < 1000) : (i += 1) cat = (try insert(&w, cat, &.{ i, i * 2 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 1000), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        _ = (try getByPk(&r, r.root(), 777, &out)).?;
        try testing.expectEqual(@as(u64, 777), out[0]);
        try testing.expectEqual(@as(u64, 1554), out[1]);
        try testing.expectEqual(@as(?u64, null), try getByPk(&r, r.root(), 5000, &out));
        r.end();
    }
}

test "100k objects with updates and deletes match a reference map after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj7.airdb");
    defer testing.allocator.free(path);
    var ref = std.AutoHashMap(u64, u64).init(testing.allocator); // pk -> prop1 value, live only
    defer ref.deinit();
    const N: u64 = 100_000;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2);
        var out: [2]u64 = undefined;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            const pk = (i *% 2654435761) % 5_000_011;
            if ((try getByPk(&w, cat, pk, &out)) != null) continue; // skip hash collision (dup pk)
            cat = (try insert(&w, cat, &.{ pk, i })).cat;
            try ref.put(pk, i);
        }
        // Snapshot the live keys, then update every 5th and delete every 7th.
        var keys = std.ArrayList(u64).empty;
        defer keys.deinit(testing.allocator);
        var kit = ref.keyIterator();
        while (kit.next()) |k| try keys.append(testing.allocator, k.*);
        for (keys.items, 0..) |pk, idx| {
            const ver = (try getByPk(&w, cat, pk, &out)).?;
            if (idx % 5 == 0) {
                const res = try update(&w, cat, pk, &.{ pk, out[1] +% 1 }, ver);
                cat = res.ok.cat;
                try ref.put(pk, out[1] +% 1);
            } else if (idx % 7 == 0) {
                const res = try delete(&w, cat, pk, ver);
                cat = res.ok;
                _ = ref.remove(pk);
            }
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, ref.count()), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        var it = ref.iterator();
        while (it.next()) |e| {
            const ver = try getByPk(&r, r.root(), e.key_ptr.*, &out);
            try testing.expect(ver != null);
            try testing.expectEqual(e.value_ptr.*, out[1]);
        }
        r.end();
    }
}

test "typed insert and get round-trip a string property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob, .int });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 30 } })).cat;
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "Linus" }, .{ .int = 54 } })).cat;
    var out: [3]Value = undefined;
    const ver = try getTyped(&w, cat, 2, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 2), out[0].int);
    try testing.expectEqualStrings("Linus", out[1].bytes);
    try testing.expectEqual(@as(u64, 54), out[2].int);
    w.deinit();
}

test "typed update on a stale version does not free the old blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_stale.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    // stale-version update must NOT free the old blob (conflict path)
    const conflict = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "X" } }, ver + 1);
    try testing.expect(conflict == .conflict);
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqualStrings("short", out[1].bytes);
    w.deinit();
}

test "typed update replaces a string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_replace.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    const ures = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "a much longer value" } }, ver);
    cat = ures.ok.cat;
    _ = try getTyped(&w, cat, 1, &out);
    try testing.expectEqualStrings("a much longer value", out[1].bytes);
    w.deinit();
}

test "typed delete removes the row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_delete.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const v2 = (try getTyped(&w, cat, 1, &out)).?;
    const dres = try deleteTyped(&w, cat, 1, v2);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getTyped(&w, cat, 1, &out));
    w.deinit();
}

test "strings persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str3.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try createTyped(&w, &.{ .int, .blob });
        var i: u64 = 0;
        var buf: [32]u8 = undefined;
        while (i < 500) : (i += 1) {
            const s = try std.fmt.bufPrint(&buf, "name-{d}", .{i});
            cat = (try insertTyped(&w, cat, &.{ .{ .int = i }, .{ .bytes = s } })).cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        var out: [2]Value = undefined;
        _ = (try getTyped(&r, r.root(), 321, &out)).?;
        try testing.expectEqualStrings("name-321", out[1].bytes);
        r.end();
    }
}

test "a large blob property decodes to a ref and materializes; small stays inline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bigblob.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });

    // A blob well past the inline cap (section_size is 16 MiB) forces chunking.
    const n: usize = 20 * 1024 * 1024;
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = big } })).cat;
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "small" } })).cat;

    // The large blob decodes to a ref, not an inline slice.
    var out: [2]Value = undefined;
    try testing.expect((try getTyped(&w, cat, 1, &out)) != null);
    try testing.expect(out[1] == .blob_ref);

    // Materialize it and verify length + sampled offsets + first/last KB.
    const got = try blob.getAlloc(&w, out[1].blob_ref, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(n, got.len);
    try testing.expectEqualSlices(u8, big[0..1024], got[0..1024]);
    try testing.expectEqualSlices(u8, big[n - 1024 ..], got[n - 1024 ..]);
    try testing.expectEqual(big[n / 2], got[n / 2]);
    try testing.expectEqual(big[12_345_678], got[12_345_678]);

    // A small blob in the same property still decodes to a zero-copy slice.
    try testing.expect((try getTyped(&w, cat, 2, &out)) != null);
    try testing.expect(out[1] == .bytes);
    try testing.expectEqualStrings("small", out[1].bytes);
    w.deinit();
}

test "getByObjectKey reads a row by its stable object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const r0 = try insert(&w, cat, &.{ 100, 7 });
    cat = r0.cat;
    const r1 = try insert(&w, cat, &.{ 200, 8 });
    cat = r1.cat;
    var out: [2]u64 = undefined;
    const v1 = try getByObjectKey(&w, cat, r1.row, &out);
    try testing.expect(v1 != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, 999, &out));
    const vk = (try getByObjectKey(&w, cat, r0.row, &out)).?;
    const dres = try delete(&w, cat, 100, vk);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, r0.row, &out));
    w.deinit();
}

test "getByObjectKey resolves through the key-to-row index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey_index.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const r0 = try insert(&w, cat, &.{ 100, 7 });
    cat = r0.cat;
    const r1 = try insert(&w, cat, &.{ 200, 8 });
    cat = r1.cat;
    var out: [2]u64 = undefined;
    try testing.expect((try getByObjectKey(&w, cat, r0.row, &out)) != null);
    try testing.expectEqual(@as(u64, 100), out[0]);
    try testing.expectEqual(@as(u64, 7), out[1]);
    try testing.expect((try getByObjectKey(&w, cat, r1.row, &out)) != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    // An object key with no mapping resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, 999, &out));
    w.deinit();
}

// Collect, in ascending order, the object keys held in the value index's inner
// set for (cat, prop, value). Empty/absent yields an empty list.
fn collectIndexOkeys(
    txn: anytype,
    cat: Ref,
    prop: usize,
    value: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const v = try loadCatalog(txn, cat);
    const vi = v.valueIndexRef(prop);
    const inner = (try Index.get(txn, vi, value)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, inner, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

fn expectIndexOkeys(
    txn: anytype,
    cat: Ref,
    prop: usize,
    value: u64,
    expected: []const u64,
) !void {
    var got = std.ArrayList(u64).empty;
    defer got.deinit(testing.allocator);
    try collectIndexOkeys(txn, cat, prop, value, &got, testing.allocator);
    try testing.expectEqualSlices(u64, expected, got.items);
}

test "value index tracks inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_insert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    const o3 = try insert(&w, cat, &.{ 4, 30 });
    cat = o3.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o2.row });
    try expectIndexOkeys(&w, cat, 1, 20, &.{o1.row});
    try expectIndexOkeys(&w, cat, 1, 30, &.{o3.row});
    w.deinit();
}

test "value index tracks updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_update.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    // Move o1's indexed prop from 20 to 10.
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 2, &out)).?;
    const res = try update(&w, cat, 2, &.{ 2, 10 }, ver);
    try testing.expect(res == .ok);
    cat = res.ok.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o1.row, o2.row });
    // The 20 entry is now empty.
    try expectIndexOkeys(&w, cat, 1, 20, &.{});
    w.deinit();
}

test "value index tracks deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_delete.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o2.row });
    // Delete o0 (value 10); only o2 should remain under 10.
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try delete(&w, cat, 1, ver)).ok;
    try expectIndexOkeys(&w, cat, 1, 10, &.{o2.row});
    try expectIndexOkeys(&w, cat, 1, 20, &.{o1.row});
    w.deinit();
}

test "non-indexed prop has no index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_none.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const r0 = try insert(&w, cat, &.{ 1, 100 });
    cat = r0.cat;
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try update(&w, cat, 1, &.{ 1, 200 }, ver)).ok.cat;
    const ver2 = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try delete(&w, cat, 1, ver2)).ok;
    const v = try loadCatalog(&w, cat);
    var i: usize = 0;
    while (i < v.prop_count) : (i += 1) try testing.expectEqual(@as(Ref, 0), v.valueIndexRef(i));
    w.deinit();
}

test "reinserting a primary key after delete yields a new object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey_reinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const first = try insert(&w, cat, &.{ 100, 7 });
    cat = first.cat;
    const okey_a = first.row;
    var out: [2]u64 = undefined;
    const v = (try getByPk(&w, cat, 100, &out)).?;
    cat = (try delete(&w, cat, 100, v)).ok;
    const second = try insert(&w, cat, &.{ 100, 70 });
    cat = second.cat;
    const okey_b = second.row;
    try testing.expect(okey_a != okey_b);
    // The old object key is tombstoned and resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, okey_a, &out));
    // The new object key returns the new row.
    try testing.expect((try getByObjectKey(&w, cat, okey_b, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    // Lookup by pk returns the new values.
    try testing.expect((try getByPk(&w, cat, 100, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    w.deinit();
}
