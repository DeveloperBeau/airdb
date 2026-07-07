const std = @import("std");
const testing = std.testing;
const typedir = @import("typeDirectory.zig");
const typeRouting = @import("typeRouting.zig");
const Database = @import("../database.zig").Database;
const catalog = @import("catalog.zig");
const collections = @import("../records/collections.zig");
const links = @import("../records/links.zig");
const Objects = @import("../records/objects.zig");
const rows = @import("../records/rows.zig");
const PropKind = catalog.PropKind;
const Value = typedir.Value;
const createTypes = typedir.createTypes;
const createWithDefs = typedir.createWithDefs;
const create = typedir.create;
const typeCount = typedir.typeCount;
const catalogRef = typedir.catalogRef;
const setCatalogRef = typedir.setCatalogRef;
const addTypeDefs = typedir.addTypeDefs;
const addType = typedir.addType;
const isEmbedded = typedir.isEmbedded;
const validate = typedir.validate;
const insert = typeRouting.insert;
const get = typeRouting.get;
const update = typeRouting.update;
const delete = typeRouting.delete;
const liveCount = typeRouting.liveCount;
const getLink = typeRouting.getLink;
const setLink = typeRouting.setLink;
const backlinkCount = typeRouting.backlinkCount;
const linkSetAdd = typeRouting.linkSetAdd;
const linkSetContains = typeRouting.linkSetContains;
const resolveLink = typeRouting.resolveLink;
const getLinked = typeRouting.getLinked;
const deleteNullifyX = typeRouting.deleteNullifyX;
const insertEmbedded = typedir.insertEmbedded;
const clearEmbedded = typedir.clearEmbedded;

fn tdTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "create builds a directory with one catalog per type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const schema = [_][]const catalog.PropKind{
        &.{ .int, .blob },
        &.{ .int, .int, .int },
    };
    const dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    const c0 = try catalogRef(&w, dir, 0);
    const c1 = try catalogRef(&w, dir, 1);
    try testing.expect(c0 != 0 and c1 != 0 and c0 != c1);
    try testing.expectEqual(@as(catalog.PropCount, 2), (try catalog.loadCatalog(&w, c0)).prop_count);
    try testing.expectEqual(@as(catalog.PropCount, 3), (try catalog.loadCatalog(&w, c1)).prop_count);
    w.deinit();
}

test "catalogRef rejects an out-of-range type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1b.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const schema = [_][]const catalog.PropKind{&.{ .int, .int }};
    const dir = try create(&w, &schema);
    try testing.expectError(error.NoSuchType, catalogRef(&w, dir, 5));
    w.deinit();
}

test "validate accepts a matching schema and rejects a mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td2.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const catalog.PropKind{ &.{ .int, .blob }, &.{ .int, .int, .int } };
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        const dir = try create(&w, &schema);
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try validate(&r, r.root(), &schema); // matches
        const fewer = [_][]const catalog.PropKind{&.{ .int, .blob }};
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &fewer));
        const wrong_kind = [_][]const catalog.PropKind{ &.{ .int, .int }, &.{ .int, .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrong_kind));
        const wrong_count = [_][]const catalog.PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrong_count));
        r.end();
    }
}

test "two types route independently through the directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const schema = [_][]const PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
    var dir = try create(&w, &schema);

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .int = 42 } })).dir;

    var out0: [2]Value = undefined;
    _ = (try get(&w, dir, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    var out1: [2]Value = undefined;
    const ver1 = (try get(&w, dir, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 42), out1[1].int);

    const ur = try update(&w, dir, 1, 1, &.{ .{ .int = 1 }, .{ .int = 99 } }, ver1);
    dir = ur.ok.dir;
    _ = (try get(&w, dir, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 99), out1[1].int);
    _ = (try get(&w, dir, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    // delete type 0's row
    const v0 = (try get(&w, dir, 0, 1, &out0)).?;
    const dr = try delete(&w, dir, 0, 1, v0);
    dir = dr.ok;
    try testing.expectEqual(@as(?u64, null), try get(&w, dir, 0, 1, &out0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1)); // type 1 unaffected
    w.deinit();
}

test "multiple types persist across reopen and validate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td4.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var dir = try create(&w, &schema);
        var i: u64 = 0;
        var buf: [16]u8 = undefined;
        while (i < 300) : (i += 1) {
            const s = try std.fmt.bufPrint(&buf, "p{d}", .{i});
            dir = (try insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } })).dir;
            dir = (try insert(&w, dir, 1, &.{ .{ .int = i }, .{ .int = i * 10 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try validate(&r, r.root(), &schema);
        try testing.expectEqual(@as(u64, 300), try liveCount(&r, r.root(), 0));
        try testing.expectEqual(@as(u64, 300), try liveCount(&r, r.root(), 1));
        var out0: [2]Value = undefined;
        _ = (try get(&r, r.root(), 0, 250, &out0)).?;
        try testing.expectEqualStrings("p250", out0[1].bytes);
        var out1: [2]Value = undefined;
        _ = (try get(&r, r.root(), 1, 250, &out1)).?;
        try testing.expectEqual(@as(u64, 2500), out1[1].int);
        r.end();
    }
}

test "addType grows the directory and routes the new type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const schema = [_][]const PropKind{&.{ .int, .blob }};
    var dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 1), try typeCount(&w, dir));
    const added = try addType(&w, dir, &.{ .int, .int, .int });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 1), added.type_id);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    // old type still works; new type accepts rows
    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "x" } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } })).dir;
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
    var out: [3]Value = undefined;
    _ = (try get(&w, dir, 1, 1, &out)).?;
    try testing.expectEqual(@as(u64, 3), out[2].int);
    w.deinit();
}

test "multi-type directory carries links and collections via createWithDefs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    // type 0: scalar (int pk, blob name); type 1: int pk + a to-one link + a to-many link_set
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .link }, .{ .kind = .link_set } },
    };
    var dir = try createWithDefs(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));

    // insert two type-1 rows; row a links to nothing, b's set links to a.
    const a = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 10 }, .{ .link = null }, .{ .link_set = &.{} } });
    dir = try setCatalogRef(&w, dir, 1, a.cat);
    const b = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 20 }, .{ .link = a.row }, .{ .link_set = &.{a.row} } });
    dir = try setCatalogRef(&w, dir, 1, b.cat);

    // route a to-many add through the directory
    dir = try linkSetAdd(&w, dir, 1, 20, 2, a.row); // already member -> no-op
    try testing.expect(try linkSetContains(&w, dir, 1, 20, 2, a.row));
    try testing.expectEqual(@as(?u64, a.row), try getLink(&w, dir, 1, 20, 1));
    // a has 2 inbound to-one? no: only b's to-one links a -> backlink on prop 1 == 1
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, dir, 1, 1, a.row));

    // addTypeDefs: append a type with a list property
    const added = try addTypeDefs(&w, dir, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 2), added.type_id);
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 1 }, .{ .list_int = &.{ 7, 8, 9 } } })).dir;
    try testing.expectEqual(@as(?u64, 3), try collections.listLen(&w, try catalogRef(&w, dir, 2), 1, 1));
    w.deinit();
}

test "a cross-type link resolves to the target type's object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefs(&w, &schema);

    const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = ains.dir;
    const author_okey = ains.row;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = author_okey } })).dir;

    const r = (try resolveLink(&w, dir, 1, 1, 1)).?;
    try testing.expectEqual(@as(u16, 0), r.target_type);
    try testing.expectEqual(author_okey, r.okey);

    var out: [2]Value = undefined;
    _ = (try getLinked(&w, dir, 1, 1, 1, &out)).?;
    try testing.expectEqualStrings("Ada", out[1].bytes);
    w.deinit();
}

test "deleting a target nullifies inbound links from another type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefs(&w, &schema);

    const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = ains.dir;
    const author_okey = ains.row;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = author_okey } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 2 }, .{ .link = author_okey } })).dir;

    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, dir, 1, 1, author_okey));

    var abuf: [2]Value = undefined;
    const author_ver = (try get(&w, dir, 0, 1, &abuf)).?;
    const dres = try deleteNullifyX(&w, dir, 0, 1, author_ver);
    dir = dres.ok;

    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 1, 1, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 1, 2, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, dir, 1, 1, author_okey));
    w.deinit();
}

test "cross-type links persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx3.airdb");
    defer testing.allocator.free(path);
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book.author -> Author
    };
    var author_okey: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var dir = try createWithDefs(&w, &schema);
        const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
        dir = ains.dir;
        author_okey = ains.row;
        var i: u64 = 1;
        while (i <= 20) : (i += 1) {
            dir = (try insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = author_okey } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try testing.expectEqual(@as(u64, 20), try backlinkCount(&r, r.root(), 1, 1, author_okey));
        const res = (try resolveLink(&r, r.root(), 1, 7, 1)).?;
        try testing.expectEqual(@as(u16, 0), res.target_type);
        try testing.expectEqual(author_okey, res.okey);
        var out: [2]Value = undefined;
        _ = (try getLinked(&r, r.root(), 1, 13, 1, &out)).?;
        try testing.expectEqualStrings("Ada", out[1].bytes);
        r.end();
    }
}

test "block prevents deleting a referenced object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "block1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0, .del_rule = .block } }, // Book.author (block)
    };
    var dir = try createWithDefs(&w, &schema);
    const author = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = author.dir;
    const book = try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = author.row } });
    dir = book.dir;

    var av: [2]Value = undefined;
    const aver = (try get(&w, dir, 0, 1, &av)).?;
    const blocked = try deleteNullifyX(&w, dir, 0, 1, aver);
    try testing.expect(blocked == .blocked);
    try testing.expect((try get(&w, dir, 0, 1, &av)) != null); // author still there

    // Remove the book, then the author deletes fine.
    var bv: [2]Value = undefined;
    const bver = (try get(&w, dir, 1, 1, &bv)).?;
    const dbk = try deleteNullifyX(&w, dir, 1, 1, bver);
    dir = dbk.ok;
    const aver2 = (try get(&w, dir, 0, 1, &av)).?;
    const da = try deleteNullifyX(&w, dir, 0, 1, aver2);
    try testing.expect(da == .ok);
    dir = da.ok;
    try testing.expectEqual(@as(?u64, null), try get(&w, dir, 0, 1, &av));
    w.deinit();
}

test "cascade deletes owned children" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "cascade1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .link_set, .link_target = 1, .del_rule = .cascade } }, // Parent.children
        &.{.{ .kind = .int }}, // Child
    };
    var dir = try createWithDefs(&w, &schema);
    const c1 = try insert(&w, dir, 1, &.{.{ .int = 10 }});
    dir = c1.dir;
    const c2 = try insert(&w, dir, 1, &.{.{ .int = 20 }});
    dir = c2.dir;
    const c3 = try insert(&w, dir, 1, &.{.{ .int = 30 }});
    dir = c3.dir;
    const parent = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link_set = &.{ c1.row, c2.row, c3.row } } });
    dir = parent.dir;
    try testing.expectEqual(@as(u64, 3), try liveCount(&w, dir, 1));

    var pv: [2]Value = undefined;
    const pver = (try get(&w, dir, 0, 1, &pv)).?;
    const dp = try deleteNullifyX(&w, dir, 0, 1, pver);
    dir = dp.ok;
    try testing.expectEqual(@as(?u64, null), try get(&w, dir, 0, 1, &pv)); // parent gone
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, dir, 1)); // all children gone
    w.deinit();
}

test "directory records per-type embedded flags" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .int } },
    };
    var dir = try createTypes(&w, &schema, &.{ false, true });
    try testing.expectEqual(false, try isEmbedded(&w, dir, 0));
    try testing.expectEqual(true, try isEmbedded(&w, dir, 1));

    // A setCatalogRef (via insert) rebuilds the node; flags must survive.
    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "x" } })).dir;
    try testing.expectEqual(false, try isEmbedded(&w, dir, 0));
    try testing.expectEqual(true, try isEmbedded(&w, dir, 1));
    w.deinit();
}

const embedded_owner_schema = [_][]const catalog.PropDef{
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 1, .del_rule = .cascade } }, // 0: owner
    &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 1: embedded child
};

test "insertEmbedded creates an owned child reachable from the owner" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var dir = try createTypes(&w, &embedded_owner_schema, &.{ false, true });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });

    var out: [2]Value = undefined;
    _ = (try getLinked(&w, dir, 0, 1, 1, &out)).?;
    try testing.expectEqualStrings("note", out[1].bytes);
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
    w.deinit();
}

test "clearEmbedded deletes the owned child" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var dir = try createTypes(&w, &embedded_owner_schema, &.{ false, true });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });
    dir = try clearEmbedded(&w, dir, 0, 1, 1);

    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, dir, 1));
    w.deinit();
}

test "replacing an embedded child deletes the old one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var dir = try createTypes(&w, &embedded_owner_schema, &.{ false, true });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 1 }, .{ .bytes = "first" } });
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 2 }, .{ .bytes = "second" } });

    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
    var out: [2]Value = undefined;
    _ = (try getLinked(&w, dir, 0, 1, 1, &out)).?;
    try testing.expectEqualStrings("second", out[1].bytes);
    w.deinit();
}

test "deleting the owner cascades to the embedded child" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var dir = try createTypes(&w, &embedded_owner_schema, &.{ false, true });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });

    var ov: [2]Value = undefined;
    const owner_ver = (try get(&w, dir, 0, 1, &ov)).?;
    const dres = try deleteNullifyX(&w, dir, 0, 1, owner_ver);
    dir = dres.ok;
    try testing.expectEqual(@as(?u64, null), try get(&w, dir, 0, 1, &ov));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, dir, 1));
    w.deinit();
}

test "directory delete works after relocating the target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "reloc_del.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefs(&w, &schema);

    // A throwaway author opens a dead slot for the real author to move into.
    const throwaway = try insert(&w, dir, 0, &.{ .{ .int = 99 }, .{ .bytes = "tmp" } });
    dir = throwaway.dir;
    const throwaway_okey = throwaway.row;

    const author = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = author.dir;
    const author_okey = author.row;

    // A book links the real author by its stable okey.
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = author_okey } })).dir;
    try testing.expectEqual(@as(?u64, author_okey), try getLink(&w, dir, 1, 1, 1));

    // Free the throwaway's physical slot, then relocate the author into it.
    const author_cat = try catalogRef(&w, dir, 0);
    const dead_row = (try catalog.okeyToRow(&w, author_cat, throwaway_okey)).?;
    var vbuf: [2]Value = undefined;
    const tv = (try get(&w, dir, 0, 99, &vbuf)).?;
    const dthrow = try delete(&w, dir, 0, 99, tv);
    dir = dthrow.ok;
    const relocated = try relocation.relocateRow(&w, try catalogRef(&w, dir, 0), author_okey, dead_row);
    dir = try setCatalogRef(&w, dir, 0, relocated);

    // Deleting the author must nullify the book's link, proving the delete used
    // the object key rather than a stale physical row.
    var abuf: [2]Value = undefined;
    const author_ver = (try get(&w, dir, 0, 1, &abuf)).?;
    const dres = try deleteNullifyX(&w, dir, 0, 1, author_ver);
    dir = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 1, 1, 1));
    w.deinit();
}

const relocation = @import("../storage/relocation.zig");

test "a self-linked object is deletable across transactions" {
    // Two regressions in one shape: (a) a block-rule self-link counted itself
    // and refused the delete forever; (b) the nullify version bump stamped the
    // row being deleted, so the follow-up tombstone's version check failed
    // forever. Both must not block a self-linked delete.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "selflink.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a row that links to ITSELF via a block-rule property.
    {
        var w = try database.beginWrite();
        var dir = try createWithDefs(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0, .del_rule = .block } },
        });
        const a = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        dir = a.dir;
        dir = try setLink(&w, dir, 0, 1, 1, a.row);
        w.setRoot(dir);
        _ = try w.commit();
    }
    // Deleting it in a LATER transaction must succeed: the self-link neither
    // blocks nor invalidates the version the caller read.
    {
        var w = try database.beginWrite();
        var out: [2]Value = undefined;
        const ver = (try get(&w, w.new_root, 0, 1, &out)).?;
        const res = try deleteNullifyX(&w, w.new_root, 0, 1, ver);
        try testing.expect(res == .ok);
        w.setRoot(res.ok);
        _ = try w.commit();
    }
    var r = try database.beginRead();
    defer r.end();
    try testing.expectEqual(@as(u64, 0), try liveCount(&r, r.root(), 0));
    // A FOREIGN block-rule source must still block, self-exemption or not.
    // (covered by the existing "block prevents deleting a referenced object")
}

test "cascade is cycle-safe" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "cascade2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const PD = catalog.PropDef;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0, .del_rule = .cascade } }, // Node.next (self type)
    };
    var dir = try createWithDefs(&w, &schema);
    const a = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    dir = a.dir;
    const b = try insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .link = a.row } }); // b -> a
    dir = b.dir;
    dir = try setLink(&w, dir, 0, 1, 1, b.row); // a -> b (cycle)
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, dir, 0));

    var av: [2]Value = undefined;
    const aver = (try get(&w, dir, 0, 1, &av)).?;
    const da = try deleteNullifyX(&w, dir, 0, 1, aver); // must terminate
    dir = da.ok;
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, dir, 0)); // both gone
    w.deinit();
}

test "a directory delete of a self-referencing link_set row frees its set root exactly once" {
    // Directory-path variant of the objects-layer regression: deleteWorker now
    // reclaims the row's collection storage, so the inbound nullify must not
    // COW (and thereby free) the dying row's own set root first.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "selfset_dir.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var w = try database.beginWrite();
        var dir = try createWithDefs(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link_set, .link_target = 0 } },
        });
        const ins = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
        dir = ins.dir;
        dir = try linkSetAdd(&w, dir, 0, 1, 1, ins.row); // set contains own okey
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var out: [2]Value = undefined;
    const ver = (try get(&w, w.new_root, 0, 1, &out)).?;
    const res = try deleteNullifyX(&w, w.new_root, 0, 1, ver);
    try testing.expect(res == .ok);
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

test "a directory delete frees the row's collection storage" {
    // Regression: deleteWorker tombstoned via the raw delete and never freed
    // the row's collection trees -- every directory-path delete leaked them
    // permanently. The captured roots must show up among the freed extents.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "dircoll.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var w = try database.beginWrite();
        var dir = try createWithDefs(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int }, .{ .kind = .list, .elem = .int } },
        });
        dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .set_int = &.{ 1, 2, 3 } }, .{ .list_int = &.{ 7, 8, 9 } } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var raw: [3]u64 = undefined;
    _ = (try rows.getByPk(&w, try catalogRef(&w, w.new_root, 0), 1, &raw)).?;
    var out: [3]Value = undefined;
    const ver = (try get(&w, w.new_root, 0, 1, &out)).?;
    const res = try deleteNullifyX(&w, w.new_root, 0, 1, ver);
    try testing.expect(res == .ok);
    var freed_set = false;
    var freed_list = false;
    for (w.in_flight_frees.items) |e| {
        if (e.offset == raw[1]) freed_set = true;
        if (e.offset == raw[2]) freed_list = true;
    }
    for (w.transactionReuse.extents.items) |e| {
        if (e.offset == raw[1]) freed_set = true;
        if (e.offset == raw[2]) freed_list = true;
    }
    try testing.expect(freed_set);
    try testing.expect(freed_list);
}

test "a cascade delete frees the child's collection storage" {
    // Regression: cascade-deleted children go through deleteWorker, which
    // leaked their collection trees; the child's set root must be freed.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "casccoll.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var w = try database.beginWrite();
        var dir = try createWithDefs(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 1, .del_rule = .cascade } }, // 0: owner
            &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } }, // 1: child
        });
        const child = try insert(&w, dir, 1, &.{ .{ .int = 100 }, .{ .set_int = &.{ 1, 2, 3 } } });
        dir = child.dir;
        dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = child.row } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var raw: [2]u64 = undefined;
    _ = (try rows.getByPk(&w, try catalogRef(&w, w.new_root, 1), 100, &raw)).?;
    var out: [2]Value = undefined;
    const ver = (try get(&w, w.new_root, 0, 1, &out)).?;
    const res = try deleteNullifyX(&w, w.new_root, 0, 1, ver);
    try testing.expect(res == .ok);
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, res.ok, 1)); // child cascaded
    var freed_child_set = false;
    for (w.in_flight_frees.items) |e| {
        if (e.offset == raw[1]) freed_child_set = true;
    }
    for (w.transactionReuse.extents.items) |e| {
        if (e.offset == raw[1]) freed_child_set = true;
    }
    try testing.expect(freed_child_set);
}

const embedded_block_schema = [_][]const catalog.PropDef{
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 1, .del_rule = .cascade } }, // 0: owner
    &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 1: embedded child
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 1, .del_rule = .block } }, // 2: blocker
};

test "replacing an embedded child surfaces a blocked delete" {
    // Regression: the refused delete of the old child was swallowed and the
    // new child linked anyway -- two live children, one of them ownerless,
    // breaking the single-owner invariant.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "embblock1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var dir = try createTypes(&w, &embedded_block_schema, &.{ false, true, false });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "old" } });
    const child_okey = (try getLink(&w, dir, 0, 1, 1)).?;
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 5 }, .{ .link = child_okey } })).dir;

    try testing.expectError(error.Blocked, insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 200 }, .{ .bytes = "new" } }));
    // Old child intact and still owned.
    try testing.expectEqual(@as(?u64, child_okey), try getLink(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
}

test "clearing an embedded child surfaces a blocked delete" {
    // Regression: a refused clear returned the unchanged directory, reading as
    // success while the child and its owning link silently survived.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "embblock2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var dir = try createTypes(&w, &embedded_block_schema, &.{ false, true, false });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });
    const child_okey = (try getLink(&w, dir, 0, 1, 1)).?;
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 5 }, .{ .link = child_okey } })).dir;

    try testing.expectError(error.Blocked, clearEmbedded(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(?u64, child_okey), try getLink(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
}
