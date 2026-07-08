const std = @import("std");
const collections = @import("collections.zig");
const catalog = @import("../schema/catalog.zig");
const Value = catalog.Value;
const listLength = collections.listLength;
const listGetInt = collections.listGetInt;
const listGetBlob = collections.listGetBlob;
const listAppendInt = collections.listAppendInt;
const listSetInt = collections.listSetInt;
const listAppendBlob = collections.listAppendBlob;
const setCountInt = collections.setCountInt;
const setContainsInt = collections.setContainsInt;
const setAddInt = collections.setAddInt;
const setRemoveInt = collections.setRemoveInt;
const setCollectInt = collections.setCollectInt;
const setCountBlob = collections.setCountBlob;
const setContainsBlob = collections.setContainsBlob;
const setAddBlob = collections.setAddBlob;
const setRemoveBlob = collections.setRemoveBlob;
const setCollectBlob = collections.setCollectBlob;
const dictGet = collections.dictGet;
const dictCount = collections.dictCount;
const dictPut = collections.dictPut;
const dictRemove = collections.dictRemove;
const dictCollect = collections.dictCollect;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const insertTyped = @import("objects.zig").insertTyped;

const getTyped = @import("objects.zig").getTyped;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "collection accessors return error.NotFound for an absent primaryKey" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "coll_notfound.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .int },
        .{ .kind = .set, .element = .int },
        .{ .kind = .dict },
        .{ .kind = .set, .element = .blob },
    });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{
        .{ .int = 1 },
        .{ .listInt = &.{1} },
        .{ .setInt = &.{1} },
        .{ .dictInt = &.{} },
        .{ .setBlob = &.{} },
    })).catalogReference;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, listGetInt(&writeTransaction, catalogReference, missing, 1, 0));
    try testing.expectError(error.NotFound, listAppendInt(&writeTransaction, catalogReference, missing, 1, 7));
    try testing.expectError(error.NotFound, listSetInt(&writeTransaction, catalogReference, missing, 1, 0, 7));
    try testing.expectError(error.NotFound, setContainsInt(&writeTransaction, catalogReference, missing, 2, 1));
    try testing.expectError(error.NotFound, setAddInt(&writeTransaction, catalogReference, missing, 2, 5));
    try testing.expectError(error.NotFound, setRemoveInt(&writeTransaction, catalogReference, missing, 2, 1));
    try testing.expectError(error.NotFound, dictGet(&writeTransaction, catalogReference, missing, 3, "k"));
    try testing.expectError(error.NotFound, dictPut(&writeTransaction, catalogReference, missing, 3, "k", 1));
    try testing.expectError(error.NotFound, dictRemove(&writeTransaction, catalogReference, missing, 3, "k"));
    try testing.expectError(error.NotFound, setContainsBlob(&writeTransaction, catalogReference, missing, 4, "m"));
    try testing.expectError(error.NotFound, setAddBlob(&writeTransaction, catalogReference, missing, 4, "m"));
    try testing.expectError(error.NotFound, setRemoveBlob(&writeTransaction, catalogReference, missing, 4, "m"));
}

test "list of int: insert seeds members and reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_seed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .listInt = &.{ 10, 20, 30 } } })).catalogReference;
    try testing.expectEqual(@as(?u64, 3), try listLength(&writeTransaction, catalogReference, 1, 1));
    try testing.expectEqual(@as(u64, 20), try listGetInt(&writeTransaction, catalogReference, 1, 1, 1));
    var out: [2]Value = undefined;
    _ = (try getTyped(&writeTransaction, catalogReference, 1, &out)).?;
    try testing.expectEqual(@as(u64, 1), out[0].int);
    try testing.expect(out[1].collectionRoot != 0);
    writeTransaction.deinit();
}

test "list of int: append grows the list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_append.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .listInt = &.{ 10, 20, 30 } } })).catalogReference;
    catalogReference = try listAppendInt(&writeTransaction, catalogReference, 1, 1, 40);
    try testing.expectEqual(@as(?u64, 4), try listLength(&writeTransaction, catalogReference, 1, 1));
    try testing.expectEqual(@as(u64, 40), try listGetInt(&writeTransaction, catalogReference, 1, 1, 3));
    writeTransaction.deinit();
}

test "list of int: set overwrites an element" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_set.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .listInt = &.{ 10, 20, 30 } } })).catalogReference;
    catalogReference = try listSetInt(&writeTransaction, catalogReference, 1, 1, 0, 99);
    try testing.expectEqual(@as(u64, 99), try listGetInt(&writeTransaction, catalogReference, 1, 1, 0));
    writeTransaction.deinit();
}

test "list of blob: insert and read back element strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listblob.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .list, .element = .blob } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 7 }, .{ .listBlob = &.{ "alpha", "beta", "gamma" } } })).catalogReference;
    try testing.expectEqual(@as(?u64, 3), try listLength(&writeTransaction, catalogReference, 7, 1));
    try testing.expectEqualStrings("beta", try listGetBlob(&writeTransaction, catalogReference, 7, 1, 1));
    catalogReference = try listAppendBlob(&writeTransaction, catalogReference, 7, 1, "delta");
    try testing.expectEqualStrings("delta", try listGetBlob(&writeTransaction, catalogReference, 7, 1, 3));
    writeTransaction.deinit();
}

test "set of int: build from initial members dedups and counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_count.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 5, 9, 5, 12 } } })).catalogReference;
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&writeTransaction, catalogReference, 1, 1));
    writeTransaction.deinit();
}

test "set of int: membership reports contains true and false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_member.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 5, 9, 5, 12 } } })).catalogReference;
    try testing.expect(try setContainsInt(&writeTransaction, catalogReference, 1, 1, 9));
    try testing.expect(!(try setContainsInt(&writeTransaction, catalogReference, 1, 1, 7)));
    writeTransaction.deinit();
}

test "set of int: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addnew.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 5, 9, 12 } } })).catalogReference;
    catalogReference = try setAddInt(&writeTransaction, catalogReference, 1, 1, 7);
    try testing.expect(try setContainsInt(&writeTransaction, catalogReference, 1, 1, 7));
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&writeTransaction, catalogReference, 1, 1));
    writeTransaction.deinit();
}

test "set of int: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addexist.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 5, 7, 9, 12 } } })).catalogReference;
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&writeTransaction, catalogReference, 1, 1));
    catalogReference = try setAddInt(&writeTransaction, catalogReference, 1, 1, 7); // dedup: no change
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&writeTransaction, catalogReference, 1, 1));
    writeTransaction.deinit();
}

test "set of int: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 5, 7, 9, 12 } } })).catalogReference;
    catalogReference = try setRemoveInt(&writeTransaction, catalogReference, 1, 1, 9);
    try testing.expect(!(try setContainsInt(&writeTransaction, catalogReference, 1, 1, 9)));
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&writeTransaction, catalogReference, 1, 1));
    writeTransaction.deinit();
}

test "set of int: collect returns ascending members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_collect.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .int } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .setInt = &.{ 12, 5, 7 } } })).catalogReference;
    var members = std.ArrayList(u64).empty;
    defer members.deinit(testing.allocator);
    try setCollectInt(&writeTransaction, catalogReference, 1, 1, &members, testing.allocator);
    try testing.expectEqual(@as(usize, 3), members.items.len);
    try testing.expectEqual(@as(u64, 5), members.items[0]);
    try testing.expectEqual(@as(u64, 7), members.items[1]);
    try testing.expectEqual(@as(u64, 12), members.items[2]);
    writeTransaction.deinit();
}

test "collections persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collpersist.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = .list, .element = .int },
            .{ .kind = .set, .element = .int },
            .{ .kind = .list, .element = .blob },
        });
        catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{
            .{ .int = 42 },
            .{ .listInt = &.{ 1, 2, 3 } },
            .{ .setInt = &.{ 100, 200, 300 } },
            .{ .listBlob = &.{ "x", "yy", "zzz" } },
        })).catalogReference;
        catalogReference = try listAppendInt(&writeTransaction, catalogReference, 42, 1, 4);
        catalogReference = try setAddInt(&writeTransaction, catalogReference, 42, 2, 400);
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        const catalogReference = readTransaction.root();
        try testing.expectEqual(@as(?u64, 4), try listLength(&readTransaction, catalogReference, 42, 1));
        try testing.expectEqual(@as(u64, 4), try listGetInt(&readTransaction, catalogReference, 42, 1, 3));
        try testing.expectEqual(@as(?u64, 4), try setCountInt(&readTransaction, catalogReference, 42, 2));
        try testing.expect(try setContainsInt(&readTransaction, catalogReference, 42, 2, 400));
        try testing.expectEqualStrings("zzz", try listGetBlob(&readTransaction, catalogReference, 42, 3, 2));
        readTransaction.end();
    }
}

test "large list and set: 50k elements each, append and membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collscale.airdb");
    defer testing.allocator.free(path);
    const N: u64 = 50_000;
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .int },
        .{ .kind = .set, .element = .int },
    });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .listInt = &.{} }, .{ .setInt = &.{} } })).catalogReference;
    var index: u64 = 0;
    while (index < N) : (index += 1) {
        catalogReference = try listAppendInt(&writeTransaction, catalogReference, 1, 1, index);
        catalogReference = try setAddInt(&writeTransaction, catalogReference, 1, 2, index *% 2654435761 % 1_000_003);
    }
    try testing.expectEqual(@as(?u64, N), try listLength(&writeTransaction, catalogReference, 1, 1));
    try testing.expectEqual(@as(u64, 12345), try listGetInt(&writeTransaction, catalogReference, 1, 1, 12345));
    const setCount = (try setCountInt(&writeTransaction, catalogReference, 1, 2)).?;
    try testing.expect(setCount > 0 and setCount <= N);
    try testing.expect(try setContainsInt(&writeTransaction, catalogReference, 1, 2, 0));
    writeTransaction.deinit();
}

test "dict: insert, get, put, remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "dict_ops.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .dict } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{
        .{ .int = 1 },
        .{ .dictInt = &.{ .{ .key = "apple", .value = 1 }, .{ .key = "banana", .value = 2 } } },
    })).catalogReference;
    try testing.expectEqual(@as(?u64, 1), try dictGet(&writeTransaction, catalogReference, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, null), try dictGet(&writeTransaction, catalogReference, 1, 1, "missing"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&writeTransaction, catalogReference, 1, 1));

    catalogReference = try dictPut(&writeTransaction, catalogReference, 1, 1, "cherry", 3);
    try testing.expectEqual(@as(?u64, 3), try dictGet(&writeTransaction, catalogReference, 1, 1, "cherry"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&writeTransaction, catalogReference, 1, 1));

    catalogReference = try dictPut(&writeTransaction, catalogReference, 1, 1, "apple", 9); // overwrite
    try testing.expectEqual(@as(?u64, 9), try dictGet(&writeTransaction, catalogReference, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&writeTransaction, catalogReference, 1, 1));

    catalogReference = try dictRemove(&writeTransaction, catalogReference, 1, 1, "banana");
    try testing.expectEqual(@as(?u64, null), try dictGet(&writeTransaction, catalogReference, 1, 1, "banana"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&writeTransaction, catalogReference, 1, 1));

    var entries = std.ArrayList(catalog.DictEntry).empty;
    defer {
        for (entries.items) |entry| testing.allocator.free(entry.key);
        entries.deinit(testing.allocator);
    }
    try dictCollect(&writeTransaction, catalogReference, 1, 1, &entries, testing.allocator);
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("apple", entries.items[0].key);
    try testing.expectEqual(@as(u64, 9), entries.items[0].value);
    try testing.expectEqualStrings("cherry", entries.items[1].key);
    try testing.expectEqual(@as(u64, 3), entries.items[1].value);
    writeTransaction.deinit();
}

test "set of blob: insert, membership, add(dedup), remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setblob_ops.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .set, .element = .blob } });
    catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{
        .{ .int = 1 },
        .{ .setBlob = &.{ "x", "yy", "x" } }, // duplicate "x"
    })).catalogReference;
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&writeTransaction, catalogReference, 1, 1));
    try testing.expect(try setContainsBlob(&writeTransaction, catalogReference, 1, 1, "yy"));
    try testing.expect(!(try setContainsBlob(&writeTransaction, catalogReference, 1, 1, "z")));

    catalogReference = try setAddBlob(&writeTransaction, catalogReference, 1, 1, "z");
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&writeTransaction, catalogReference, 1, 1));
    catalogReference = try setAddBlob(&writeTransaction, catalogReference, 1, 1, "z"); // dedup no-op
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&writeTransaction, catalogReference, 1, 1));

    catalogReference = try setRemoveBlob(&writeTransaction, catalogReference, 1, 1, "x");
    try testing.expect(!(try setContainsBlob(&writeTransaction, catalogReference, 1, 1, "x")));
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&writeTransaction, catalogReference, 1, 1));

    var members = std.ArrayList([]const u8).empty;
    defer {
        for (members.items) |member| testing.allocator.free(member);
        members.deinit(testing.allocator);
    }
    try setCollectBlob(&writeTransaction, catalogReference, 1, 1, &members, testing.allocator);
    try testing.expectEqual(@as(usize, 2), members.items.len);
    try testing.expectEqualStrings("yy", members.items[0]);
    try testing.expectEqualStrings("z", members.items[1]);
    writeTransaction.deinit();
}

test "dict and set-of-blob persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "dictsetblob_persist.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = .dict },
            .{ .kind = .set, .element = .blob },
        });
        catalogReference = (try insertTyped(&writeTransaction, catalogReference, &.{
            .{ .int = 42 },
            .{ .dictInt = &.{ .{ .key = "one", .value = 1 }, .{ .key = "two", .value = 2 } } },
            .{ .setBlob = &.{ "alpha", "beta" } },
        })).catalogReference;
        catalogReference = try dictPut(&writeTransaction, catalogReference, 42, 1, "three", 3);
        catalogReference = try setAddBlob(&writeTransaction, catalogReference, 42, 2, "gamma");
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        const catalogReference = readTransaction.root();
        try testing.expectEqual(@as(?u64, 1), try dictGet(&readTransaction, catalogReference, 42, 1, "one"));
        try testing.expectEqual(@as(?u64, 3), try dictGet(&readTransaction, catalogReference, 42, 1, "three"));
        try testing.expectEqual(@as(?u64, 3), try dictCount(&readTransaction, catalogReference, 42, 1));
        try testing.expectEqual(@as(?u64, 3), try setCountBlob(&readTransaction, catalogReference, 42, 2));
        try testing.expect(try setContainsBlob(&readTransaction, catalogReference, 42, 2, "gamma"));
        try testing.expect(try setContainsBlob(&readTransaction, catalogReference, 42, 2, "alpha"));
        readTransaction.end();
    }
}
