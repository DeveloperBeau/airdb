// evaluationTests.zig -- companion suite for evaluation.zig. Exists because
// evaluation.zig is reachable from the test file directly, which is how the
// two branches unreachable through the public query API get covered.

const std = @import("std");
const testing = std.testing;
const evaluation = @import("evaluation.zig");
const predicateModule = @import("predicate.zig");
const Scan = @import("scan.zig").Scan;
const catalog = @import("../schema/catalog.zig");
const rows = @import("../records/rows.zig");
const objects = @import("../records/objects.zig");
const Column = @import("../trees/column.zig");
const Database = @import("../database.zig").Database;
const Reference = @import("../storage/reference.zig").Reference;

const Predicate = predicateModule.Predicate;
const Match = predicateModule.Match;

fn evalTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: predicateModule.Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// primaryKey(property 0) + age(property 1).
fn seed(writeTransaction: anytype, pairs: []const [2]u64) !Reference {
    var catalogReference = try catalog.create(writeTransaction, 2);
    for (pairs) |pair| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ pair[0], pair[1] })).catalogReference;
    return catalogReference;
}

fn bytesComparison(property: usize, operator: predicateModule.Operator, value: []const u8) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .bytes = value } } };
}

// primaryKey(property 0, int) + value(property 1, blob). One row.
fn seedBlobRow(writeTransaction: *@import("../database.zig").WriteTransaction, primaryKey: u64, bytes: []const u8) !Reference {
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob } };
    const catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    const inserted = try objects.insertTyped(writeTransaction, catalogReference, &.{ .{ .int = primaryKey }, .{ .bytes = bytes } });
    return inserted.catalogReference;
}

test "T-E3: matchesInt over all six int operators, both directions, at equality and at value +/- 1" {
    try testing.expect(try evaluation.matchesInt(.eq, 5, 5));
    try testing.expect(!(try evaluation.matchesInt(.eq, 5, 4)));
    try testing.expect(!(try evaluation.matchesInt(.eq, 5, 6)));

    try testing.expect(!(try evaluation.matchesInt(.ne, 5, 5)));
    try testing.expect(try evaluation.matchesInt(.ne, 5, 4));
    try testing.expect(try evaluation.matchesInt(.ne, 5, 6));

    try testing.expect(!(try evaluation.matchesInt(.lt, 5, 5)));
    try testing.expect(try evaluation.matchesInt(.lt, 4, 5));
    try testing.expect(!(try evaluation.matchesInt(.lt, 6, 5)));

    try testing.expect(try evaluation.matchesInt(.le, 5, 5));
    try testing.expect(try evaluation.matchesInt(.le, 4, 5));
    try testing.expect(!(try evaluation.matchesInt(.le, 6, 5)));

    try testing.expect(!(try evaluation.matchesInt(.gt, 5, 5)));
    try testing.expect(!(try evaluation.matchesInt(.gt, 4, 5)));
    try testing.expect(try evaluation.matchesInt(.gt, 6, 5));

    try testing.expect(try evaluation.matchesInt(.ge, 5, 5));
    try testing.expect(!(try evaluation.matchesInt(.ge, 4, 5)));
    try testing.expect(try evaluation.matchesInt(.ge, 6, 5));
}

test "matchesInt rejects beginsWith with error.UnsupportedPredicate" {
    try testing.expectError(error.UnsupportedPredicate, evaluation.matchesInt(.beginsWith, 1, 1));
}

test "T-E1: matchesOrder truth table over all six order-comparing operators and three orders" {
    // eq
    try testing.expect(try evaluation.matchesOrder(.eq, .eq));
    try testing.expect(!(try evaluation.matchesOrder(.eq, .lt)));
    try testing.expect(!(try evaluation.matchesOrder(.eq, .gt)));
    // ne
    try testing.expect(!(try evaluation.matchesOrder(.ne, .eq)));
    try testing.expect(try evaluation.matchesOrder(.ne, .lt));
    try testing.expect(try evaluation.matchesOrder(.ne, .gt));
    // lt
    try testing.expect(!(try evaluation.matchesOrder(.lt, .eq)));
    try testing.expect(try evaluation.matchesOrder(.lt, .lt));
    try testing.expect(!(try evaluation.matchesOrder(.lt, .gt)));
    // le
    try testing.expect(try evaluation.matchesOrder(.le, .eq));
    try testing.expect(try evaluation.matchesOrder(.le, .lt));
    try testing.expect(!(try evaluation.matchesOrder(.le, .gt)));
    // gt
    try testing.expect(!(try evaluation.matchesOrder(.gt, .eq)));
    try testing.expect(!(try evaluation.matchesOrder(.gt, .lt)));
    try testing.expect(try evaluation.matchesOrder(.gt, .gt));
    // ge
    try testing.expect(try evaluation.matchesOrder(.ge, .eq));
    try testing.expect(!(try evaluation.matchesOrder(.ge, .lt)));
    try testing.expect(try evaluation.matchesOrder(.ge, .gt));
}

test "T-E2: matchesOrder rejects beginsWith with error.UnsupportedPredicate" {
    try testing.expectError(error.UnsupportedPredicate, evaluation.matchesOrder(.beginsWith, .eq));
}

test "evaluatePredicate returns matched or unmatched, never unknown, for every tree shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_shapes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const scan = try Scan.open(&writeTransaction, catalogReference);
    const row: u64 = 0;

    // Comparison.
    try testing.expectEqual(Match.matched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, intComparison(1, .eq, 30)));
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, intComparison(1, .eq, 99)));

    // Empty conjunction is vacuously matched.
    try testing.expectEqual(Match.matched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, .{ .conjunction = &.{} }));

    // Empty disjunction matches nothing.
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, .{ .disjunction = &.{} }));

    // Nested negation.
    const leaf = intComparison(1, .eq, 30);
    const innerNegation = Predicate{ .negation = &leaf };
    const outerNegation = Predicate{ .negation = &innerNegation };
    try testing.expectEqual(Match.matched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, outerNegation));
}

test "isLiveMatch is true before delete and false after, for the same still-matching predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_live.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    var catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const predicate = intComparison(1, .eq, 30);
    const row: u64 = 0;

    // False positive control: true before the delete.
    const scanBeforeDelete = try Scan.open(&writeTransaction, catalogReference);
    try testing.expect(try evaluation.isLiveMatch(&writeTransaction, &scanBeforeDelete, row, predicate));

    var out: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 1, version)).ok;

    // The predicate over the stored values still matches; only liveness changed.
    const scanAfterDelete = try Scan.open(&writeTransaction, catalogReference);
    try testing.expect(!(try evaluation.isLiveMatch(&writeTransaction, &scanAfterDelete, row, predicate)));
}

test "T-E4: matchesBytes against a real blob column, all seven operators" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_bytes_banana.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedBlobRow(&writeTransaction, 1, "banana");
    const scan = try Scan.open(&writeTransaction, catalogReference);
    const row: u64 = 0;

    const Case = struct { operator: predicateModule.Operator, probe: []const u8, expected: bool };
    // Stored value is "banana". Each expectation is hand-written against the
    // ordinary meaning of the operator over that fixed value.
    const cases = [_]Case{
        .{ .operator = .eq, .probe = "apple", .expected = false },
        .{ .operator = .eq, .probe = "banana", .expected = true },
        .{ .operator = .eq, .probe = "cherry", .expected = false },
        .{ .operator = .eq, .probe = "ban", .expected = false },
        .{ .operator = .eq, .probe = "", .expected = false },

        .{ .operator = .ne, .probe = "apple", .expected = true },
        .{ .operator = .ne, .probe = "banana", .expected = false },
        .{ .operator = .ne, .probe = "cherry", .expected = true },
        .{ .operator = .ne, .probe = "ban", .expected = true },
        .{ .operator = .ne, .probe = "", .expected = true },

        .{ .operator = .lt, .probe = "apple", .expected = false },
        .{ .operator = .lt, .probe = "banana", .expected = false },
        .{ .operator = .lt, .probe = "cherry", .expected = true },
        .{ .operator = .lt, .probe = "ban", .expected = false },
        .{ .operator = .lt, .probe = "", .expected = false },

        .{ .operator = .le, .probe = "apple", .expected = false },
        .{ .operator = .le, .probe = "banana", .expected = true },
        .{ .operator = .le, .probe = "cherry", .expected = true },
        .{ .operator = .le, .probe = "ban", .expected = false },
        .{ .operator = .le, .probe = "", .expected = false },

        .{ .operator = .gt, .probe = "apple", .expected = true },
        .{ .operator = .gt, .probe = "banana", .expected = false },
        .{ .operator = .gt, .probe = "cherry", .expected = false },
        .{ .operator = .gt, .probe = "ban", .expected = true },
        .{ .operator = .gt, .probe = "", .expected = true },

        .{ .operator = .ge, .probe = "apple", .expected = true },
        .{ .operator = .ge, .probe = "banana", .expected = true },
        .{ .operator = .ge, .probe = "cherry", .expected = false },
        .{ .operator = .ge, .probe = "ban", .expected = true },
        .{ .operator = .ge, .probe = "", .expected = true },

        .{ .operator = .beginsWith, .probe = "apple", .expected = false },
        .{ .operator = .beginsWith, .probe = "banana", .expected = true },
        .{ .operator = .beginsWith, .probe = "cherry", .expected = false },
        .{ .operator = .beginsWith, .probe = "ban", .expected = true },
        .{ .operator = .beginsWith, .probe = "", .expected = true },
    };
    for (cases) |case| {
        const predicate = bytesComparison(1, case.operator, case.probe);
        const expected: Match = if (case.expected) .matched else .unmatched;
        try testing.expectEqual(expected, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, predicate));
    }
}

test "T-E5: the empty-string row (null-reference column word), per the D1 table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_bytes_empty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedBlobRow(&writeTransaction, 1, "");
    const scan = try Scan.open(&writeTransaction, catalogReference);
    const row: u64 = 0;

    // The column word for an empty blob is the null reference (0).
    try testing.expectEqual(@as(u64, 0), try Column.get(&writeTransaction, scan.propertyReferences[1], row));

    const Case = struct { operator: predicateModule.Operator, probe: []const u8, expected: bool };
    const cases = [_]Case{
        .{ .operator = .eq, .probe = "", .expected = true },
        .{ .operator = .eq, .probe = "a", .expected = false },
        .{ .operator = .ne, .probe = "", .expected = false },
        .{ .operator = .ne, .probe = "a", .expected = true },
        .{ .operator = .lt, .probe = "", .expected = false },
        .{ .operator = .lt, .probe = "a", .expected = true },
        .{ .operator = .le, .probe = "", .expected = true },
        .{ .operator = .le, .probe = "a", .expected = true },
        .{ .operator = .gt, .probe = "", .expected = false },
        .{ .operator = .gt, .probe = "a", .expected = false },
        .{ .operator = .ge, .probe = "", .expected = true },
        .{ .operator = .ge, .probe = "a", .expected = false },
        .{ .operator = .beginsWith, .probe = "", .expected = true },
        .{ .operator = .beginsWith, .probe = "a", .expected = false },
    };
    for (cases) |case| {
        const predicate = bytesComparison(1, case.operator, case.probe);
        const expected: Match = if (case.expected) .matched else .unmatched;
        try testing.expectEqual(expected, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, predicate));
    }
}

test "T-E6: evaluatePredicate reaches matchesBytes through negation and conjunction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_bytes_tree.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seedBlobRow(&writeTransaction, 1, "banana");
    const scan = try Scan.open(&writeTransaction, catalogReference);
    const row: u64 = 0;

    // Bare comparison, matched and unmatched.
    try testing.expectEqual(Match.matched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, bytesComparison(1, .eq, "banana")));
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, bytesComparison(1, .eq, "apple")));

    // Negation of a bytes comparison.
    const leaf = bytesComparison(1, .eq, "banana");
    const negated = Predicate{ .negation = &leaf };
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, negated));

    // Conjunction mixing an int and a bytes comparison.
    const children = [_]Predicate{ intComparison(0, .eq, 1), bytesComparison(1, .beginsWith, "ban") };
    const conjunction = Predicate{ .conjunction = &children };
    try testing.expectEqual(Match.matched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, conjunction));

    const mismatchedChildren = [_]Predicate{ intComparison(0, .eq, 99), bytesComparison(1, .beginsWith, "ban") };
    const mismatchedConjunction = Predicate{ .conjunction = &mismatchedChildren };
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, row, mismatchedConjunction));
}

test "evaluatePredicate rejects a 33-deep tree with error.PredicateTooDeep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_deep.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const scan = try Scan.open(&writeTransaction, catalogReference);

    var leaf = intComparison(1, .eq, 30);
    var boxes: [33]Predicate = undefined;
    var level: usize = 0;
    while (level < 33) : (level += 1) {
        boxes[level] = leaf;
        leaf = .{ .negation = &boxes[level] };
    }
    try testing.expectError(error.PredicateTooDeep, evaluation.evaluatePredicate(&writeTransaction, &scan, 0, leaf));
}

test "evaluatePredicate succeeds on a tree with the comparison at exactly depth 31, the deepest depth the cap allows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_deep_boundary_ok.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const scan = try Scan.open(&writeTransaction, catalogReference);

    var leaf = intComparison(1, .eq, 30);
    var boxes: [31]Predicate = undefined;
    var level: usize = 0;
    while (level < 31) : (level += 1) {
        boxes[level] = leaf;
        leaf = .{ .negation = &boxes[level] };
    }
    // 31 negations put the comparison at depth 31, one short of the 32 cap: this must
    // evaluate normally, not error. An odd number of negations flips a match to unmatched.
    try testing.expectEqual(Match.unmatched, try evaluation.evaluatePredicate(&writeTransaction, &scan, 0, leaf));
}

test "evaluatePredicate rejects a tree with the comparison at exactly depth 32, one level past the cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_deep_boundary_fail.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const scan = try Scan.open(&writeTransaction, catalogReference);

    var leaf = intComparison(1, .eq, 30);
    var boxes: [32]Predicate = undefined;
    var level: usize = 0;
    while (level < 32) : (level += 1) {
        boxes[level] = leaf;
        leaf = .{ .negation = &boxes[level] };
    }
    // 32 negations put the comparison at exactly depth 32: the cap must fire there, not
    // one level later as it would if this boundary were off by one.
    try testing.expectError(error.PredicateTooDeep, evaluation.evaluatePredicate(&writeTransaction, &scan, 0, leaf));
}
