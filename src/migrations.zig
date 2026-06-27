const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

// ---------------------------------------------------------------------------
// Migrations (structural schema evolution)
//
// The catalog stores properties by position, not name, so renaming is a no-op
// at this layer (names live in the binding/schema layer). Add and remove
// rewrite the catalog transactionally (COW); existing snapshots are unaffected.
// ---------------------------------------------------------------------------

// Append a new property to the type. The new column is filled with
// `default_value` for every existing row (live or tombstoned). For a link or
// link_set property a fresh backlink index is created. Returns the new catalog.
pub fn addProperty(txn: *WriteTxn, cat: Ref, def: PropDef, default_value: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(pc + 1 <= max_prop_count);
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const ver_ref = v.version_col_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    var vidx: [max_prop_count]Ref = undefined;
    var idxf: [max_prop_count]bool = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
            vidx[j] = v.valueIndexRef(j);
            idxf[j] = v.indexed(j);
        }
    }
    // Build the new column, backfilled with the default for every existing row.
    var new_col = try Column.create(txn);
    var i: u64 = 0;
    while (i < next_row) : (i += 1) new_col = try Column.append(txn, new_col, default_value);
    prop_refs[pc] = new_col;
    kinds[pc] = def.kind;
    elems[pc] = def.elem;
    bl[pc] = if (def.kind == .link or def.kind == .link_set) try Index.create(txn) else 0;
    targets[pc] = def.link_target;
    rules[pc] = def.del_rule;
    idxf[pc] = def.indexed;
    vidx[pc] = if (def.indexed) try Index.create(txn) else 0;
    return catalog.writeCatalog(txn, pc + 1, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0 .. pc + 1], kinds[0 .. pc + 1], elems[0 .. pc + 1], bl[0 .. pc + 1], targets[0 .. pc + 1], rules[0 .. pc + 1], vidx[0 .. pc + 1], idxf[0 .. pc + 1]);
}

// Remove property `prop` (must be >= 1; the primary key at 0 cannot be removed).
// The dropped column is left for compaction to reclaim. Returns the new catalog.
pub fn removeProperty(txn: *WriteTxn, cat: Ref, prop: usize) !Ref {
    std.debug.assert(prop >= 1);
    const v = try catalog.loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(prop < pc);
    const next_row = v.next_row;
    const idx_ref = v.pk_index_ref;
    const ver_ref = v.version_col_ref;
    const live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    var vidx: [max_prop_count]Ref = undefined;
    var idxf: [max_prop_count]bool = undefined;
    var out: usize = 0;
    var j: usize = 0;
    while (j < pc) : (j += 1) {
        if (j == prop) continue;
        prop_refs[out] = v.propColRef(j);
        kinds[out] = v.kind(j);
        elems[out] = v.elemKind(j);
        bl[out] = v.backlinkRef(j);
        targets[out] = v.linkTarget(j);
        rules[out] = v.delRule(j);
        vidx[out] = v.valueIndexRef(j);
        idxf[out] = v.indexed(j);
        out += 1;
    }
    return catalog.writeCatalog(txn, pc - 1, next_row, v.keyrow_index_ref, v.next_key, idx_ref, ver_ref, live_ref, prop_refs[0..out], kinds[0..out], elems[0..out], bl[0..out], targets[0..out], rules[0..out], vidx[0..out], idxf[0..out]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const create = catalog.create;
const propCount = catalog.propCount;
const insert = @import("objects.zig").insert;
const getByPk = @import("objects.zig").getByPk;
const getLink = @import("links.zig").getLink;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "addProperty backfills the default for existing rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_backfill.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    // start with pk + one value
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
    // add a third int property defaulting to 7
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, cat));
    var out: [3]u64 = undefined;
    _ = (try getByPk(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 10), out[1]);
    try testing.expectEqual(@as(u64, 7), out[2]); // backfilled
    w.deinit();
}

test "addProperty: new inserts supply the added property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_newinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    // new inserts provide all three
    cat = (try insert(&w, cat, &.{ 3, 30, 99 })).cat;
    var out: [3]u64 = undefined;
    _ = (try getByPk(&w, cat, 3, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[2]);
    w.deinit();
}

test "removeProperty drops a property and shifts the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_remove.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    cat = (try insert(&w, cat, &.{ 3, 30, 99 })).cat;
    // remove the middle property (index 1); now pk + the added prop
    cat = try removeProperty(&w, cat, 1);
    try testing.expectEqual(@as(PropCount, 2), try propCount(&w, cat));
    var out2: [2]u64 = undefined;
    _ = (try getByPk(&w, cat, 3, &out2)).?;
    try testing.expectEqual(@as(u64, 3), out2[0]); // pk preserved
    try testing.expectEqual(@as(u64, 99), out2[1]); // the formerly-third prop shifted to index 1
    w.deinit();
}

test "addProperty link type gets a backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 1); // just a pk
    cat = (try insert(&w, cat, &.{1})).cat;
    cat = try addProperty(&w, cat, .{ .kind = .link }, 0); // 0 == null link
    const v = try catalog.loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.link, v.kind(1));
    try testing.expect(v.backlinkRef(1) != 0);
    // a row created before the migration reads as a null link
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 1, 1));
    w.deinit();
}
