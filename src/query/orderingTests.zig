//! Test suite for ordering.zig: pure types, the sort comparator, and
//! Request.validate. No database, no I/O.

const std = @import("std");
const testing = std.testing;
const catalog = @import("../schema/catalog.zig");
const predicateLanguage = @import("predicate.zig");
const Predicate = predicateLanguage.Predicate;
const scanModule = @import("scan.zig");
const Scan = scanModule.Scan;
const ordering = @import("ordering.zig");
const SortOrder = ordering.SortOrder;
const SortKey = ordering.SortKey;
const Ordering = ordering.Ordering;
const Page = ordering.Page;
const PageStart = ordering.PageStart;
const Cursor = ordering.Cursor;
const Request = ordering.Request;
const SortEntry = ordering.SortEntry;
const isOrderedBefore = ordering.isOrderedBefore;

// A Scan with three properties: 0 = int, 1 = blob, 2 = link. Property 0 is
// indexed, the others are not, except where a test overrides scan.indexed
// directly (Scan is a plain struct, no I/O needed to build one for validate).
fn makeScan(propertyKinds: []const catalog.PropertyKind, indexed: []const bool) Scan {
    var scan: Scan = undefined;
    scan.propertyCount = propertyKinds.len;
    for (propertyKinds, 0..) |kind, propertyIndex| {
        scan.propertyKinds[propertyIndex] = kind;
        scan.indexed[propertyIndex] = indexed[propertyIndex];
        scan.propertyReferences[propertyIndex] = 0;
        scan.valueIndexReferences[propertyIndex] = 0;
    }
    scan.liveColumnReference = 0;
    scan.keyToRowIndexReference = 0;
    return scan;
}

test "O1: a default request is every live row, objectKey ascending, offset zero, no limit" {
    const request = Request{};
    try testing.expectEqual(SortKey.objectKey, request.ordering.sortKey);
    try testing.expectEqual(SortOrder.ascending, request.ordering.order);
    try testing.expectEqual(PageStart{ .offset = 0 }, request.page.start);
    try testing.expectEqual(@as(?u64, null), request.page.limit);
    switch (request.predicate) {
        .conjunction => |children| try testing.expectEqual(@as(usize, 0), children.len),
        else => try testing.expect(false),
    }
}

test "O2: isOrderedBefore orders by value, then by objectKey" {
    try testing.expect(isOrderedBefore(.ascending, .{ .value = 1, .objectKey = 9 }, .{ .value = 2, .objectKey = 0 }));
    try testing.expect(isOrderedBefore(.ascending, .{ .value = 2, .objectKey = 3 }, .{ .value = 2, .objectKey = 4 }));
    // False positive guard: the reverse must not also hold.
    try testing.expect(!isOrderedBefore(.ascending, .{ .value = 2, .objectKey = 0 }, .{ .value = 1, .objectKey = 9 }));
}

test "O3: descending is the exact reverse of ascending, ties included" {
    const entries = [_]SortEntry{
        .{ .value = 5, .objectKey = 1 },
        .{ .value = 3, .objectKey = 2 },
        .{ .value = 3, .objectKey = 1 },
        .{ .value = 9, .objectKey = 0 },
        .{ .value = 3, .objectKey = 5 },
        .{ .value = 1, .objectKey = 4 },
    };
    var ascending = entries;
    std.mem.sort(SortEntry, &ascending, SortOrder.ascending, isOrderedBefore);
    var descending = entries;
    std.mem.sort(SortEntry, &descending, SortOrder.descending, isOrderedBefore);

    var reversedAscending: [6]SortEntry = undefined;
    for (ascending, 0..) |entry, index| reversedAscending[ascending.len - 1 - index] = entry;
    try testing.expectEqualSlices(SortEntry, &reversedAscending, &descending);
}

test "O4: a sort property past the property count is error.BadProperty" {
    const kinds = [_]catalog.PropertyKind{.int};
    const indexed = [_]bool{true};
    const scan = makeScan(&kinds, &indexed);
    const request = Request{ .ordering = .{ .sortKey = .{ .property = 1 } } };
    try testing.expectError(error.BadProperty, request.validate(&scan));
}

test "O5: a blob sort property is error.UnsupportedOrdering" {
    const kinds = [_]catalog.PropertyKind{ .int, .blob };
    const indexed = [_]bool{ true, false };
    const scan = makeScan(&kinds, &indexed);
    const request = Request{ .ordering = .{ .sortKey = .{ .property = 1 } } };
    try testing.expectError(error.UnsupportedOrdering, request.validate(&scan));
}

test "O6: each collection kind as a sort property is error.UnsupportedOrdering" {
    const collectionKinds = [_]catalog.PropertyKind{ .list, .set, .linkSet, .dict };
    for (collectionKinds) |collectionKind| {
        const kinds = [_]catalog.PropertyKind{ .int, collectionKind };
        const indexed = [_]bool{ true, false };
        const scan = makeScan(&kinds, &indexed);
        const request = Request{ .ordering = .{ .sortKey = .{ .property = 1 } } };
        try testing.expectError(error.UnsupportedOrdering, request.validate(&scan));
    }
}

test "O7: validate accepts an int sort property and a link sort property" {
    const kinds = [_]catalog.PropertyKind{ .int, .link };
    const indexed = [_]bool{ true, true };
    const scan = makeScan(&kinds, &indexed);
    try (Request{ .ordering = .{ .sortKey = .{ .property = 0 } } }).validate(&scan);
    try (Request{ .ordering = .{ .sortKey = .{ .property = 1 } } }).validate(&scan);
}

test "O8: a cursor with an unindexed sort property is error.CursorRequiresIndexedSort" {
    const kinds = [_]catalog.PropertyKind{ .int, .int };
    const indexed = [_]bool{ true, false };
    const scan = makeScan(&kinds, &indexed);
    const cursor = Cursor{ .lastValue = 5, .lastObjectKey = 5 };
    // Must NOT fire for an indexed sort property with a cursor.
    try (Request{ .ordering = .{ .sortKey = .{ .property = 0 } }, .page = .{ .start = .{ .after = cursor } } }).validate(&scan);
    // MUST fire for the unindexed one.
    try testing.expectError(
        error.CursorRequiresIndexedSort,
        (Request{ .ordering = .{ .sortKey = .{ .property = 1 } }, .page = .{ .start = .{ .after = cursor } } }).validate(&scan),
    );
}

test "O9: validate accepts a cursor with objectKey ordering over an unindexed type" {
    const kinds = [_]catalog.PropertyKind{.int};
    const indexed = [_]bool{false};
    const scan = makeScan(&kinds, &indexed);
    const cursor = Cursor{ .lastValue = 5, .lastObjectKey = 5 };
    try (Request{ .page = .{ .start = .{ .after = cursor } } }).validate(&scan);
}

test "O11: a malformed predicate is still rejected through Request.validate" {
    const kinds = [_]catalog.PropertyKind{.int};
    const indexed = [_]bool{true};
    const scan = makeScan(&kinds, &indexed);
    const badPredicate = Predicate{ .comparison = .{ .property = 9, .operator = .eq, .value = .{ .int = 1 } } };
    const request = Request{ .predicate = badPredicate };
    try testing.expectError(error.BadProperty, request.validate(&scan));
}

test "O10: isOrderedBefore is a strict total order, fuzzed" {
    var seed: u64 = 0;
    while (seed < 5000) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        const domain = [_]u64{ 0, 1, std.math.maxInt(u64) };
        const drawValue = struct {
            fn draw(innerRandom: std.Random, boostedDomain: []const u64) u64 {
                if (innerRandom.intRangeLessThan(u32, 0, 5) == 0) return boostedDomain[innerRandom.intRangeLessThan(usize, 0, boostedDomain.len)];
                return innerRandom.int(u64);
            }
        }.draw;
        const first = SortEntry{ .value = drawValue(random, &domain), .objectKey = drawValue(random, &domain) };
        const second = SortEntry{ .value = drawValue(random, &domain), .objectKey = drawValue(random, &domain) };
        const third = SortEntry{ .value = drawValue(random, &domain), .objectKey = drawValue(random, &domain) };

        inline for ([_]SortOrder{ .ascending, .descending }) |order| {
            // Irreflexive.
            try testing.expect(!isOrderedBefore(order, first, first));
            // Asymmetric.
            if (isOrderedBefore(order, first, second)) try testing.expect(!isOrderedBefore(order, second, first));
            // Transitive.
            if (isOrderedBefore(order, first, second) and isOrderedBefore(order, second, third)) {
                try testing.expect(isOrderedBefore(order, first, third));
            }
        }
    }
}
