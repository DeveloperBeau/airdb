const std = @import("std");
const objects = @import("objects.zig");
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const catalog = @import("catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");
const Index = @import("index.zig");
const blob = @import("blob.zig");
const Value = catalog.Value;
const loadCatalog = catalog.loadCatalog;
const insert = objects.insert;
const update = objects.update;
const delete = objects.delete;
const getByPk = objects.getByPk;
const getByObjectKey = objects.getByObjectKey;
const insertTyped = objects.insertTyped;
const getTyped = objects.getTyped;
const deleteAndNullify = objects.deleteAndNullify;
const updateTyped = objects.updateTyped;
const deleteTyped = objects.deleteTyped;

const testing = std.testing;

const create = catalog.create;

const createTyped = catalog.createTyped;

const propCount = catalog.propCount;

const liveCount = catalog.liveCount;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "insert appends a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_append.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    const r1 = try insert(&w, cat, &.{ 100, 7, 1 });
    cat = r1.cat;
    const r2 = try insert(&w, cat, &.{ 200, 8, 0 });
    cat = r2.cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    w.deinit();
}

test "insert rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_dup.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    try testing.expectError(error.DuplicateKey, insert(&w, cat, &.{ 100, 9, 1 }));
    w.deinit();
}

test "getByPk reads property values and the row version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;

    var out: [3]u64 = undefined;
    const ver = try getByPk(&w, cat, 200, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(u64, 0), out[2]);
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 999, &out));
    w.deinit();
}

test "update applies on a matching version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_apply.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var cat: Ref = undefined;
    var fetched_version: u64 = undefined;
    {
        var w = try db.beginWrite();
        cat = try create(&w, 3);
        cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        fetched_version = (try getByPk(&r, r.root(), 100, &out)).?;
        r.end();
    }
    {
        var w = try db.beginWrite();
        const res = try update(&w, w.new_root, 100, &.{ 100, 77, 1 }, fetched_version);
        try testing.expect(res == .ok);
        cat = res.ok.cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        _ = try getByPk(&r, r.root(), 100, &out);
        try testing.expectEqual(@as(u64, 77), out[1]);
        r.end();
    }
}

test "update copies only the columns whose value changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_diff.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 1, 10, 20 })).cat;

    const before = try loadCatalog(&w, cat);
    const col0 = before.propColRef(0);
    const col1 = before.propColRef(1);
    const col2 = before.propColRef(2);

    var out: [3]u64 = undefined;
    const ver = (try getByPk(&w, cat, 1, &out)).?;
    const res = try update(&w, cat, 1, &.{ 1, 99, 20 }, ver);
    try testing.expect(res == .ok);
    cat = res.ok.cat;

    const after = try loadCatalog(&w, cat);
    // Unchanged columns keep their exact roots (no copy-on-write happened).
    try testing.expectEqual(col0, after.propColRef(0));
    try testing.expectEqual(col2, after.propColRef(2));
    // The changed column was rewritten.
    try testing.expect(after.propColRef(1) != col1);
    _ = (try getByPk(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[1]);
    try testing.expectEqual(@as(u64, 20), out[2]);
    w.deinit();
}

test "update conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_conflict.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var cat: Ref = undefined;
    var fetched_version: u64 = undefined;
    {
        var w = try db.beginWrite();
        cat = try create(&w, 3);
        cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        fetched_version = (try getByPk(&r, r.root(), 100, &out)).?;
        r.end();
    }
    {
        var w = try db.beginWrite();
        const res = try update(&w, w.new_root, 100, &.{ 100, 77, 1 }, fetched_version);
        try testing.expect(res == .ok);
        cat = res.ok.cat;
        const res2 = try update(&w, cat, 100, &.{ 100, 88, 1 }, fetched_version); // stale now
        try testing.expect(res2 == .conflict);
        w.deinit();
    }
}

test "delete conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_conflict.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    const stale = try delete(&w, cat, 100, v100 + 1);
    try testing.expect(stale == .conflict);
    w.deinit();
}

test "delete tombstones a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_tombstone.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    const ok = try delete(&w, cat, 100, v100);
    try testing.expect(ok == .ok);
    cat = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, cat));
    w.deinit();
}

test "a deleted primary key can be reinserted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_reinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    cat = (try delete(&w, cat, 100, v100)).ok;
    // pk 100 can be reinserted after deletion
    cat = (try insert(&w, cat, &.{ 100, 70, 1 })).cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    w.deinit();
}

test "objects persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj6.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2); // pk + one value
        var i: u64 = 0;
        while (i < 1000) : (i += 1) cat = (try insert(&w, cat, &.{ i, i * 2 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 1000), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        _ = (try getByPk(&r, r.root(), 777, &out)).?;
        try testing.expectEqual(@as(u64, 777), out[0]);
        try testing.expectEqual(@as(u64, 1554), out[1]);
        try testing.expectEqual(@as(?u64, null), try getByPk(&r, r.root(), 5000, &out));
        r.end();
    }
}

test "100k objects with updates and deletes match a reference map after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj7.airdb");
    defer testing.allocator.free(path);
    var ref = std.AutoHashMap(u64, u64).init(testing.allocator); // pk -> prop1 value, live only
    defer ref.deinit();
    const N: u64 = 100_000;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2);
        var out: [2]u64 = undefined;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            const pk = (i *% 2654435761) % 5_000_011;
            if ((try getByPk(&w, cat, pk, &out)) != null) continue; // skip hash collision (dup pk)
            cat = (try insert(&w, cat, &.{ pk, i })).cat;
            try ref.put(pk, i);
        }
        // Snapshot the live keys, then update every 5th and delete every 7th.
        var keys = std.ArrayList(u64).empty;
        defer keys.deinit(testing.allocator);
        var kit = ref.keyIterator();
        while (kit.next()) |k| try keys.append(testing.allocator, k.*);
        for (keys.items, 0..) |pk, idx| {
            const ver = (try getByPk(&w, cat, pk, &out)).?;
            if (idx % 5 == 0) {
                const res = try update(&w, cat, pk, &.{ pk, out[1] +% 1 }, ver);
                cat = res.ok.cat;
                try ref.put(pk, out[1] +% 1);
            } else if (idx % 7 == 0) {
                const res = try delete(&w, cat, pk, ver);
                cat = res.ok;
                _ = ref.remove(pk);
            }
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, ref.count()), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        var it = ref.iterator();
        while (it.next()) |e| {
            const ver = try getByPk(&r, r.root(), e.key_ptr.*, &out);
            try testing.expect(ver != null);
            try testing.expectEqual(e.value_ptr.*, out[1]);
        }
        r.end();
    }
}

test "typed insert and get round-trip a string property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob, .int });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 30 } })).cat;
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "Linus" }, .{ .int = 54 } })).cat;
    var out: [3]Value = undefined;
    const ver = try getTyped(&w, cat, 2, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 2), out[0].int);
    try testing.expectEqualStrings("Linus", out[1].bytes);
    try testing.expectEqual(@as(u64, 54), out[2].int);
    w.deinit();
}

test "typed update on a stale version does not free the old blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_stale.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    // stale-version update must NOT free the old blob (conflict path)
    const conflict = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "X" } }, ver + 1);
    try testing.expect(conflict == .conflict);
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqualStrings("short", out[1].bytes);
    w.deinit();
}

test "typed update replaces a string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_replace.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    const ures = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "a much longer value" } }, ver);
    cat = ures.ok.cat;
    _ = try getTyped(&w, cat, 1, &out);
    try testing.expectEqualStrings("a much longer value", out[1].bytes);
    w.deinit();
}

test "typed delete removes the row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_delete.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const v2 = (try getTyped(&w, cat, 1, &out)).?;
    const dres = try deleteTyped(&w, cat, 1, v2);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getTyped(&w, cat, 1, &out));
    w.deinit();
}

test "strings persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str3.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try createTyped(&w, &.{ .int, .blob });
        var i: u64 = 0;
        var buf: [32]u8 = undefined;
        while (i < 500) : (i += 1) {
            const s = try std.fmt.bufPrint(&buf, "name-{d}", .{i});
            cat = (try insertTyped(&w, cat, &.{ .{ .int = i }, .{ .bytes = s } })).cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        var out: [2]Value = undefined;
        _ = (try getTyped(&r, r.root(), 321, &out)).?;
        try testing.expectEqualStrings("name-321", out[1].bytes);
        r.end();
    }
}

test "a large blob property decodes to a ref and materializes; small stays inline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bigblob.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });

    // A blob well past the inline cap (section_size is 16 MiB) forces chunking.
    const n: usize = 20 * 1024 * 1024;
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);

    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = big } })).cat;
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "small" } })).cat;

    // The large blob decodes to a ref, not an inline slice.
    var out: [2]Value = undefined;
    try testing.expect((try getTyped(&w, cat, 1, &out)) != null);
    try testing.expect(out[1] == .blob_ref);

    // Materialize it and verify length + sampled offsets + first/last KB.
    const got = try blob.getAlloc(&w, out[1].blob_ref, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(n, got.len);
    try testing.expectEqualSlices(u8, big[0..1024], got[0..1024]);
    try testing.expectEqualSlices(u8, big[n - 1024 ..], got[n - 1024 ..]);
    try testing.expectEqual(big[n / 2], got[n / 2]);
    try testing.expectEqual(big[12_345_678], got[12_345_678]);

    // A small blob in the same property still decodes to a zero-copy slice.
    try testing.expect((try getTyped(&w, cat, 2, &out)) != null);
    try testing.expect(out[1] == .bytes);
    try testing.expectEqualStrings("small", out[1].bytes);
    w.deinit();
}

test "getByObjectKey reads a row by its stable object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const r0 = try insert(&w, cat, &.{ 100, 7 });
    cat = r0.cat;
    const r1 = try insert(&w, cat, &.{ 200, 8 });
    cat = r1.cat;
    var out: [2]u64 = undefined;
    const v1 = try getByObjectKey(&w, cat, r1.row, &out);
    try testing.expect(v1 != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, 999, &out));
    const vk = (try getByObjectKey(&w, cat, r0.row, &out)).?;
    const dres = try delete(&w, cat, 100, vk);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, r0.row, &out));
    w.deinit();
}

test "getByObjectKey resolves through the key-to-row index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey_index.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const r0 = try insert(&w, cat, &.{ 100, 7 });
    cat = r0.cat;
    const r1 = try insert(&w, cat, &.{ 200, 8 });
    cat = r1.cat;
    var out: [2]u64 = undefined;
    try testing.expect((try getByObjectKey(&w, cat, r0.row, &out)) != null);
    try testing.expectEqual(@as(u64, 100), out[0]);
    try testing.expectEqual(@as(u64, 7), out[1]);
    try testing.expect((try getByObjectKey(&w, cat, r1.row, &out)) != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    // An object key with no mapping resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, 999, &out));
    w.deinit();
}

// Collect, in ascending order, the object keys held in the value index's inner
// set for (cat, prop, value). Empty/absent yields an empty list.
fn collectIndexOkeys(
    txn: anytype,
    cat: Ref,
    prop: usize,
    value: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const v = try loadCatalog(txn, cat);
    const vi = v.valueIndexRef(prop);
    const inner = (try Index.get(txn, vi, value)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, inner, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

fn expectIndexOkeys(
    txn: anytype,
    cat: Ref,
    prop: usize,
    value: u64,
    expected: []const u64,
) !void {
    var got = std.ArrayList(u64).empty;
    defer got.deinit(testing.allocator);
    try collectIndexOkeys(txn, cat, prop, value, &got, testing.allocator);
    try testing.expectEqualSlices(u64, expected, got.items);
}

test "value index tracks inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_insert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    const o3 = try insert(&w, cat, &.{ 4, 30 });
    cat = o3.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o2.row });
    try expectIndexOkeys(&w, cat, 1, 20, &.{o1.row});
    try expectIndexOkeys(&w, cat, 1, 30, &.{o3.row});
    w.deinit();
}

test "value index tracks updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_update.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    // Move o1's indexed prop from 20 to 10.
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 2, &out)).?;
    const res = try update(&w, cat, 2, &.{ 2, 10 }, ver);
    try testing.expect(res == .ok);
    cat = res.ok.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o1.row, o2.row });
    // The 20 entry is now empty.
    try expectIndexOkeys(&w, cat, 1, 20, &.{});
    w.deinit();
}

test "value index tracks deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_delete.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const o0 = try insert(&w, cat, &.{ 1, 10 });
    cat = o0.cat;
    const o1 = try insert(&w, cat, &.{ 2, 20 });
    cat = o1.cat;
    const o2 = try insert(&w, cat, &.{ 3, 10 });
    cat = o2.cat;
    try expectIndexOkeys(&w, cat, 1, 10, &.{ o0.row, o2.row });
    // Delete o0 (value 10); only o2 should remain under 10.
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try delete(&w, cat, 1, ver)).ok;
    try expectIndexOkeys(&w, cat, 1, 10, &.{o2.row});
    try expectIndexOkeys(&w, cat, 1, 20, &.{o1.row});
    w.deinit();
}

test "updateTyped carries collection properties through unchanged" {
    // Regression: updating any row of a collection-bearing type hit
    // `unreachable` (panic in Debug, UB in release). Collections are now
    // carried through; mutate them via their own APIs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "utyped_coll.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .int = 10 }, .{ .list_int = &.{ 7, 8, 9 } } })).cat;

    var out: [3]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    const res = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .int = 20 }, out[2] }, ver);
    try testing.expect(res == .ok);
    cat = res.ok.cat;

    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 20), out[1].int);
    try testing.expectEqual(@as(?u64, 3), try collections.listLen(&w, cat, 1, 2));
    try testing.expectEqual(@as(u64, 8), try collections.listGetInt(&w, cat, 1, 2, 1));
}

test "deleteTyped frees the row's collection storage" {
    // Regression: deleted rows leaked their list/set/dict trees (and element
    // and key blobs) permanently -- unreclaimable except by a full file copy.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "del_coll_free.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Commit a row carrying every collection kind so its trees are committed.
    {
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .list, .elem = .blob },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .dict },
        });
        cat = (try insertTyped(&w, cat, &.{
            .{ .int = 1 },
            .{ .list_blob = &.{ "alpha", "beta" } },
            .{ .set_int = &.{ 1, 2, 3 } },
            .{ .dict_int = &.{ .{ .key = "k1", .val = 10 }, .{ .key = "k2", .val = 20 } } },
        })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    // Deleting the row must record the collection trees as in-flight frees.
    var w = try db.beginWrite();
    defer w.deinit();
    var out: [4]Value = undefined;
    const ver = (try getTyped(&w, w.new_root, 1, &out)).?;
    const before = w.in_flight_frees.items.len;
    const res = try deleteTyped(&w, w.new_root, 1, ver);
    try testing.expect(res == .ok);
    // list tree + 2 element blobs + set tree + dict tree + 2 key blobs, plus
    // the COW frees of the delete itself: well above the tombstone-only count.
    try testing.expect(w.in_flight_frees.items.len >= before + 7);
}

test "updateTyped moves backlinks when a link value changes" {
    // Regression: updateTyped encoded the new link into the column but never
    // touched the backlink index, leaving the old target's set naming this
    // source forever and the new target's set missing it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "utyped_link.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = null } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = a.row } });
    cat = c.cat;

    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 3, &out)).?;
    const res = try updateTyped(&w, cat, 3, &.{ .{ .int = 3 }, .{ .link = b.row } }, ver);
    try testing.expect(res == .ok);
    cat = res.ok.cat;

    const links_mod = @import("links.zig");
    try testing.expectEqual(@as(u64, 0), try links_mod.backlinkCount(&w, cat, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try links_mod.backlinkCount(&w, cat, 1, b.row));
    // Deleting the NEW target nullifies the source's link.
    var raw: [2]u64 = undefined;
    const bv = (try getByPk(&w, cat, 2, &raw)).?;
    cat = switch (try deleteAndNullify(&w, cat, 2, bv)) {
        .ok => |x| x,
        else => unreachable,
    };
    try testing.expectEqual(@as(?u64, null), try links_mod.getLink(&w, cat, 3, 1));
}

test "a multi-leaf value-index set is pruned and freed when emptied" {
    // The single-leaf prune case is covered elsewhere; this drives the inner
    // set past one leaf (>64 members) so freeTree's inner-node recursion runs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_prune_big.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const n: u64 = 80;
    var pk: u64 = 1;
    while (pk <= n) : (pk += 1) cat = (try insert(&w, cat, &.{ pk, 7 })).cat;
    var out: [2]u64 = undefined;
    pk = 1;
    while (pk <= n) : (pk += 1) {
        const ver = (try getByPk(&w, cat, pk, &out)).?;
        cat = (try delete(&w, cat, pk, ver)).ok;
    }
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(@as(?u64, null), try Index.get(&w, v.valueIndexRef(1), 7));
    try testing.expectEqual(@as(u64, 0), try Index.count(&w, v.valueIndexRef(1)));
}

test "an emptied value-index set is pruned from the outer index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_prune.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = (try insert(&w, cat, &.{ 2, 10 })).cat;
    // Delete both rows carrying value 10: the 10 entry must disappear entirely,
    // not linger as an empty set.
    var out: [2]u64 = undefined;
    var pk: u64 = 1;
    while (pk <= 2) : (pk += 1) {
        const ver = (try getByPk(&w, cat, pk, &out)).?;
        cat = (try delete(&w, cat, pk, ver)).ok;
    }
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(@as(?u64, null), try Index.get(&w, v.valueIndexRef(1), 10));
    try testing.expectEqual(@as(u64, 0), try Index.count(&w, v.valueIndexRef(1)));
}

test "non-indexed prop has no index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_none.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const r0 = try insert(&w, cat, &.{ 1, 100 });
    cat = r0.cat;
    var out: [2]u64 = undefined;
    const ver = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try update(&w, cat, 1, &.{ 1, 200 }, ver)).ok.cat;
    const ver2 = (try getByPk(&w, cat, 1, &out)).?;
    cat = (try delete(&w, cat, 1, ver2)).ok;
    const v = try loadCatalog(&w, cat);
    var i: usize = 0;
    while (i < v.prop_count) : (i += 1) try testing.expectEqual(@as(Ref, 0), v.valueIndexRef(i));
    w.deinit();
}

test "reinserting a primary key after delete yields a new object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey_reinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const first = try insert(&w, cat, &.{ 100, 7 });
    cat = first.cat;
    const okey_a = first.row;
    var out: [2]u64 = undefined;
    const v = (try getByPk(&w, cat, 100, &out)).?;
    cat = (try delete(&w, cat, 100, v)).ok;
    const second = try insert(&w, cat, &.{ 100, 70 });
    cat = second.cat;
    const okey_b = second.row;
    try testing.expect(okey_a != okey_b);
    // The old object key is tombstoned and resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, okey_a, &out));
    // The new object key returns the new row.
    try testing.expect((try getByObjectKey(&w, cat, okey_b, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    // Lookup by pk returns the new values.
    try testing.expect((try getByPk(&w, cat, 100, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    w.deinit();
}

test "deleteTyped frees a self-referencing link_set root exactly once" {
    // Regression: deleting a row whose link_set contained its own okey freed
    // the set root twice. The inbound nullify removed okey from the row's own
    // set -- a COW whose Index.remove freed the old root -- and the delete's
    // storage reclamation then freed the same root again from the captured
    // column raw, handing one extent to two future allocations. The nullify
    // now leaves a self-sourced set untouched; no freed offset may repeat.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "selfset.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    {
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .link_set },
        });
        const ins = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
        cat = ins.cat;
        cat = try links.linkSetAdd(&w, cat, 1, 1, ins.row); // set contains own okey
        w.setRoot(cat);
        _ = try w.commit();
    }
    var w = try db.beginWrite();
    defer w.deinit();
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, w.new_root, 1, &out)).?;
    const res = try deleteTyped(&w, w.new_root, 1, ver);
    try testing.expect(res == .ok);
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (w.txn_reuse.extents.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (w.in_flight_frees.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing);
    }
}
