const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("catalog.zig");
const objects = @import("objects.zig");
const index = @import("index.zig");
const Ref = @import("ref.zig").Ref;
const Db = @import("db.zig").Db;
const Predicate = query.Predicate;
const where = query.where;
const countWhere = query.countWhere;
const aggregateInt = query.aggregateInt;
const rangeInclusive = query.rangeInclusive;
const sortByPropAsc = query.sortByPropAsc;

fn qTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..path_len], name });
}

// Build a 3-prop type: prop0 = pk, prop1 = value (indexed iff `idx`), prop2 =
// secondary. Inserts n rows with pk=i, prop1=i%100, prop2=i.
fn seedPlannerCat(w: *@import("db.zig").WriteTxn, idx: bool, n: u64) !Ref {
    const defs = [_]catalog.PropDef{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = idx },
        .{ .kind = .int },
    };
    var cat = try catalog.createDefs(w, &defs);
    var i: u64 = 0;
    while (i < n) : (i += 1) cat = (try objects.insert(w, cat, &.{ i, i % 100, i })).cat;
    return cat;
}

// Build a type with pk(int) + age(int) and insert (pk, age) rows.
fn seed(w: anytype, pairs: []const [2]u64) !Ref {
    var cat = try catalog.create(w, 2);
    for (pairs) |p| cat = (try objects.insert(w, cat, &.{ p[0], p[1] })).cat;
    return cat;
}

test "where filters live rows by ANDed predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try seed(&w, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    // age == 30
    var r1 = std.ArrayList(u64).empty;
    defer r1.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &r1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r1.items.len);
    // age > 25 AND pk < 4  -> pk 2 (age30), pk3 (age40) ; pk4 excluded by pk<4
    var r2 = std.ArrayList(u64).empty;
    defer r2.deinit(testing.allocator);
    try where(&w, cat, &.{
        .{ .prop = 1, .op = .gt, .value = 25 },
        .{ .prop = 0, .op = .lt, .value = 4 },
    }, &r2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r2.items.len);
    // delete pk 2, re-query age==30 -> only pk4
    var out: [2]u64 = undefined;
    const vv = (try objects.getByPk(&w, cat, 2, &out)).?;
    cat = (try objects.delete(&w, cat, 2, vv)).ok;
    var r3 = std.ArrayList(u64).empty;
    defer r3.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &r3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), r3.items.len);
    w.deinit();
}

test "out-of-range property indices are rejected up front" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qbadprop.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    const cat = try seed(&w, &.{.{ 1, 20 }});
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    const bad = [_]Predicate{.{ .prop = 2, .op = .eq, .value = 1 }};
    try testing.expectError(error.BadProp, where(&w, cat, &bad, &hits, testing.allocator));
    try testing.expectError(error.BadProp, countWhere(&w, cat, &bad, testing.allocator));
    try testing.expectError(error.BadProp, aggregateInt(&w, cat, 9, &.{}, testing.allocator));
    var okeys = [_]u64{};
    try testing.expectError(error.BadProp, sortByPropAsc(&w, cat, &okeys, 5, testing.allocator));
}

test "streamed full scan agrees with where on count and aggregate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qstream.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    var cat = try seed(&w, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 }, .{ 5, 25 } });
    // Tombstone one matching row so the live filter is exercised mid-stream.
    var out: [2]u64 = undefined;
    const ver = (try objects.getByPk(&w, cat, 4, &out)).?;
    cat = (try objects.delete(&w, cat, 4, ver)).ok;

    const preds = [_]Predicate{.{ .prop = 1, .op = .ge, .value = 25 }};
    var okeys = std.ArrayList(u64).empty;
    defer okeys.deinit(testing.allocator);
    try where(&w, cat, &preds, &okeys, testing.allocator);
    try testing.expectEqual(@as(usize, 3), okeys.items.len); // pks 2, 3, 5
    try testing.expectEqual(@as(u64, okeys.items.len), try countWhere(&w, cat, &preds, testing.allocator));
    const agg = try aggregateInt(&w, cat, 1, &preds, testing.allocator);
    try testing.expectEqual(@as(u64, 3), agg.count);
    try testing.expectEqual(@as(u64, 30 + 40 + 25), agg.sum);
    try testing.expectEqual(@as(?u64, 25), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
}

test "countWhere and aggregateInt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try seed(&w, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 } });
    try testing.expectEqual(@as(u64, 4), try countWhere(&w, cat, &.{}, testing.allocator));
    try testing.expectEqual(@as(u64, 2), try countWhere(&w, cat, &.{.{ .prop = 1, .op = .ge, .value = 30 }}, testing.allocator));
    const agg = try aggregateInt(&w, cat, 1, &.{}, testing.allocator);
    try testing.expectEqual(@as(u64, 4), agg.count);
    try testing.expectEqual(@as(u64, 100), agg.sum);
    try testing.expectEqual(@as(?u64, 10), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
    const empty = try aggregateInt(&w, cat, 1, &.{.{ .prop = 1, .op = .gt, .value = 1000 }}, testing.allocator);
    try testing.expectEqual(@as(u64, 0), empty.count);
    try testing.expectEqual(@as(?u64, null), empty.min);
    w.deinit();
}

test "rangeInclusive and sortByPropAsc" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try seed(&w, &.{ .{ 5, 1 }, .{ 1, 1 }, .{ 9, 1 }, .{ 3, 1 }, .{ 7, 1 } });
    var rng = std.ArrayList(u64).empty;
    defer rng.deinit(testing.allocator);
    // pk in [3,7]
    try rangeInclusive(&w, cat, 0, 3, 7, &rng, testing.allocator);
    try testing.expectEqual(@as(usize, 3), rng.items.len); // pks 5,3,7
    // sort the matching okeys by pk ascending, then verify the pk order is 3,5,7
    try sortByPropAsc(&w, cat, rng.items, 0, testing.allocator);
    var out: [2]u64 = undefined;
    _ = try objects.getByObjectKey(&w, cat, rng.items[0], &out);
    try testing.expectEqual(@as(u64, 3), out[0]);
    _ = try objects.getByObjectKey(&w, cat, rng.items[1], &out);
    try testing.expectEqual(@as(u64, 5), out[0]);
    _ = try objects.getByObjectKey(&w, cat, rng.items[2], &out);
    try testing.expectEqual(@as(u64, 7), out[0]);
    w.deinit();
}

test "scan over 100k rows finds the matching slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < 100_000) : (i += 1) cat = (try objects.insert(&w, cat, &.{ i, i % 100 })).cat;
    // 1000 rows have (i % 100 == 7)
    try testing.expectEqual(@as(u64, 1000), try countWhere(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator));
    w.deinit();
}

test "query returns stable object keys after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    // pk + age. Insert a throwaway first to open up a dead slot, then the target.
    var cat = try catalog.create(&w, 2);
    const throwaway = try objects.insert(&w, cat, &.{ 1, 99 });
    cat = throwaway.cat;
    const target = try objects.insert(&w, cat, &.{ 2, 30 });
    cat = target.cat;
    const target_okey = target.row;

    // Free the throwaway's physical slot.
    const dead_row = (try catalog.okeyToRow(&w, cat, throwaway.row)).?;
    var vbuf: [2]u64 = undefined;
    const tv = (try objects.getByPk(&w, cat, 1, &vbuf)).?;
    cat = (try objects.delete(&w, cat, 1, tv)).ok;

    // Relocate the target into the freed slot; its okey is unchanged.
    cat = try relocation.relocateRow(&w, cat, target_okey, dead_row);

    // A query that matches the relocated row must return its stable okey, and
    // that okey must resolve to the right values.
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(target_okey, hits.items[0]);

    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, hits.items[0], &out)) != null);
    try testing.expectEqual(@as(u64, 2), out[0]); // pk
    try testing.expectEqual(@as(u64, 30), out[1]); // age
    w.deinit();
}

const relocation = @import("relocation.zig");

fn whereSorted(txn: anytype, cat: Ref, preds: []const Predicate, out: *std.ArrayList(u64)) !void {
    try where(txn, cat, preds, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Assert the index path (on cat_idx) yields the exact same sorted okey set as
// the full scan (on cat_scan) for the given predicates.
fn expectSameWhere(txn: anytype, cat_idx: Ref, cat_scan: Ref, preds: []const Predicate) !void {
    var a = std.ArrayList(u64).empty;
    defer a.deinit(testing.allocator);
    var b = std.ArrayList(u64).empty;
    defer b.deinit(testing.allocator);
    try whereSorted(txn, cat_idx, preds, &a);
    try whereSorted(txn, cat_scan, preds, &b);
    try testing.expectEqualSlices(u64, b.items, a.items);
}

test "indexed eq equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_eq.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 42 }});
    w.deinit();
}

test "indexed range equals full scan for each of lt le gt ge with boundary correctness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_range.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    // Combined range [40,45].
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .ge, .value = 40 },
        .{ .prop = 1, .op = .le, .value = 45 },
    });
    // Each operator individually, at and around the bound (off-by-one guards).
    for ([_]u64{ 0, 1, 42, 99 }) |b| {
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .lt, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .le, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = b }});
    }
    w.deinit();
}

test "indexed predicate plus non-indexed predicate equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_mixed.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    // prop1 (indexed) drives; prop2 (not indexed) is a remaining predicate.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .eq, .value = 42 },
        .{ .prop = 2, .op = .ge, .value = 2500 },
    });
    // Range driver plus a remaining predicate.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .ge, .value = 30 },
        .{ .prop = 2, .op = .lt, .value = 1000 },
    });
    w.deinit();
}

test "ne falls back to the scan and still equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_ne.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 2000);
    const cat_scan = try seedPlannerCat(&w, false, 2000);
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ne, .value = 42 }});
    w.deinit();
}

test "non-indexed query is unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_noidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 2000);
    const cat_scan = try seedPlannerCat(&w, false, 2000);
    // Query a non-indexed prop on both: both run the full scan.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 2, .op = .eq, .value = 1234 }});
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 0, .op = .ge, .value = 1000 }});
    w.deinit();
}

test "countWhere rangeInclusive aggregateInt match between index path and full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_aggs.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);

    // countWhere on an indexed eq predicate.
    try testing.expectEqual(
        try countWhere(&w, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator),
        try countWhere(&w, cat_idx, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator),
    );
    // countWhere on an indexed range predicate.
    try testing.expectEqual(
        try countWhere(&w, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = 90 }}, testing.allocator),
        try countWhere(&w, cat_idx, &.{.{ .prop = 1, .op = .ge, .value = 90 }}, testing.allocator),
    );

    // rangeInclusive over the indexed prop.
    var ri_idx = std.ArrayList(u64).empty;
    defer ri_idx.deinit(testing.allocator);
    var ri_scan = std.ArrayList(u64).empty;
    defer ri_scan.deinit(testing.allocator);
    try rangeInclusive(&w, cat_idx, 1, 10, 20, &ri_idx, testing.allocator);
    try rangeInclusive(&w, cat_scan, 1, 10, 20, &ri_scan, testing.allocator);
    std.mem.sort(u64, ri_idx.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, ri_scan.items, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, ri_scan.items, ri_idx.items);

    // aggregateInt over the indexed prop with an indexed driver.
    const a = try aggregateInt(&w, cat_idx, 1, &.{.{ .prop = 1, .op = .eq, .value = 50 }}, testing.allocator);
    const b = try aggregateInt(&w, cat_scan, 1, &.{.{ .prop = 1, .op = .eq, .value = 50 }}, testing.allocator);
    try testing.expectEqual(b.count, a.count);
    try testing.expectEqual(b.sum, a.sum);
    try testing.expectEqual(b.min, a.min);
    try testing.expectEqual(b.max, a.max);
    w.deinit();
}

test "empty result and all-match edge cases match full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_edges.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 1000);
    const cat_scan = try seedPlannerCat(&w, false, 1000);

    // Empty: eq on a value no row holds (values are i%100, so 100 never appears).
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 100 }});
    // Empty: range entirely above the populated values.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = 99 }});
    // Empty: lt 0 underflow guard.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .lt, .value = 0 }});
    // Empty: gt maxInt overflow guard.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = std.math.maxInt(u64) }});
    // All-match: ge 0 selects every row.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = 0 }});
    // All-match: le maxInt selects every row.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .le, .value = std.math.maxInt(u64) }});
    w.deinit();
}

test "index path equals full scan after deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_del.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat_idx = try seedPlannerCat(&w, true, 2000);
    var cat_scan = try seedPlannerCat(&w, false, 2000);
    // Delete every 7th pk from both catalogs.
    var out: [3]u64 = undefined;
    var pk: u64 = 0;
    while (pk < 2000) : (pk += 7) {
        const vi = (try objects.getByPk(&w, cat_idx, pk, &out)).?;
        cat_idx = (try objects.delete(&w, cat_idx, pk, vi)).ok;
        const vs = (try objects.getByPk(&w, cat_scan, pk, &out)).?;
        cat_scan = (try objects.delete(&w, cat_scan, pk, vs)).ok;
    }
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 42 }});
    try expectSameWhere(&w, cat_idx, cat_scan, &.{ .{ .prop = 1, .op = .ge, .value = 40 }, .{ .prop = 1, .op = .le, .value = 45 } });
    w.deinit();
}
