const std = @import("std");
const verification = @import("../verification.zig");
const migrations = @import("migrations.zig");
const catalog = @import("catalog.zig");
const objects = @import("../records/objects.zig");
const blob = @import("../records/blob.zig");
const PropKind = catalog.PropKind;
const PropCount = catalog.PropCount;
const addProperty = migrations.addProperty;
const removeProperty = migrations.removeProperty;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const create = catalog.create;

const propCount = catalog.propCount;

const insert = @import("../records/rows.zig").insert;

const getByPrimaryKey = @import("../records/rows.zig").getByPrimaryKey;

const getLink = @import("../records/links.zig").getLink;

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
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    // start with primaryKey + one value
    var catalogRef = try create(&w, 2);
    catalogRef = (try insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = (try insert(&w, catalogRef, &.{ 2, 20 })).catalogRef;
    // add a third int property defaulting to 7
    catalogRef = try addProperty(&w, catalogRef, .{ .kind = .int }, 7);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, catalogRef));
    var out: [3]u64 = undefined;
    _ = (try getByPrimaryKey(&w, catalogRef, 1, &out)).?;
    try testing.expectEqual(@as(u64, 10), out[1]);
    try testing.expectEqual(@as(u64, 7), out[2]); // backfilled
    w.deinit();
}

test "addProperty: new inserts supply the added property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_newinsert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try create(&w, 2);
    catalogRef = (try insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = (try insert(&w, catalogRef, &.{ 2, 20 })).catalogRef;
    catalogRef = try addProperty(&w, catalogRef, .{ .kind = .int }, 7);
    // new inserts provide all three
    catalogRef = (try insert(&w, catalogRef, &.{ 3, 30, 99 })).catalogRef;
    var out: [3]u64 = undefined;
    _ = (try getByPrimaryKey(&w, catalogRef, 3, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[2]);
    w.deinit();
}

test "removeProperty drops a property and shifts the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try create(&w, 2);
    catalogRef = (try insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = try addProperty(&w, catalogRef, .{ .kind = .int }, 7);
    catalogRef = (try insert(&w, catalogRef, &.{ 3, 30, 99 })).catalogRef;
    // remove the middle property (index 1); now primaryKey + the added prop
    catalogRef = try removeProperty(&w, catalogRef, 1);
    try testing.expectEqual(@as(PropCount, 2), try propCount(&w, catalogRef));
    var out2: [2]u64 = undefined;
    _ = (try getByPrimaryKey(&w, catalogRef, 3, &out2)).?;
    try testing.expectEqual(@as(u64, 3), out2[0]); // primaryKey preserved
    try testing.expectEqual(@as(u64, 99), out2[1]); // the formerly-third prop shifted to index 1
    w.deinit();
}

test "addProperty(indexed) backfills the value index for existing rows" {
    // Regression: the fresh value index was left empty, so indexed queries
    // silently missed every pre-migration row and the audit flagged the file.
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_vidx.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var w = try database.beginWrite();
        var catalogRef = try create(&w, 2);
        catalogRef = (try insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;
        catalogRef = (try insert(&w, catalogRef, &.{ 2, 20 })).catalogRef;
        catalogRef = try addProperty(&w, catalogRef, .{ .kind = .int, .indexed = true }, 7);
        // A post-migration insert supplies its own value.
        catalogRef = (try insert(&w, catalogRef, &.{ 3, 30, 9 })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&database);
    var r = try database.beginRead();
    defer r.end();
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&r, r.root(), &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len); // both pre-migration rows
    hits.clearRetainingCapacity();
    try query.where(&r, r.root(), &.{.{ .prop = 2, .op = .eq, .value = 9 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "addProperty(link_set) leaves pre-migration rows deletable" {
    // Regression: collection kinds were backfilled with a raw 0 root, which
    // broke every collection accessor on migrated rows and made them
    // undeletable through the graph-safe delete (its outbound cleanup walks
    // link_set roots and hit error.BadRef).
    const typedir = @import("typeDirectory.zig");
    const typeRouting = @import("typeRouting.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_collroot.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{.{ .kind = .int }}}, &.{false});
        dir = (try typeRouting.insert(&w, dir, 0, &.{.{ .int = 1 }})).dir;
        // Migrate: add a link_set property targeting the same type.
        const catalogRef = try typedir.catalogRef(&w, dir, 0);
        const newCatalog = try addProperty(&w, catalogRef, .{ .kind = .link_set, .link_target = 0 }, 0);
        dir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&database); // the audit must not trip over the backfilled roots
    {
        var w = try database.beginWrite();
        var out: [2]catalog.Value = undefined;
        const ver = (try typeRouting.get(&w, w.new_root, 0, 1, &out)).?;
        const res = try typeRouting.deleteNullifyX(&w, w.new_root, 0, 1, ver);
        try testing.expect(res == .ok); // previously error.BadRef
        w.setRoot(res.ok);
        _ = try w.commit();
    }
}

test "addProperty rejects an indexed collection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_idxcoll.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    const catalogRef = try create(&w, 1);
    try testing.expectError(error.Unsupported, addProperty(&w, catalogRef, .{ .kind = .list, .indexed = true }, 0));
}

test "addProperty link type gets a backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try create(&w, 1); // just a primaryKey
    catalogRef = (try insert(&w, catalogRef, &.{1})).catalogRef;
    catalogRef = try addProperty(&w, catalogRef, .{ .kind = .link }, 0); // 0 == null link
    const v = try catalog.loadCatalog(&w, catalogRef);
    try testing.expectEqual(PropKind.link, v.kind(1));
    try testing.expect(v.backlinkRef(1) != 0);
    // a row created before the migration reads as a null link
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 1, 1));
    w.deinit();
}

test "addProperty copies a blob default per row instead of sharing one node" {
    // Regression: the backfill wrote the caller's single blob ref into every
    // existing row. The first row's delete freed the node underneath all the
    // others, and a second delete freed it again -- a duplicate extent in the
    // free list, handing the same bytes to two future allocations.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "blobdefault.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var w = try database.beginWrite();
        var catalogRef = try catalog.createTyped(&w, &.{ .int, .int });
        catalogRef = (try insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;
        catalogRef = (try insert(&w, catalogRef, &.{ 2, 20 })).catalogRef;
        const dflt = try blob.put(&w, "default-bytes");
        catalogRef = try addProperty(&w, catalogRef, .{ .kind = .blob }, dflt);
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    // Every row reads the default bytes, but from its OWN node.
    var raw1: [3]u64 = undefined;
    var raw2: [3]u64 = undefined;
    const v1 = (try getByPrimaryKey(&w, w.new_root, 1, &raw1)).?;
    const v2 = (try getByPrimaryKey(&w, w.new_root, 2, &raw2)).?;
    try testing.expectEqualStrings("default-bytes", try blob.get(&w, raw1[2]));
    try testing.expectEqualStrings("default-bytes", try blob.get(&w, raw2[2]));
    try testing.expect(raw1[2] != raw2[2]);
    // Deleting both rows must not free any extent twice.
    var catalogRef = w.new_root;
    switch (try objects.deleteTyped(&w, catalogRef, 1, v1)) {
        .ok => |c| catalogRef = c,
        else => return error.TestUnexpectedResult,
    }
    switch (try objects.deleteTyped(&w, catalogRef, 2, v2)) {
        .ok => |c| catalogRef = c,
        else => return error.TestUnexpectedResult,
    }
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (w.transactionReuse.extents.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (w.in_flight_frees.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing);
    }
}
