//! The scan/candidate execution core shared by every query entry point: given
//! a predicate, an order, and optional objectKey bounds, streams matching
//! (objectKey, row) pairs to a caller-supplied callback. Lives below the
//! facade (query.zig) so paging.zig, which needs it, does not have to import
//! the facade and violate the dependency rule.

const std = @import("std");
const index = @import("../trees/index.zig");
const Reference = @import("../storage/reference.zig").Reference;
const Scan = @import("scan.zig").Scan;
const evaluation = @import("evaluation.zig");
const planner = @import("planner.zig");
const Bounds = planner.Bounds;
const predicateLanguage = @import("predicate.zig");
const Predicate = predicateLanguage.Predicate;
const orderingLanguage = @import("ordering.zig");
const SortOrder = orderingLanguage.SortOrder;

/// Stream every live matching (objectKey, row) pair to `onMatch` in objectKey
/// order, ascending or descending, restricted to `bounds` when given.
/// `onMatch` returns whether to keep walking, so a caller that has filled its
/// page stops the traversal instead of draining it.
///
/// With a driving predicate the candidate set comes from that property's value
/// index and is materialized, sorted and deduplicated first, so this path's
/// memory tracks the driver's match count, not the page size; the early stop
/// still saves the per-row residual filtering. The full-scan path streams the
/// key->row index and materializes nothing. O(candidates log candidates) or
/// O(live rows walked), with I/O.
pub fn runQuery(
    transaction: anytype,
    scan: *const Scan,
    predicate: Predicate,
    order: SortOrder,
    bounds: ?Bounds,
    allocator: std.mem.Allocator,
    context: anytype,
    comptime onMatch: fn (@TypeOf(context), u64, u64) anyerror!bool,
) !void {
    if (planner.canDriveFromIndex(scan, predicate)) {
        var candidates = std.ArrayList(u64).empty;
        defer candidates.deinit(allocator);
        try planner.collectCandidates(transaction, scan, predicate, &candidates, allocator, 0);
        std.mem.sort(u64, candidates.items, {}, std.sort.asc(u64));
        var previousCandidate: ?u64 = null;
        switch (order) {
            .ascending => {
                for (candidates.items) |objectKey| {
                    if (previousCandidate != null and previousCandidate.? == objectKey) continue;
                    previousCandidate = objectKey;
                    if (bounds) |range| {
                        if (objectKey < range.low or objectKey > range.high) continue;
                    }
                    const row = (try index.get(transaction, scan.keyToRowIndexReference, objectKey)) orelse continue;
                    if (try evaluation.isLiveMatch(transaction, scan, row, predicate)) {
                        if (!try onMatch(context, objectKey, row)) return;
                    }
                }
            },
            .descending => {
                var position = candidates.items.len;
                while (position > 0) {
                    position -= 1;
                    const objectKey = candidates.items[position];
                    if (previousCandidate != null and previousCandidate.? == objectKey) continue;
                    previousCandidate = objectKey;
                    if (bounds) |range| {
                        if (objectKey < range.low or objectKey > range.high) continue;
                    }
                    const row = (try index.get(transaction, scan.keyToRowIndexReference, objectKey)) orelse continue;
                    if (try evaluation.isLiveMatch(transaction, scan, row, predicate)) {
                        if (!try onMatch(context, objectKey, row)) return;
                    }
                }
            },
        }
        return;
    }
    const Stream = struct {
        transaction: @TypeOf(transaction),
        scan: *const Scan,
        predicate: Predicate,
        inner: @TypeOf(context),
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!bool {
            if (!try evaluation.isLiveMatch(self.transaction, self.scan, row, self.predicate)) return true;
            return onMatch(self.inner, objectKey, row);
        }
    };
    try walkLiveRows(transaction, scan.keyToRowIndexReference, order, bounds, Stream{
        .transaction = transaction,
        .scan = scan,
        .predicate = predicate,
        .inner = context,
    }, Stream.onEntry);
}

/// Walk the key->row index in the requested direction, optionally restricted
/// to `bounds`, calling `onEntry(context, objectKey, row)` until it returns
/// false. The uncursored ascending walk uses the unbounded walker, which does
/// no per-node bound routing; the other three use the range walkers. O(nodes
/// visited) with I/O.
pub fn walkLiveRows(
    transaction: anytype,
    keyToRowIndexReference: Reference,
    order: SortOrder,
    bounds: ?Bounds,
    context: anytype,
    comptime onEntry: fn (@TypeOf(context), u64, u64) anyerror!bool,
) !void {
    if (bounds) |range| {
        switch (order) {
            .ascending => _ = try index.forEachEntryInRangeWhile(transaction, keyToRowIndexReference, range.low, range.high, context, onEntry),
            .descending => _ = try index.forEachEntryInRangeDescendingWhile(transaction, keyToRowIndexReference, range.low, range.high, context, onEntry),
        }
        return;
    }
    switch (order) {
        .ascending => _ = try index.forEachEntryWhile(transaction, keyToRowIndexReference, context, onEntry),
        .descending => _ = try index.forEachEntryInRangeDescendingWhile(transaction, keyToRowIndexReference, 0, std.math.maxInt(u64), context, onEntry),
    }
}
