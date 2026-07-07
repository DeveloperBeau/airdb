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
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "link-set accessors return error.NotFound for an absent primaryKey" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link_notfound.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } })).catalogRef;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, linkSetContains(&w, catalogRef, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetAdd(&w, catalogRef, missing, 1, 0));
    try testing.expectError(error.NotFound, linkSetRemove(&w, catalogRef, missing, 1, 0));
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.NotFound, linkSetCollect(&w, catalogRef, missing, 1, &out, testing.allocator));
}

test "insert stores a link and records the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .link } });
    const boss = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "Boss" }, .{ .link = null } });
    catalogRef = boss.catalogRef;
    const rep = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .bytes = "Report" }, .{ .link = boss.row } });
    catalogRef = rep.catalogRef;
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 1, 2));
    try testing.expectEqual(@as(?u64, boss.row), try getLink(&w, catalogRef, 2, 2));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 2, boss.row));
    var srcs = std.ArrayList(u64).empty;
    defer srcs.deinit(testing.allocator);
    try backlinkCollect(&w, catalogRef, 2, boss.row, &srcs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), srcs.items.len);
    try testing.expectEqual(rep.row, srcs.items[0]);
    w.deinit();
}

test "setLink moves a link and updates both backlink sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_move.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link = a.row } });
    catalogRef = c.catalogRef;
    catalogRef = try setLink(&w, catalogRef, 3, 1, b.row);
    try testing.expectEqual(@as(?u64, b.row), try getLink(&w, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, b.row));
    w.deinit();
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
        var w = try database.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogRef = a.catalogRef;
        objectKeyA = a.row;
        const s = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = a.row } });
        w.setRoot(s.catalogRef);
        _ = try w.commit();
    }
    // Snapshot the source's version, then nullify it via the target's delete
    // in a LATER commit (a distinct transaction version).
    var out: [2]catalog.Value = undefined;
    var stale: u64 = undefined;
    {
        var r = try database.beginRead();
        defer r.end();
        stale = (try getTyped(&r, r.root(), 2, &out)).?;
    }
    {
        var w = try database.beginWrite();
        var raw: [2]u64 = undefined;
        const av = (try @import("rows.zig").getByPrimaryKey(&w, w.new_root, 1, &raw)).?;
        const catalogRef = switch (try @import("objects.zig").deleteAndNullify(&w, w.new_root, 1, av)) {
            .ok => |x| x,
            else => unreachable,
        };
        try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 2, 1));
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    // The pre-nullify version must now conflict instead of resurrecting the
    // dangling link.
    {
        var w = try database.beginWrite();
        defer w.deinit();
        const res = try @import("objects.zig").updateTyped(&w, w.new_root, 2, &.{ .{ .int = 2 }, .{ .link = objectKeyA } }, stale);
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
    var w = try database.beginWrite();
    defer w.deinit();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const target = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = target.catalogRef;
    // >64 sources so the backlink inner set splits past one leaf.
    var primaryKey: u64 = 2;
    while (primaryKey <= 82) : (primaryKey += 1) {
        const src = try insertTyped(&w, catalogRef, &.{ .{ .int = primaryKey }, .{ .link = target.row } });
        catalogRef = src.catalogRef;
    }
    try testing.expectEqual(@as(u64, 81), try backlinkCount(&w, catalogRef, 1, target.row));
    // Clear every inbound link; the set (and its inner nodes) must be pruned.
    primaryKey = 2;
    while (primaryKey <= 82) : (primaryKey += 1) catalogRef = try setLink(&w, catalogRef, primaryKey, 1, null);
    const v = try catalog.loadCatalog(&w, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&w, v.backlinkRef(1), target.row));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, target.row));
}

test "an emptied backlink set is pruned from the backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bl_prune.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = a.row } });
    catalogRef = b.catalogRef;
    // Clearing the only inbound link must remove a's backlink entry entirely.
    catalogRef = try setLink(&w, catalogRef, 2, 1, null);
    const v = try catalog.loadCatalog(&w, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&w, v.backlinkRef(1), a.row));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, a.row));
}

test "setLink clearing a link drops the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_clear.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link = b.row } });
    catalogRef = c.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, b.row));
    catalogRef = try setLink(&w, catalogRef, 3, 1, null);
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, b.row));
    w.deinit();
}

test "nullifyInboundInCatalog clears only links whose target type matches the filter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "nullify_filter.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    // properties: primaryKey(int), property1(link -> type 5), property2(link -> type 9)
    var catalogRef = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 5 },
        .{ .kind = .link, .link_target = 9 },
    });
    // Target row T, plus S1 (property1 -> T) and S2 (property2 -> T).
    const t = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null }, .{ .link = null } });
    catalogRef = t.catalogRef;
    const s1 = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = t.row }, .{ .link = null } });
    catalogRef = s1.catalogRef;
    const s2 = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link = null }, .{ .link = t.row } });
    catalogRef = s2.catalogRef;
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, catalogRef, 3, 2));
    // Filtered nullify on target type 5 clears only property1's inbound link.
    catalogRef = try nullifyInboundInCatalog(&w, catalogRef, t.row, 5, false);
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, catalogRef, 3, 2));
    w.deinit();
}

test "deleting a target nullifies inbound to-one links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_target.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = a.row } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link = a.row } });
    catalogRef = c.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, catalogRef, 1, a.row));
    var out: [2]Value = undefined;
    const va = (try getTyped(&w, catalogRef, 1, &out)).?;
    const dres = try deleteTyped(&w, catalogRef, 1, va);
    catalogRef = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 2, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&w, catalogRef, 3, 1));
    w.deinit();
}

test "deleting a source removes its outbound backlink entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_source.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = a.row } });
    catalogRef = b.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    var out: [2]Value = undefined;
    const vb = (try getTyped(&w, catalogRef, 2, &out)).?;
    catalogRef = (try deleteTyped(&w, catalogRef, 2, vb)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, a.row));
    w.deinit();
}

test "links and backlinks persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkpersist.airdb");
    defer testing.allocator.free(path);
    var boss_row: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const boss = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
        catalogRef = boss.catalogRef;
        boss_row = boss.row;
        var i: u64 = 2;
        while (i <= 50) : (i += 1) catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = i }, .{ .link = boss.row } })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try testing.expectEqual(@as(u64, 49), try backlinkCount(&r, r.root(), 1, boss_row));
        try testing.expectEqual(@as(?u64, boss_row), try getLink(&r, r.root(), 25, 1));
        r.end();
    }
}

test "a self-link is allowed and recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_self.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    catalogRef = try setLink(&w, catalogRef, 1, 1, a.row);
    try testing.expectEqual(@as(?u64, a.row), try getLink(&w, catalogRef, 1, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    w.deinit();
}

test "a two-node cycle is allowed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = a.row } });
    catalogRef = b.catalogRef;
    catalogRef = try setLink(&w, catalogRef, 1, 1, b.row);
    try testing.expectEqual(@as(?u64, b.row), try getLink(&w, catalogRef, 1, 1));
    // a links to b, and b still links to a, so each keeps one inbound.
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, b.row));
    w.deinit();
}

test "to-many link set: insert seeds members and backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_insert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    // properties: primaryKey(int), tags(link_set -> same type)
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    catalogRef = b.catalogRef;
    // c links to both a and b at insert.
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    catalogRef = c.catalogRef;
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, b.row));
    // d also links to a, so a now has two inbound.
    const d = try insertTyped(&w, catalogRef, &.{ .{ .int = 4 }, .{ .link_set = &.{a.row} } });
    catalogRef = d.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, catalogRef, 1, a.row));
    w.deinit();
}

test "to-many link set: membership query reflects members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_member.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    catalogRef = c.catalogRef;
    try testing.expect(try linkSetContains(&w, catalogRef, 3, 1, a.row));
    try testing.expect(!(try linkSetContains(&w, catalogRef, 3, 1, b.row)));
    w.deinit();
}

test "to-many link set: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addnew.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    catalogRef = c.catalogRef;
    catalogRef = try linkSetAdd(&w, catalogRef, 3, 1, b.row);
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, catalogRef, 3, 1));
    try testing.expect(try linkSetContains(&w, catalogRef, 3, 1, b.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, b.row));
    w.deinit();
}

test "to-many link set: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addexist.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    catalogRef = c.catalogRef;
    catalogRef = try linkSetAdd(&w, catalogRef, 3, 1, a.row); // already member, no change
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, catalogRef, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    w.deinit();
}

test "to-many link set: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    catalogRef = c.catalogRef;
    // d also links to a, so a has two inbound before the removal.
    const d = try insertTyped(&w, catalogRef, &.{ .{ .int = 4 }, .{ .link_set = &.{a.row} } });
    catalogRef = d.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, catalogRef, 1, a.row));
    catalogRef = try linkSetRemove(&w, catalogRef, 3, 1, a.row);
    try testing.expect(!(try linkSetContains(&w, catalogRef, 3, 1, a.row)));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row)); // only d now
    w.deinit();
}

test "deleting a to-many target removes it from all linkers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_target.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{a.row} } });
    catalogRef = b.catalogRef;
    const c = try insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    catalogRef = c.catalogRef;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, catalogRef, 1, a.row));
    // Delete a: b and c must lose a from their sets.
    var out: [2]Value = undefined;
    const va = (try getTyped(&w, catalogRef, 1, &out)).?;
    catalogRef = (try deleteTyped(&w, catalogRef, 1, va)).ok;
    try testing.expect(!(try linkSetContains(&w, catalogRef, 2, 1, a.row)));
    try testing.expect(!(try linkSetContains(&w, catalogRef, 3, 1, a.row)));
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&w, catalogRef, 2, 1));
    w.deinit();
}

test "deleting a to-many linker cleans its backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_linker.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    catalogRef = a.catalogRef;
    const b = try insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link_set = &.{a.row} } });
    catalogRef = b.catalogRef;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, catalogRef, 1, a.row));
    // Delete b (the linker): no lingering backlink on a's objectKey.
    var out: [2]Value = undefined;
    const vb = (try getTyped(&w, catalogRef, 2, &out)).?;
    catalogRef = (try deleteTyped(&w, catalogRef, 2, vb)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, catalogRef, 1, a.row));
    w.deinit();
}

test "to-many links persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset3.airdb");
    defer testing.allocator.free(path);
    var hub_row: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
        const hub = try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
        catalogRef = hub.catalogRef;
        hub_row = hub.row;
        var i: u64 = 2;
        while (i <= 30) : (i += 1) {
            const o = try insertTyped(&w, catalogRef, &.{ .{ .int = i }, .{ .link_set = &.{hub.row} } });
            catalogRef = o.catalogRef;
        }
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try testing.expectEqual(@as(u64, 29), try backlinkCount(&r, r.root(), 1, hub_row));
        try testing.expect(try linkSetContains(&r, r.root(), 15, 1, hub_row));
        r.end();
    }
}
