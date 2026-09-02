//! Facade-level suite for `query.distinct` / `query.groupBy`: the indexed fast
//! path, the unindexed fallback, the kind allow-list, paging, relocation, and
//! a differential fuzz against a RAM oracle.
//!
//! No assertion in this file establishes correctness by comparing the indexed
//! path against the unindexed path alone. Both run through
//! `evaluation.isLiveMatch` and `Column.get` underneath, so a shared bug there
//! would leave them agreeing. Every fixture-based test asserts against a
//! hand-written expected literal computed from the fixture table by a human,
//! and the indexed-versus-unindexed comparison is an ADDITIONAL assertion on
//! top of it, never the only one. The fuzz tests assert against a RAM oracle
//! built from the generator's own arrays with `std`, which never reads the
//! database.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const index = @import("trees/index.zig");
const relocation = @import("storage/relocation.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;

const Predicate = query.Predicate;
const Operator = query.Operator;
const Page = query.Page;
const Group = query.Group;
const Grouping = query.Grouping;

fn qgTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

const emptyPredicate: Predicate = .{ .conjunction = &.{} };

// Fixture A. Four int properties: 0 = primaryKey, 1 = colorUnindexed,
// 2 = colorIndexed (indexed), 3 = price. Properties 1 and 2 carry the same
// value in every row, so one fixture serves both paths. Seven rows, written
// out by hand from the spec's table.
fn seedGroupingFixture(writeTransaction: *WriteTransaction) !struct { catalogReference: Reference, objectKeys: [7]u64 } {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    const rowsData = [_][3]u64{
        .{ 0, 10, 5 },
        .{ 1, 10, 7 },
        .{ 2, 20, 1 },
        .{ 3, 30, 4 },
        .{ 4, 10, 2 },
        .{ 5, 20, 9 },
        .{ 6, 30, 4 },
    };
    var objectKeys: [7]u64 = undefined;
    for (rowsData, 0..) |row, rowIndex| {
        const primaryKey = row[0];
        const color = row[1];
        const price = row[2];
        const inserted = try rows.insert(writeTransaction, catalogReference, &.{ primaryKey, color, color, price });
        catalogReference = inserted.catalogReference;
        objectKeys[rowIndex] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .objectKeys = objectKeys };
}

// Fixture B. Same four-property shape as fixture A. Five rows, all
// color = 42, prices 1..5.
fn seedSingleValueFixture(writeTransaction: *WriteTransaction) !struct { catalogReference: Reference, objectKeys: [5]u64 } {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var objectKeys: [5]u64 = undefined;
    var rowIndex: u64 = 0;
    while (rowIndex < 5) : (rowIndex += 1) {
        const inserted = try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, 42, 42, rowIndex + 1 });
        catalogReference = inserted.catalogReference;
        objectKeys[rowIndex] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .objectKeys = objectKeys };
}

// Fixture C. Same four-property shape. Five rows, color = row, price = 100.
fn seedAllDistinctFixture(writeTransaction: *WriteTransaction) !struct { catalogReference: Reference, objectKeys: [5]u64 } {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var objectKeys: [5]u64 = undefined;
    var rowIndex: u64 = 0;
    while (rowIndex < 5) : (rowIndex += 1) {
        const inserted = try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, rowIndex, rowIndex, 100 });
        catalogReference = inserted.catalogReference;
        objectKeys[rowIndex] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .objectKeys = objectKeys };
}

// Fixture D. Same shape, no rows.
fn seedEmptyFixture(writeTransaction: *WriteTransaction) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    return catalog.createFromDefinitions(writeTransaction, &definitions);
}

// Fixture E. primaryKey(int), a link property (indexed), price(int). No real
// target type is needed: nothing in this suite dereferences the link, so the
// raw column word (targetObjectKey + 1, links.zig:19) is written directly.
// T is a made-up target objectKey; it is never inserted anywhere.
const linkFixtureTarget: u64 = 99;

fn seedLinkFixture(writeTransaction: *WriteTransaction) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    // primaryKey 0: no link (word 0), primaryKey 1 and 2: linked to T (word T + 1).
    catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ 0, 0, 1 })).catalogReference;
    catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ 1, linkFixtureTarget + 1, 2 })).catalogReference;
    catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ 2, linkFixtureTarget + 1, 3 })).catalogReference;
    return catalogReference;
}

// Fixture F. property 0 = int (a valid group/aggregate property), properties
// 1-5 = one of each rejected kind. Used only by the rejection tests; no rows
// are needed because validation runs before any row is read.
fn seedRejectedKindFixture(writeTransaction: *WriteTransaction) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob, .indexed = true },
        .{ .kind = .list },
        .{ .kind = .set },
        .{ .kind = .linkSet },
        .{ .kind = .dict },
    };
    return catalog.createFromDefinitions(writeTransaction, &definitions);
}

// ---------------------------------------------------------------------------
// distinct
// ---------------------------------------------------------------------------

test "D1: unindexed, empty predicate, fixture A, no page: exact objectKeys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &out, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.objectKeys[0], fixture.objectKeys[2], fixture.objectKeys[3] }, out.items);
}

test "D2: indexed path returns the same sequence as the unindexed path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &unindexed, testing.allocator);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &indexed, testing.allocator);

    const expected = [_]u64{ fixture.objectKeys[0], fixture.objectKeys[2], fixture.objectKeys[3] };
    try testing.expectEqualSlices(u64, &expected, indexed.items);
    try testing.expectEqualSlices(u64, unindexed.items, indexed.items);
}

test "D3: distinct count on fixture A is 3, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqual(@as(usize, 3), unindexed.items.len);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &indexed, testing.allocator);
    try testing.expectEqual(@as(usize, 3), indexed.items.len);
}

test "D4: distinct count equals the value index's outer-key count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 3), out.items.len);

    const view = try catalog.loadCatalog(&writeTransaction, fixture.catalogReference);
    const outerKeyCount = try index.count(&writeTransaction, view.valueIndexReference(2));
    try testing.expectEqual(@as(u64, 3), outerKeyCount);
}

test "D5: predicate price >= 4 returns objectKeys[0], objectKeys[5], objectKeys[3], both paths" {
    // Hand-computed from the fixture table: rows 0 (price5), 1 (price7),
    // 3 (price4), 5 (price9) and 6 (price4) satisfy price >= 4; rows 2
    // (price1) and 4 (price2) do not. Grouped by color: value 10 -> rows
    // 0, 1 (smallest objectKey 0); value 20 -> row 5 only (row 2 is
    // excluded, so its representative is objectKeys[5]); value 30 -> rows
    // 3, 6 (smallest objectKey 3). Ascending by value: 0, 5, 3.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const predicate = intComparison(3, .ge, 4);
    const expected = [_]u64{ fixture.objectKeys[0], fixture.objectKeys[5], fixture.objectKeys[3] };

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, predicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &expected, unindexed.items);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, predicate, .{}, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &expected, indexed.items);
}

test "D6: empty relation appends nothing, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedEmptyFixture(&writeTransaction);

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, catalogReference, 1, emptyPredicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqual(@as(usize, 0), unindexed.items.len);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, catalogReference, 2, emptyPredicate, .{}, &indexed, testing.allocator);
    try testing.expectEqual(@as(usize, 0), indexed.items.len);
}

test "D7: single value fixture returns exactly the smallest of the five objectKeys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedSingleValueFixture(&writeTransaction);
    var smallest = fixture.objectKeys[0];
    for (fixture.objectKeys) |objectKey| smallest = @min(smallest, objectKey);

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{smallest}, unindexed.items);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{smallest}, indexed.items);
}

test "D8: all distinct fixture returns five objectKeys ascending by value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedAllDistinctFixture(&writeTransaction);

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &fixture.objectKeys, unindexed.items);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &fixture.objectKeys, indexed.items);
}

test "D9: page.limit = 2 on fixture A returns the first two, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const expected = [_]u64{ fixture.objectKeys[0], fixture.objectKeys[2] };

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{ .limit = 2 }, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &expected, unindexed.items);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{ .limit = 2 }, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &expected, indexed.items);
}

test "D10: offset 1 limit 1 returns exactly the middle element, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d10.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const page: Page = .{ .start = .{ .offset = 1 }, .limit = 1 };

    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, page, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[2]}, unindexed.items);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, page, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[2]}, indexed.items);
}

test "D11: a cursor page start is rejected and appends nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const page: Page = .{ .start = .{ .after = .{ .lastValue = 10, .lastObjectKey = fixture.objectKeys[0] } } };

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedPageStart, query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, page, &out, testing.allocator));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "D12: each rejected kind raises error.UnsupportedGrouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d12.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedRejectedKindFixture(&writeTransaction);

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var property: usize = 1;
    while (property <= 5) : (property += 1) {
        try testing.expectError(error.UnsupportedGrouping, query.distinct(&writeTransaction, catalogReference, property, emptyPredicate, .{}, &out, testing.allocator));
    }
}

test "D13: after relocation, distinct still returns the objectKey" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d13.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // primaryKey + color(indexed). Insert a throwaway first to open a dead
    // slot, then the target, matching src/queryTests.zig's relocation setup.
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    const throwaway = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 99 });
    catalogReference = throwaway.catalogReference;
    const target = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 30 });
    catalogReference = target.catalogReference;
    const targetObjectKey = target.objectKey;

    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, throwaway.objectKey)).?;
    var versionBuffer: [2]u64 = undefined;
    const rowVersion = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &versionBuffer)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 1, rowVersion)).ok;
    catalogReference = try relocation.relocateRow(&writeTransaction, catalogReference, targetObjectKey, deadRow);

    // The divergence this test exists to prove: objectKey no longer equals row.
    const resolvedRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, targetObjectKey)).?;
    try testing.expect(resolvedRow != targetObjectKey);

    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, catalogReference, 1, emptyPredicate, .{}, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{targetObjectKey}, indexed.items);

    var unindexedCatalog = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int } });
    unindexedCatalog = (try rows.insert(&writeTransaction, unindexedCatalog, &.{ 2, 30 })).catalogReference;
    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&writeTransaction, unindexedCatalog, 1, emptyPredicate, .{}, &unindexed, testing.allocator);
    try testing.expectEqual(@as(usize, 1), unindexed.items.len);
}

test "D14: out pre-loaded with a sentinel survives; distinct only appends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "d14.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 999);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &out, testing.allocator);
    try testing.expectEqual(@as(u64, 999), out.items[0]);
    try testing.expectEqualSlices(u64, &.{ fixture.objectKeys[0], fixture.objectKeys[2], fixture.objectKeys[3] }, out.items[1..]);
}

// ---------------------------------------------------------------------------
// groupBy
// ---------------------------------------------------------------------------

// Fixture A's whole-relation groups, aggregating price, ascending by color.
// Hand-computed: value 10 from rows 0, 1, 4 (prices 5, 7, 2); value 20 from
// rows 2, 5 (prices 1, 9); value 30 from rows 3, 6 (prices 4, 4).
const fixtureAWholeGroups = [_]Group{
    .{ .value = 10, .aggregate = .{ .count = 3, .sum = 14, .min = 2, .max = 7 } },
    .{ .value = 20, .aggregate = .{ .count = 2, .sum = 10, .min = 1, .max = 9 } },
    .{ .value = 30, .aggregate = .{ .count = 2, .sum = 8, .min = 4, .max = 4 } },
};

// Fixture A's groups under predicate price >= 4. Hand-computed from the
// fixture table: rows 0 (price5), 1 (price7), 3 (price4), 5 (price9) and 6
// (price4) satisfy the predicate; rows 2 (price1) and 4 (price2) do not.
// Grouped: value 10 from rows 0, 1 (prices 5, 7); value 20 from row 5 alone
// (price 9, row 2 excluded); value 30 from rows 3, 6 (prices 4, 4). Value 20
// still produces a group here, unlike a naive reading of the table might
// suggest, because row 5's price (9) meets the predicate.
const fixtureAFilteredGroups = [_]Group{
    .{ .value = 10, .aggregate = .{ .count = 2, .sum = 12, .min = 5, .max = 7 } },
    .{ .value = 20, .aggregate = .{ .count = 1, .sum = 9, .min = 9, .max = 9 } },
    .{ .value = 30, .aggregate = .{ .count = 2, .sum = 8, .min = 4, .max = 4 } },
};

test "G1: unindexed group property, fixture A, empty predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
    try testing.expectEqualSlices(Group, &fixtureAWholeGroups, out.items);
}

test "G2: indexed group property matches the hand-written literal and the unindexed path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var unindexed = std.ArrayList(Group).empty;
    defer unindexed.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 3 }, emptyPredicate, &unindexed, testing.allocator);

    var indexed = std.ArrayList(Group).empty;
    defer indexed.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 2, .aggregateProperty = 3 }, emptyPredicate, &indexed, testing.allocator);

    try testing.expectEqualSlices(Group, &fixtureAWholeGroups, indexed.items);
    try testing.expectEqualSlices(Group, unindexed.items, indexed.items);
}

test "G3: grouped counts sum to countWhere and to the fixture's row count, empty predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
        var summedCount: u64 = 0;
        for (out.items) |group| summedCount += group.aggregate.count;
        const totalRows = try query.countWhere(&writeTransaction, fixture.catalogReference, emptyPredicate, testing.allocator);
        try testing.expectEqual(@as(u64, 7), summedCount);
        try testing.expectEqual(totalRows, summedCount);
    }
}

test "G4: grouped counts sum to countWhere and to 5, price >= 4" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const predicate = intComparison(3, .ge, 4);

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, predicate, &out, testing.allocator);
        var summedCount: u64 = 0;
        for (out.items) |group| summedCount += group.aggregate.count;
        const matchingRows = try query.countWhere(&writeTransaction, fixture.catalogReference, predicate, testing.allocator);
        try testing.expectEqual(@as(u64, 5), summedCount);
        try testing.expectEqual(matchingRows, summedCount);
    }
}

test "G5: under price >= 4, groups are exactly the three-row table, value 20 present with one row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);
    const predicate = intComparison(3, .ge, 4);

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, predicate, &out, testing.allocator);
        try testing.expectEqualSlices(Group, &fixtureAFilteredGroups, out.items);
    }
}

test "G6: empty relation, no groups, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedEmptyFixture(&writeTransaction);

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "G7: single group fixture, exactly one group of the whole fixture" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedSingleValueFixture(&writeTransaction);
    const expected = [_]Group{.{ .value = 42, .aggregate = .{ .count = 5, .sum = 15, .min = 1, .max = 5 } }};

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
        try testing.expectEqualSlices(Group, &expected, out.items);
    }
}

test "G8: every row its own group, five groups each count 1 sum 100" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedAllDistinctFixture(&writeTransaction);
    const expected = [_]Group{
        .{ .value = 0, .aggregate = .{ .count = 1, .sum = 100, .min = 100, .max = 100 } },
        .{ .value = 1, .aggregate = .{ .count = 1, .sum = 100, .min = 100, .max = 100 } },
        .{ .value = 2, .aggregate = .{ .count = 1, .sum = 100, .min = 100, .max = 100 } },
        .{ .value = 3, .aggregate = .{ .count = 1, .sum = 100, .min = 100, .max = 100 } },
        .{ .value = 4, .aggregate = .{ .count = 1, .sum = 100, .min = 100, .max = 100 } },
    };

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
        try testing.expectEqualSlices(Group, &expected, out.items);
    }
}

test "G9: groups arrive strictly ascending by value, both paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedAllDistinctFixture(&writeTransaction);

    inline for (.{ 1, 2 }) |groupProperty| {
        var out = std.ArrayList(Group).empty;
        defer out.deinit(testing.allocator);
        try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
        try testing.expect(out.items.len > 1);
        for (out.items[0 .. out.items.len - 1], out.items[1..]) |left, right| try testing.expect(left.value < right.value);
    }
}

test "G10: link group property, groups are no-link (0) and the linked target (T + 1)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g10.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedLinkFixture(&writeTransaction);
    // links.zig:19: a link column stores targetObjectKey + 1, 0 meaning no
    // link. Fixture E's rows: primaryKey 0 has no link (word 0, price 1);
    // primaryKey 1 and 2 both link to T (word T + 1, prices 2 and 3).
    const expected = [_]Group{
        .{ .value = 0, .aggregate = .{ .count = 1, .sum = 1, .min = 1, .max = 1 } },
        .{ .value = linkFixtureTarget + 1, .aggregate = .{ .count = 2, .sum = 5, .min = 2, .max = 3 } },
    };

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = 1, .aggregateProperty = 2 }, emptyPredicate, &out, testing.allocator);
    try testing.expectEqualSlices(Group, &expected, out.items);
}

test "G11: each rejected group-property kind raises error.UnsupportedGrouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedRejectedKindFixture(&writeTransaction);

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    var groupProperty: usize = 1;
    while (groupProperty <= 5) : (groupProperty += 1) {
        try testing.expectError(error.UnsupportedGrouping, query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = groupProperty, .aggregateProperty = 0 }, emptyPredicate, &out, testing.allocator));
    }
}

test "G12: a blob AGGREGATE property raises error.UnsupportedGrouping even with a valid int group property" {
    // Without this, groupBy would inherit aggregateInt's deferred kind check
    // and silently aggregate the blob column's raw tree-root u64.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g12.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedRejectedKindFixture(&writeTransaction);

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedGrouping, query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = 0, .aggregateProperty = 1 }, emptyPredicate, &out, testing.allocator));
}

test "G13: either property out of range raises error.BadProperty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g13.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedGroupingFixture(&writeTransaction);

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.BadProperty, query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 100, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator));
    try testing.expectError(error.BadProperty, query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 100 }, emptyPredicate, &out, testing.allocator));
}

test "G14: after relocation, the aggregate is read from the row the objectKey now resolves to" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g14.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // primaryKey + group(indexed) + price. Insert a throwaway first to open a
    // dead slot, then two same-group rows with distinct prices, and relocate
    // the second into the freed slot.
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    const throwaway = try rows.insert(&writeTransaction, catalogReference, &.{ 100, 7, 999 });
    catalogReference = throwaway.catalogReference;
    const rowA = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 7, 10 });
    catalogReference = rowA.catalogReference;
    const rowB = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 7, 20 });
    catalogReference = rowB.catalogReference;

    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, throwaway.objectKey)).?;
    var versionBuffer: [3]u64 = undefined;
    const throwawayVersion = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 100, &versionBuffer)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 100, throwawayVersion)).ok;
    catalogReference = try relocation.relocateRow(&writeTransaction, catalogReference, rowB.objectKey, deadRow);

    // The divergence this test exists to prove: rowB's objectKey no longer
    // equals the physical row it resolves to.
    const resolvedRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, rowB.objectKey)).?;
    try testing.expect(resolvedRow != rowB.objectKey);

    const expected = [_]Group{.{ .value = 7, .aggregate = .{ .count = 2, .sum = 30, .min = 10, .max = 20 } }};
    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = 1, .aggregateProperty = 2 }, emptyPredicate, &out, testing.allocator);
    try testing.expectEqualSlices(Group, &expected, out.items);
}

test "G15: sum wraps, two rows of maxInt in one group" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g15.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ 0, 1, std.math.maxInt(u64) })).catalogReference;
    catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ 1, 1, std.math.maxInt(u64) })).catalogReference;

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, catalogReference, .{ .groupProperty = 1, .aggregateProperty = 2 }, emptyPredicate, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(std.math.maxInt(u64) - 1, out.items[0].aggregate.sum);
}

test "G16: out pre-loaded with a sentinel group; only the tail is sorted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "g16.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedAllDistinctFixture(&writeTransaction);
    const sentinel = Group{ .value = std.math.maxInt(u64), .aggregate = .{ .count = 1, .sum = 1, .min = 1, .max = 1 } };

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, sentinel);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 3 }, emptyPredicate, &out, testing.allocator);
    try testing.expectEqual(sentinel, out.items[0]);
    try testing.expectEqual(@as(usize, 6), out.items.len);
    for (out.items[1 .. out.items.len - 1], out.items[2..]) |left, right| try testing.expect(left.value < right.value);
}

// ---------------------------------------------------------------------------
// Fuzz and differential
//
// The oracle below reads only the `colors`/`prices`/`objectKeys` arrays the
// generator itself filled with `std.Random`; it never queries the database
// and never calls `Aggregate.accumulate` or any other engine code, so a bug
// shared between the oracle and the engine cannot make this block agree with
// itself.
// ---------------------------------------------------------------------------

const fuzzColorRange: u64 = 8; // colors 0..7 inclusive
const fuzzPriceMax: u64 = 1000;

const ColorSlot = struct {
    count: u64 = 0,
    sum: u64 = 0,
    min: ?u64 = null,
    max: ?u64 = null,
    smallestObjectKey: ?u64 = null,
};

// Fold (color, price, objectKey) triples matching `threshold` (price >=
// threshold, or every row when null) into one slot per color, by hand: plain
// arithmetic, no calls into query/aggregate.zig.
fn foldFuzzRows(colors: []const u64, prices: []const u64, objectKeys: []const u64, threshold: ?u64) [fuzzColorRange]ColorSlot {
    var slots = [_]ColorSlot{.{}} ** fuzzColorRange;
    for (colors, prices, objectKeys) |color, price, objectKey| {
        if (threshold) |minimumPrice| {
            if (price < minimumPrice) continue;
        }
        const slot = &slots[color];
        slot.count += 1;
        slot.sum +%= price;
        if (slot.min == null or price < slot.min.?) slot.min = price;
        if (slot.max == null or price > slot.max.?) slot.max = price;
        if (slot.smallestObjectKey == null or objectKey < slot.smallestObjectKey.?) slot.smallestObjectKey = objectKey;
    }
    return slots;
}

fn oracleGroups(slots: *const [fuzzColorRange]ColorSlot, allocator: std.mem.Allocator) ![]Group {
    var out = std.ArrayList(Group).empty;
    defer out.deinit(allocator);
    for (slots, 0..) |slot, color| {
        if (slot.count == 0) continue;
        try out.append(allocator, .{ .value = color, .aggregate = .{ .count = slot.count, .sum = slot.sum, .min = slot.min, .max = slot.max } });
    }
    return out.toOwnedSlice(allocator);
}

fn oracleRepresentatives(slots: *const [fuzzColorRange]ColorSlot, allocator: std.mem.Allocator) ![]u64 {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(allocator);
    for (slots) |slot| {
        if (slot.count == 0) continue;
        try out.append(allocator, slot.smallestObjectKey.?);
    }
    return out.toOwnedSlice(allocator);
}

// Generate `rowCount` (color, price) pairs with `random`, insert them into a
// fresh fixture-A-shaped catalog (color into both the indexed and unindexed
// properties), and hand back the parallel arrays the oracle folds and the
// catalog reference the engine queries.
fn seedFuzzRound(
    writeTransaction: *WriteTransaction,
    random: std.Random,
    rowCount: usize,
    allocator: std.mem.Allocator,
) !struct { catalogReference: Reference, colors: []u64, prices: []u64, objectKeys: []u64 } {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    const colors = try allocator.alloc(u64, rowCount);
    const prices = try allocator.alloc(u64, rowCount);
    const objectKeys = try allocator.alloc(u64, rowCount);
    for (0..rowCount) |rowIndex| {
        const color = random.intRangeAtMost(u64, 0, fuzzColorRange - 1);
        const price = random.intRangeAtMost(u64, 0, fuzzPriceMax);
        const inserted = try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, color, color, price });
        catalogReference = inserted.catalogReference;
        colors[rowIndex] = color;
        prices[rowIndex] = price;
        objectKeys[rowIndex] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .colors = colors, .prices = prices, .objectKeys = objectKeys };
}

// One fuzz round: generate `rowCount` rows with `seed`, then check F1-F5
// against the RAM oracle. Shared by the main fuzz test and its false-positive
// boundary checks (zero and one generated row).
fn runFuzzRound(seed: u64, rowCount: usize) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qgTmpPath(testing.allocator, &tmp, "fuzz.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const fixture = try seedFuzzRound(&writeTransaction, random, rowCount, testing.allocator);
    defer testing.allocator.free(fixture.colors);
    defer testing.allocator.free(fixture.prices);
    defer testing.allocator.free(fixture.objectKeys);

    const wholeSlots = foldFuzzRows(fixture.colors, fixture.prices, fixture.objectKeys, null);
    const wholeGroups = try oracleGroups(&wholeSlots, testing.allocator);
    defer testing.allocator.free(wholeGroups);
    const wholeRepresentatives = try oracleRepresentatives(&wholeSlots, testing.allocator);
    defer testing.allocator.free(wholeRepresentatives);

    // F1: groupBy, unindexed path, equals the RAM oracle.
    var unindexedGroups = std.ArrayList(Group).empty;
    defer unindexedGroups.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 3 }, emptyPredicate, &unindexedGroups, testing.allocator);
    try testing.expectEqualSlices(Group, wholeGroups, unindexedGroups.items);

    // F2: groupBy, indexed path, equals the same oracle.
    var indexedGroups = std.ArrayList(Group).empty;
    defer indexedGroups.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 2, .aggregateProperty = 3 }, emptyPredicate, &indexedGroups, testing.allocator);
    try testing.expectEqualSlices(Group, wholeGroups, indexedGroups.items);

    // F3: distinct, both paths, equal the oracle's representative objectKeys.
    var unindexedDistinct = std.ArrayList(u64).empty;
    defer unindexedDistinct.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, emptyPredicate, .{}, &unindexedDistinct, testing.allocator);
    try testing.expectEqualSlices(u64, wholeRepresentatives, unindexedDistinct.items);
    var indexedDistinct = std.ArrayList(u64).empty;
    defer indexedDistinct.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, emptyPredicate, .{}, &indexedDistinct, testing.allocator);
    try testing.expectEqualSlices(u64, wholeRepresentatives, indexedDistinct.items);

    // F4: sum of count over the returned groups equals the number of
    // generated rows, counted in RAM, independent of countWhere.
    var summedCount: u64 = 0;
    for (unindexedGroups.items) |group| summedCount += group.aggregate.count;
    try testing.expectEqual(@as(u64, rowCount), summedCount);

    // F5: a random predicate price >= threshold, both paths still equal the
    // RAM oracle recomputed under the same threshold in RAM.
    const threshold = random.intRangeAtMost(u64, 0, fuzzPriceMax);
    const filteredSlots = foldFuzzRows(fixture.colors, fixture.prices, fixture.objectKeys, threshold);
    const filteredGroups = try oracleGroups(&filteredSlots, testing.allocator);
    defer testing.allocator.free(filteredGroups);
    const filteredRepresentatives = try oracleRepresentatives(&filteredSlots, testing.allocator);
    defer testing.allocator.free(filteredRepresentatives);
    const thresholdPredicate = intComparison(3, .ge, threshold);

    var filteredUnindexedGroups = std.ArrayList(Group).empty;
    defer filteredUnindexedGroups.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 1, .aggregateProperty = 3 }, thresholdPredicate, &filteredUnindexedGroups, testing.allocator);
    try testing.expectEqualSlices(Group, filteredGroups, filteredUnindexedGroups.items);

    var filteredIndexedGroups = std.ArrayList(Group).empty;
    defer filteredIndexedGroups.deinit(testing.allocator);
    try query.groupBy(&writeTransaction, fixture.catalogReference, .{ .groupProperty = 2, .aggregateProperty = 3 }, thresholdPredicate, &filteredIndexedGroups, testing.allocator);
    try testing.expectEqualSlices(Group, filteredGroups, filteredIndexedGroups.items);

    var filteredUnindexedDistinct = std.ArrayList(u64).empty;
    defer filteredUnindexedDistinct.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 1, thresholdPredicate, .{}, &filteredUnindexedDistinct, testing.allocator);
    try testing.expectEqualSlices(u64, filteredRepresentatives, filteredUnindexedDistinct.items);

    var filteredIndexedDistinct = std.ArrayList(u64).empty;
    defer filteredIndexedDistinct.deinit(testing.allocator);
    try query.distinct(&writeTransaction, fixture.catalogReference, 2, thresholdPredicate, .{}, &filteredIndexedDistinct, testing.allocator);
    try testing.expectEqualSlices(u64, filteredRepresentatives, filteredIndexedDistinct.items);
}

test "F1-F5: fuzz, groupBy and distinct against a RAM oracle" {
    var seed: u64 = 0xF0079123;
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        errdefer std.debug.print("F1-F5 failed at seed {d}\n", .{seed});
        var seedPrng = std.Random.DefaultPrng.init(seed);
        const rowCount = seedPrng.random().intRangeAtMost(usize, 0, 200);
        try runFuzzRound(seed, rowCount);
        seed +%= 0x9E3779B97F4A7C15;
    }
}

test "false-positive validation: the fuzz oracle is empty on zero generated rows" {
    try runFuzzRound(0xF0079123, 0);
}

test "false-positive validation: the fuzz oracle yields exactly one group on one generated row" {
    try runFuzzRound(0xF0079123, 1);
}
