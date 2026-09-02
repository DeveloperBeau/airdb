//! Query engine over an object catalog. Operates on the stable object key (objectKey)
//! space: a scan walks the per-type key->row index, so each entry maps an objectKey to
//! the physical row that currently holds its data (rows can move via relocation).
//! Predicates compare the raw u64 stored in a property column, so they apply to
//! int properties and to link properties (which store target objectKey + 1), and
//! to blob properties, whose word is a storage reference the engine follows to
//! compare the stored bytes against the probe. A `.blob` property may carry a
//! value index keyed by its truncated bytes (see records/blobIndexKey.zig),
//! which serves `eq`, `beginsWith` and the four range operators; an unindexed
//! blob property still costs a full scan. Collection predicates are a later
//! addition.
//!
//! Results are object keys (objectKeys); materialize them with
//! objects.getTypedByObjectKey. The fetch model is stale-snapshot: a query reads one
//! committed snapshot and returns detached keys, never live cursors.
//!
//! `countWhere` and `aggregateInt` take a bare `Predicate` rather than a `Request`:
//! neither has an order and neither has a page, so a `Request` would offer fields
//! that do nothing for them. `minimum` and `maximum` take no predicate at all:
//! their fast path is the value index's own endpoint, and a predicate would
//! silently disable it. `distinct` takes a `Predicate` and a `Page` but no
//! `Ordering`, because its order is fixed by its own property; `groupBy` takes
//! neither an order nor a page, because a group is only correct once complete,
//! so a limit would bound what is copied out and not what is read.

const std = @import("std");
const catalog = @import("schema/catalog.zig");
const Column = @import("trees/column.zig");
const Reference = @import("storage/reference.zig").Reference;
const Scan = @import("query/scan.zig").Scan;
const index = @import("trees/index.zig");
const execution = @import("query/execution.zig");
const predicateLanguage = @import("query/predicate.zig");
const orderingLanguage = @import("query/ordering.zig");
const paging = @import("query/paging.zig");
const aggregateModule = @import("query/aggregate.zig");
const groupingModule = @import("query/grouping.zig");
const materialized = @import("query/materialized.zig");

/// Direction an ordered query emits in.
pub const SortOrder = orderingLanguage.SortOrder;
/// What a query orders by: the stable object key, or one int or link property's value.
pub const SortKey = orderingLanguage.SortKey;
/// How a query orders its results.
pub const Ordering = orderingLanguage.Ordering;
/// The last row a page delivered, for resuming a page with `cursorAfter`.
pub const Cursor = orderingLanguage.Cursor;
/// Where a page begins: after an offset, or immediately after a cursor.
pub const PageStart = orderingLanguage.PageStart;
/// One page of results: where it starts and how many rows it takes.
pub const Page = orderingLanguage.Page;
/// Everything a query asks for: which rows, in what order, and which page.
pub const Request = orderingLanguage.Request;

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

/// Append one page of the objectKeys satisfying `request` to `out`, in the
/// order `request.ordering` asks for. `out` grows with `allocator`, the caller
/// owns it, and existing items are left in place. Which orderings bound their
/// work and which do not is documented on `paging.collectPage`; the short form
/// is that every ordering except property ordering on an unindexed property
/// stops walking when the page fills.
pub fn where(
    transaction: anytype,
    catalogReference: Reference,
    request: Request,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const scan = try Scan.open(transaction, catalogReference);
    try request.validate(&scan);
    try paging.collectPage(transaction, &scan, request, out, allocator);
}

/// Number of live rows satisfying `predicate`. The full-scan path streams,
/// so this allocates nothing proportional to the table; still O(n) over the
/// live set without a usable value index. A blob value index is a candidate
/// index, not a covering one (blobIndexKey.zig), so `countWhere` over a blob
/// predicate reads every candidate row even when the index drives the plan.
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
        fn onMatch(self: @This(), _: u64, _: u64) anyerror!bool {
            self.rowCount.* += 1;
            return true;
        }
    };
    try execution.runQuery(transaction, &scan, predicate, .ascending, null, allocator, Sink{ .rowCount = &rowCount }, Sink.onMatch);
    return rowCount;
}

/// The result of aggregating one int or link property over a set of rows:
/// matched-row count, wrapping sum, and the min/max values (null when no row
/// contributed).
pub const Aggregate = aggregateModule.Aggregate;

/// One distinct value of a grouping property, with the aggregate of the
/// aggregated property over the rows carrying it.
pub const Group = groupingModule.Group;
/// Which property `groupBy` partitions by and which one it aggregates.
pub const Grouping = groupingModule.Grouping;

/// Aggregate int property `property` over the live rows satisfying `predicate`.
/// `sum` wraps on overflow; min/max are null when no row matches. O(n) over the
/// live set without a usable value index. `property`'s kind is not yet
/// checked, unlike `sortByProperty` and `Request.validate`: a blob or
/// collection property aggregates its raw tree-root u64 rather than being
/// rejected. That check arrives with collection predicates.
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
    var aggregate: Aggregate = .{};
    const Sink = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        property: usize,
        aggregate: *Aggregate,
        fn onMatch(self: @This(), _: u64, row: u64) anyerror!bool {
            const value = try Column.get(self.transaction, self.scan.propertyReferences[self.property], row);
            self.aggregate.accumulate(value);
            return true;
        }
    };
    try execution.runQuery(transaction, &scan, predicate, .ascending, null, allocator, Sink{ .transaction = transaction, .scan = &scan, .property = property, .aggregate = &aggregate }, Sink.onMatch);
    return aggregate;
}

/// Append one page of representative objectKeys, one per distinct value of int
/// or link property `property` among the live rows satisfying `predicate`, to
/// `out`. Values arrive ascending, and each value's representative is the
/// SMALLEST matching objectKey carrying it, so the indexed and unindexed paths
/// return the identical sequence. `out` grows with `allocator`, the caller
/// owns it, and existing items are left in place.
///
/// `error.BadProperty` when `property` is outside the type,
/// `error.UnsupportedGrouping` when its kind is neither int nor link (a `.blob`
/// property is rejected even when indexed: its value index is keyed by
/// TRUNCATED bytes, so one outer key can cover two distinct values),
/// `error.UnsupportedPageStart` when `page` resumes from a cursor, which this
/// terminal does not yet produce.
///
/// Only one of the two paths is lazy:
///   - `property` indexed: walks its value index in key order and stops at the
///     first matching row of each value, then stops entirely when the page
///     fills, so the work tracks the page. O(values visited + rows examined)
///     with I/O, and no memory beyond `out`.
///   - `property` unindexed: NOT lazy. A hash set must see every matching row
///     before it knows which values are distinct, so `page.limit` bounds what
///     is delivered and not what is read. O(matching rows) time with I/O and
///     O(distinct values) memory whatever the limit.
///
/// The indexed path sees only rows present in `property`'s value index; a
/// future nullable-properties phase will need the same treatment
/// `paging.deliverByIndexedProperty` already flags for null rows.
pub fn distinct(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    predicate: Predicate,
    page: Page,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const scan = try Scan.open(transaction, catalogReference);
    try predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
    try groupingModule.validateGroupableProperty(&scan, property);
    switch (page.start) {
        .offset => {},
        .after => return error.UnsupportedPageStart,
    }
    try groupingModule.collectDistinct(transaction, &scan, property, predicate, page, out, allocator);
}

/// Append one `Group` per distinct value of `grouping.groupProperty` among the
/// live rows satisfying `predicate` to `out`, each carrying the `Aggregate` of
/// `grouping.aggregateProperty` over that value's matching rows. Groups arrive
/// ascending by value; a value whose every row is dead or filtered out
/// produces no group. `Group` holds no pointers, so `out.deinit(allocator)` is
/// the whole free, and existing items are left in place.
///
/// `error.BadProperty` when either property is outside the type,
/// `error.UnsupportedGrouping` when either property's kind is neither int nor
/// link. Unlike `aggregateInt`, this terminal does NOT inherit the deferred
/// kind check: a blob or collection property is rejected here rather than
/// aggregated as its raw tree-root u64.
///
/// Neither path is lazy, because a group is only correct once it is complete.
/// They differ in memory:
///   - `grouping.groupProperty` indexed: the value index yields each group's
///     rows contiguously, so groups stream out with one `Aggregate` live at a
///     time. O(matching rows) time with I/O, no working memory beyond `out`.
///   - unindexed: one scan pass into an `AutoHashMap(u64, Aggregate)`, then a
///     sort by value. O(matching rows) time with I/O, O(distinct values)
///     memory.
///
/// The indexed path sees only rows present in `grouping.groupProperty`'s value
/// index; a future nullable-properties phase will need the same treatment
/// `paging.deliverByIndexedProperty` already flags for null rows.
pub fn groupBy(
    transaction: anytype,
    catalogReference: Reference,
    grouping: Grouping,
    predicate: Predicate,
    out: *std.ArrayList(Group),
    allocator: std.mem.Allocator,
) !void {
    const scan = try Scan.open(transaction, catalogReference);
    try predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
    try grouping.validate(&scan);
    try groupingModule.collectGroups(transaction, &scan, grouping, predicate, out, allocator);
}

/// Which end of a property's value range an endpoint terminal wants.
const Endpoint = enum { minimum, maximum };

/// The smallest value of int or link property `property` over the live rows,
/// or null when the type holds no live row. O(log n) with I/O when `property`
/// carries a value index, because the answer is that index's first key;
/// otherwise O(n) over the live set. `allocator` is used only by the scan
/// path. `error.BadProperty` when `property` is outside the type,
/// `error.UnsupportedAggregate` when its kind is neither int nor link (a blob
/// or collection column holds a reference or a tree root, so its smallest
/// stored word is not a value). Takes no predicate: for the smallest value
/// over a filtered set, read `aggregateInt`'s `min`.
pub fn minimum(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    allocator: std.mem.Allocator,
) !?u64 {
    return endpointValue(transaction, catalogReference, property, .minimum, allocator);
}

/// The largest value of int or link property `property` over the live rows, or
/// null when the type holds no live row. The mirror of `minimum`: same costs,
/// same errors, same absence of a predicate.
pub fn maximum(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    allocator: std.mem.Allocator,
) !?u64 {
    return endpointValue(transaction, catalogReference, property, .maximum, allocator);
}

fn endpointValue(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    endpoint: Endpoint,
    allocator: std.mem.Allocator,
) !?u64 {
    const scan = try Scan.open(transaction, catalogReference);
    if (property >= scan.propertyCount) return error.BadProperty;
    const kind = scan.propertyKinds[property];
    if (kind != .int and kind != .link) return error.UnsupportedAggregate;
    if (scan.indexed[property]) {
        // No residual liveness filtering needed here: rows.intValueIndexRemove
        // drops an outer key the moment its last live objectKey is removed
        // (delete, or update moving off the old value), so the value index's
        // outer key set already equals exactly the live values.
        const valueIndexReference = scan.valueIndexReferences[property];
        return switch (endpoint) {
            .minimum => try index.minKey(transaction, valueIndexReference),
            .maximum => try index.maxKey(transaction, valueIndexReference),
        };
    }
    const aggregate = try aggregateInt(transaction, catalogReference, property, .{ .conjunction = &.{} }, allocator);
    return switch (endpoint) {
        .minimum => aggregate.min,
        .maximum => aggregate.max,
    };
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
    try where(transaction, catalogReference, .{ .predicate = .{ .conjunction = &bounds } }, out, allocator);
}

/// The first objectKey `request` matches in its ordering, or null when nothing
/// matches. Honours `request.page.start` (so it can ask for the first row after
/// a cursor or after an offset) and ignores `request.page.limit`. Costs one
/// page of size 1, so on the lazy orderings it stops at the first match; it
/// allocates one small result buffer and frees it. I/O.
pub fn first(
    transaction: anytype,
    catalogReference: Reference,
    request: Request,
    allocator: std.mem.Allocator,
) !?u64 {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(allocator);
    var firstPageRequest = request;
    firstPageRequest.page.limit = 1;
    try where(transaction, catalogReference, firstPageRequest, &out, allocator);
    return if (out.items.len == 0) null else out.items[0];
}

/// Whether any live row satisfies `request`. Same cost as `first`, which it is
/// defined in terms of. I/O.
pub fn exists(
    transaction: anytype,
    catalogReference: Reference,
    request: Request,
    allocator: std.mem.Allocator,
) !bool {
    return (try first(transaction, catalogReference, request, allocator)) != null;
}

/// The cursor that resumes immediately after `objectKey` under `ordering`.
/// Call it on the transaction that produced the page: it reads the row's
/// current sort value, so a value that changed since the page was fetched
/// yields a cursor for the new position. `error.NotFound` when `objectKey` no
/// longer resolves, `error.BadProperty` when `ordering`'s property is outside
/// the type. O(1) and no I/O for `.objectKey`; one index descent plus one
/// column read for `.property`.
pub fn cursorAfter(
    transaction: anytype,
    catalogReference: Reference,
    ordering: Ordering,
    objectKey: u64,
) !Cursor {
    switch (ordering.sortKey) {
        .objectKey => return .{ .lastValue = objectKey, .lastObjectKey = objectKey },
        .property => |property| {
            const view = try catalog.loadCatalog(transaction, catalogReference);
            if (property >= view.propertyCount) return error.BadProperty;
            const row = (try catalog.objectKeyToRow(transaction, catalogReference, objectKey)) orelse return error.NotFound;
            const value = try Column.get(transaction, view.propertyColumnReference(property), row);
            return .{ .lastValue = value, .lastObjectKey = objectKey };
        },
    }
}

/// Sort a slice of objectKeys in place by int or link property `property`, in
/// `order`. Ties break by objectKey, ascending under `.ascending` and
/// descending under `.descending`, so the result is a total order and
/// `.descending` is the exact reverse of `.ascending`. Reads each row's value
/// once into a temporary pair array (allocated from `allocator`, freed before
/// returning), then sorts: O(k log k) plus a tree walk per key.
/// `error.BadProperty` when `property` is outside the type,
/// `error.UnsupportedOrdering` when its kind is neither int nor link, and
/// `error.NotFound` when a key no longer resolves.
pub fn sortByProperty(
    transaction: anytype,
    catalogReference: Reference,
    objectKeys: []u64,
    property: usize,
    order: SortOrder,
    allocator: std.mem.Allocator,
) !void {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    if (property >= view.propertyCount) return error.BadProperty;
    const kind = view.kind(property);
    if (kind != .int and kind != .link) return error.UnsupportedOrdering;
    const column = view.propertyColumnReference(property);
    const entries = try allocator.alloc(orderingLanguage.SortEntry, objectKeys.len);
    defer allocator.free(entries);
    for (objectKeys, 0..) |key, entryIndex| {
        // A caller-supplied objectKey that no longer resolves (stale or deleted) is
        // an input error, not a crash.
        const row = (try catalog.objectKeyToRow(transaction, catalogReference, key)) orelse return error.NotFound;
        entries[entryIndex] = .{ .value = try Column.get(transaction, column, row), .objectKey = key };
    }
    std.mem.sort(orderingLanguage.SortEntry, entries, order, orderingLanguage.isOrderedBefore);
    for (entries, 0..) |entry, entryIndex| objectKeys[entryIndex] = entry.objectKey;
}

test {
    _ = @import("queryTests.zig");
    _ = @import("queryDifferentialTests.zig");
    _ = @import("queryPaginationTests.zig");
    _ = @import("queryLazinessTests.zig");
    _ = @import("queryEndpointTests.zig");
    _ = @import("queryStringTests.zig");
    _ = @import("queryIndexedStringTests.zig");
    _ = @import("queryGroupingTests.zig");
    // Pulled in directly, ahead of the facade re-exports added later in this
    // branch, so materializedTests.zig and batchTests.zig run as soon as their
    // production files exist.
    _ = @import("query/materialized.zig");
    _ = @import("query/batch.zig");
}
