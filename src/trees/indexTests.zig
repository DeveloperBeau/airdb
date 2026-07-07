// indexTests.zig -- test suite for the u64-keyed B+tree in index.zig.

const std = @import("std");
const testing = std.testing;
const Db = @import("../database.zig").Db;
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

const leaf_node_size = node.leaf_node_size;
const inner_node_size = node.inner_node_size;
const encodeLeaf = node.encodeLeaf;
const encodeInner = node.encodeInner;

fn idxTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "a ref cycle or unknown kind byte fails with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx_cycle.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    // An inner node whose only child is itself: every walk must hit the depth
    // cap and error out rather than overflow the stack. (count is exempt: it is
    // a single-node read of the stored subtree counts and never descends.)
    const a = try w.alloc(inner_node_size);
    _ = encodeInner(a.bytes, &.{a.ref}, &.{0}, &.{1});
    try testing.expectError(error.Corrupt, get(&w, a.ref, 5));
    try testing.expectError(error.Corrupt, maxKey(&w, a.ref));
    try testing.expectError(error.Corrupt, insert(&w, a.ref, 1, 1));
    try testing.expectError(error.Corrupt, remove(&w, a.ref, 1));
    const NopSink = struct {
        fn onKey(_: @This(), _: u64) !void {}
    };
    try testing.expectError(error.Corrupt, forEachKey(&w, a.ref, NopSink{}, NopSink.onKey));

    // A node with an out-of-range kind byte is rejected outright.
    const b = try w.alloc(leaf_node_size);
    _ = encodeLeaf(b.bytes, &.{}, &.{});
    // Rewrite the kind byte through the arena (b.bytes is mutable).
    b.bytes[0] = 7;
    try testing.expectError(error.Corrupt, get(&w, b.ref, 1));
}

test "get and count traverse an inner node over two leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var a = try create(&w);
    a = try insert(&w, a, 1, 11);
    a = try insert(&w, a, 3, 33);
    var b = try create(&w);
    b = try insert(&w, b, 5, 55);
    b = try insert(&w, b, 7, 77);
    const inner = try makeInnerForTest(&w, &.{ .{ .ref = a, .low = 1, .count = 2 }, .{ .ref = b, .low = 5, .count = 2 } });
    try testing.expectEqual(@as(u64, 4), try count(&w, inner));
    try testing.expectEqual(@as(?u64, 11), try get(&w, inner, 1));
    try testing.expectEqual(@as(?u64, 55), try get(&w, inner, 5));
    try testing.expectEqual(@as(?u64, 77), try get(&w, inner, 7));
    try testing.expect((try get(&w, inner, 6)) == null);
    try testing.expect((try get(&w, inner, 0)) == null);
    w.deinit();
}

test "insert builds a balanced tree across many leaves and reads back correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    const N: u64 = 5000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003; // scattered keys force mid-splits
        root = try insert(&w, root, k, k +% 7);
    }
    var ref_map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer ref_map.deinit();
    i = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003;
        try ref_map.put(k, k +% 7);
    }
    try testing.expectEqual(@as(u64, ref_map.count()), try count(&w, root));
    var it = ref_map.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(@as(?u64, e.value_ptr.*), try get(&w, root, e.key_ptr.*));
    }
    w.deinit();
}

test "single-leaf index: insert, get, upsert, remove, count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    try testing.expect((try get(&w, root, 5)) == null);
    root = try insert(&w, root, 5, 50);
    root = try insert(&w, root, 1, 10);
    root = try insert(&w, root, 9, 90);
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    try testing.expectEqual(@as(?u64, 50), try get(&w, root, 5));
    try testing.expectEqual(@as(?u64, 10), try get(&w, root, 1));
    root = try insert(&w, root, 5, 555);
    try testing.expectEqual(@as(?u64, 555), try get(&w, root, 5));
    try testing.expectEqual(@as(u64, 3), try count(&w, root));
    root = try remove(&w, root, 1);
    try testing.expect((try get(&w, root, 1)) == null);
    try testing.expectEqual(@as(u64, 2), try count(&w, root));
    w.deinit();
}

test "a committed index version stays intact for a pinned reader while a later commit mutates it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Commit version 1: keys 0..1999, value = key*10.
    {
        var w = try db.beginWrite();
        var root = try create(&w);
        var i: u64 = 0;
        while (i < 2000) : (i += 1) root = try insert(&w, root, i, i * 10);
        w.setRoot(root);
        _ = try w.commit();
    }

    // Pin a reader on version 1.
    var r1 = try db.beginRead();
    const root_v1 = r1.root();
    try testing.expectEqual(@as(?u64, 1234 * 10), try get(&r1, root_v1, 1234));

    // Commit version 2: update key 1234, remove key 500.
    {
        var w = try db.beginWrite();
        var root = w.new_root; // start from the latest committed root (refreshed in beginWrite)
        root = try insert(&w, root, 1234, 999999);
        root = try remove(&w, root, 500);
        w.setRoot(root);
        _ = try w.commit();
    }

    // The pinned v1 reader still sees the original values (committed snapshot intact).
    try testing.expectEqual(@as(?u64, 1234 * 10), try get(&r1, root_v1, 1234));
    try testing.expectEqual(@as(?u64, 500 * 10), try get(&r1, root_v1, 500));
    r1.end();

    // A fresh read sees version 2.
    var r2 = try db.beginRead();
    try testing.expectEqual(@as(?u64, 999999), try get(&r2, r2.root(), 1234));
    try testing.expect((try get(&r2, r2.root(), 500)) == null);
    try testing.expectEqual(@as(?u64, 1235 * 10), try get(&r2, r2.root(), 1235)); // untouched key
    r2.end();
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var root = try create(&w);
    var k: u64 = 0;
    while (k <= 64) : (k += 1) root = try insert(&w, root, k, k); // forces a leaf split
    try testing.expectEqual(@as(?u64, 64), try maxKey(&w, root));
    // Empty the rightmost leaf by removing the upper half.
    k = 32;
    while (k <= 64) : (k += 1) root = try remove(&w, root, k);
    try testing.expectEqual(@as(?u64, 31), try maxKey(&w, root));
    // Fully emptied tree reports null.
    k = 0;
    while (k < 32) : (k += 1) root = try remove(&w, root, k);
    try testing.expectEqual(@as(?u64, null), try maxKey(&w, root));
}

test "stored subtree counts match a full iteration under churn" {
    // count() reads per-child subtree counts from a single node. Verify the
    // stored counts stay exact through scattered inserts (with splits and
    // height growth), upserts (which must NOT bump counts), and removes.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx_counts.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var root = try create(&w);
    const N: u64 = 5000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003;
        root = try insert(&w, root, k, k);
    }
    // Upserts: rewrite existing keys; counts must not change.
    i = 0;
    while (i < 500) : (i += 1) {
        const k = (i *% 2654435761) % 1_000_003;
        root = try insert(&w, root, k, k + 1);
    }
    // Remove every 3rd inserted key.
    i = 0;
    while (i < N) : (i += 3) {
        const k = (i *% 2654435761) % 1_000_003;
        root = try remove(&w, root, k);
    }

    const Tally = struct {
        n: *u64,
        fn onKey(self: @This(), _: u64) !void {
            self.n.* += 1;
        }
    };
    var walked: u64 = 0;
    try forEachKey(&w, root, Tally{ .n = &walked }, Tally.onKey);
    try testing.expectEqual(walked, try count(&w, root));
}

test "forEachKey visits all keys in ascending order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "iter.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        const k = (i *% 2654435761) % 100_003;
        root = try insert(&w, root, k, k + 1);
    }
    const Collector = struct {
        list: *std.ArrayList(u64),
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(testing.allocator, key);
        }
    };
    var seen = std.ArrayList(u64).empty;
    defer seen.deinit(testing.allocator);
    try forEachKey(&w, root, Collector{ .list = &seen }, Collector.onKey);
    try testing.expectEqual(try count(&w, root), @as(u64, seen.items.len));
    var prev: u64 = 0;
    var first = true;
    for (seen.items) |k| {
        if (!first) try testing.expect(k > prev);
        prev = k;
        first = false;
    }
    w.deinit();
}

test "forEachEntry visits key/value pairs in ascending key order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "iter_entry.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var root = try create(&w);
    var i: u64 = 0;
    while (i < 200) : (i += 1) {
        const k = (i *% 2654435761) % 100_003; // scrambled insertion order
        root = try insert(&w, root, k, k * 7 + 1);
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
    try forEachEntry(&w, root, Collector{ .keys = &keys, .vals = &vals }, Collector.onEntry);
    try testing.expectEqual(try count(&w, root), @as(u64, keys.items.len));
    try testing.expectEqual(keys.items.len, vals.items.len);
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |k, val| {
        if (!first) try testing.expect(k > prev);
        try testing.expectEqual(k * 7 + 1, val);
        prev = k;
        first = false;
    }
    w.deinit();
}

// Build a tree holding keys 0..=1000 (each once) inserted in scrambled order,
// with value == key*10. 397 is coprime to 1001 (=7*11*13), so (i*397)%1001
// visits every residue exactly once.
fn buildScrambled0to1000(w: *WriteTransaction) !Reference {
    var root = try create(w);
    var i: u64 = 0;
    while (i <= 1000) : (i += 1) {
        const k = (i * 397) % 1001;
        root = try insert(w, root, k, k * 10);
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const root = try buildScrambled0to1000(&w);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);
    try forEachEntryInRange(&w, root, 200, 300, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);

    try testing.expectEqual(@as(usize, 101), keys.items.len);
    try testing.expectEqual(keys.items.len, vals.items.len);
    var expected: u64 = 200;
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |k, val| {
        try testing.expectEqual(expected, k); // strictly ascending 200..300
        try testing.expectEqual(k * 10, val);
        try testing.expect(k >= 200 and k <= 300); // nothing outside
        if (!first) try testing.expect(k > prev);
        prev = k;
        first = false;
        expected += 1;
    }
    try testing.expectEqual(@as(u64, 200), keys.items[0]);
    try testing.expectEqual(@as(u64, 300), keys.items[keys.items.len - 1]);
    w.deinit();
}

test "forEachEntryInRange empty range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const root = try buildScrambled0to1000(&w);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // lo above the max key -> nothing.
    try forEachEntryInRange(&w, root, 1001, 2000, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);

    // lo > hi -> nothing.
    try forEachEntryInRange(&w, root, 300, 200, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);
    w.deinit();
}

test "forEachEntryInRange single key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const root = try buildScrambled0to1000(&w);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // Present single key.
    try forEachEntryInRange(&w, root, 500, 500, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 1), keys.items.len);
    try testing.expectEqual(@as(u64, 500), keys.items[0]);
    try testing.expectEqual(@as(u64, 5000), vals.items[0]);

    // Absent single key.
    keys.clearRetainingCapacity();
    vals.clearRetainingCapacity();
    try forEachEntryInRange(&w, root, 10001, 10001, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);
    try testing.expectEqual(@as(usize, 0), keys.items.len);
    w.deinit();
}

test "forEachEntryInRange spans multiple leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "range4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const root = try buildScrambled0to1000(&w);

    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(testing.allocator);
    var vals = std.ArrayList(u64).empty;
    defer vals.deinit(testing.allocator);

    // [50,800] crosses many leaves (LEAF_CAP == 64).
    try forEachEntryInRange(&w, root, 50, 800, RangeCollector{ .keys = &keys, .vals = &vals }, RangeCollector.onEntry);

    try testing.expectEqual(@as(usize, 751), keys.items.len); // 800-50+1
    try testing.expectEqual(@as(u64, 50), keys.items[0]);
    try testing.expectEqual(@as(u64, 800), keys.items[keys.items.len - 1]);
    var prev: u64 = 0;
    var first = true;
    for (keys.items, vals.items) |k, val| {
        if (!first) try testing.expect(k == prev + 1); // no gaps or dupes
        try testing.expectEqual(k * 10, val);
        prev = k;
        first = false;
    }
    w.deinit();
}

test "ordered index persists across reopen and matches a reference map under churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try idxTmpPath(testing.allocator, &tmp, "idx6.airdb");
    defer testing.allocator.free(path);
    var ref_map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer ref_map.deinit();
    const N: u64 = 100_000;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var root = try create(&w);
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            const k = (i *% 2654435761) % 5_000_011;
            root = try insert(&w, root, k, i);
            try ref_map.put(k, i);
        }
        // Remove every 3rd inserted key.
        i = 0;
        while (i < N) : (i += 3) {
            const k = (i *% 2654435761) % 5_000_011;
            root = try remove(&w, root, k);
            _ = ref_map.remove(k);
        }
        w.setRoot(root);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, ref_map.count()), try count(&r, r.root()));
        var it = ref_map.iterator();
        while (it.next()) |e| {
            try testing.expectEqual(@as(?u64, e.value_ptr.*), try get(&r, r.root(), e.key_ptr.*));
        }
        // Spot-check some removed keys are absent.
        var j: u64 = 0;
        while (j < 30) : (j += 3) {
            const k = (j *% 2654435761) % 5_000_011;
            if (!ref_map.contains(k)) try testing.expect((try get(&r, r.root(), k)) == null);
        }
        r.end();
    }
}

fn appendRunVal(k: u64) u64 {
    return k *% 7 +% 3;
}

fn appendTmpDb(tmp: *testing.TmpDir, name: []const u8) !Db {
    const path = try idxTmpPath(testing.allocator, tmp, name);
    defer testing.allocator.free(path);
    return Db.create(testing.allocator, path);
}

// Build a base tree of keys 0..base via sequential insert, append the run
// base..base+run via appendRun, and assert the result is logically identical
// to inserting all keys 0..base+run sequentially.
fn checkAppendEquiv(w: *WriteTransaction, base: u64, run: u64) !void {
    var base_root = try create(w);
    var k: u64 = 0;
    while (k < base) : (k += 1) base_root = try insert(w, base_root, k, appendRunVal(k));

    const rk = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rk);
    const rv = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rv);
    var r: u64 = 0;
    while (r < run) : (r += 1) {
        rk[r] = base + r;
        rv[r] = appendRunVal(base + r);
    }

    const appended = try appendRun(w, base_root, rk, rv, testing.allocator);

    var expected = try create(w);
    k = 0;
    while (k < base + run) : (k += 1) expected = try insert(w, expected, k, appendRunVal(k));

    const total = base + run;
    try testing.expectEqual(total, try count(w, appended));
    try testing.expectEqual(try count(w, expected), try count(w, appended));

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
    for (samples.items) |sk| {
        try testing.expectEqual(try get(w, expected, sk), try get(w, appended, sk));
    }
    // Beyond the max key is absent in both.
    try testing.expectEqual(@as(?u64, null), try get(w, appended, total));
    try testing.expectEqual(try get(w, expected, total), try get(w, appended, total));

    // Full ascending (key,val) sequence must match exactly.
    var ak = std.ArrayList(u64).empty;
    defer ak.deinit(testing.allocator);
    var av = std.ArrayList(u64).empty;
    defer av.deinit(testing.allocator);
    var ek = std.ArrayList(u64).empty;
    defer ek.deinit(testing.allocator);
    var ev = std.ArrayList(u64).empty;
    defer ev.deinit(testing.allocator);
    try forEachEntry(w, appended, RangeCollector{ .keys = &ak, .vals = &av }, RangeCollector.onEntry);
    try forEachEntry(w, expected, RangeCollector{ .keys = &ek, .vals = &ev }, RangeCollector.onEntry);
    try testing.expectEqualSlices(u64, ek.items, ak.items);
    try testing.expectEqualSlices(u64, ev.items, av.items);
}

test "appendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append1.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 100, 200); // 100 % 64 == 36 in the last leaf
    w.deinit();
}

test "appendRun overflow rightmost inner node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append2.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    // A multi-level base plus a run large enough that the new leaves alone
    // exceed FANOUT, forcing a split at the leaf-parent (non-root) inner level.
    try checkAppendEquiv(&w, 3000, 5000);
    w.deinit();
}

test "appendRun grows tree height by one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append3.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    // Single-leaf base, run crossing FANOUT*LEAF_CAP (== 4096) so the result
    // must be three levels tall.
    try checkAppendEquiv(&w, 50, 4200);
    w.deinit();
}

test "appendRun single-leaf base tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append4.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 40, 50); // base < LEAF_CAP
    w.deinit();
}

test "appendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append5.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 10, 5000);
    w.deinit();
}

test "appendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append6.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    var base_root = try create(&w);
    var k: u64 = 0;
    while (k < 100) : (k += 1) base_root = try insert(&w, base_root, k, appendRunVal(k));
    const before = try count(&w, base_root);
    const appended = try appendRun(&w, base_root, &.{}, &.{}, testing.allocator);
    try testing.expectEqual(base_root, appended); // same ref, unchanged
    try testing.expectEqual(before, try count(&w, appended));
    w.deinit();
}
