// queryDifferentialTests.zig -- randomized predicate trees checked against a
// naive in-memory reference matcher, plus index/scan equivalence over the
// same corpus. This is the brute-force cross-check for the whole predicate
// tree engine: everything else in queryTests.zig pins named shapes by hand,
// this file pins the engine against an independent implementation over
// thousands of generated trees.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const Database = @import("database.zig").Database;
const Reference = @import("storage/reference.zig").Reference;
const Scan = @import("query/scan.zig").Scan;
const planner = @import("query/planner.zig");

const Predicate = query.Predicate;
const Operator = query.Operator;

const rowCount: u64 = 300;

const ReferenceRow = struct { objectKey: u64, values: [3]u64, isLive: bool };

// A hand-written recursive matcher over the same Predicate tree type, with
// its own switch over Operator and its own two-valued and/or/not. It must
// not import anything from src/query/ other than the Predicate type, and
// must not mention Match: the point is an implementation that shares nothing
// with the engine except the input.
fn referenceMatches(row: ReferenceRow, predicate: Predicate) bool {
    switch (predicate) {
        .comparison => |comparison| {
            const storedValue = row.values[comparison.property];
            const probeValue = switch (comparison.value) {
                .int => |value| value,
                .bytes => unreachable, // the generator never emits bytes values
            };
            return switch (comparison.operator) {
                .eq => storedValue == probeValue,
                .ne => storedValue != probeValue,
                .lt => storedValue < probeValue,
                .le => storedValue <= probeValue,
                .gt => storedValue > probeValue,
                .ge => storedValue >= probeValue,
                .beginsWith => @panic("the generator never emits beginsWith"),
            };
        },
        .conjunction => |children| {
            for (children) |child| if (!referenceMatches(row, child)) return false;
            return true;
        },
        .disjunction => |children| {
            for (children) |child| if (referenceMatches(row, child)) return true;
            return false;
        },
        .negation => |child| return !referenceMatches(row, child.*),
    }
}

const ReferenceAggregate = struct { count: u64, sum: u64, min: ?u64, max: ?u64 };

// A from-scratch aggregate over the same rows and matcher as the rest of this
// file. Must not call query.aggregateInt, or the comparison below would agree
// with the engine by construction and prove nothing.
fn referenceAggregate(referenceRows: []const ReferenceRow, predicate: Predicate, property: usize) ReferenceAggregate {
    var result = ReferenceAggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    for (referenceRows) |row| {
        if (!row.isLive or !referenceMatches(row, predicate)) continue;
        const value = row.values[property];
        result.count += 1;
        result.sum +%= value;
        if (result.min == null or value < result.min.?) result.min = value;
        if (result.max == null or value > result.max.?) result.max = value;
    }
    return result;
}

fn treeContainsNegation(predicate: Predicate) bool {
    switch (predicate) {
        .comparison => return false,
        .conjunction, .disjunction => |children| {
            for (children) |child| if (treeContainsNegation(child)) return true;
            return false;
        },
        .negation => return true,
    }
}

// Whether the tree contains a disjunction with at least one drivable and at
// least one non-drivable child. Used only to size the differential corpus,
// so a shallow (non-recursive-depth-aware) canDriveFromIndex check on each
// child is a fine approximation.
fn treeContainsMixedDisjunction(scan: *const Scan, predicate: Predicate) bool {
    switch (predicate) {
        .comparison => return false,
        .conjunction => |children| {
            for (children) |child| if (treeContainsMixedDisjunction(scan, child)) return true;
            return false;
        },
        .disjunction => |children| {
            var sawDrivable = false;
            var sawUndrivable = false;
            for (children) |child| {
                if (planner.canDriveFromIndex(scan, child)) sawDrivable = true else sawUndrivable = true;
            }
            if (sawDrivable and sawUndrivable) return true;
            for (children) |child| if (treeContainsMixedDisjunction(scan, child)) return true;
            return false;
        },
        .negation => |child| return treeContainsMixedDisjunction(scan, child.*),
    }
}

fn pickValue(random: std.Random) u64 {
    if (random.intRangeLessThan(u8, 0, 5) == 0) {
        const boosted = [_]u64{ 0, 1, 36, 37, std.math.maxInt(u64) };
        return boosted[random.intRangeLessThan(usize, 0, boosted.len)];
    }
    return random.intRangeLessThan(u64, 0, 40);
}

fn pickOperator(random: std.Random) Operator {
    // Indices 0..5 are eq, ne, lt, le, gt, ge; index 6 (beginsWith) is never
    // generated, since nothing in this corpus produces bytes values.
    return @enumFromInt(random.intRangeLessThan(u8, 0, 6));
}

fn makeComparison(random: std.Random) Predicate {
    return .{ .comparison = .{
        .property = random.intRangeLessThan(usize, 0, 3),
        .operator = pickOperator(random),
        .value = .{ .int = pickValue(random) },
    } };
}

// Depth bound 4: any node reached at depth 4 is forced to a comparison. Node
// kind weights below depth 4: 45% comparison, 20% conjunction, 20%
// disjunction, 15% negation.
fn makeRandomTree(allocator: std.mem.Allocator, random: std.Random, depth: usize) !Predicate {
    if (depth >= 4) return makeComparison(random);
    const roll = random.intRangeLessThan(u8, 0, 100);
    if (roll < 45) return makeComparison(random);
    if (roll < 65) {
        const childCount = random.intRangeAtMost(u8, 0, 3);
        const children = try allocator.alloc(Predicate, childCount);
        for (children) |*child| child.* = try makeRandomTree(allocator, random, depth + 1);
        return .{ .conjunction = children };
    }
    if (roll < 85) {
        const childCount = random.intRangeAtMost(u8, 0, 3);
        const children = try allocator.alloc(Predicate, childCount);
        for (children) |*child| child.* = try makeRandomTree(allocator, random, depth + 1);
        return .{ .disjunction = children };
    }
    const child = try allocator.create(Predicate);
    child.* = try makeRandomTree(allocator, random, depth + 1);
    return .{ .negation = child };
}

fn queryDifferentialTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn seedRows(writeTransaction: anytype, catalogReference: Reference, referenceRows: *std.ArrayList(ReferenceRow)) !Reference {
    var result = catalogReference;
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) {
        const values = [3]u64{ rowIndex, rowIndex % 37, (rowIndex * 7) % 11 };
        const inserted = try rows.insert(writeTransaction, result, &values);
        result = inserted.catalogReference;
        try referenceRows.append(testing.allocator, .{ .objectKey = inserted.objectKey, .values = values, .isLive = true });
    }
    return result;
}

test "predicate trees agree with a naive reference matcher, across a randomized corpus" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try queryDifferentialTmpPath(testing.allocator, &tmp, "differential.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const definitionsA = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    const definitionsB = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .int },
    };
    var catalogA = try catalog.createFromDefinitions(&writeTransaction, &definitionsA);
    var catalogB = try catalog.createFromDefinitions(&writeTransaction, &definitionsB);

    var referenceRowsA = std.ArrayList(ReferenceRow).empty;
    defer referenceRowsA.deinit(testing.allocator);
    var referenceRowsB = std.ArrayList(ReferenceRow).empty;
    defer referenceRowsB.deinit(testing.allocator);
    catalogA = try seedRows(&writeTransaction, catalogA, &referenceRowsA);
    catalogB = try seedRows(&writeTransaction, catalogB, &referenceRowsB);

    // Delete every 9th row from both catalogs (and the reference bookkeeping),
    // so liveness is exercised. Neither catalog had any prior activity, so
    // primaryKey i has objectKey i in both, and the reference arrays stay
    // index-aligned with insertion order.
    var primaryKey: u64 = 0;
    while (primaryKey < rowCount) : (primaryKey += 9) {
        var out: [3]u64 = undefined;
        const versionA = (try rows.getByPrimaryKey(&writeTransaction, catalogA, primaryKey, &out)).?;
        catalogA = (try rows.delete(&writeTransaction, catalogA, primaryKey, versionA)).ok;
        referenceRowsA.items[primaryKey].isLive = false;
        const versionB = (try rows.getByPrimaryKey(&writeTransaction, catalogB, primaryKey, &out)).?;
        catalogB = (try rows.delete(&writeTransaction, catalogB, primaryKey, versionB)).ok;
        referenceRowsB.items[primaryKey].isLive = false;
    }

    const scanA = try Scan.open(&writeTransaction, catalogA);
    var totalLiveCount: usize = 0;
    for (referenceRowsA.items) |row| if (row.isLive) {
        totalLiveCount += 1;
    };

    var emptyResultCount: usize = 0;
    var matchAllCount: usize = 0;
    var strictSubsetCount: usize = 0;
    var drivableCount: usize = 0;
    var nonDrivableCount: usize = 0;
    var containsNegationCount: usize = 0;
    var mixedDisjunctionCount: usize = 0;

    var seed: u64 = 1;
    while (seed <= 17) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var treeIndex: usize = 0;
        while (treeIndex < 40) : (treeIndex += 1) {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const tree = try makeRandomTree(arena.allocator(), random, 0);

            var expected = std.ArrayList(u64).empty;
            defer expected.deinit(testing.allocator);
            for (referenceRowsA.items) |row| {
                if (row.isLive and referenceMatches(row, tree)) try expected.append(testing.allocator, row.objectKey);
            }

            var hitsA = std.ArrayList(u64).empty;
            defer hitsA.deinit(testing.allocator);
            query.where(&writeTransaction, catalogA, tree, &hitsA, testing.allocator) catch |err| {
                std.debug.print("seed {d} tree {d} (catalog A): where failed with {}\n", .{ seed, treeIndex, err });
                return err;
            };
            std.mem.sort(u64, hitsA.items, {}, std.sort.asc(u64));
            testing.expectEqualSlices(u64, expected.items, hitsA.items) catch |err| {
                std.debug.print("seed {d} tree {d}: catalog A mismatch\n", .{ seed, treeIndex });
                return err;
            };

            var hitsB = std.ArrayList(u64).empty;
            defer hitsB.deinit(testing.allocator);
            query.where(&writeTransaction, catalogB, tree, &hitsB, testing.allocator) catch |err| {
                std.debug.print("seed {d} tree {d} (catalog B): where failed with {}\n", .{ seed, treeIndex, err });
                return err;
            };
            std.mem.sort(u64, hitsB.items, {}, std.sort.asc(u64));
            testing.expectEqualSlices(u64, expected.items, hitsB.items) catch |err| {
                std.debug.print("seed {d} tree {d}: catalog B mismatch\n", .{ seed, treeIndex });
                return err;
            };

            const countA = try query.countWhere(&writeTransaction, catalogA, tree, testing.allocator);
            try testing.expectEqual(@as(u64, hitsA.items.len), countA);
            const countB = try query.countWhere(&writeTransaction, catalogB, tree, testing.allocator);
            try testing.expectEqual(@as(u64, hitsB.items.len), countB);

            // aggregateInt shares runQuery/the planner/isLiveMatch with where and
            // countWhere (already checked above); this is the only line that
            // exercises the Sink's own count/sum/min/max arithmetic against an
            // independent reference.
            const aggregateProperty = 0;
            const expectedAggregateA = referenceAggregate(referenceRowsA.items, tree, aggregateProperty);
            const actualAggregateA = try query.aggregateInt(&writeTransaction, catalogA, aggregateProperty, tree, testing.allocator);
            try testing.expectEqual(expectedAggregateA.count, actualAggregateA.count);
            try testing.expectEqual(expectedAggregateA.sum, actualAggregateA.sum);
            try testing.expectEqual(expectedAggregateA.min, actualAggregateA.min);
            try testing.expectEqual(expectedAggregateA.max, actualAggregateA.max);

            const expectedAggregateB = referenceAggregate(referenceRowsB.items, tree, aggregateProperty);
            const actualAggregateB = try query.aggregateInt(&writeTransaction, catalogB, aggregateProperty, tree, testing.allocator);
            try testing.expectEqual(expectedAggregateB.count, actualAggregateB.count);
            try testing.expectEqual(expectedAggregateB.sum, actualAggregateB.sum);
            try testing.expectEqual(expectedAggregateB.min, actualAggregateB.min);
            try testing.expectEqual(expectedAggregateB.max, actualAggregateB.max);

            // Every returned objectKey is live in the reference and appears at
            // most once (guaranteed here by matching the deduplicated,
            // ascending `expected` slice exactly, asserted above).
            for (hitsA.items) |objectKey| {
                const row = referenceRowsA.items[objectKey];
                try testing.expect(row.isLive);
            }

            const matchedCount = expected.items.len;
            if (matchedCount == 0) emptyResultCount += 1;
            if (matchedCount == totalLiveCount) matchAllCount += 1;
            if (matchedCount > 0 and matchedCount < totalLiveCount) strictSubsetCount += 1;
            if (planner.canDriveFromIndex(&scanA, tree)) drivableCount += 1 else nonDrivableCount += 1;
            if (treeContainsNegation(tree)) containsNegationCount += 1;
            if (treeContainsMixedDisjunction(&scanA, tree)) mixedDisjunctionCount += 1;
        }
    }

    // Corpus diversity: without these, a generator that only ever emits a
    // single trivial shape would pass the loop above while proving nothing.
    try testing.expect(emptyResultCount > 0);
    try testing.expect(matchAllCount > 0);
    try testing.expect(strictSubsetCount >= 100);
    try testing.expect(drivableCount >= 50);
    try testing.expect(nonDrivableCount >= 50);
    try testing.expect(containsNegationCount > 0);
    try testing.expect(mixedDisjunctionCount >= 10);
}
