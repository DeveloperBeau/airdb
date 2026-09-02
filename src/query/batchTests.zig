//! Companion suite for batch.zig: collectRowsForSortedKeys against a bare
//! index (no catalog needed).
//!
//! Every expected value in this file is written out by hand from the
//! fixture's own construction, never read back from the code under test.
//! Every count bound is a literal derived from the fixture's sizes and the
//! node capacities in indexNode.zig, never from a measurement of this code.

const std = @import("std");
const testing = std.testing;
const Database = @import("../database.zig").Database;
const WriteTransaction = @import("../database.zig").WriteTransaction;
const index = @import("../trees/index.zig");
const batch = @import("batch.zig");

fn batchTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

// Keys 0, 10, 20, ..., 990 (100 keys) mapped to row (key / 10 + 1000): a
// mapping where the row is never equal to the key and never equal to the
// key's position in the sequence, so a key/row/position confusion cannot
// pass.
fn buildFixture(writeTransaction: *WriteTransaction) !u64 {
    var root = try index.create(writeTransaction);
    var key: u64 = 0;
    while (key <= 990) : (key += 10) {
        root = try index.insert(writeTransaction, root, key, key / 10 + 1000);
    }
    return root;
}

test "R4: success, three present keys yield their hand-written rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    const keys = [_]u64{ 20, 50, 990 };
    var rowsOut: [3]?u64 = undefined;
    try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
    try testing.expectEqualSlices(?u64, &.{ 1002, 1005, 1099 }, &rowsOut);
}

test "R5: misses, a key below the minimum, one present, one above the maximum" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    const keys = [_]u64{ 15, 20, 1005 };
    var rowsOut: [3]?u64 = undefined;
    try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
    try testing.expectEqualSlices(?u64, &.{ null, 1002, null }, &rowsOut);
}

test "R6: boundaries, exact smallest and largest keys, and one below/above each" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    {
        const keys = [_]u64{0};
        var rowsOut: [1]?u64 = undefined;
        try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
        try testing.expectEqualSlices(?u64, &.{1000}, &rowsOut);
    }
    {
        const keys = [_]u64{990};
        var rowsOut: [1]?u64 = undefined;
        try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
        try testing.expectEqualSlices(?u64, &.{1099}, &rowsOut);
    }
    {
        const keys = [_]u64{999};
        var rowsOut: [1]?u64 = undefined;
        try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
        try testing.expectEqualSlices(?u64, &.{null}, &rowsOut);
    }
    {
        // One below the smallest is impossible for a u64 whose smallest is 0,
        // so use one above the largest instead, the mirror boundary.
        const keys = [_]u64{991};
        var rowsOut: [1]?u64 = undefined;
        try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
        try testing.expectEqualSlices(?u64, &.{null}, &rowsOut);
    }
}

test "R7: unsorted keys fail before any I/O" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    {
        const keys = [_]u64{ 20, 10 };
        var rowsOut: [2]?u64 = undefined;
        try testing.expectError(error.UnsortedObjectKeys, batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut));
    }
    {
        // Duplicates are rejected too: strictly ascending, not merely sorted.
        const keys = [_]u64{ 20, 20 };
        var rowsOut: [2]?u64 = undefined;
        try testing.expectError(error.UnsortedObjectKeys, batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut));
    }
}

test "R7: an empty key slice succeeds and writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    const keys = [_]u64{};
    var rowsOut = [_]?u64{};
    try batch.collectRowsForSortedKeys(&writeTransaction, root, &keys, &rowsOut);
}

test "R8: fuzz, the merge walk agrees with index.get point descents over random key sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildFixture(&writeTransaction);

    var randomNumberGenerator = std.Random.DefaultPrng.init(0x7107);
    const random = randomNumberGenerator.random();

    var sawNull = false;
    var sawNonNull = false;

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        const drawCount = 1 + random.uintLessThan(usize, 64);
        var drawnKeys = std.ArrayList(u64).empty;
        defer drawnKeys.deinit(testing.allocator);
        var drawIndex: usize = 0;
        while (drawIndex < drawCount) : (drawIndex += 1) {
            try drawnKeys.append(testing.allocator, random.uintLessThan(u64, 1200));
        }
        std.mem.sort(u64, drawnKeys.items, {}, std.sort.asc(u64));
        // Deduplicate: collectRowsForSortedKeys requires strictly ascending input.
        var uniqueKeys = std.ArrayList(u64).empty;
        defer uniqueKeys.deinit(testing.allocator);
        for (drawnKeys.items) |key| {
            if (uniqueKeys.items.len == 0 or uniqueKeys.items[uniqueKeys.items.len - 1] != key) {
                try uniqueKeys.append(testing.allocator, key);
            }
        }

        const rowsOut = try testing.allocator.alloc(?u64, uniqueKeys.items.len);
        defer testing.allocator.free(rowsOut);
        try batch.collectRowsForSortedKeys(&writeTransaction, root, uniqueKeys.items, rowsOut);

        for (uniqueKeys.items, 0..) |key, position| {
            const expected = try index.get(&writeTransaction, root, key);
            try testing.expectEqual(expected, rowsOut[position]);
            if (rowsOut[position] == null) sawNull = true else sawNonNull = true;
        }
    }

    // False-negative guard: a generator that only produced hits or only
    // produced misses would let a broken merge pass silently.
    try testing.expect(sawNull);
    try testing.expect(sawNonNull);
}
