//! Chooses whether a predicate tree can be answered from value indexes and,
//! when it can, gathers the candidate objectKeys those indexes hold.
//!
//! The candidate set a plan produces is a **superset** of the true result
//! set. Correctness is restored by residual-filtering the whole predicate
//! tree over every candidate.

const std = @import("std");
const predicateModule = @import("predicate.zig");
const Operator = predicateModule.Operator;
const Predicate = predicateModule.Predicate;
const maxPredicateDepth = predicateModule.maxPredicateDepth;
const Scan = @import("scan.zig").Scan;
const index = @import("../trees/index.zig");

/// How many candidate objectKeys a node is expected to yield. Used only to rank
/// the children of a conjunction, so a wrong estimate picks a slower driver and
/// never a wrong answer. `unbounded` marks a range node, always ranked last.
pub const Selectivity = union(enum) { exact: u64, unbounded };

/// Whether a value index can serve `operator` directly.
fn isIndexFriendly(operator: Operator) bool {
    return switch (operator) {
        .eq, .lt, .le, .gt, .ge => true,
        .ne, .beginsWith => false,
    };
}

/// Whether the planner can produce a candidate set for `predicate` from value
/// indexes alone. Pure, no I/O: the answer depends only on which properties are
/// indexed and which operators an index serves.
pub fn canDriveFromIndex(scan: *const Scan, predicate: Predicate) bool {
    return canDriveFromIndexAt(scan, predicate, 0);
}

fn canDriveFromIndexAt(scan: *const Scan, predicate: Predicate, depth: usize) bool {
    if (depth >= maxPredicateDepth) return false;
    return switch (predicate) {
        .comparison => |comparison| comparison.property < scan.propertyCount and
            scan.indexed[comparison.property] and isIndexFriendly(comparison.operator),
        .conjunction => |children| blk: {
            for (children) |child| if (canDriveFromIndexAt(scan, child, depth + 1)) break :blk true;
            break :blk false;
        },
        .disjunction => |children| blk: {
            for (children) |child| if (!canDriveFromIndexAt(scan, child, depth + 1)) break :blk false;
            break :blk true;
        },
        .negation => false,
    };
}

/// Translate a range operator + value into an inclusive [lo, hi] over u64.
/// Returns null when the range is provably empty (gt maxInt, lt 0), so the
/// caller emits zero candidates.
///   ge v -> [v, max]      gt v -> [v+1, max]  (empty if v == max)
///   le v -> [0, v]        lt v -> [0, v-1]    (empty if v == 0)
pub const Bounds = struct { lo: u64, hi: u64 };
pub fn rangeBounds(operator: Operator, value: u64) ?Bounds {
    const max = std.math.maxInt(u64);
    return switch (operator) {
        .ge => Bounds{ .lo = value, .hi = max },
        .gt => if (value == max) null else Bounds{ .lo = value + 1, .hi = max },
        .le => Bounds{ .lo = 0, .hi = value },
        .lt => if (value == 0) null else Bounds{ .lo = 0, .hi = value - 1 },
        else => unreachable,
    };
}

/// Whether `left` is expected to yield fewer candidates than `right`. Any exact
/// count beats an unbounded range; two ranges tie, so the first wins.
pub fn isMoreSelective(left: Selectivity, right: Selectivity) bool {
    return switch (left) {
        .exact => |leftCount| switch (right) {
            .exact => |rightCount| leftCount < rightCount,
            .unbounded => true,
        },
        .unbounded => false,
    };
}

const Driver = struct { child: Predicate, selectivity: Selectivity };

/// The child of a conjunction to drive off: the most selective one that can be
/// driven from an index, or null when none can.
fn mostSelectiveChild(transaction: anytype, scan: *const Scan, children: []const Predicate, depth: usize) anyerror!?Driver {
    var best: ?Driver = null;
    for (children) |child| {
        if (!canDriveFromIndexAt(scan, child, depth)) continue;
        const selectivity = try selectivityOf(transaction, scan, child, depth);
        if (best == null or isMoreSelective(selectivity, best.?.selectivity)) {
            best = .{ .child = child, .selectivity = selectivity };
        }
    }
    return best;
}

/// Estimated candidate count for a node `canDriveFromIndex` accepts. One index
/// descent plus one node read per equality term, O(log n) I/O.
pub fn selectivityOf(transaction: anytype, scan: *const Scan, predicate: Predicate, depth: usize) !Selectivity {
    switch (predicate) {
        .comparison => |comparison| {
            if (comparison.property >= scan.propertyCount or !scan.indexed[comparison.property] or comparison.operator != .eq) return .unbounded;
            const probeValue = switch (comparison.value) {
                .int => |value| value,
                .bytes => return .unbounded,
            };
            const valueIndexReference = scan.valueIndexReferences[comparison.property];
            const innerRoot = (try index.get(transaction, valueIndexReference, probeValue)) orelse return .{ .exact = 0 };
            if (innerRoot == 0) return .{ .exact = 0 };
            return .{ .exact = try index.count(transaction, innerRoot) };
        },
        .conjunction => |children| {
            const driver = try mostSelectiveChild(transaction, scan, children, depth + 1);
            return if (driver) |found| found.selectivity else .unbounded;
        },
        .disjunction => |children| {
            var total: u64 = 0;
            for (children) |child| {
                switch (try selectivityOf(transaction, scan, child, depth + 1)) {
                    .exact => |count| total += count,
                    .unbounded => return .unbounded,
                }
            }
            return .{ .exact = total };
        },
        .negation => return .unbounded,
    }
}

// Appends objectKeys to a list; used to drain a value-index inner set (objectKey -> 1).
const ObjectKeyCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onKey(self: @This(), key: u64) !void {
        try self.list.append(self.allocator, key);
    }
};

// Appends each outer entry's value (an inner-set root reference) to a list; used to
// gather the inner sets a range scan of the value index touches.
const InnerRootCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onEntry(self: @This(), _: u64, value: u64) !void {
        try self.list.append(self.allocator, value);
    }
};

/// Append a superset of the objectKeys satisfying `predicate` to `candidates`.
/// Valid only for a predicate `canDriveFromIndex` accepts; anything else is
/// error.NoIndexPlan. Output is neither sorted nor deduplicated, the caller does
/// both. O(candidates) index reads.
pub fn collectCandidates(
    transaction: anytype,
    scan: *const Scan,
    predicate: Predicate,
    candidates: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    depth: usize,
) !void {
    if (depth >= maxPredicateDepth) return error.PredicateTooDeep;
    switch (predicate) {
        .comparison => |comparison| {
            if (comparison.property >= scan.propertyCount or !scan.indexed[comparison.property] or !isIndexFriendly(comparison.operator))
                return error.NoIndexPlan;
            const probeValue = switch (comparison.value) {
                .int => |value| value,
                .bytes => return error.NoIndexPlan,
            };
            const valueIndexReference = scan.valueIndexReferences[comparison.property];
            if (comparison.operator == .eq) {
                if (try index.get(transaction, valueIndexReference, probeValue)) |innerRoot| {
                    if (innerRoot != 0) {
                        try index.forEachKey(transaction, innerRoot, ObjectKeyCollector{ .list = candidates, .allocator = allocator }, ObjectKeyCollector.onKey);
                    }
                }
                return;
            }
            const bounds = rangeBounds(comparison.operator, probeValue) orelse return; // empty range
            var innerRoots = std.ArrayList(u64).empty;
            defer innerRoots.deinit(allocator);
            try index.forEachEntryInRange(transaction, valueIndexReference, bounds.lo, bounds.hi, InnerRootCollector{ .list = &innerRoots, .allocator = allocator }, InnerRootCollector.onEntry);
            for (innerRoots.items) |innerRoot| {
                if (innerRoot == 0) continue;
                try index.forEachKey(transaction, innerRoot, ObjectKeyCollector{ .list = candidates, .allocator = allocator }, ObjectKeyCollector.onKey);
            }
        },
        .conjunction => |children| {
            const driver = (try mostSelectiveChild(transaction, scan, children, depth + 1)) orelse return error.NoIndexPlan;
            try collectCandidates(transaction, scan, driver.child, candidates, allocator, depth + 1);
        },
        .disjunction => |children| {
            for (children) |child| {
                if (!canDriveFromIndexAt(scan, child, depth + 1)) return error.NoIndexPlan;
                try collectCandidates(transaction, scan, child, candidates, allocator, depth + 1);
            }
        },
        .negation => return error.NoIndexPlan,
    }
}

test {
    _ = @import("plannerTests.zig");
}
