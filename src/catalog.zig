const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");

pub const PropCount = u16;
pub const PropKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3, link = 4, link_set = 5 };
pub const ElemKind = enum(u8) { int = 0, blob = 1 };
pub const DeletionRule = enum(u8) { nullify = 0, cascade = 1, block = 2 };
pub const PropDef = struct { kind: PropKind, elem: ElemKind = .int, link_target: u16 = 0, del_rule: DeletionRule = .nullify };
pub const Value = union(enum) {
    int: u64,
    bytes: []const u8,
    list_int: []const u64,
    list_blob: []const []const u8,
    set_int: []const u64,
    coll_root: Ref, // read side: getTyped returns this for list/set/link_set properties
    link: ?u64,
    link_set: []const u64, // to-many: initial set of target okeys
};

// Catalog node layout:
// [prop_count u16][next_row u64][pk_index_ref u64][version_col_ref u64][live_col_ref u64]
// [prop_count * (prop_col_ref u64)][prop_count * (kind u8)][prop_count * (elem u8)]
// [prop_count * (backlink_ref u64)][prop_count * (link_target u16)][prop_count * (del_rule u8)]
const off_prop_count: usize = 0;
const off_next_row: usize = 2;
const off_pk_index_ref: usize = 10;
const off_version_col_ref: usize = 18;
const off_live_col_ref: usize = 26;
const off_keyrow_index_ref: usize = 34;
const off_next_key: usize = 42;
const off_prop_cols: usize = 50;

pub const max_prop_count: usize = 256;

fn catalogSize(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8 + @as(usize, pc) * 2 + @as(usize, pc) * 8 + @as(usize, pc) * 2 + @as(usize, pc);
}

fn kindsOffset(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8;
}

fn elemsOffset(pc: PropCount) usize {
    return kindsOffset(pc) + pc;
}

fn backlinksOffset(pc: PropCount) usize {
    return elemsOffset(pc) + pc;
}

fn targetsOffset(pc: PropCount) usize {
    return backlinksOffset(pc) + @as(usize, pc) * 8;
}

fn rulesOffset(pc: PropCount) usize {
    return targetsOffset(pc) + @as(usize, pc) * 2;
}

// Allocate and encode a fresh catalog node; return its ref.
pub fn writeCatalog(
    txn: *WriteTxn,
    prop_count: PropCount,
    next_row: u64,
    keyrow_index_ref: Ref,
    next_key: u64,
    pk_index_ref: Ref,
    version_col_ref: Ref,
    live_col_ref: Ref,
    prop_col_refs: []const Ref,
    kinds: []const PropKind,
    elems: []const ElemKind,
    backlinks: []const Ref,
    targets: []const u16,
    rules: []const DeletionRule,
) !Ref {
    const a = try txn.alloc(catalogSize(prop_count));
    std.mem.writeInt(u16, a.bytes[off_prop_count..][0..2], prop_count, .little);
    std.mem.writeInt(u64, a.bytes[off_next_row..][0..8], next_row, .little);
    std.mem.writeInt(u64, a.bytes[off_keyrow_index_ref..][0..8], keyrow_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_next_key..][0..8], next_key, .little);
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
    const blo = backlinksOffset(prop_count);
    for (backlinks, 0..) |bref, i| {
        std.mem.writeInt(u64, a.bytes[blo + i * 8 ..][0..8], bref, .little);
    }
    const to = targetsOffset(prop_count);
    for (targets, 0..) |t, i| std.mem.writeInt(u16, a.bytes[to + i * 2 ..][0..2], t, .little);
    const ro = rulesOffset(prop_count);
    for (rules, 0..) |r, i| a.bytes[ro + i] = @intFromEnum(r);
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
    var backlinks: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]DeletionRule = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        prop_col_refs[i] = try Column.create(txn);
        kinds[i] = defs[i].kind;
        elems[i] = defs[i].elem;
        backlinks[i] = if (defs[i].kind == .link or defs[i].kind == .link_set) try Index.create(txn) else 0;
        targets[i] = defs[i].link_target;
        rules[i] = defs[i].del_rule;
    }
    const version_col_ref = try Column.create(txn);
    const live_col_ref = try Column.create(txn);
    const pk_index_ref = try Index.create(txn);
    const keyrow = try Index.create(txn);
    return writeCatalog(
        txn,
        prop_count,
        0,
        keyrow,
        0,
        pk_index_ref,
        version_col_ref,
        live_col_ref,
        prop_col_refs[0..prop_count],
        kinds[0..prop_count],
        elems[0..prop_count],
        backlinks[0..prop_count],
        targets[0..prop_count],
        rules[0..prop_count],
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
    keyrow_index_ref: Ref,
    next_key: u64,
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

    pub fn backlinkRef(self: CatalogView, i: usize) Ref {
        const blo = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2;
        return std.mem.readInt(u64, self.bytes[blo + i * 8 ..][0..8], .little);
    }

    pub fn linkTarget(self: CatalogView, i: usize) u16 {
        const to = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2 + @as(usize, self.prop_count) * 8;
        return std.mem.readInt(u16, self.bytes[to + i * 2 ..][0..2], .little);
    }

    pub fn delRule(self: CatalogView, i: usize) DeletionRule {
        const ro = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2 + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2;
        return @enumFromInt(self.bytes[ro + i]);
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
        .keyrow_index_ref = std.mem.readInt(u64, bytes[off_keyrow_index_ref..][0..8], .little),
        .next_key = std.mem.readInt(u64, bytes[off_next_key..][0..8], .little),
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

// Resolve an object key to its physical row via the key-to-row index.
// Returns null if the okey has no mapping.
pub fn okeyToRow(txn: anytype, cat: Ref, okey: u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    return Index.get(txn, v.keyrow_index_ref, okey);
}

// Resolve a primary key to its stable object key via the pk index.
// Returns null if the pk has no mapping.
pub fn pkToOkey(txn: anytype, cat: Ref, pk: u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    return Index.get(txn, v.pk_index_ref, pk);
}

// Resolve (cat, pk, prop) to the property column ref and the row;
// null if pk absent or row tombstoned. The pk index maps pk -> okey, and the
// keyrow index maps okey -> physical row.
pub fn resolveProp(txn: anytype, cat: Ref, pk: u64, prop: usize) !?struct { row: u64, prop_col: Ref } {
    const v = try loadCatalog(txn, cat);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return null;
    const row = (try Index.get(txn, v.keyrow_index_ref, okey)) orelse return null;
    if ((try Column.get(txn, v.live_col_ref, row)) == 0) return null;
    return .{ .row = row, .prop_col = v.propColRef(prop) };
}

// Write new_root into property `prop` at `row`, bump that row's version stamp,
// return the new catalog ref. Reloads the catalog fresh and captures all refs.
pub fn replaceCollRoot(txn: *WriteTxn, cat: Ref, row: u64, prop: usize, new_root: Ref) !Ref {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
        }
    }
    var ver_ref = v.version_col_ref;
    prop_refs[prop] = try Column.set(txn, prop_refs[prop], row, new_root);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);
    return writeCatalog(txn, pc, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets_buf[0..pc], rules_buf[0..pc]);
}

// Write a new backlink ref into property `p`, preserving everything else.
pub fn setBacklinkRef(txn: *WriteTxn, cat: Ref, p: usize, new_bl: Ref) !Ref {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const ver_ref = v.version_col_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
        }
    }
    bl[p] = new_bl;
    return writeCatalog(txn, pc, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets_buf[0..pc], rules_buf[0..pc]);
}

// Write a new column ref into property `p`, preserving everything else.
pub fn setPropColRef(txn: *WriteTxn, cat: Ref, p: usize, new_col: Ref) !Ref {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const ver_ref = v.version_col_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
        }
    }
    prop_refs[p] = new_col;
    return writeCatalog(txn, pc, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets_buf[0..pc], rules_buf[0..pc]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;

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

test "createDefs builds a backlink index for each link property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcat.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .link },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.link, v.kind(2));
    try testing.expect(v.backlinkRef(2) != 0);
    try testing.expectEqual(@as(Ref, 0), v.backlinkRef(0));
    try testing.expectEqual(@as(Ref, 0), v.backlinkRef(1));
    w.deinit();
}

test "createDefs records a link target type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "ltarget.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 3 },
        .{ .kind = .link_set, .link_target = 7 },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(@as(u16, 0), v.linkTarget(0));
    try testing.expectEqual(@as(u16, 3), v.linkTarget(1));
    try testing.expectEqual(@as(u16, 7), v.linkTarget(2));
    w.deinit();
}

test "createDefs creates an empty key-to-row index and zero next_key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "keyrow.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const v = try loadCatalog(&w, cat);
    try testing.expect(v.keyrow_index_ref != 0);
    try testing.expectEqual(@as(u64, 0), v.next_key);
    w.deinit();
}

test "createDefs records a per-property deletion rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "delrule.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 2, .del_rule = .cascade },
        .{ .kind = .link, .link_target = 3, .del_rule = .block },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(DeletionRule.nullify, v.delRule(0));
    try testing.expectEqual(DeletionRule.cascade, v.delRule(1));
    try testing.expectEqual(DeletionRule.block, v.delRule(2));
    // existing per-prop data still intact
    try testing.expectEqual(@as(u16, 2), v.linkTarget(1));
    w.deinit();
}
