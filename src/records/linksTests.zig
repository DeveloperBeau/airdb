const std = @import("std");
const links = @import("links.zig");
const catalog = @import("../schema/catalog.zig");
const Index = @import("../trees/index.zig");
const Value = catalog.Value;
const getLink = links.getLink;
const backlinkCount = links.backlinkCount;
const backlinkCollect = links.backlinkCollect;
const setLink = links.setLink;
const linkSetCount = links.linkSetCount;
const linkSetContains = links.linkSetContains;
const linkSetCollect = links.linkSetCollect;
const linkSetAdd = links.linkSetAdd;
const linkSetRemove = links.linkSetRemove;
const nullifyInboundInCatalog = links.nullifyInboundInCatalog;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const insertTyped = @import("objects.zig").insertTyped;

const getTyped = @import("objects.zig").getTyped;

const deleteTyped = @import("objects.zig").deleteTyped;

const deleteAndNullify = @import("objects.zig").deleteAndNullify;

const verification = @import("../verification.zig");
const typeDirectory = @import("../schema/typeDirectory.zig");
const typeRouting = @import("../schema/typeRouting.zig");
const rows = @import("rows.zig");
const relocateRow = @import("../storage/relocation.zig").relocateRow;
const Reference = @import("../storage/reference.zig").Reference;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "link-set accessors return error.NotFound for an absent primaryKey" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link_notfound.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } })).catalogReference;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, linkSetContains(&writeTransaction, catalogReference, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetAdd(&writeTransaction, catalogReference, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetRemove(&writeTransaction, catalogReference, missing, 1, 0));
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.NotFound, linkSetCollect(&writeTransaction, catalogReference, missing, 1, &out, testing.allocator));
}

test "insert stores a link and records the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .link } });
    const boss = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = "Boss" }, .{ .link = null } });
    catalogReference = boss.catalogReference;
    const rep = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .bytes = "Report" }, .{ .link = boss.objectKey } });
    catalogReference = rep.catalogReference;
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 1, 2));
    try testing.expectEqual(@as(?u64, boss.objectKey), try getLink(&writeTransaction, catalogReference, 2, 2));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 2, boss.objectKey));
    var srcs = std.ArrayList(u64).empty;
    defer srcs.deinit(testing.allocator);
    try backlinkCollect(&writeTransaction, catalogReference, 2, boss.objectKey, &srcs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), srcs.items.len);
    try testing.expectEqual(rep.objectKey, srcs.items[0]);
    writeTransaction.deinit();
}

test "setLink moves a link and updates both backlink sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_move.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedC.catalogReference;
    catalogReference = try setLink(&writeTransaction, catalogReference, 3, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, insertedB.objectKey), try getLink(&writeTransaction, catalogReference, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    writeTransaction.deinit();
}

test "nullifying a source's link bumps its version" {
    // Regression: nullify cleared the source's link column without bumping its
    // version, so a client holding the pre-nullify version could update the
    // source with no conflict and silently resurrect the dangling link.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "nullify_version.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var objectKeyA: u64 = undefined;

    // Commit 1: target + linked source.
    {
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogReference = insertedA.catalogReference;
        objectKeyA = insertedA.objectKey;
        const insertedS = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
        writeTransaction.setRoot(insertedS.catalogReference);
        _ = try writeTransaction.commit();
    }
    // Snapshot the source's version, then nullify it via the target's delete
    // in a LATER commit (a distinct transaction version).
    var out: [2]catalog.Value = undefined;
    var stale: u64 = undefined;
    {
        var readTransaction = try database.beginRead();
        defer readTransaction.end();
        stale = (try getTyped(&readTransaction, readTransaction.root(), 2, &out)).?;
    }
    {
        var writeTransaction = try database.beginWrite();
        var raw: [2]u64 = undefined;
        const version = (try @import("rows.zig").getByPrimaryKey(&writeTransaction, writeTransaction.newRoot, 1, &raw)).?;
        const catalogReference = switch (try @import("objects.zig").deleteAndNullify(&writeTransaction, writeTransaction.newRoot, 1, version)) {
            .ok => |newCatalog| newCatalog,
            else => unreachable,
        };
        try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 2, 1));
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }
    // The pre-nullify version must now conflict instead of resurrecting the
    // dangling link.
    {
        var writeTransaction = try database.beginWrite();
        defer writeTransaction.deinit();
        const res = try @import("objects.zig").updateTyped(&writeTransaction, writeTransaction.newRoot, 2, &.{ .{ .int = 2 }, .{ .link = objectKeyA } }, stale);
        try testing.expect(res == .conflict);
    }
}

test "a multi-leaf backlink set is pruned and freed when emptied" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bl_prune_big.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const target = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = target.catalogReference;
    // >64 sources so the backlink inner set splits past one leaf.
    var primaryKey: u64 = 2;
    while (primaryKey <= 82) : (primaryKey += 1) {
        const src = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = primaryKey }, .{ .link = target.objectKey } });
        catalogReference = src.catalogReference;
    }
    try testing.expectEqual(@as(u64, 81), try backlinkCount(&writeTransaction, catalogReference, 1, target.objectKey));
    // Clear every inbound link; the set (and its inner nodes) must be pruned.
    primaryKey = 2;
    while (primaryKey <= 82) : (primaryKey += 1) catalogReference = try setLink(&writeTransaction, catalogReference, primaryKey, 1, null);
    const view = try catalog.loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.backlinkReference(1), target.objectKey));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, target.objectKey));
}

test "an emptied backlink set is pruned from the backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bl_prune.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedB.catalogReference;
    // Clearing the only inbound link must remove a's backlink entry entirely.
    catalogReference = try setLink(&writeTransaction, catalogReference, 2, 1, null);
    const view = try catalog.loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.backlinkReference(1), insertedA.objectKey));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
}

test "setLink clearing a link drops the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_clear.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .link = insertedB.objectKey } });
    catalogReference = insertedC.catalogReference;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    catalogReference = try setLink(&writeTransaction, catalogReference, 3, 1, null);
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    writeTransaction.deinit();
}

test "nullifyInboundInCatalog clears only links whose target type matches the filter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "nullify_filter.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // properties: primaryKey(int), property1(link -> type 5), property2(link -> type 9)
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 5 },
        .{ .kind = .link, .linkTarget = 9 },
    });
    // Target row T, plus S1 (property1 -> T) and S2 (property2 -> T).
    const insertedT = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null }, .{ .link = null } });
    catalogReference = insertedT.catalogReference;
    const inserted1 = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedT.objectKey }, .{ .link = null } });
    catalogReference = inserted1.catalogReference;
    const inserted2 = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .link = null }, .{ .link = insertedT.objectKey } });
    catalogReference = inserted2.catalogReference;
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogReference, 2, 1));
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogReference, 3, 2));
    // Filtered nullify on target type 5 clears only property1's inbound link.
    catalogReference = try nullifyInboundInCatalog(&writeTransaction, catalogReference, insertedT.objectKey, 5, false);
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 2, 1));
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogReference, 3, 2));
    writeTransaction.deinit();
}

test "deleting a target nullifies inbound to-one links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_target.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedC.catalogReference;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogReference, 1, &out)).?;
    const dres = try deleteTyped(&writeTransaction, catalogReference, 1, version);
    catalogReference = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 2, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogReference, 3, 1));
    writeTransaction.deinit();
}

test "deleting a source removes its outbound backlink entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_source.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedB.catalogReference;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = (try deleteTyped(&writeTransaction, catalogReference, 2, version)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    writeTransaction.deinit();
}

test "links and backlinks persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkpersist.airdb");
    defer testing.allocator.free(path);
    var bossRow: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const boss = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogReference = boss.catalogReference;
        bossRow = boss.objectKey;
        var index: u64 = 2;
        while (index <= 50) : (index += 1) catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = index }, .{ .link = boss.objectKey } })).catalogReference;
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, 49), try backlinkCount(&readTransaction, readTransaction.root(), 1, bossRow));
        try testing.expectEqual(@as(?u64, bossRow), try getLink(&readTransaction, readTransaction.root(), 25, 1));
        readTransaction.end();
    }
}

test "a self-link is allowed and recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_self.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    catalogReference = try setLink(&writeTransaction, catalogReference, 1, 1, insertedA.objectKey);
    try testing.expectEqual(@as(?u64, insertedA.objectKey), try getLink(&writeTransaction, catalogReference, 1, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    writeTransaction.deinit();
}

test "a two-node cycle is allowed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogReference = insertedB.catalogReference;
    catalogReference = try setLink(&writeTransaction, catalogReference, 1, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, insertedB.objectKey), try getLink(&writeTransaction, catalogReference, 1, 1));
    // a links to b, and b still links to a, so each keeps one inbound.
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    writeTransaction.deinit();
}

test "to-many link set: insert seeds members and backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_insert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // properties: primaryKey(int), tags(linkSet -> same type)
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogReference = insertedB.catalogReference;
    // c links to both a and b at insert.
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogReference = insertedC.catalogReference;
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogReference, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    // d also links to a, so a now has two inbound.
    const insertedD = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 4 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedD.catalogReference;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    writeTransaction.deinit();
}

test "to-many link set: membership query reflects members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_member.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedC.catalogReference;
    try testing.expect(try linkSetContains(&writeTransaction, catalogReference, 3, 1, insertedA.objectKey));
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogReference, 3, 1, insertedB.objectKey)));
    writeTransaction.deinit();
}

test "to-many link set: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addnew.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedC.catalogReference;
    catalogReference = try linkSetAdd(&writeTransaction, catalogReference, 3, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogReference, 3, 1));
    try testing.expect(try linkSetContains(&writeTransaction, catalogReference, 3, 1, insertedB.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedB.objectKey));
    writeTransaction.deinit();
}

test "to-many link set: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addexist.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogReference = insertedC.catalogReference;
    catalogReference = try linkSetAdd(&writeTransaction, catalogReference, 3, 1, insertedA.objectKey); // already member, no change
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogReference, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    writeTransaction.deinit();
}

test "to-many link set: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogReference = insertedC.catalogReference;
    // d also links to a, so a has two inbound before the removal.
    const insertedD = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 4 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedD.catalogReference;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    catalogReference = try linkSetRemove(&writeTransaction, catalogReference, 3, 1, insertedA.objectKey);
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogReference, 3, 1, insertedA.objectKey)));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey)); // only d now
    writeTransaction.deinit();
}

test "deleting a to-many target removes it from all linkers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_target.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedB.catalogReference;
    const insertedC = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedC.catalogReference;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    // Delete a: b and c must lose a from their sets.
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogReference, 1, &out)).?;
    catalogReference = (try deleteTyped(&writeTransaction, catalogReference, 1, version)).ok;
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogReference, 2, 1, insertedA.objectKey)));
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogReference, 3, 1, insertedA.objectKey)));
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&writeTransaction, catalogReference, 2, 1));
    writeTransaction.deinit();
}

test "deleting a to-many linker cleans its backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_linker.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogReference = insertedA.catalogReference;
    const insertedB = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 2 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogReference = insertedB.catalogReference;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    // Delete b (the linker): no lingering backlink on a's objectKey.
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = (try deleteTyped(&writeTransaction, catalogReference, 2, version)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogReference, 1, insertedA.objectKey));
    writeTransaction.deinit();
}

test "to-many links persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset3.airdb");
    defer testing.allocator.free(path);
    var hubRow: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
        const hub = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
        catalogReference = hub.catalogReference;
        hubRow = hub.objectKey;
        var index: u64 = 2;
        while (index <= 30) : (index += 1) {
            const insertedO = try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = index }, .{ .linkSet = &.{hub.objectKey} } });
            catalogReference = insertedO.catalogReference;
        }
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, 29), try backlinkCount(&readTransaction, readTransaction.root(), 1, hubRow));
        try testing.expect(try linkSetContains(&readTransaction, readTransaction.root(), 15, 1, hubRow));
        readTransaction.end();
    }
}

// ---------------------------------------------------------------------------
// Regression coverage for issue #60: an indexed link property going stale
// when its column is written outside rows.zig (nullifySourceLink, setLink).
// ---------------------------------------------------------------------------

const IndexedLinkFixture = struct {
    target: u64,
    source: u64,
    bystander: u64,
};

// Shared setup for L1-L3: one type with an int property and an indexed link
// property, three objects (target null-linked, source linked to target,
// bystander null-linked so value-index key 0 already has a non-empty inner
// set before the nullify), then target is deleted so source's inbound link
// is nullified. Commits, so the caller reads through a fresh transaction.
// Every test that reads through verifyIntegrity needs a real type-directory
// root (not a bare catalog), so this always goes through typeDirectory /
// typeRouting rather than catalog.createFromDefinitions directly.
fn buildIndexedLinkFixture(database: *Database) !IndexedLinkFixture {
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0, .indexed = true },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const target = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = target.directoryReference;
    const source = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = target.objectKey } });
    directoryReference = source.directoryReference;
    const bystander = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .link = null } });
    directoryReference = bystander.directoryReference;

    var buffer: [2]catalog.Value = undefined;
    const targetVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 1, &buffer)).?;
    directoryReference = (try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, targetVersion)).ok;
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    return .{ .target = target.objectKey, .source = source.objectKey, .bystander = bystander.objectKey };
}

test "L1: an inbound nullify keeps the indexed link property queryable at null" {
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const fixture = try buildIndexedLinkFixture(&database);

    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = 0 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    var containsSource = false;
    var containsBystander = false;
    for (hits.items) |objectKey| {
        if (objectKey == fixture.source) containsSource = true;
        if (objectKey == fixture.bystander) containsBystander = true;
    }
    try testing.expect(containsSource);
    try testing.expect(containsBystander);
}

test "L2: an inbound nullify leaves the value index auditable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    _ = try buildIndexedLinkFixture(&database);
    try verification.verifyIntegrity(&database);
}

test "L3: maximum over an indexed link reads no value after an inbound nullify" {
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    _ = try buildIndexedLinkFixture(&database);

    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    try testing.expectEqual(@as(?u64, 0), try query.maximum(&readTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 0), try query.minimum(&readTransaction, catalogReference, 1, testing.allocator));
}

test "L4: an untouched indexed link keeps its value-index entry through an unrelated nullify" {
    // False-positive control: the input that must NOT trigger a removal.
    // The where/getLink assertions below carry that guarantee and hold both
    // before and after the fix: survivor/other are never touched by the
    // target nullify and are indexed correctly at insert time regardless of
    // this bug.
    //
    // The verifyIntegrity call, by contrast, is expected to fail pre-fix for
    // the SAME reason L1/L2 fail: this fixture reuses the L1 shape (target
    // deleted, source's inbound link goes stale) inside the same catalog,
    // and verifyIntegrity audits the whole catalog, not just the
    // survivor/other pair. That failure is not evidence of over-removal; it
    // is the already-covered L1 defect, present in the same shared catalog.
    // Confirmed pre-fix: the where/getLink assertions pass in isolation
    // (checked before verifyIntegrity below) while verifyIntegrity itself
    // fails with error.ValueIndexMissingEntry, at the same source-row
    // divergence L1 exercises.
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0, .indexed = true },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const target = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = target.directoryReference;
    const source = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = target.objectKey } });
    directoryReference = source.directoryReference;
    const bystander = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .link = null } });
    directoryReference = bystander.directoryReference;
    const other = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 5 }, .{ .link = null } });
    directoryReference = other.directoryReference;
    const survivor = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 4 }, .{ .link = other.objectKey } });
    directoryReference = survivor.directoryReference;

    var buffer: [2]catalog.Value = undefined;
    const targetVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 1, &buffer)).?;
    directoryReference = (try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, targetVersion)).ok;
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = other.objectKey + 1 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(survivor.objectKey, hits.items[0]);
    try testing.expectEqual(@as(?u64, other.objectKey), try getLink(&readTransaction, catalogReference, 4, 1));
    try verification.verifyIntegrity(&database);
}

test "L5: deleting a self-linked object with an indexed link leaves the index clean" {
    // The concurrency-free but genuinely distinct seam: bumpVersion = false,
    // and the row being nullified is the row about to be tombstoned, so the
    // value-index move and the delete's own value-index removal must compose.
    //
    // otherSource is deliberately included alongside the self-link: on the
    // self-link alone, rows.delete's own post-nullify value-index removal
    // (which always reads the CURRENT, already-nullified column of the row
    // being deleted) masks nullifySourceLink's defect, because the self
    // source and the row being tombstoned are the same row -- the self case
    // is therefore audit-clean whether or not nullifySourceLink itself
    // maintains the index. otherSource is a genuinely separate row indexed
    // correctly at insert time and nullified by the SAME delete, exactly
    // like L1/L7's single-mutation shape, so it is what actually exposes the
    // bug here; the self-link's own contract (bumpVersion stays false, no
    // conflict) is what the .ok assertion below pins.
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0, .indexed = true },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const selfObject = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = selfObject.directoryReference;
    directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, 0, 1, 1, selfObject.objectKey);
    const bystander = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = null } });
    directoryReference = bystander.directoryReference;
    const otherSource = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .link = selfObject.objectKey } });
    directoryReference = otherSource.directoryReference;

    var buffer: [2]catalog.Value = undefined;
    const selfVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 1, &buffer)).?;
    const deleteResult = try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, selfVersion);
    try testing.expect(deleteResult == .ok); // not .conflict: bumpVersion must stay false on the self-link path
    directoryReference = deleteResult.ok;
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = 0 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    var containsBystander = false;
    var containsOtherSource = false;
    for (hits.items) |objectKey| {
        if (objectKey == bystander.objectKey) containsBystander = true;
        if (objectKey == otherSource.objectKey) containsOtherSource = true;
    }
    try testing.expect(containsBystander);
    try testing.expect(containsOtherSource);
    try testing.expectEqual(@as(?u64, null), try typeRouting.get(&readTransaction, readTransaction.root(), 0, 1, &buffer));
}

test "L6: a link property with no value index is left alone by an inbound nullify" {
    // False-negative guard for the indexed check. If the Coder drops that
    // condition, addToValueIndex would call Index.insert on a zero
    // valueIndexReference and Arena.dereference would return
    // error.BadReference, since an unindexed property's valueIndexReference
    // is 0 (catalog.createFromDefinitions).
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0 },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const target = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = target.directoryReference;
    const source = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = target.objectKey } });
    directoryReference = source.directoryReference;
    const bystander = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .link = null } });
    directoryReference = bystander.directoryReference;

    var buffer: [2]catalog.Value = undefined;
    const targetVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 1, &buffer)).?;
    directoryReference = (try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, targetVersion)).ok;
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    try testing.expectEqual(@as(?u64, null), try getLink(&readTransaction, catalogReference, 2, 1));
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = 0 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len);
}

test "L7: setLink moves the value-index entry with the link" {
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0, .indexed = true },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const targetA = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = targetA.directoryReference;
    const targetB = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = null } });
    directoryReference = targetB.directoryReference;
    const source = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .link = targetA.objectKey } });
    directoryReference = source.directoryReference;
    directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, 0, 3, 1, targetB.objectKey);
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = targetB.objectKey + 1 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(source.objectKey, hits.items[0]);
    hits.clearRetainingCapacity();
    try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = targetA.objectKey + 1 } } } }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
    try testing.expectEqual(@as(?u64, targetB.objectKey + 1), try query.maximum(&readTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 0), try query.minimum(&readTransaction, catalogReference, 1, testing.allocator));
}

test "L8: createFromDefinitions rejects indexed on a collection kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    for ([_]catalog.PropertyKind{ .list, .set, .dict, .linkSet }) |collectionKind| {
        try testing.expectError(error.Unsupported, catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = collectionKind, .indexed = true },
        }));
    }

    // L8b, false-positive validation: the check must not reject what it has
    // to accept. Without this, a guard that rejected every indexed property,
    // or every collection property, would pass L8 and nothing would notice.
    _ = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    _ = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } });
    _ = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link, .indexed = true } });
    _ = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
}

test "L9: an inbound nullify of a to-many link stays auditable" {
    // nullifySourceLinkSet is unchanged by this work, and after Fix C an
    // indexed linkSet can never exist. This pins that the to-many nullify
    // path still behaves, backing the survey's "exempt" verdict with an
    // assertion rather than reasoning alone. Must pass before and after
    // every edit in this change.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .linkSet, .linkTarget = 0 },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
    const target = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    directoryReference = target.directoryReference;
    const sourceA = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .linkSet = &.{target.objectKey} } });
    directoryReference = sourceA.directoryReference;
    const sourceB = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 3 }, .{ .linkSet = &.{target.objectKey} } });
    directoryReference = sourceB.directoryReference;
    const selfLinker = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 4 }, .{ .linkSet = &.{} } });
    directoryReference = selfLinker.directoryReference;
    directoryReference = try typeRouting.linkSetAdd(&writeTransaction, directoryReference, 0, 4, 1, selfLinker.objectKey);

    var buffer: [2]catalog.Value = undefined;
    const targetVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 1, &buffer)).?;
    const deleteTargetResult = try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, targetVersion);
    try testing.expect(deleteTargetResult == .ok);
    directoryReference = deleteTargetResult.ok;

    const selfVersion = (try typeRouting.get(&writeTransaction, directoryReference, 0, 4, &buffer)).?;
    const deleteSelfResult = try typeRouting.deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 4, selfVersion);
    try testing.expect(deleteSelfResult == .ok);
    directoryReference = deleteSelfResult.ok;

    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();

    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&readTransaction, catalogReference, 2, 1));
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&readTransaction, catalogReference, 3, 1));
}

test "L11: an inbound nullify of a relocated source indexes the objectKey, not the row" {
    // The value index's inner sets hold objectKeys, exactly like backlink
    // sets. On a fresh catalog objectKey == row for every row (rows.insert
    // advances nextRow and nextKey in lockstep from 0, and delete decrements
    // neither), so no other test in this plan can tell the two apart.
    // Relocating the source is what separates them; the divergence
    // assertion below is mandatory, not decoration.
    //
    // otherTarget gives the source a NON-ZERO initial indexed value (rather
    // than null). rows.insert does not create backlinks for a raw link value
    // written directly into the column (only links.setLink/insertTyped do
    // that), so the source-to-target backlink under test still has to be
    // established through links.setLink; and if the source started at null
    // (0), establishing then nullifying it would round-trip the raw value to
    // exactly the one rows.insert originally indexed it at, which
    // rows.delete's own bookkeeping keeps correct regardless of
    // nullifySourceLink's own defect (the same masking L5's comment
    // describes) -- it would make this test pass vacuously rather than
    // exercising Fix A. otherTarget breaks the round trip: the source's
    // insert-time indexed value (otherTarget+1) differs from its final,
    // nullified value (0), so a missing move is a genuine, observable
    // divergence.
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .indexed = true } });
    const throwaway = try rows.insert(&writeTransaction, catalogReference, &.{ 99, 0 });
    catalogReference = throwaway.catalogReference;
    const otherTarget = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 0 });
    catalogReference = otherTarget.catalogReference;
    const targetObject = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 0 });
    catalogReference = targetObject.catalogReference;
    const sourceObject = try rows.insert(&writeTransaction, catalogReference, &.{ 3, otherTarget.objectKey + 1 });
    catalogReference = sourceObject.catalogReference;

    // Free the throwaway's physical slot and relocate the SOURCE into it, so
    // the source's row and objectKey diverge.
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, throwaway.objectKey)).?;
    var out: [2]u64 = undefined;
    const throwawayVersion = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 99, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 99, throwawayVersion)).ok;
    catalogReference = try relocateRow(&writeTransaction, catalogReference, sourceObject.objectKey, deadRow);
    try testing.expect((try catalog.objectKeyToRow(&writeTransaction, catalogReference, sourceObject.objectKey)).? != sourceObject.objectKey);

    // Move the source's link from otherTarget to the real target under test.
    // setLink always maintains the backlink (unaffected by this bug), which
    // is what lets the deletion below find the source through the graph.
    catalogReference = try links.setLink(&writeTransaction, catalogReference, 3, 1, targetObject.objectKey);
    const targetVersion = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &out)).?;
    catalogReference = switch (try deleteAndNullify(&writeTransaction, catalogReference, 1, targetVersion)) {
        .ok => |newCatalog| newCatalog,
        else => unreachable,
    };

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&writeTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = 0 } } } }, &hits, testing.allocator);
    // The target and the throwaway are dead; otherTarget (still null-linked)
    // and the relocated source (nullified back to null) are the two live
    // rows left at value 0.
    try testing.expectEqual(@as(usize, 2), hits.items.len);
    var containsSource = false;
    for (hits.items) |objectKey| {
        try testing.expect(objectKey != deadRow); // the objectKey is indexed, not the physical row
        if (objectKey == sourceObject.objectKey) containsSource = true;
    }
    try testing.expect(containsSource);
    try testing.expectEqual(@as(?u64, null), try links.getLink(&writeTransaction, catalogReference, 3, 1));
}

test "L10: fuzz, indexed link writes keep the value index and the columns in agreement" {
    const query = @import("../query.zig");
    const ModelEntry = struct { objectKey: u64, target: ?u64 };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "l10.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 0, .indexed = true },
    };
    var model = std.AutoHashMap(u64, ModelEntry).init(testing.allocator);
    defer model.deinit();
    var dead = std.AutoHashMap(u64, void).init(testing.allocator);
    defer dead.deinit();
    {
        var writeTransaction = try database.beginWrite();
        defer writeTransaction.deinit();
        var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
        var primaryKey: u64 = 1;
        while (primaryKey <= 8) : (primaryKey += 1) {
            const inserted = try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = primaryKey }, .{ .link = null } });
            directoryReference = inserted.directoryReference;
            try model.put(primaryKey, .{ .objectKey = inserted.objectKey, .target = null });
        }
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }

    // Seed literal, recorded per the test plan: 20260902 (any fixed value
    // works; this one is the date the spec was written).
    var prng = std.Random.DefaultPrng.init(20260902);
    const random = prng.random();
    var setLinkMoves: usize = 0;
    var nullifyEvents: usize = 0;
    var round: usize = 0;
    while (round < 120) : (round += 1) {
        var liveKeys = std.ArrayList(u64).empty;
        defer liveKeys.deinit(testing.allocator);
        {
            var liveIterator = model.keyIterator();
            while (liveIterator.next()) |primaryKeyPointer| try liveKeys.append(testing.allocator, primaryKeyPointer.*);
        }
        var deadKeys = std.ArrayList(u64).empty;
        defer deadKeys.deinit(testing.allocator);
        {
            var deadIterator = dead.keyIterator();
            while (deadIterator.next()) |primaryKeyPointer| try deadKeys.append(testing.allocator, primaryKeyPointer.*);
        }

        const Action = enum { setLink, delete, reinsert };
        var action: Action = .setLink;
        while (true) {
            action = switch (random.intRangeLessThan(usize, 0, 3)) {
                0 => .setLink,
                1 => .delete,
                else => .reinsert,
            };
            if (action == .reinsert and deadKeys.items.len == 0) continue;
            if (action != .reinsert and liveKeys.items.len == 0) continue;
            break;
        }

        var writeTransaction = try database.beginWrite();
        defer writeTransaction.deinit();
        var currentDirectory = writeTransaction.newRoot;

        switch (action) {
            .setLink => {
                const sourcePrimaryKey = liveKeys.items[random.intRangeLessThan(usize, 0, liveKeys.items.len)];
                const choice = random.intRangeLessThan(usize, 0, liveKeys.items.len + 1);
                const newTarget: ?u64 = if (choice == liveKeys.items.len) null else model.get(liveKeys.items[choice]).?.objectKey;
                currentDirectory = try typeRouting.setLink(&writeTransaction, currentDirectory, 0, sourcePrimaryKey, 1, newTarget);
                const entry = model.getPtr(sourcePrimaryKey).?;
                if (entry.target != newTarget) setLinkMoves += 1;
                entry.target = newTarget;
            },
            .delete => {
                const deletedPrimaryKey = liveKeys.items[random.intRangeLessThan(usize, 0, liveKeys.items.len)];
                var buffer: [2]catalog.Value = undefined;
                const version = (try typeRouting.get(&writeTransaction, currentDirectory, 0, deletedPrimaryKey, &buffer)).?;
                const result = try typeRouting.deleteNullifyCrossType(&writeTransaction, currentDirectory, 0, deletedPrimaryKey, version);
                try testing.expect(result == .ok);
                currentDirectory = result.ok;
                const deletedObjectKey = model.get(deletedPrimaryKey).?.objectKey;
                _ = model.remove(deletedPrimaryKey);
                try dead.put(deletedPrimaryKey, {});
                var affectedIterator = model.valueIterator();
                while (affectedIterator.next()) |entry| {
                    if (entry.target) |currentTarget| {
                        if (currentTarget == deletedObjectKey) {
                            entry.target = null;
                            nullifyEvents += 1;
                        }
                    }
                }
            },
            .reinsert => {
                const revivedPrimaryKey = deadKeys.items[random.intRangeLessThan(usize, 0, deadKeys.items.len)];
                const choice = random.intRangeLessThan(usize, 0, liveKeys.items.len + 1);
                const newTarget: ?u64 = if (liveKeys.items.len == 0 or choice == liveKeys.items.len) null else model.get(liveKeys.items[choice]).?.objectKey;
                const inserted = try typeRouting.insert(&writeTransaction, currentDirectory, 0, &.{ .{ .int = revivedPrimaryKey }, .{ .link = newTarget } });
                currentDirectory = inserted.directoryReference;
                try model.put(revivedPrimaryKey, .{ .objectKey = inserted.objectKey, .target = newTarget });
                _ = dead.remove(revivedPrimaryKey);
            },
        }

        writeTransaction.setRoot(currentDirectory);
        _ = try writeTransaction.commit();

        try verification.verifyIntegrity(&database);

        var readTransaction = try database.beginRead();
        defer readTransaction.end();
        const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);

        var seenRaws = std.ArrayList(u64).empty;
        defer seenRaws.deinit(testing.allocator);
        {
            var modelIterator = model.valueIterator();
            while (modelIterator.next()) |entry| {
                const raw: u64 = if (entry.target) |target| target + 1 else 0;
                var alreadySeen = false;
                for (seenRaws.items) |seen| {
                    if (seen == raw) {
                        alreadySeen = true;
                        break;
                    }
                }
                if (!alreadySeen) try seenRaws.append(testing.allocator, raw);
            }
        }

        for (seenRaws.items) |raw| {
            var expected = std.ArrayList(u64).empty;
            defer expected.deinit(testing.allocator);
            {
                var expectedIterator = model.valueIterator();
                while (expectedIterator.next()) |entry| {
                    const entryRaw: u64 = if (entry.target) |target| target + 1 else 0;
                    if (entryRaw == raw) try expected.append(testing.allocator, entry.objectKey);
                }
            }
            var actual = std.ArrayList(u64).empty;
            defer actual.deinit(testing.allocator);
            try query.where(&readTransaction, catalogReference, .{ .predicate = .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = raw } } } }, &actual, testing.allocator);
            try testing.expectEqual(expected.items.len, actual.items.len);
            for (expected.items) |expectedObjectKey| {
                var found = false;
                for (actual.items) |actualObjectKey| {
                    if (actualObjectKey == expectedObjectKey) {
                        found = true;
                        break;
                    }
                }
                try testing.expect(found);
            }
        }
    }

    // False-positive validation: a seed that happened to exercise neither a
    // moving setLink nor a nullifying delete would pass vacuously.
    try testing.expect(setLinkMoves > 0);
    try testing.expect(nullifyEvents > 0);
}
