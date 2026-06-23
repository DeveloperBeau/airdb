const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("bindex.zig");
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
// set of blob: byte-string members backed by the byte-keyed B+tree (bindex).
// Members are the bindex keys; the value column is an unused sentinel (1).
// ---------------------------------------------------------------------------

pub fn buildSetBlob(txn: *WriteTxn, items: []const []const u8) !Ref {
    var root = try bindex.create(txn);
    // bindex.insert overwrites an existing key, so duplicate members dedup.
    for (items) |member| root = try bindex.insert(txn, root, member, 1);
    return root;
}

pub fn setCountBlob(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.count(txn, set_root);
}

pub fn setContainsBlob(txn: anytype, cat: Ref, pk: u64, prop: usize, member: []const u8) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try bindex.get(txn, set_root, member)) != null;
}

pub fn setAddBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, member: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, member)) != null) return cat; // already a member, no version bump
    const new_root = try bindex.insert(txn, old_root, member, 1);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setRemoveBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, member: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, member)) == null) return cat; // not a member, no version bump
    const new_root = try bindex.remove(txn, old_root, member);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

// Collect members in ascending byte order. forEachEntry hands the callback a key
// slice that points into mapped storage and is only valid for the duration of
// the call, so each member is duped into `allocator`. The caller owns the result:
// it must free every appended slice and then deinit the list.
pub fn setCollectBlob(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            _ = val;
            try self.list.append(self.alloc, try self.alloc.dupe(u8, key));
        }
    };
    try bindex.forEachEntry(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

// ---------------------------------------------------------------------------
// dict: byte-string key -> u64 value, backed by the byte-keyed B+tree (bindex).
// ---------------------------------------------------------------------------

pub fn buildDict(txn: *WriteTxn, entries: []const catalog.DictEntry) !Ref {
    var root = try bindex.create(txn);
    // bindex.insert overwrites an existing key, so a repeated key keeps the last value.
    for (entries) |e| root = try bindex.insert(txn, root, e.key, e.val);
    return root;
}

pub fn dictGet(txn: anytype, cat: Ref, pk: u64, prop: usize, key: []const u8) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.get(txn, dict_root, key);
}

pub fn dictCount(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.count(txn, dict_root);
}

pub fn dictPut(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: []const u8, val: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try bindex.insert(txn, old_root, key, val); // overwrites existing key
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn dictRemove(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, key)) == null) return cat; // absent, no version bump
    const new_root = try bindex.remove(txn, old_root, key);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

// Collect (key, val) pairs in ascending byte-key order. The key slice handed to
// the callback is only valid during the call, so each key is duped into
// `allocator`. The caller owns the result: it must free every entry's key and
// then deinit the list.
pub fn dictCollect(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(catalog.DictEntry),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(catalog.DictEntry),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.list.append(self.alloc, .{ .key = try self.alloc.dupe(u8, key), .val = val });
        }
    };
    try bindex.forEachEntry(txn, dict_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
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
