const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const cnode = @import("column_node.zig");
const inode = @import("index_node.zig");

// ---------------------------------------------------------------------------
// Bottom-up bulk tree builders.
//
// These build a complete, balanced tree directly from sorted input rather than
// inserting one element at a time. Leaves are packed to capacity in key order,
// then inner levels are stacked on top in runs of FANOUT until a single root
// remains. The produced nodes are byte-for-byte the same on-disk format the
// sequential readers expect, so a bulk-built tree is indistinguishable from one
// grown via the normal append/insert path.
// ---------------------------------------------------------------------------

pub const ValueOkeys = struct { value: u64, okeys: []const u64 };

/// Build a column tree holding `values` at row indices 0..values.len. Returns
/// the root Ref. Equivalent to Column.create followed by an append per value.
pub fn bulkColumn(txn: *WriteTxn, values: []const u64) !Ref {
    if (values.len == 0) return Column.create(txn);
    const al = txn.db.store.allocator;
    const cap: usize = cnode.LEAF_CAP;
    const fan: usize = cnode.FANOUT;

    // Current level: a list of child refs and the value count under each child.
    var refs = std.ArrayList(u64).empty;
    defer refs.deinit(al);
    var counts = std.ArrayList(u64).empty;
    defer counts.deinit(al);

    // Pack leaves to capacity in row order.
    var i: usize = 0;
    while (i < values.len) {
        const end = @min(i + cap, values.len);
        const a = try txn.alloc(cnode.leaf_node_size);
        _ = cnode.encodeLeaf(a.bytes, values[i..end]);
        try refs.append(al, a.ref);
        try counts.append(al, @intCast(end - i));
        i = end;
    }

    // Stack inner levels until a single root remains. A column inner node stores
    // (child_ref, subtree_count); the parent's own count is the sum of its
    // children's counts.
    while (refs.items.len > 1) {
        var next_refs = std.ArrayList(u64).empty;
        var next_counts = std.ArrayList(u64).empty;
        var j: usize = 0;
        while (j < refs.items.len) {
            const end = @min(j + fan, refs.items.len);
            const a = try txn.alloc(cnode.inner_node_size);
            _ = cnode.encodeInner(a.bytes, refs.items[j..end], counts.items[j..end]);
            var total: u64 = 0;
            for (counts.items[j..end]) |c| total += c;
            try next_refs.append(al, a.ref);
            try next_counts.append(al, total);
            j = end;
        }
        refs.deinit(al);
        counts.deinit(al);
        refs = next_refs;
        counts = next_counts;
    }
    return refs.items[0];
}

/// Build a u64 index over strictly-ascending `keys` with parallel `vals`.
/// Returns the root Ref. Equivalent to Index.create plus an insert per pair.
pub fn bulkIndex(txn: *WriteTxn, keys: []const u64, vals: []const u64) !Ref {
    std.debug.assert(keys.len == vals.len);
    if (std.debug.runtime_safety) {
        var p: usize = 1;
        while (p < keys.len) : (p += 1) std.debug.assert(keys[p] > keys[p - 1]);
    }
    if (keys.len == 0) return Index.create(txn);
    const al = txn.db.store.allocator;
    const cap: usize = inode.LEAF_CAP;
    const fan: usize = inode.FANOUT;

    // Current level: child refs and the low key (first key) of each child.
    var refs = std.ArrayList(u64).empty;
    defer refs.deinit(al);
    var lows = std.ArrayList(u64).empty;
    defer lows.deinit(al);

    // Pack leaves to capacity in key order.
    var i: usize = 0;
    while (i < keys.len) {
        const end = @min(i + cap, keys.len);
        const a = try txn.alloc(inode.leaf_node_size);
        _ = inode.encodeLeaf(a.bytes, keys[i..end], vals[i..end]);
        try refs.append(al, a.ref);
        try lows.append(al, keys[i]);
        i = end;
    }

    // Stack inner levels. An index inner node stores (child_ref, low_key); the
    // parent's own low key is the low key of its first child.
    while (refs.items.len > 1) {
        var next_refs = std.ArrayList(u64).empty;
        var next_lows = std.ArrayList(u64).empty;
        var j: usize = 0;
        while (j < refs.items.len) {
            const end = @min(j + fan, refs.items.len);
            const a = try txn.alloc(inode.inner_node_size);
            _ = inode.encodeInner(a.bytes, refs.items[j..end], lows.items[j..end]);
            try next_refs.append(al, a.ref);
            try next_lows.append(al, lows.items[j]);
            j = end;
        }
        refs.deinit(al);
        lows.deinit(al);
        refs = next_refs;
        lows = next_lows;
    }
    return refs.items[0];
}

/// Build a value index (value -> inner okey-set) from `entries`, sorted by
/// value, each with ascending okeys. Each inner set maps okey -> 1, matching
/// the shape objects.viAdd maintains (value -> Index{okey -> 1}).
pub fn bulkValueIndex(txn: *WriteTxn, entries: []const ValueOkeys) !Ref {
    if (entries.len == 0) return Index.create(txn);
    const al = txn.db.store.allocator;

    const values = try al.alloc(u64, entries.len);
    defer al.free(values);
    const inner_roots = try al.alloc(u64, entries.len);
    defer al.free(inner_roots);

    // A reusable buffer of 1s big enough for the largest okey set.
    var max_okeys: usize = 0;
    for (entries) |e| max_okeys = @max(max_okeys, e.okeys.len);
    const ones = try al.alloc(u64, max_okeys);
    defer al.free(ones);
    @memset(ones, 1);

    for (entries, 0..) |e, k| {
        values[k] = e.value;
        inner_roots[k] = try bulkIndex(txn, e.okeys, ones[0..e.okeys.len]);
    }

    return bulkIndex(txn, values, inner_roots);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;

fn bulkTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

fn checkColumnSize(w: *WriteTxn, n: usize) !void {
    const values = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(values);
    for (values, 0..) |*v, i| v.* = @as(u64, i) * 7;

    const built = try bulkColumn(w, values);

    var seq = try Column.create(w);
    for (values) |v| seq = try Column.append(w, seq, v);

    try testing.expectEqual(try Column.len(w, seq), try Column.len(w, built));
    try testing.expectEqual(@as(u64, n), try Column.len(w, built));
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(try Column.get(w, seq, i), try Column.get(w, built, i));
    }
}

test "bulkColumn equals sequential appends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcol.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColumnSize(&w, 1000);
    w.deinit();
}

test "bulkColumn boundary sizes: 0, 1, LEAF_CAP, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcolsizes.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColumnSize(&w, 0);
    try checkColumnSize(&w, 1);
    try checkColumnSize(&w, cnode.LEAF_CAP); // single full leaf
    try checkColumnSize(&w, @as(usize, cnode.LEAF_CAP) * cnode.FANOUT + 1); // 3 levels
    w.deinit();
}

const IdxCollector = struct {
    keys: *std.ArrayList(u64),
    vals: *std.ArrayList(u64),
    fn onEntry(self: @This(), key: u64, val: u64) !void {
        try self.keys.append(testing.allocator, key);
        try self.vals.append(testing.allocator, val);
    }
};

fn checkIndexSize(w: *WriteTxn, n: usize) !void {
    const keys = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(keys);
    const vals = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(vals);
    for (keys, vals, 0..) |*k, *v, i| {
        k.* = @intCast(i);
        v.* = @as(u64, i) * 10;
    }

    const built = try bulkIndex(w, keys, vals);

    var seq = try Index.create(w);
    for (keys, vals) |k, v| seq = try Index.insert(w, seq, k, v);

    try testing.expectEqual(@as(u64, n), try Index.count(w, built));
    try testing.expectEqual(try Index.count(w, seq), try Index.count(w, built));

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(try Index.get(w, seq, i), try Index.get(w, built, i));
    }

    var bk = std.ArrayList(u64).empty;
    defer bk.deinit(testing.allocator);
    var bv = std.ArrayList(u64).empty;
    defer bv.deinit(testing.allocator);
    try Index.forEachEntry(w, built, IdxCollector{ .keys = &bk, .vals = &bv }, IdxCollector.onEntry);
    try testing.expectEqual(n, bk.items.len);
    for (bk.items, bv.items, 0..) |k, v, j| {
        try testing.expectEqual(@as(u64, j), k);
        try testing.expectEqual(@as(u64, j) * 10, v);
    }
}

test "bulkIndex equals sequential inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkIndexSize(&w, 1000);
    w.deinit();
}

test "bulkIndex boundary sizes: 0, 1, LEAF_CAP, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidxsizes.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkIndexSize(&w, 0);
    try checkIndexSize(&w, 1);
    try checkIndexSize(&w, inode.LEAF_CAP);
    try checkIndexSize(&w, @as(usize, inode.LEAF_CAP) * inode.FANOUT + 1);
    w.deinit();
}

const SetCollector = struct {
    keys: *std.ArrayList(u64),
    fn onKey(self: @This(), key: u64) !void {
        try self.keys.append(testing.allocator, key);
    }
};

fn collectSet(w: *WriteTxn, set_root: Ref, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    try Index.forEachKey(w, set_root, SetCollector{ .keys = out }, SetCollector.onKey);
}

test "bulkValueIndex equals sequential maintenance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkvi.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    const N: u64 = 1000;
    const num_values: u64 = 100;

    // Build the grouped entries: value v=i%100 maps to okeys {i : i%100==v}, ascending.
    var entries = std.ArrayList(ValueOkeys).empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.okeys);
        entries.deinit(testing.allocator);
    }
    var v: u64 = 0;
    while (v < num_values) : (v += 1) {
        var okeys = std.ArrayList(u64).empty;
        var i: u64 = v; // first okey with i%100==v
        while (i < N) : (i += num_values) try okeys.append(testing.allocator, i);
        try entries.append(testing.allocator, .{ .value = v, .okeys = try okeys.toOwnedSlice(testing.allocator) });
    }

    const built = try bulkValueIndex(&w, entries.items);

    // Sequential maintenance mirror: for each (value, okey) add okey to the inner
    // set for value, exactly as objects.viAdd does.
    var seq = try Index.create(&w);
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const value = i % num_values;
        const existing = try Index.get(&w, seq, value);
        var set_root = existing orelse try Index.create(&w);
        set_root = try Index.insert(&w, set_root, i, 1);
        seq = try Index.insert(&w, seq, value, set_root);
    }

    // Compare the inner okey set for every value.
    var built_set = std.ArrayList(u64).empty;
    defer built_set.deinit(testing.allocator);
    var seq_set = std.ArrayList(u64).empty;
    defer seq_set.deinit(testing.allocator);

    v = 0;
    while (v < num_values) : (v += 1) {
        const b_inner = (try Index.get(&w, built, v)) orelse return error.MissingValue;
        const s_inner = (try Index.get(&w, seq, v)) orelse return error.MissingValue;
        try collectSet(&w, b_inner, &built_set);
        try collectSet(&w, s_inner, &seq_set);
        try testing.expectEqualSlices(u64, seq_set.items, built_set.items);
    }
    w.deinit();
}
