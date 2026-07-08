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
const catalogReference = typeDirectory.catalogReference;
const setCatalogReference = typeDirectory.setCatalogReference;
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
    var writeTransaction = try database.beginWrite();
    const schema = [_][]const catalog.PropertyKind{
        &.{ .int, .blob },
        &.{ .int, .int, .int },
    };
    const directoryReference = try create(&writeTransaction, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&writeTransaction, directoryReference));
    const catalog0 = try catalogReference(&writeTransaction, directoryReference, 0);
    const catalog1 = try catalogReference(&writeTransaction, directoryReference, 1);
    try testing.expect(catalog0 != 0 and catalog1 != 0 and catalog0 != catalog1);
    try testing.expectEqual(@as(catalog.PropertyCount, 2), (try catalog.loadCatalog(&writeTransaction, catalog0)).propertyCount);
    try testing.expectEqual(@as(catalog.PropertyCount, 3), (try catalog.loadCatalog(&writeTransaction, catalog1)).propertyCount);
    writeTransaction.deinit();
}

test "catalogReference rejects an out-of-range type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1b.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const schema = [_][]const catalog.PropertyKind{&.{ .int, .int }};
    const directoryReference = try create(&writeTransaction, &schema);
    try testing.expectError(error.NoSuchType, catalogReference(&writeTransaction, directoryReference, 5));
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        const directoryReference = try create(&writeTransaction, &schema);
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try validate(&readTransaction, readTransaction.root(), &schema); // matches
        const fewer = [_][]const catalog.PropertyKind{&.{ .int, .blob }};
        try testing.expectError(error.SchemaMismatch, validate(&readTransaction, readTransaction.root(), &fewer));
        const wrongKind = [_][]const catalog.PropertyKind{ &.{ .int, .int }, &.{ .int, .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&readTransaction, readTransaction.root(), &wrongKind));
        const wrongCount = [_][]const catalog.PropertyKind{ &.{ .int, .blob }, &.{ .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&readTransaction, readTransaction.root(), &wrongCount));
        readTransaction.end();
    }
}

test "two types route independently through the directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const schema = [_][]const PropertyKind{ &.{ .int, .blob }, &.{ .int, .int } };
    var directoryReference = try create(&writeTransaction, &schema);

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } })).directoryReference;
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .int = 42 } })).directoryReference;

    var out0: [2]Value = undefined;
    _ = (try get(&writeTransaction, directoryReference, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    var out1: [2]Value = undefined;
    const ver1 = (try get(&writeTransaction, directoryReference, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 42), out1[1].int);

    const updateResult = try update(&writeTransaction, directoryReference, 1, 1, &.{ .{ .int = 1 }, .{ .int = 99 } }, ver1);
    directoryReference = updateResult.ok.directoryReference;
    _ = (try get(&writeTransaction, directoryReference, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 99), out1[1].int);
    _ = (try get(&writeTransaction, directoryReference, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    // delete type 0's row
    const version0 = (try get(&writeTransaction, directoryReference, 0, 1, &out0)).?;
    const deleteResult = try delete(&writeTransaction, directoryReference, 0, 1, version0);
    directoryReference = deleteResult.ok;
    try testing.expectEqual(@as(?u64, null), try get(&writeTransaction, directoryReference, 0, 1, &out0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1)); // type 1 unaffected
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try create(&writeTransaction, &schema);
        var index: u64 = 0;
        var buffer: [16]u8 = undefined;
        while (index < 300) : (index += 1) {
            const name = try std.fmt.bufPrint(&buffer, "p{d}", .{index});
            directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = index }, .{ .bytes = name } })).directoryReference;
            directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = index }, .{ .int = index * 10 } })).directoryReference;
        }
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try validate(&readTransaction, readTransaction.root(), &schema);
        try testing.expectEqual(@as(u64, 300), try liveCount(&readTransaction, readTransaction.root(), 0));
        try testing.expectEqual(@as(u64, 300), try liveCount(&readTransaction, readTransaction.root(), 1));
        var out0: [2]Value = undefined;
        _ = (try get(&readTransaction, readTransaction.root(), 0, 250, &out0)).?;
        try testing.expectEqualStrings("p250", out0[1].bytes);
        var out1: [2]Value = undefined;
        _ = (try get(&readTransaction, readTransaction.root(), 1, 250, &out1)).?;
        try testing.expectEqual(@as(u64, 2500), out1[1].int);
        readTransaction.end();
    }
}

test "addType grows the directory and routes the new type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const schema = [_][]const PropertyKind{&.{ .int, .blob }};
    var directoryReference = try create(&writeTransaction, &schema);
    try testing.expectEqual(@as(u16, 1), try typeCount(&writeTransaction, directoryReference));
    const added = try addType(&writeTransaction, directoryReference, &.{ .int, .int, .int });
    directoryReference = added.directoryReference;
    try testing.expectEqual(@as(u16, 1), added.typeId);
    try testing.expectEqual(@as(u16, 2), try typeCount(&writeTransaction, directoryReference));
    // old type still works; new type accepts rows
    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "x" } })).directoryReference;
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } })).directoryReference;
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1));
    var out: [3]Value = undefined;
    _ = (try get(&writeTransaction, directoryReference, 1, 1, &out)).?;
    try testing.expectEqual(@as(u64, 3), out[2].int);
    writeTransaction.deinit();
}

test "multi-type directory carries links and collections via createWithDefs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    // type 0: scalar (int primaryKey, blob name); type 1: int primaryKey + a to-one link + a to-many linkSet
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .link }, .{ .kind = .linkSet } },
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&writeTransaction, directoryReference));

    // insert two type-1 rows; row a links to nothing, b's set links to a.
    const insertedA = try Objects.insertTyped(&writeTransaction, try catalogReference(&writeTransaction, directoryReference, 1), &.{ .{ .int = 10 }, .{ .link = null }, .{ .linkSet = &.{} } });
    directoryReference = try setCatalogReference(&writeTransaction, directoryReference, 1, insertedA.catalogReference);
    const insertedB = try Objects.insertTyped(&writeTransaction, try catalogReference(&writeTransaction, directoryReference, 1), &.{ .{ .int = 20 }, .{ .link = insertedA.objectKey }, .{ .linkSet = &.{insertedA.objectKey} } });
    directoryReference = try setCatalogReference(&writeTransaction, directoryReference, 1, insertedB.catalogReference);

    // route a to-many add through the directory
    directoryReference = try linkSetAdd(&writeTransaction, directoryReference, 1, 20, 2, insertedA.objectKey); // already member -> no-op
    try testing.expect(try linkSetContains(&writeTransaction, directoryReference, 1, 20, 2, insertedA.objectKey));
    try testing.expectEqual(@as(?u64, insertedA.objectKey), try getLink(&writeTransaction, directoryReference, 1, 20, 1));
    // a has 2 inbound to-one? no: only b's to-one links a -> backlink on property 1 == 1
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&writeTransaction, directoryReference, 1, 1, insertedA.objectKey));

    // addTypeDefinitions: append a type with a list property
    const added = try addTypeDefinitions(&writeTransaction, directoryReference, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    directoryReference = added.directoryReference;
    try testing.expectEqual(@as(u16, 2), added.typeId);
    directoryReference = (try insert(&writeTransaction, directoryReference, 2, &.{ .{ .int = 1 }, .{ .listInt = &.{ 7, 8, 9 } } })).directoryReference;
    try testing.expectEqual(@as(?u64, 3), try collections.listLength(&writeTransaction, try catalogReference(&writeTransaction, directoryReference, 2), 1, 1));
    writeTransaction.deinit();
}

test "a cross-type link resolves to the target type's object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);

    const ains = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    directoryReference = ains.directoryReference;
    const authorObjectKey = ains.objectKey;
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).directoryReference;

    const readTransaction = (try resolveLink(&writeTransaction, directoryReference, 1, 1, 1)).?;
    try testing.expectEqual(@as(u16, 0), readTransaction.targetType);
    try testing.expectEqual(authorObjectKey, readTransaction.objectKey);

    var out: [2]Value = undefined;
    _ = (try getLinked(&writeTransaction, directoryReference, 1, 1, 1, &out)).?;
    try testing.expectEqualStrings("Ada", out[1].bytes);
    writeTransaction.deinit();
}

test "deleting a target nullifies inbound links from another type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "tdx2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);

    const ains = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    directoryReference = ains.directoryReference;
    const authorObjectKey = ains.objectKey;
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).directoryReference;
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 2 }, .{ .link = authorObjectKey } })).directoryReference;

    try testing.expectEqual(@as(u64, 2), try backlinkCount(&writeTransaction, directoryReference, 1, 1, authorObjectKey));

    var abuf: [2]Value = undefined;
    const authorVersion = (try get(&writeTransaction, directoryReference, 0, 1, &abuf)).?;
    const dres = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, authorVersion);
    directoryReference = dres.ok;

    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, directoryReference, 1, 1, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, directoryReference, 1, 2, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&writeTransaction, directoryReference, 1, 1, authorObjectKey));
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try createWithDefinitions(&writeTransaction, &schema);
        const ains = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
        directoryReference = ains.directoryReference;
        authorObjectKey = ains.objectKey;
        var index: u64 = 1;
        while (index <= 20) : (index += 1) {
            directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = index }, .{ .link = authorObjectKey } })).directoryReference;
        }
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, 20), try backlinkCount(&readTransaction, readTransaction.root(), 1, 1, authorObjectKey));
        const res = (try resolveLink(&readTransaction, readTransaction.root(), 1, 7, 1)).?;
        try testing.expectEqual(@as(u16, 0), res.targetType);
        try testing.expectEqual(authorObjectKey, res.objectKey);
        var out: [2]Value = undefined;
        _ = (try getLinked(&readTransaction, readTransaction.root(), 1, 13, 1, &out)).?;
        try testing.expectEqualStrings("Ada", out[1].bytes);
        readTransaction.end();
    }
}

test "block prevents deleting a referenced object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "block1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .block } }, // Book.author (block)
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);
    const author = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    directoryReference = author.directoryReference;
    const book = try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .link = author.objectKey } });
    directoryReference = book.directoryReference;

    var valuesA: [2]Value = undefined;
    const versionA = (try get(&writeTransaction, directoryReference, 0, 1, &valuesA)).?;
    const blocked = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, versionA);
    try testing.expect(blocked == .blocked);
    try testing.expect((try get(&writeTransaction, directoryReference, 0, 1, &valuesA)) != null); // author still there

    // Remove the book, then the author deletes fine.
    var valuesB: [2]Value = undefined;
    const versionB = (try get(&writeTransaction, directoryReference, 1, 1, &valuesB)).?;
    const deleteResultB = try deleteNullifyCrossType(&writeTransaction, directoryReference, 1, 1, versionB);
    directoryReference = deleteResultB.ok;
    const versionA2 = (try get(&writeTransaction, directoryReference, 0, 1, &valuesA)).?;
    const deleteResultA = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, versionA2);
    try testing.expect(deleteResultA == .ok);
    directoryReference = deleteResultA.ok;
    try testing.expectEqual(@as(?u64, null), try get(&writeTransaction, directoryReference, 0, 1, &valuesA));
    writeTransaction.deinit();
}

test "cascade deletes owned children" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "cascade1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .linkSet, .linkTarget = 1, .deletionRule = .cascade } }, // Parent.children
        &.{.{ .kind = .int }}, // Child
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);
    const child1 = try insert(&writeTransaction, directoryReference, 1, &.{.{ .int = 10 }});
    directoryReference = child1.directoryReference;
    const child2 = try insert(&writeTransaction, directoryReference, 1, &.{.{ .int = 20 }});
    directoryReference = child2.directoryReference;
    const child3 = try insert(&writeTransaction, directoryReference, 1, &.{.{ .int = 30 }});
    directoryReference = child3.directoryReference;
    const parent = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .linkSet = &.{ child1.objectKey, child2.objectKey, child3.objectKey } } });
    directoryReference = parent.directoryReference;
    try testing.expectEqual(@as(u64, 3), try liveCount(&writeTransaction, directoryReference, 1));

    var parentValues: [2]Value = undefined;
    const parentVersion = (try get(&writeTransaction, directoryReference, 0, 1, &parentValues)).?;
    const parentDelete = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, parentVersion);
    directoryReference = parentDelete.ok;
    try testing.expectEqual(@as(?u64, null), try get(&writeTransaction, directoryReference, 0, 1, &parentValues)); // parent gone
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, directoryReference, 1)); // all children gone
    writeTransaction.deinit();
}

test "directory records per-type embedded flags" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .int } },
    };
    var directoryReference = try createTypes(&writeTransaction, &schema, &.{ false, true });
    try testing.expectEqual(false, try isEmbedded(&writeTransaction, directoryReference, 0));
    try testing.expectEqual(true, try isEmbedded(&writeTransaction, directoryReference, 1));

    // A setCatalogReference (via insert) rebuilds the node; flags must survive.
    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "x" } })).directoryReference;
    try testing.expectEqual(false, try isEmbedded(&writeTransaction, directoryReference, 0));
    try testing.expectEqual(true, try isEmbedded(&writeTransaction, directoryReference, 1));
    writeTransaction.deinit();
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
    var writeTransaction = try database.beginWrite();
    var directoryReference = try createTypes(&writeTransaction, &embeddedOwnerSchema, &.{ false, true });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });

    var out: [2]Value = undefined;
    _ = (try getLinked(&writeTransaction, directoryReference, 0, 1, 1, &out)).?;
    try testing.expectEqualStrings("note", out[1].bytes);
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1));
    writeTransaction.deinit();
}

test "clearEmbedded deletes the owned child" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var directoryReference = try createTypes(&writeTransaction, &embeddedOwnerSchema, &.{ false, true });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });
    directoryReference = try clearEmbedded(&writeTransaction, directoryReference, 0, 1, 1);

    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, directoryReference, 0, 1, 1));
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, directoryReference, 1));
    writeTransaction.deinit();
}

test "replacing an embedded child deletes the old one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var directoryReference = try createTypes(&writeTransaction, &embeddedOwnerSchema, &.{ false, true });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 1 }, .{ .bytes = "first" } });
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 2 }, .{ .bytes = "second" } });

    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1));
    var out: [2]Value = undefined;
    _ = (try getLinked(&writeTransaction, directoryReference, 0, 1, 1, &out)).?;
    try testing.expectEqualStrings("second", out[1].bytes);
    writeTransaction.deinit();
}

test "deleting the owner cascades to the embedded child" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "emb5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var directoryReference = try createTypes(&writeTransaction, &embeddedOwnerSchema, &.{ false, true });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });

    var ownerValues: [2]Value = undefined;
    const ownerVersion = (try get(&writeTransaction, directoryReference, 0, 1, &ownerValues)).?;
    const dres = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, ownerVersion);
    directoryReference = dres.ok;
    try testing.expectEqual(@as(?u64, null), try get(&writeTransaction, directoryReference, 0, 1, &ownerValues));
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, directoryReference, 1));
    writeTransaction.deinit();
}

test "directory delete works after relocating the target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "reloc_del.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } }, // 1: Book.author -> Author
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);

    // A throwaway author opens a dead slot for the real author to move into.
    const throwaway = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 99 }, .{ .bytes = "tmp" } });
    directoryReference = throwaway.directoryReference;
    const throwawayObjectKey = throwaway.objectKey;

    const author = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } });
    directoryReference = author.directoryReference;
    const authorObjectKey = author.objectKey;

    // A book links the real author by its stable objectKey.
    directoryReference = (try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 1 }, .{ .link = authorObjectKey } })).directoryReference;
    try testing.expectEqual(@as(?u64, authorObjectKey), try getLink(&writeTransaction, directoryReference, 1, 1, 1));

    // Free the throwaway's physical slot, then relocate the author into it.
    const authorCatalog = try catalogReference(&writeTransaction, directoryReference, 0);
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, authorCatalog, throwawayObjectKey)).?;
    var vbuf: [2]Value = undefined;
    const throwawayVersion = (try get(&writeTransaction, directoryReference, 0, 99, &vbuf)).?;
    const throwawayDelete = try delete(&writeTransaction, directoryReference, 0, 99, throwawayVersion);
    directoryReference = throwawayDelete.ok;
    const relocated = try relocation.relocateRow(&writeTransaction, try catalogReference(&writeTransaction, directoryReference, 0), authorObjectKey, deadRow);
    directoryReference = try setCatalogReference(&writeTransaction, directoryReference, 0, relocated);

    // Deleting the author must nullify the book's link, proving the delete used
    // the object key rather than a stale physical row.
    var abuf: [2]Value = undefined;
    const authorVersion = (try get(&writeTransaction, directoryReference, 0, 1, &abuf)).?;
    const dres = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, authorVersion);
    directoryReference = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&writeTransaction, directoryReference, 1, 1, 1));
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try createWithDefinitions(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .block } },
        });
        const valueA = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        directoryReference = valueA.directoryReference;
        directoryReference = try setLink(&writeTransaction, directoryReference, 0, 1, 1, valueA.objectKey);
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    // Deleting it in a LATER transaction must succeed: the self-link neither
    // blocks nor invalidates the version the caller read.
    {
        var writeTransaction = try database.beginWrite();
        var out: [2]Value = undefined;
        const version = (try get(&writeTransaction, writeTransaction.newRoot, 0, 1, &out)).?;
        const res = try deleteNullifyCrossType(&writeTransaction, writeTransaction.newRoot, 0, 1, version);
        try testing.expect(res == .ok);
        writeTransaction.setRoot(res.ok);
        _ = try writeTransaction.commit();
    }
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    try testing.expectEqual(@as(u64, 0), try liveCount(&readTransaction, readTransaction.root(), 0));
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
    var writeTransaction = try database.beginWrite();
    const PD = catalog.PropertyDefinition;
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0, .deletionRule = .cascade } }, // Node.next (self type)
    };
    var directoryReference = try createWithDefinitions(&writeTransaction, &schema);
    const valueA = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } });
    directoryReference = valueA.directoryReference;
    const valueB = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .link = valueA.objectKey } }); // b -> a
    directoryReference = valueB.directoryReference;
    directoryReference = try setLink(&writeTransaction, directoryReference, 0, 1, 1, valueB.objectKey); // a -> b (cycle)
    try testing.expectEqual(@as(u64, 2), try liveCount(&writeTransaction, directoryReference, 0));

    var valuesA: [2]Value = undefined;
    const versionA = (try get(&writeTransaction, directoryReference, 0, 1, &valuesA)).?;
    const deleteResultA = try deleteNullifyCrossType(&writeTransaction, directoryReference, 0, 1, versionA); // must terminate
    directoryReference = deleteResultA.ok;
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, directoryReference, 0)); // both gone
    writeTransaction.deinit();
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try createWithDefinitions(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .linkSet, .linkTarget = 0 } },
        });
        const ins = try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
        directoryReference = ins.directoryReference;
        directoryReference = try linkSetAdd(&writeTransaction, directoryReference, 0, 1, 1, ins.objectKey); // set contains own objectKey
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var out: [2]Value = undefined;
    const version = (try get(&writeTransaction, writeTransaction.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&writeTransaction, writeTransaction.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try createWithDefinitions(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int }, .{ .kind = .list, .element = .int } },
        });
        directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .setInt = &.{ 1, 2, 3 } }, .{ .listInt = &.{ 7, 8, 9 } } })).directoryReference;
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var raw: [3]u64 = undefined;
    _ = (try rows.getByPrimaryKey(&writeTransaction, try catalogReference(&writeTransaction, writeTransaction.newRoot, 0), 1, &raw)).?;
    var out: [3]Value = undefined;
    const version = (try get(&writeTransaction, writeTransaction.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&writeTransaction, writeTransaction.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
    var freedSet = false;
    var freedList = false;
    for (writeTransaction.inFlightFrees.items) |item| {
        if (item.offset == raw[1]) freedSet = true;
        if (item.offset == raw[2]) freedList = true;
    }
    for (writeTransaction.transactionReuse.extents.items) |extent| {
        if (extent.offset == raw[1]) freedSet = true;
        if (extent.offset == raw[2]) freedList = true;
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
        var writeTransaction = try database.beginWrite();
        var directoryReference = try createWithDefinitions(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .cascade } }, // 0: owner
            &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } }, // 1: child
        });
        const child = try insert(&writeTransaction, directoryReference, 1, &.{ .{ .int = 100 }, .{ .setInt = &.{ 1, 2, 3 } } });
        directoryReference = child.directoryReference;
        directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = child.objectKey } })).directoryReference;
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var raw: [2]u64 = undefined;
    _ = (try rows.getByPrimaryKey(&writeTransaction, try catalogReference(&writeTransaction, writeTransaction.newRoot, 1), 100, &raw)).?;
    var out: [2]Value = undefined;
    const version = (try get(&writeTransaction, writeTransaction.newRoot, 0, 1, &out)).?;
    const res = try deleteNullifyCrossType(&writeTransaction, writeTransaction.newRoot, 0, 1, version);
    try testing.expect(res == .ok);
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, res.ok, 1)); // child cascaded
    var freedChildSet = false;
    for (writeTransaction.inFlightFrees.items) |item| {
        if (item.offset == raw[1]) freedChildSet = true;
    }
    for (writeTransaction.transactionReuse.extents.items) |extent| {
        if (extent.offset == raw[1]) freedChildSet = true;
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
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var directoryReference = try createTypes(&writeTransaction, &embeddedBlockSchema, &.{ false, true, false });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "old" } });
    const childObjectKey = (try getLink(&writeTransaction, directoryReference, 0, 1, 1)).?;
    directoryReference = (try insert(&writeTransaction, directoryReference, 2, &.{ .{ .int = 5 }, .{ .link = childObjectKey } })).directoryReference;

    try testing.expectError(error.Blocked, insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 200 }, .{ .bytes = "new" } }));
    // Old child intact and still owned.
    try testing.expectEqual(@as(?u64, childObjectKey), try getLink(&writeTransaction, directoryReference, 0, 1, 1));
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1));
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
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var directoryReference = try createTypes(&writeTransaction, &embeddedBlockSchema, &.{ false, true, false });

    directoryReference = (try insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
    directoryReference = try insertEmbedded(&writeTransaction, directoryReference, 0, 1, 1, &.{ .{ .int = 100 }, .{ .bytes = "note" } });
    const childObjectKey = (try getLink(&writeTransaction, directoryReference, 0, 1, 1)).?;
    directoryReference = (try insert(&writeTransaction, directoryReference, 2, &.{ .{ .int = 5 }, .{ .link = childObjectKey } })).directoryReference;

    try testing.expectError(error.Blocked, clearEmbedded(&writeTransaction, directoryReference, 0, 1, 1));
    try testing.expectEqual(@as(?u64, childObjectKey), try getLink(&writeTransaction, directoryReference, 0, 1, 1));
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, directoryReference, 1));
}
