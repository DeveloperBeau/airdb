//! Query engine over an object catalog. Operates on the stable object key (objectKey)
//! space: a scan walks the per-type key->row index, so each entry maps an objectKey to
//! the physical row that currently holds its data (rows can move via relocation).
//! Predicates compare the raw u64 stored in a property column, so they apply to
//! int properties and to link properties (which store target objectKey + 1). Blob and
//! collection predicates are a later addition.
//!
//! Results are object keys (objectKeys); materialize them with
//! objects.getTypedByObjectKey. The fetch model is stale-snapshot: a query reads one
//! committed snapshot and returns detached keys, never live cursors.

const std = @import("std");
const catalog = @import("schema/catalog.zig");
const index = @import("trees/index.zig");
const Column = @import("trees/column.zig");
const Reference = @import("storage/reference.zig").Reference;
const Scan = @import("query/scan.zig").Scan;
const evaluation = @import("query/evaluation.zig");
const planner = @import("query/planner.zig");
const predicateLanguage = @import("query/predicate.zig");

/// A filter tree over a type's properties.
pub const Predicate = predicateLanguage.Predicate;
/// Comparison a predicate applies to one property's value.
pub const Operator = predicateLanguage.Operator;
/// The right-hand side of a comparison: a raw u64 for int and link properties,
/// or bytes for blob properties.
pub const ComparisonValue = predicateLanguage.ComparisonValue;
/// One filter clause: property `property` compared against `value` with `operator`.
pub const Comparison = predicateLanguage.Comparison;
/// Three-valued outcome of evaluating a predicate against one row.
pub const Match = predicateLanguage.Match;
/// Deepest predicate nesting accepted. Predicates are caller-supplied and will
/// eventually arrive across the C ABI, which is an untrusted boundary.
pub const maxPredicateDepth = predicateLanguage.maxPredicateDepth;

/// Run a query: stream every live matching (objectKey, row) pair into
/// `onMatch(context, objectKey, row)`. With a driving predicate the candidate
/// set comes from that property's value index (bounded by its selectivity, so
/// a temporary candidate buffer is fine); the full-scan path streams the
/// key->row index directly and evaluates each row inside the traversal, so no
/// O(live) buffer is ever materialized.
fn runQuery(
    transaction: anytype,
    scan: *const Scan,
    predicate: Predicate,
    allocator: std.mem.Allocator,
    context: anytype,
    comptime onMatch: fn (@TypeOf(context), u64, u64) anyerror!void,
) !void {
    if (planner.canDriveFromIndex(scan, predicate)) {
        var candidates = std.ArrayList(u64).empty;
        defer candidates.deinit(allocator);
        try planner.collectCandidates(transaction, scan, predicate, &candidates, allocator, 0);
        std.mem.sort(u64, candidates.items, {}, std.sort.asc(u64));
        var previousCandidate: ?u64 = null;
        for (candidates.items) |objectKey| {
            if (previousCandidate != null and previousCandidate.? == objectKey) continue;
            previousCandidate = objectKey;
            const row = (try index.get(transaction, scan.keyToRowIndexReference, objectKey)) orelse continue;
            if (try evaluation.isLiveMatch(transaction, scan, row, predicate)) try onMatch(context, objectKey, row);
        }
        return;
    }
    const Stream = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        inner: @TypeOf(context),
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if (try evaluation.isLiveMatch(self.transaction, self.scan, row, self.predicate)) try onMatch(self.inner, objectKey, row);
        }
    };
    try index.forEachEntry(transaction, scan.keyToRowIndexReference, Stream{
        .transaction = transaction,
        .scan = scan,
        .predicate = predicate,
        .inner = context,
    }, Stream.onEntry);
}

/// Append the objectKeys of every live row satisfying `predicate` to `out`, in
/// ascending objectKey order. `out` grows with `allocator` and the caller owns
/// it. Drives off a value index when the tree allows one; otherwise a full scan
/// over the live set (O(n) tree walks). A driving term that matches most rows
/// materializes a candidate list proportional to its match count; bounded
/// delivery is future work.
pub fn where(
    transaction: anytype,
    catalogReference: Reference,
    predicate: Predicate,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const scan = try Scan.open(transaction, catalogReference);
    try predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
    const Sink = struct {
        out: *std.ArrayList(u64),
        allocator: std.mem.Allocator,
        fn onMatch(self: @This(), objectKey: u64, _: u64) anyerror!void {
            try self.out.append(self.allocator, objectKey);
        }
    };
    try runQuery(transaction, &scan, predicate, allocator, Sink{ .out = out, .allocator = allocator }, Sink.onMatch);
}

/// Number of live rows satisfying `predicate`. The full-scan path streams,
/// so this allocates nothing proportional to the table; still O(n) over the
/// live set without a usable value index.
pub fn countWhere(
    transaction: anytype,
    catalogReference: Reference,
    predicate: Predicate,
    allocator: std.mem.Allocator,
) !u64 {
    const scan = try Scan.open(transaction, catalogReference);
    try predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
    var rowCount: u64 = 0;
    const Sink = struct {
        rowCount: *u64,
        fn onMatch(self: @This(), _: u64, _: u64) anyerror!void {
            self.rowCount.* += 1;
        }
    };
    try runQuery(transaction, &scan, predicate, allocator, Sink{ .rowCount = &rowCount }, Sink.onMatch);
    return rowCount;
}

/// The result of aggregateInt: matched-row count, wrapping sum, and the min/max
/// values (null when no row matched).
pub const Aggregate = struct { count: u64, sum: u64, min: ?u64, max: ?u64 };

/// Aggregate int property `property` over the live rows satisfying `predicate`.
/// `sum` wraps on overflow; min/max are null when no row matches. O(n) over the
/// live set without a usable value index.
pub fn aggregateInt(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    predicate: Predicate,
    allocator: std.mem.Allocator,
) !Aggregate {
    const scan = try Scan.open(transaction, catalogReference);
    try predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
    if (property >= scan.propertyCount) return error.BadProperty;
    var agg = Aggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    const Sink = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        property: usize,
        agg: *Aggregate,
        fn onMatch(self: @This(), _: u64, row: u64) anyerror!void {
            const value = try Column.get(self.transaction, self.scan.propertyReferences[self.property], row);
            self.agg.count += 1;
            self.agg.sum +%= value;
            if (self.agg.min == null or value < self.agg.min.?) self.agg.min = value;
            if (self.agg.max == null or value > self.agg.max.?) self.agg.max = value;
        }
    };
    try runQuery(transaction, &scan, predicate, allocator, Sink{ .transaction = transaction, .scan = &scan, .property = property, .agg = &agg }, Sink.onMatch);
    return agg;
}

/// Append the objectKeys whose property `property` lies in the inclusive range
/// [low, high] to `out`. A conjunction of two bound comparisons, so it takes
/// whichever path the planner picks for that tree.
pub fn rangeInclusive(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    low: u64,
    high: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const bounds = [_]Predicate{
        .{ .comparison = .{ .property = property, .operator = .ge, .value = .{ .int = low } } },
        .{ .comparison = .{ .property = property, .operator = .le, .value = .{ .int = high } } },
    };
    try where(transaction, catalogReference, .{ .conjunction = &bounds }, out, allocator);
}

/// Sort a slice of objectKeys in place by int property `property`, ascending.
/// Reads each row's value once into a temporary pair array (allocated from
/// `allocator`, freed before returning), then sorts: O(k log k) plus a tree
/// walk per key. A key that no longer resolves is error.NotFound.
pub fn sortByPropertyAscending(
    transaction: anytype,
    catalogReference: Reference,
    objectKeys: []u64,
    property: usize,
    allocator: std.mem.Allocator,
) !void {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    if (property >= view.propertyCount) return error.BadProperty;
    const column = view.propertyColumnReference(property);
    const SortPair = struct { value: u64, key: u64 };
    const pairs = try allocator.alloc(SortPair, objectKeys.len);
    defer allocator.free(pairs);
    for (objectKeys, 0..) |key, rowIndex| {
        // A caller-supplied objectKey that no longer resolves (stale or deleted) is
        // an input error, not a crash.
        const row = (try catalog.objectKeyToRow(transaction, catalogReference, key)) orelse return error.NotFound;
        pairs[rowIndex] = .{ .value = try Column.get(transaction, column, row), .key = key };
    }
    std.mem.sort(SortPair, pairs, {}, struct {
        fn lessThan(_: void, left: SortPair, right: SortPair) bool {
            return left.value < right.value;
        }
    }.lessThan);
    for (pairs, 0..) |pair, rowIndex| objectKeys[rowIndex] = pair.key;
}

test {
    _ = @import("queryTests.zig");
    _ = @import("queryDifferentialTests.zig");
}
