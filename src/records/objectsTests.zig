const std = @import("std");
const objects = @import("objects.zig");
const rows = @import("rows.zig");
const Database = @import("../database.zig").Database;
const Reference = @import("../storage/reference.zig").Reference;
const catalog = @import("../schema/catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");
const Index = @import("../trees/index.zig");
const blob = @import("blob.zig");
const Value = catalog.Value;
const loadCatalog = catalog.loadCatalog;
const insert = rows.insert;
const update = rows.update;
const delete = rows.delete;
const getByPrimaryKey = rows.getByPrimaryKey;
const getByObjectKey = rows.getByObjectKey;
const insertTyped = objects.insertTyped;
const getTyped = objects.getTyped;
const deleteAndNullify = objects.deleteAndNullify;
const updateTyped = objects.updateTyped;
const deleteTyped = objects.deleteTyped;

const testing = std.testing;

const create = catalog.create;

const createTyped = catalog.createTyped;

const loadPropertyCount = catalog.loadPropertyCount;

const liveCount = catalog.liveCount;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "insert appends a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_append.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 });
    catalogRef = inserted1.catalogRef;
    const inserted2 = try insert(&writeTransaction, catalogRef, &.{ 200, 8, 0 });
    catalogRef = inserted2.catalogRef;
    try testing.expectEqual(@as(u64, 2), try liveCount(&writeTransaction, catalogRef));
    writeTransaction.deinit();
}

test "insert rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_dup.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
    try testing.expectError(error.DuplicateKey, insert(&writeTransaction, catalogRef, &.{ 100, 9, 1 }));
    writeTransaction.deinit();
}

test "getByPrimaryKey reads property values and the row version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 200, 8, 0 })).catalogRef;

    var out: [3]u64 = undefined;
    const version = try getByPrimaryKey(&writeTransaction, catalogRef, 200, &out);
    try testing.expect(version != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(u64, 0), out[2]);
    try testing.expectEqual(@as(?u64, null), try getByPrimaryKey(&writeTransaction, catalogRef, 999, &out));
    writeTransaction.deinit();
}

test "update applies on a matching version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_apply.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var catalogRef: Reference = undefined;
    var fetchedVersion: u64 = undefined;
    {
        var writeTransaction = try database.beginWrite();
        catalogRef = try create(&writeTransaction, 3);
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var readTransaction = try database.beginRead();
        var out: [3]u64 = undefined;
        fetchedVersion = (try getByPrimaryKey(&readTransaction, readTransaction.root(), 100, &out)).?;
        readTransaction.end();
    }
    {
        var writeTransaction = try database.beginWrite();
        const res = try update(&writeTransaction, writeTransaction.newRoot, 100, &.{ 100, 77, 1 }, fetchedVersion);
        try testing.expect(res == .ok);
        catalogRef = res.ok.catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var readTransaction = try database.beginRead();
        var out: [3]u64 = undefined;
        _ = try getByPrimaryKey(&readTransaction, readTransaction.root(), 100, &out);
        try testing.expectEqual(@as(u64, 77), out[1]);
        readTransaction.end();
    }
}

test "update copies only the columns whose value changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_diff.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10, 20 })).catalogRef;

    const before = try loadCatalog(&writeTransaction, catalogRef);
    const col0 = before.propertyColumnRef(0);
    const col1 = before.propertyColumnRef(1);
    const col2 = before.propertyColumnRef(2);

    var out: [3]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    const res = try update(&writeTransaction, catalogRef, 1, &.{ 1, 99, 20 }, version);
    try testing.expect(res == .ok);
    catalogRef = res.ok.catalogRef;

    const after = try loadCatalog(&writeTransaction, catalogRef);
    // Unchanged columns keep their exact roots (no copy-on-write happened).
    try testing.expectEqual(col0, after.propertyColumnRef(0));
    try testing.expectEqual(col2, after.propertyColumnRef(2));
    // The changed column was rewritten.
    try testing.expect(after.propertyColumnRef(1) != col1);
    _ = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[1]);
    try testing.expectEqual(@as(u64, 20), out[2]);
    writeTransaction.deinit();
}

test "update conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_conflict.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var catalogRef: Reference = undefined;
    var fetchedVersion: u64 = undefined;
    {
        var writeTransaction = try database.beginWrite();
        catalogRef = try create(&writeTransaction, 3);
        catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var readTransaction = try database.beginRead();
        var out: [3]u64 = undefined;
        fetchedVersion = (try getByPrimaryKey(&readTransaction, readTransaction.root(), 100, &out)).?;
        readTransaction.end();
    }
    {
        var writeTransaction = try database.beginWrite();
        const res = try update(&writeTransaction, writeTransaction.newRoot, 100, &.{ 100, 77, 1 }, fetchedVersion);
        try testing.expect(res == .ok);
        catalogRef = res.ok.catalogRef;
        const res2 = try update(&writeTransaction, catalogRef, 100, &.{ 100, 88, 1 }, fetchedVersion); // stale now
        try testing.expect(res2 == .conflict);
        writeTransaction.deinit();
    }
}

test "delete conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_conflict.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 200, 8, 0 })).catalogRef;
    var out: [3]u64 = undefined;
    const v100 = (try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out)).?;
    const stale = try delete(&writeTransaction, catalogRef, 100, v100 + 1);
    try testing.expect(stale == .conflict);
    writeTransaction.deinit();
}

test "delete tombstones a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_tombstone.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 200, 8, 0 })).catalogRef;
    var out: [3]u64 = undefined;
    const v100 = (try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out)).?;
    const ok = try delete(&writeTransaction, catalogRef, 100, v100);
    try testing.expect(ok == .ok);
    catalogRef = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&writeTransaction, catalogRef));
    writeTransaction.deinit();
}

test "a deleted primary key can be reinserted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_reinsert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 3);
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 7, 1 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 200, 8, 0 })).catalogRef;
    var out: [3]u64 = undefined;
    const v100 = (try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out)).?;
    catalogRef = (try delete(&writeTransaction, catalogRef, 100, v100)).ok;
    // primaryKey 100 can be reinserted after deletion
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 100, 70, 1 })).catalogRef;
    try testing.expectEqual(@as(u64, 2), try liveCount(&writeTransaction, catalogRef));
    writeTransaction.deinit();
}

test "objects persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj6.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogRef = try create(&writeTransaction, 2); // primaryKey + one value
        var index: u64 = 0;
        while (index < 1000) : (index += 1) catalogRef = (try insert(&writeTransaction, catalogRef, &.{ index, index * 2 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, 1000), try liveCount(&readTransaction, readTransaction.root()));
        var out: [2]u64 = undefined;
        _ = (try getByPrimaryKey(&readTransaction, readTransaction.root(), 777, &out)).?;
        try testing.expectEqual(@as(u64, 777), out[0]);
        try testing.expectEqual(@as(u64, 1554), out[1]);
        try testing.expectEqual(@as(?u64, null), try getByPrimaryKey(&readTransaction, readTransaction.root(), 5000, &out));
        readTransaction.end();
    }
}

test "100k objects with updates and deletes match a reference map after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj7.airdb");
    defer testing.allocator.free(path);
    var ref = std.AutoHashMap(u64, u64).init(testing.allocator); // primaryKey -> property1 value, live only
    defer ref.deinit();
    const N: u64 = 100_000;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogRef = try create(&writeTransaction, 2);
        var out: [2]u64 = undefined;
        var index: u64 = 0;
        while (index < N) : (index += 1) {
            const primaryKey = (index *% 2654435761) % 5_000_011;
            if ((try getByPrimaryKey(&writeTransaction, catalogRef, primaryKey, &out)) != null) continue; // skip hash collision (dup primaryKey)
            catalogRef = (try insert(&writeTransaction, catalogRef, &.{ primaryKey, index })).catalogRef;
            try ref.put(primaryKey, index);
        }
        // Snapshot the live keys, then update every 5th and delete every 7th.
        var keys = std.ArrayList(u64).empty;
        defer keys.deinit(testing.allocator);
        var kit = ref.keyIterator();
        while (kit.next()) |key| try keys.append(testing.allocator, key.*);
        for (keys.items, 0..) |primaryKey, position| {
            const version = (try getByPrimaryKey(&writeTransaction, catalogRef, primaryKey, &out)).?;
            if (position % 5 == 0) {
                const res = try update(&writeTransaction, catalogRef, primaryKey, &.{ primaryKey, out[1] +% 1 }, version);
                catalogRef = res.ok.catalogRef;
                try ref.put(primaryKey, out[1] +% 1);
            } else if (position % 7 == 0) {
                const res = try delete(&writeTransaction, catalogRef, primaryKey, version);
                catalogRef = res.ok;
                _ = ref.remove(primaryKey);
            }
        }
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, ref.count()), try liveCount(&readTransaction, readTransaction.root()));
        var out: [2]u64 = undefined;
        var iterator = ref.iterator();
        while (iterator.next()) |err| {
            const version = try getByPrimaryKey(&readTransaction, readTransaction.root(), err.key_ptr.*, &out);
            try testing.expect(version != null);
            try testing.expectEqual(err.value_ptr.*, out[1]);
        }
        readTransaction.end();
    }
}

test "typed insert and get round-trip a string property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob, .int });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 30 } })).catalogRef;
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .bytes = "Linus" }, .{ .int = 54 } })).catalogRef;
    var out: [3]Value = undefined;
    const version = try getTyped(&writeTransaction, catalogRef, 2, &out);
    try testing.expect(version != null);
    try testing.expectEqual(@as(u64, 2), out[0].int);
    try testing.expectEqualStrings("Linus", out[1].bytes);
    try testing.expectEqual(@as(u64, 54), out[2].int);
    writeTransaction.deinit();
}

test "typed update on a stale version does not free the old blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_stale.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).catalogRef;
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    // stale-version update must NOT free the old blob (conflict path)
    const conflict = try updateTyped(&writeTransaction, catalogRef, 1, &.{ .{ .int = 1 }, .{ .bytes = "X" } }, version + 1);
    try testing.expect(conflict == .conflict);
    _ = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    try testing.expectEqualStrings("short", out[1].bytes);
    writeTransaction.deinit();
}

test "typed update replaces a string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_replace.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).catalogRef;
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    const ures = try updateTyped(&writeTransaction, catalogRef, 1, &.{ .{ .int = 1 }, .{ .bytes = "a much longer value" } }, version);
    catalogRef = ures.ok.catalogRef;
    _ = try getTyped(&writeTransaction, catalogRef, 1, &out);
    try testing.expectEqualStrings("a much longer value", out[1].bytes);
    writeTransaction.deinit();
}

test "typed delete removes the row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_delete.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).catalogRef;
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    const dres = try deleteTyped(&writeTransaction, catalogRef, 1, version);
    catalogRef = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getTyped(&writeTransaction, catalogRef, 1, &out));
    writeTransaction.deinit();
}

test "strings persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str3.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob });
        var index: u64 = 0;
        var buffer: [32]u8 = undefined;
        while (index < 500) : (index += 1) {
            const name = try std.fmt.bufPrint(&buffer, "name-{d}", .{index});
            catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = index }, .{ .bytes = name } })).catalogRef;
        }
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        var out: [2]Value = undefined;
        _ = (try getTyped(&readTransaction, readTransaction.root(), 321, &out)).?;
        try testing.expectEqualStrings("name-321", out[1].bytes);
        readTransaction.end();
    }
}

test "a large blob property decodes to a ref and materializes; small stays inline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "bigblob.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob });

    // A blob well past the inline cap (sectionSize is 16 MiB) forces chunking.
    const count: usize = 20 * 1024 * 1024;
    const big = try testing.allocator.alloc(u8, count);
    defer testing.allocator.free(big);
    for (big, 0..) |*byte, index| byte.* = @intCast(index % 251);

    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .bytes = big } })).catalogRef;
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .bytes = "small" } })).catalogRef;

    // The large blob decodes to a ref, not an inline slice.
    var out: [2]Value = undefined;
    try testing.expect((try getTyped(&writeTransaction, catalogRef, 1, &out)) != null);
    try testing.expect(out[1] == .blobRef);

    // Materialize it and verify length + sampled offsets + first/last KB.
    const got = try blob.getAlloc(&writeTransaction, out[1].blobRef, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(count, got.len);
    try testing.expectEqualSlices(u8, big[0..1024], got[0..1024]);
    try testing.expectEqualSlices(u8, big[count - 1024 ..], got[count - 1024 ..]);
    try testing.expectEqual(big[count / 2], got[count / 2]);
    try testing.expectEqual(big[12_345_678], got[12_345_678]);

    // A small blob in the same property still decodes to a zero-copy slice.
    try testing.expect((try getTyped(&writeTransaction, catalogRef, 2, &out)) != null);
    try testing.expect(out[1] == .bytes);
    try testing.expectEqualStrings("small", out[1].bytes);
    writeTransaction.deinit();
}

test "getByObjectKey reads a row by its stable object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "objectKey.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 2);
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 100, 7 });
    catalogRef = inserted0.catalogRef;
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 200, 8 });
    catalogRef = inserted1.catalogRef;
    var out: [2]u64 = undefined;
    const version1 = try getByObjectKey(&writeTransaction, catalogRef, inserted1.objectKey, &out);
    try testing.expect(version1 != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&writeTransaction, catalogRef, 999, &out));
    const fetchedVersion = (try getByObjectKey(&writeTransaction, catalogRef, inserted0.objectKey, &out)).?;
    const dres = try delete(&writeTransaction, catalogRef, 100, fetchedVersion);
    catalogRef = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&writeTransaction, catalogRef, inserted0.objectKey, &out));
    writeTransaction.deinit();
}

test "getByObjectKey resolves through the key-to-row index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "objectKeyIndex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 2);
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 100, 7 });
    catalogRef = inserted0.catalogRef;
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 200, 8 });
    catalogRef = inserted1.catalogRef;
    var out: [2]u64 = undefined;
    try testing.expect((try getByObjectKey(&writeTransaction, catalogRef, inserted0.objectKey, &out)) != null);
    try testing.expectEqual(@as(u64, 100), out[0]);
    try testing.expectEqual(@as(u64, 7), out[1]);
    try testing.expect((try getByObjectKey(&writeTransaction, catalogRef, inserted1.objectKey, &out)) != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    // An object key with no mapping resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&writeTransaction, catalogRef, 999, &out));
    writeTransaction.deinit();
}

// Collect, in ascending order, the object keys held in the value index's inner
// set for (catalogRef, property, value). Empty/absent yields an empty list.
fn collectIndexObjectKeys(
    transaction: anytype,
    catalogRef: Reference,
    property: usize,
    value: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const view = try loadCatalog(transaction, catalogRef);
    const valueIndexRef = view.valueIndexRef(property);
    const inner = (try Index.get(transaction, valueIndexRef, value)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, inner, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

fn expectIndexObjectKeys(
    transaction: anytype,
    catalogRef: Reference,
    property: usize,
    value: u64,
    expected: []const u64,
) !void {
    var got = std.ArrayList(u64).empty;
    defer got.deinit(testing.allocator);
    try collectIndexObjectKeys(transaction, catalogRef, property, value, &got, testing.allocator);
    try testing.expectEqualSlices(u64, expected, got.items);
}

test "value index tracks inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_insert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 1, 10 });
    catalogRef = inserted0.catalogRef;
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 2, 20 });
    catalogRef = inserted1.catalogRef;
    const inserted2 = try insert(&writeTransaction, catalogRef, &.{ 3, 10 });
    catalogRef = inserted2.catalogRef;
    const inserted3 = try insert(&writeTransaction, catalogRef, &.{ 4, 30 });
    catalogRef = inserted3.catalogRef;
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 10, &.{ inserted0.objectKey, inserted2.objectKey });
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 20, &.{inserted1.objectKey});
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 30, &.{inserted3.objectKey});
    writeTransaction.deinit();
}

test "value index tracks updates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_update.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 1, 10 });
    catalogRef = inserted0.catalogRef;
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 2, 20 });
    catalogRef = inserted1.catalogRef;
    const inserted2 = try insert(&writeTransaction, catalogRef, &.{ 3, 10 });
    catalogRef = inserted2.catalogRef;
    // Move o1's indexed property from 20 to 10.
    var out: [2]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, catalogRef, 2, &out)).?;
    const res = try update(&writeTransaction, catalogRef, 2, &.{ 2, 10 }, version);
    try testing.expect(res == .ok);
    catalogRef = res.ok.catalogRef;
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 10, &.{ inserted0.objectKey, inserted1.objectKey, inserted2.objectKey });
    // The 20 entry is now empty.
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 20, &.{});
    writeTransaction.deinit();
}

test "value index tracks deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_delete.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 1, 10 });
    catalogRef = inserted0.catalogRef;
    const inserted1 = try insert(&writeTransaction, catalogRef, &.{ 2, 20 });
    catalogRef = inserted1.catalogRef;
    const inserted2 = try insert(&writeTransaction, catalogRef, &.{ 3, 10 });
    catalogRef = inserted2.catalogRef;
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 10, &.{ inserted0.objectKey, inserted2.objectKey });
    // Delete o0 (value 10); only o2 should remain under 10.
    var out: [2]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    catalogRef = (try delete(&writeTransaction, catalogRef, 1, version)).ok;
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 10, &.{inserted2.objectKey});
    try expectIndexObjectKeys(&writeTransaction, catalogRef, 1, 20, &.{inserted1.objectKey});
    writeTransaction.deinit();
}

test "updateTyped carries collection properties through unchanged" {
    // Regression: updating any row of a collection-bearing type hit
    // `unreachable` (panic in Debug, UB in release). Collections are now
    // carried through; mutate them via their own APIs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "utyped_coll.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int }, .{ .kind = .list, .element = .int } });
    catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .int = 10 }, .{ .listInt = &.{ 7, 8, 9 } } })).catalogRef;

    var out: [3]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    const res = try updateTyped(&writeTransaction, catalogRef, 1, &.{ .{ .int = 1 }, .{ .int = 20 }, out[2] }, version);
    try testing.expect(res == .ok);
    catalogRef = res.ok.catalogRef;

    _ = (try getTyped(&writeTransaction, catalogRef, 1, &out)).?;
    try testing.expectEqual(@as(u64, 20), out[1].int);
    try testing.expectEqual(@as(?u64, 3), try collections.listLength(&writeTransaction, catalogRef, 1, 2));
    try testing.expectEqual(@as(u64, 8), try collections.listGetInt(&writeTransaction, catalogRef, 1, 2, 1));
}

test "deleteTyped frees the row's collection storage" {
    // Regression: deleted rows leaked their list/set/dict trees (and element
    // and key blobs) permanently -- unreclaimable except by a full file copy.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "del_coll_free.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a row carrying every collection kind so its trees are committed.
    {
        var writeTransaction = try database.beginWrite();
        var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = .list, .element = .blob },
            .{ .kind = .set, .element = .int },
            .{ .kind = .dict },
        });
        catalogRef = (try insertTyped(&writeTransaction, catalogRef, &.{
            .{ .int = 1 },
            .{ .listBlob = &.{ "alpha", "beta" } },
            .{ .setInt = &.{ 1, 2, 3 } },
            .{ .dictInt = &.{ .{ .key = "k1", .value = 10 }, .{ .key = "k2", .value = 20 } } },
        })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    // Deleting the row must record the collection trees as in-flight frees.
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var out: [4]Value = undefined;
    const version = (try getTyped(&writeTransaction, writeTransaction.newRoot, 1, &out)).?;
    const before = writeTransaction.inFlightFrees.items.len;
    const res = try deleteTyped(&writeTransaction, writeTransaction.newRoot, 1, version);
    try testing.expect(res == .ok);
    // list tree + 2 element blobs + set tree + dict tree + 2 key blobs, plus
    // the COW frees of the delete itself: well above the tombstone-only count.
    try testing.expect(writeTransaction.inFlightFrees.items.len >= before + 7);
}

test "updateTyped moves backlinks when a link value changes" {
    // Regression: updateTyped encoded the new link into the column but never
    // touched the backlink index, leaving the old target's set naming this
    // source forever and the new target's set missing it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "utyped_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const insertedA = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = insertedA.catalogRef;
    const insertedB = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = insertedB.catalogRef;
    const insertedC = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 3 }, .{ .link = insertedA.objectKey } });
    catalogRef = insertedC.catalogRef;

    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, catalogRef, 3, &out)).?;
    const res = try updateTyped(&writeTransaction, catalogRef, 3, &.{ .{ .int = 3 }, .{ .link = insertedB.objectKey } }, version);
    try testing.expect(res == .ok);
    catalogRef = res.ok.catalogRef;

    const linksMod = @import("links.zig");
    try testing.expectEqual(@as(u64, 0), try linksMod.backlinkCount(&writeTransaction, catalogRef, 1, insertedA.objectKey));
    try testing.expectEqual(@as(u64, 1), try linksMod.backlinkCount(&writeTransaction, catalogRef, 1, insertedB.objectKey));
    // Deleting the NEW target nullifies the source's link.
    var raw: [2]u64 = undefined;
    const targetVersion = (try getByPrimaryKey(&writeTransaction, catalogRef, 2, &raw)).?;
    catalogRef = switch (try deleteAndNullify(&writeTransaction, catalogRef, 2, targetVersion)) {
        .ok => |newCatalog| newCatalog,
        else => unreachable,
    };
    try testing.expectEqual(@as(?u64, null), try linksMod.getLink(&writeTransaction, catalogRef, 3, 1));
}

test "a multi-leaf value-index set is pruned and freed when emptied" {
    // The single-leaf prune case is covered elsewhere; this drives the inner
    // set past one leaf (>64 members) so freeTree's inner-node recursion runs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_prune_big.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    const count: u64 = 80;
    var primaryKey: u64 = 1;
    while (primaryKey <= count) : (primaryKey += 1) catalogRef = (try insert(&writeTransaction, catalogRef, &.{ primaryKey, 7 })).catalogRef;
    var out: [2]u64 = undefined;
    primaryKey = 1;
    while (primaryKey <= count) : (primaryKey += 1) {
        const version = (try getByPrimaryKey(&writeTransaction, catalogRef, primaryKey, &out)).?;
        catalogRef = (try delete(&writeTransaction, catalogRef, primaryKey, version)).ok;
    }
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.valueIndexRef(1), 7));
    try testing.expectEqual(@as(u64, 0), try Index.count(&writeTransaction, view.valueIndexRef(1)));
}

test "an emptied value-index set is pruned from the outer index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_prune.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 1, 10 })).catalogRef;
    catalogRef = (try insert(&writeTransaction, catalogRef, &.{ 2, 10 })).catalogRef;
    // Delete both rows carrying value 10: the 10 entry must disappear entirely,
    // not linger as an empty set.
    var out: [2]u64 = undefined;
    var primaryKey: u64 = 1;
    while (primaryKey <= 2) : (primaryKey += 1) {
        const version = (try getByPrimaryKey(&writeTransaction, catalogRef, primaryKey, &out)).?;
        catalogRef = (try delete(&writeTransaction, catalogRef, primaryKey, version)).ok;
    }
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(?u64, null), try Index.get(&writeTransaction, view.valueIndexRef(1), 10));
    try testing.expectEqual(@as(u64, 0), try Index.count(&writeTransaction, view.valueIndexRef(1)));
}

test "non-indexed property has no index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vidx_none.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const inserted0 = try insert(&writeTransaction, catalogRef, &.{ 1, 100 });
    catalogRef = inserted0.catalogRef;
    var out: [2]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    catalogRef = (try update(&writeTransaction, catalogRef, 1, &.{ 1, 200 }, version)).ok.catalogRef;
    const ver2 = (try getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)).?;
    catalogRef = (try delete(&writeTransaction, catalogRef, 1, ver2)).ok;
    const view = try loadCatalog(&writeTransaction, catalogRef);
    var index: usize = 0;
    while (index < view.propertyCount) : (index += 1) try testing.expectEqual(@as(Reference, 0), view.valueIndexRef(index));
    writeTransaction.deinit();
}

test "reinserting a primary key after delete yields a new object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey_reinsert.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try create(&writeTransaction, 2);
    const first = try insert(&writeTransaction, catalogRef, &.{ 100, 7 });
    catalogRef = first.catalogRef;
    const objectKeyA = first.objectKey;
    var out: [2]u64 = undefined;
    const version = (try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out)).?;
    catalogRef = (try delete(&writeTransaction, catalogRef, 100, version)).ok;
    const second = try insert(&writeTransaction, catalogRef, &.{ 100, 70 });
    catalogRef = second.catalogRef;
    const objectKeyB = second.objectKey;
    try testing.expect(objectKeyA != objectKeyB);
    // The old object key is tombstoned and resolves to null.
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&writeTransaction, catalogRef, objectKeyA, &out));
    // The new object key returns the new row.
    try testing.expect((try getByObjectKey(&writeTransaction, catalogRef, objectKeyB, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    // Lookup by primaryKey returns the new values.
    try testing.expect((try getByPrimaryKey(&writeTransaction, catalogRef, 100, &out)) != null);
    try testing.expectEqual(@as(u64, 70), out[1]);
    writeTransaction.deinit();
}

test "deleteTyped frees a self-referencing linkSet root exactly once" {
    // Regression: deleting a row whose linkSet contained its own objectKey freed
    // the set root twice. The inbound nullify removed objectKey from the row's own
    // set -- a COW whose Index.remove freed the old root -- and the delete's
    // storage reclamation then freed the same root again from the captured
    // column raw, handing one extent to two future allocations. The nullify
    // now leaves a self-sourced set untouched; no freed offset may repeat.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "selfset.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var writeTransaction = try database.beginWrite();
        var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = .linkSet },
        });
        const ins = try insertTyped(&writeTransaction, catalogRef, &.{ .{ .int = 1 }, .{ .linkSet = &.{} } });
        catalogRef = ins.catalogRef;
        catalogRef = try links.linkSetAdd(&writeTransaction, catalogRef, 1, 1, ins.objectKey); // set contains own objectKey
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var out: [2]Value = undefined;
    const version = (try getTyped(&writeTransaction, writeTransaction.newRoot, 1, &out)).?;
    const res = try deleteTyped(&writeTransaction, writeTransaction.newRoot, 1, version);
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
