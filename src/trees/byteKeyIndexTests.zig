// byteKeyIndexTests.zig -- test suite for the byte-keyed B+tree in byteKeyIndex.zig.

const std = @import("std");
const testing = std.testing;
const Database = @import("../database.zig").Database;
const blob = @import("../records/blob.zig");
const bindex = @import("byteKeyIndex.zig");
const node = @import("indexNode.zig");

const create = bindex.create;
const insert = bindex.insert;
const get = bindex.get;
const remove = bindex.remove;
const count = bindex.count;
const freeTree = bindex.freeTree;
const forEachEntry = bindex.forEachEntry;

const inner_node_size = node.inner_node_size;
const encodeInner = node.encodeInner;

fn bidxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "a bindex ref cycle fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx_cycle.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    // Inner node whose only child is itself; its low key is a real blob so the
    // ordering compare succeeds and the walk descends into the cycle.
    const key_ref = try blob.put(&w, "k");
    const a = try w.alloc(inner_node_size);
    _ = encodeInner(a.bytes, &.{a.ref}, &.{key_ref}, &.{1});
    try testing.expectError(error.Corrupt, get(&w, a.ref, "k"));
    try testing.expectError(error.Corrupt, insert(&w, a.ref, "x", 1));
    try testing.expectError(error.Corrupt, remove(&w, a.ref, "k"));
    const NopSink = struct {
        fn onEntry(_: @This(), _: []const u8, _: u64) !void {}
    };
    try testing.expectError(error.Corrupt, forEachEntry(&w, a.ref, NopSink{}, NopSink.onEntry));
}

test "freeTree over a three-level tree frees every blob exactly once" {
    // Regression: an inner split promoted its boundary low to the parent while
    // the right inner node kept the SAME blob ref as its slot-0 low; freeTree
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
    var w = try database.beginWrite();
    defer w.deinit();

    var root = try create(&w);
    var buffer: [10]u8 = undefined;
    var i: u64 = 0;
    while (i < 4300) : (i += 1) { // > leafCap * fanout: forces inner splits
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>7}", .{i});
        root = try insert(&w, root, key, i);
    }
    try testing.expectEqual(@as(u64, 4300), try count(&w, root));

    try freeTree(&w, root);

    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (w.transactionReuse.extents.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (w.in_flight_frees.items) |e| {
        const gop = try seen.getOrPut(e.offset);
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
    var w = try database.beginWrite();
    defer w.deinit();

    var root = try create(&w);
    var buffer: [8]u8 = undefined;
    var i: u64 = 0;
    while (i < 200) : (i += 1) { // multiple leaf splits
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{i});
        root = try insert(&w, root, key, i);
    }
    // Remove each key (any of them may be a split boundary) and immediately
    // insert a same-length replacement so the freed key blob is reused.
    i = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{i});
        root = try remove(&w, root, key);
        const repl = try std.fmt.bufPrint(&buffer, "z{d:0>5}", .{i});
        root = try insert(&w, root, repl, i);
        // Every surviving original key must still resolve exactly.
        var j: u64 = i + 1;
        while (j < 200) : (j += 17) {
            const probe = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{j});
            try testing.expectEqual(@as(?u64, j), try get(&w, root, probe));
        }
    }
    // All replacements resolve; all originals are gone.
    i = 0;
    while (i < 200) : (i += 1) {
        const repl = try std.fmt.bufPrint(&buffer, "z{d:0>5}", .{i});
        try testing.expectEqual(@as(?u64, i), try get(&w, root, repl));
        const orig = try std.fmt.bufPrint(&buffer, "k{d:0>5}", .{i});
        try testing.expectEqual(@as(?u64, null), try get(&w, root, orig));
    }
    try testing.expectEqual(@as(u64, 200), try count(&w, root));
}

test "insert and get round-trip byte keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var root = try create(&w);
    // Scrambled insertion order.
    root = try insert(&w, root, "banana", 1);
    root = try insert(&w, root, "apple", 2);
    root = try insert(&w, root, "cherry", 3);
    root = try insert(&w, root, "app", 4);
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "banana"));
    try testing.expectEqual(@as(?u64, 2), try get(&w, root, "apple"));
    try testing.expectEqual(@as(?u64, 3), try get(&w, root, "cherry"));
    try testing.expectEqual(@as(?u64, 4), try get(&w, root, "app"));
    try testing.expect((try get(&w, root, "ap")) == null);
    try testing.expect((try get(&w, root, "")) == null);
    try testing.expect((try get(&w, root, "bananas")) == null);
    try testing.expectEqual(@as(u64, 4), try count(&w, root));
    w.deinit();
}

test "keys iterate in ascending byte order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "cherry", 30);
    root = try insert(&w, root, "app", 40);
    root = try insert(&w, root, "banana", 10);
    root = try insert(&w, root, "apple", 20);

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
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&w, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);

    // Expected ascending byte order: "app" < "apple" < "banana" < "cherry".
    const expect_keys = [_][]const u8{ "app", "apple", "banana", "cherry" };
    const expect_vals = [_]u64{ 40, 20, 10, 30 };
    try testing.expectEqual(expect_keys.len, keys.items.len);
    for (keys.items, vals.items, 0..) |k, val, index| {
        try testing.expectEqualStrings(expect_keys[index], k);
        try testing.expectEqual(expect_vals[index], val);
    }
    // And explicitly assert the collected keys are sorted by std.mem.order.
    var i: usize = 1;
    while (i < keys.items.len) : (i += 1) {
        try testing.expect(std.mem.order(u8, keys.items[i - 1], keys.items[i]) == .lt);
    }
    w.deinit();
}

test "insert overwrites an existing key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "k", 1);
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "k"));
    root = try insert(&w, root, "k", 2);
    try testing.expectEqual(@as(?u64, 2), try get(&w, root, "k"));
    try testing.expectEqual(@as(u64, 1), try count(&w, root));
    w.deinit();
}

test "remove deletes a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var root = try create(&w);
    root = try insert(&w, root, "apple", 2);
    root = try insert(&w, root, "banana", 1);
    root = try insert(&w, root, "cherry", 3);
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    root = try remove(&w, root, "apple");
    try testing.expect((try get(&w, root, "apple")) == null);
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    try testing.expectEqual(@as(?u64, 1), try get(&w, root, "banana"));
    try testing.expectEqual(@as(?u64, 3), try get(&w, root, "cherry"));
    // Removing an absent key is a no-op.
    root = try remove(&w, root, "apple");
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    w.deinit();
}

test "many keys across splits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bidxTmpPath(testing.allocator, &tmp, "bidx5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var root = try create(&w);

    const N: u64 = 1000;
    var buffer: [64]u8 = undefined;
    // Scrambled insertion order; varied lengths/zero-padding make byte order non-trivial.
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % N; // permutation of 0..N-1
        const key = try std.fmt.bufPrint(&buffer, "key-{d}", .{k});
        root = try insert(&w, root, key, k +% 7);
    }
    try testing.expectEqual(N, try count(&w, root));

    // Get every key back.
    i = 0;
    while (i < N) : (i += 1) {
        const key = try std.fmt.bufPrint(&buffer, "key-{d}", .{i});
        try testing.expectEqual(@as(?u64, i +% 7), try get(&w, root, key));
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
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntry(&w, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);
    try testing.expectEqual(@as(usize, N), keys.items.len);
    var j: usize = 1;
    while (j < keys.items.len) : (j += 1) {
        try testing.expect(std.mem.order(u8, keys.items[j - 1], keys.items[j]) == .lt);
    }
    // Each emitted key's value matches the number parsed from "key-{d}".
    for (keys.items, vals.items) |k, val| {
        const num = try std.fmt.parseInt(u64, k["key-".len..], 10);
        try testing.expectEqual(num +% 7, val);
    }
    w.deinit();
}
