const std = @import("std");
const collections = @import("collections.zig");
const catalog = @import("../schema/catalog.zig");
const Value = catalog.Value;
const listLen = collections.listLen;
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
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "collection accessors return error.NotFound for an absent primaryKey" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "coll_notfound.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var catalogRef = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
        .{ .kind = .dict },
        .{ .kind = .set, .elem = .blob },
    });
    catalogRef = (try insertTyped(&w, catalogRef, &.{
        .{ .int = 1 },
        .{ .list_int = &.{1} },
        .{ .set_int = &.{1} },
        .{ .dict_int = &.{} },
        .{ .set_blob = &.{} },
    })).catalogRef;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, listGetInt(&w, catalogRef, missing, 1, 0));
    try testing.expectError(error.NotFound, listAppendInt(&w, catalogRef, missing, 1, 7));
    try testing.expectError(error.NotFound, listSetInt(&w, catalogRef, missing, 1, 0, 7));
    try testing.expectError(error.NotFound, setContainsInt(&w, catalogRef, missing, 2, 1));
    try testing.expectError(error.NotFound, setAddInt(&w, catalogRef, missing, 2, 5));
    try testing.expectError(error.NotFound, setRemoveInt(&w, catalogRef, missing, 2, 1));
    try testing.expectError(error.NotFound, dictGet(&w, catalogRef, missing, 3, "k"));
    try testing.expectError(error.NotFound, dictPut(&w, catalogRef, missing, 3, "k", 1));
    try testing.expectError(error.NotFound, dictRemove(&w, catalogRef, missing, 3, "k"));
    try testing.expectError(error.NotFound, setContainsBlob(&w, catalogRef, missing, 4, "m"));
    try testing.expectError(error.NotFound, setAddBlob(&w, catalogRef, missing, 4, "m"));
    try testing.expectError(error.NotFound, setRemoveBlob(&w, catalogRef, missing, 4, "m"));
}

test "list of int: insert seeds members and reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_seed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).catalogRef;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, catalogRef, 1, 1));
    try testing.expectEqual(@as(u64, 20), try listGetInt(&w, catalogRef, 1, 1, 1));
    var out: [2]Value = undefined;
    _ = (try getTyped(&w, catalogRef, 1, &out)).?;
    try testing.expectEqual(@as(u64, 1), out[0].int);
    try testing.expect(out[1].coll_root != 0);
    w.deinit();
}

test "list of int: append grows the list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_append.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).catalogRef;
    catalogRef = try listAppendInt(&w, catalogRef, 1, 1, 40);
    try testing.expectEqual(@as(?u64, 4), try listLen(&w, catalogRef, 1, 1));
    try testing.expectEqual(@as(u64, 40), try listGetInt(&w, catalogRef, 1, 1, 3));
    w.deinit();
}

test "list of int: set overwrites an element" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_set.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).catalogRef;
    catalogRef = try listSetInt(&w, catalogRef, 1, 1, 0, 99);
    try testing.expectEqual(@as(u64, 99), try listGetInt(&w, catalogRef, 1, 1, 0));
    w.deinit();
}

test "list of blob: insert and read back element strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listblob.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .blob } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 7 }, .{ .list_blob = &.{ "alpha", "beta", "gamma" } } })).catalogRef;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, catalogRef, 7, 1));
    try testing.expectEqualStrings("beta", try listGetBlob(&w, catalogRef, 7, 1, 1));
    catalogRef = try listAppendBlob(&w, catalogRef, 7, 1, "delta");
    try testing.expectEqualStrings("delta", try listGetBlob(&w, catalogRef, 7, 1, 3));
    w.deinit();
}

test "set of int: build from initial members dedups and counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_count.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).catalogRef;
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, catalogRef, 1, 1));
    w.deinit();
}

test "set of int: membership reports contains true and false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_member.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).catalogRef;
    try testing.expect(try setContainsInt(&w, catalogRef, 1, 1, 9));
    try testing.expect(!(try setContainsInt(&w, catalogRef, 1, 1, 7)));
    w.deinit();
}

test "set of int: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addnew.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 12 } } })).catalogRef;
    catalogRef = try setAddInt(&w, catalogRef, 1, 1, 7);
    try testing.expect(try setContainsInt(&w, catalogRef, 1, 1, 7));
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, catalogRef, 1, 1));
    w.deinit();
}

test "set of int: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addexist.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 7, 9, 12 } } })).catalogRef;
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, catalogRef, 1, 1));
    catalogRef = try setAddInt(&w, catalogRef, 1, 1, 7); // dedup: no change
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, catalogRef, 1, 1));
    w.deinit();
}

test "set of int: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_remove.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 7, 9, 12 } } })).catalogRef;
    catalogRef = try setRemoveInt(&w, catalogRef, 1, 1, 9);
    try testing.expect(!(try setContainsInt(&w, catalogRef, 1, 1, 9)));
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, catalogRef, 1, 1));
    w.deinit();
}

test "set of int: collect returns ascending members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_collect.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .set_int = &.{ 12, 5, 7 } } })).catalogRef;
    var members = std.ArrayList(u64).empty;
    defer members.deinit(testing.allocator);
    try setCollectInt(&w, catalogRef, 1, 1, &members, testing.allocator);
    try testing.expectEqual(@as(usize, 3), members.items.len);
    try testing.expectEqual(@as(u64, 5), members.items[0]);
    try testing.expectEqual(@as(u64, 7), members.items[1]);
    try testing.expectEqual(@as(u64, 12), members.items[2]);
    w.deinit();
}

test "collections persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collpersist.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .list, .elem = .blob },
        });
        catalogRef = (try insertTyped(&w, catalogRef, &.{
            .{ .int = 42 },
            .{ .list_int = &.{ 1, 2, 3 } },
            .{ .set_int = &.{ 100, 200, 300 } },
            .{ .list_blob = &.{ "x", "yy", "zzz" } },
        })).catalogRef;
        catalogRef = try listAppendInt(&w, catalogRef, 42, 1, 4);
        catalogRef = try setAddInt(&w, catalogRef, 42, 2, 400);
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        const catalogRef = r.root();
        try testing.expectEqual(@as(?u64, 4), try listLen(&r, catalogRef, 42, 1));
        try testing.expectEqual(@as(u64, 4), try listGetInt(&r, catalogRef, 42, 1, 3));
        try testing.expectEqual(@as(?u64, 4), try setCountInt(&r, catalogRef, 42, 2));
        try testing.expect(try setContainsInt(&r, catalogRef, 42, 2, 400));
        try testing.expectEqualStrings("zzz", try listGetBlob(&r, catalogRef, 42, 3, 2));
        r.end();
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
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
    });
    catalogRef = (try insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .list_int = &.{} }, .{ .set_int = &.{} } })).catalogRef;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        catalogRef = try listAppendInt(&w, catalogRef, 1, 1, i);
        catalogRef = try setAddInt(&w, catalogRef, 1, 2, i *% 2654435761 % 1_000_003);
    }
    try testing.expectEqual(@as(?u64, N), try listLen(&w, catalogRef, 1, 1));
    try testing.expectEqual(@as(u64, 12345), try listGetInt(&w, catalogRef, 1, 1, 12345));
    const sc = (try setCountInt(&w, catalogRef, 1, 2)).?;
    try testing.expect(sc > 0 and sc <= N);
    try testing.expect(try setContainsInt(&w, catalogRef, 1, 2, 0));
    w.deinit();
}

test "dict: insert, get, put, remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "dict_ops.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .dict } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{
        .{ .int = 1 },
        .{ .dict_int = &.{ .{ .key = "apple", .val = 1 }, .{ .key = "banana", .val = 2 } } },
    })).catalogRef;
    try testing.expectEqual(@as(?u64, 1), try dictGet(&w, catalogRef, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, null), try dictGet(&w, catalogRef, 1, 1, "missing"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&w, catalogRef, 1, 1));

    catalogRef = try dictPut(&w, catalogRef, 1, 1, "cherry", 3);
    try testing.expectEqual(@as(?u64, 3), try dictGet(&w, catalogRef, 1, 1, "cherry"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&w, catalogRef, 1, 1));

    catalogRef = try dictPut(&w, catalogRef, 1, 1, "apple", 9); // overwrite
    try testing.expectEqual(@as(?u64, 9), try dictGet(&w, catalogRef, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&w, catalogRef, 1, 1));

    catalogRef = try dictRemove(&w, catalogRef, 1, 1, "banana");
    try testing.expectEqual(@as(?u64, null), try dictGet(&w, catalogRef, 1, 1, "banana"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&w, catalogRef, 1, 1));

    var entries = std.ArrayList(catalog.DictEntry).empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.key);
        entries.deinit(testing.allocator);
    }
    try dictCollect(&w, catalogRef, 1, 1, &entries, testing.allocator);
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    try testing.expectEqualStrings("apple", entries.items[0].key);
    try testing.expectEqual(@as(u64, 9), entries.items[0].val);
    try testing.expectEqualStrings("cherry", entries.items[1].key);
    try testing.expectEqual(@as(u64, 3), entries.items[1].val);
    w.deinit();
}

test "set of blob: insert, membership, add(dedup), remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setblob_ops.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .blob } });
    catalogRef = (try insertTyped(&w, catalogRef, &.{
        .{ .int = 1 },
        .{ .set_blob = &.{ "x", "yy", "x" } }, // duplicate "x"
    })).catalogRef;
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&w, catalogRef, 1, 1));
    try testing.expect(try setContainsBlob(&w, catalogRef, 1, 1, "yy"));
    try testing.expect(!(try setContainsBlob(&w, catalogRef, 1, 1, "z")));

    catalogRef = try setAddBlob(&w, catalogRef, 1, 1, "z");
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&w, catalogRef, 1, 1));
    catalogRef = try setAddBlob(&w, catalogRef, 1, 1, "z"); // dedup no-op
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&w, catalogRef, 1, 1));

    catalogRef = try setRemoveBlob(&w, catalogRef, 1, 1, "x");
    try testing.expect(!(try setContainsBlob(&w, catalogRef, 1, 1, "x")));
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&w, catalogRef, 1, 1));

    var members = std.ArrayList([]const u8).empty;
    defer {
        for (members.items) |m| testing.allocator.free(m);
        members.deinit(testing.allocator);
    }
    try setCollectBlob(&w, catalogRef, 1, 1, &members, testing.allocator);
    try testing.expectEqual(@as(usize, 2), members.items.len);
    try testing.expectEqualStrings("yy", members.items[0]);
    try testing.expectEqualStrings("z", members.items[1]);
    w.deinit();
}

test "dict and set-of-blob persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "dictsetblob_persist.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .dict },
            .{ .kind = .set, .elem = .blob },
        });
        catalogRef = (try insertTyped(&w, catalogRef, &.{
            .{ .int = 42 },
            .{ .dict_int = &.{ .{ .key = "one", .val = 1 }, .{ .key = "two", .val = 2 } } },
            .{ .set_blob = &.{ "alpha", "beta" } },
        })).catalogRef;
        catalogRef = try dictPut(&w, catalogRef, 42, 1, "three", 3);
        catalogRef = try setAddBlob(&w, catalogRef, 42, 2, "gamma");
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        const catalogRef = r.root();
        try testing.expectEqual(@as(?u64, 1), try dictGet(&r, catalogRef, 42, 1, "one"));
        try testing.expectEqual(@as(?u64, 3), try dictGet(&r, catalogRef, 42, 1, "three"));
        try testing.expectEqual(@as(?u64, 3), try dictCount(&r, catalogRef, 42, 1));
        try testing.expectEqual(@as(?u64, 3), try setCountBlob(&r, catalogRef, 42, 2));
        try testing.expect(try setContainsBlob(&r, catalogRef, 42, 2, "gamma"));
        try testing.expect(try setContainsBlob(&r, catalogRef, 42, 2, "alpha"));
        r.end();
    }
}
