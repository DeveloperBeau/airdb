//! Applies a request's page (offset/limit or cursor) to a stream of matched
//! objectKeys, and delivers pages for each of the four ordering paths.

const std = @import("std");
const index = @import("../trees/index.zig");
const Column = @import("../trees/column.zig");
const Reference = @import("../storage/reference.zig").Reference;
const Scan = @import("scan.zig").Scan;
const evaluation = @import("evaluation.zig");
const execution = @import("execution.zig");
const planner = @import("planner.zig");
const Bounds = planner.Bounds;
const predicateLanguage = @import("predicate.zig");
const Predicate = predicateLanguage.Predicate;
const orderingLanguage = @import("ordering.zig");
const SortOrder = orderingLanguage.SortOrder;
const Cursor = orderingLanguage.Cursor;
const Page = orderingLanguage.Page;
const Request = orderingLanguage.Request;
const SortEntry = orderingLanguage.SortEntry;
const isOrderedBefore = orderingLanguage.isOrderedBefore;

/// Applies one page's offset and limit to a stream of matched objectKeys
/// arriving in emission order, and tells the walk when to stop.
pub const PageCollector = struct {
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    remainingToSkip: u64,
    remainingToCollect: ?u64,

    /// A collector for `page`, appending to `out` with `allocator`. A cursor
    /// start skips nothing here: the walk's own bounds already positioned it.
    pub fn init(page: Page, out: *std.ArrayList(u64), allocator: std.mem.Allocator) PageCollector {
        return .{
            .out = out,
            .allocator = allocator,
            .remainingToSkip = switch (page.start) {
                .offset => |offset| offset,
                .after => 0,
            },
            .remainingToCollect = page.limit,
        };
    }

    /// Whether the page can take no more rows, so a walk need not start or
    /// continue. O(1).
    pub fn isFull(self: PageCollector) bool {
        return self.remainingToCollect != null and self.remainingToCollect.? == 0;
    }

    /// Offer one matched objectKey in emission order: dropped while the offset
    /// is unspent, otherwise appended. Returns whether the walk should
    /// continue, matching the tree walkers' convention that a callback's
    /// `false` stops the traversal. Amortized O(1), may allocate.
    pub fn collect(self: *PageCollector, objectKey: u64) !bool {
        if (self.remainingToSkip > 0) {
            self.remainingToSkip -= 1;
            return true;
        }
        if (self.isFull()) return false;
        try self.out.append(self.allocator, objectKey);
        if (self.remainingToCollect) |remaining| self.remainingToCollect = remaining - 1;
        return !self.isFull();
    }
};

/// The inclusive key bounds a cursor imposes on an objectKey-ordered walk, or
/// null when the cursor sits at the edge of the domain so nothing follows it.
fn objectKeyBounds(order: SortOrder, cursor: Cursor) ?Bounds {
    return switch (order) {
        .ascending => if (cursor.lastObjectKey == std.math.maxInt(u64)) null else .{ .low = cursor.lastObjectKey + 1, .high = std.math.maxInt(u64) },
        .descending => if (cursor.lastObjectKey == 0) null else .{ .low = 0, .high = cursor.lastObjectKey - 1 },
    };
}

/// Append one page of `request`'s matching objectKeys to `out`, in the
/// requested order. Appends only: whatever `out` already holds is left alone.
///
/// Three of the four paths are lazy, in the sense that the tree walk stops as
/// soon as the page is full and the work tracks the page rather than the result:
///   - objectKey ordering, either direction, over a full scan;
///   - objectKey ordering over an index-driven plan, where the candidate list
///     is still materialized (its size tracks the driving term's selectivity)
///     but the residual filtering stops with the page;
///   - property ordering on an indexed property, which walks the value index in
///     key order and emits as it goes.
/// The fourth, property ordering on an unindexed property, is NOT lazy: it
/// collects every match, sorts, and then takes the page, so it costs O(result)
/// time and memory whatever the limit. I/O throughout.
pub fn collectPage(
    transaction: anytype,
    scan: *const Scan,
    request: Request,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    var collector = PageCollector.init(request.page, out, allocator);
    if (collector.isFull()) return;
    switch (request.ordering.sortKey) {
        .objectKey => try deliverByObjectKey(transaction, scan, request, &collector, allocator),
        .property => |property| {
            if (scan.indexed[property]) {
                try deliverByIndexedProperty(transaction, scan, request, property, &collector);
            } else {
                try deliverBySortedMaterialization(transaction, scan, request, property, out, allocator);
            }
        },
    }
}

/// Deliver in objectKey order by streaming `runQuery`, bounded below (ascending)
/// or above (descending) when the page resumes from a cursor. Stops when the
/// page fills. See `collectPage` for which parts of this are lazy. I/O.
fn deliverByObjectKey(
    transaction: anytype,
    scan: *const Scan,
    request: Request,
    collector: *PageCollector,
    allocator: std.mem.Allocator,
) !void {
    const bounds: ?Bounds = switch (request.page.start) {
        .offset => null,
        .after => |cursor| objectKeyBounds(request.ordering.order, cursor) orelse return,
    };
    const Sink = struct {
        collector: *PageCollector,
        fn onMatch(self: @This(), objectKey: u64, _: u64) anyerror!bool {
            return self.collector.collect(objectKey);
        }
    };
    try execution.runQuery(transaction, scan, request.predicate, request.ordering.order, bounds, allocator, Sink{ .collector = collector }, Sink.onMatch);
}

/// Deliver in property order by walking property `property`'s value index in
/// key order, and within each value its inner objectKey set, residual-filtering
/// the whole predicate over each candidate and stopping when the page fills.
/// Emission order is (value, objectKey), which is `ordering.isOrderedBefore`'s
/// order.
///
/// Correct because a value index covers every live row of an indexed property
/// (the forward invariant `verification.auditValueIndexForward` audits). Phase 8
/// breaks that for null rows: when a property becomes nullable, null rows are
/// absent from its value index and this path would drop them from an ordered
/// page. O(rows walked) with I/O, so lazy: the work tracks the page.
///
/// Drives off the sort property's index and ignores the planner even when the
/// predicate has a more selective indexed term: driving off the predicate
/// would force a materialize-then-sort and lose bounded delivery.
fn deliverByIndexedProperty(
    transaction: anytype,
    scan: *const Scan,
    request: Request,
    property: usize,
    collector: *PageCollector,
) !void {
    const order = request.ordering.order;
    const cursorOrNull: ?Cursor = switch (request.page.start) {
        .offset => null,
        .after => |cursor| cursor,
    };
    const valueIndexReference = scan.valueIndexReferences[property];

    const Inner = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        collector: *PageCollector,
        fn onKey(self: @This(), objectKey: u64, _: u64) anyerror!bool {
            const row = (try index.get(self.transaction, self.scan.keyToRowIndexReference, objectKey)) orelse return true;
            if (!try evaluation.isLiveMatch(self.transaction, self.scan, row, self.predicate)) return true;
            return self.collector.collect(objectKey);
        }
    };

    const Outer = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        order: SortOrder,
        cursorOrNull: ?Cursor,
        collector: *PageCollector,
        fn onEntry(self: @This(), value: u64, innerSetRoot: u64) anyerror!bool {
            if (innerSetRoot == 0) return true;
            var innerBounds: ?Bounds = null;
            if (self.cursorOrNull) |cursor| {
                if (value == cursor.lastValue) innerBounds = objectKeyBounds(self.order, cursor) orelse return true;
            }
            const innerContext = Inner{ .transaction = self.transaction, .scan = self.scan, .predicate = self.predicate, .collector = self.collector };
            if (innerBounds) |bounds| {
                return switch (self.order) {
                    .ascending => try index.forEachEntryInRangeWhile(self.transaction, innerSetRoot, bounds.low, bounds.high, innerContext, Inner.onKey),
                    .descending => try index.forEachEntryInRangeDescendingWhile(self.transaction, innerSetRoot, bounds.low, bounds.high, innerContext, Inner.onKey),
                };
            }
            return switch (self.order) {
                .ascending => try index.forEachEntryWhile(self.transaction, innerSetRoot, innerContext, Inner.onKey),
                .descending => try index.forEachEntryInRangeDescendingWhile(self.transaction, innerSetRoot, 0, std.math.maxInt(u64), innerContext, Inner.onKey),
            };
        }
    };
    const outerContext = Outer{
        .transaction = transaction,
        .scan = scan,
        .predicate = request.predicate,
        .order = order,
        .cursorOrNull = cursorOrNull,
        .collector = collector,
    };

    if (cursorOrNull) |cursor| {
        switch (order) {
            .ascending => _ = try index.forEachEntryInRangeWhile(transaction, valueIndexReference, cursor.lastValue, std.math.maxInt(u64), outerContext, Outer.onEntry),
            .descending => _ = try index.forEachEntryInRangeDescendingWhile(transaction, valueIndexReference, 0, cursor.lastValue, outerContext, Outer.onEntry),
        }
    } else {
        switch (order) {
            .ascending => _ = try index.forEachEntryWhile(transaction, valueIndexReference, outerContext, Outer.onEntry),
            .descending => _ = try index.forEachEntryInRangeDescendingWhile(transaction, valueIndexReference, 0, std.math.maxInt(u64), outerContext, Outer.onEntry),
        }
    }
}

/// Deliver in property order over a property with no value index: collect every
/// match with its sort value, sort, then take the page. O(result) time and
/// O(result) temporary memory whatever the limit, so this path is NOT lazy and
/// a deep offset over a large result is expensive. A cursor is refused by
/// validation before reaching here. I/O.
fn deliverBySortedMaterialization(
    transaction: anytype,
    scan: *const Scan,
    request: Request,
    property: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    var entries = std.ArrayList(SortEntry).empty;
    defer entries.deinit(allocator);
    const propertyColumn = scan.propertyReferences[property];
    const Sink = struct {
        transaction: @TypeOf(transaction),
        propertyColumn: Reference,
        entries: *std.ArrayList(SortEntry),
        allocator: std.mem.Allocator,
        fn onMatch(self: @This(), objectKey: u64, row: u64) anyerror!bool {
            const value = try Column.get(self.transaction, self.propertyColumn, row);
            try self.entries.append(self.allocator, .{ .value = value, .objectKey = objectKey });
            return true;
        }
    };
    try execution.runQuery(transaction, scan, request.predicate, .ascending, null, allocator, Sink{
        .transaction = transaction,
        .propertyColumn = propertyColumn,
        .entries = &entries,
        .allocator = allocator,
    }, Sink.onMatch);
    std.mem.sort(SortEntry, entries.items, request.ordering.order, isOrderedBefore);

    const offset = switch (request.page.start) {
        .offset => |value| value,
        .after => 0,
    };
    const start = @min(offset, entries.items.len);
    const end = if (request.page.limit) |limit| @min(start +| limit, entries.items.len) else entries.items.len;
    for (entries.items[start..end]) |entry| try out.append(allocator, entry.objectKey);
}

test {
    _ = @import("pagingTests.zig");
}
