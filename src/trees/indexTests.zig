// indexTests.zig -- test suite for the u64-keyed B+tree in index.zig.

const std = @import("std");
const testing = std.testing;
const Database = @import("../database.zig").Database;
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const index = @import("index.zig");
const node = @import("indexNode.zig");

const create = index.create;
const insert = index.insert;
const get = index.get;
const remove = index.remove;
const count = index.count;
const maxKey = index.maxKey;
const forEachKey = index.forEachKey;
const forEachEntry = index.forEachEntry;
const forEachEntryInRange = index.forEachEntryInRange;
const appendRun = index.appendRun;
const makeInnerForTest = index.makeInnerForTest;

const leafNodeSize = node.leafNodeSize;
const innerNodeSize = node.innerNodeSize;
const encodeLeaf = node.encodeLeaf;
const encodeInner = node.encodeInner;

fn idxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "a reference cycle or unknown kind byte fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // An inner node whose only child is itself: every walk must hit the depth
    // cap and error out rather than overflow the stack. (count is exempt: it is
    // a single-node read of the stored subtree counts and never descends.)
    const allocation = try writeTransaction.alloc(innerNodeSize);
    _ = encodeInner(allocation.bytes, &.{allocation.reference}, &.{0}, &.{1});
    try testing.expectError(error.Corrupt, get(&writeTransaction, allocation.reference, 5));
    try testing.expectError(error.Corrupt, maxKey(&writeTransaction, allocation.reference));
    try testing.expectError(error.Corrupt, insert(&writeTransaction, allocation.reference, 1, 1));
    try testing.expectError(error.Corrupt, remove(&writeTransaction, allocation.reference, 1));
    const NopSink = struct {
        fn onKey(_: @This(), _: u64) !void {}
    };
    try testing.expectError(error.Corrupt, forEachKey(&writeTransaction, allocation.reference, NopSink{}, NopSink.onKey));

    // A node with an out-of-range kind byte is rejected outright.
    const allocationB = try writeTransaction.alloc(leafNodeSize);
    _ = encodeLeaf(allocationB.bytes, &.{}, &.{});
    // Rewrite the kind byte through the arena (b.bytes is mutable).
    allocationB.bytes[0] = 7;
    try testing.expectError(error.Corrupt, get(&writeTransaction, allocationB.reference, 1));
}

test "get and count traverse an inner node over two leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var leftLeaf = try create(&writeTransaction);
    leftLeaf = try insert(&writeTransaction, leftLeaf, 1, 11);
    leftLeaf = try insert(&writeTransaction, leftLeaf, 3, 33);
    var rightLeaf = try create(&writeTransaction);
    rightLeaf = try insert(&writeTransaction, rightLeaf, 5, 55);
    rightLeaf = try insert(&writeTransaction, rightLeaf, 7, 77);
    const inner = try makeInnerForTest(&writeTransaction, &.{ .{ .reference = leftLeaf, .low = 1, .count = 2 }, .{ .reference = rightLeaf, .low = 5, .count = 2 } });
    try testing.expectEqual(@as(u64, 4), try count(&writeTransaction, inner));
    try testing.expectEqual(@as(?u64, 11), try get(&writeTransaction, inner, 1));
    try testing.expectEqual(@as(?u64, 55), try get(&writeTransaction, inner, 5));
    try testing.expectEqual(@as(?u64, 77), try get(&writeTransaction, inner, 7));
    try testing.expect((try get(&writeTransaction, inner, 6)) == null);
    try testing.expect((try get(&writeTransaction, inner, 0)) == null);
    writeTransaction.deinit();
}

test "insert builds a balanced tree across many leaves and reads back correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    const N: u64 = 5000;
    var position: u64 = 0;
    while (position < N) : (position += 1) {
        const key = (position *% 2654435761) % 1_000_003; // scattered keys force mid-splits
        root = try insert(&writeTransaction, root, key, key +% 7);
    }
    var referenceMap = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer referenceMap.deinit();
    position = 0;
    while (position < N) : (position += 1) {
        const key = (position *% 2654435761) % 1_000_003;
        try referenceMap.put(key, key +% 7);
    }
    try testing.expectEqual(@as(u64, referenceMap.count()), try count(&writeTransaction, root));
    var iterator = referenceMap.iterator();
    while (iterator.next()) |err| {
        try testing.expectEqual(@as(?u64, err.value_ptr.*), try get(&writeTransaction, root, err.key_ptr.*));
    }
    writeTransaction.deinit();
}

test "single-leaf index: insert, get, upsert, remove, count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    try testing.expect((try get(&writeTransaction, root, 5)) == null);
    root = try insert(&writeTransaction, root, 5, 50);
    root = try insert(&writeTransaction, root, 1, 10);
    root = try insert(&writeTransaction, root, 9, 90);
    try testing.expectEqual(@as(u64, 3), try count(&writeTransaction, root));
    try testing.expectEqual(@as(?u64, 50), try get(&writeTransaction, root, 5));
    try testing.expectEqual(@as(?u64, 10), try get(&writeTransaction, root, 1));
    root = try insert(&writeTransaction, root, 5, 555);
    try testing.expectEqual(@as(?u64, 555), try get(&writeTransaction, root, 5));
    try testing.expectEqual(@as(u64, 3), try count(&writeTransaction, root));
    root = try remove(&writeTransaction, root, 1);
    try testing.expect((try get(&writeTransaction, root, 1)) == null);
    try testing.expectEqual(@as(u64, 2), try count(&writeTransaction, root));
    writeTransaction.deinit();
}

test "a committed index version stays intact for a pinned reader while a later commit mutates it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit version 1: keys 0..1999, value = key*10.
    {
        var writeTransaction = try database.beginWrite();
        var root = try create(&writeTransaction);
        var position: u64 = 0;
        while (position < 2000) : (position += 1) root = try insert(&writeTransaction, root, position, position * 10);
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }

    // Pin a reader on version 1.
    var readTransaction1 = try database.beginRead();
    const rootV1 = readTransaction1.root();
    try testing.expectEqual(@as(?u64, 1234 * 10), try get(&readTransaction1, rootV1, 1234));

    // Commit version 2: update key 1234, remove key 500.
    {
        var writeTransaction = try database.beginWrite();
        var root = writeTransaction.newRoot; // start from the latest committed root (refreshed in beginWrite)
        root = try insert(&writeTransaction, root, 1234, 999999);
        root = try remove(&writeTransaction, root, 500);
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }

    // The pinned v1 reader still sees the original values (committed snapshot intact).
    try testing.expectEqual(@as(?u64, 1234 * 10), try get(&readTransaction1, rootV1, 1234));
    try testing.expectEqual(@as(?u64, 500 * 10), try get(&readTransaction1, rootV1, 500));
    readTransaction1.end();

    // A fresh read sees version 2.
    var readTransaction2 = try database.beginRead();
    try testing.expectEqual(@as(?u64, 999999), try get(&readTransaction2, readTransaction2.root(), 1234));
    try testing.expect((try get(&readTransaction2, readTransaction2.root(), 500)) == null);
    try testing.expectEqual(@as(?u64, 1235 * 10), try get(&readTransaction2, readTransaction2.root(), 1235)); // untouched key
    readTransaction2.end();
}

test "maxKey survives an emptied rightmost leaf" {
    // Removals never merge or drop leaves, so deleting the upper key range
    // leaves an EMPTY rightmost leaf. maxKey must keep descending into the
    // last non-empty subtree instead of reporting the tree empty -- bulkAppend
    // uses maxKey to qualify batches, and a false "empty" admits keys below
    // the true maximum.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx_maxkey.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var root = try create(&writeTransaction);
    var key: u64 = 0;
    while (key <= 64) : (key += 1) root = try insert(&writeTransaction, root, key, key); // forces a leaf split
    try testing.expectEqual(@as(?u64, 64), try maxKey(&writeTransaction, root));
    // Empty the rightmost leaf by removing the upper half.
    key = 32;
    while (key <= 64) : (key += 1) root = try remove(&writeTransaction, root, key);
    try testing.expectEqual(@as(?u64, 31), try maxKey(&writeTransaction, root));
    // Fully emptied tree reports null.
    key = 0;
    while (key < 32) : (key += 1) root = try remove(&writeTransaction, root, key);
    try testing.expectEqual(@as(?u64, null), try maxKey(&writeTransaction, root));
}

test "stored subtree counts match a full iteration under churn" {
    // count() reads per-child subtree counts from a single node. Verify the
    // stored counts stay exact through scattered inserts (with splits and
    // height growth), upserts (which must NOT bump counts), and removes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx_counts.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var root = try create(&writeTransaction);
    const N: u64 = 5000;
    var position: u64 = 0;
    while (position < N) : (position += 1) {
        const key = (position *% 2654435761) % 1_000_003;
        root = try insert(&writeTransaction, root, key, key);
    }
    // Upserts: rewrite existing keys; counts must not change.
    position = 0;
    while (position < 500) : (position += 1) {
        const key = (position *% 2654435761) % 1_000_003;
        root = try insert(&writeTransaction, root, key, key + 1);
    }
    // Remove every 3rd inserted key.
    position = 0;
    while (position < N) : (position += 3) {
        const key = (position *% 2654435761) % 1_000_003;
        root = try remove(&writeTransaction, root, key);
    }

    const Tally = struct {
        total: *u64,
        fn onKey(self: @This(), _: u64) !void {
            self.total.* += 1;
        }
    };
    var walked: u64 = 0;
    try forEachKey(&writeTransaction, root, Tally{ .total = &walked }, Tally.onKey);
    try testing.expectEqual(walked, try count(&writeTransaction, root));
}

test "forEachKey visits all keys in ascending order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "iter.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    var position: u64 = 0;
    while (position < 500) : (position += 1) {
        const key = (position *% 2654435761) % 100_003;
        root = try insert(&writeTransaction, root, key, key + 1);
    }
    const Collector = struct {
        list: *std.ArrayList(u64),
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(testing.allocator, key);
        }
    };
    var seen = std.ArrayList(u64).empty;
    defer seen.deinit(testing.allocator);
    try forEachKey(&writeTransaction, root, Collector{ .list = &seen }, Collector.onKey);
    try testing.expectEqual(try count(&writeTransaction, root), @as(u64, seen.items.len));
    var prev: u64 = 0;
    var first = true;
    for (seen.items) |item| {
        if (!first) try testing.expect(item > prev);
        prev = item;
        first = false;
    }
    writeTransaction.deinit();
}

test "forEachEntry visits key/value pairs in ascending key order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "iter_entry.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    var position: u64 = 0;
    while (position < 200) : (position += 1) {
        const key = (position *% 2654435761) % 100_003; // scrambled insertion order
        root = try insert(&writeTransaction, root, key, key * 7 + 1);
    }
    const Collector = struct {
        keys: *std.ArrayList(u64),
        vals: *std.ArrayList(u64),
        fn onEntry(self: @This(), key: u64, val: u64) !void {
            try self.keys.append(testing.allocator, key);
            try self.vals.append(testing.allocator, val);
        }
    };
    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&writeTransaction, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);
    try testing.expectEqual(try count(&writeTransaction, root), @as(u64, keys.items.len));
    try testing.expectEqual(keys.items.len, vals.items.len);
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |key, val| {
        if (!first) try testing.expect(key > prev);
        try testing.expectEqual(key * 7 + 1, val);
        prev = key;
        first = false;
    }
    writeTransaction.deinit();
}

// Build a tree holding keys 0..=1000 (each once) inserted in scrambled order,
// with value == key*10. 397 is coprime to 1001 (=7*11*13), so (i*397)%1001
// visits every residue exactly once.
fn buildScrambled0to1000(writeTransaction: *WriteTransaction) !Reference {
    var root = try create(writeTransaction);
    var position: u64 = 0;
    while (position <= 1000) : (position += 1) {
        const key = (position * 397) % 1001;
        root = try insert(writeTransaction, root, key, key * 10);
    }
    return root;
}

const RangeCollector = struct {
    keys: *std.ArrayList(u64),
    vals: *std.ArrayList(u64),
    fn onEntry(self: @This(), key: u64, val: u64) !void {
        try self.keys.append(testing.allocator, key);
        try self.vals.append(testing.allocator, val);
    }
};

test "forEachEntryInRange visits only [lo,hi] ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const root = try buildScrambled0to1000(&writeTransaction);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntryInRange(&writeTransaction, root, 200, 300, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);

    try testing.expectEqual(@as(usize, 101), keys.items.len);
    try testing.expectEqual(keys.items.len, vals.items.len);
    var expected: u64 = 200;
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |key, val| {
        try testing.expectEqual(expected, key); // strictly ascending 200..300
        try testing.expectEqual(key * 10, val);
        try testing.expect(key >= 200 and key <= 300); // nothing outside
        if (!first) try testing.expect(key > prev);
        prev = key;
        first = false;
        expected += 1;
    }
    try testing.expectEqual(@as(u64, 200), keys.items[0]);
    try testing.expectEqual(@as(u64, 300), keys.items[keys.items.len - 1]);
    writeTransaction.deinit();
}

test "forEachEntryInRange empty range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const root = try buildScrambled0to1000(&writeTransaction);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // lo above the max key -> nothing.
    try forEachEntryInRange(&writeTransaction, root, 1001, 2000, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);

    // lo > hi -> nothing.
    try forEachEntryInRange(&writeTransaction, root, 300, 200, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);
    writeTransaction.deinit();
}

test "forEachEntryInRange single key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const root = try buildScrambled0to1000(&writeTransaction);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // Present single key.
    try forEachEntryInRange(&writeTransaction, root, 500, 500, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 1), keys.items.len);
    try testing.expectEqual(@as(u64, 500), keys.items[0]);
    try testing.expectEqual(@as(u64, 5000), vals.items[0]);

    // Absent single key.
    keys.clearRetainingCapacity();
    vals.clearRetainingCapacity();
    try forEachEntryInRange(&writeTransaction, root, 10001, 10001, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);
    writeTransaction.deinit();
}

test "forEachEntryInRange spans multiple leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const root = try buildScrambled0to1000(&writeTransaction);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // [50,800] crosses many leaves (leafCap == 64).
    try forEachEntryInRange(&writeTransaction, root, 50, 800, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);

    try testing.expectEqual(@as(usize, 751), keys.items.len); // 800-50+1
    try testing.expectEqual(@as(u64, 50), keys.items[0]);
    try testing.expectEqual(@as(u64, 800), keys.items[keys.items.len - 1]);
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |key, val| {
        if (!first) try testing.expect(key == prev + 1); // no gaps or dupes
        try testing.expectEqual(key * 10, val);
        prev = key;
        first = false;
    }
    writeTransaction.deinit();
}

test "ordered index persists across reopen and matches a reference map under churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx6.airdb");
    defer testing.allocator.free(path);
    var referenceMap = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer referenceMap.deinit();
    const N: u64 = 100_000;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var root = try create(&writeTransaction);
        var position: u64 = 0;
        while (position < N) : (position += 1) {
            const key = (position *% 2654435761) % 5_000_011;
            root = try insert(&writeTransaction, root, key, position);
            try referenceMap.put(key, position);
        }
        // Remove every 3rd inserted key.
        position = 0;
        while (position < N) : (position += 3) {
            const key = (position *% 2654435761) % 5_000_011;
            root = try remove(&writeTransaction, root, key);
            _ = referenceMap.remove(key);
        }
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqual(@as(u64, referenceMap.count()), try count(&readTransaction, readTransaction.root()));
        var iterator = referenceMap.iterator();
        while (iterator.next()) |err| {
            try testing.expectEqual(@as(?u64, err.value_ptr.*), try get(&readTransaction, readTransaction.root(), err.key_ptr.*));
        }
        // Spot-check some removed keys are absent.
        var innerPosition: u64 = 0;
        while (innerPosition < 30) : (innerPosition += 3) {
            const key = (innerPosition *% 2654435761) % 5_000_011;
            if (!referenceMap.contains(key)) try testing.expect((try get(&readTransaction, readTransaction.root(), key)) == null);
        }
        readTransaction.end();
    }
}

fn appendRunVal(key: u64) u64 {
    return key *% 7 +% 3;
}

fn appendTmpDatabase(tmp: *testing.TmpDir, name: []const u8) !Database {
    const path = try idxTmpPath(testing.allocator, tmp, name);
    defer testing.allocator.free(path);
    return Database.create(testing.allocator, path);
}

// Build a base tree of keys 0..base via sequential insert, append the run
// base..base+run via appendRun, and assert the result is logically identical
// to inserting all keys 0..base+run sequentially.
fn checkAppendEquiv(writeTransaction: *WriteTransaction, base: u64, run: u64) !void {
    var baseRoot = try create(writeTransaction);
    var key: u64 = 0;
    while (key < base) : (key += 1) baseRoot = try insert(writeTransaction, baseRoot, key, appendRunVal(key));

    const runKeys = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(runKeys);
    const runValues = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(runValues);
    var runIndex: u64 = 0;
    while (runIndex < run) : (runIndex += 1) {
        runKeys[runIndex] = base + runIndex;
        runValues[runIndex] = appendRunVal(base + runIndex);
    }

    const appended = try appendRun(writeTransaction, baseRoot, runKeys, runValues, testing.allocator);

    var expected = try create(writeTransaction);
    key = 0;
    while (key < base + run) : (key += 1) expected = try insert(writeTransaction, expected, key, appendRunVal(key));

    const total = base + run;
    try testing.expectEqual(total, try count(writeTransaction, appended));
    try testing.expectEqual(try count(writeTransaction, expected), try count(writeTransaction, appended));

    // Boundary + sampled get checks (compared against the sequential twin).
    var samples = std.ArrayList(u64).empty;
    defer samples.deinit(testing.allocator);
    if (total > 0) {
        try samples.append(testing.allocator, 0); // first key
        try samples.append(testing.allocator, total - 1); // last key
    }
    if (base > 0) {
        try samples.append(testing.allocator, base - 1); // seam: last base key
        try samples.append(testing.allocator, base); // seam: first run key (== total when run == 0)
    }
    if (total > 4) {
        try samples.append(testing.allocator, total / 4);
        try samples.append(testing.allocator, total / 2);
        try samples.append(testing.allocator, (3 * total) / 4);
    }
    for (samples.items) |sampleKey| {
        try testing.expectEqual(try get(writeTransaction, expected, sampleKey), try get(writeTransaction, appended, sampleKey));
    }
    // Beyond the max key is absent in both.
    try testing.expectEqual(@as(?u64, null), try get(writeTransaction, appended, total));
    try testing.expectEqual(try get(writeTransaction, expected, total), try get(writeTransaction, appended, total));

    // Full ascending (key,val) sequence must match exactly.
    var appendedKeys = std.ArrayList(u64).empty;
    defer appendedKeys.deinit(testing.allocator);
    var appendedValues = std.ArrayList(u64).empty;
    defer appendedValues.deinit(testing.allocator);
    var expectedKeys = std.ArrayList(u64).empty;
    defer expectedKeys.deinit(testing.allocator);
    var expectedValues = std.ArrayList(u64).empty;
    defer expectedValues.deinit(testing.allocator);
    try forEachEntry(writeTransaction, appended, RangeCollector{ .keys = &appendedKeys, .vals = &appendedValues }, RangeCollector.onEntry);
    try forEachEntry(writeTransaction, expected, RangeCollector{ .keys = &expectedKeys, .vals = &expectedValues }, RangeCollector.onEntry);
    try testing.expectEqualSlices(u64, expectedKeys.items, appendedKeys.items);
    try testing.expectEqualSlices(u64, expectedValues.items, appendedValues.items);
}

test "appendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append1.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkAppendEquiv(&writeTransaction, 100, 200); // 100 % 64 == 36 in the last leaf
    writeTransaction.deinit();
}

test "appendRun overflow rightmost inner node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append2.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // A multi-level base plus a run large enough that the new leaves alone
    // exceed fanout, forcing a split at the leaf-parent (non-root) inner level.
    try checkAppendEquiv(&writeTransaction, 3000, 5000);
    writeTransaction.deinit();
}

test "appendRun grows tree height by one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append3.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    // Single-leaf base, run crossing fanout*leafCap (== 4096) so the result
    // must be three levels tall.
    try checkAppendEquiv(&writeTransaction, 50, 4200);
    writeTransaction.deinit();
}

test "appendRun single-leaf base tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append4.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkAppendEquiv(&writeTransaction, 40, 50); // base < leafCap
    writeTransaction.deinit();
}

test "appendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append5.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkAppendEquiv(&writeTransaction, 10, 5000);
    writeTransaction.deinit();
}

test "appendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var database = try appendTmpDatabase(&tmp, "append6.airdb");
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var baseRoot = try create(&writeTransaction);
    var key: u64 = 0;
    while (key < 100) : (key += 1) baseRoot = try insert(&writeTransaction, baseRoot, key, appendRunVal(key));
    const before = try count(&writeTransaction, baseRoot);
    const appended = try appendRun(&writeTransaction, baseRoot, &.{}, &.{}, testing.allocator);
    try testing.expectEqual(baseRoot, appended); // same reference, unchanged
    try testing.expectEqual(before, try count(&writeTransaction, appended));
    writeTransaction.deinit();
}
