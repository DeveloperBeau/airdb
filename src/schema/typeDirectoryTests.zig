const std = @import("std");
const testing = std.testing;
const typeDirectory = @import("typeDirectory.zig");
const typeRouting = @import("typeRouting.zig");
const Database = @import("../database.zig").Database;
const catalog = @import("catalog.zig");
const collections = @import("../records/collections.zig");
const links = @import("../records/links.zig");
const Objects = @import("../records/objects.zig");
const rows = @import("../records/rows.zig");
const PropertyKind = catalog.PropertyKind;
const Value = typeDirectory.Value;
const createTypes = typeDirectory.createTypes;
const createWithDefinitions = typeDirectory.createWithDefinitions;
const create = typeDirectory.create;
const typeCount = typeDirectory.typeCount;
const catalogRef = typeDirectory.catalogRef;
const setCatalogRef = typeDirectory.setCatalogRef;
const addTypeDefinitions = typeDirectory.addTypeDefinitions;
const addType = typeDirectory.addType;
const isEmbedded = typeDirectory.isEmbedded;
const validate = typeDirectory.validate;
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
const deleteNullifyCrossType = typeRouting.deleteNullifyCrossType;
const insertEmbedded = typeDirectory.insertEmbedded;
const clearEmbedded = typeDirectory.clearEmbedded;

fn tdTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "create builds a directory with one catalog per type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const schema = [_][]const catalog.PropertyKind{
        &.{ .int, .blob },
        &.{ .int, .int, .int },
    };
    const dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    const c0 = try catalogRef(&w, dir, 0);
    const c1 = try catalogRef(&w, dir, 1);
    try testing.expect(c0 != 0 and c1 != 0 and c0 != c1);
    try testing.expectEqual(@as(catalog.PropertyCount, 2), (try catalog.loadCatalog(&w, c0)).propertyCount);
    try testing.expectEqual(@as(catalog.PropertyCount, 3), (try catalog.loadCatalog(&w, c1)).propertyCount);
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
    const schema = [_][]const catalog.PropertyKind{&.{ .int, .int }};
    const dir = try create(&w, &schema);
    try testing.expectError(error.NoSuchType, catalogRef(&w, dir, 5));
    w.deinit();
}

test "validate accepts a matching schema and rejects a mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td2.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const catalog.PropertyKind{ &.{ .int, .blob }, &.{ .int, .int, .int } };
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
        const fewer = [_][]const catalog.PropertyKind{&.{ .int, .blob }};
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &fewer));
        const wrongKind = [_][]const catalog.PropertyKind{ &.{ .int, .int }, &.{ .int, .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrongKind));
        const wrongCount = [_][]const catalog.PropertyKind{ &.{ .int, .blob }, &.{ .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrongCount));
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
    const schema = [_][]const PropertyKind{ &.{ .int, .blob }, &.{ .int, .int } };
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
    const schema = [_][]const PropertyKind{ &.{ .int, .blob }, &.{ .int, .int } };
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var dir = try create(&w, &schema);
        var i: u64 = 0;
        var buffer: [16]u8 = undefined;
        while (i < 300) : (i += 1) {
            const s = try std.fmt.bufPrint(&buffer, "p{d}", .{i});
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
    const schema = [_][]const PropertyKind{&.{ .int, .blob }};
    var dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 1), try typeCount(&w, dir));
    const added = try addType(&w, dir, &.{ .int, .int, .int });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 1), added.typeId);
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
    const PD = catalog.PropertyDefinition;
    // type 0: scalar (int primaryKey, blob name); type 1: int primaryKey + a to-one link + a to-many linkSet
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .link }, .{ .kind = .linkSet } },
    };
    var dir = try createWithDefinitions(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));

    // insert two type-1 rows; row a links to nothing, b's set links to a.
    const a = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 10 }, .{ .link = null }, .{ .linkSet = &.{} } });
    dir = try setCatalogRef(&w, dir, 1, a.catalogRef);
    const b = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 20 }, .{ .link = a.objectKey }, .{ .linkSet = &.{a.objectKey} } });
    dir = try setCatalogRef(&w, dir, 1, b.catalogRef);

    // route a to-many add through the directory
    dir = try linkSetAdd(&w, dir, 1, 20, 2, a.objectKey); // already member -> no-op
    try testing.expect(try linkSetContains(&w, dir, 1, 20, 2, a.objectKey));
    try testing.expectEqual(@as(?u64, a.objectKey), try getLink(&w, dir, 1, 20, 1));
    // a has 2 inbound to-one? no: only b's to-one links a -> backlink on property 1 == 1
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, dir, 1, 1, a.objectKey));

    // addTypeDefinitions: append a type with a list property
    const added = try addTypeDefinitions(&w, dir, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 2), added.typeId);
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 1 }, .{ .listInt = &.{ 7, 8, 9 } } })).dir;
    try testing.expectEqual(@as(?u64, 3), try collections.listLength(&w, try catalogRef(&w, dir, 2), 1, 1));
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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefinitions(&w, &schema);

    const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = ains.dir;
    const authorObjectKey = ains.objectKey;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).dir;

    const r = (try resolveLink(&w, dir, 1, 1, 1)).?;
    try testing.expectEqual(@as(u16, 0), r.targetType);
    try testing.expectEqual(authorObjectKey, r.objectKey);

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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefinitions(&w, &schema);

    const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = ains.dir;
    const authorObjectKey = ains.objectKey;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 2 }, .{ .link = authorObjectKey } })).dir;

    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, dir, 1, 1, authorObjectKey));

    var abuf: [2]Value = undefined;
    const authorVersion = (try get(&w, dir, 0, 1, &abuf)).?;
    const dres = try deleteNullifyCrossType(&w, dir, 0, 1, authorVersion);
    dir = dres.ok;

    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 1, 1, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&w, dir, 1, 2, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, dir, 1, 1, authorObjectKey));
    w.deinit();
}

test "cross-type links persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx3.airdb");
    defer testing.allocator.free(path);
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var authorObjectKey: u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var dir = try createWithDefinitions(&w, &schema);
        const ains = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
        dir = ains.dir;
        authorObjectKey = ains.objectKey;
        var i: u64 = 1;
        while (i <= 20) : (i += 1) {
            dir = (try insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = authorObjectKey } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        try testing.expectEqual(@as(u64, 20), try backlinkCount(&r, r.root(), 1, 1, authorObjectKey));
        const res = (try resolveLink(&r, r.root(), 1, 7, 1)).?;
        try testing.expectEqual(@as(u16, 0), res.targetType);
        try testing.expectEqual(authorObjectKey, res.objectKey);
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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .block } }, // Book.author (block)
    };
    var dir = try createWithDefinitions(&w, &schema);
    const author = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = author.dir;
    const book = try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = author.objectKey } });
    dir = book.dir;

    var av: [2]Value = undefined;
    const aver = (try get(&w, dir, 0, 1, &av)).?;
    const blocked = try deleteNullifyCrossType(&w, dir, 0, 1, aver);
    try testing.expect(blocked == .blocked);
    try testing.expect((try get(&w, dir, 0, 1, &av)) != null); // author still there

    // Remove the book, then the author deletes fine.
    var bv: [2]Value = undefined;
    const versionB = (try get(&w, dir, 1, 1, &bv)).?;
    const dbk = try deleteNullifyCrossType(&w, dir, 1, 1, versionB);
    dir = dbk.ok;
    const aver2 = (try get(&w, dir, 0, 1, &av)).?;
    const da = try deleteNullifyCrossType(&w, dir, 0, 1, aver2);
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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .linkSet, .linkTarget = 1, .deletionRule = .cascade } }, // Parent.children
        &.{.{ .kind = .int }}, // Child
    };
    var dir = try createWithDefinitions(&w, &schema);
    const c1 = try insert(&w, dir, 1, &.{.{ .int = 10 }});
    dir = c1.dir;
    const c2 = try insert(&w, dir, 1, &.{.{ .int = 20 }});
    dir = c2.dir;
    const c3 = try insert(&w, dir, 1, &.{.{ .int = 30 }});
    dir = c3.dir;
    const parent = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .linkSet = &.{ c1.objectKey, c2.objectKey, c3.objectKey } } });
    dir = parent.dir;
    try testing.expectEqual(@as(u64, 3), try liveCount(&w, dir, 1));

    var pv: [2]Value = undefined;
    const pver = (try get(&w, dir, 0, 1, &pv)).?;
    const dp = try deleteNullifyCrossType(&w, dir, 0, 1, pver);
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
    const PD = catalog.PropertyDefinition;
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

const embeddedOwnerSchema = [_][]const catalog.PropertyDefinition{
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .cascade } }, // 0: owner
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
    var dir = try createTypes(&w, &embeddedOwnerSchema, &.{ false, true });

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
    var dir = try createTypes(&w, &embeddedOwnerSchema, &.{ false, true });

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
    var dir = try createTypes(&w, &embeddedOwnerSchema, &.{ false, true });

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
    var dir = try createTypes(&w, &embeddedOwnerSchema, &.{ false, true });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });

    var ov: [2]Value = undefined;
    const ownerVersion = (try get(&w, dir, 0, 1, &ov)).?;
    const dres = try deleteNullifyCrossType(&w, dir, 0, 1, ownerVersion);
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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var dir = try createWithDefinitions(&w, &schema);

    // A throwaway author opens a dead slot for the real author to move into.
    const throwaway = try insert(&w, dir, 0, &.{ .{ .int = 99 }, .{ .bytes = "tmp" } });
    dir = throwaway.dir;
    const throwawayObjectKey = throwaway.objectKey;

    const author = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    dir = author.dir;
    const authorObjectKey = author.objectKey;

    // A book links the real author by its stable objectKey.
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).dir;
    try testing.expectEqual(@as(?u64, authorObjectKey), try getLink(&w, dir, 1, 1, 1));

    // Free the throwaway's physical slot, then relocate the author into it.
    const authorCatalog = try catalogRef(&w, dir, 0);
    const deadRow = (try catalog.objectKeyToRow(&w, authorCatalog, throwawayObjectKey)).?;
    var vbuf: [2]Value = undefined;
    const tv = (try get(&w, dir, 0, 99, &vbuf)).?;
    const dthrow = try delete(&w, dir, 0, 99, tv);
    dir = dthrow.ok;
    const relocated = try relocation.relocateRow(&w, try catalogRef(&w, dir, 0), authorObjectKey, deadRow);
    dir = try setCatalogRef(&w, dir, 0, relocated);

    // Deleting the author must nullify the book's link, proving the delete used
    // the object key rather than a stale physical row.
    var abuf: [2]Value = undefined;
    const authorVersion = (try get(&w, dir, 0, 1, &abuf)).?;
    const dres = try deleteNullifyCrossType(&w, dir, 0, 1, authorVersion);
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
        var dir = try createWithDefinitions(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .block } },
        });
        const a = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        dir = a.dir;
        dir = try setLink(&w, dir, 0, 1, 1, a.objectKey);
        w.setRoot(dir);
        _ = try w.commit();
    }
    // Deleting it in a LATER transaction must succeed: the self-link neither
    // blocks nor invalidates the version the caller read.
    {
        var w = try database.beginWrite();
        var out: [2]Value = undefined;
        const version = (try get(&w, w.newRoot, 0, 1, &out)).?;
        const res = try deleteNullifyCrossType(&w, w.newRoot, 0, 1, version);
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
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .cascade } }, // Node.next (self type)
    };
    var dir = try createWithDefinitions(&w, &schema);
    const a = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    dir = a.dir;
    const b = try insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .link = a.objectKey } }); // b -> a
    dir = b.dir;
    dir = try setLink(&w, dir, 0, 1, 1, b.objectKey); // a -> b (cycle)
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, dir, 0));

    var av: [2]Value = undefined;
    const aver = (try get(&w, dir, 0, 1, &av)).?;
    const da = try deleteNullifyCrossType(&w, dir, 0, 1, aver); // must terminate
    dir = da.ok;
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, dir, 0)); // both gone
    w.deinit();
}

test "a directory delete of a self-referencing linkSet row frees its set root exactly once" {
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
        var dir = try createWithDefinitions(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .linkSet, .linkTarget = 0 } },
        });
        const ins = try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
        dir = ins.dir;
        dir = try linkSetAdd(&w, dir, 0, 1, 1, ins.objectKey); // set contains own objectKey
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var out: [2]Value = undefined;
    const version = (try get(&w, w.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&w, w.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (w.transactionReuse.extents.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (w.inFlightFrees.items) |e| {
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
        var dir = try createWithDefinitions(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int }, .{ .kind = .list, .element = .int } },
        });
        dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .setInt = &.{ 1, 2, 3 } }, .{ .listInt = &.{ 7, 8, 9 } } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var raw: [3]u64 = undefined;
    _ = (try rows.getByPrimaryKey(&w, try catalogRef(&w, w.newRoot, 0), 1, &raw)).?;
    var out: [3]Value = undefined;
    const version = (try get(&w, w.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&w, w.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
    var freedSet = false;
    var freedList = false;
    for (w.inFlightFrees.items) |e| {
        if (e.offset == raw[1]) freedSet = true;
        if (e.offset == raw[2]) freedList = true;
    }
    for (w.transactionReuse.extents.items) |e| {
        if (e.offset == raw[1]) freedSet = true;
        if (e.offset == raw[2]) freedList = true;
    }
    try testing.expect(freedSet);
    try testing.expect(freedList);
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
        var dir = try createWithDefinitions(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .cascade } }, // 0: owner
            &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } }, // 1: child
        });
        const child = try insert(&w, dir, 1, &.{ .{ .int = 100 }, .{ .setInt = &.{ 1, 2, 3 } } });
        dir = child.dir;
        dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = child.objectKey } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    var w = try database.beginWrite();
    defer w.deinit();
    var raw: [2]u64 = undefined;
    _ = (try rows.getByPrimaryKey(&w, try catalogRef(&w, w.newRoot, 1), 100, &raw)).?;
    var out: [2]Value = undefined;
    const version = (try get(&w, w.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&w, w.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, res.ok, 1)); // child cascaded
    var freedChildSet = false;
    for (w.inFlightFrees.items) |e| {
        if (e.offset == raw[1]) freedChildSet = true;
    }
    for (w.transactionReuse.extents.items) |e| {
        if (e.offset == raw[1]) freedChildSet = true;
    }
    try testing.expect(freedChildSet);
}

const embeddedBlockSchema = [_][]const catalog.PropertyDefinition{
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .cascade } }, // 0: owner
    &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 1: embedded child
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .block } }, // 2: blocker
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
    var dir = try createTypes(&w, &embeddedBlockSchema, &.{ false, true, false });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "old" } });
    const childObjectKey = (try getLink(&w, dir, 0, 1, 1)).?;
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 5 }, .{ .link = childObjectKey } })).dir;

    try testing.expectError(error.Blocked, insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 200 }, .{ .bytes = "new" } }));
    // Old child intact and still owned.
    try testing.expectEqual(@as(?u64, childObjectKey), try getLink(&w, dir, 0, 1, 1));
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
    var dir = try createTypes(&w, &embeddedBlockSchema, &.{ false, true, false });

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } })).dir;
    dir = try insertEmbedded(&w, dir, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });
    const childObjectKey = (try getLink(&w, dir, 0, 1, 1)).?;
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 5 }, .{ .link = childObjectKey } })).dir;

    try testing.expectError(error.Blocked, clearEmbedded(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(?u64, childObjectKey), try getLink(&w, dir, 0, 1, 1));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
}
