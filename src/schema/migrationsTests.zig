const std = @import("std");
const verification = @import("../verification.zig");
const migrations = @import("migrations.zig");
const catalog = @import("catalog.zig");
const objects = @import("../records/objects.zig");
const blob = @import("../records/blob.zig");
const PropertyKind = catalog.PropertyKind;
const PropertyCount = catalog.PropertyCount;
const addProperty = migrations.addProperty;
const removeProperty = migrations.removeProperty;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const create = catalog.create;

const loadPropertyCount = catalog.loadPropertyCount;

const insert = @import("../records/rows.zig").insert;

const getByPrimaryKey = @import("../records/rows.zig").getByPrimaryKey;

const getLink = @import("../records/links.zig").getLink;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "addProperty backfills the default for existing rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_backfill.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // start with primaryKey + one value
    var catalogRef = try create(&writeTransaction, 2);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 2, 20 })).catalogRef;
    // add a third int property defaulting to 7
    catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .int }, 7);
    try testing.expectEqual(@as(PropertyCount, 3), try loadPropertyCount(&writeTransaction, catalogRef));
    var out: [3]u64 = undefined;
    _ = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    try testing.expectEqual(@as(u64, 10), out[1]);
    try testing.expectEqual(@as(u64, 7), out[2]); // backfilled
    writeTransaction.deinit();
}

test "addProperty: new inserts supply the added property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_newinsert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 2);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 2, 20 })).catalogRef;
    catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .int }, 7);
    // new inserts provide all three
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 3, 30, 99 })).catalogRef;
    var out: [3]u64 = undefined;
    _ = (try getByPrimaryKey(&writeTransaction, catalogRef, 3, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[2]);
    writeTransaction.deinit();
}

test "removeProperty drops a property and shifts the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 2);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .int }, 7);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 3, 30, 99 })).catalogRef;
    // remove the middle property (index 1); now primaryKey + the added property
    catalogRef = try removeProperty(&writeTransaction, catalogRef, 1);
    try testing.expectEqual(@as(PropertyCount, 2), try loadPropertyCount(&writeTransaction, catalogRef));
    var out2: [2]u64 = undefined;
    _ = (try getByPrimaryKey(&writeTransaction, catalogRef, 3, &out2)).?;
    try testing.expectEqual(@as(u64, 3), out2[0]); // primaryKey preserved
    try testing.expectEqual(@as(u64, 99), out2[1]); // the formerly-third property shifted to index 1
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var catalogRef = try create(&writeTransaction, 2);
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 2, 20 })).catalogRef;
        catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .int, .indexed = true }, 7);
        // A post-migration insert supplies its own value.
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 3, 30, 9 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, readTransaction.root(), &.{.{ .property = 2, .operator = .eq, .value = 7 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len); // both pre-migration rows
    hits.clearRetainingCapacity();
    try query.where(&readTransaction, readTransaction.root(), &.{.{ .property = 2, .operator = .eq, .value = 9 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "addProperty(linkSet) leaves pre-migration rows deletable" {
    // Regression: collection kinds were backfilled with a raw 0 root, which
    // broke every collection accessor on migrated rows and made them
    // undeletable through the graph-safe delete (its outbound cleanup walks
    // linkSet roots and hit error.BadRef).
    const typeDirectory = @import("typeDirectory.zig");
    const typeRouting = @import("typeRouting.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_collroot.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{.{ .kind = .int }}}, &.{false});
        dir = (try typeRouting.insert(&writeTransaction, dir, 0, &.{.{ .int = 1 }})).dir;
        // Migrate: add a linkSet property targeting the same type.
        const catalogRef = try typeDirectory.catalogRef(&writeTransaction, dir, 0);
        const newCatalog = try addProperty(&writeTransaction, catalogRef, .{ .kind = .linkSet, .linkTarget = 0 }, 0);
        dir = try typeDirectory.setCatalogRef(&writeTransaction, dir, 0, newCatalog);
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // the audit must not trip over the backfilled roots
    {
        var writeTransaction = try database.beginWrite();
        var out: [2]catalog.Value = undefined;
        const version = (try typeRouting.get(&writeTransaction, writeTransaction.newRoot, 0, 1, &out)).?;
        const res = try typeRouting.deleteNullifyCrossType(&writeTransaction, writeTransaction.newRoot, 0, 1, version);
        try testing.expect(res == .ok); // previously error.BadRef
        writeTransaction.setRoot(res.ok);
        _ = try writeTransaction.commit();
    }
}

test "addProperty rejects an indexed collection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_idxcoll.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogRef = try create(&writeTransaction, 1);
    try testing.expectError(error.Unsupported, addProperty(&writeTransaction, catalogRef, .{ .kind = .list, .indexed = true }, 0));
}

test "addProperty link type gets a backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 1); // just a primaryKey
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{1})).catalogRef;
    catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .link }, 0); // 0 == null link
    const view = try catalog.loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(PropertyKind.link, view.kind(1));
    try testing.expect(view.backlinkRef(1) != 0);
    // a row created before the migration reads as a null link
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 1, 1));
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var catalogRef = try catalog.createTyped(&writeTransaction, &.{ .int, .int });
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 2, 20 })).catalogRef;
        const dflt = try blob.put(&writeTransaction, "default-bytes");
        catalogRef = try addProperty(&writeTransaction, catalogRef, .{ .kind = .blob }, dflt);
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // Every row reads the default bytes, but from its OWN node.
    var raw1: [3]u64 = undefined;
    var raw2: [3]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, writeTransaction.newRoot, 1, &raw1)).?;
    const version2 = (try getByPrimaryKey(&writeTransaction, writeTransaction.newRoot, 2, &raw2)).?;
    try testing.expectEqualStrings("default-bytes", try blob.get(&writeTransaction, raw1[2]));
    try testing.expectEqualStrings("default-bytes", try blob.get(&writeTransaction, raw2[2]));
    try testing.expect(raw1[2] != raw2[2]);
    // Deleting both rows must not free any extent twice.
    var catalogRef = writeTransaction.newRoot;
    switch (try objects.deleteTyped(&writeTransaction, catalogRef, 1, version)) {
        .ok => |newCatalog| catalogRef = newCatalog,
        else => return error.TestUnexpectedResult,
    }
    switch (try objects.deleteTyped(&writeTransaction, catalogRef, 2, version2)) {
        .ok => |newCatalog| catalogRef = newCatalog,
        else => return error.TestUnexpectedResult,
    }
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (writeTransaction.transactionReuse.extents.items) |extent| {
        const gop = try seen.getOrPut(extent.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (writeTransaction.inFlightFrees.items) |item| {
        const gop = try seen.getOrPut(item.offset);
        try testing.expect(!gop.found_existing);
    }
}
