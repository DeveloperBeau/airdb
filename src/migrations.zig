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
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const pc = s.prop_count;
    std.debug.assert(pc + 1 <= max_prop_count);
    // Build the new column, backfilled with the default for every existing row.
    var new_col = try Column.create(txn);
    var i: u64 = 0;
    while (i < s.next_row) : (i += 1) new_col = try Column.append(txn, new_col, default_value);
    s.props[pc] = .{
        .col = new_col,
        .kind = def.kind,
        .elem = def.elem,
        .backlink = if (def.kind == .link or def.kind == .link_set) try Index.create(txn) else 0,
        .target = def.link_target,
        .rule = def.del_rule,
        .value_index = if (def.indexed) try Index.create(txn) else 0,
        .indexed = def.indexed,
    };
    s.prop_count = pc + 1;
    return s.write(txn);
}

// Remove property `prop` (must be >= 1; the primary key at 0 cannot be removed).
// The dropped column is left for compaction to reclaim. Returns the new catalog.
pub fn removeProperty(txn: *WriteTxn, cat: Ref, prop: usize) !Ref {
    std.debug.assert(prop >= 1);
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    std.debug.assert(prop < s.prop_count);
    var j: usize = prop;
    while (j + 1 < s.prop_count) : (j += 1) s.props[j] = s.props[j + 1];
    s.prop_count -= 1;
    return s.write(txn);
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
