// byteKeyIndexTests.zig -- test suite for the byte-keyed B+tree in byteKeyIndex.zig.

const std = @import("std");
const testing = std.testing;
const Database = @import("../database.zig").Database;
const blob = @import("../records/blob.zig");
const byteKeyIndex = @import("byteKeyIndex.zig");
const node = @import("indexNode.zig");

const create = byteKeyIndex.create;
const insert = byteKeyIndex.insert;
const get = byteKeyIndex.get;
const remove = byteKeyIndex.remove;
const count = byteKeyIndex.count;
const freeTree = byteKeyIndex.freeTree;
const forEachEntry = byteKeyIndex.forEachEntry;

const innerNodeSize = node.innerNodeSize;
const encodeInner = node.encodeInner;

fn bidxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "a byteKeyIndex reference cycle fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // Inner node whose only child is itself; its low key is a real blob so the
    // ordering compare succeeds and the walk descends into the cycle.
    const keyReference = try blob.put(&writeTransaction, "k");
    const allocation = try writeTransaction.alloc(innerNodeSize);
    _ = encodeInner(allocation.bytes, &.{allocation.reference}, &.{keyReference}, &.{1});
    try testing.expectError(error.Corrupt, get(&writeTransaction, allocation.reference, "k"));
    try testing.expectError(error.Corrupt, insert(&writeTransaction, allocation.reference, "x", 1));
    try testing.expectError(error.Corrupt, remove(&writeTransaction, allocation.reference, "k"));
    const NopSink = struct {
        fn onEntry(_: @This(), _: []const u8, _: u64) !void {}
    };
    try testing.expectError(error.Corrupt, forEachEntry(&writeTransaction, allocation.reference, NopSink{}, NopSink.onEntry));
}

test "freeTree over a three-level tree frees every blob exactly once" {
    // Regression: an inner split promoted its boundary low to the parent while
    // the right inner node kept the SAME blob reference as its slot-0 low; freeTree
    // then freed that blob twice, planting a duplicate extent in the pool
    // (two later allocations handed the same bytes). The promoted low is now
    // duplicated. Detector: after freeing the whole tree, no freed offset may
    // appear twice.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_freedup.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var root = try create(&writeTransaction);
    var buffer: [10]u8 = undefined;
    var round: u64 = 0;
    while (round < 4300) : (round += 1) { // > leafCap * fanout: forces inner splits
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>7}", .{round});
        root = try insert(&writeTransaction, root, key, round);
    }
    try testing.expectEqual(@as(u64, 4300), try count(&writeTransaction, root));

    try freeTree(&writeTransaction, root);

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

test "removing split-boundary keys never dangles routing separators" {
    // Regression: parent low keys used to alias the right leaf's slot-0 key
    // blob; removing that key freed bytes every ancestor still dereferenced
    // for ordering, and the immediately-reused blob misrouted later lookups.
    // Churn removal+insert (same key sizes, so the freed blob is reused at
    // once) across a split tree must keep every lookup exact.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_boundary.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var root = try create(&writeTransaction);
    var buffer: [8]u8 = undefined;
    var round: u64 = 0;
    while (round < 200) : (round += 1) { // multiple leaf splits
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{round});
        root = try insert(&writeTransaction, root, key, round);
    }
    // Remove each key (any of them may be a split boundary) and immediately
    // insert a same-length replacement so the freed key blob is reused.
    round = 0;
    while (round < 200) : (round += 1) {
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{round});
        root = try remove(&writeTransaction, root, key);
        const repl = try std.fmt.bufPrint(&buffer, "z{d:0>5}", .{round});
        root = try insert(&writeTransaction, root, repl, round);
        // Every surviving original key must still resolve exactly.
        var innerRound: u64 = round + 1;
        while (innerRound < 200) : (innerRound += 17) {
            const probe = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{innerRound});
            try testing.expectEqual(@as(?u64, innerRound), try get(&writeTransaction, root, probe));
        }
    }
    // All replacements resolve; all originals are gone.
    round = 0;
    while (round < 200) : (round += 1) {
        const repl = try std.fmt.bufPrint(&buffer, "z{d:0>5}", .{round});
        try testing.expectEqual(@as(?u64, round), try get(&writeTransaction, root, repl));
        const orig = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{round});
        try testing.expectEqual(@as(?u64, null), try get(&writeTransaction, root, orig));
    }
    try testing.expectEqual(@as(u64, 200), try count(&writeTransaction, root));
}

test "insert and get round-trip byte keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    // Scrambled insertion order.
    root = try insert(&writeTransaction, root, "banana", 1);
    root = try insert(&writeTransaction, root, "apple", 2);
    root = try insert(&writeTransaction, root, "cherry", 3);
    root = try insert(&writeTransaction, root, "app", 4);
    try testing.expectEqual(@as(?u64, 1), try get(&writeTransaction, root, "banana"));
    try testing.expectEqual(@as(?u64, 2), try get(&writeTransaction, root, "apple"));
    try testing.expectEqual(@as(?u64, 3), try get(&writeTransaction, root, "cherry"));
    try testing.expectEqual(@as(?u64, 4), try get(&writeTransaction, root, "app"));
    try testing.expect((try get(&writeTransaction, root, "ap")) == null);
    try testing.expect((try get(&writeTransaction, root, "")) == null);
    try testing.expect((try get(&writeTransaction, root, "bananas")) == null);
    try testing.expectEqual(@as(u64, 4), try count(&writeTransaction, root));
    writeTransaction.deinit();
}

test "keys iterate in ascending byte order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    root = try insert(&writeTransaction, root, "cherry", 30);
    root = try insert(&writeTransaction, root, "app", 40);
    root = try insert(&writeTransaction, root, "banana", 10);
    root = try insert(&writeTransaction, root, "apple", 20);

    const Collector = struct {
        keys: *std.ArrayList([]u8),
        vals: *std.ArrayList(u64),
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.keys.append(testing.allocator, try testing.allocator.dupe(u8, key));
            try self.vals.append(testing.allocator, val);
        }
    };
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |key| testing.allocator.free(key);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&writeTransaction, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);

    // Expected ascending byte order: "app" < "apple" < "banana" < "cherry".
    const expectKeys = [_][]const u8{ "app", "apple", "banana", "cherry" };
    const expectVals = [_]u64{ 40, 20, 10, 30 };
    try testing.expectEqual(expectKeys.len, keys.items.len);
    for (keys.items, vals.items, 0..) |key, val, index| {
        try testing.expectEqualStrings(expectKeys[index], key);
        try testing.expectEqual(expectVals[index], val);
    }
    // And explicitly assert the collected keys are sorted by std.mem.order.
    var round: usize = 1;
    while (round < keys.items.len) : (round += 1) {
        try testing.expect(std.mem.order(u8, keys.items[round - 1], keys.items[round]) == .lt);
    }
    writeTransaction.deinit();
}

test "insert overwrites an existing key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    root = try insert(&writeTransaction, root, "k", 1);
    try testing.expectEqual(@as(?u64, 1), try get(&writeTransaction, root, "k"));
    root = try insert(&writeTransaction, root, "k", 2);
    try testing.expectEqual(@as(?u64, 2), try get(&writeTransaction, root, "k"));
    try testing.expectEqual(@as(u64, 1), try count(&writeTransaction, root));
    writeTransaction.deinit();
}

test "remove deletes a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);
    root = try insert(&writeTransaction, root, "apple", 2);
    root = try insert(&writeTransaction, root, "banana", 1);
    root = try insert(&writeTransaction, root, "cherry", 3);
    try testing.expectEqual(@as(u64, 3), try count(&writeTransaction, root));
    root = try remove(&writeTransaction, root, "apple");
    try testing.expect((try get(&writeTransaction, root, "apple")) == null);
    try testing.expectEqual(@as(u64, 2), try count(&writeTransaction, root));
    try testing.expectEqual(@as(?u64, 1), try get(&writeTransaction, root, "banana"));
    try testing.expectEqual(@as(?u64, 3), try get(&writeTransaction, root, "cherry"));
    // Removing an absent key is a no-op.
    root = try remove(&writeTransaction, root, "apple");
    try testing.expectEqual(@as(u64, 2), try count(&writeTransaction, root));
    writeTransaction.deinit();
}

test "many keys across splits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var root = try create(&writeTransaction);

    const N: u64 = 1000;
    var buffer: [64]u8 = undefined;
    // Scrambled insertion order; varied lengths/zero-padding make byte order non-trivial.
    var round: u64 = 0;
    while (round < N) : (round += 1) {
        const keyNumber = (round *% 2654435761) % N; // permutation of 0..N-1
        const key = try std.fmt.bufPrint(&buffer, "key-{d}", .{keyNumber});
        root = try insert(&writeTransaction, root, key, keyNumber +% 7);
    }
    try testing.expectEqual(N, try count(&writeTransaction, root));

    // Get every key back.
    round = 0;
    while (round < N) : (round += 1) {
        const key = try std.fmt.bufPrint(&buffer, "key-{d}", .{round});
        try testing.expectEqual(@as(?u64, round +% 7), try get(&writeTransaction, root, key));
    }

    // Iteration is sorted by std.mem.order and values match their keys.
    const Collector = struct {
        keys: *std.ArrayList([]u8),
        vals: *std.ArrayList(u64),
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.keys.append(testing.allocator, try testing.allocator.dupe(u8, key));
            try self.vals.append(testing.allocator, val);
        }
    };
    var keys = std.ArrayList([]u8).empty;
    defer {
        for (keys.items) |key| testing.allocator.free(key);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&writeTransaction, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);
    try testing.expectEqual(@as(usize, N), keys.items.len);
    var innerRound: usize = 1;
    while (innerRound < keys.items.len) : (innerRound += 1) {
        try testing.expect(std.mem.order(u8, keys.items[innerRound - 1], keys.items[innerRound]) == .lt);
    }
    // Each emitted key's value matches the number parsed from "key-{d}".
    for (keys.items, vals.items) |key, val| {
        const num = try std.fmt.parseInt(u64, key["key-".len..], 10);
        try testing.expectEqual(num +% 7, val);
    }
    writeTransaction.deinit();
}
