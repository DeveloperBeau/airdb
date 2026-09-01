// predicateTests.zig -- companion suite for predicate.zig: exhaustive Kleene
// tables and validation shapes, none of which need a database.

const std = @import("std");
const testing = std.testing;
const predicate = @import("predicate.zig");
const catalog = @import("../schema/catalog.zig");

const Match = predicate.Match;
const Predicate = predicate.Predicate;
const Comparison = predicate.Comparison;

test "maxPredicateDepth is pinned to 32" {
    try testing.expectEqual(@as(usize, 32), predicate.maxPredicateDepth);
}

test "conjoined truth table" {
    try testing.expectEqual(Match.matched, Match.conjoined(.matched, .matched));
    try testing.expectEqual(Match.unmatched, Match.conjoined(.matched, .unmatched));
    try testing.expectEqual(Match.unknown, Match.conjoined(.matched, .unknown));
    try testing.expectEqual(Match.unmatched, Match.conjoined(.unmatched, .matched));
    try testing.expectEqual(Match.unmatched, Match.conjoined(.unmatched, .unmatched));
    try testing.expectEqual(Match.unmatched, Match.conjoined(.unmatched, .unknown));
    try testing.expectEqual(Match.unknown, Match.conjoined(.unknown, .matched));
    try testing.expectEqual(Match.unmatched, Match.conjoined(.unknown, .unmatched));
    try testing.expectEqual(Match.unknown, Match.conjoined(.unknown, .unknown));
}

test "disjoined truth table" {
    try testing.expectEqual(Match.matched, Match.disjoined(.matched, .matched));
    try testing.expectEqual(Match.matched, Match.disjoined(.matched, .unmatched));
    try testing.expectEqual(Match.matched, Match.disjoined(.matched, .unknown));
    try testing.expectEqual(Match.matched, Match.disjoined(.unmatched, .matched));
    try testing.expectEqual(Match.unmatched, Match.disjoined(.unmatched, .unmatched));
    try testing.expectEqual(Match.unknown, Match.disjoined(.unmatched, .unknown));
    try testing.expectEqual(Match.matched, Match.disjoined(.unknown, .matched));
    try testing.expectEqual(Match.unknown, Match.disjoined(.unknown, .unmatched));
    try testing.expectEqual(Match.unknown, Match.disjoined(.unknown, .unknown));
}

test "negated table" {
    try testing.expectEqual(Match.unmatched, Match.negated(.matched));
    try testing.expectEqual(Match.matched, Match.negated(.unmatched));
    try testing.expectEqual(Match.unknown, Match.negated(.unknown));
}

test "conjoined and disjoined are commutative over every pair" {
    const values = [_]Match{ .matched, .unmatched, .unknown };
    for (values) |a| {
        for (values) |b| {
            try testing.expectEqual(Match.conjoined(a, b), Match.conjoined(b, a));
            try testing.expectEqual(Match.disjoined(a, b), Match.disjoined(b, a));
        }
    }
}

fn intComparison(property: usize, operator: predicate.Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

fn bytesComparison(property: usize, operator: predicate.Operator, value: []const u8) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .bytes = value } } };
}

const intKinds = [_]catalog.PropertyKind{ .int, .int, .blob };

// property0 = int, property1 = list, property2 = set, property3 = link,
// property4 = linkSet, property5 = dict. Used to check every non-scalar kind
// rejects an int comparison, and that link (a scalar-shaped reference) does not.
const everyKind = [_]catalog.PropertyKind{ .int, .list, .set, .link, .linkSet, .dict };

test "validate accepts well-formed trees" {
    // A bare int comparison on an int property.
    try (intComparison(0, .eq, 1)).validate(&intKinds);
    // A conjunction of two.
    const two = [_]Predicate{ intComparison(0, .eq, 1), intComparison(1, .ge, 2) };
    try (Predicate{ .conjunction = &two }).validate(&intKinds);
    // An empty conjunction.
    try (Predicate{ .conjunction = &.{} }).validate(&intKinds);
    // An empty disjunction.
    try (Predicate{ .disjunction = &.{} }).validate(&intKinds);
    // A negation of a comparison.
    const leaf = intComparison(0, .eq, 1);
    try (Predicate{ .negation = &leaf }).validate(&intKinds);
    // A chain of exactly 32 nested negations ending in a comparison.
    try validateDeepNegationChain(32, false);
}

fn validateDeepNegationChain(depth: usize, comptime expectTooDeep: bool) !void {
    var leaf = intComparison(0, .eq, 1);
    var level: usize = 0;
    while (level < depth - 1) : (level += 1) {
        const boxed = try testing.allocator.create(Predicate);
        boxed.* = leaf;
        leaf = .{ .negation = boxed };
    }
    defer {
        // Walk back and free every allocated negation node.
        var current = leaf;
        while (current == .negation) {
            const inner = current.negation;
            current = inner.*;
            testing.allocator.destroy(@as(*Predicate, @constCast(inner)));
        }
    }
    if (expectTooDeep) {
        try testing.expectError(error.PredicateTooDeep, leaf.validate(&intKinds));
    } else {
        try leaf.validate(&intKinds);
    }
}

test "validate rejects an out-of-range property index" {
    // Boundary: index len - 1 is accepted (false-positive control).
    try (intComparison(1, .eq, 1)).validate(&intKinds);
    // index == propertyKinds.len is rejected.
    try testing.expectError(error.BadProperty, (intComparison(3, .eq, 1)).validate(&intKinds));
}

test "validate rejects an out-of-range property nested inside negation inside conjunction" {
    const badLeaf = intComparison(3, .eq, 1);
    const negated = Predicate{ .negation = &badLeaf };
    const children = [_]Predicate{negated};
    const tree = Predicate{ .conjunction = &children };
    try testing.expectError(error.BadProperty, tree.validate(&intKinds));
}

test "validate rejects an int value against a blob property" {
    try testing.expectError(error.BadPredicate, (intComparison(2, .eq, 1)).validate(&intKinds));
}

test "validate rejects an int value against a list property" {
    try testing.expectError(error.BadPredicate, (intComparison(1, .eq, 1)).validate(&everyKind));
}

test "validate rejects an int value against a set property" {
    try testing.expectError(error.BadPredicate, (intComparison(2, .eq, 1)).validate(&everyKind));
}

test "validate rejects an int value against a linkSet property" {
    try testing.expectError(error.BadPredicate, (intComparison(4, .eq, 1)).validate(&everyKind));
}

test "validate rejects an int value against a dict property" {
    try testing.expectError(error.BadPredicate, (intComparison(5, .eq, 1)).validate(&everyKind));
}

test "validate accepts an int value against a link property, the one non-int scalar kind" {
    // False-positive control for the four rejections above: link is the kind
    // that must stay accepted (module doc: link properties compare as target
    // objectKey + 1), so the check must be a scalar allow-list, not a blanket
    // non-int rejection.
    try (intComparison(3, .eq, 1)).validate(&everyKind);
}

test "validate rejects a bytes value against an int property" {
    try testing.expectError(error.BadPredicate, (bytesComparison(0, .eq, "x")).validate(&intKinds));
}

test "validate rejects a bytes value against a blob property as unsupported, not malformed" {
    try testing.expectError(error.UnsupportedPredicate, (bytesComparison(2, .eq, "x")).validate(&intKinds));
}

test "validate rejects beginsWith against an int property" {
    try testing.expectError(error.BadPredicate, (intComparison(0, .beginsWith, 1)).validate(&intKinds));
}

test "validate rejects a chain of 33 nested negations" {
    try validateDeepNegationChain(33, true);
}

test "validate rejects a conjunction whose 33rd level holds a comparison" {
    var current = intComparison(0, .eq, 1);
    var level: usize = 0;
    // Wrap 32 times in a single-child conjunction so the comparison sits at depth 32.
    var boxedChildren = std.ArrayList([]const Predicate).empty;
    defer {
        for (boxedChildren.items) |slice| testing.allocator.free(slice);
        boxedChildren.deinit(testing.allocator);
    }
    while (level < 32) : (level += 1) {
        const slice = try testing.allocator.alloc(Predicate, 1);
        slice[0] = current;
        try boxedChildren.append(testing.allocator, slice);
        current = .{ .conjunction = slice };
    }
    try testing.expectError(error.PredicateTooDeep, current.validate(&intKinds));
}

test "validate fuzz: never panics, error is one of the named set, and validated trees hold no out-of-range property" {
    var acceptedCount: usize = 0;
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const tree = try makeRandomTree(arena.allocator(), random, 0, 5);
        const result = tree.validate(&intKinds);
        if (result) |_| {
            acceptedCount += 1;
            try expectNoOutOfRangeProperty(tree);
        } else |err| {
            switch (err) {
                error.BadProperty, error.BadPredicate, error.UnsupportedPredicate, error.PredicateTooDeep => {},
            }
        }
    }
    try testing.expect(acceptedCount > 0);
}

fn expectNoOutOfRangeProperty(tree: Predicate) !void {
    switch (tree) {
        .comparison => |comparison| try testing.expect(comparison.property < intKinds.len),
        .conjunction, .disjunction => |children| for (children) |child| try expectNoOutOfRangeProperty(child),
        .negation => |child| try expectNoOutOfRangeProperty(child.*),
    }
}

fn makeRandomTree(allocator: std.mem.Allocator, random: std.Random, depth: usize, maxDepth: usize) !Predicate {
    const kind = if (depth >= maxDepth) 0 else random.intRangeLessThan(u8, 0, 4);
    switch (kind) {
        0 => {
            const property = random.intRangeLessThan(usize, 0, intKinds.len + 1);
            const operator: predicate.Operator = @enumFromInt(random.intRangeLessThan(u8, 0, 7));
            const valueIsBytes = random.boolean();
            const value: predicate.ComparisonValue = if (valueIsBytes) .{ .bytes = "probe" } else .{ .int = random.int(u64) };
            return .{ .comparison = .{ .property = property, .operator = operator, .value = value } };
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
