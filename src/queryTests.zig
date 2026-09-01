const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const index = @import("trees/index.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const Predicate = query.Predicate;
const Operator = query.Operator;
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

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff `indexed`), property2 =
// secondary. Inserts n rows with primaryKey=i, property1=i%100, property2=i.
fn seedPlannerCatalog(writeTransaction: *@import("database.zig").WriteTransaction, indexed: bool, rowCount: u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, rowIndex % 100, rowIndex })).catalogReference;
    return catalogReference;
}

// Build a type with primaryKey(int) + age(int) and insert (primaryKey, age) rows.
fn seed(writeTransaction: anytype, pairs: []const [2]u64) !Reference {
    var catalogReference = try catalog.create(writeTransaction, 2);
    for (pairs) |pair| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ pair[0], pair[1] })).catalogReference;
    return catalogReference;
}

test "where filters live rows by ANDed predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    // age == 30
    var hits1 = std.ArrayList(u64).empty;
    defer hits1.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, intComparison(1, .eq, 30), &hits1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits1.items.len);
    // age > 25 AND primaryKey < 4  -> primaryKey 2 (age30), primaryKey3 (age40) ; primaryKey4 excluded by primaryKey<4
    var hits2 = std.ArrayList(u64).empty;
    defer hits2.deinit(testing.allocator);
    const conjunction2 = [_]Predicate{ intComparison(1, .gt, 25), intComparison(0, .lt, 4) };
    try where(&writeTransaction, catalogReference, .{ .conjunction = &conjunction2 }, &hits2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits2.items.len);
    // delete primaryKey 2, re-query age==30 -> only primaryKey4
    var out: [2]u64 = undefined;
    const version2 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 2, version2)).ok;
    var hits3 = std.ArrayList(u64).empty;
    defer hits3.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, intComparison(1, .eq, 30), &hits3, testing.allocator);
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
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 20 }});
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    const bad = intComparison(2, .eq, 1);
    try testing.expectError(error.BadProperty, where(&writeTransaction, catalogReference, bad, &hits, testing.allocator));
    try testing.expectError(error.BadProperty, countWhere(&writeTransaction, catalogReference, bad, testing.allocator));
    try testing.expectError(error.BadProperty, aggregateInt(&writeTransaction, catalogReference, 9, .{ .conjunction = &.{} }, testing.allocator));
    var objectKeys = [_]u64{};
    try testing.expectError(error.BadProperty, sortByPropertyAscending(&writeTransaction, catalogReference, &objectKeys, 5, testing.allocator));
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
    var catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 }, .{ 5, 25 } });
    // Tombstone one matching row so the live filter is exercised mid-stream.
    var out: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 4, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 4, version)).ok;

    const predicate = intComparison(1, .ge, 25);
    var objectKeys = std.ArrayList(u64).empty;
    defer objectKeys.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, predicate, &objectKeys, testing.allocator);
    try testing.expectEqual(@as(usize, 3), objectKeys.items.len); // primaryKeys 2, 3, 5
    try testing.expectEqual(@as(u64, objectKeys.items.len), try countWhere(&writeTransaction, catalogReference, predicate, testing.allocator));
    const agg = try aggregateInt(&writeTransaction, catalogReference, 1, predicate, testing.allocator);
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
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 } });
    try testing.expectEqual(@as(u64, 4), try countWhere(&writeTransaction, catalogReference, .{ .conjunction = &.{} }, testing.allocator));
    try testing.expectEqual(@as(u64, 2), try countWhere(&writeTransaction, catalogReference, intComparison(1, .ge, 30), testing.allocator));
    const agg = try aggregateInt(&writeTransaction, catalogReference, 1, .{ .conjunction = &.{} }, testing.allocator);
    try testing.expectEqual(@as(u64, 4), agg.count);
    try testing.expectEqual(@as(u64, 100), agg.sum);
    try testing.expectEqual(@as(?u64, 10), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
    const empty = try aggregateInt(&writeTransaction, catalogReference, 1, intComparison(1, .gt, 1000), testing.allocator);
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
    const catalogReference = try seed(&writeTransaction, &.{ .{ 5, 1 }, .{ 1, 1 }, .{ 9, 1 }, .{ 3, 1 }, .{ 7, 1 } });
    var rng = std.ArrayList(u64).empty;
    defer rng.deinit(testing.allocator);
    // primaryKey in [3,7]
    try rangeInclusive(&writeTransaction, catalogReference, 0, 3, 7, &rng, testing.allocator);
    try testing.expectEqual(@as(usize, 3), rng.items.len); // primaryKeys 5,3,7
    // sort the matching objectKeys by primaryKey ascending, then verify the primaryKey order is 3,5,7
    try sortByPropertyAscending(&writeTransaction, catalogReference, rng.items, 0, testing.allocator);
    var out: [2]u64 = undefined;
    _ = try rows.getByObjectKey(&writeTransaction, catalogReference, rng.items[0], &out);
    try testing.expectEqual(@as(u64, 3), out[0]);
    _ = try rows.getByObjectKey(&writeTransaction, catalogReference, rng.items[1], &out);
    try testing.expectEqual(@as(u64, 5), out[0]);
    _ = try rows.getByObjectKey(&writeTransaction, catalogReference, rng.items[2], &out);
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
    var catalogReference = try catalog.create(&writeTransaction, 2);
    var row: u64 = 0;
    while (row < 100_000) : (row += 1) catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ row, row % 100 })).catalogReference;
    // 1000 rows have (i % 100 == 7)
    try testing.expectEqual(@as(u64, 1000), try countWhere(&writeTransaction, catalogReference, intComparison(1, .eq, 7), testing.allocator));
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
    var catalogReference = try catalog.create(&writeTransaction, 2);
    const throwaway = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 99 });
    catalogReference = throwaway.catalogReference;
    const target = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 30 });
    catalogReference = target.catalogReference;
    const targetObjectKey = target.objectKey;

    // Free the throwaway's physical slot.
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, throwaway.objectKey)).?;
    var vbuf: [2]u64 = undefined;
    const rowVersion1 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &vbuf)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 1, rowVersion1)).ok;

    // Relocate the target into the freed slot; its objectKey is unchanged.
    catalogReference = try relocation.relocateRow(&writeTransaction, catalogReference, targetObjectKey, deadRow);

    // A query that matches the relocated row must return its stable objectKey, and
    // that objectKey must resolve to the right values.
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, intComparison(1, .eq, 30), &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(targetObjectKey, hits.items[0]);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogReference, hits.items[0], &out)) != null);
    try testing.expectEqual(@as(u64, 2), out[0]); // primaryKey
    try testing.expectEqual(@as(u64, 30), out[1]); // age
    writeTransaction.deinit();
}

const relocation = @import("storage/relocation.zig");

fn whereSorted(transaction: anytype, catalogReference: Reference, predicate: Predicate, out: *std.ArrayList(u64)) !void {
    try where(transaction, catalogReference, predicate, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Assert the index path (on indexedCatalog) yields the exact same sorted objectKey set as
// the full scan (on scanCatalog) for the given predicate.
fn expectSameWhere(transaction: anytype, indexedCatalog: Reference, scanCatalog: Reference, predicate: Predicate) !void {
    var indexedHits = std.ArrayList(u64).empty;
    defer indexedHits.deinit(testing.allocator);
    var scanHits = std.ArrayList(u64).empty;
    defer scanHits.deinit(testing.allocator);
    try whereSorted(transaction, indexedCatalog, predicate, &indexedHits);
    try whereSorted(transaction, scanCatalog, predicate, &scanHits);
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
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .eq, 42));
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
    const combinedRange = [_]Predicate{ intComparison(1, .ge, 40), intComparison(1, .le, 45) };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &combinedRange });
    // Each operator individually, at and around the bound (off-by-one guards).
    for ([_]u64{ 0, 1, 42, 99 }) |scanHits| {
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .lt, scanHits));
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .le, scanHits));
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .gt, scanHits));
        try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .ge, scanHits));
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
    const eqPlusRemaining = [_]Predicate{ intComparison(1, .eq, 42), intComparison(2, .ge, 2500) };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &eqPlusRemaining });
    // Range driver plus a remaining predicate.
    const rangePlusRemaining = [_]Predicate{ intComparison(1, .ge, 30), intComparison(2, .lt, 1000) };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &rangePlusRemaining });
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
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .ne, 42));
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
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(2, .eq, 1234));
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(0, .ge, 1000));
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
        try countWhere(&writeTransaction, scanCatalog, intComparison(1, .eq, 7), testing.allocator),
        try countWhere(&writeTransaction, indexedCatalog, intComparison(1, .eq, 7), testing.allocator),
    );
    // countWhere on an indexed range predicate.
    try testing.expectEqual(
        try countWhere(&writeTransaction, scanCatalog, intComparison(1, .ge, 90), testing.allocator),
        try countWhere(&writeTransaction, indexedCatalog, intComparison(1, .ge, 90), testing.allocator),
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
    const indexedHits = try aggregateInt(&writeTransaction, indexedCatalog, 1, intComparison(1, .eq, 50), testing.allocator);
    const scanHits = try aggregateInt(&writeTransaction, scanCatalog, 1, intComparison(1, .eq, 50), testing.allocator);
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
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .eq, 100));
    // Empty: range entirely above the populated values.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .gt, 99));
    // Empty: lt 0 underflow guard.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .lt, 0));
    // Empty: gt maxInt overflow guard.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .gt, std.math.maxInt(u64)));
    // All-match: ge 0 selects every row.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .ge, 0));
    // All-match: le maxInt selects every row.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .le, std.math.maxInt(u64)));
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
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, intComparison(1, .eq, 42));
    const combinedRange = [_]Predicate{ intComparison(1, .ge, 40), intComparison(1, .le, 45) };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &combinedRange });
    writeTransaction.deinit();
}

// ---------------------------------------------------------------------------
// Predicate tree behaviour: and/or/not, added by the tree-shaped predicate
// language.
// ---------------------------------------------------------------------------

test "an empty conjunction matches every live row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_empty_and.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 } });
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .conjunction = &.{} }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 3), hits.items.len);
}

test "an empty disjunction matches nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_empty_or.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 } });
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .disjunction = &.{} }, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "a disjunction returns the union, and a row matching both branches is returned exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_or_union.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // property0 = primaryKey, property1 = a-branch value, property2 = b-branch value.
    var catalogReference = try catalog.create(&writeTransaction, 3);
    // primaryKey 1: only a matches (property1==1, property2==0).
    const onlyA = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 1, 0 });
    catalogReference = onlyA.catalogReference;
    // primaryKey 2: only b matches (property1==0, property2==1).
    const onlyB = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 0, 1 });
    catalogReference = onlyB.catalogReference;
    // primaryKey 3: both branches match.
    const both = try rows.insert(&writeTransaction, catalogReference, &.{ 3, 1, 1 });
    catalogReference = both.catalogReference;
    // primaryKey 4: neither branch matches.
    const neither = try rows.insert(&writeTransaction, catalogReference, &.{ 4, 0, 0 });
    catalogReference = neither.catalogReference;

    const branches = [_]Predicate{ intComparison(1, .eq, 1), intComparison(2, .eq, 1) };
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, .{ .disjunction = &branches }, &hits);
    var expected = [_]u64{ onlyA.objectKey, onlyB.objectKey, both.objectKey };
    std.mem.sort(u64, &expected, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &expected, hits.items);
}

test "results ascend by objectKey on the candidate path for a drivable disjunction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_or_sorted.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < 500) : (rowIndex += 1) catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ rowIndex, rowIndex % 10, rowIndex % 13 })).catalogReference;
    const branches = [_]Predicate{ intComparison(1, .eq, 3), intComparison(2, .eq, 5) };
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .disjunction = &branches }, &hits, testing.allocator);
    try testing.expect(hits.items.len > 0);
    try testing.expect(std.sort.isSorted(u64, hits.items, {}, std.sort.asc(u64)));
}

test "not(p) returns exactly the live rows that p did not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_not.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    const leaf = intComparison(1, .eq, 30);

    var allLive = std.ArrayList(u64).empty;
    defer allLive.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, .{ .conjunction = &.{} }, &allLive);

    var matching = std.ArrayList(u64).empty;
    defer matching.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, leaf, &matching);

    var negated = std.ArrayList(u64).empty;
    defer negated.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, .{ .negation = &leaf }, &negated);

    var expected = std.ArrayList(u64).empty;
    defer expected.deinit(testing.allocator);
    for (allLive.items) |objectKey| {
        if (std.mem.indexOfScalar(u64, matching.items, objectKey) == null) try expected.append(testing.allocator, objectKey);
    }
    try testing.expectEqualSlices(u64, expected.items, negated.items);
}

test "not(not(p)) equals p" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_double_not.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 } });
    const leaf = intComparison(1, .eq, 30);
    const innerNegation = Predicate{ .negation = &leaf };
    const doubleNegation = Predicate{ .negation = &innerNegation };

    var plain = std.ArrayList(u64).empty;
    defer plain.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, leaf, &plain);

    var doubled = std.ArrayList(u64).empty;
    defer doubled.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, doubleNegation, &doubled);

    try testing.expectEqualSlices(u64, plain.items, doubled.items);
}

test "De Morgan: not(a AND b) equals not(a) OR not(b)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_demorgan.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedPlannerCatalog(&writeTransaction, false, 500);
    const a = intComparison(1, .ge, 40);
    const b = intComparison(2, .lt, 300);

    const andChildren = [_]Predicate{ a, b };
    const andTree = Predicate{ .conjunction = &andChildren };
    const notAnd = Predicate{ .negation = &andTree };

    const notA = Predicate{ .negation = &a };
    const notB = Predicate{ .negation = &b };
    const orChildren = [_]Predicate{ notA, notB };
    const orOfNegations = Predicate{ .disjunction = &orChildren };

    var left = std.ArrayList(u64).empty;
    defer left.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, notAnd, &left);

    var right = std.ArrayList(u64).empty;
    defer right.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, orOfNegations, &right);

    try testing.expectEqualSlices(u64, right.items, left.items);
}

test "a conjunction containing a drivable disjunction is index-driven and agrees with the scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_and_or.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 2000);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, 2000);
    const orChildren = [_]Predicate{ intComparison(1, .eq, 10), intComparison(1, .eq, 20) };
    const tree = Predicate{ .conjunction = &.{ .{ .disjunction = &orChildren }, intComparison(2, .lt, 1500) } };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, tree);
}

test "out-of-range property anywhere in the tree is rejected before any emission" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_bad_property.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 } });
    const badLeaf = intComparison(5, .eq, 1);
    const negatedBad = Predicate{ .negation = &badLeaf };
    const tree = Predicate{ .conjunction = &.{ intComparison(0, .ge, 0), negatedBad } };

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try testing.expectError(error.BadProperty, where(&writeTransaction, catalogReference, tree, &hits, testing.allocator));
    try testing.expectEqual(@as(usize, 0), hits.items.len);
    try testing.expectError(error.BadProperty, countWhere(&writeTransaction, catalogReference, tree, testing.allocator));
}

test "a 33-deep tree is rejected with error.PredicateTooDeep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_too_deep.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 20 }});

    var current = intComparison(1, .eq, 20);
    var boxes: [33]Predicate = undefined;
    var level: usize = 0;
    while (level < 33) : (level += 1) {
        boxes[level] = current;
        current = .{ .negation = &boxes[level] };
    }
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try testing.expectError(error.PredicateTooDeep, where(&writeTransaction, catalogReference, current, &hits, testing.allocator));
}

test "a bytes comparison against an int property is rejected with error.BadPredicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_bad_predicate.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 20 }});
    const predicate = Predicate{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .bytes = "x" } } };
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try testing.expectError(error.BadPredicate, where(&writeTransaction, catalogReference, predicate, &hits, testing.allocator));
}

test "comparing a blob property with bytes is rejected with error.UnsupportedPredicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_unsupported.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob },
    };
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    const predicate = Predicate{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .bytes = "x" } } };
    try testing.expectError(error.UnsupportedPredicate, countWhere(&writeTransaction, catalogReference, predicate, testing.allocator));
}

test "index/scan equivalence over every predicate tree shape this phase adds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_equivalence.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int, .indexed = true },
    };
    const unindexedDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = false },
        .{ .kind = .int, .indexed = false },
    };
    var indexedCatalog = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    var scanCatalog = try catalog.createFromDefinitions(&writeTransaction, &unindexedDefinitions);
    var rowIndex: u64 = 0;
    while (rowIndex < 1000) : (rowIndex += 1) {
        indexedCatalog = (try rows.insert(&writeTransaction, indexedCatalog, &.{ rowIndex, rowIndex % 13, rowIndex % 17 })).catalogReference;
        scanCatalog = (try rows.insert(&writeTransaction, scanCatalog, &.{ rowIndex, rowIndex % 13, rowIndex % 17 })).catalogReference;
    }
    const a = intComparison(1, .eq, 3);
    const b = intComparison(2, .eq, 5);
    const c = intComparison(1, .lt, 7);

    var nonEmptySeen = false;

    // A bare comparison.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, a);
    // A two-term conjunction.
    const conjunctionAB = [_]Predicate{ a, b };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &conjunctionAB });
    // a OR b with both indexed.
    const disjunctionAB = [_]Predicate{ a, b };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .disjunction = &disjunctionAB });
    {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(&writeTransaction, indexedCatalog, .{ .disjunction = &disjunctionAB }, &hits);
        if (hits.items.len > 0) nonEmptySeen = true;
    }
    // a OR b with b unindexed: use property2 unindexed on a mixed catalog.
    {
        const mixedDefinitions = [_]catalog.PropertyDefinition{
            .{ .kind = .int },
            .{ .kind = .int, .indexed = true },
            .{ .kind = .int, .indexed = false },
        };
        var mixedIndexedCatalog = try catalog.createFromDefinitions(&writeTransaction, &mixedDefinitions);
        var mixedScanCatalog = try catalog.createFromDefinitions(&writeTransaction, &unindexedDefinitions);
        var mixedRow: u64 = 0;
        while (mixedRow < 1000) : (mixedRow += 1) {
            mixedIndexedCatalog = (try rows.insert(&writeTransaction, mixedIndexedCatalog, &.{ mixedRow, mixedRow % 13, mixedRow % 17 })).catalogReference;
            mixedScanCatalog = (try rows.insert(&writeTransaction, mixedScanCatalog, &.{ mixedRow, mixedRow % 13, mixedRow % 17 })).catalogReference;
        }
        try expectSameWhere(&writeTransaction, mixedIndexedCatalog, mixedScanCatalog, .{ .disjunction = &disjunctionAB });
    }
    // not(a).
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .negation = &a });
    {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(&writeTransaction, indexedCatalog, .{ .negation = &a }, &hits);
        if (hits.items.len > 0) nonEmptySeen = true;
    }
    // a AND (b OR c).
    const bOrC = [_]Predicate{ b, c };
    const andOfOr = Predicate{ .conjunction = &.{ a, .{ .disjunction = &bOrC } } };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, andOfOr);
    // (a OR b) AND not(c).
    const aOrB = [_]Predicate{ a, b };
    const notC = Predicate{ .negation = &c };
    const orAndNot = Predicate{ .conjunction = &.{ .{ .disjunction = &aOrB }, notC } };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, orAndNot);
    // An empty conjunction.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .conjunction = &.{} });
    {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(&writeTransaction, indexedCatalog, .{ .conjunction = &.{} }, &hits);
        if (hits.items.len > 0) nonEmptySeen = true;
    }
    // An empty disjunction.
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, .{ .disjunction = &.{} });
    // A conjunction nesting four levels deep.
    const level1 = [_]Predicate{ a, b };
    const level2 = Predicate{ .conjunction = &level1 };
    const level3 = [_]Predicate{ level2, c };
    const level4 = Predicate{ .conjunction = &level3 };
    const level5 = [_]Predicate{ level4, a };
    const deepTree = Predicate{ .conjunction = &level5 };
    try expectSameWhere(&writeTransaction, indexedCatalog, scanCatalog, deepTree);
    {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(&writeTransaction, indexedCatalog, deepTree, &hits);
        if (hits.items.len > 0) nonEmptySeen = true;
    }

    // False positive control for the equivalence harness: two empty slices agree
    // trivially, so at least one shape above must have produced a non-empty match.
    try testing.expect(nonEmptySeen);
}

test "the disjunction regression: a row matching only the unindexed branch is not dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "tree_or_regression.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // property1 indexed in catalog A, not in catalog B; property2 indexed in
    // neither. Rows are {i, i % 100, i}, so at i == 7: property1 == 7 (not 42)
    // and property2 == 7, meaning the row matches only the property2 branch.
    const catalogA = try seedPlannerCatalog(&writeTransaction, true, 100);
    const catalogB = try seedPlannerCatalog(&writeTransaction, false, 100);
    const regressionRowObjectKey = 7;

    const branches = [_]Predicate{ intComparison(1, .eq, 42), intComparison(2, .eq, 7) };
    const tree = Predicate{ .disjunction = &branches };

    var hitsA = std.ArrayList(u64).empty;
    defer hitsA.deinit(testing.allocator);
    var hitsB = std.ArrayList(u64).empty;
    defer hitsB.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogA, tree, &hitsA);
    try whereSorted(&writeTransaction, catalogB, tree, &hitsB);

    try testing.expectEqualSlices(u64, hitsB.items, hitsA.items);
    try testing.expect(std.mem.indexOfScalar(u64, hitsA.items, regressionRowObjectKey) != null);
}
