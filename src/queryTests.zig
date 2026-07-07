const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const index = @import("trees/index.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const Predicate = query.Predicate;
const where = query.where;
const countWhere = query.countWhere;
const aggregateInt = query.aggregateInt;
const rangeInclusive = query.rangeInclusive;
const sortByPropertyAscending = query.sortByPropertyAscending;

fn qTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..path_len], name });
}

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff `idx`), property2 =
// secondary. Inserts n rows with primaryKey=i, property1=i%100, property2=i.
fn seedPlannerCatalog(w: *@import("database.zig").WriteTransaction, idx: bool, n: u64) !Reference {
    const defs = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = idx },
        .{ .kind = .int },
    };
    var catalogRef = try catalog.createDefs(w, &defs);
    var i: u64 = 0;
    while (i < n) : (i += 1) catalogRef = (try rows.insert(w, catalogRef, &.{ i, i % 100, i })).catalogRef;
    return catalogRef;
}

// Build a type with primaryKey(int) + age(int) and insert (primaryKey, age) rows.
fn seed(w: anytype, pairs: []const [2]u64) !Reference {
    var catalogRef = try catalog.create(w, 2);
    for (pairs) |p| catalogRef = (try rows.insert(w, catalogRef, &.{ p[0], p[1] })).catalogRef;
    return catalogRef;
}

test "where filters live rows by ANDed predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try seed(&w, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    // age == 30
    var r1 = std.ArrayList(u64).empty;
    defer r1.deinit(testing.allocator);
    try where(&w, catalogRef, &.{.{ .property = 1, .op = .eq, .value = 30 }}, &r1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r1.items.len);
    // age > 25 AND primaryKey < 4  -> primaryKey 2 (age30), primaryKey3 (age40) ; primaryKey4 excluded by primaryKey<4
    var r2 = std.ArrayList(u64).empty;
    defer r2.deinit(testing.allocator);
    try where(&w, catalogRef, &.{
        .{ .property = 1, .op = .gt, .value = 25 },
        .{ .property = 0, .op = .lt, .value = 4 },
    }, &r2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r2.items.len);
    // delete primaryKey 2, re-query age==30 -> only primaryKey4
    var out: [2]u64 = undefined;
    const vv = (try rows.getByPrimaryKey(&w, catalogRef, 2, &out)).?;
    catalogRef = (try rows.delete(&w, catalogRef, 2, vv)).ok;
    var r3 = std.ArrayList(u64).empty;
    defer r3.deinit(testing.allocator);
    try where(&w, catalogRef, &.{.{ .property = 1, .op = .eq, .value = 30 }}, &r3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), r3.items.len);
    w.deinit();
}

test "out-of-range property indices are rejected up front" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qbadprop.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    const catalogRef = try seed(&w, &.{.{ 1, 20 }});
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    const bad = [_]Predicate{.{ .property = 2, .op = .eq, .value = 1 }};
    try testing.expectError(error.BadProperty, where(&w, catalogRef, &bad, &hits, testing.allocator));
    try testing.expectError(error.BadProperty, countWhere(&w, catalogRef, &bad, testing.allocator));
    try testing.expectError(error.BadProperty, aggregateInt(&w, catalogRef, 9, &.{}, testing.allocator));
    var objectKeys = [_]u64{};
    try testing.expectError(error.BadProperty, sortByPropertyAscending(&w, catalogRef, &objectKeys, 5, testing.allocator));
}

test "streamed full scan agrees with where on count and aggregate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qstream.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    var catalogRef = try seed(&w, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 }, .{ 5, 25 } });
    // Tombstone one matching row so the live filter is exercised mid-stream.
    var out: [2]u64 = undefined;
    const ver = (try rows.getByPrimaryKey(&w, catalogRef, 4, &out)).?;
    catalogRef = (try rows.delete(&w, catalogRef, 4, ver)).ok;

    const preds = [_]Predicate{.{ .property = 1, .op = .ge, .value = 25 }};
    var objectKeys = std.ArrayList(u64).empty;
    defer objectKeys.deinit(testing.allocator);
    try where(&w, catalogRef, &preds, &objectKeys, testing.allocator);
    try testing.expectEqual(@as(usize, 3), objectKeys.items.len); // primaryKeys 2, 3, 5
    try testing.expectEqual(@as(u64, objectKeys.items.len), try countWhere(&w, catalogRef, &preds, testing.allocator));
    const agg = try aggregateInt(&w, catalogRef, 1, &preds, testing.allocator);
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
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try seed(&w, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 } });
    try testing.expectEqual(@as(u64, 4), try countWhere(&w, catalogRef, &.{}, testing.allocator));
    try testing.expectEqual(@as(u64, 2), try countWhere(&w, catalogRef, &.{.{ .property = 1, .op = .ge, .value = 30 }}, testing.allocator));
    const agg = try aggregateInt(&w, catalogRef, 1, &.{}, testing.allocator);
    try testing.expectEqual(@as(u64, 4), agg.count);
    try testing.expectEqual(@as(u64, 100), agg.sum);
    try testing.expectEqual(@as(?u64, 10), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
    const empty = try aggregateInt(&w, catalogRef, 1, &.{.{ .property = 1, .op = .gt, .value = 1000 }}, testing.allocator);
    try testing.expectEqual(@as(u64, 0), empty.count);
    try testing.expectEqual(@as(?u64, null), empty.min);
    w.deinit();
}

test "rangeInclusive and sortByPropertyAscending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try seed(&w, &.{ .{ 5, 1 }, .{ 1, 1 }, .{ 9, 1 }, .{ 3, 1 }, .{ 7, 1 } });
    var rng = std.ArrayList(u64).empty;
    defer rng.deinit(testing.allocator);
    // primaryKey in [3,7]
    try rangeInclusive(&w, catalogRef, 0, 3, 7, &rng, testing.allocator);
    try testing.expectEqual(@as(usize, 3), rng.items.len); // primaryKeys 5,3,7
    // sort the matching objectKeys by primaryKey ascending, then verify the primaryKey order is 3,5,7
    try sortByPropertyAscending(&w, catalogRef, rng.items, 0, testing.allocator);
    var out: [2]u64 = undefined;
    _ = try rows.getByObjectKey(&w, catalogRef, rng.items[0], &out);
    try testing.expectEqual(@as(u64, 3), out[0]);
    _ = try rows.getByObjectKey(&w, catalogRef, rng.items[1], &out);
    try testing.expectEqual(@as(u64, 5), out[0]);
    _ = try rows.getByObjectKey(&w, catalogRef, rng.items[2], &out);
    try testing.expectEqual(@as(u64, 7), out[0]);
    w.deinit();
}

test "scan over 100k rows finds the matching slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var catalogRef = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < 100_000) : (i += 1) catalogRef = (try rows.insert(&w, catalogRef, &.{ i, i % 100 })).catalogRef;
    // 1000 rows have (i % 100 == 7)
    try testing.expectEqual(@as(u64, 1000), try countWhere(&w, catalogRef, &.{.{ .property = 1, .op = .eq, .value = 7 }}, testing.allocator));
    w.deinit();
}

test "query returns stable object keys after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();

    // primaryKey + age. Insert a throwaway first to open up a dead slot, then the target.
    var catalogRef = try catalog.create(&w, 2);
    const throwaway = try rows.insert(&w, catalogRef, &.{ 1, 99 });
    catalogRef = throwaway.catalogRef;
    const target = try rows.insert(&w, catalogRef, &.{ 2, 30 });
    catalogRef = target.catalogRef;
    const targetObjectKey = target.row;

    // Free the throwaway's physical slot.
    const dead_row = (try catalog.objectKeyToRow(&w, catalogRef, throwaway.row)).?;
    var vbuf: [2]u64 = undefined;
    const tv = (try rows.getByPrimaryKey(&w, catalogRef, 1, &vbuf)).?;
    catalogRef = (try rows.delete(&w, catalogRef, 1, tv)).ok;

    // Relocate the target into the freed slot; its objectKey is unchanged.
    catalogRef = try relocation.relocateRow(&w, catalogRef, targetObjectKey, dead_row);

    // A query that matches the relocated row must return its stable objectKey, and
    // that objectKey must resolve to the right values.
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&w, catalogRef, &.{.{ .property = 1, .op = .eq, .value = 30 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(targetObjectKey, hits.items[0]);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&w, catalogRef, hits.items[0], &out)) != null);
    try testing.expectEqual(@as(u64, 2), out[0]); // primaryKey
    try testing.expectEqual(@as(u64, 30), out[1]); // age
    w.deinit();
}

const relocation = @import("storage/relocation.zig");

fn whereSorted(transaction: anytype, catalogRef: Reference, preds: []const Predicate, out: *std.ArrayList(u64)) !void {
    try where(transaction, catalogRef, preds, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Assert the index path (on indexedCatalog) yields the exact same sorted objectKey set as
// the full scan (on scanCatalog) for the given predicates.
fn expectSameWhere(transaction: anytype, indexedCatalog: Reference, scanCatalog: Reference, preds: []const Predicate) !void {
    var a = std.ArrayList(u64).empty;
    defer a.deinit(testing.allocator);
    var b = std.ArrayList(u64).empty;
    defer b.deinit(testing.allocator);
    try whereSorted(transaction, indexedCatalog, preds, &a);
    try whereSorted(transaction, scanCatalog, preds, &b);
    try testing.expectEqualSlices(u64, b.items, a.items);
}

test "indexed eq equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_eq.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 5000);
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .eq, .value = 42 }});
    w.deinit();
}

test "indexed range equals full scan for each of lt le gt ge with boundary correctness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_range.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 5000);
    // Combined range [40,45].
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .op = .ge, .value = 40 },
        .{ .property = 1, .op = .le, .value = 45 },
    });
    // Each operator individually, at and around the bound (off-by-one guards).
    for ([_]u64{ 0, 1, 42, 99 }) |b| {
        try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .lt, .value = b }});
        try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .le, .value = b }});
        try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .gt, .value = b }});
        try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .ge, .value = b }});
    }
    w.deinit();
}

test "indexed predicate plus non-indexed predicate equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_mixed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 5000);
    // property1 (indexed) drives; property2 (not indexed) is a remaining predicate.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .op = .eq, .value = 42 },
        .{ .property = 2, .op = .ge, .value = 2500 },
    });
    // Range driver plus a remaining predicate.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .op = .ge, .value = 30 },
        .{ .property = 2, .op = .lt, .value = 1000 },
    });
    w.deinit();
}

test "ne falls back to the scan and still equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_ne.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 2000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 2000);
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .ne, .value = 42 }});
    w.deinit();
}

test "non-indexed query is unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_noidx.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 2000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 2000);
    // Query a non-indexed property on both: both run the full scan.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 2, .op = .eq, .value = 1234 }});
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 0, .op = .ge, .value = 1000 }});
    w.deinit();
}

test "countWhere rangeInclusive aggregateInt match between index path and full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_aggs.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 5000);

    // countWhere on an indexed eq predicate.
    try testing.expectEqual(
        try countWhere(&w, scanCatalog, &.{.{ .property = 1, .op = .eq, .value = 7 }}, testing.allocator),
        try countWhere(&w, indexedCatalog, &.{.{ .property = 1, .op = .eq, .value = 7 }}, testing.allocator),
    );
    // countWhere on an indexed range predicate.
    try testing.expectEqual(
        try countWhere(&w, scanCatalog, &.{.{ .property = 1, .op = .ge, .value = 90 }}, testing.allocator),
        try countWhere(&w, indexedCatalog, &.{.{ .property = 1, .op = .ge, .value = 90 }}, testing.allocator),
    );

    // rangeInclusive over the indexed property.
    var ri_idx = std.ArrayList(u64).empty;
    defer ri_idx.deinit(testing.allocator);
    var ri_scan = std.ArrayList(u64).empty;
    defer ri_scan.deinit(testing.allocator);
    try rangeInclusive(&w, indexedCatalog, 1, 10, 20, &ri_idx, testing.allocator);
    try rangeInclusive(&w, scanCatalog, 1, 10, 20, &ri_scan, testing.allocator);
    std.mem.sort(u64, ri_idx.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, ri_scan.items, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, ri_scan.items, ri_idx.items);

    // aggregateInt over the indexed property with an indexed driver.
    const a = try aggregateInt(&w, indexedCatalog, 1, &.{.{ .property = 1, .op = .eq, .value = 50 }}, testing.allocator);
    const b = try aggregateInt(&w, scanCatalog, 1, &.{.{ .property = 1, .op = .eq, .value = 50 }}, testing.allocator);
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
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&w, true, 1000);
    const scanCatalog = try seedPlannerCatalog(&w, false, 1000);

    // Empty: eq on a value no row holds (values are i%100, so 100 never appears).
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .eq, .value = 100 }});
    // Empty: range entirely above the populated values.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .gt, .value = 99 }});
    // Empty: lt 0 underflow guard.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .lt, .value = 0 }});
    // Empty: gt maxInt overflow guard.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .gt, .value = std.math.maxInt(u64) }});
    // All-match: ge 0 selects every row.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .ge, .value = 0 }});
    // All-match: le maxInt selects every row.
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .le, .value = std.math.maxInt(u64) }});
    w.deinit();
}

test "index path equals full scan after deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_del.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    var indexedCatalog = try seedPlannerCatalog(&w, true, 2000);
    var scanCatalog = try seedPlannerCatalog(&w, false, 2000);
    // Delete every 7th primaryKey from both catalogs.
    var out: [3]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 2000) : (primaryKey += 7) {
        const rowVersion = (try rows.getByPrimaryKey(&w, indexedCatalog, primaryKey, &out)).?;
        indexedCatalog = (try rows.delete(&w, indexedCatalog, primaryKey, rowVersion)).ok;
        const vs = (try rows.getByPrimaryKey(&w, scanCatalog, primaryKey, &out)).?;
        scanCatalog = (try rows.delete(&w, scanCatalog, primaryKey, vs)).ok;
    }
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{.{ .property = 1, .op = .eq, .value = 42 }});
    try expectSameWhere(&w, indexedCatalog, scanCatalog, &.{ .{ .property = 1, .op = .ge, .value = 40 }, .{ .property = 1, .op = .le, .value = 45 } });
    w.deinit();
}
