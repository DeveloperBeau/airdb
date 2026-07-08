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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } })).catalogRef;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, linkSetContains(&writeTransaction, catalogRef, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetAdd(&writeTransaction, catalogRef, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetRemove(&writeTransaction, catalogRef, missing, 1, 0));
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.NotFound, linkSetCollect(&writeTransaction, catalogRef, missing, 1, &out, testing.allocator));
}

test "insert stores a link and records the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .link } });
    const boss = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "Boss" }, .{ .link = null } });
    catalogRef = boss.catalogRef;
    const rep = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .bytes = "Report" }, .{ .link = boss.objectKey } });
    catalogRef = rep.catalogRef;
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 1, 2));
    try testing.expectEqual(@as(?u64, boss.objectKey), try getLink(&writeTransaction, catalogRef, 2, 2));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 2, boss.objectKey));
    var srcs = std.ArrayList(u64).empty;
    defer srcs.deinit(testing.allocator);
    try backlinkCollect(&writeTransaction, catalogRef, 2, boss.objectKey, &srcs, testing.allocator);
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedC.catalogRef;
    catalogRef = try setLink(&writeTransaction, catalogRef, 3, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, insertedB.objectKey), try getLink(&writeTransaction, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
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
        var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogRef = insertedA.catalogRef;
        objectKeyA = insertedA.objectKey;
        const insertedS = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
        writeTransaction.setRoot(insertedS.catalogRef);
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
        const catalogRef = switch (try @import("objects.zig").deleteAndNullify(&writeTransaction, writeTransaction.newRoot, 1, version)) {
            .ok => |newCatalog| newCatalog,
            else => unreachable,
        };
        try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 2, 1));
        writeTransaction.setRoot(catalogRef);
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const target = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = target.catalogRef;
    // >64 sources so the backlink inner set splits past one leaf.
    var primaryKey: u64 = 2;
    while (primaryKey <= 82) : (primaryKey += 1) {
        const src = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = primaryKey }, .{ .link = target.objectKey } });
        catalogRef = src.catalogRef;
    }
    try testing.expectEqual(@as(u64, 81), try backlinkCount(&writeTransaction, catalogRef, 1, target.objectKey));
    // Clear every inbound link; the set (and its inner nodes) must be pruned.
    primaryKey = 2;
    while (primaryKey <= 82) : (primaryKey += 1) catalogRef = try setLink(&writeTransaction, catalogRef, primaryKey, 1, null);
    const view = try catalog.loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.backlinkRef(1), target.objectKey));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, target.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedB.catalogRef;
    // Clearing the only inbound link must remove a's backlink entry entirely.
    catalogRef = try setLink(&writeTransaction, catalogRef, 2, 1, null);
    const view = try catalog.loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.backlinkRef(1), insertedA.objectKey));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
}

test "setLink clearing a link drops the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_clear.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .link = insertedB.objectKey } });
    catalogRef = insertedC.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
    catalogRef = try setLink(&writeTransaction, catalogRef, 3, 1, null);
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 5 },
        .{ .kind = .link, .linkTarget = 9 },
    });
    // Target row T, plus S1 (property1 -> T) and S2 (property2 -> T).
    const insertedT = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null }, .{ .link = null } });
    catalogRef = insertedT.catalogRef;
    const inserted1 = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedT.objectKey }, .{ .link = null } });
    catalogRef = inserted1.catalogRef;
    const inserted2 = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .link = null }, .{ .link = insertedT.objectKey } });
    catalogRef = inserted2.catalogRef;
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogRef, 3, 2));
    // Filtered nullify on target type 5 clears only property1's inbound link.
    catalogRef = try nullifyInboundInCatalog(&writeTransaction, catalogRef, insertedT.objectKey, 5, false);
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, insertedT.objectKey), try getLink(&writeTransaction, catalogRef, 3, 2));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedC.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    const dres = try deleteTyped(&writeTransaction, catalogRef, 1, version);
    catalogRef = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, catalogRef, 3, 1));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedB.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 2, &out)).?;
    catalogRef = (try deleteTyped(&writeTransaction, catalogRef, 2, version)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
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
        var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const boss = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogRef = boss.catalogRef;
        bossRow = boss.objectKey;
        var index: u64 = 2;
        while (index <= 50) : (index += 1) catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = index }, .{ .link = boss.objectKey } })).catalogRef;
        writeTransaction.setRoot(catalogRef);
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    catalogRef = try setLink(&writeTransaction, catalogRef, 1, 1, insertedA.objectKey);
    try testing.expectEqual(@as(?u64, insertedA.objectKey), try getLink(&writeTransaction, catalogRef, 1, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedB.catalogRef;
    catalogRef = try setLink(&writeTransaction, catalogRef, 1, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, insertedB.objectKey), try getLink(&writeTransaction, catalogRef, 1, 1));
    // a links to b, and b still links to a, so each keeps one inbound.
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogRef = insertedB.catalogRef;
    // c links to both a and b at insert.
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogRef = insertedC.catalogRef;
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
    // d also links to a, so a now has two inbound.
    const insertedD = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 4 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedD.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedC.catalogRef;
    try testing.expect(try linkSetContains(&writeTransaction, catalogRef, 3, 1, insertedA.objectKey));
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogRef, 3, 1, insertedB.objectKey)));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedC.catalogRef;
    catalogRef = try linkSetAdd(&writeTransaction, catalogRef, 3, 1, insertedB.objectKey);
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogRef, 3, 1));
    try testing.expect(try linkSetContains(&writeTransaction, catalogRef, 3, 1, insertedB.objectKey));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogRef = insertedC.catalogRef;
    catalogRef = try linkSetAdd(&writeTransaction, catalogRef, 3, 1, insertedA.objectKey); // already member, no change
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&writeTransaction, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{} } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } });
    catalogRef = insertedC.catalogRef;
    // d also links to a, so a has two inbound before the removal.
    const insertedD = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 4 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedD.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    catalogRef = try linkSetRemove(&writeTransaction, catalogRef, 3, 1, insertedA.objectKey);
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogRef, 3, 1, insertedA.objectKey)));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey)); // only d now
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedC.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    // Delete a: b and c must lose a from their sets.
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    catalogRef = (try deleteTyped(&writeTransaction, catalogRef, 1, version)).ok;
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogRef, 2, 1, insertedA.objectKey)));
    try testing.expect(!(try linkSetContains(&writeTransaction, catalogRef, 3, 1, insertedA.objectKey)));
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&writeTransaction, catalogRef, 2, 1));
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .linkSet = &.{insertedA.objectKey} } });
    catalogRef = insertedB.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    // Delete b (the linker): no lingering backlink on a's objectKey.
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 2, &out)).?;
    catalogRef = (try deleteTyped(&writeTransaction, catalogRef, 2, version)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
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
        var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .linkSet } });
        const hub = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
        catalogRef = hub.catalogRef;
        hubRow = hub.objectKey;
        var index: u64 = 2;
        while (index <= 30) : (index += 1) {
            const insertedO = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = index }, .{ .linkSet = &.{hub.objectKey} } });
            catalogRef = insertedO.catalogRef;
        }
        writeTransaction.setRoot(catalogRef);
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
