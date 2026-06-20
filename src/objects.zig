const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const blob = @import("blob.zig");

pub const PropCount = u16;
pub const PropKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3 };
pub const ElemKind = enum(u8) { int = 0, blob = 1 };
pub const PropDef = struct { kind: PropKind, elem: ElemKind = .int };
pub const Value = union(enum) {
    int: u64,
    bytes: []const u8,
    list_int: []const u64,
    list_blob: []const []const u8,
    set_int: []const u64,
    coll_root: Ref, // read side: getTyped returns this for list/set properties
};

// Catalog node layout:
// [prop_count u16][next_row u64][pk_index_ref u64][version_col_ref u64][live_col_ref u64]
// [prop_count * (prop_col_ref u64)][prop_count * (kind u8)][prop_count * (elem u8)]
const off_prop_count: usize = 0;
const off_next_row: usize = 2;
const off_pk_index_ref: usize = 10;
const off_version_col_ref: usize = 18;
const off_live_col_ref: usize = 26;
const off_prop_cols: usize = 34;

const max_prop_count: usize = 256;

fn catalogSize(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8 + @as(usize, pc) * 2;
}

fn kindsOffset(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8;
}

fn elemsOffset(pc: PropCount) usize {
    return kindsOffset(pc) + pc;
}

// Allocate and encode a fresh catalog node; return its ref.
fn writeCatalog(
    txn: *WriteTxn,
    prop_count: PropCount,
    next_row: u64,
    pk_index_ref: Ref,
    version_col_ref: Ref,
    live_col_ref: Ref,
    prop_col_refs: []const Ref,
    kinds: []const PropKind,
    elems: []const ElemKind,
) !Ref {
    const a = try txn.alloc(catalogSize(prop_count));
    std.mem.writeInt(u16, a.bytes[off_prop_count..][0..2], prop_count, .little);
    std.mem.writeInt(u64, a.bytes[off_next_row..][0..8], next_row, .little);
    std.mem.writeInt(u64, a.bytes[off_pk_index_ref..][0..8], pk_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_version_col_ref..][0..8], version_col_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_live_col_ref..][0..8], live_col_ref, .little);
    for (prop_col_refs, 0..) |ref, i| {
        std.mem.writeInt(u64, a.bytes[off_prop_cols + i * 8 ..][0..8], ref, .little);
    }
    const ko = kindsOffset(prop_count);
    for (kinds, 0..) |k, i| a.bytes[ko + i] = @intFromEnum(k);
    const eo = elemsOffset(prop_count);
    for (elems, 0..) |e, i| a.bytes[eo + i] = @intFromEnum(e);
    return a.ref;
}

// createDefs allocates columns, a pk index, version/live columns, and a catalog
// node from explicit per-property definitions. defs[0].kind must be .int (the pk).
pub fn createDefs(txn: *WriteTxn, defs: []const PropDef) !Ref {
    std.debug.assert(defs.len >= 1 and defs[0].kind == .int);
    const prop_count: PropCount = @intCast(defs.len);
    std.debug.assert(prop_count <= max_prop_count);
    var prop_col_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        prop_col_refs[i] = try Column.create(txn);
        kinds[i] = defs[i].kind;
        elems[i] = defs[i].elem;
    }
    const version_col_ref = try Column.create(txn);
    const live_col_ref = try Column.create(txn);
    const pk_index_ref = try Index.create(txn);
    return writeCatalog(
        txn,
        prop_count,
        0,
        pk_index_ref,
        version_col_ref,
        live_col_ref,
        prop_col_refs[0..prop_count],
        kinds[0..prop_count],
        elems[0..prop_count],
    );
}

// createTyped keeps its scalar-only signature; every property gets elem = int.
pub fn createTyped(txn: *WriteTxn, kinds: []const PropKind) !Ref {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const pc: PropCount = @intCast(kinds.len);
    std.debug.assert(pc <= max_prop_count);
    var defs: [max_prop_count]PropDef = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) defs[i] = .{ .kind = kinds[i], .elem = .int };
    return createDefs(txn, defs[0..pc]);
}

// Create prop_count property columns, a version column, a live column, and an
// empty pk index. All property kinds default to .int.
pub fn create(txn: *WriteTxn, prop_count: PropCount) !Ref {
    std.debug.assert(prop_count <= max_prop_count);
    var all_int: [max_prop_count]PropKind = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) all_int[i] = .int;
    return createTyped(txn, all_int[0..prop_count]);
}

pub const CatalogView = struct {
    prop_count: PropCount,
    next_row: u64,
    pk_index_ref: Ref,
    version_col_ref: Ref,
    live_col_ref: Ref,
    bytes: []const u8,

    pub fn propColRef(self: CatalogView, i: usize) Ref {
        return std.mem.readInt(u64, self.bytes[off_prop_cols + i * 8 ..][0..8], .little);
    }

    pub fn kind(self: CatalogView, i: usize) PropKind {
        const kinds_offset = off_prop_cols + @as(usize, self.prop_count) * 8;
        return @enumFromInt(self.bytes[kinds_offset + i]);
    }

    pub fn elemKind(self: CatalogView, i: usize) ElemKind {
        const eo = off_prop_cols + @as(usize, self.prop_count) * 8 + self.prop_count;
        return @enumFromInt(self.bytes[eo + i]);
    }
};

// Deref the catalog at cat, read prop_count, then deref the full node and parse
// all fixed fields. Returns a CatalogView whose bytes slice is valid for the
// lifetime of the transaction.
pub fn loadCatalog(txn: anytype, cat: Ref) !CatalogView {
    const pc_bytes = try txn.deref(cat, 2);
    const prop_count = std.mem.readInt(u16, pc_bytes[0..2], .little);
    std.debug.assert(prop_count <= max_prop_count);
    const bytes = try txn.deref(cat, catalogSize(prop_count));
    return CatalogView{
        .prop_count = prop_count,
        .next_row = std.mem.readInt(u64, bytes[off_next_row..][0..8], .little),
        .pk_index_ref = std.mem.readInt(u64, bytes[off_pk_index_ref..][0..8], .little),
        .version_col_ref = std.mem.readInt(u64, bytes[off_version_col_ref..][0..8], .little),
        .live_col_ref = std.mem.readInt(u64, bytes[off_live_col_ref..][0..8], .little),
        .bytes = bytes,
    };
}

pub fn propCount(txn: anytype, cat: Ref) !PropCount {
    const view = try loadCatalog(txn, cat);
    return view.prop_count;
}

// liveCount returns the number of live rows tracked by the pk index.
pub fn liveCount(txn: anytype, cat: Ref) !u64 {
    const view = try loadCatalog(txn, cat);
    return Index.count(txn, view.pk_index_ref);
}

// insert appends a new row to all columns and updates the pk index.
// values.len must equal the prop_count stored in the catalog.
// Returns error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(txn: *WriteTxn, cat: Ref, values: []const u64) !struct { cat: Ref, row: u64 } {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(values.len == v.prop_count);

    // Capture all refs from the view into locals before any mutation so the
    // bytes slice backing CatalogView cannot be invalidated by file growth.
    const old_pk_index_ref = v.pk_index_ref;
    const old_version_col_ref = v.version_col_ref;
    const old_live_col_ref = v.live_col_ref;
    var old_prop_refs: [max_prop_count]Ref = undefined;
    var old_kinds: [max_prop_count]PropKind = undefined;
    var old_elems: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            old_prop_refs[j] = v.propColRef(j);
            old_kinds[j] = v.kind(j);
            old_elems[j] = v.elemKind(j);
        }
    }
    const prop_count = v.prop_count;
    const row = v.next_row;

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
    const new_index = try Index.insert(txn, old_pk_index_ref, pk, row);

    const new_cat = try writeCatalog(
        txn,
        prop_count,
        row + 1,
        new_index,
        new_version_col,
        new_live_col,
        new_prop_refs[0..prop_count],
        old_kinds[0..prop_count],
        old_elems[0..prop_count],
    );
    return .{ .cat = new_cat, .row = row };
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
    const row = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
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
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
        }
    }
    var ver_ref = v.version_col_ref;

    var i: usize = 0;
    while (i < pc) : (i += 1) prop_refs[i] = try Column.set(txn, prop_refs[i], row, values[i]);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc]);
    return .{ .ok = .{ .cat = new_cat, .version = txn.new_version } };
}

pub fn delete(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const row = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const cur = try Column.get(txn, v.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };

    // Capture refs into locals before mutating.
    const pc = v.prop_count;
    const next_row = v.next_row;
    var prop_refs: [256]Ref = undefined;
    var kinds: [256]PropKind = undefined;
    var elems_buf: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
        }
    }
    var live_ref = v.live_col_ref;
    var ver_ref = v.version_col_ref;
    var idx_ref = v.pk_index_ref;

    live_ref = try Column.set(txn, live_ref, row, 0); // tombstone
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version); // bump version stamp
    idx_ref = try Index.remove(txn, idx_ref, pk); // remove pk from the index

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc]);
    return .{ .ok = new_cat };
}

pub fn getByPk(txn: anytype, cat: Ref, pk: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    // Capture refs before any potential file growth from other ops.
    const pk_index_ref = v.pk_index_ref;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    const row = (try Index.get(txn, pk_index_ref, pk)) orelse return null;
    if ((try Column.get(txn, live_col_ref, row)) == 0) return null;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        out[i] = try Column.get(txn, prop_refs[i], row);
    }
    return try Column.get(txn, version_col_ref, row);
}

// Read a row by its stable object key (okey == the row assigned at insert).
// Returns the row version, or null if the okey is out of range or tombstoned.
pub fn getByObjectKey(txn: anytype, cat: Ref, okey: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    if (okey >= v.next_row) return null;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    if ((try Column.get(txn, live_col_ref, okey)) == 0) return null;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) out[i] = try Column.get(txn, prop_refs[i], okey);
    return try Column.get(txn, version_col_ref, okey);
}

fn buildListInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Column.create(txn);
    for (items) |x| root = try Column.append(txn, root, x);
    return root;
}

fn buildListBlob(txn: *WriteTxn, items: []const []const u8) !Ref {
    var root = try Column.create(txn);
    for (items) |s| {
        const bref = try blob.put(txn, s);
        root = try Column.append(txn, root, bref);
    }
    return root;
}

fn buildSetInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Index.create(txn);
    for (items) |k| root = try Index.insert(txn, root, k, 1);
    return root;
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
                .int => try buildListInt(txn, values[i].list_int),
                .blob => try buildListBlob(txn, values[i].list_blob),
            },
            .set => switch (elems[i]) {
                .int => try buildSetInt(txn, values[i].set_int),
                .blob => unreachable, // set of blob out of scope this phase
            },
        };
    }
    const r = try insert(txn, cat, raw[0..pc]);
    return .{ .cat = r.cat, .row = r.row };
}

// getTyped reads a row by primary key and decodes each property into a Value.
// .blob properties are zero-copy slices into the mapped storage.
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
            .blob => .{ .bytes = try blob.get(txn, raw[i]) },
            .list, .set => .{ .coll_root = raw[i] },
        };
    }
    return ver;
}

// Resolve (cat, pk, prop) to the property column ref and the row;
// null if pk absent or row tombstoned.
fn resolveProp(txn: anytype, cat: Ref, pk: u64, prop: usize) !?struct { row: u64, prop_col: Ref } {
    const v = try loadCatalog(txn, cat);
    const row = (try Index.get(txn, v.pk_index_ref, pk)) orelse return null;
    if ((try Column.get(txn, v.live_col_ref, row)) == 0) return null;
    return .{ .row = row, .prop_col = v.propColRef(prop) };
}

pub fn listLen(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try resolveProp(txn, cat, pk, prop)) orelse return null;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.len(txn, list_root);
}

pub fn listGetInt(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) !u64 {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.get(txn, list_root, index);
}

pub fn listGetBlob(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) ![]const u8 {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try Column.get(txn, list_root, index);
    return try blob.get(txn, bref);
}

// Write new_root into property `prop` at `row`, bump that row's version stamp,
// return the new catalog ref. Reloads the catalog fresh and captures all refs.
fn replaceCollRoot(txn: *WriteTxn, cat: Ref, row: u64, prop: usize, new_root: Ref) !Ref {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
        }
    }
    var ver_ref = v.version_col_ref;
    prop_refs[prop] = try Column.set(txn, prop_refs[prop], row, new_root);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);
    return writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems[0..pc]);
}

pub fn listAppendInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, value: u64) !Ref {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.append(txn, old_root, value);
    return replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listSetInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, index: u64, value: u64) !Ref {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.set(txn, old_root, index, value);
    return replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listAppendBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, bytes: []const u8) !Ref {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try blob.put(txn, bytes);
    const new_root = try Column.append(txn, old_root, bref);
    return replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCountInt(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try Index.count(txn, set_root);
}

pub fn setContainsInt(txn: anytype, cat: Ref, pk: u64, prop: usize, key: u64) !bool {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try Index.get(txn, set_root, key)) != null;
}

pub fn setAddInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) != null) return cat; // already a member, no version bump
    const new_root = try Index.insert(txn, old_root, key, 1);
    return replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setRemoveInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) == null) return cat; // not a member, no version bump
    const new_root = try Index.remove(txn, old_root, key);
    return replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCollectInt(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
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
            .list, .set => unreachable, // collection update not yet implemented
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
    // Step 4: delegate to the core delete.
    return try delete(txn, cat, pk, expected_version);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "create allocates an empty type and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try create(&w, 3);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, cat));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, cat));
    w.deinit();
}

test "insert appends rows and rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2.airdb");
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

test "update applies on a matching version and conflicts on a stale one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4.airdb");
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

test "delete tombstones a row and conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5.airdb");
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

    const ok = try delete(&w, cat, 100, v100);
    try testing.expect(ok == .ok);
    cat = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, cat));
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

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createTyped(&w, &.{ .int, .blob, .int });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.blob, v.kind(1));
    try testing.expectEqual(PropKind.int, v.kind(2));
    const cat2 = try create(&w, 2);
    const v2 = try loadCatalog(&w, cat2);
    try testing.expectEqual(PropKind.int, v2.kind(0));
    try testing.expectEqual(PropKind.int, v2.kind(1));
    w.deinit();
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

test "typed update replaces a string and frees the old blob; delete frees blobs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2.airdb");
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
    const ures = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "a much longer value" } }, ver);
    cat = ures.ok.cat;
    _ = try getTyped(&w, cat, 1, &out);
    try testing.expectEqualStrings("a much longer value", out[1].bytes);
    const v2 = (try getTyped(&w, cat, 1, &out)).?;
    const dres = try deleteTyped(&w, cat, 1, v2);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getTyped(&w, cat, 1, &out));
    w.deinit();
}

test "createDefs records kind and element kind per property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "defs.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
        .{ .kind = .list, .elem = .blob },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(@as(PropCount, 4), v.prop_count);
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.list, v.kind(1));
    try testing.expectEqual(ElemKind.int, v.elemKind(1));
    try testing.expectEqual(PropKind.set, v.kind(2));
    try testing.expectEqual(ElemKind.int, v.elemKind(2));
    try testing.expectEqual(PropKind.list, v.kind(3));
    try testing.expectEqual(ElemKind.blob, v.elemKind(3));
    const cat2 = try createTyped(&w, &.{ .int, .blob });
    const v2 = try loadCatalog(&w, cat2);
    try testing.expectEqual(PropKind.blob, v2.kind(1));
    try testing.expectEqual(ElemKind.int, v2.elemKind(1));
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

test "list of int: insert, read, append, set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 20), try listGetInt(&w, cat, 1, 1, 1));
    cat = try listAppendInt(&w, cat, 1, 1, 40);
    try testing.expectEqual(@as(?u64, 4), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 40), try listGetInt(&w, cat, 1, 1, 3));
    cat = try listSetInt(&w, cat, 1, 1, 0, 99);
    try testing.expectEqual(@as(u64, 99), try listGetInt(&w, cat, 1, 1, 0));
    var out: [2]Value = undefined;
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 1), out[0].int);
    try testing.expect(out[1].coll_root != 0);
    w.deinit();
}

test "list of blob: insert and read back element strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listblob.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .blob } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 7 }, .{ .list_blob = &.{ "alpha", "beta", "gamma" } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, cat, 7, 1));
    try testing.expectEqualStrings("beta", try listGetBlob(&w, cat, 7, 1, 1));
    cat = try listAppendBlob(&w, cat, 7, 1, "delta");
    try testing.expectEqualStrings("delta", try listGetBlob(&w, cat, 7, 1, 3));
    w.deinit();
}

test "set of int: insert, membership, add (dedup), remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 9));
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 7)));
    cat = try setAddInt(&w, cat, 1, 1, 7);
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 7));
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    cat = try setAddInt(&w, cat, 1, 1, 7); // dedup: no change
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    cat = try setRemoveInt(&w, cat, 1, 1, 9);
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 9)));
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
    var members = std.ArrayList(u64).empty;
    defer members.deinit(testing.allocator);
    try setCollectInt(&w, cat, 1, 1, &members, testing.allocator);
    try testing.expectEqual(@as(usize, 3), members.items.len);
    try testing.expectEqual(@as(u64, 5), members.items[0]);
    try testing.expectEqual(@as(u64, 7), members.items[1]);
    try testing.expectEqual(@as(u64, 12), members.items[2]);
    w.deinit();
}

test "collections persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collpersist.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .list, .elem = .blob },
        });
        cat = (try insertTyped(&w, cat, &.{
            .{ .int = 42 },
            .{ .list_int = &.{ 1, 2, 3 } },
            .{ .set_int = &.{ 100, 200, 300 } },
            .{ .list_blob = &.{ "x", "yy", "zzz" } },
        })).cat;
        cat = try listAppendInt(&w, cat, 42, 1, 4);
        cat = try setAddInt(&w, cat, 42, 2, 400);
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const cat = r.root();
        try testing.expectEqual(@as(?u64, 4), try listLen(&r, cat, 42, 1));
        try testing.expectEqual(@as(u64, 4), try listGetInt(&r, cat, 42, 1, 3));
        try testing.expectEqual(@as(?u64, 4), try setCountInt(&r, cat, 42, 2));
        try testing.expect(try setContainsInt(&r, cat, 42, 2, 400));
        try testing.expectEqualStrings("zzz", try listGetBlob(&r, cat, 42, 3, 2));
        r.end();
    }
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

test "large list and set: 50k elements each, append and membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collscale.airdb");
    defer testing.allocator.free(path);
    const N: u64 = 50_000;
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
    });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{} }, .{ .set_int = &.{} } })).cat;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        cat = try listAppendInt(&w, cat, 1, 1, i);
        cat = try setAddInt(&w, cat, 1, 2, i *% 2654435761 % 1_000_003);
    }
    try testing.expectEqual(@as(?u64, N), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 12345), try listGetInt(&w, cat, 1, 1, 12345));
    const sc = (try setCountInt(&w, cat, 1, 2)).?;
    try testing.expect(sc > 0 and sc <= N);
    try testing.expect(try setContainsInt(&w, cat, 1, 2, 0));
    w.deinit();
}
