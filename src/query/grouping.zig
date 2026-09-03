//! Partitions the live matching rows of one int or link property by that
//! property's value, and delivers either one representative objectKey per
//! value (`collectDistinct`) or one aggregate per value (`collectGroups`).
//! Mirrors `paging.zig`, which holds four deliveries of one pagination in one
//! file; this holds four deliveries of one partitioning.

const std = @import("std");
const index = @import("../trees/index.zig");
const Column = @import("../trees/column.zig");
const Reference = @import("../storage/reference.zig").Reference;
const scanModule = @import("scan.zig");
const Scan = scanModule.Scan;
const evaluation = @import("evaluation.zig");
const execution = @import("execution.zig");
const paging = @import("paging.zig");
const PageCollector = paging.PageCollector;
const orderingLanguage = @import("ordering.zig");
const Page = orderingLanguage.Page;
const SortEntry = orderingLanguage.SortEntry;
const SortOrder = orderingLanguage.SortOrder;
const isOrderedBefore = orderingLanguage.isOrderedBefore;
const predicateLanguage = @import("predicate.zig");
const Predicate = predicateLanguage.Predicate;
const aggregateModule = @import("aggregate.zig");
const Aggregate = aggregateModule.Aggregate;

/// One distinct value of a grouping property, with the aggregate of the
/// aggregated property over the live matching rows that carry it. Holds no
/// pointers, so a `std.ArrayList(Group)` is freed by `deinit` alone.
/// `value` is the property's RAW column word: for an int property the value
/// itself, for a link property `targetObjectKey + 1` with 0 meaning no link.
pub const Group = struct { value: u64, aggregate: Aggregate };

/// Which property partitions the rows and which one is aggregated within each
/// partition. A struct rather than two positional `usize` parameters, because
/// two adjacent bare indexes transpose silently: the call still compiles and
/// still returns groups, just the wrong ones.
pub const Grouping = struct {
    groupProperty: usize,
    aggregateProperty: usize,

    /// Reject a grouping this engine cannot answer, before any row is read:
    /// either property outside the type (`error.BadProperty`), or either
    /// property's kind neither int nor link (`error.UnsupportedGrouping`).
    /// O(1), no I/O.
    pub fn validate(self: Grouping, scan: *const Scan) !void {
        try validateGroupableProperty(scan, self.groupProperty);
        try validateGroupableProperty(scan, self.aggregateProperty);
    }
};

/// Reject a property these terminals cannot group over. `.int` and `.link` are
/// the whole allow-list: an int column's word is its value, and a link
/// column's word is `targetObjectKey + 1`, which is a faithful group key.
/// Every other kind's word is a storage reference or a tree root, not a value.
/// `.blob` is rejected even when indexed, because its value index is keyed by
/// bytes truncated to `blobIndexKey.maxLength`, so one outer key can cover two
/// distinct values and grouping off it would merge them. `error.BadProperty`
/// outside the type, `error.UnsupportedGrouping` for a kind outside the
/// allow-list. O(1), no I/O.
pub fn validateGroupableProperty(scan: *const Scan, property: usize) !void {
    if (property >= scan.propertyCount) return error.BadProperty;
    const kind = scan.propertyKinds[property];
    if (kind != .int and kind != .link) return error.UnsupportedGrouping;
}

/// Whether `left` sorts before `right` by value alone. Values arriving from
/// `collectGroups`' hash map are unique keys, so a strict `<` is a total
/// order here and no tiebreak is needed. Shaped as a `std.mem.sort`
/// comparator. O(1).
pub fn isOrderedByValue(_: void, left: Group, right: Group) bool {
    return left.value < right.value;
}

/// Append one page of representative objectKeys, one per distinct value of
/// `property` among the live rows satisfying `predicate`, to `out`. See
/// `query.distinct` for the contract and the cost of each path; this is where
/// the paths live.
pub fn collectDistinct(
    transaction: anytype,
    scan: *const Scan,
    property: usize,
    predicate: Predicate,
    page: Page,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    var collector = PageCollector.init(page, out, allocator);
    if (collector.isFull()) return;
    if (scan.indexed[property]) {
        return deliverDistinctFromIndex(transaction, scan, property, predicate, &collector);
    }
    return deliverDistinctFromScan(transaction, scan, property, predicate, &collector, allocator);
}

/// Append one `Group` per distinct value of `grouping.groupProperty` among the
/// live rows satisfying `predicate` to `out`, ascending by value. See
/// `query.groupBy` for the contract and the cost of each path.
pub fn collectGroups(
    transaction: anytype,
    scan: *const Scan,
    grouping: Grouping,
    predicate: Predicate,
    out: *std.ArrayList(Group),
    allocator: std.mem.Allocator,
) !void {
    if (scan.indexed[grouping.groupProperty]) {
        return deliverGroupsFromIndex(transaction, scan, grouping, predicate, out, allocator);
    }
    return deliverGroupsFromScan(transaction, scan, grouping, predicate, out, allocator);
}

/// Walk `property`'s value index in ascending key order and, for each outer
/// value with a live match, collect the smallest matching objectKey. Stops
/// entirely once the page fills. O(values visited + rows examined) with I/O,
/// no memory beyond `collector`'s `out`.
fn deliverDistinctFromIndex(
    transaction: anytype,
    scan: *const Scan,
    property: usize,
    predicate: Predicate,
    collector: *PageCollector,
) !void {
    const valueIndexReference = scan.valueIndexReferences[property];

    const Inner = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        representative: *?u64,
        fn onKey(self: @This(), objectKey: u64, _: u64) anyerror!bool {
            const row = (try index.get(self.transaction, self.scan.keyToRowIndexReference, objectKey)) orelse return true;
            if (!try evaluation.isLiveMatch(self.transaction, self.scan, row, self.predicate)) return true;
            self.representative.* = objectKey;
            return false;
        }
    };

    const Outer = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        collector: *PageCollector,
        fn onEntry(self: @This(), _: u64, innerSetRoot: u64) anyerror!bool {
            if (innerSetRoot == 0) return true;
            var representative: ?u64 = null;
            const innerContext = Inner{ .transaction = self.transaction, .scan = self.scan, .predicate = self.predicate, .representative = &representative };
            _ = try index.forEachEntryWhile(self.transaction, innerSetRoot, innerContext, Inner.onKey);
            const objectKey = representative orelse return true;
            return self.collector.collect(objectKey);
        }
    };
    const outerContext = Outer{ .transaction = transaction, .scan = scan, .predicate = predicate, .collector = collector };
    _ = try index.forEachEntryWhile(transaction, valueIndexReference, outerContext, Outer.onEntry);
}

/// Stream every live match, keeping the smallest objectKey seen per value in a
/// hash map, then emit ascending by value. NOT lazy: every matching row must
/// be seen before the distinct values are known, so `page.limit` bounds what
/// is delivered and not what is read. O(matching rows) time with I/O,
/// O(distinct values) memory whatever the limit.
fn deliverDistinctFromScan(
    transaction: anytype,
    scan: *const Scan,
    property: usize,
    predicate: Predicate,
    collector: *PageCollector,
    allocator: std.mem.Allocator,
) !void {
    var representatives = std.AutoHashMap(u64, u64).init(allocator);
    defer representatives.deinit();
    const propertyColumn = scan.propertyReferences[property];

    const Sink = struct {
        transaction: @TypeOf(transaction),
        propertyColumn: Reference,
        representatives: *std.AutoHashMap(u64, u64),
        fn onMatch(self: @This(), objectKey: u64, row: u64) anyerror!bool {
            const value = try Column.get(self.transaction, self.propertyColumn, row);
            const entry = try self.representatives.getOrPut(value);
            if (!entry.found_existing or objectKey < entry.value_ptr.*) entry.value_ptr.* = objectKey;
            return true;
        }
    };
    try execution.runQuery(transaction, scan, predicate, .ascending, null, allocator, Sink{
        .transaction = transaction,
        .propertyColumn = propertyColumn,
        .representatives = &representatives,
    }, Sink.onMatch);

    // Emit ascending by value, so this path returns the same sequence the
    // indexed path does rather than hash order.
    var entries = std.ArrayList(SortEntry).empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, representatives.count());
    var iterator = representatives.iterator();
    while (iterator.next()) |entry| entries.appendAssumeCapacity(.{ .value = entry.key_ptr.*, .objectKey = entry.value_ptr.* });
    std.mem.sort(SortEntry, entries.items, SortOrder.ascending, isOrderedBefore);
    for (entries.items) |entry| {
        if (!try collector.collect(entry.objectKey)) return;
    }
}

/// Walk `grouping.groupProperty`'s value index in ascending key order; each
/// outer value's inner set is one group's rows, contiguous, so groups stream
/// out with one `Aggregate` live at a time. O(matching rows) time with I/O,
/// no working memory beyond `out`. Emits nothing for a value whose whole
/// inner set is dead or filtered out.
fn deliverGroupsFromIndex(
    transaction: anytype,
    scan: *const Scan,
    grouping: Grouping,
    predicate: Predicate,
    out: *std.ArrayList(Group),
    allocator: std.mem.Allocator,
) !void {
    const valueIndexReference = scan.valueIndexReferences[grouping.groupProperty];
    const aggregateColumn = scan.propertyReferences[grouping.aggregateProperty];

    const Inner = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        aggregateColumn: Reference,
        aggregate: *Aggregate,
        fn onKey(self: @This(), objectKey: u64, _: u64) anyerror!bool {
            const row = (try index.get(self.transaction, self.scan.keyToRowIndexReference, objectKey)) orelse return true;
            if (!try evaluation.isLiveMatch(self.transaction, self.scan, row, self.predicate)) return true;
            const value = try Column.get(self.transaction, self.aggregateColumn, row);
            self.aggregate.accumulate(value);
            return true;
        }
    };

    const Outer = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        aggregateColumn: Reference,
        out: *std.ArrayList(Group),
        allocator: std.mem.Allocator,
        fn onEntry(self: @This(), value: u64, innerSetRoot: u64) anyerror!bool {
            if (innerSetRoot == 0) return true;
            var aggregate: Aggregate = .{};
            const innerContext = Inner{ .transaction = self.transaction, .scan = self.scan, .predicate = self.predicate, .aggregateColumn = self.aggregateColumn, .aggregate = &aggregate };
            _ = try index.forEachEntryWhile(self.transaction, innerSetRoot, innerContext, Inner.onKey);
            if (aggregate.count == 0) return true;
            try self.out.append(self.allocator, .{ .value = value, .aggregate = aggregate });
            return true;
        }
    };
    const outerContext = Outer{ .transaction = transaction, .scan = scan, .predicate = predicate, .aggregateColumn = aggregateColumn, .out = out, .allocator = allocator };
    _ = try index.forEachEntryWhile(transaction, valueIndexReference, outerContext, Outer.onEntry);
}

/// Stream every live match into a hash map keyed by `grouping.groupProperty`'s
/// value, accumulating `grouping.aggregateProperty` per key, then emit
/// ascending by value. O(matching rows) time with I/O, O(distinct values)
/// memory.
fn deliverGroupsFromScan(
    transaction: anytype,
    scan: *const Scan,
    grouping: Grouping,
    predicate: Predicate,
    out: *std.ArrayList(Group),
    allocator: std.mem.Allocator,
) !void {
    var byValue = std.AutoHashMap(u64, Aggregate).init(allocator);
    defer byValue.deinit();
    const groupColumn = scan.propertyReferences[grouping.groupProperty];
    const aggregateColumn = scan.propertyReferences[grouping.aggregateProperty];

    const Sink = struct {
        transaction: @TypeOf(transaction),
        groupColumn: Reference,
        aggregateColumn: Reference,
        byValue: *std.AutoHashMap(u64, Aggregate),
        fn onMatch(self: @This(), _: u64, row: u64) anyerror!bool {
            const value = try Column.get(self.transaction, self.groupColumn, row);
            const aggregated = try Column.get(self.transaction, self.aggregateColumn, row);
            const entry = try self.byValue.getOrPut(value);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.accumulate(aggregated);
            return true;
        }
    };
    try execution.runQuery(transaction, scan, predicate, .ascending, null, allocator, Sink{
        .transaction = transaction,
        .groupColumn = groupColumn,
        .aggregateColumn = aggregateColumn,
        .byValue = &byValue,
    }, Sink.onMatch);

    const startLength = out.items.len;
    try out.ensureUnusedCapacity(allocator, byValue.count());
    var iterator = byValue.iterator();
    while (iterator.next()) |entry| out.appendAssumeCapacity(.{ .value = entry.key_ptr.*, .aggregate = entry.value_ptr.* });
    std.mem.sort(Group, out.items[startLength..], {}, isOrderedByValue);
}

test {
    _ = @import("groupingTests.zig");
}
