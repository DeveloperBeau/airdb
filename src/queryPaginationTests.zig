//! Behaviour suite for pages, ordering and cursors: `where` with a `Request`,
//! `first`, `exists`, `cursorAfter`, and `sortByProperty`. A second suite
//! beside queryTests.zig, following the precedent phase 1 set with
//! queryDifferentialTests.zig, so this file stays about pagination and
//! ordering rather than growing queryTests.zig further.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;
const Predicate = query.Predicate;
const Operator = query.Operator;
const Request = query.Request;
const SortOrder = query.SortOrder;
const Ordering = query.Ordering;
const where = query.where;
const first = query.first;
const exists = query.exists;
const cursorAfter = query.cursorAfter;
const sortByProperty = query.sortByProperty;

fn qpTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// Build a type with primaryKey(int) + age(int) and insert (primaryKey, age) rows.
fn seed(writeTransaction: anytype, pairs: []const [2]u64) !Reference {
    var catalogReference = try catalog.create(writeTransaction, 2);
    for (pairs) |pair| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ pair[0], pair[1] })).catalogReference;
    return catalogReference;
}

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff
// `indexed`), property2 = secondary (never indexed). Inserts rowCount rows with
// primaryKey=i, property1=i%100, property2=i. objectKeys land at 0..rowCount-1 in
// insertion order for a freshly created catalog (nextKey starts at 0).
fn seedThreeProperty(writeTransaction: *WriteTransaction, indexed: bool, rowCount: u64) !Reference {
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

// Delete the row whose primaryKey is `primaryKey` from `catalogReference`.
fn deletePrimaryKey(writeTransaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64) !Reference {
    var out: [3]u64 = undefined;
    const version = (try rows.getByPrimaryKey(writeTransaction, catalogReference, primaryKey, &out)).?;
    return (try rows.delete(writeTransaction, catalogReference, primaryKey, version)).ok;
}

fn expectSlice(expected: []const u64, out: *std.ArrayList(u64)) !void {
    try testing.expectEqualSlices(u64, expected, out.items);
}

test "P1: an unpaged request returns exactly what an unpaged phase 1 query returned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    var hits1 = std.ArrayList(u64).empty;
    defer hits1.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = intComparison(1, .eq, 30) }, &hits1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits1.items.len);

    const conjunction2 = [_]Predicate{ intComparison(1, .gt, 25), intComparison(0, .lt, 4) };
    var hits2 = std.ArrayList(u64).empty;
    defer hits2.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = .{ .conjunction = &conjunction2 } }, &hits2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits2.items.len);

    var out: [2]u64 = undefined;
    const version2 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 2, version2)).ok;
    var hits3 = std.ArrayList(u64).empty;
    defer hits3.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = intComparison(1, .eq, 30) }, &hits3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits3.items.len);
    writeTransaction.deinit();
}

// ---------------------------------------------------------------------------
// Regression and basics
// ---------------------------------------------------------------------------

test "P2: limit bounds the page and offset skips, objectKey ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 20);

    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .start = .{ .offset = 5 }, .limit = 3 } }, &page, testing.allocator);
    try expectSlice(&.{ 5, 6, 7 }, &page);

    // False positive/negative guards: the unpaged result must be longer, and the
    // first key must not be the unskipped first match.
    var unpaged = std.ArrayList(u64).empty;
    defer unpaged.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{}, &unpaged, testing.allocator);
    try testing.expect(unpaged.items.len != page.items.len);
    try testing.expect(page.items[0] != unpaged.items[0]);
}

fn assertPagesReconstructUnpaged(writeTransaction: *WriteTransaction, catalogReference: Reference, ordering: Ordering, pageSize: u64) !void {
    var unpaged = std.ArrayList(u64).empty;
    defer unpaged.deinit(testing.allocator);
    try where(writeTransaction, catalogReference, .{ .ordering = ordering }, &unpaged, testing.allocator);

    var reconstructed = std.ArrayList(u64).empty;
    defer reconstructed.deinit(testing.allocator);
    var offset: u64 = 0;
    while (true) {
        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        try where(writeTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = .{ .offset = offset }, .limit = pageSize } }, &page, testing.allocator);
        if (page.items.len == 0) break;
        try reconstructed.appendSlice(testing.allocator, page.items);
        offset += pageSize;
    }
    try testing.expectEqualSlices(u64, unpaged.items, reconstructed.items);
}

test "P3: concatenated pages equal the unpaged result, objectKey ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{}, 7);
}

test "P4: concatenated pages equal the unpaged result, objectKey descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{ .order = .descending }, 7);
}

test "P5: concatenated pages equal the unpaged result, indexed property ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 } }, 7);
}

test "P6: concatenated pages equal the unpaged result, indexed property descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 }, .order = .descending }, 7);
}

test "P7: concatenated pages equal the unpaged result, unindexed property ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 } }, 7);
}

test "P8: concatenated pages equal the unpaged result, unindexed property descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 50);
    try assertPagesReconstructUnpaged(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 }, .order = .descending }, 7);
}

test "P9: descending objectKey order is the exact reverse of ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 30);

    var ascending = std.ArrayList(u64).empty;
    defer ascending.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{}, &ascending, testing.allocator);
    var descending = std.ArrayList(u64).empty;
    defer descending.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .order = .descending } }, &descending, testing.allocator);

    var reversedAscending = try testing.allocator.alloc(u64, ascending.items.len);
    defer testing.allocator.free(reversedAscending);
    for (ascending.items, 0..) |key, position| reversedAscending[ascending.items.len - 1 - position] = key;
    try testing.expectEqualSlices(u64, reversedAscending, descending.items);
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

const p10Values = [_]u64{ 5, 2, 5, 3, 2, 4, 1, 5, 0, 3, 4, 1 };
const p10ExpectedAscending = [_]u64{ 8, 6, 11, 1, 4, 3, 9, 5, 10, 0, 2, 7 };
const p10ExpectedDescending = [_]u64{ 7, 2, 0, 10, 5, 9, 3, 4, 1, 11, 6, 8 };

fn seedWithValues(writeTransaction: *WriteTransaction, indexed: bool, values: []const u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    for (values, 0..) |value, position| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ position, value, position })).catalogReference;
    return catalogReference;
}

test "P10: the indexed and the unindexed property paths deliver the same hand-written sequence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p10.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedWithValues(&writeTransaction, true, &p10Values);
    const unindexedCatalog = try seedWithValues(&writeTransaction, false, &p10Values);

    var indexedAscending = std.ArrayList(u64).empty;
    defer indexedAscending.deinit(testing.allocator);
    try where(&writeTransaction, indexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &indexedAscending, testing.allocator);
    try expectSlice(&p10ExpectedAscending, &indexedAscending);

    var unindexedAscending = std.ArrayList(u64).empty;
    defer unindexedAscending.deinit(testing.allocator);
    try where(&writeTransaction, unindexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &unindexedAscending, testing.allocator);
    try expectSlice(&p10ExpectedAscending, &unindexedAscending);

    var indexedDescending = std.ArrayList(u64).empty;
    defer indexedDescending.deinit(testing.allocator);
    try where(&writeTransaction, indexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending } }, &indexedDescending, testing.allocator);
    try expectSlice(&p10ExpectedDescending, &indexedDescending);

    var unindexedDescending = std.ArrayList(u64).empty;
    defer unindexedDescending.deinit(testing.allocator);
    try where(&writeTransaction, unindexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending } }, &unindexedDescending, testing.allocator);
    try expectSlice(&p10ExpectedDescending, &unindexedDescending);
}

test "P11: ties break by ascending objectKey when ascending and by descending objectKey when descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const tiedValues = [_]u64{ 7, 7, 7, 7 };
    const indexedCatalog = try seedWithValues(&writeTransaction, true, &tiedValues);
    const unindexedCatalog = try seedWithValues(&writeTransaction, false, &tiedValues);

    var indexedAscending = std.ArrayList(u64).empty;
    defer indexedAscending.deinit(testing.allocator);
    try where(&writeTransaction, indexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &indexedAscending, testing.allocator);
    try expectSlice(&.{ 0, 1, 2, 3 }, &indexedAscending);

    var indexedDescending = std.ArrayList(u64).empty;
    defer indexedDescending.deinit(testing.allocator);
    try where(&writeTransaction, indexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending } }, &indexedDescending, testing.allocator);
    try expectSlice(&.{ 3, 2, 1, 0 }, &indexedDescending);

    var unindexedAscending = std.ArrayList(u64).empty;
    defer unindexedAscending.deinit(testing.allocator);
    try where(&writeTransaction, unindexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &unindexedAscending, testing.allocator);
    try expectSlice(&.{ 0, 1, 2, 3 }, &unindexedAscending);

    var unindexedDescending = std.ArrayList(u64).empty;
    defer unindexedDescending.deinit(testing.allocator);
    try where(&writeTransaction, unindexedCatalog, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending } }, &unindexedDescending, testing.allocator);
    try expectSlice(&.{ 3, 2, 1, 0 }, &unindexedDescending);
}

test "P15: an index-driven predicate honours offset and limit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p15.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // 250 rows: property1 == 7 matches objectKeys 7, 107, 207.
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 250);
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{
        .predicate = intComparison(1, .eq, 7),
        .page = .{ .start = .{ .offset = 1 }, .limit = 1 },
    }, &page, testing.allocator);
    try expectSlice(&.{107}, &page);
}

test "P16: an index-driven predicate honours descending objectKey order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p16.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 250);
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{
        .predicate = intComparison(1, .eq, 7),
        .ordering = .{ .order = .descending },
    }, &page, testing.allocator);
    try expectSlice(&.{ 207, 107, 7 }, &page);
}

test "P12: an offset past the end returns an empty page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p12.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 10);
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .start = .{ .offset = 100 } } }, &page, testing.allocator);
    try testing.expectEqual(@as(usize, 0), page.items.len);
}

test "P13: limit zero returns an empty page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p13.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 10);
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .limit = 0 } }, &page, testing.allocator);
    try testing.expectEqual(@as(usize, 0), page.items.len);
}

test "P14: a page appended to a non-empty list leaves the existing items untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p14.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 10);

    // Streaming path (deliverByObjectKey).
    var streamed = std.ArrayList(u64).empty;
    defer streamed.deinit(testing.allocator);
    try streamed.append(testing.allocator, 999);
    try streamed.append(testing.allocator, 888);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .limit = 3 } }, &streamed, testing.allocator);
    try expectSlice(&.{ 999, 888, 0, 1, 2 }, &streamed);

    // Materialized path (deliverBySortedMaterialization: unindexed property order).
    var materialized = std.ArrayList(u64).empty;
    defer materialized.deinit(testing.allocator);
    try materialized.append(testing.allocator, 999);
    try materialized.append(testing.allocator, 888);
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } }, .page = .{ .limit = 3 } }, &materialized, testing.allocator);
    try expectSlice(&.{ 999, 888, 0, 1, 2 }, &materialized);
}

test "P38: deleted rows never appear in any page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p38.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var indexedCatalog = try seedThreeProperty(&writeTransaction, true, 20);
    var unindexedCatalog = try seedThreeProperty(&writeTransaction, false, 20);
    for ([_]u64{ 3, 7, 12 }) |primaryKey| {
        indexedCatalog = try deletePrimaryKey(&writeTransaction, indexedCatalog, primaryKey);
        unindexedCatalog = try deletePrimaryKey(&writeTransaction, unindexedCatalog, primaryKey);
    }

    const configurations = [_]Ordering{
        .{},
        .{ .order = .descending },
        .{ .sortKey = .{ .property = 1 } },
        .{ .sortKey = .{ .property = 1 }, .order = .descending },
    };
    for (configurations) |ordering| {
        var indexedPage = std.ArrayList(u64).empty;
        defer indexedPage.deinit(testing.allocator);
        try where(&writeTransaction, indexedCatalog, .{ .ordering = ordering }, &indexedPage, testing.allocator);
        try testing.expectEqual(@as(usize, 17), indexedPage.items.len);
        for ([_]u64{ 3, 7, 12 }) |deletedKey| try testing.expect(std.mem.indexOfScalar(u64, indexedPage.items, deletedKey) == null);

        var unindexedPage = std.ArrayList(u64).empty;
        defer unindexedPage.deinit(testing.allocator);
        try where(&writeTransaction, unindexedCatalog, .{ .ordering = ordering }, &unindexedPage, testing.allocator);
        try testing.expectEqual(@as(usize, 17), unindexedPage.items.len);
        for ([_]u64{ 3, 7, 12 }) |deletedKey| try testing.expect(std.mem.indexOfScalar(u64, unindexedPage.items, deletedKey) == null);
    }
}

test "P39: every ordering returns an empty page over a type with no rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p39.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedThreeProperty(&writeTransaction, true, 0);
    const unindexedCatalog = try seedThreeProperty(&writeTransaction, false, 0);

    const configurations = [_]Ordering{
        .{},
        .{ .order = .descending },
        .{ .sortKey = .{ .property = 1 } },
        .{ .sortKey = .{ .property = 1 }, .order = .descending },
    };
    for (configurations) |ordering| {
        var indexedPage = std.ArrayList(u64).empty;
        defer indexedPage.deinit(testing.allocator);
        try where(&writeTransaction, indexedCatalog, .{ .ordering = ordering }, &indexedPage, testing.allocator);
        try testing.expectEqual(@as(usize, 0), indexedPage.items.len);

        var unindexedPage = std.ArrayList(u64).empty;
        defer unindexedPage.deinit(testing.allocator);
        try where(&writeTransaction, unindexedCatalog, .{ .ordering = ordering }, &unindexedPage, testing.allocator);
        try testing.expectEqual(@as(usize, 0), unindexedPage.items.len);
    }
}

// ---------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------

test "P17: first returns the same objectKey as a limit-one page, and null when nothing matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p17.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);

    const firstMatch = try first(&writeTransaction, catalogReference, .{}, testing.allocator);
    try testing.expectEqual(@as(?u64, 0), firstMatch);

    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .limit = 1 } }, &page, testing.allocator);
    try testing.expectEqual(firstMatch.?, page.items[0]);

    const noMatch = try first(&writeTransaction, catalogReference, .{ .predicate = intComparison(0, .eq, 999) }, testing.allocator);
    try testing.expectEqual(@as(?u64, null), noMatch);
}

test "P18: exists is true for a matching predicate and false for one that matches nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p18.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);

    try testing.expect(try exists(&writeTransaction, catalogReference, .{}, testing.allocator));
    try testing.expect(!try exists(&writeTransaction, catalogReference, .{ .predicate = intComparison(0, .eq, 999) }, testing.allocator));
}

test "P19: first honours the ordering, smallest by property ascending and largest descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p19.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedWithValues(&writeTransaction, true, &p10Values);

    const smallestAscending = try first(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, testing.allocator);
    try testing.expectEqual(@as(?u64, p10ExpectedAscending[0]), smallestAscending);

    const largestDescending = try first(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending } }, testing.allocator);
    try testing.expectEqual(@as(?u64, p10ExpectedDescending[0]), largestDescending);
}

// ---------------------------------------------------------------------------
// Cursors
// ---------------------------------------------------------------------------

test "P20: cursorAfter under objectKey ordering returns the objectKey in both fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p20.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);
    const cursor = try cursorAfter(&writeTransaction, catalogReference, .{}, 2);
    try testing.expectEqual(@as(u64, 2), cursor.lastValue);
    try testing.expectEqual(@as(u64, 2), cursor.lastObjectKey);
}

test "P21: cursorAfter under property ordering returns that row's property value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p21.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 5);
    // objectKey 3 has property1 == 3 % 100 == 3.
    const cursor = try cursorAfter(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 } }, 3);
    try testing.expectEqual(@as(u64, 3), cursor.lastValue);
    try testing.expectEqual(@as(u64, 3), cursor.lastObjectKey);
}

test "P22: cursorAfter on an objectKey that does not resolve is error.NotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p22.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 5);
    try testing.expectError(error.NotFound, cursorAfter(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 } }, 999));
}

fn assertCursorPagesEqualOffsetPages(writeTransaction: *WriteTransaction, catalogReference: Reference, ordering: Ordering, pageSize: u64) !void {
    var unpaged = std.ArrayList(u64).empty;
    defer unpaged.deinit(testing.allocator);
    try where(writeTransaction, catalogReference, .{ .ordering = ordering }, &unpaged, testing.allocator);

    var offsetResult = std.ArrayList(u64).empty;
    defer offsetResult.deinit(testing.allocator);
    var offset: u64 = 0;
    while (true) {
        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        try where(writeTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = .{ .offset = offset }, .limit = pageSize } }, &page, testing.allocator);
        if (page.items.len == 0) break;
        try offsetResult.appendSlice(testing.allocator, page.items);
        offset += pageSize;
    }

    var cursorResult = std.ArrayList(u64).empty;
    defer cursorResult.deinit(testing.allocator);
    var cursor: ?query.Cursor = null;
    while (true) {
        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        const start: query.PageStart = if (cursor) |resumeCursor| .{ .after = resumeCursor } else .{ .offset = 0 };
        try where(writeTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = start, .limit = pageSize } }, &page, testing.allocator);
        if (page.items.len == 0) break;
        try cursorResult.appendSlice(testing.allocator, page.items);
        const nextCursor = try cursorAfter(writeTransaction, catalogReference, ordering, page.items[page.items.len - 1]);
        // Fail fast rather than hang: a cursor that fails to advance past its
        // predecessor would otherwise re-fetch the same trailing row forever.
        if (cursor) |previousCursor| try testing.expect(!std.meta.eql(previousCursor, nextCursor));
        cursor = nextCursor;
    }

    try testing.expectEqualSlices(u64, unpaged.items, offsetResult.items);
    try testing.expectEqualSlices(u64, offsetResult.items, cursorResult.items);
}

test "P23: cursor pages equal offset pages, objectKey ordering, both directions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p23.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 37);
    try assertCursorPagesEqualOffsetPages(&writeTransaction, catalogReference, .{}, 5);
    try assertCursorPagesEqualOffsetPages(&writeTransaction, catalogReference, .{ .order = .descending }, 5);
}

test "P24: cursor pages equal offset pages, indexed property ordering, both directions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p24.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // Uses the already-decorrelated p10Values dataset (value order deliberately
    // disagrees with objectKey order, e.g. ascending visits objectKey 8 before 6)
    // rather than seedThreeProperty's identity mapping (property1 == objectKey),
    // so a resume bound wrongly applied outside the resumed value bucket would
    // not be a no-op against this data.
    const catalogReference = try seedWithValues(&writeTransaction, true, &p10Values);
    try assertCursorPagesEqualOffsetPages(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 } }, 5);
    try assertCursorPagesEqualOffsetPages(&writeTransaction, catalogReference, .{ .sortKey = .{ .property = 1 }, .order = .descending }, 5);
}

test "P25: a cursor inside a run of duplicate sort values resumes within the run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p25.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    // Row with value 8 inserted FIRST (objectKey 0), then 5 rows sharing value 7
    // (objectKeys 1..5): the run's objectKeys deliberately sort below the
    // value-8 row's objectKey, disagreeing with sort-property order, so a
    // resume bound wrongly applied to the later value-8 bucket (instead of
    // only the resumed value-7 bucket) would exclude it.
    const values = [_]u64{ 8, 7, 7, 7, 7, 7 };
    const catalogReference = try seedWithValues(&writeTransaction, true, &values);
    const ordering = Ordering{ .sortKey = .{ .property = 1 } };
    // Ascending order: the run 1,2,3,4,5 (value 7), then 0 (value 8).
    // Cursor placed at the third row of the run (objectKey 3).
    const cursor = try cursorAfter(&writeTransaction, catalogReference, ordering, 3);
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = .{ .after = cursor } } }, &page, testing.allocator);
    try expectSlice(&.{ 4, 5, 0 }, &page);

    // Must NOT fire for a cursor at the end of a run: the next value's bucket
    // follows in full, including its lower objectKey.
    const endOfRunCursor = try cursorAfter(&writeTransaction, catalogReference, ordering, 5);
    var afterEndOfRun = std.ArrayList(u64).empty;
    defer afterEndOfRun.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = .{ .after = endOfRunCursor } } }, &afterEndOfRun, testing.allocator);
    try expectSlice(&.{0}, &afterEndOfRun);
}

test "P26: an ascending cursor at maxInt returns an empty page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p26.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);
    const cursor = query.Cursor{ .lastValue = std.math.maxInt(u64), .lastObjectKey = std.math.maxInt(u64) };
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .page = .{ .start = .{ .after = cursor } } }, &page, testing.allocator);
    try testing.expectEqual(@as(usize, 0), page.items.len);
}

test "P27: a descending cursor at objectKey zero returns an empty page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p27.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);
    const cursor = query.Cursor{ .lastValue = 0, .lastObjectKey = 0 };
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .order = .descending }, .page = .{ .start = .{ .after = cursor } } }, &page, testing.allocator);
    try testing.expectEqual(@as(usize, 0), page.items.len);
}

test "P28: a cursor with an unindexed sort property is error.CursorRequiresIndexedSort and appends nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p28.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);
    const cursor = query.Cursor{ .lastValue = 1, .lastObjectKey = 1 };
    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try testing.expectError(error.CursorRequiresIndexedSort, where(&writeTransaction, catalogReference, .{
        .ordering = .{ .sortKey = .{ .property = 1 } },
        .page = .{ .start = .{ .after = cursor } },
    }, &page, testing.allocator));
    try testing.expectEqual(@as(usize, 0), page.items.len);
}

fn createSeededDirectory(writeTransaction: *WriteTransaction, rowCount: u64) !Reference {
    var directoryReference = try typeDirectory.createTypes(writeTransaction, &.{
        &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true }, .{ .kind = .int } },
    }, &.{false});
    var primaryKey: u64 = 0;
    while (primaryKey < rowCount) : (primaryKey += 1) {
        directoryReference = (try typeRouting.insert(writeTransaction, directoryReference, 0, &.{
            .{ .int = primaryKey }, .{ .int = primaryKey % 10 }, .{ .int = primaryKey },
        })).directoryReference;
    }
    return directoryReference;
}

fn appendRowsToDirectory(writeTransaction: *WriteTransaction, directoryReference: Reference, startPrimaryKey: u64, rowCount: u64) !Reference {
    var result = directoryReference;
    var primaryKey = startPrimaryKey;
    const end = startPrimaryKey + rowCount;
    while (primaryKey < end) : (primaryKey += 1) {
        result = (try typeRouting.insert(writeTransaction, result, 0, &.{
            .{ .int = primaryKey }, .{ .int = primaryKey % 10 }, .{ .int = primaryKey },
        })).directoryReference;
    }
    return result;
}

// Scroll `catalogReferenceOf` (looked up fresh from each new read transaction's
// root) to exhaustion under `ordering`, calling `betweenFetches` once after the
// first page is fetched (to let the caller commit concurrent writes), and
// returning the concatenation of every page fetched.
fn scrollToExhaustion(
    database: *Database,
    ordering: Ordering,
    pageSize: u64,
    betweenFetches: *const fn (*Database) anyerror!void,
) !std.ArrayList(u64) {
    var allFetched = std.ArrayList(u64).empty;
    var cursor: ?query.Cursor = null;
    var isFirstFetch = true;
    while (true) {
        var readTransaction = try database.beginRead();
        const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        const start: query.PageStart = if (cursor) |resumeCursor| .{ .after = resumeCursor } else .{ .offset = 0 };
        try where(&readTransaction, catalogReference, .{ .ordering = ordering, .page = .{ .start = start, .limit = pageSize } }, &page, testing.allocator);
        if (page.items.len > 0) {
            try allFetched.appendSlice(testing.allocator, page.items);
            const nextCursor = try cursorAfter(&readTransaction, catalogReference, ordering, page.items[page.items.len - 1]);
            // Fail fast rather than hang: see assertCursorPagesEqualOffsetPages.
            if (cursor) |previousCursor| try testing.expect(!std.meta.eql(previousCursor, nextCursor));
            cursor = nextCursor;
        }
        readTransaction.end();
        if (page.items.len == 0) break;
        if (isFirstFetch) {
            isFirstFetch = false;
            try betweenFetches(database);
        }
    }
    return allFetched;
}

var p29ExtraRowsCommitted = false;

fn commitTwentyMoreRows(database: *Database) !void {
    var writeTransaction = try database.beginWrite();
    const directoryReference = try appendRowsToDirectory(&writeTransaction, writeTransaction.newRoot, 30, 20);
    writeTransaction.setRoot(directoryReference);
    _ = try writeTransaction.commit();
    p29ExtraRowsCommitted = true;
}

fn noOpBetweenFetches(_: *Database) !void {}

fn checkCursorStabilityUnderCommits(allocator: std.mem.Allocator, path: []const u8, ordering: Ordering) !void {
    var database = try Database.create(allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const directoryReference = try createSeededDirectory(&writeTransaction, 30);
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }

    p29ExtraRowsCommitted = false;
    var fetched = try scrollToExhaustion(&database, ordering, 10, commitTwentyMoreRows);
    defer fetched.deinit(allocator);
    try testing.expect(p29ExtraRowsCommitted);

    // Every one of the 30 pre-existing objectKeys (0..29, never deleted) must
    // appear exactly once across every page fetched.
    try testing.expect(fetched.items.len > 0); // false-positive guard: nothing empty passes trivially
    var seenCounts = [_]u8{0} ** 30;
    for (fetched.items) |objectKey| {
        if (objectKey < 30) seenCounts[objectKey] += 1;
    }
    for (seenCounts) |seenCount| try testing.expectEqual(@as(u8, 1), seenCount);
}

test "P29: cursor stability under commits between page fetches, objectKey ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p29a.airdb");
    defer testing.allocator.free(path);
    try checkCursorStabilityUnderCommits(testing.allocator, path, .{});
}

test "P29: cursor stability under commits between page fetches, indexed property ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p29b.airdb");
    defer testing.allocator.free(path);
    try checkCursorStabilityUnderCommits(testing.allocator, path, .{ .sortKey = .{ .property = 1 } });
}

test "P30: a pinned snapshot gives a fully consistent multi-page scroll" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p30.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const directoryReference = try createSeededDirectory(&writeTransaction, 25);
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    const pinnedVersion = database.horizon();

    var pinnedReader = try database.beginReadAt(pinnedVersion);
    const pinnedCatalog = try typeDirectory.catalogReference(&pinnedReader, pinnedReader.root(), 0);
    var unpaged = std.ArrayList(u64).empty;
    defer unpaged.deinit(testing.allocator);
    try where(&pinnedReader, pinnedCatalog, .{}, &unpaged, testing.allocator);

    // A writer commits more rows while the reader stays pinned.
    {
        var writeTransaction = try database.beginWrite();
        const directoryReference = try appendRowsToDirectory(&writeTransaction, writeTransaction.newRoot, 25, 15);
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }

    var scrolled = std.ArrayList(u64).empty;
    defer scrolled.deinit(testing.allocator);
    var offset: u64 = 0;
    while (true) {
        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        try where(&pinnedReader, pinnedCatalog, .{ .page = .{ .start = .{ .offset = offset }, .limit = 6 } }, &page, testing.allocator);
        if (page.items.len == 0) break;
        try scrolled.appendSlice(testing.allocator, page.items);
        offset += 6;
    }
    pinnedReader.end();

    try testing.expectEqualSlices(u64, unpaged.items, scrolled.items);
    for (scrolled.items) |objectKey| try testing.expect(objectKey < 25); // no post-snapshot row appears
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

test "P31: ordering by a blob property is error.UnsupportedOrdering with nothing appended" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p31.airdb");
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

    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedOrdering, where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &page, testing.allocator));
    try testing.expectEqual(@as(usize, 0), page.items.len);

    // Must NOT reject an int property.
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 0 } } }, &page, testing.allocator);
}

test "P32: ordering by a property past the count is error.BadProperty with nothing appended" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p32.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);

    var page = std.ArrayList(u64).empty;
    defer page.deinit(testing.allocator);
    try testing.expectError(error.BadProperty, where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 9 } } }, &page, testing.allocator));
    try testing.expectEqual(@as(usize, 0), page.items.len);

    // Must NOT reject an int property.
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &page, testing.allocator);
}

test "P33: sortByProperty descending is the exact reverse of ascending, ties included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p33.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedWithValues(&writeTransaction, false, &p10Values);

    var ascendingKeys: [p10Values.len]u64 = undefined;
    for (0..p10Values.len) |index| ascendingKeys[index] = index;
    try sortByProperty(&writeTransaction, catalogReference, &ascendingKeys, 1, .ascending, testing.allocator);

    var descendingKeys: [p10Values.len]u64 = undefined;
    for (0..p10Values.len) |index| descendingKeys[index] = index;
    try sortByProperty(&writeTransaction, catalogReference, &descendingKeys, 1, .descending, testing.allocator);

    var reversedAscending: [p10Values.len]u64 = undefined;
    for (ascendingKeys, 0..) |key, position| reversedAscending[ascendingKeys.len - 1 - position] = key;
    try testing.expectEqualSlices(u64, &reversedAscending, &descendingKeys);
    try testing.expectEqualSlices(u64, &p10ExpectedAscending, &ascendingKeys);
}

test "P34: sortByProperty on a blob property is error.UnsupportedOrdering" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p34.airdb");
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
    var objectKeys = [_]u64{};
    try testing.expectError(error.UnsupportedOrdering, sortByProperty(&writeTransaction, catalogReference, &objectKeys, 1, .ascending, testing.allocator));
}

test "P35: sortByProperty on an objectKey that does not resolve is error.NotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p35.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, false, 5);
    var objectKeys = [_]u64{999};
    try testing.expectError(error.NotFound, sortByProperty(&writeTransaction, catalogReference, &objectKeys, 1, .ascending, testing.allocator));
}

// ---------------------------------------------------------------------------
// Fuzz
// ---------------------------------------------------------------------------

const P36Entry = struct { value: u64, objectKey: u64 };

fn p36LessThan(order: SortOrder, left: P36Entry, right: P36Entry) bool {
    return switch (order) {
        .ascending => if (left.value != right.value) left.value < right.value else left.objectKey < right.objectKey,
        .descending => if (left.value != right.value) left.value > right.value else left.objectKey > right.objectKey,
    };
}

// Expected page for sortKeyChoice 1 (indexed property1) or 2 (unindexed
// property2, whose seeded value equals the objectKey itself): filter by
// property1 >= 10, sort by the chosen property's value with objectKey
// breaking ties, then slice [offset, offset+limit).
fn p36ExpectedSlice(
    allocator: std.mem.Allocator,
    property1Values: []const u64,
    sortKeyChoice: u2,
    order: SortOrder,
    offset: u64,
    limit: ?u64,
) !std.ArrayList(u64) {
    var matching = std.ArrayList(P36Entry).empty;
    defer matching.deinit(allocator);
    for (property1Values, 0..) |property1Value, objectKey| {
        if (property1Value < 10) continue;
        const sortValue: u64 = if (sortKeyChoice == 1) property1Value else objectKey; // property2[i] == i
        try matching.append(allocator, .{ .value = sortValue, .objectKey = objectKey });
    }
    std.mem.sort(P36Entry, matching.items, order, p36LessThan);

    var result = std.ArrayList(u64).empty;
    const start = @min(offset, matching.items.len);
    const end = if (limit) |l| @min(start +| l, matching.items.len) else matching.items.len;
    for (matching.items[start..end]) |entry| try result.append(allocator, entry.objectKey);
    return result;
}

test "P36: fuzz, a random page equals the independently computed expected slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p36.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const rowCount: u64 = 120;
    var property1Values: [rowCount]u64 = undefined;
    var prngSeed = std.Random.DefaultPrng.init(42);
    const seedRandom = prngSeed.random();
    for (0..rowCount) |index| property1Values[index] = seedRandom.intRangeAtMost(u64, 0, 40);

    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    for (property1Values, 0..) |value, index| catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ index, value, index })).catalogReference;

    var draw: u64 = 0;
    while (draw < 200) : (draw += 1) {
        var prng = std.Random.DefaultPrng.init(draw);
        const random = prng.random();
        const sortKeyChoice = random.intRangeLessThan(u2, 0, 3);
        const order: SortOrder = if (random.boolean()) .ascending else .descending;
        const offset = random.intRangeAtMost(u64, 0, 130);
        const limitChoice = random.intRangeLessThan(u3, 0, 5);
        const limit: ?u64 = switch (limitChoice) {
            0 => null,
            1 => 0,
            2 => 1,
            3 => 7,
            else => 130,
        };
        const ordering: Ordering = switch (sortKeyChoice) {
            0 => .{ .sortKey = .objectKey, .order = order },
            1 => .{ .sortKey = .{ .property = 1 }, .order = order }, // indexed
            else => .{ .sortKey = .{ .property = 2 }, .order = order }, // unindexed
        };

        var page = std.ArrayList(u64).empty;
        defer page.deinit(testing.allocator);
        try where(&writeTransaction, catalogReference, .{
            .predicate = intComparison(1, .ge, 10),
            .ordering = ordering,
            .page = .{ .start = .{ .offset = offset }, .limit = limit },
        }, &page, testing.allocator);

        if (sortKeyChoice == 0) {
            // objectKey ordering: expected is the matching objectKeys themselves
            // (property1 >= 10), sorted by objectKey.
            var matching = std.ArrayList(u64).empty;
            defer matching.deinit(testing.allocator);
            for (property1Values, 0..) |value, objectKey| {
                if (value >= 10) try matching.append(testing.allocator, objectKey);
            }
            if (order == .descending) std.mem.reverse(u64, matching.items);
            const start = @min(offset, matching.items.len);
            const end = if (limit) |l| @min(start +| l, matching.items.len) else matching.items.len;
            try testing.expectEqualSlices(u64, matching.items[start..end], page.items);
        } else {
            var expected = try p36ExpectedSlice(testing.allocator, &property1Values, sortKeyChoice, order, offset, limit);
            defer expected.deinit(testing.allocator);
            try testing.expectEqualSlices(u64, expected.items, page.items);
        }
        if (limit) |l| try testing.expect(page.items.len <= l);
    }
}

test "P37: fuzz, random page sizes reconstruct the full ordered result exactly once per row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p37.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedThreeProperty(&writeTransaction, true, 80);

    var unpaged = std.ArrayList(u64).empty;
    defer unpaged.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &unpaged, testing.allocator);

    var draw: u64 = 0;
    while (draw < 100) : (draw += 1) {
        var prng = std.Random.DefaultPrng.init(draw + 1000);
        const random = prng.random();
        const pageSize = random.intRangeAtMost(u64, 1, 20);

        var reconstructed = std.ArrayList(u64).empty;
        defer reconstructed.deinit(testing.allocator);
        var offset: u64 = 0;
        while (true) {
            var page = std.ArrayList(u64).empty;
            defer page.deinit(testing.allocator);
            try where(&writeTransaction, catalogReference, .{
                .ordering = .{ .sortKey = .{ .property = 1 } },
                .page = .{ .start = .{ .offset = offset }, .limit = pageSize },
            }, &page, testing.allocator);
            if (page.items.len == 0) break;
            try reconstructed.appendSlice(testing.allocator, page.items);
            offset += pageSize;
        }
        try testing.expectEqualSlices(u64, unpaged.items, reconstructed.items);
    }
}
