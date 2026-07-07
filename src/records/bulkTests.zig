const std = @import("std");
const verification = @import("../verification.zig");
const bulk = @import("bulk.zig");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const cnode = @import("../trees/columnNode.zig");
const inode = @import("../trees/indexNode.zig");
const catalog = @import("../schema/catalog.zig");
const objects = @import("objects.zig");
const rawRows = @import("rows.zig");
const ValueObjectKeys = bulk.ValueObjectKeys;
const bulkColumn = bulk.bulkColumn;
const bulkIndex = bulk.bulkIndex;
const bulkValueIndex = bulk.bulkValueIndex;
const bulkImport = bulk.bulkImport;
const bulkAppend = bulk.bulkAppend;
const bulkAppendOrInsert = bulk.bulkAppendOrInsert;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const query = @import("../query.zig");

const typedir = @import("../schema/typeDirectory.zig");

fn bulkTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "bulk append is refused when the batch does not clear the true max primaryKey" {
    // Regression: deleting the upper primaryKey range empties the primaryKey index's rightmost
    // leaf. A maxKey that followed only the rightmost path then reported the
    // type EMPTY, so bulkAppend admitted a batch below the surviving keys --
    // duplicate primaryKeys and broken leaf ordering. The batch must be NotAppendable
    // (and the fallback must handle it correctly instead).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_maxpk.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var primaryKey: u64 = 0;
    while (primaryKey <= 64) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey })).catalogRef; // primaryKey index splits
    var out: [2]u64 = undefined;
    primaryKey = 32;
    while (primaryKey <= 64) : (primaryKey += 1) {
        const version = (try rawRows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
        catalogRef = (try rawRows.delete(&w, catalogRef, primaryKey, version)).ok;
    }
    // primaryKeys 0..31 survive; a batch starting at 10 must NOT take the fast path.
    const rows = [_][]const u64{ &.{ 10, 1 }, &.{ 11, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &rows));
    // The orchestrator falls back to row-by-row, which detects the duplicate.
    try testing.expectError(error.DuplicateKey, bulkAppendOrInsert(&w, catalogRef, &rows));
    // A batch that truly clears the surviving max qualifies.
    const ok_rows = [_][]const u64{ &.{ 100, 1 }, &.{ 101, 2 } };
    catalogRef = try bulkAppend(&w, catalogRef, &ok_rows);
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 100, &out)) != null);
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 31, &out)) != null);
}

test "bulk append into a primaryKey-history gap takes the fallback" {
    // Regression: with primaryKeys 0..31 and 40..104 inserted then 40..104 deleted,
    // the rightmost primaryKey-index leaves are EMPTY but keep recorded lows (40, 72).
    // A batch of {33, 34} clears the surviving max (31) but sits BELOW the
    // stale low; the old fast path rebuilt the low-72 leaf with low 33 and the
    // appended rows became unreachable. Such a batch must fall back; a batch
    // clearing the stale low may still take the fast path.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_gap.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var primaryKey: u64 = 0;
    while (primaryKey <= 31) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey })).catalogRef;
    primaryKey = 40;
    while (primaryKey <= 104) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey })).catalogRef;
    var out: [2]u64 = undefined;
    primaryKey = 40;
    while (primaryKey <= 104) : (primaryKey += 1) {
        const version = (try rawRows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
        catalogRef = (try rawRows.delete(&w, catalogRef, primaryKey, version)).ok;
    }

    // Below the stale low: NotAppendable; the orchestrator's fallback must
    // leave every row reachable.
    const gap_rows = [_][]const u64{ &.{ 33, 1 }, &.{ 34, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &gap_rows));
    catalogRef = try bulkAppendOrInsert(&w, catalogRef, &gap_rows);
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 33, &out)) != null);
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 34, &out)) != null);

    // Every surviving primaryKey still resolves (routing lows intact).
    primaryKey = 0;
    while (primaryKey <= 31) : (primaryKey += 1) try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)) != null);
}

test "bulk append fallback refuses link-bearing schemas" {
    // objects.insert writes raw columns without backlink maintenance, so the
    // row-by-row fallback must reject link/link_set types like bulkImport does
    // instead of silently corrupting the graph.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_links.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    const catalogRef = try catalog.createFromDefinitions(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const rows = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkAppendOrInsert(&w, catalogRef, &rows));
}

test "bulk append frees the replaced right-edge nodes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_free.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a populated type so the old right edge is committed nodes.
    {
        var w = try database.beginWrite();
        var catalogRef = try catalog.create(&w, 2);
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // A qualifying append must record the replaced committed spine as
    // in-flight frees (deferred, MVCC-safe reclaim) instead of leaking it.
    var w = try database.beginWrite();
    defer w.deinit();
    const rows = [_][]const u64{ &.{ 1000, 1 }, &.{ 1001, 2 } };
    _ = try bulkAppend(&w, w.new_root, &rows);
    try testing.expect(w.in_flight_frees.items.len > 0);
}

fn checkColumnSize(w: *WriteTransaction, n: usize) !void {
    const values = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(values);
    for (values, 0..) |*v, i| v.* = @as(u64, i) * 7;

    const built = try bulkColumn(w, values);

    var seq = try Column.create(w);
    for (values) |v| seq = try Column.append(w, seq, v);

    try testing.expectEqual(try Column.length(w, seq), try Column.length(w, built));
    try testing.expectEqual(@as(u64, n), try Column.length(w, built));
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
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    try checkColumnSize(&w, 1000);
    w.deinit();
}

test "bulkColumn boundary sizes: 0, 1, leafCap, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcolsizes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    try checkColumnSize(&w, 0);
    try checkColumnSize(&w, 1);
    try checkColumnSize(&w, cnode.leafCap); // single full leaf
    try checkColumnSize(&w, @as(usize, cnode.leafCap) * cnode.fanout + 1); // 3 levels
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

fn checkIndexSize(w: *WriteTransaction, n: usize) !void {
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
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    try checkIndexSize(&w, 1000);
    w.deinit();
}

test "bulkIndex boundary sizes: 0, 1, leafCap, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidxsizes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    try checkIndexSize(&w, 0);
    try checkIndexSize(&w, 1);
    try checkIndexSize(&w, inode.leafCap);
    try checkIndexSize(&w, @as(usize, inode.leafCap) * inode.fanout + 1);
    w.deinit();
}

const SetCollector = struct {
    keys: *std.ArrayList(u64),
    fn onKey(self: @This(), key: u64) !void {
        try self.keys.append(testing.allocator, key);
    }
};

fn collectSet(w: *WriteTransaction, set_root: Reference, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    try Index.forEachKey(w, set_root, SetCollector{ .keys = out }, SetCollector.onKey);
}

test "bulkValueIndex equals sequential maintenance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkvi.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();

    const N: u64 = 1000;
    const num_values: u64 = 100;

    // Build the grouped entries: value v=i%100 maps to objectKeys {i : i%100==v}, ascending.
    var entries = std.ArrayList(ValueObjectKeys).empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.objectKeys);
        entries.deinit(testing.allocator);
    }
    var v: u64 = 0;
    while (v < num_values) : (v += 1) {
        var objectKeys = std.ArrayList(u64).empty;
        var i: u64 = v; // first objectKey with i%100==v
        while (i < N) : (i += num_values) try objectKeys.append(testing.allocator, i);
        try entries.append(testing.allocator, .{ .value = v, .objectKeys = try objectKeys.toOwnedSlice(testing.allocator) });
    }

    const built = try bulkValueIndex(&w, entries.items);

    // Sequential maintenance mirror: for each (value, objectKey) add objectKey to the inner
    // set for value, exactly as rows.valueIndexAdd does.
    var seq = try Index.create(&w);
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const value = i % num_values;
        const existing = try Index.get(&w, seq, value);
        var set_root = existing orelse try Index.create(&w);
        set_root = try Index.insert(&w, set_root, i, 1);
        seq = try Index.insert(&w, seq, value, set_root);
    }

    // Compare the inner objectKey set for every value.
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

// Schema shared by the orchestrator tests: int primaryKey, int value, int category (indexed).
const importDefinitions = [_]catalog.PropertyDefinition{
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

    // Shuffled input order for the bulk import: primaryKeys arrive out of order, so the
    // import must sort them and reproduce the same objectKey-per-primaryKey mapping the
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
    for (order, 0..) |primaryKey, k| {
        storage[k] = .{ primaryKey, primaryKey * 3, primaryKey % 50 };
        row_slices[k] = &storage[k];
    }

    // database A: bulk import inside a one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, path_a);
        defer database.deinit();
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&importDefinitions}, &.{false});
        const catalog0 = try typedir.catalogRef(&w, dir, 0);
        const newCatalog = try bulkImport(&w, catalog0, row_slices, .{});
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&database); // both value-index directions, in memory
    }

    // database B: the same rows inserted one at a time, in ascending-primaryKey order.
    {
        var database = try Database.create(testing.allocator, path_b);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createFromDefinitions(&w, &importDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < N) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3, primaryKey % 50 })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var da = try Database.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da); // audit again after reopen
    var databaseB = try Database.open(testing.allocator, path_b);
    defer databaseB.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try databaseB.beginRead();
    defer rb.end();

    const catalogA = try typedir.catalogRef(&ra, ra.root(), 0);
    const catalogB = rb.root();

    // Counts equal.
    try testing.expectEqual(N, try catalog.liveCount(&ra, catalogA));
    try testing.expectEqual(try catalog.liveCount(&rb, catalogB), try catalog.liveCount(&ra, catalogA));

    // Every primaryKey lookup equal: property values AND row version.
    var primaryKey: u64 = 0;
    while (primaryKey < N) : (primaryKey += 1) {
        var oa: [3]u64 = undefined;
        var ob: [3]u64 = undefined;
        const va = try rawRows.getByPrimaryKey(&ra, catalogA, primaryKey, &oa);
        const vb = try rawRows.getByPrimaryKey(&rb, catalogB, primaryKey, &ob);
        try testing.expectEqual(vb, va);
        try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, catalogA, &.{}, &sa, testing.allocator);
        try query.where(&rb, catalogB, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }

    // Indexed query: category == 7, equal sorted objectKey sets.
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, catalogA, &.{.{ .property = 2, .op = .eq, .value = 7 }}, &sa, testing.allocator);
        try query.where(&rb, catalogB, &.{.{ .property = 2, .op = .eq, .value = 7 }}, &sb, testing.allocator);
        std.mem.sort(u64, sa.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, sb.items, {}, std.sort.asc(u64));
        try testing.expectEqualSlices(u64, sb.items, sa.items);
        try testing.expectEqual(@as(usize, 100), sa.items.len); // primaryKey%50==7 over 0..5000
    }
}

test "bulkImport rejects a non-empty type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_nonempty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &importDefinitions);
    catalogRef = (try rawRows.insert(&w, catalogRef, &.{ 1, 3, 1 })).catalogRef;

    const more = [_][]const u64{ &.{ 10, 30, 5 }, &.{ 11, 33, 6 } };
    try testing.expectError(error.TypeNotEmpty, bulkImport(&w, catalogRef, &more, .{}));

    // The type is unchanged: still one live row, intact.
    try testing.expectEqual(@as(u64, 1), try catalog.liveCount(&w, catalogRef));
    var out: [3]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 3), out[1]);
    try testing.expectEqual(@as(u64, 1), out[2]);
    w.deinit();
}

test "bulkImport rejects duplicate primaryKey before committing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_dup.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try catalog.createFromDefinitions(&w, &importDefinitions);

    const dup = [_][]const u64{ &.{ 5, 1, 0 }, &.{ 6, 2, 0 }, &.{ 5, 3, 0 } };
    try testing.expectError(error.DuplicateKey, bulkImport(&w, catalogRef, &dup, .{}));

    // Nothing was written: the type is still empty.
    try testing.expectEqual(@as(u64, 0), try catalog.liveCount(&w, catalogRef));
    const cv = try catalog.loadCatalog(&w, catalogRef);
    try testing.expectEqual(@as(u64, 0), cv.next_row);
    try testing.expectEqual(@as(u64, 0), cv.next_key);
    w.deinit();
}

test "bulkImport rejects a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const linkDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } };
    const catalogRef = try catalog.createFromDefinitions(&w, &linkDefinitions);

    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&w, catalogRef, &rws, .{}));
    w.deinit();
}

test "bulkImport edge sizes: empty, single, leafCap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sizes = [_]u64{ 0, 1, @as(u64, cnode.leafCap) };
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

        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        {
            var w = try database.beginWrite();
            const dir = try typedir.createTypes(&w, &.{&importDefinitions}, &.{false});
            const catalog0 = try typedir.catalogRef(&w, dir, 0);
            const newCatalog = try bulkImport(&w, catalog0, row_slices, .{ .presorted = true });
            const new_dir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
            w.setRoot(new_dir);
            _ = try w.commit();
        }
        try verification.verifyIntegrity(&database);

        var r = try database.beginRead();
        defer r.end();
        const catalogRef = try typedir.catalogRef(&r, r.root(), 0);
        try testing.expectEqual(n, try catalog.liveCount(&r, catalogRef));
        const cv = try catalog.loadCatalog(&r, catalogRef);
        try testing.expectEqual(n, cv.next_row);
        try testing.expectEqual(n, cv.next_key);
        if (n > 0) {
            var out: [3]u64 = undefined;
            const last = n - 1;
            try testing.expect((try rawRows.getByPrimaryKey(&r, catalogRef, last, &out)) != null);
            try testing.expectEqual(last, out[0]);
            try testing.expectEqual(last * 3, out[1]);
            try testing.expectEqual(last % 7, out[2]);
        }
    }
}

// A no-index, no-link scalar schema: int primaryKey, int value. Qualifies for append.
const appendDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int } };

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

    // Batch rows: primaryKeys BASE..TOTAL, value = primaryKey*3 (ascending, above the base max).
    const storage = try testing.allocator.alloc([2]u64, APPEND);
    defer testing.allocator.free(storage);
    const batch = try testing.allocator.alloc([]const u64, APPEND);
    defer testing.allocator.free(batch);
    {
        var j: usize = 0;
        while (j < APPEND) : (j += 1) {
            const primaryKey = BASE + @as(u64, @intCast(j));
            storage[j] = .{ primaryKey, primaryKey * 3 };
            batch[j] = &storage[j];
        }
    }

    // database A: base via row-by-row insert, then the batch via bulkAppend, inside a
    // one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, path_a);
        defer database.deinit();
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&appendDefinitions}, &.{false});
        var catalogRef = try typedir.catalogRef(&w, dir, 0);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3 })).catalogRef;
        const newCatalog = try bulkAppend(&w, catalogRef, batch);
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&database);
    }

    // database B: every row inserted one at a time, in ascending-primaryKey order.
    {
        var database = try Database.create(testing.allocator, path_b);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createFromDefinitions(&w, &appendDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < TOTAL) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3 })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var da = try Database.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da); // audit again after reopen
    var databaseB = try Database.open(testing.allocator, path_b);
    defer databaseB.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try databaseB.beginRead();
    defer rb.end();

    const catalogA = try typedir.catalogRef(&ra, ra.root(), 0);
    const catalogB = rb.root();

    // Counts equal.
    try testing.expectEqual(TOTAL, try catalog.liveCount(&ra, catalogA));
    try testing.expectEqual(try catalog.liveCount(&rb, catalogB), try catalog.liveCount(&ra, catalogA));

    // Every primaryKey lookup equal: property values AND row version.
    var primaryKey: u64 = 0;
    while (primaryKey < TOTAL) : (primaryKey += 1) {
        var oa: [2]u64 = undefined;
        var ob: [2]u64 = undefined;
        const va = try rawRows.getByPrimaryKey(&ra, catalogA, primaryKey, &oa);
        const vb = try rawRows.getByPrimaryKey(&rb, catalogB, primaryKey, &ob);
        try testing.expectEqual(vb, va);
        try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, catalogA, &.{}, &sa, testing.allocator);
        try query.where(&rb, catalogB, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }
}

test "bulkAppend returns NotAppendable for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_scatter.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &appendDefinitions);
    var primaryKey: u64 = 0;
    while (primaryKey < 100) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3 })).catalogRef;

    const before = try catalog.liveCount(&w, catalogRef);
    var before_row: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 50, &before_row)) != null);

    // First batch primaryKey (50) is <= the current max (99): not a right-edge append.
    const batch = [_][]const u64{ &.{ 50, 150 }, &.{ 200, 600 }, &.{ 201, 603 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &batch));

    // The type is byte-unchanged: same count, and the sampled row is intact.
    try testing.expectEqual(before, try catalog.liveCount(&w, catalogRef));
    var after_row: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&w, catalogRef, 50, &after_row)) != null);
    try testing.expectEqualSlices(u64, &before_row, &after_row);
    w.deinit();
}

test "bulkAppend returns NotAppendable for an indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_indexed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    catalogRef = (try rawRows.insert(&w, catalogRef, &.{ 1, 10 })).catalogRef;

    // Even an ascending batch above the max is rejected: a pure right-edge append
    // cannot maintain the value index.
    const batch = [_][]const u64{ &.{ 100, 5 }, &.{ 101, 6 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &batch));
    w.deinit();
}

test "bulkAppend returns NotAppendable for a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } });
    catalogRef = (try rawRows.insert(&w, catalogRef, &.{ 1, 0 })).catalogRef;

    const batch = [_][]const u64{ &.{ 100, 0 }, &.{ 101, 0 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &batch));
    w.deinit();
}

test "bulkAppend returns NotAppendable for a non-ascending or duplicate batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_nonasc.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &appendDefinitions);
    catalogRef = (try rawRows.insert(&w, catalogRef, &.{ 1, 3 })).catalogRef;

    // Non-ascending batch (both primaryKeys above the max, but out of order).
    const desc = [_][]const u64{ &.{ 200, 600 }, &.{ 150, 450 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &desc));

    // In-batch duplicate primaryKey.
    const dup = [_][]const u64{ &.{ 300, 900 }, &.{ 300, 901 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&w, catalogRef, &dup));
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
    // Scattered batch: all primaryKeys new (>= BASE) and distinct, but out of order, so
    // bulkAppend rejects and the orchestrator falls back to row-by-row insert.
    const scatteredPrimaryKeys = [_]u64{ 200, 100, 300, 150, 400, 250 };
    const TOTAL = BASE + scatteredPrimaryKeys.len;

    var storage: [scatteredPrimaryKeys.len][2]u64 = undefined;
    var batch: [scatteredPrimaryKeys.len][]const u64 = undefined;
    for (scatteredPrimaryKeys, 0..) |primaryKey, j| {
        storage[j] = .{ primaryKey, primaryKey * 3 };
        batch[j] = &storage[j];
    }

    // database A: base via insert, then the scattered batch via bulkAppendOrInsert,
    // inside a one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, path_a);
        defer database.deinit();
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&appendDefinitions}, &.{false});
        var catalogRef = try typedir.catalogRef(&w, dir, 0);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3 })).catalogRef;
        const newCatalog = try bulkAppendOrInsert(&w, catalogRef, &batch);
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
        w.setRoot(new_dir);
        _ = try w.commit();
        try verification.verifyIntegrity(&database);
    }

    // database B: base via insert, then the same scattered rows inserted one at a time
    // in the SAME order the fallback uses.
    {
        var database = try Database.create(testing.allocator, path_b);
        defer database.deinit();
        var w = try database.beginWrite();
        var catalogRef = try catalog.createFromDefinitions(&w, &appendDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogRef = (try rawRows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 3 })).catalogRef;
        for (scatteredPrimaryKeys) |scatteredPrimaryKey| catalogRef = (try rawRows.insert(&w, catalogRef, &.{ scatteredPrimaryKey, scatteredPrimaryKey * 3 })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    var da = try Database.open(testing.allocator, path_a);
    defer da.deinit();
    try verification.verifyIntegrity(&da);
    var databaseB = try Database.open(testing.allocator, path_b);
    defer databaseB.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try databaseB.beginRead();
    defer rb.end();

    const catalogA = try typedir.catalogRef(&ra, ra.root(), 0);
    const catalogB = rb.root();

    try testing.expectEqual(@as(u64, TOTAL), try catalog.liveCount(&ra, catalogA));
    try testing.expectEqual(try catalog.liveCount(&rb, catalogB), try catalog.liveCount(&ra, catalogA));

    // Every primaryKey over the union (and the absent gaps between) resolves identically.
    var primaryKey: u64 = 0;
    while (primaryKey <= 401) : (primaryKey += 1) {
        var oa: [2]u64 = undefined;
        var ob: [2]u64 = undefined;
        const va = try rawRows.getByPrimaryKey(&ra, catalogA, primaryKey, &oa);
        const vb = try rawRows.getByPrimaryKey(&rb, catalogB, primaryKey, &ob);
        try testing.expectEqual(vb, va);
        if (vb != null) try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, catalogA, &.{}, &sa, testing.allocator);
        try query.where(&rb, catalogB, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }
}

test "bulkAppendOrInsert empty batch is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_empty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.createFromDefinitions(&w, &appendDefinitions);
    catalogRef = (try rawRows.insert(&w, catalogRef, &.{ 1, 3 })).catalogRef;

    const before = try catalog.liveCount(&w, catalogRef);
    const after = try bulkAppendOrInsert(&w, catalogRef, &.{});
    try testing.expectEqual(catalogRef, after); // same ref, untouched
    try testing.expectEqual(before, try catalog.liveCount(&w, after));
    w.deinit();
}
