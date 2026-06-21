const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

pub fn buildListInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Column.create(txn);
    for (items) |x| root = try Column.append(txn, root, x);
    return root;
}

pub fn buildListBlob(txn: *WriteTxn, items: []const []const u8) !Ref {
    var root = try Column.create(txn);
    for (items) |s| {
        const bref = try blob.put(txn, s);
        root = try Column.append(txn, root, bref);
    }
    return root;
}

pub fn buildSetInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Index.create(txn);
    for (items) |k| root = try Index.insert(txn, root, k, 1);
    return root;
}

pub fn listLen(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.len(txn, list_root);
}

pub fn listGetInt(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) !u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.get(txn, list_root, index);
}

pub fn listGetBlob(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) ![]const u8 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try Column.get(txn, list_root, index);
    return try blob.get(txn, bref);
}

pub fn listAppendInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, value: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.append(txn, old_root, value);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listSetInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, index: u64, value: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.set(txn, old_root, index, value);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listAppendBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, bytes: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try blob.put(txn, bytes);
    const new_root = try Column.append(txn, old_root, bref);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCountInt(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try Index.count(txn, set_root);
}

pub fn setContainsInt(txn: anytype, cat: Ref, pk: u64, prop: usize, key: u64) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try Index.get(txn, set_root, key)) != null;
}

pub fn setAddInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) != null) return cat; // already a member, no version bump
    const new_root = try Index.insert(txn, old_root, key, 1);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setRemoveInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) == null) return cat; // not a member, no version bump
    const new_root = try Index.remove(txn, old_root, key);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCollectInt(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const insertTyped = @import("objects.zig").insertTyped;
const getTyped = @import("objects.zig").getTyped;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "list of int: insert, read, append, set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "listint.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .list_int = &.{ 10, 20, 30 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 20), try listGetInt(&w, cat, 1, 1, 1));
    cat = try listAppendInt(&w, cat, 1, 1, 40);
    try testing.expectEqual(@as(?u64, 4), try listLen(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 40), try listGetInt(&w, cat, 1, 1, 3));
    cat = try listSetInt(&w, cat, 1, 1, 0, 99);
    try testing.expectEqual(@as(u64, 99), try listGetInt(&w, cat, 1, 1, 0));
    var out: [2]Value = undefined;
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 1), out[0].int);
    try testing.expect(out[1].coll_root != 0);
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

test "set of int: insert, membership, add (dedup), remove, count, collect" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "setint.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .set, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .set_int = &.{ 5, 9, 5, 12 } } })).cat;
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 9));
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 7)));
    cat = try setAddInt(&w, cat, 1, 1, 7);
    try testing.expect(try setContainsInt(&w, cat, 1, 1, 7));
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    cat = try setAddInt(&w, cat, 1, 1, 7); // dedup: no change
    try testing.expectEqual(@as(?u64, 4), try setCountInt(&w, cat, 1, 1));
    cat = try setRemoveInt(&w, cat, 1, 1, 9);
    try testing.expect(!(try setContainsInt(&w, cat, 1, 1, 9)));
    try testing.expectEqual(@as(?u64, 3), try setCountInt(&w, cat, 1, 1));
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
