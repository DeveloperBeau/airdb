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
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff `indexed`), property2 =
// secondary. Inserts n rows with primaryKey=i, property1=i%100, property2=i.
fn seedPlannerCatalog(writeTransaction: *@import("database.zig").WriteTransaction, indexed: bool, rowCount: u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
        .{ .kind = .int },
    };
    var catalogRef = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var row: u64 = 0;
    while (row < rowCount) : (row += 1) catalogRef = (try rows.insert(writeTransaction, catalogRef, &.{ row, row % 100, row })).catalogRef;
    return catalogRef;
}

// Build a type with primaryKey(int) + age(int) and insert (primaryKey, age) rows.
fn seed(writeTransaction: anytype, pairs: []const [2]u64) !Reference {
    var catalogRef = try catalog.create(writeTransaction, 2);
    for (pairs) |pair| catalogRef = (try rows.insert(writeTransaction, catalogRef, &.{ pair[0], pair[1] })).catalogRef;
    return catalogRef;
}

test "where filters live rows by ANDed predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    // age == 30
    var hits1 = std.ArrayList(u64).empty;
    defer hits1.deinit(testing.allocator);
    try where(&writeTransaction, catalogRef, &.{.{ .property = 1, .operator = .eq, .value = 30 }}, &hits1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits1.items.len);
    // age > 25 AND primaryKey < 4  -> primaryKey 2 (age30), primaryKey3 (age40) ; primaryKey4 excluded by primaryKey<4
    var hits2 = std.ArrayList(u64).empty;
    defer hits2.deinit(testing.allocator);
    try where(&writeTransaction, catalogRef, &.{
        .{ .property = 1, .operator = .gt, .value = 25 },
        .{ .property = 0, .operator = .lt, .value = 4 },
    }, &hits2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits2.items.len);
    // delete primaryKey 2, re-query age==30 -> only primaryKey4
    var out: [2]u64 = undefined;
    const version2 = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 2, &out)).?;
    catalogRef = (try rows.delete(&writeTransaction, catalogRef, 2, version2)).ok;
    var hits3 = std.ArrayList(u64).empty;
    defer hits3.deinit(testing.allocator);
    try where(&writeTransaction, catalogRef, &.{.{ .property = 1, .operator = .eq, .value = 30 }}, &hits3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits3.items.len);
    writeTransaction.deinit();
}

test "out-of-range property indices are rejected up front" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qbadprop.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogRef = try seed(&writeTransaction, &.{.{ 1, 20 }});
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    const bad = [_]Predicate{.{ .property = 2, .operator = .eq, .value = 1 }};
    try testing.expectError(error.BadProperty, where(&writeTransaction, catalogRef, &bad, &hits, testing.allocator));
    try testing.expectError(error.BadProperty, countWhere(&writeTransaction, catalogRef, &bad, testing.allocator));
    try testing.expectError(error.BadProperty, aggregateInt(&writeTransaction, catalogRef, 9, &.{}, testing.allocator));
    var objectKeys = [_]u64{};
    try testing.expectError(error.BadProperty, sortByPropertyAscending(&writeTransaction, catalogRef, &objectKeys, 5, testing.allocator));
}

test "streamed full scan agrees with where on count and aggregate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "qstream.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogRef = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 }, .{ 5, 25 } });
    // Tombstone one matching row so the live filter is exercised mid-stream.
    var out: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 4, &out)).?;
    catalogRef = (try rows.delete(&writeTransaction, catalogRef, 4, version)).ok;

    const preds = [_]Predicate{.{ .property = 1, .operator = .ge, .value = 25 }};
    var objectKeys = std.ArrayList(u64).empty;
    defer objectKeys.deinit(testing.allocator);
    try where(&writeTransaction, catalogRef, &preds, &objectKeys, testing.allocator);
    try testing.expectEqual(@as(usize, 3), objectKeys.items.len); // primaryKeys 2, 3, 5
    try testing.expectEqual(@as(u64, objectKeys.items.len), try countWhere(&writeTransaction, catalogRef, &preds, testing.allocator));
    const agg = try aggregateInt(&writeTransaction, catalogRef, 1, &preds, testing.allocator);
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
    var writeTransaction = try database.beginWrite();
    const catalogRef = try seed(&writeTransaction, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 } });
    try testing.expectEqual(@as(u64, 4), try countWhere(&writeTransaction, catalogRef, &.{}, testing.allocator));
    try testing.expectEqual(@as(u64, 2), try countWhere(&writeTransaction, catalogRef, &.{.{ .property = 1, .operator = .ge, .value = 30 }}, testing.allocator));
    const agg = try aggregateInt(&writeTransaction, catalogRef, 1, &.{}, testing.allocator);
    try testing.expectEqual(@as(u64, 4), agg.count);
    try testing.expectEqual(@as(u64, 100), agg.sum);
    try testing.expectEqual(@as(?u64, 10), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
    const empty = try aggregateInt(&writeTransaction, catalogRef, 1, &.{.{ .property = 1, .operator = .gt, .value = 1000 }}, testing.allocator);
    try testing.expectEqual(@as(u64, 0), empty.count);
    try testing.expectEqual(@as(?u64, null), empty.min);
    writeTransaction.deinit();
}

test "rangeInclusive and sortByPropertyAscending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try seed(&writeTransaction, &.{ .{ 5, 1 }, .{ 1, 1 }, .{ 9, 1 }, .{ 3, 1 }, .{ 7, 1 } });
    var rng = std.ArrayList(u64).empty;
    defer rng.deinit(testing.allocator);
    // primaryKey in [3,7]
    try rangeInclusive(&writeTransaction, catalogRef, 0, 3, 7, &rng, testing.allocator);
    try testing.expectEqual(@as(usize, 3), rng.items.len); // primaryKeys 5,3,7
    // sort the matching objectKeys by primaryKey ascending, then verify the primaryKey order is 3,5,7
    try sortByPropertyAscending(&writeTransaction, catalogRef, rng.items, 0, testing.allocator);
    var out: [2]u64 = undefined;
    _ = try rows.getByObjectKey(&writeTransaction, catalogRef, rng.items[0], &out);
    try testing.expectEqual(@as(u64, 3), out[0]);
    _ = try rows.getByObjectKey(&writeTransaction, catalogRef, rng.items[1], &out);
    try testing.expectEqual(@as(u64, 5), out[0]);
    _ = try rows.getByObjectKey(&writeTransaction, catalogRef, rng.items[2], &out);
    try testing.expectEqual(@as(u64, 7), out[0]);
    writeTransaction.deinit();
}

test "scan over 100k rows finds the matching slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogRef = try catalog.create(&writeTransaction, 2);
    var row: u64 = 0;
    while (row < 100_000) : (row += 1) catalogRef = (try rows.insert(&writeTransaction, catalogRef, &.{ row, row % 100 })).catalogRef;
    // 1000 rows have (i % 100 == 7)
    try testing.expectEqual(@as(u64, 1000), try countWhere(&writeTransaction, catalogRef, &.{.{ .property = 1, .operator = .eq, .value = 7 }}, testing.allocator));
    writeTransaction.deinit();
}

test "query returns stable object keys after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    // primaryKey + age. Insert a throwaway first to open up a dead slot, then the target.
    var catalogRef = try catalog.create(&writeTransaction, 2);
    const throwaway = try rows.insert(&writeTransaction, catalogRef, &.{ 1, 99 });
    catalogRef = throwaway.catalogRef;
    const target = try rows.insert(&writeTransaction, catalogRef, &.{ 2, 30 });
    catalogRef = target.catalogRef;
    const targetObjectKey = target.objectKey;

    // Free the throwaway's physical slot.
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogRef, throwaway.objectKey)).?;
    var vbuf: [2]u64 = undefined;
    const rowVersion1 = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 1, &vbuf)).?;
    catalogRef = (try rows.delete(&writeTransaction, catalogRef, 1, rowVersion1)).ok;

    // Relocate the target into the freed slot; its objectKey is unchanged.
    catalogRef = try relocation.relocateRow(&writeTransaction, catalogRef, targetObjectKey, deadRow);

    // A query that matches the relocated row must return its stable objectKey, and
    // that objectKey must resolve to the right values.
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogRef, &.{.{ .property = 1, .operator = .eq, .value = 30 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(targetObjectKey, hits.items[0]);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogRef, hits.items[0], &out)) != null);
    try testing.expectEqual(@as(u64, 2), out[0]); // primaryKey
    try testing.expectEqual(@as(u64, 30), out[1]); // age
    writeTransaction.deinit();
}

const relocation = @import("storage/relocation.zig");

fn whereSorted(transaction: anytype, catalogRef: Reference, preds: []const Predicate, out: *std.ArrayList(u64)) !void {
    try where(transaction, catalogRef, preds, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Assert the index path (on indexedCatalog) yields the exact same sorted objectKey set as
// the full scan (on scanCatalog) for the given predicates.
fn expectSameWhere(transaction: anytype, indexedCatalog: Reference, scanCatalog: Reference, preds: []const Predicate) !void {
    var indexedHits = std.ArrayList(u64).empty;
    defer indexedHits.deinit(testing.allocator);
    var scanHits = std.ArrayList(u64).empty;
    defer scanHits.deinit(testing.allocator);
    try whereSorted(transaction, indexedCatalog, preds, &indexedHits);
    try whereSorted(transaction, scanCatalog, preds, &scanHits);
    try testing.expectEqualSlices(u64, scanHits.items, indexedHits.items);
}

test "indexed eq equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_eq.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 5000);
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .eq, .value = 42 }});
    writeTransaction.deinit();
}

test "indexed range equals full scan for each of lt le gt ge with boundary correctness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_range.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 5000);
    // Combined range [40,45].
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .operator = .ge, .value = 40 },
        .{ .property = 1, .operator = .le, .value = 45 },
    });
    // Each operator individually, at and around the bound (off-by-one guards).
    for ([_]u64{ 0, 1, 42, 99 }) |scanHits| {
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .lt, .value = scanHits }});
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .le, .value = scanHits }});
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .gt, .value = scanHits }});
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .ge, .value = scanHits }});
    }
    writeTransaction.deinit();
}

test "indexed predicate plus non-indexed predicate equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_mixed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 5000);
    // property1 (indexed) drives; property2 (not indexed) is a remaining predicate.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .operator = .eq, .value = 42 },
        .{ .property = 2, .operator = .ge, .value = 2500 },
    });
    // Range driver plus a remaining predicate.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{
        .{ .property = 1, .operator = .ge, .value = 30 },
        .{ .property = 2, .operator = .lt, .value = 1000 },
    });
    writeTransaction.deinit();
}

test "ne falls back to the scan and still equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_ne.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 2000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 2000);
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .ne, .value = 42 }});
    writeTransaction.deinit();
}

test "non-indexed query is unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_noidx.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 2000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 2000);
    // Query a non-indexed property on both: both run the full scan.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 2, .operator = .eq, .value = 1234 }});
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 0, .operator = .ge, .value = 1000 }});
    writeTransaction.deinit();
}

test "countWhere rangeInclusive aggregateInt match between index path and full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_aggs.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 5000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 5000);

    // countWhere on an indexed eq predicate.
    try testing.expectEqual(
        try countWhere(&writeTransaction, scanCatalog, &.{.{ .property = 1, .operator = .eq, .value = 7 }}, testing.allocator),
        try countWhere(&writeTransaction, indexedCatalog, &.{.{ .property = 1, .operator = .eq, .value = 7 }}, testing.allocator),
    );
    // countWhere on an indexed range predicate.
    try testing.expectEqual(
        try countWhere(&writeTransaction, scanCatalog, &.{.{ .property = 1, .operator = .ge, .value = 90 }}, testing.allocator),
        try countWhere(&writeTransaction, indexedCatalog, &.{.{ .property = 1, .operator = .ge, .value = 90 }}, testing.allocator),
    );

    // rangeInclusive over the indexed property.
    var riIdx = std.ArrayList(u64).empty;
    defer riIdx.deinit(testing.allocator);
    var riScan = std.ArrayList(u64).empty;
    defer riScan.deinit(testing.allocator);
    try rangeInclusive(&writeTransaction, indexedCatalog, 1, 10, 20, &riIdx, testing.allocator);
    try rangeInclusive(&writeTransaction, scanCatalog, 1, 10, 20, &riScan, testing.allocator);
    std.mem.sort(u64, riIdx.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, riScan.items, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, riScan.items, riIdx.items);

    // aggregateInt over the indexed property with an indexed driver.
    const indexedHits = try aggregateInt(&writeTransaction, indexedCatalog, 1, &.{.{ .property = 1, .operator = .eq, .value = 50 }}, testing.allocator);
    const scanHits = try aggregateInt(&writeTransaction, scanCatalog, 1, &.{.{ .property = 1, .operator = .eq, .value = 50 }}, testing.allocator);
    try testing.expectEqual(scanHits.count, indexedHits.count);
    try testing.expectEqual(scanHits.sum, indexedHits.sum);
    try testing.expectEqual(scanHits.min, indexedHits.min);
    try testing.expectEqual(scanHits.max, indexedHits.max);
    writeTransaction.deinit();
}

test "empty result and all-match edge cases match full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_edges.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 1000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 1000);

    // Empty: eq on a value no row holds (values are i%100, so 100 never appears).
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .eq, .value = 100 }});
    // Empty: range entirely above the populated values.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .gt, .value = 99 }});
    // Empty: lt 0 underflow guard.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .lt, .value = 0 }});
    // Empty: gt maxInt overflow guard.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .gt, .value = std.math.maxInt(u64) }});
    // All-match: ge 0 selects every row.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .ge, .value = 0 }});
    // All-match: le maxInt selects every row.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .le, .value = std.math.maxInt(u64) }});
    writeTransaction.deinit();
}

test "index path equals full scan after deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_del.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 2000);
    var scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 2000);
    // Delete every 7th primaryKey from both catalogs.
    var out: [3]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 2000) : (primaryKey += 7) {
        const rowVersion = (try rows.getByPrimaryKey(&writeTransaction, indexedCatalog, primaryKey, &out)).?;
        indexedCatalog = (try rows.delete(&writeTransaction, indexedCatalog, primaryKey, rowVersion)).ok;
        const scanVersion = (try rows.getByPrimaryKey(&writeTransaction, scanCatalog, primaryKey, &out)).?;
        scanCatalog = (try rows.delete(&writeTransaction, scanCatalog, primaryKey, scanVersion)).ok;
    }
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{.{ .property = 1, .operator = .eq, .value = 42 }});
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, &.{ .{ .property = 1, .operator = .ge, .value = 40 }, .{ .property = 1, .operator = .le, .value = 45 } });
    writeTransaction.deinit();
}
