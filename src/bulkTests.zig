const std = @import("std");
const verification = @import("verification.zig");
const bulk = @import("bulk.zig");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const cnode = @import("column_node.zig");
const inode = @import("index_node.zig");
const catalog = @import("catalog.zig");
const objects = @import("objects.zig");
const rawRows = @import("rows.zig");
const ValueOkeys = bulk.ValueOkeys;
const bulkColumn = bulk.bulkColumn;
const bulkIndex = bulk.bulkIndex;
const indexAppendRun = bulk.indexAppendRun;
const columnAppendRun = bulk.columnAppendRun;
const bulkValueIndex = bulk.bulkValueIndex;
const bulkImport = bulk.bulkImport;
const bulkAppend = bulk.bulkAppend;
const bulkAppendOrInsert = bulk.bulkAppendOrInsert;

const testing = std.testing;

const Db = @import("db.zig").Db;

const query = @import("query.zig");

const typedir = @import("typedir.zig");

fn bulkTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "bulk append is refused when the batch does not clear the true max pk" {
    // Regression: deleting the upper pk range empties the pk index's rightmost
    // leaf. A maxKey that followed only the rightmost path then reported the
    // type EMPTY, so bulkAppend admitted a batch below the surviving keys --
    // duplicate pks and broken leaf ordering. The batch must be NotAppendable
    // (and the fallback must handle it correctly instead).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_maxpk.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var pk: u64 = 0;
    while (pk <= 64) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk })).cat; // pk index splits
    var out: [2]u64 = undefined;
    pk = 32;
    while (pk <= 64) : (pk += 1) {
        const ver = (try rawRows.getByPk(&w, cat, pk, &out)).?;
        cat = (try rawRows.delete(&w, cat, pk, ver)).ok;
    }
    // pks 0..31 survive; a batch starting at 10 must NOT take the fast path.
    const rows = [_][]const u64{ &.{ 10, 1 }, &.{ 11, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &rows));
    // The orchestrator falls back to row-by-row, which detects the duplicate.
    try testing.expectError(error.DuplicateKey, bulkAppendOrInsert(&w, cat, &rows));
    // A batch that truly clears the surviving max qualifies.
    const ok_rows = [_][]const u64{ &.{ 100, 1 }, &.{ 101, 2 } };
    cat = try bulkAppend(&w, cat, &ok_rows);
    try testing.expect((try rawRows.getByPk(&w, cat, 100, &out)) != null);
    try testing.expect((try rawRows.getByPk(&w, cat, 31, &out)) != null);
}

test "bulk append into a pk-history gap takes the fallback" {
    // Regression: with pks 0..31 and 40..104 inserted then 40..104 deleted,
    // the rightmost pk-index leaves are EMPTY but keep recorded lows (40, 72).
    // A batch of {33, 34} clears the surviving max (31) but sits BELOW the
    // stale low; the old fast path rebuilt the low-72 leaf with low 33 and the
    // appended rows became unreachable. Such a batch must fall back; a batch
    // clearing the stale low may still take the fast path.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_gap.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var pk: u64 = 0;
    while (pk <= 31) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk })).cat;
    pk = 40;
    while (pk <= 104) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk })).cat;
    var out: [2]u64 = undefined;
    pk = 40;
    while (pk <= 104) : (pk += 1) {
        const ver = (try rawRows.getByPk(&w, cat, pk, &out)).?;
        cat = (try rawRows.delete(&w, cat, pk, ver)).ok;
    }

    // Below the stale low: NotAppendable; the orchestrator's fallback must
    // leave every row reachable.
    const gap_rows = [_][]const u64{ &.{ 33, 1 }, &.{ 34, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &gap_rows));
    cat = try bulkAppendOrInsert(&w, cat, &gap_rows);
    try testing.expect((try rawRows.getByPk(&w, cat, 33, &out)) != null);
    try testing.expect((try rawRows.getByPk(&w, cat, 34, &out)) != null);

    // Every surviving pk still resolves (routing lows intact).
    pk = 0;
    while (pk <= 31) : (pk += 1) try testing.expect((try rawRows.getByPk(&w, cat, pk, &out)) != null);
}

test "bulk append fallback refuses link-bearing schemas" {
    // objects.insert writes raw columns without backlink maintenance, so the
    // row-by-row fallback must reject link/link_set types like bulkImport does
    // instead of silently corrupting the graph.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_links.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    const cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const rows = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkAppendOrInsert(&w, cat, &rows));
}

test "bulk append frees the replaced right-edge nodes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_free.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Commit a populated type so the old right edge is committed nodes.
    {
        var w = try db.beginWrite();
        var cat = try catalog.create(&w, 2);
        var pk: u64 = 0;
        while (pk < 200) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // A qualifying append must record the replaced committed spine as
    // in-flight frees (deferred, MVCC-safe reclaim) instead of leaking it.
    var w = try db.beginWrite();
    defer w.deinit();
    const rows = [_][]const u64{ &.{ 1000, 1 }, &.{ 1001, 2 } };
    _ = try bulkAppend(&w, w.new_root, &rows);
    try testing.expect(w.in_flight_frees.items.len > 0);
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
    // set for value, exactly as rows.viAdd does.
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

// Schema shared by the orchestrator tests: int pk, int value, int category (indexed).
const import_defs = [_]catalog.PropDef{
    .{ .kind = .int },
    .{ .kind = .int },
    .{ .kind = .int, .indexed = true },
};

test "bulkImport equals row-by-row for a scalar indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try bulkTmpPath(testing.allocator, &tmp, "import_a.airdb");
    defer testing.allocator.free(path_a);
    const path_b = try bulkTmpPath(testing.allocator, &tmp, "import_b.airdb");
    defer testing.allocator.free(path_b);

    const N: u64 = 5000;

    // Shuffled input order for the bulk import: pks arrive out of order, so the
    // import must sort them and reproduce the same okey-per-pk mapping the
    // in-order row-by-row twin produces.
    const order = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE12345678);
    prng.random().shuffle(u64, order);

    const storage = try testing.allocator.alloc([3]u64, N);
    defer testing.allocator.free(storage);
    const row_slices = try testing.allocator.alloc([]const u64, N);
    defer testing.allocator.free(row_slices);
    for (order, 0..) |pk, k| {
        storage[k] = .{ pk, pk * 3, pk % 50 };
        row_slices[k] = &storage[k];
    }

    // db A: bulk import inside a one-type directory so verifyIntegrity audits it.
    {
        var db = try Db.create(testing.allocator, path_a);
        defer db.deinit();
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&import_defs}, &.{false});
        const cat0 = try typedir.catalogRef(&w, dir, 0);
        const new_cat = try bulkImport(&w, cat0, row_slices, .{});
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&db); // both value-index directions, in memory
    }

    // db B: the same rows inserted one at a time, in ascending-pk order.
    {
        var db = try Db.create(testing.allocator, path_b);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &import_defs);
        var pk: u64 = 0;
        while (pk < N) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3, pk % 50 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var da = try Db.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da); // audit again after reopen
    var dbb = try Db.open(testing.allocator, path_b);
    defer dbb.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try dbb.beginRead();
    defer rb.end();

    const cat_a = try typedir.catalogRef(&ra, ra.root(), 0);
    const cat_b = rb.root();

    // Counts equal.
    try testing.expectEqual(N, try catalog.liveCount(&ra, cat_a));
    try testing.expectEqual(try catalog.liveCount(&rb, cat_b), try catalog.liveCount(&ra, cat_a));

    // Every pk lookup equal: property values AND row version.
    var pk: u64 = 0;
    while (pk < N) : (pk += 1) {
        var oa: [3]u64 = undefined;
        var ob: [3]u64 = undefined;
        const va = try rawRows.getByPk(&ra, cat_a, pk, &oa);
        const vb = try rawRows.getByPk(&rb, cat_b, pk, &ob);
        try testing.expectEqual(vb, va);
        try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending okey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }

    // Indexed query: category == 7, equal sorted okey sets.
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &sb, testing.allocator);
        std.mem.sort(u64, sa.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, sb.items, {}, std.sort.asc(u64));
        try testing.expectEqualSlices(u64, sb.items, sa.items);
        try testing.expectEqual(@as(usize, 100), sa.items.len); // pk%50==7 over 0..5000
    }
}

test "bulkImport rejects a non-empty type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_nonempty.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &import_defs);
    cat = (try rawRows.insert(&w, cat, &.{ 1, 3, 1 })).cat;

    const more = [_][]const u64{ &.{ 10, 30, 5 }, &.{ 11, 33, 6 } };
    try testing.expectError(error.TypeNotEmpty, bulkImport(&w, cat, &more, .{}));

    // The type is unchanged: still one live row, intact.
    try testing.expectEqual(@as(u64, 1), try catalog.liveCount(&w, cat));
    var out: [3]u64 = undefined;
    try testing.expect((try rawRows.getByPk(&w, cat, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 3), out[1]);
    try testing.expectEqual(@as(u64, 1), out[2]);
    w.deinit();
}

test "bulkImport rejects duplicate pk before committing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_dup.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try catalog.createDefs(&w, &import_defs);

    const dup = [_][]const u64{ &.{ 5, 1, 0 }, &.{ 6, 2, 0 }, &.{ 5, 3, 0 } };
    try testing.expectError(error.DuplicateKey, bulkImport(&w, cat, &dup, .{}));

    // Nothing was written: the type is still empty.
    try testing.expectEqual(@as(u64, 0), try catalog.liveCount(&w, cat));
    const cv = try catalog.loadCatalog(&w, cat);
    try testing.expectEqual(@as(u64, 0), cv.next_row);
    try testing.expectEqual(@as(u64, 0), cv.next_key);
    w.deinit();
}

test "bulkImport rejects a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_link.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const link_defs = [_]catalog.PropDef{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } };
    const cat = try catalog.createDefs(&w, &link_defs);

    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&w, cat, &rws, .{}));
    w.deinit();
}

test "bulkImport edge sizes: empty, single, LEAF_CAP" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sizes = [_]u64{ 0, 1, @as(u64, cnode.LEAF_CAP) };
    for (sizes, 0..) |n, si| {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "edge_{d}.airdb", .{si});
        const path = try bulkTmpPath(testing.allocator, &tmp, name);
        defer testing.allocator.free(path);

        const storage = try testing.allocator.alloc([3]u64, n);
        defer testing.allocator.free(storage);
        const row_slices = try testing.allocator.alloc([]const u64, n);
        defer testing.allocator.free(row_slices);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            storage[i] = .{ i, i * 3, i % 7 };
            row_slices[i] = &storage[i];
        }

        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        {
            var w = try db.beginWrite();
            const dir = try typedir.createTypes(&w, &.{&import_defs}, &.{false});
            const cat0 = try typedir.catalogRef(&w, dir, 0);
            const new_cat = try bulkImport(&w, cat0, row_slices, .{ .presorted = true });
            const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
            w.setRoot(new_dir);
            _ = try w.commit();
        }
        try verification.verifyIntegrity(&db);

        var r = try db.beginRead();
        defer r.end();
        const cat = try typedir.catalogRef(&r, r.root(), 0);
        try testing.expectEqual(n, try catalog.liveCount(&r, cat));
        const cv = try catalog.loadCatalog(&r, cat);
        try testing.expectEqual(n, cv.next_row);
        try testing.expectEqual(n, cv.next_key);
        if (n > 0) {
            var out: [3]u64 = undefined;
            const last = n - 1;
            try testing.expect((try rawRows.getByPk(&r, cat, last, &out)) != null);
            try testing.expectEqual(last, out[0]);
            try testing.expectEqual(last * 3, out[1]);
            try testing.expectEqual(last % 7, out[2]);
        }
    }
}

fn appendRunVal(k: u64) u64 {
    return k *% 7 +% 3;
}

// Build a base tree of keys 0..base via sequential insert, append the run
// base..base+run via indexAppendRun, and assert the result is logically
// identical to inserting all keys 0..base+run sequentially.
fn checkAppendEquiv(w: *WriteTxn, base: u64, run: u64) !void {
    var base_root = try Index.create(w);
    var k: u64 = 0;
    while (k < base) : (k += 1) base_root = try Index.insert(w, base_root, k, appendRunVal(k));

    const rk = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rk);
    const rv = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rv);
    var r: u64 = 0;
    while (r < run) : (r += 1) {
        rk[r] = base + r;
        rv[r] = appendRunVal(base + r);
    }

    const appended = try indexAppendRun(w, base_root, rk, rv);

    var expected = try Index.create(w);
    k = 0;
    while (k < base + run) : (k += 1) expected = try Index.insert(w, expected, k, appendRunVal(k));

    const total = base + run;
    try testing.expectEqual(total, try Index.count(w, appended));
    try testing.expectEqual(try Index.count(w, expected), try Index.count(w, appended));

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
        try testing.expectEqual(try Index.get(w, expected, sk), try Index.get(w, appended, sk));
    }
    // Beyond the max key is absent in both.
    try testing.expectEqual(@as(?u64, null), try Index.get(w, appended, total));
    try testing.expectEqual(try Index.get(w, expected, total), try Index.get(w, appended, total));

    // Full ascending (key,val) sequence must match exactly.
    var ak = std.ArrayList(u64).empty;
    defer ak.deinit(testing.allocator);
    var av = std.ArrayList(u64).empty;
    defer av.deinit(testing.allocator);
    var ek = std.ArrayList(u64).empty;
    defer ek.deinit(testing.allocator);
    var ev = std.ArrayList(u64).empty;
    defer ev.deinit(testing.allocator);
    try Index.forEachEntry(w, appended, IdxCollector{ .keys = &ak, .vals = &av }, IdxCollector.onEntry);
    try Index.forEachEntry(w, expected, IdxCollector{ .keys = &ek, .vals = &ev }, IdxCollector.onEntry);
    try testing.expectEqualSlices(u64, ek.items, ak.items);
    try testing.expectEqualSlices(u64, ev.items, av.items);
}

fn appendTmpDb(tmp: *testing.TmpDir, name: []const u8) !Db {
    const path = try bulkTmpPath(testing.allocator, tmp, name);
    defer testing.allocator.free(path);
    return Db.create(testing.allocator, path);
}

test "indexAppendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append1.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 100, 200); // 100 % 64 == 36 in the last leaf
    w.deinit();
}

test "indexAppendRun overflow rightmost inner node" {
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

test "indexAppendRun grows tree height by one" {
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

test "indexAppendRun single-leaf base tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append4.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 40, 50); // base < LEAF_CAP
    w.deinit();
}

test "indexAppendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append5.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkAppendEquiv(&w, 10, 5000);
    w.deinit();
}

test "indexAppendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "append6.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    var base_root = try Index.create(&w);
    var k: u64 = 0;
    while (k < 100) : (k += 1) base_root = try Index.insert(&w, base_root, k, appendRunVal(k));
    const before = try Index.count(&w, base_root);
    const appended = try indexAppendRun(&w, base_root, &.{}, &.{});
    try testing.expectEqual(base_root, appended); // same ref, unchanged
    try testing.expectEqual(before, try Index.count(&w, appended));
    w.deinit();
}

fn appendColVal(i: u64) u64 {
    return i *% 11 +% 5;
}

// Build a base column of `base` values via sequential append, append `run` more
// values via columnAppendRun, and assert the result is logically identical to
// appending all base+run values sequentially: same length, and get(i) matches
// the sequential twin at every index.
fn checkColAppendEquiv(w: *WriteTxn, base: u64, run: u64) !void {
    var base_root = try Column.create(w);
    var k: u64 = 0;
    while (k < base) : (k += 1) base_root = try Column.append(w, base_root, appendColVal(k));

    const rv = try testing.allocator.alloc(u64, run);
    defer testing.allocator.free(rv);
    var r: u64 = 0;
    while (r < run) : (r += 1) rv[r] = appendColVal(base + r);

    const appended = try columnAppendRun(w, base_root, rv);

    var expected = try Column.create(w);
    k = 0;
    while (k < base + run) : (k += 1) expected = try Column.append(w, expected, appendColVal(k));

    const total = base + run;
    try testing.expectEqual(total, try Column.len(w, appended));
    try testing.expectEqual(try Column.len(w, expected), try Column.len(w, appended));

    var i: u64 = 0;
    while (i < total) : (i += 1) {
        try testing.expectEqual(try Column.get(w, expected, i), try Column.get(w, appended, i));
    }
    if (total > 0) try testing.expectError(error.IndexOutOfBounds, Column.get(w, appended, total));
}

test "columnAppendRun partial last leaf then new leaves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend1.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 100, 200); // 100 % 64 == 36 in the last leaf
    w.deinit();
}

test "columnAppendRun grows height" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend2.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    // Single-leaf base, run crossing FANOUT*LEAF_CAP (== 4096) so the result
    // must be three levels tall.
    try checkColAppendEquiv(&w, 50, 4200);
    w.deinit();
}

test "columnAppendRun single-leaf base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend3.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 40, 50); // base < LEAF_CAP
    w.deinit();
}

test "columnAppendRun run far larger than base" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend4.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColAppendEquiv(&w, 10, 5000);
    w.deinit();
}

test "columnAppendRun empty run is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try appendTmpDb(&tmp, "colappend5.airdb");
    defer db.deinit();
    var w = try db.beginWrite();
    var base_root = try Column.create(&w);
    var k: u64 = 0;
    while (k < 100) : (k += 1) base_root = try Column.append(&w, base_root, appendColVal(k));
    const before = try Column.len(&w, base_root);
    const appended = try columnAppendRun(&w, base_root, &.{});
    try testing.expectEqual(base_root, appended); // same ref, unchanged
    try testing.expectEqual(before, try Column.len(&w, appended));
    w.deinit();
}

// A no-index, no-link scalar schema: int pk, int value. Qualifies for append.
const append_defs = [_]catalog.PropDef{ .{ .kind = .int }, .{ .kind = .int } };

test "bulkAppend equals row-by-row for a contiguous monotonic batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try bulkTmpPath(testing.allocator, &tmp, "append_eq_a.airdb");
    defer testing.allocator.free(path_a);
    const path_b = try bulkTmpPath(testing.allocator, &tmp, "append_eq_b.airdb");
    defer testing.allocator.free(path_b);

    const BASE: u64 = 1000;
    const APPEND: u64 = 500;
    const TOTAL = BASE + APPEND;

    // Batch rows: pks BASE..TOTAL, value = pk*3 (ascending, above the base max).
    const storage = try testing.allocator.alloc([2]u64, APPEND);
    defer testing.allocator.free(storage);
    const batch = try testing.allocator.alloc([]const u64, APPEND);
    defer testing.allocator.free(batch);
    {
        var j: usize = 0;
        while (j < APPEND) : (j += 1) {
            const pk = BASE + @as(u64, @intCast(j));
            storage[j] = .{ pk, pk * 3 };
            batch[j] = &storage[j];
        }
    }

    // db A: base via row-by-row insert, then the batch via bulkAppend, inside a
    // one-type directory so verifyIntegrity audits it.
    {
        var db = try Db.create(testing.allocator, path_a);
        defer db.deinit();
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&append_defs}, &.{false});
        var cat = try typedir.catalogRef(&w, dir, 0);
        var pk: u64 = 0;
        while (pk < BASE) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3 })).cat;
        const new_cat = try bulkAppend(&w, cat, batch);
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&db);
    }

    // db B: every row inserted one at a time, in ascending-pk order.
    {
        var db = try Db.create(testing.allocator, path_b);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &append_defs);
        var pk: u64 = 0;
        while (pk < TOTAL) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var da = try Db.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da); // audit again after reopen
    var dbb = try Db.open(testing.allocator, path_b);
    defer dbb.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try dbb.beginRead();
    defer rb.end();

    const cat_a = try typedir.catalogRef(&ra, ra.root(), 0);
    const cat_b = rb.root();

    // Counts equal.
    try testing.expectEqual(TOTAL, try catalog.liveCount(&ra, cat_a));
    try testing.expectEqual(try catalog.liveCount(&rb, cat_b), try catalog.liveCount(&ra, cat_a));

    // Every pk lookup equal: property values AND row version.
    var pk: u64 = 0;
    while (pk < TOTAL) : (pk += 1) {
        var oa: [2]u64 = undefined;
        var ob: [2]u64 = undefined;
        const va = try rawRows.getByPk(&ra, cat_a, pk, &oa);
        const vb = try rawRows.getByPk(&rb, cat_b, pk, &ob);
        try testing.expectEqual(vb, va);
        try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending okey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }
}

test "bulkAppend returns NotAppendable for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_scatter.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &append_defs);
    var pk: u64 = 0;
    while (pk < 100) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3 })).cat;

    const before = try catalog.liveCount(&w, cat);
    var before_row: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPk(&w, cat, 50, &before_row)) != null);

    // First batch pk (50) is <= the current max (99): not a right-edge append.
    const batch = [_][]const u64{ &.{ 50, 150 }, &.{ 200, 600 }, &.{ 201, 603 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &batch));

    // The type is byte-unchanged: same count, and the sampled row is intact.
    try testing.expectEqual(before, try catalog.liveCount(&w, cat));
    var after_row: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPk(&w, cat, 50, &after_row)) != null);
    try testing.expectEqualSlices(u64, &before_row, &after_row);
    w.deinit();
}

test "bulkAppend returns NotAppendable for an indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_indexed.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    cat = (try rawRows.insert(&w, cat, &.{ 1, 10 })).cat;

    // Even an ascending batch above the max is rejected: a pure right-edge append
    // cannot maintain the value index.
    const batch = [_][]const u64{ &.{ 100, 5 }, &.{ 101, 6 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &batch));
    w.deinit();
}

test "bulkAppend returns NotAppendable for a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_link.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } });
    cat = (try rawRows.insert(&w, cat, &.{ 1, 0 })).cat;

    const batch = [_][]const u64{ &.{ 100, 0 }, &.{ 101, 0 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &batch));
    w.deinit();
}

test "bulkAppend returns NotAppendable for a non-ascending or duplicate batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_nonasc.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &append_defs);
    cat = (try rawRows.insert(&w, cat, &.{ 1, 3 })).cat;

    // Non-ascending batch (both pks above the max, but out of order).
    const desc = [_][]const u64{ &.{ 200, 600 }, &.{ 150, 450 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &desc));

    // In-batch duplicate pk.
    const dup = [_][]const u64{ &.{ 300, 900 }, &.{ 300, 901 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, cat, &dup));
    w.deinit();
}

test "bulkAppendOrInsert falls back and equals row-by-row for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try bulkTmpPath(testing.allocator, &tmp, "fallback_a.airdb");
    defer testing.allocator.free(path_a);
    const path_b = try bulkTmpPath(testing.allocator, &tmp, "fallback_b.airdb");
    defer testing.allocator.free(path_b);

    const BASE: u64 = 100;
    // Scattered batch: all pks new (>= BASE) and distinct, but out of order, so
    // bulkAppend rejects and the orchestrator falls back to row-by-row insert.
    const scattered_pks = [_]u64{ 200, 100, 300, 150, 400, 250 };
    const TOTAL = BASE + scattered_pks.len;

    var storage: [scattered_pks.len][2]u64 = undefined;
    var batch: [scattered_pks.len][]const u64 = undefined;
    for (scattered_pks, 0..) |pk, j| {
        storage[j] = .{ pk, pk * 3 };
        batch[j] = &storage[j];
    }

    // db A: base via insert, then the scattered batch via bulkAppendOrInsert,
    // inside a one-type directory so verifyIntegrity audits it.
    {
        var db = try Db.create(testing.allocator, path_a);
        defer db.deinit();
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&append_defs}, &.{false});
        var cat = try typedir.catalogRef(&w, dir, 0);
        var pk: u64 = 0;
        while (pk < BASE) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3 })).cat;
        const new_cat = try bulkAppendOrInsert(&w, cat, &batch);
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&db);
    }

    // db B: base via insert, then the same scattered rows inserted one at a time
    // in the SAME order the fallback uses.
    {
        var db = try Db.create(testing.allocator, path_b);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &append_defs);
        var pk: u64 = 0;
        while (pk < BASE) : (pk += 1) cat = (try rawRows.insert(&w, cat, &.{ pk, pk * 3 })).cat;
        for (scattered_pks) |spk| cat = (try rawRows.insert(&w, cat, &.{ spk, spk * 3 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }

    var da = try Db.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da);
    var dbb = try Db.open(testing.allocator, path_b);
    defer dbb.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try dbb.beginRead();
    defer rb.end();

    const cat_a = try typedir.catalogRef(&ra, ra.root(), 0);
    const cat_b = rb.root();

    try testing.expectEqual(@as(u64, TOTAL), try catalog.liveCount(&ra, cat_a));
    try testing.expectEqual(try catalog.liveCount(&rb, cat_b), try catalog.liveCount(&ra, cat_a));

    // Every pk over the union (and the absent gaps between) resolves identically.
    var pk: u64 = 0;
    while (pk <= 401) : (pk += 1) {
        var oa: [2]u64 = undefined;
        var ob: [2]u64 = undefined;
        const va = try rawRows.getByPk(&ra, cat_a, pk, &oa);
        const vb = try rawRows.getByPk(&rb, cat_b, pk, &ob);
        try testing.expectEqual(vb, va);
        if (vb != null) try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending okey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }
}

test "bulkAppendOrInsert empty batch is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_empty.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &append_defs);
    cat = (try rawRows.insert(&w, cat, &.{ 1, 3 })).cat;

    const before = try catalog.liveCount(&w, cat);
    const after = try bulkAppendOrInsert(&w, cat, &.{});
    try testing.expectEqual(cat, after); // same ref, untouched
    try testing.expectEqual(before, try catalog.liveCount(&w, after));
    w.deinit();
}
