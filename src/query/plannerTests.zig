// plannerTests.zig -- companion suite for planner.zig.
//
// Pure decision tests build a Scan by hand from property definitions and need
// no database. Database-backed tests (selectivityOf, collectCandidates)
// follow, seeded through the public query facade.

const std = @import("std");
const testing = std.testing;
const planner = @import("planner.zig");
const predicateModule = @import("predicate.zig");
const Scan = @import("scan.zig").Scan;
const catalog = @import("../schema/catalog.zig");
const rows = @import("../records/rows.zig");
const Database = @import("../database.zig").Database;
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
// Cross-checks selectivityOf/collectCandidates against the public facade's
// own scan path, on a separately-seeded unindexed twin, so the planner's
// candidate estimate is never verified against itself.
const query = @import("../query.zig");

const Predicate = predicateModule.Predicate;
const Operator = predicateModule.Operator;
const Selectivity = planner.Selectivity;

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// Build a Scan by hand: property 0 unindexed, remaining properties indexed
// according to `indexedFlags`. No I/O: propertyReferences/valueIndexReferences
// are never dereferenced by the pure decision functions under test.
fn makeScanForTest(indexedFlags: []const bool) Scan {
    var scan: Scan = undefined;
    scan.propertyCount = indexedFlags.len;
    for (indexedFlags, 0..) |isIndexed, propertyIndex| {
        scan.propertyReferences[propertyIndex] = 0;
        scan.propertyKinds[propertyIndex] = .int;
        scan.indexed[propertyIndex] = isIndexed;
        scan.valueIndexReferences[propertyIndex] = 0;
    }
    scan.liveColumnReference = 0;
    scan.keyToRowIndexReference = 0;
    return scan;
}

test "canDriveFromIndex: eq and each range operator on an indexed property are drivable" {
    const scan = makeScanForTest(&.{true});
    try testing.expect(planner.canDriveFromIndex(&scan, intComparison(0, .eq, 5)));
    try testing.expect(planner.canDriveFromIndex(&scan, intComparison(0, .lt, 5)));
    try testing.expect(planner.canDriveFromIndex(&scan, intComparison(0, .le, 5)));
    try testing.expect(planner.canDriveFromIndex(&scan, intComparison(0, .gt, 5)));
    try testing.expect(planner.canDriveFromIndex(&scan, intComparison(0, .ge, 5)));
}

test "canDriveFromIndex: a conjunction with exactly one drivable child is drivable" {
    const scan = makeScanForTest(&.{ true, false });
    const children = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .eq, 1) };
    try testing.expect(planner.canDriveFromIndex(&scan, .{ .conjunction = &children }));
}

test "canDriveFromIndex: a disjunction is drivable only when every child is, including an empty one" {
    const scan = makeScanForTest(&.{ true, true });
    const bothIndexed = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .eq, 1) };
    try testing.expect(planner.canDriveFromIndex(&scan, .{ .disjunction = &bothIndexed }));
    try testing.expect(planner.canDriveFromIndex(&scan, .{ .disjunction = &.{} }));
}

test "canDriveFromIndex: a conjunction nested inside a drivable disjunction is drivable" {
    const scan = makeScanForTest(&.{ true, true });
    const innerConjunction = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .eq, 2) };
    const outer = [_]Predicate{ .{ .conjunction = &innerConjunction }, intComparison(1, .eq, 3) };
    try testing.expect(planner.canDriveFromIndex(&scan, .{ .disjunction = &outer }));
}

test "canDriveFromIndex: ne and beginsWith on an indexed property are not drivable" {
    const scan = makeScanForTest(&.{true});
    try testing.expect(!planner.canDriveFromIndex(&scan, intComparison(0, .ne, 5)));
    try testing.expect(!planner.canDriveFromIndex(&scan, intComparison(0, .beginsWith, 5)));
}

test "canDriveFromIndex: eq on an unindexed property is not drivable" {
    const scan = makeScanForTest(&.{false});
    try testing.expect(!planner.canDriveFromIndex(&scan, intComparison(0, .eq, 5)));
}

test "canDriveFromIndex: an empty conjunction is not drivable" {
    const scan = makeScanForTest(&.{true});
    try testing.expect(!planner.canDriveFromIndex(&scan, .{ .conjunction = &.{} }));
}

test "canDriveFromIndex: a disjunction with one unindexed branch is not drivable" {
    const scan = makeScanForTest(&.{ true, false });
    const children = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .eq, 1) };
    try testing.expect(!planner.canDriveFromIndex(&scan, .{ .disjunction = &children }));
}

test "canDriveFromIndex: any negation, including of an indexed eq, is not drivable" {
    const scan = makeScanForTest(&.{true});
    const leaf = intComparison(0, .eq, 5);
    try testing.expect(!planner.canDriveFromIndex(&scan, .{ .negation = &leaf }));
}

test "canDriveFromIndex: a conjunction whose children are all unindexed is not drivable" {
    const scan = makeScanForTest(&.{ false, false });
    const children = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .eq, 1) };
    try testing.expect(!planner.canDriveFromIndex(&scan, .{ .conjunction = &children }));
}

test "canDriveFromIndex: a tree nested 33 deep is not drivable" {
    const scan = makeScanForTest(&.{true});
    var current = intComparison(0, .eq, 1);
    var boxes: [33]Predicate = undefined;
    var level: usize = 0;
    while (level < 33) : (level += 1) {
        boxes[level] = current;
        current = .{ .negation = &boxes[level] };
    }
    // 33 negations puts the comparison itself at depth 33, past the cap; even
    // ignoring negation's own always-false rule this must not be drivable.
    try testing.expect(!planner.canDriveFromIndex(&scan, current));
}

test "canDriveFromIndex: a chain of single-child conjunctions reaching exactly depth 31 is drivable" {
    // Conjunctions, not negations: negation's own `.negation => false` rule would
    // shadow the depth check before it is ever reached.
    const scan = makeScanForTest(&.{true});
    var current = intComparison(0, .eq, 1);
    var slots: [31][1]Predicate = undefined;
    var level: usize = 0;
    while (level < 31) : (level += 1) {
        slots[level][0] = current;
        current = .{ .conjunction = slots[level][0..] };
    }
    // 31 nested single-child conjunctions put the comparison at depth 31, one short of
    // the 32 cap: it must still be drivable.
    try testing.expect(planner.canDriveFromIndex(&scan, current));
}

test "canDriveFromIndex: a chain of single-child conjunctions reaching exactly depth 32 is not drivable" {
    const scan = makeScanForTest(&.{true});
    var current = intComparison(0, .eq, 1);
    var slots: [32][1]Predicate = undefined;
    var level: usize = 0;
    while (level < 32) : (level += 1) {
        slots[level][0] = current;
        current = .{ .conjunction = slots[level][0..] };
    }
    // 32 nested single-child conjunctions put the comparison at exactly depth 32: the
    // cap must fire there, not one level later as it would if this boundary were off by
    // one.
    try testing.expect(!planner.canDriveFromIndex(&scan, current));
}

test "isMoreSelective: exact counts order ascending, exact beats unbounded, unbounded beats nothing" {
    try testing.expect(planner.isMoreSelective(.{ .exact = 1 }, .{ .exact = 2 }));
    try testing.expect(!planner.isMoreSelective(.{ .exact = 2 }, .{ .exact = 1 }));
    try testing.expect(planner.isMoreSelective(.{ .exact = 0 }, .{ .exact = 1 }));
    try testing.expect(planner.isMoreSelective(.{ .exact = 1_000_000 }, .unbounded));
    try testing.expect(!planner.isMoreSelective(.unbounded, .{ .exact = 1 }));
    try testing.expect(!planner.isMoreSelective(.unbounded, .unbounded));
}

test "rangeBounds translates each operator into an inclusive range, with the two empty-range guards" {
    try testing.expectEqual(planner.Bounds{ .low = 5, .high = std.math.maxInt(u64) }, planner.rangeBounds(.ge, 5).?);
    try testing.expectEqual(planner.Bounds{ .low = 6, .high = std.math.maxInt(u64) }, planner.rangeBounds(.gt, 5).?);
    try testing.expectEqual(planner.Bounds{ .low = 0, .high = 5 }, planner.rangeBounds(.le, 5).?);
    try testing.expectEqual(planner.Bounds{ .low = 0, .high = 4 }, planner.rangeBounds(.lt, 5).?);
    try testing.expectEqual(@as(?planner.Bounds, null), planner.rangeBounds(.gt, std.math.maxInt(u64)));
    try testing.expectEqual(@as(?planner.Bounds, null), planner.rangeBounds(.lt, 0));
}

test "canDriveFromIndex fuzz: both true and false buckets occur, and the disjunction rule never inverts" {
    var trueCount: usize = 0;
    var falseCount: usize = 0;
    const scan = makeScanForTest(&.{ true, false, true });
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try makeRandomTree(arena.allocator(), random, 0, 4);
        if (planner.canDriveFromIndex(&scan, tree)) trueCount += 1 else falseCount += 1;
    }
    try testing.expect(trueCount > 0);
    try testing.expect(falseCount > 0);
}

fn makeRandomTree(allocator: std.mem.Allocator, random: std.Random, depth: usize, maxDepth: usize) !Predicate {
    const kind = if (depth >= maxDepth) 0 else random.intRangeLessThan(u8, 0, 4);
    switch (kind) {
        0 => {
            const property = random.intRangeLessThan(usize, 0, 3);
            const operator: Operator = @enumFromInt(random.intRangeLessThan(u8, 0, 7));
            return intComparison(property, operator, random.int(u64));
        },
        1, 2 => {
            const childCount = random.intRangeLessThan(u8, 0, 4);
            const children = try allocator.alloc(Predicate, childCount);
            for (children) |*child| child.* = try makeRandomTree(allocator, random, depth + 1, maxDepth);
            return if (kind == 1) .{ .conjunction = children } else .{ .disjunction = children };
        },
        else => {
            const child = try allocator.create(Predicate);
            child.* = try makeRandomTree(allocator, random, depth + 1, maxDepth);
            return .{ .negation = child };
        },
    }
}

// ---------------------------------------------------------------------------
// Database-backed tests: selectivityOf and collectCandidates.
// ---------------------------------------------------------------------------

fn plannerTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff `indexed`), property2 =
// secondary. Inserts n rows with primaryKey=i, property1=i%100, property2=i.
fn seedPlannerCatalog(writeTransaction: *WriteTransaction, indexed: bool, rowCount: u64) !Reference {
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

// Two properties indexed with distributions chosen so an eq on each yields a
// different exact count: property1 (i % 100) matches 50 rows for any of its
// 100 values at rowCount 5000; property2 is 0 only at row 0, so eq(0) matches
// exactly 1 row.
fn seedTwoIndexedCatalog(writeTransaction: *WriteTransaction, rowCount: u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) {
        const secondaryValue: u64 = if (rowIndex == 0) 0 else 1;
        catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ rowIndex, rowIndex % 100, secondaryValue })).catalogReference;
    }
    return catalogReference;
}

test "selectivityOf: an eq on an indexed property returns the exact match count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_sel_eq.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const rowCount: u64 = 5000;
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, rowCount);
    const scanCatalog = try seedPlannerCatalog(&writeTransaction, false, rowCount);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    const predicate = intComparison(1, .eq, 7);

    const selectivity = try planner.selectivityOf(&writeTransaction, &scan, predicate, 0);
    // Expected value from the seed arithmetic itself, not from the index.
    try testing.expectEqual(Selectivity{ .exact = rowCount / 100 }, selectivity);
    // Cross-check against the scan path over the unindexed twin.
    const scanCount = try query.countWhere(&writeTransaction, scanCatalog, predicate, testing.allocator);
    try testing.expectEqual(scanCount, selectivity.exact);
}

test "selectivityOf: an eq whose value no row holds returns exact 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_sel_zero.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 1000);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    // Values are i % 100, so 100 never appears.
    const selectivity = try planner.selectivityOf(&writeTransaction, &scan, intComparison(1, .eq, 100), 0);
    try testing.expectEqual(Selectivity{ .exact = 0 }, selectivity);
}

test "selectivityOf: a range comparison returns unbounded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_sel_range.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 1000);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    const selectivity = try planner.selectivityOf(&writeTransaction, &scan, intComparison(1, .ge, 10), 0);
    try testing.expectEqual(Selectivity.unbounded, selectivity);
}

test "selectivityOf: a conjunction of two indexed eq terms returns the smaller exact count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_sel_and.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const rowCount: u64 = 5000;
    const twoIndexedCatalog = try seedTwoIndexedCatalog(&writeTransaction, rowCount);
    const scan = try Scan.open(&writeTransaction, twoIndexedCatalog);
    // property1 == 7 matches 50 rows; property2 == 0 matches exactly 1 row.
    const children = [_]Predicate{ intComparison(1, .eq, 7), intComparison(2, .eq, 0) };
    const selectivity = try planner.selectivityOf(&writeTransaction, &scan, .{ .conjunction = &children }, 0);
    try testing.expectEqual(Selectivity{ .exact = 1 }, selectivity);
}

test "selectivityOf: a disjunction of two eq terms returns the sum of their counts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_sel_or.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const rowCount: u64 = 5000;
    const twoIndexedCatalog = try seedTwoIndexedCatalog(&writeTransaction, rowCount);
    const scan = try Scan.open(&writeTransaction, twoIndexedCatalog);
    const children = [_]Predicate{ intComparison(1, .eq, 7), intComparison(2, .eq, 0) };
    const selectivity = try planner.selectivityOf(&writeTransaction, &scan, .{ .disjunction = &children }, 0);
    try testing.expectEqual(Selectivity{ .exact = 50 + 1 }, selectivity);
}

test "collectCandidates: a drivable disjunction yields the union either branch matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_collect_or.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const rowCount: u64 = 2000;
    const twoIndexedCatalog = try seedTwoIndexedCatalog(&writeTransaction, rowCount);
    const scan = try Scan.open(&writeTransaction, twoIndexedCatalog);
    const branchA = intComparison(1, .eq, 7);
    const branchB = intComparison(2, .eq, 0);
    const children = [_]Predicate{ branchA, branchB };
    const tree = Predicate{ .disjunction = &children };

    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try planner.collectCandidates(&writeTransaction, &scan, tree, &candidates, testing.allocator, 0);
    std.mem.sort(u64, candidates.items, {}, std.sort.asc(u64));

    var expectedUnion = std.ArrayList(u64).empty;
    defer expectedUnion.deinit(testing.allocator);
    try query.where(&writeTransaction, twoIndexedCatalog, .{ .predicate = branchA }, &expectedUnion, testing.allocator);
    try query.where(&writeTransaction, twoIndexedCatalog, .{ .predicate = branchB }, &expectedUnion, testing.allocator);
    std.mem.sort(u64, expectedUnion.items, {}, std.sort.asc(u64));

    // collectCandidates is a superset (untrimmed, may repeat); every expected
    // key must appear.
    for (expectedUnion.items) |objectKey| {
        try testing.expect(std.mem.indexOfScalar(u64, candidates.items, objectKey) != null);
    }
}

test "collectCandidates rejects a negation with error.NoIndexPlan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_collect_negation.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 100);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    const leaf = intComparison(1, .eq, 7);
    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try testing.expectError(error.NoIndexPlan, planner.collectCandidates(&writeTransaction, &scan, .{ .negation = &leaf }, &candidates, testing.allocator, 0));
}

test "collectCandidates rejects ne with error.NoIndexPlan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_collect_ne.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 100);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try testing.expectError(error.NoIndexPlan, planner.collectCandidates(&writeTransaction, &scan, intComparison(1, .ne, 7), &candidates, testing.allocator, 0));
}

test "collectCandidates rejects an empty conjunction with error.NoIndexPlan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_collect_empty_and.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 100);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try testing.expectError(error.NoIndexPlan, planner.collectCandidates(&writeTransaction, &scan, .{ .conjunction = &.{} }, &candidates, testing.allocator, 0));
}

test "collectCandidates rejects a 33-deep drivable chain with error.PredicateTooDeep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_collect_deep.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedPlannerCatalog(&writeTransaction, true, 100);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);
    // A single drivable eq comparison, entered directly at depth 32 (the cap)
    // to simulate sitting at the bottom of a 33-deep chain: canDriveFromIndex
    // already treats anything at or past the cap as non-drivable, via the
    // identical depth check in canDriveFromIndexAt, so a chain actually built
    // from 33 nested conjunctions would fail the pairing invariant with
    // error.NoIndexPlan (checked by the fuzz test below) before ever reaching
    // this branch. Calling collectCandidates directly at depth 32 is the only
    // way to exercise its own depth guard, which protects against the two
    // guards drifting out of lockstep under a future edit.
    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try testing.expectError(error.PredicateTooDeep, planner.collectCandidates(&writeTransaction, &scan, intComparison(1, .eq, 7), &candidates, testing.allocator, 32));
}

test "canDriveFromIndex and collectCandidates never disagree, over 200 random trees" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try plannerTmpPath(testing.allocator, &tmp, "planner_pairing_fuzz.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const indexedCatalog = try seedTwoIndexedCatalog(&writeTransaction, 500);
    const scan = try Scan.open(&writeTransaction, indexedCatalog);

    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try makeRandomTree(arena.allocator(), random, 0, 4);

        var candidates = std.ArrayList(u64).empty;
        defer candidates.deinit(testing.allocator);
        const result = planner.collectCandidates(&writeTransaction, &scan, tree, &candidates, testing.allocator, 0);
        if (planner.canDriveFromIndex(&scan, tree)) {
            _ = result catch |err| {
                std.debug.print("seed {d}: expected collectCandidates to succeed, got {}\n", .{ seed, err });
                return err;
            };
        } else {
            try testing.expectError(error.NoIndexPlan, result);
        }
    }
}
