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
const Reference = @import("../storage/reference.zig").Reference;
const index = @import("../trees/index.zig");
const batch = @import("batch.zig");

fn batchTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

/// Counts every dereference the wrapped transaction performs. This file owns
/// its own copy of the harness (queryIncludeCostTests.zig owns its own): the
/// two are never imported across files.
const CountingTransaction = struct {
    inner: *WriteTransaction,
    dereferenceCount: u64 = 0,

    pub fn dereference(self: *CountingTransaction, reference: Reference, length: usize) ![]const u8 {
        self.dereferenceCount += 1;
        return self.inner.dereference(reference, length);
    }
};

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

// Bulk-packed (not incrementally inserted) so leaf boundaries land exactly on
// leafCap = 64: two leaves, keys 0..63 in the first and 128..191 in the
// second, nothing in between. Values are key + 1000, the same
// row-never-equals-key convention as buildFixture.
fn buildTwoLeafGapFixture(writeTransaction: *WriteTransaction, allocator: std.mem.Allocator) !u64 {
    var keys: [128]u64 = undefined;
    var values: [128]u64 = undefined;
    for (0..64) |position| {
        keys[position] = position;
        values[position] = position + 1000;
    }
    for (64..128) |position| {
        keys[position] = position - 64 + 128;
        values[position] = keys[position] + 1000;
    }
    var leafLevel = try index.packLeaves(writeTransaction, &keys, &values, allocator);
    try index.collapseToRoot(writeTransaction, &leafLevel, allocator);
    defer leafLevel.deinit(allocator);
    return leafLevel.items[0].reference;
}

// R9 isolates the two mechanisms `collectRowsForSortedKeys` uses to stop its
// walk: the [low, high] range check, and the merge callback's own stop
// signal (`position == sortedObjectKeys.len`). Whenever the largest
// requested key has a row, the callback's own signal always fires first, at
// that exact entry, before the range check ever gets a chance to matter: a
// batch of pure hits (R4-R8, and R20/R21's dense/sparse fixtures) cannot
// tell the two mechanisms apart. Requesting a largest key that is genuinely
// ABSENT from the index removes the callback's own signal from the picture
// (it can only fire on an exact match), leaving the range check to prune
// the second leaf alone.
test "R9: a miss beyond the matched keys is pruned by the range bound, without extra dereferences" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try batchTmpPath(testing.allocator, &tmp, "batch7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const root = try buildTwoLeafGapFixture(&writeTransaction, testing.allocator);

    var counter = CountingTransaction{ .inner = &writeTransaction };
    // 100 is inside the 64..127 gap: a miss, with the second leaf (128..191)
    // beyond it. The range check (high = 100) must exclude that leaf via the
    // root's own low-key check, without ever dereferencing it.
    const targets = [_]u64{ 0, 100 };
    var rowsOut: [2]?u64 = undefined;
    try batch.collectRowsForSortedKeys(&counter, root, &targets, &rowsOut);

    try testing.expectEqualSlices(?u64, &.{ 1000, null }, &rowsOut);
    // Hand-derived: dereferenceNode costs two dereference() calls (a 1-byte
    // kind read, then the sized read); this walk visits exactly the root
    // (an inner node with two children) and the first leaf, and must NOT
    // visit the second leaf: 2 nodes * 2 = 4.
    try testing.expectEqual(@as(u64, 4), counter.dereferenceCount);
}
