//! Facade-level suite for `query.minimum` / `query.maximum`: the indexed
//! fast path, the unindexed scan fallback, the empty-boundary-leaf case at
//! either edge, the kind check, and a differential fuzz against an in-memory
//! model. Governing rule (spec D6): no assertion here compares a
//! `minimum`/`maximum` result against `aggregateInt`, because on the
//! unindexed path the terminal literally calls `aggregateInt` and the two
//! would agree by construction. Every expected value below is either a
//! literal written out by hand or computed by `referenceEndpoints`, which
//! reads only its own argument slice.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;

fn qeTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

// Delete the row whose primaryKey is `primaryKey` from `catalogReference`. The
// types built by the helpers below all have exactly two properties
// (primaryKey, value), so a two-cell read is enough to recover the version.
fn deletePrimaryKey(writeTransaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64) !Reference {
    var out: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(writeTransaction, catalogReference, primaryKey, &out)).?;
    return (try rows.delete(writeTransaction, catalogReference, primaryKey, version)).ok;
}

// Build primaryKey(int) + value(int, indexed iff `indexed`) and insert
// `rowCount` rows with primaryKey = i and value = i, so the value index holds
// `rowCount` distinct outer keys.
fn seedDistinct(writeTransaction: *WriteTransaction, indexed: bool, rowCount: u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, rowIndex })).catalogReference;
    return catalogReference;
}

// Build primaryKey(int) + value(int, indexed iff `indexed`) and insert one row
// per (primaryKey, value) pair, in order. Lets a test choose non-consecutive
// values, unlike seedDistinct.
fn seedPairs(writeTransaction: *WriteTransaction, indexed: bool, pairs: []const [2]u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    for (pairs) |pair| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ pair[0], pair[1] })).catalogReference;
    return catalogReference;
}

// The min and max of `values`, computed here so an endpoint assertion is not
// checked against the engine that produced it.
fn referenceEndpoints(values: []const u64) struct { minimum: ?u64, maximum: ?u64 } {
    var minimum: ?u64 = null;
    var maximum: ?u64 = null;
    for (values) |value| {
        if (minimum == null or value < minimum.?) minimum = value;
        if (maximum == null or value > maximum.?) maximum = value;
    }
    return .{ .minimum = minimum, .maximum = maximum };
}

test "E1: indexed path, hand-written literals" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const catalogReference = try seedPairs(&writeTransaction, true, &.{ .{ 1, 50 }, .{ 2, 10 }, .{ 3, 90 }, .{ 4, 30 } });
    try testing.expectEqual(@as(?u64, 10), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 90), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E2: unindexed path, same literals" {
    // Together with E1, the "indexed and unindexed paths agree" obligation --
    // both sides pinned to the same hand-written literals rather than to
    // each other.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const catalogReference = try seedPairs(&writeTransaction, false, &.{ .{ 1, 50 }, .{ 2, 10 }, .{ 3, 90 }, .{ 4, 30 } });
    try testing.expectEqual(@as(?u64, 10), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 90), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E3: the boundary-leaf case at the low end, end to end" {
    // The facade counterpart of the index-level "minKey survives an emptied
    // leftmost leaf" test, and the reason this phase exists: deleting the
    // lowest primaryKeys drives rows.intValueIndexRemove 32 times, emptying the
    // value index's leftmost leaf.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try seedDistinct(&writeTransaction, true, 65);
    try testing.expectEqual(@as(?u64, 0), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 64), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));

    var primaryKey: u64 = 0;
    while (primaryKey <= 31) : (primaryKey += 1) catalogReference = try deletePrimaryKey(&writeTransaction, catalogReference, primaryKey);
    try testing.expectEqual(@as(?u64, 32), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 64), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));

    while (primaryKey <= 64) : (primaryKey += 1) catalogReference = try deletePrimaryKey(&writeTransaction, catalogReference, primaryKey);
    try testing.expectEqual(@as(?u64, null), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, null), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E4: the boundary-leaf case at the high end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try seedDistinct(&writeTransaction, true, 65);
    var primaryKey: u64 = 32;
    while (primaryKey <= 64) : (primaryKey += 1) catalogReference = try deletePrimaryKey(&writeTransaction, catalogReference, primaryKey);
    try testing.expectEqual(@as(?u64, 0), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 31), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E5: the same two deletions on an unindexed property" {
    // Proves the scan path is not accidentally passing E3/E4 because both
    // paths share a bug, and that the expected values are properties of the
    // data rather than of the index.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var lowDeleted = try seedDistinct(&writeTransaction, false, 65);
    var primaryKey: u64 = 0;
    while (primaryKey <= 31) : (primaryKey += 1) lowDeleted = try deletePrimaryKey(&writeTransaction, lowDeleted, primaryKey);
    try testing.expectEqual(@as(?u64, 32), try query.minimum(&writeTransaction, lowDeleted, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 64), try query.maximum(&writeTransaction, lowDeleted, 1, testing.allocator));

    var highDeleted = try seedDistinct(&writeTransaction, false, 65);
    primaryKey = 32;
    while (primaryKey <= 64) : (primaryKey += 1) highDeleted = try deletePrimaryKey(&writeTransaction, highDeleted, primaryKey);
    try testing.expectEqual(@as(?u64, 0), try query.minimum(&writeTransaction, highDeleted, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 31), try query.maximum(&writeTransaction, highDeleted, 1, testing.allocator));
}

test "E6: empty relation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const indexedCatalog = try seedDistinct(&writeTransaction, true, 0);
    try testing.expectEqual(@as(?u64, null), try query.minimum(&writeTransaction, indexedCatalog, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, null), try query.maximum(&writeTransaction, indexedCatalog, 1, testing.allocator));

    const unindexedCatalog = try seedDistinct(&writeTransaction, false, 0);
    try testing.expectEqual(@as(?u64, null), try query.minimum(&writeTransaction, unindexedCatalog, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, null), try query.maximum(&writeTransaction, unindexedCatalog, 1, testing.allocator));
}

test "E7: single row, including value 0 and value maxInt as ordinary values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const values = [_]u64{ 7, 0, std.math.maxInt(u64) };
    for (values) |value| {
        for ([_]bool{ true, false }) |indexed| {
            const catalogReference = try seedPairs(&writeTransaction, indexed, &.{.{ 0, value }});
            try testing.expectEqual(@as(?u64, value), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
            try testing.expectEqual(@as(?u64, value), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
        }
    }
}

test "E8: all rows deleted, distinct from a freshly-created empty catalog" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    for ([_]bool{ true, false }) |indexed| {
        var catalogReference = try seedDistinct(&writeTransaction, indexed, 8);
        var primaryKey: u64 = 0;
        while (primaryKey < 8) : (primaryKey += 1) catalogReference = try deletePrimaryKey(&writeTransaction, catalogReference, primaryKey);
        try testing.expectEqual(@as(?u64, null), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
        try testing.expectEqual(@as(?u64, null), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
    }
}

test "E9: an update that moves the endpoint" {
    // False-negative role: an index path that read a stale outer key returns
    // 10 for minimum here instead of 20.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try seedPairs(&writeTransaction, true, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 } });
    var out: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &out)).?;
    catalogReference = (try rows.update(&writeTransaction, catalogReference, 1, &.{ 1, 40 }, version)).ok.catalogReference;

    try testing.expectEqual(@as(?u64, 20), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 40), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E10: failure cases, named errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e10.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // property = 9, far out of range on a 2-property type.
    const twoPropertyCatalog = try seedDistinct(&writeTransaction, false, 0);
    try testing.expectError(error.BadProperty, query.minimum(&writeTransaction, twoPropertyCatalog, 9, testing.allocator));
    try testing.expectError(error.BadProperty, query.maximum(&writeTransaction, twoPropertyCatalog, 9, testing.allocator));
    // property = 2, exactly propertyCount: the off-by-one boundary.
    try testing.expectError(error.BadProperty, query.minimum(&writeTransaction, twoPropertyCatalog, 2, testing.allocator));
    try testing.expectError(error.BadProperty, query.maximum(&writeTransaction, twoPropertyCatalog, 2, testing.allocator));

    // A blob property carrying a real value index (createFromDefinitions does
    // not reject `indexed` on a blob kind): still UnsupportedAggregate.
    const indexedBlobDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob, .indexed = true },
    };
    const indexedBlobCatalog = try catalog.createFromDefinitions(&writeTransaction, &indexedBlobDefinitions);
    try testing.expectError(error.UnsupportedAggregate, query.minimum(&writeTransaction, indexedBlobCatalog, 1, testing.allocator));
    try testing.expectError(error.UnsupportedAggregate, query.maximum(&writeTransaction, indexedBlobCatalog, 1, testing.allocator));

    // Same kind, not indexed: also UnsupportedAggregate.
    const plainBlobDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob, .indexed = false },
    };
    const plainBlobCatalog = try catalog.createFromDefinitions(&writeTransaction, &plainBlobDefinitions);
    try testing.expectError(error.UnsupportedAggregate, query.minimum(&writeTransaction, plainBlobCatalog, 1, testing.allocator));
    try testing.expectError(error.UnsupportedAggregate, query.maximum(&writeTransaction, plainBlobCatalog, 1, testing.allocator));

    // A collection kind.
    const listDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .list },
    };
    const listCatalog = try catalog.createFromDefinitions(&writeTransaction, &listDefinitions);
    try testing.expectError(error.UnsupportedAggregate, query.minimum(&writeTransaction, listCatalog, 1, testing.allocator));
    try testing.expectError(error.UnsupportedAggregate, query.maximum(&writeTransaction, listCatalog, 1, testing.allocator));
}

test "E11: false-positive validation for the kind check, link is accepted" {
    // Without this, a kind check that rejected everything would pass E10 and
    // nothing would notice.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    for ([_]u64{ 5, 3, 9 }, 0..) |value, primaryKey| {
        catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ primaryKey, value })).catalogReference;
    }
    try testing.expectEqual(@as(?u64, 3), try query.minimum(&writeTransaction, catalogReference, 1, testing.allocator));
    try testing.expectEqual(@as(?u64, 9), try query.maximum(&writeTransaction, catalogReference, 1, testing.allocator));
}

test "E12: fuzz, differential against an in-memory model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qeTmpPath(testing.allocator, &tmp, "e12.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var indexedCatalog = try seedDistinct(&writeTransaction, true, 0);
    var unindexedCatalog = try seedDistinct(&writeTransaction, false, 0);

    var livePrimaryKeys = std.ArrayList(u64).empty;
    defer livePrimaryKeys.deinit(testing.allocator);
    var liveValues = std.ArrayList(u64).empty; // parallel to livePrimaryKeys
    defer liveValues.deinit(testing.allocator);
    var nextPrimaryKey: u64 = 0;

    var prng = std.Random.DefaultPrng.init(0x51DE12);
    const random = prng.random();
    var round: usize = 0;
    while (round < 150) : (round += 1) {
        const insertOperation = livePrimaryKeys.items.len == 0 or random.boolean();
        if (insertOperation) {
            const value = random.intRangeLessThan(u64, 0, 40);
            const primaryKey = nextPrimaryKey;
            nextPrimaryKey += 1;
            indexedCatalog = (try rows.insert(&writeTransaction, indexedCatalog, &.{ primaryKey, value })).catalogReference;
            unindexedCatalog = (try rows.insert(&writeTransaction, unindexedCatalog, &.{ primaryKey, value })).catalogReference;
            try livePrimaryKeys.append(testing.allocator, primaryKey);
            try liveValues.append(testing.allocator, value);
        } else {
            const removeIndex = random.intRangeLessThan(usize, 0, livePrimaryKeys.items.len);
            const primaryKey = livePrimaryKeys.items[removeIndex];
            indexedCatalog = try deletePrimaryKey(&writeTransaction, indexedCatalog, primaryKey);
            unindexedCatalog = try deletePrimaryKey(&writeTransaction, unindexedCatalog, primaryKey);
            _ = livePrimaryKeys.swapRemove(removeIndex);
            _ = liveValues.swapRemove(removeIndex);
        }

        const expected = referenceEndpoints(liveValues.items);
        try testing.expectEqual(expected.minimum, try query.minimum(&writeTransaction, indexedCatalog, 1, testing.allocator));
        try testing.expectEqual(expected.minimum, try query.minimum(&writeTransaction, unindexedCatalog, 1, testing.allocator));
        try testing.expectEqual(expected.maximum, try query.maximum(&writeTransaction, indexedCatalog, 1, testing.allocator));
        try testing.expectEqual(expected.maximum, try query.maximum(&writeTransaction, unindexedCatalog, 1, testing.allocator));
        try testing.expectEqual(liveValues.items.len == 0, expected.minimum == null);
    }
}
