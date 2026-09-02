//! Pagination and ordering types for the query facade: how a query orders its
//! results, where a page starts, and the request struct that ties a predicate,
//! an ordering, and a page together. Pure data plus a `validate` that walks
//! once and touches no storage, modeled on predicate.zig.

const std = @import("std");
const Predicate = @import("predicate.zig").Predicate;
const Scan = @import("scan.zig").Scan;

/// Direction an ordered query emits in.
pub const SortOrder = enum { ascending, descending };

/// What a query orders by: the stable object key, or one int or link property's value.
pub const SortKey = union(enum) { objectKey, property: usize };

/// How a query orders its results. The default is the scan's own order:
/// ascending by objectKey.
pub const Ordering = struct {
    sortKey: SortKey = .objectKey,
    order: SortOrder = .ascending,
};

/// The last row a page delivered, as the pair that identifies its position in
/// the total order: the sort key's value and the objectKey that breaks ties.
/// For `.objectKey` ordering `lastValue` equals `lastObjectKey` and is ignored
/// on resume. Build one with `query.cursorAfter` rather than by hand.
pub const Cursor = struct { lastValue: u64, lastObjectKey: u64 };

/// Where a page begins: after skipping `offset` matches, or immediately after
/// the row a cursor names. The two are alternatives, so a page cannot ask for
/// both.
pub const PageStart = union(enum) { offset: u64, after: Cursor };

/// One page of results: where it starts and how many rows it takes.
/// `limit = null` takes every remaining match.
pub const Page = struct {
    start: PageStart = .{ .offset = 0 },
    limit: ?u64 = null,
};

/// Everything a query asks for: which rows, in what order, and which page.
/// Every field defaults, so `.{}` is "every live row, objectKey ascending,
/// unpaged", which is exactly what `where` did before this phase.
pub const Request = struct {
    predicate: Predicate = .{ .conjunction = &.{} },
    ordering: Ordering = .{},
    page: Page = .{},

    /// Reject a request this engine cannot answer, before any row is read:
    /// the predicate's own faults (see `Predicate.validate`), a sort property
    /// outside the type, a sort property whose kind is neither int nor link,
    /// or a cursor against an unindexed sort property. Walks the predicate
    /// once, O(predicate nodes), no I/O.
    pub fn validate(self: Request, scan: *const Scan) !void {
        try self.predicate.validate(scan.propertyKinds[0..scan.propertyCount]);
        const property = switch (self.ordering.sortKey) {
            .objectKey => return,
            .property => |sortProperty| sortProperty,
        };
        if (property >= scan.propertyCount) return error.BadProperty;
        const kind = scan.propertyKinds[property];
        if (kind != .int and kind != .link) return error.UnsupportedOrdering;
        const hasCursor = switch (self.page.start) {
            .offset => false,
            .after => true,
        };
        if (hasCursor and !scan.indexed[property]) return error.CursorRequiresIndexedSort;
    }
};

/// One row's position in a property ordering: the property's value, and the
/// objectKey that breaks ties between equal values.
pub const SortEntry = struct { value: u64, objectKey: u64 };

/// Whether `left` sorts before `right` under `order`: by value, then by
/// objectKey. Descending is the exact reverse of ascending, ties included, so
/// the two directions of one query are mirror images and the indexed and
/// materialized paths agree by construction. Shaped as a `std.mem.sort`
/// comparator. O(1).
pub fn isOrderedBefore(order: SortOrder, left: SortEntry, right: SortEntry) bool {
    return switch (order) {
        .ascending => if (left.value != right.value) left.value < right.value else left.objectKey < right.objectKey,
        .descending => isOrderedBefore(.ascending, right, left),
    };
}

test {
    _ = @import("orderingTests.zig");
}
