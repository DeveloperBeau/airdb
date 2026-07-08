const std = @import("std");
const rows = @import("records/rows.zig");
const catalog = @import("schema/catalog.zig");
const index = @import("trees/index.zig");
const Column = @import("trees/column.zig");
const Reference = @import("storage/reference.zig").Reference;

// Query engine over an object catalog. Operates on the stable object key (objectKey)
// space: a scan walks the per-type key->row index, so each entry maps an objectKey to
// the physical row that currently holds its data (rows can move via relocation).
// Predicates compare the raw u64 stored in a property column, so they apply to
// int properties and to link properties (which store target objectKey + 1). Blob and
// collection predicates are a later addition.
//
// Results are object keys (objectKeys); materialize them with
// objects.getTypedByObjectKey. The fetch model is stale-snapshot: a query reads one
// committed snapshot and returns detached keys, never live cursors.

const MAX_PROPS: usize = 256;

pub const Operator = enum { eq, ne, lt, le, gt, ge };

pub const Predicate = struct {
    property: usize,
    operator: Operator,
    value: u64,
};

fn matches(operator: Operator, lhs: u64, rhs: u64) bool {
    return switch (operator) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .le => lhs <= rhs,
        .gt => lhs > rhs,
        .ge => lhs >= rhs,
    };
}

// Snapshot of the column refs a scan needs: all property columns, the live
// column, and the key->row index. Captured into locals so no catalog deref slice
// is held across reads.
const Scan = struct {
    propertyRefs: [MAX_PROPS]Reference,
    // Per-property: whether the property has a value index, and the ref of that
    // index. Captured so the planner can drive a query off the index without a
    // second catalog deref.
    indexed: [MAX_PROPS]bool,
    valueIndexRefs: [MAX_PROPS]Reference,
    propertyCount: usize,
    liveRef: Reference,
    keyrowIndexRef: Reference,
    nextRow: u64,
};

fn openScan(transaction: anytype, catalogRef: Reference) !Scan {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    var scan: Scan = undefined;
    scan.propertyCount = view.propertyCount;
    scan.liveRef = view.liveColRef;
    scan.keyrowIndexRef = view.keyrowIndexRef;
    scan.nextRow = view.nextRow;
    var propertyIndex: usize = 0;
    while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
        scan.propertyRefs[propertyIndex] = view.propertyColumnRef(propertyIndex);
        scan.indexed[propertyIndex] = view.indexed(propertyIndex);
        scan.valueIndexRefs[propertyIndex] = view.valueIndexRef(propertyIndex);
    }
    return scan;
}

// A keyrow entry is live unless its row is tombstoned. `delete` removes the
// object key from the key->row index, so the current snapshot's index never
// holds a stale key that could alias a relocated row; the live check is the
// only filter needed.
fn rowMatches(transaction: anytype, scan: *const Scan, row: u64, predicates: []const Predicate) !bool {
    for (predicates) |predicate| {
        const raw = try Column.get(transaction, scan.propertyRefs[predicate.property], row);
        if (!matches(predicate.operator, raw, predicate.value)) return false;
    }
    return true;
}

// Full row evaluation: live check plus every predicate (logical AND).
fn evalRow(transaction: anytype, scan: *const Scan, row: u64, predicates: []const Predicate) !bool {
    if ((try Column.get(transaction, scan.liveRef, row)) == 0) return false;
    return rowMatches(transaction, scan, row, predicates);
}

// Reject out-of-range property indices up front: the evaluators index
// fixed-size ref arrays, so an unchecked property is an undefined ref below 256
// and an out-of-bounds read past it. Query inputs will eventually cross the
// C ABI, which must not trust its arguments.
fn validateProperties(scan: *const Scan, predicates: []const Predicate) !void {
    for (predicates) |predicate| {
        if (predicate.property >= scan.propertyCount) return error.BadProperty;
    }
}

// (objectKey, physical row) pair, as surfaced by the key->row index.
const Pair = struct { objectKey: u64, row: u64 };

// ---------------------------------------------------------------------------
// Query planner.
//
// The planner chooses an optional DRIVING predicate: a predicate whose property
// is indexed and whose operator is index-friendly (eq, lt, le, gt, ge). When one
// exists, the candidate objectKeys are gathered from that property's value index
// rather than from a full keyrow scan; the remaining predicates are then applied
// to each candidate by the same rowLive/rowMatches logic the scan uses.
//
// Correctness: the value index is an exact mirror of the indexed property (kept
// in sync on every mutation), so its inner sets contain exactly the objectKeys whose
// value satisfies the driving predicate. Resolving each candidate objectKey through
// the keyrow index and re-applying ALL predicates (including the driving one,
// which always passes) plus the live check reproduces, on the same committed
// snapshot, the exact objectKey set the full scan would emit. Candidate pairs are
// sorted by objectKey so the emitted order matches the ascending-objectKey scan order too.
// ---------------------------------------------------------------------------

// Pick the index of the driving predicate, or null to fall back to a full scan.
// Prefers an indexed eq predicate (most selective); otherwise the first indexed
// range predicate. `ne` is never index-driven (negation is not index-friendly).
fn pickDriving(scan: *const Scan, predicates: []const Predicate) ?usize {
    var rangeChoice: ?usize = null;
    for (predicates, 0..) |predicate, rowIndex| {
        if (predicate.property >= scan.propertyCount or !scan.indexed[predicate.property]) continue;
        switch (predicate.operator) {
            .eq => return rowIndex, // most selective: drive off it immediately
            .lt, .le, .gt, .ge => if (rangeChoice == null) {
                rangeChoice = rowIndex;
            },
            .ne => {},
        }
    }
    return rangeChoice;
}

// Translate a range operator + value into an inclusive [lo, hi] over u64.
// Returns null when the range is provably empty (gt maxInt, lt 0), so the
// caller emits zero candidates.
//   ge v -> [v, max]      gt v -> [v+1, max]  (empty if v == max)
//   le v -> [0, v]        lt v -> [0, v-1]    (empty if v == 0)
const Bounds = struct { lo: u64, hi: u64 };
fn rangeBounds(operator: Operator, value: u64) ?Bounds {
    const max = std.math.maxInt(u64);
    return switch (operator) {
        .ge => Bounds{ .lo = value, .hi = max },
        .gt => if (value == max) null else Bounds{ .lo = value + 1, .hi = max },
        .le => Bounds{ .lo = 0, .hi = value },
        .lt => if (value == 0) null else Bounds{ .lo = 0, .hi = value - 1 },
        else => unreachable,
    };
}

// Appends objectKeys to a list; used to drain a value-index inner set (objectKey -> 1).
const ObjectKeyCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onKey(self: @This(), key: u64) !void {
        try self.list.append(self.allocator, key);
    }
};

// Appends each outer entry's value (an inner-set root ref) to a list; used to
// gather the inner sets a range scan of the value index touches.
const InnerRootCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onEntry(self: @This(), _: u64, value: u64) !void {
        try self.list.append(self.allocator, value);
    }
};

// Gather candidate (objectKey, row) pairs for a driving predicate from its value
// index, resolving each objectKey to its current physical row via the keyrow index
// (skipping any objectKey with no mapping). Pairs are returned sorted by objectKey.
fn collectCandidatePairs(
    transaction: anytype,
    scan: *const Scan,
    driver: Predicate,
    pairs: *std.ArrayList(Pair),
    allocator: std.mem.Allocator,
) !void {
    const valueIndexRef = scan.valueIndexRefs[driver.property];
    var objectKeys = std.ArrayList(u64).empty;
    defer objectKeys.deinit(allocator);

    if (driver.operator == .eq) {
        if (try index.get(transaction, valueIndexRef, driver.value)) |innerRoot| {
            if (innerRoot != 0) {
                try index.forEachKey(transaction, innerRoot, ObjectKeyCollector{ .list = &objectKeys, .allocator = allocator }, ObjectKeyCollector.onKey);
            }
        }
    } else {
        const bounds = rangeBounds(driver.operator, driver.value) orelse return; // empty range
        var innerRoots = std.ArrayList(u64).empty;
        defer innerRoots.deinit(allocator);
        try index.forEachEntryInRange(transaction, valueIndexRef, bounds.lo, bounds.hi, InnerRootCollector{ .list = &innerRoots, .allocator = allocator }, InnerRootCollector.onEntry);
        for (innerRoots.items) |innerRoot| {
            if (innerRoot == 0) continue;
            try index.forEachKey(transaction, innerRoot, ObjectKeyCollector{ .list = &objectKeys, .allocator = allocator }, ObjectKeyCollector.onKey);
        }
    }

    for (objectKeys.items) |objectKey| {
        const row = (try index.get(transaction, scan.keyrowIndexRef, objectKey)) orelse continue;
        try pairs.append(allocator, .{ .objectKey = objectKey, .row = row });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, left: Pair, right: Pair) bool {
            return left.objectKey < right.objectKey;
        }
    }.lessThan);
}

// Run a query: stream every live matching (objectKey, row) into `onMatch(ctx, objectKey, row)`.
// With a driving predicate the candidate set comes from that property's value
// index (bounded by its selectivity, so a temporary pair buffer is fine); the
// full-scan path streams the key->row index directly and evaluates each row
// inside the traversal, so no O(live) buffer is ever materialized.
fn runQuery(
    transaction: anytype,
    scan: *const Scan,
    predicates: []const Predicate,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    if (pickDriving(scan, predicates)) |drivingIndex| {
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(allocator);
        try collectCandidatePairs(transaction, scan, predicates[drivingIndex], &pairs, allocator);
        for (pairs.items) |pair| {
            if (try evalRow(transaction, scan, pair.row, predicates)) try onMatch(ctx, pair.objectKey, pair.row);
        }
        return;
    }
    const Stream = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicates: []const Predicate,
        inner: @TypeOf(ctx),
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if (try evalRow(self.transaction, self.scan, row, self.predicates)) try onMatch(self.inner, objectKey, row);
        }
    };
    try index.forEachEntry(transaction, scan.keyrowIndexRef, Stream{ .transaction = transaction, .scan = scan, .predicates = predicates, .inner = ctx }, Stream.onEntry);
}

// Test-only: expose the driving-predicate choice so equivalence tests can assert
// which path the planner takes.
fn drivingPredicateIndex(transaction: anytype, catalogRef: Reference, predicates: []const Predicate) !?usize {
    const scan = try openScan(transaction, catalogRef);
    return pickDriving(&scan, predicates);
}

// Collect the objectKeys of every live row that satisfies ALL predicates (logical
// AND). An empty predicate list matches every live row.
pub fn where(
    transaction: anytype,
    catalogRef: Reference,
    predicates: []const Predicate,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const scan = try openScan(transaction, catalogRef);
    try validateProperties(&scan, predicates);
    const Sink = struct {
        out: *std.ArrayList(u64),
        allocator: std.mem.Allocator,
        fn onMatch(self: @This(), objectKey: u64, _: u64) anyerror!void {
            try self.out.append(self.allocator, objectKey);
        }
    };
    try runQuery(transaction, &scan, predicates, allocator, Sink{ .out = out, .allocator = allocator }, Sink.onMatch);
}

// Number of live rows satisfying all predicates. The full-scan path streams,
// so this allocates nothing proportional to the table.
pub fn countWhere(transaction: anytype, catalogRef: Reference, predicates: []const Predicate, allocator: std.mem.Allocator) !u64 {
    const scan = try openScan(transaction, catalogRef);
    try validateProperties(&scan, predicates);
    var rowCount: u64 = 0;
    const Sink = struct {
        rowCount: *u64,
        fn onMatch(self: @This(), _: u64, _: u64) anyerror!void {
            self.rowCount.* += 1;
        }
    };
    try runQuery(transaction, &scan, predicates, allocator, Sink{ .rowCount = &rowCount }, Sink.onMatch);
    return rowCount;
}

pub const Aggregate = struct { count: u64, sum: u64, min: ?u64, max: ?u64 };

// Aggregate an int property over the live rows satisfying all predicates.
// `sum` wraps on overflow (wrapping add); min/max are null when no row matches.
pub fn aggregateInt(transaction: anytype, catalogRef: Reference, property: usize, predicates: []const Predicate, allocator: std.mem.Allocator) !Aggregate {
    const scan = try openScan(transaction, catalogRef);
    try validateProperties(&scan, predicates);
    if (property >= scan.propertyCount) return error.BadProperty;
    var agg = Aggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    const Sink = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        property: usize,
        agg: *Aggregate,
        fn onMatch(self: @This(), _: u64, row: u64) anyerror!void {
            const value = try Column.get(self.transaction, self.scan.propertyRefs[self.property], row);
            self.agg.count += 1;
            self.agg.sum +%= value;
            if (self.agg.min == null or value < self.agg.min.?) self.agg.min = value;
            if (self.agg.max == null or value > self.agg.max.?) self.agg.max = value;
        }
    };
    try runQuery(transaction, &scan, predicates, allocator, Sink{ .transaction = transaction, .scan = &scan, .property = property, .agg = &agg }, Sink.onMatch);
    return agg;
}

// Convenience: collect objectKeys whose property `property` is in the inclusive range
// [lo, hi]. Implemented as a scan with two predicates; an index-seek fast path
// is a later optimization.
pub fn rangeInclusive(
    transaction: anytype,
    catalogRef: Reference,
    property: usize,
    lo: u64,
    hi: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const predicates = [_]Predicate{
        .{ .property = property, .operator = .ge, .value = lo },
        .{ .property = property, .operator = .le, .value = hi },
    };
    try where(transaction, catalogRef, &predicates, out, allocator);
}

// Sort a slice of objectKeys in place by an int property, ascending. Reads each
// row's value once into a temporary pair array, then sorts.
pub fn sortByPropertyAscending(
    transaction: anytype,
    catalogRef: Reference,
    objectKeys: []u64,
    property: usize,
    allocator: std.mem.Allocator,
) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    if (property >= view.propertyCount) return error.BadProperty;
    const col = view.propertyColumnRef(property);
    const SortPair = struct { value: u64, key: u64 };
    const pairs = try allocator.alloc(SortPair, objectKeys.len);
    defer allocator.free(pairs);
    for (objectKeys, 0..) |key, rowIndex| {
        // A caller-supplied objectKey that no longer resolves (stale or deleted) is
        // an input error, not a crash.
        const row = (try catalog.objectKeyToRow(transaction, catalogRef, key)) orelse return error.NotFound;
        pairs[rowIndex] = .{ .value = try Column.get(transaction, col, row), .key = key };
    }
    std.mem.sort(SortPair, pairs, {}, struct {
        fn lessThan(_: void, left: SortPair, right: SortPair) bool {
            return left.value < right.value;
        }
    }.lessThan);
    for (pairs, 0..) |pair, rowIndex| objectKeys[rowIndex] = pair.key;
}

// Tests of file-private invariants; the main suite lives in queryTests.zig.

const testing = std.testing;
const Database = @import("database.zig").Database;

fn qTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

// ---------------------------------------------------------------------------
// Planner equivalence tests.
//
// Every test builds two catalogs over identical data inserted in identical
// order: one with property 1 indexed (the planner drives off its value index) and
// one with property 1 NOT indexed (forced full scan). Because both catalogs assign
// object keys from 0 in the same insertion order, a row's objectKey is the same in
// both, so the sorted objectKey slices must be byte-for-byte equal. Any divergence
// between the index path and the full scan is a defect.
// ---------------------------------------------------------------------------

// Build a 3-property type: property0 = primaryKey, property1 = value (indexed iff `indexed`), property2 =
// secondary. Inserts n rows with primaryKey=i, property1=i%100, property2=i.
fn seedPlannerCatalog(writeTransaction: *@import("database.zig").WriteTransaction, indexed: bool, rowCount: u64) !Reference {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = indexed },
        .{ .kind = .int },
    };
    var catalogRef = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) catalogRef = (try rows.insert(writeTransaction, catalogRef, &.{ rowIndex, rowIndex % 100, rowIndex })).catalogRef;
    return catalogRef;
}

test "planner picks an indexed eq predicate as the driver, prefers eq over range, ignores ne and non-indexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_pick.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try seedPlannerCatalog(&writeTransaction, true, 10);

    // property 1 is indexed; property 0 and property 2 are not.
    // eq on the indexed property drives.
    try testing.expectEqual(@as(?usize, 0), try drivingPredicateIndex(&writeTransaction, catalogRef, &.{
        .{ .property = 1, .operator = .eq, .value = 5 },
    }));
    // Prefer the eq over a range, even when the range appears first.
    try testing.expectEqual(@as(?usize, 1), try drivingPredicateIndex(&writeTransaction, catalogRef, &.{
        .{ .property = 1, .operator = .ge, .value = 5 },
        .{ .property = 1, .operator = .eq, .value = 5 },
    }));
    // A range on the indexed property drives when there is no eq.
    try testing.expectEqual(@as(?usize, 0), try drivingPredicateIndex(&writeTransaction, catalogRef, &.{
        .{ .property = 1, .operator = .lt, .value = 5 },
    }));
    // ne is not index-friendly: stays on the scan.
    try testing.expectEqual(@as(?usize, null), try drivingPredicateIndex(&writeTransaction, catalogRef, &.{
        .{ .property = 1, .operator = .ne, .value = 5 },
    }));
    // eq on a non-indexed property: no driver.
    try testing.expectEqual(@as(?usize, null), try drivingPredicateIndex(&writeTransaction, catalogRef, &.{
        .{ .property = 0, .operator = .eq, .value = 5 },
        .{ .property = 2, .operator = .ge, .value = 5 },
    }));
    writeTransaction.deinit();
}

test {
    _ = @import("queryTests.zig");
}
