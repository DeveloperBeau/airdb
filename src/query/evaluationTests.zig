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

test "matches over all six int operators, both directions, at equality and at value +/- 1" {
    try testing.expect(try evaluation.matches(.eq, 5, 5));
    try testing.expect(!(try evaluation.matches(.eq, 5, 4)));
    try testing.expect(!(try evaluation.matches(.eq, 5, 6)));

    try testing.expect(!(try evaluation.matches(.ne, 5, 5)));
    try testing.expect(try evaluation.matches(.ne, 5, 4));
    try testing.expect(try evaluation.matches(.ne, 5, 6));

    try testing.expect(!(try evaluation.matches(.lt, 5, 5)));
    try testing.expect(try evaluation.matches(.lt, 4, 5));
    try testing.expect(!(try evaluation.matches(.lt, 6, 5)));

    try testing.expect(try evaluation.matches(.le, 5, 5));
    try testing.expect(try evaluation.matches(.le, 4, 5));
    try testing.expect(!(try evaluation.matches(.le, 6, 5)));

    try testing.expect(!(try evaluation.matches(.gt, 5, 5)));
    try testing.expect(!(try evaluation.matches(.gt, 4, 5)));
    try testing.expect(try evaluation.matches(.gt, 6, 5));

    try testing.expect(try evaluation.matches(.ge, 5, 5));
    try testing.expect(!(try evaluation.matches(.ge, 4, 5)));
    try testing.expect(try evaluation.matches(.ge, 6, 5));
}

test "matches rejects beginsWith with error.UnsupportedPredicate" {
    try testing.expectError(error.UnsupportedPredicate, evaluation.matches(.beginsWith, 1, 1));
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

test "evaluatePredicate rejects a comparison carrying bytes with error.UnsupportedPredicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try evalTmpPath(testing.allocator, &tmp, "eval_bytes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try seed(&writeTransaction, &.{.{ 1, 30 }});
    const scan = try Scan.open(&writeTransaction, catalogReference);
    const predicate = Predicate{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .bytes = "x" } } };
    try testing.expectError(error.UnsupportedPredicate, evaluation.evaluatePredicate(&writeTransaction, &scan, 0, predicate));
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
