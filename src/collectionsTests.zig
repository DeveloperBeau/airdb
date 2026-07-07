const std = @import("std");
const collections = @import("collections.zig");
const catalog = @import("catalog.zig");
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

const Db = @import("database.zig").Db;

const insertTyped = @import("objects.zig").insertTyped;

const getTyped = @import("objects.zig").getTyped;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "collection accessors return error.NotFound for an absent pk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "coll_notfound.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
        .{ .kind = .dict },
        .{ .kind = .set, .elem = .blob },
    });
    cat = (try insertTyped(&w, cat, &.{
        .{ .int = 1 },
        .{ .list_int = &.{1} },
        .{ .set_int = &.{1} },
        .{ .dict_int = &.{} },
        .{ .set_blob = &.{} },
    })).cat;

    const missing: u64 = 999;
    try testing.expectError(error.NotFound, listGetInt(&w, cat, missing, 1, 0));
    try testing.expectError(error.NotFound, listAppendInt(&w, cat, missing, 1, 7));
    try testing.expectError(error.NotFound, listSetInt(&w, cat, missing, 1, 0, 7));
    try testing.expectError(error.NotFound, setContainsInt(&w, cat, missing, 2, 1));
    try testing.expectError(error.NotFound, setAddInt(&w, cat, missing, 2, 5));
    try testing.expectError(error.NotFound, setRemoveInt(&w, cat, missing, 2, 1));
    try testing.expectError(error.NotFound, dictGet(&w, cat, missing, 3, "k"));
    try testing.expectError(error.NotFound, dictPut(&w, cat, missing, 3, "k", 1));
    try testing.expectError(error.NotFound, dictRemove(&w, cat, missing, 3, "k"));
    try testing.expectError(error.NotFound, setContainsBlob(&w, cat, missing, 4, "m"));
    try testing.expectError(error.NotFound, setAddBlob(&w, cat, missing, 4, "m"));
    try testing.expectError(error.NotFound, setRemoveBlob(&w, cat, missing, 4, "m"));
}

test "list of int: insert seeds members and reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_seed.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 20), try listGetInt(&w, cat, 1, 1, 1));
    var out: [2]Value = undefined;
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 1), out[0].int);
    try testing.expect(out[1].coll_root != 0);
    w.deinit();
}

test "list of int: append grows the list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_append.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).cat;
    cat = try listAppendInt(&w, cat, 1, 1, 40);
    try testing.expectEqual(@as(?u64, 4), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 40), try listGetInt(&w, cat, 1, 1, 3));
    w.deinit();
}

test "list of int: set overwrites an element" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint_set.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).cat;
    cat = try listSetInt(&w, cat, 1, 1, 0, 99);
    try testing.expectEqual(@as(u64, 99), try listGetInt(&w, cat, 1, 1, 0));
    w.deinit();
}

test "list of blob: insert and read back element strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listblob.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .blob } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 7 }, .{ .list_blob = &.{ "alpha", "beta", "gamma" } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, cat, 7, 1));
    try testing.expectEqualStrings("beta", try listGetBlob(&w, cat, 7, 1, 1));
    cat = try listAppendBlob(&w, cat, 7, 1, "delta");
    try testing.expectEqualStrings("delta", try listGetBlob(&w, cat, 7, 1, 3));
    w.deinit();
}

test "set of int: build from initial members dedups and counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_count.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
    w.deinit();
}

test "set of int: membership reports contains true and false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_member.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).cat;
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 9));
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 7)));
    w.deinit();
}

test "set of int: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addnew.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 12 } } })).cat;
    cat = try setAddInt(&w, cat, 1, 1, 7);
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 7));
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    w.deinit();
}

test "set of int: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_addexist.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 7, 9, 12 } } })).cat;
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    cat = try setAddInt(&w, cat, 1, 1, 7); // dedup: no change
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    w.deinit();
}

test "set of int: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_remove.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 7, 9, 12 } } })).cat;
    cat = try setRemoveInt(&w, cat, 1, 1, 9);
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 9)));
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
    w.deinit();
}

test "set of int: collect returns ascending members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint_collect.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 12, 5, 7 } } })).cat;
    var members = std.ArrayList(u64).empty;
    defer members.deinit(testing.allocator);
    try setCollectInt(&w, cat, 1, 1, &members, testing.allocator);
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
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .list, .elem = .blob },
        });
        cat = (try insertTyped(&w, cat, &.{
            .{ .int = 42 },
            .{ .list_int = &.{ 1, 2, 3 } },
            .{ .set_int = &.{ 100, 200, 300 } },
            .{ .list_blob = &.{ "x", "yy", "zzz" } },
        })).cat;
        cat = try listAppendInt(&w, cat, 42, 1, 4);
        cat = try setAddInt(&w, cat, 42, 2, 400);
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const cat = r.root();
        try testing.expectEqual(@as(?u64, 4), try listLen(&r, cat, 42, 1));
        try testing.expectEqual(@as(u64, 4), try listGetInt(&r, cat, 42, 1, 3));
        try testing.expectEqual(@as(?u64, 4), try setCountInt(&r, cat, 42, 2));
        try testing.expect(try setContainsInt(&r, cat, 42, 2, 400));
        try testing.expectEqualStrings("zzz", try listGetBlob(&r, cat, 42, 3, 2));
        r.end();
    }
}

test "large list and set: 50k elements each, append and membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "collscale.airdb");
    defer testing.allocator.free(path);
    const N: u64 = 50_000;
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
    });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{} }, .{ .set_int = &.{} } })).cat;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        cat = try listAppendInt(&w, cat, 1, 1, i);
        cat = try setAddInt(&w, cat, 1, 2, i *% 2654435761 % 1_000_003);
    }
    try testing.expectEqual(@as(?u64, N), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 12345), try listGetInt(&w, cat, 1, 1, 12345));
    const sc = (try setCountInt(&w, cat, 1, 2)).?;
    try testing.expect(sc > 0 and sc <= N);
    try testing.expect(try setContainsInt(&w, cat, 1, 2, 0));
    w.deinit();
}

test "dict: insert, get, put, remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "dict_ops.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .dict } });
    cat = (try insertTyped(&w, cat, &.{
        .{ .int = 1 },
        .{ .dict_int = &.{ .{ .key = "apple", .val = 1 }, .{ .key = "banana", .val = 2 } } },
    })).cat;
    try testing.expectEqual(@as(?u64, 1), try dictGet(&w, cat, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, null), try dictGet(&w, cat, 1, 1, "missing"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&w, cat, 1, 1));

    cat = try dictPut(&w, cat, 1, 1, "cherry", 3);
    try testing.expectEqual(@as(?u64, 3), try dictGet(&w, cat, 1, 1, "cherry"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&w, cat, 1, 1));

    cat = try dictPut(&w, cat, 1, 1, "apple", 9); // overwrite
    try testing.expectEqual(@as(?u64, 9), try dictGet(&w, cat, 1, 1, "apple"));
    try testing.expectEqual(@as(?u64, 3), try dictCount(&w, cat, 1, 1));

    cat = try dictRemove(&w, cat, 1, 1, "banana");
    try testing.expectEqual(@as(?u64, null), try dictGet(&w, cat, 1, 1, "banana"));
    try testing.expectEqual(@as(?u64, 2), try dictCount(&w, cat, 1, 1));

    var entries = std.ArrayList(catalog.DictEntry).empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.key);
        entries.deinit(testing.allocator);
    }
    try dictCollect(&w, cat, 1, 1, &entries, testing.allocator);
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .blob } });
    cat = (try insertTyped(&w, cat, &.{
        .{ .int = 1 },
        .{ .set_blob = &.{ "x", "yy", "x" } }, // duplicate "x"
    })).cat;
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&w, cat, 1, 1));
    try testing.expect(try setContainsBlob(&w, cat, 1, 1, "yy"));
    try testing.expect(!(try setContainsBlob(&w, cat, 1, 1, "z")));

    cat = try setAddBlob(&w, cat, 1, 1, "z");
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&w, cat, 1, 1));
    cat = try setAddBlob(&w, cat, 1, 1, "z"); // dedup no-op
    try testing.expectEqual(@as(?u64, 3), try setCountBlob(&w, cat, 1, 1));

    cat = try setRemoveBlob(&w, cat, 1, 1, "x");
    try testing.expect(!(try setContainsBlob(&w, cat, 1, 1, "x")));
    try testing.expectEqual(@as(?u64, 2), try setCountBlob(&w, cat, 1, 1));

    var members = std.ArrayList([]const u8).empty;
    defer {
        for (members.items) |m| testing.allocator.free(m);
        members.deinit(testing.allocator);
    }
    try setCollectBlob(&w, cat, 1, 1, &members, testing.allocator);
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
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .dict },
            .{ .kind = .set, .elem = .blob },
        });
        cat = (try insertTyped(&w, cat, &.{
            .{ .int = 42 },
            .{ .dict_int = &.{ .{ .key = "one", .val = 1 }, .{ .key = "two", .val = 2 } } },
            .{ .set_blob = &.{ "alpha", "beta" } },
        })).cat;
        cat = try dictPut(&w, cat, 42, 1, "three", 3);
        cat = try setAddBlob(&w, cat, 42, 2, "gamma");
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const cat = r.root();
        try testing.expectEqual(@as(?u64, 1), try dictGet(&r, cat, 42, 1, "one"));
        try testing.expectEqual(@as(?u64, 3), try dictGet(&r, cat, 42, 1, "three"));
        try testing.expectEqual(@as(?u64, 3), try dictCount(&r, cat, 42, 1));
        try testing.expectEqual(@as(?u64, 3), try setCountBlob(&r, cat, 42, 2));
        try testing.expect(try setContainsBlob(&r, cat, 42, 2, "gamma"));
        try testing.expect(try setContainsBlob(&r, cat, 42, 2, "alpha"));
        r.end();
    }
}
