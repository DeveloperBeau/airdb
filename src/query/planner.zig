//! Chooses whether a predicate tree can be answered from value indexes and,
//! when it can, gathers the candidate objectKeys those indexes hold.
//!
//! The candidate set a plan produces is a **superset** of the true result
//! set. Correctness is restored by residual-filtering the whole predicate
//! tree over every candidate.

const std = @import("std");
const predicateModule = @import("predicate.zig");
const Operator = predicateModule.Operator;
const ComparisonValue = predicateModule.ComparisonValue;
const Predicate = predicateModule.Predicate;
const Comparison = predicateModule.Comparison;
const maxPredicateDepth = predicateModule.maxPredicateDepth;
const Scan = @import("scan.zig").Scan;
const index = @import("../trees/index.zig");
const byteKeyIndex = @import("../trees/byteKeyIndex.zig");
const blobIndexKey = @import("../records/blobIndexKey.zig");
const catalog = @import("../schema/catalog.zig");

/// How many candidate objectKeys a node is expected to yield, as an upper
/// bound. Used only to rank the children of a conjunction, so an overestimate
/// picks a slower driver and never a wrong answer. `unbounded` marks a range
/// node, always ranked last. For an int property the bound is exact; for a
/// blob property, truncated keys make it an overestimate whenever two values
/// share a 256-byte prefix.
pub const Selectivity = union(enum) { atMost: u64, unbounded };

/// Whether a value index can serve `operator` over `value` for a property of
/// `kind`. An int comparison is served by the u64-keyed value index of an int
/// or link property. A bytes comparison is served by the byte-keyed value
/// index of a `.blob` property, whose keys are TRUNCATED
/// (blobIndexKey.maxLength), so what it yields is a superset of the true match
/// set and the residual filter in execution.runQuery is what makes the answer
/// exact. `ne` is served by neither: its complement spans the whole key space.
/// The kind arms are defensive as well as functional, since Predicate.validate
/// already rejects a mismatched value and kind before planning.
fn isIndexFriendly(operator: Operator, value: ComparisonValue, kind: catalog.PropertyKind) bool {
    return switch (value) {
        .bytes => kind == .blob and switch (operator) {
            .eq, .lt, .le, .gt, .ge, .beginsWith => true,
            .ne => false,
        },
        .int => (kind == .int or kind == .link) and switch (operator) {
            .eq, .lt, .le, .gt, .ge => true,
            .ne, .beginsWith => false,
        },
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
            scan.indexed[comparison.property] and isIndexFriendly(comparison.operator, comparison.value, scan.propertyKinds[comparison.property]),
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

/// An inclusive [low, high] key range over a value index.
pub const Bounds = struct { low: u64, high: u64 };

/// Translate a range operator + value into an inclusive [low, high] over u64.
/// Returns null when the range is provably empty (gt maxInt, lt 0), so the
/// caller emits zero candidates.
///   ge v -> [v, max]      gt v -> [v+1, max]  (empty if v == max)
///   le v -> [0, v]        lt v -> [0, v-1]    (empty if v == 0)
pub fn rangeBounds(operator: Operator, value: u64) ?Bounds {
    const max = std.math.maxInt(u64);
    return switch (operator) {
        .ge => Bounds{ .low = value, .high = max },
        .gt => if (value == max) null else Bounds{ .low = value + 1, .high = max },
        .le => Bounds{ .low = 0, .high = value },
        .lt => if (value == 0) null else Bounds{ .low = 0, .high = value - 1 },
        else => unreachable,
    };
}

/// Whether `left` is expected to yield fewer candidates than `right`. Any
/// bound beats an unbounded range; two ranges tie, so the first wins.
pub fn isMoreSelective(left: Selectivity, right: Selectivity) bool {
    return switch (left) {
        .atMost => |leftCount| switch (right) {
            .atMost => |rightCount| leftCount < rightCount,
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
            const kind = scan.propertyKinds[comparison.property];
            // Defensive guard: isIndexFriendly already forecloses a bytes
            // comparison against a non-blob property (and an int comparison
            // against a non-int/link property) from reaching here through
            // canDriveFromIndex/runQuery. Correct for a direct caller regardless.
            if (switch (comparison.value) {
                .bytes => kind != .blob,
                .int => kind != .int and kind != .link,
            }) return .unbounded;
            const valueIndexReference = scan.valueIndexReferences[comparison.property];
            const innerRoot = switch (comparison.value) {
                .int => |value| try index.get(transaction, valueIndexReference, value),
                .bytes => |probeBytes| try byteKeyIndex.get(transaction, valueIndexReference, blobIndexKey.truncated(probeBytes)),
            } orelse return .{ .atMost = 0 };
            if (innerRoot == 0) return .{ .atMost = 0 };
            return .{ .atMost = try index.count(transaction, innerRoot) };
        },
        .conjunction => |children| {
            const driver = try mostSelectiveChild(transaction, scan, children, depth + 1);
            return if (driver) |found| found.selectivity else .unbounded;
        },
        .disjunction => |children| {
            var total: u64 = 0;
            for (children) |child| {
                switch (try selectivityOf(transaction, scan, child, depth + 1)) {
                    .atMost => |count| total += count,
                    .unbounded => return .unbounded,
                }
            }
            return .{ .atMost = total };
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

// Append every objectKey in one value-index inner set to `candidates`.
fn collectInnerSet(transaction: anytype, innerRoot: u64, candidates: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
    if (innerRoot == 0) return;
    try index.forEachKey(transaction, innerRoot, ObjectKeyCollector{ .list = candidates, .allocator = allocator }, ObjectKeyCollector.onKey);
}

// Append a superset of the objectKeys whose int/link property satisfies
// `comparison` to `candidates`. `eq` is one descent; the four range operators
// are one range walk collecting inner roots, then one drain per root.
fn collectIntCandidates(
    transaction: anytype,
    scan: *const Scan,
    comparison: Comparison,
    probeValue: u64,
    candidates: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const valueIndexReference = scan.valueIndexReferences[comparison.property];
    if (comparison.operator == .eq) {
        const innerRoot = (try index.get(transaction, valueIndexReference, probeValue)) orelse return;
        return collectInnerSet(transaction, innerRoot, candidates, allocator);
    }
    const bounds = rangeBounds(comparison.operator, probeValue) orelse return; // empty range
    var innerRoots = std.ArrayList(u64).empty;
    defer innerRoots.deinit(allocator);
    try index.forEachEntryInRange(transaction, valueIndexReference, bounds.low, bounds.high, InnerRootCollector{ .list = &innerRoots, .allocator = allocator }, InnerRootCollector.onEntry);
    for (innerRoots.items) |innerRoot| try collectInnerSet(transaction, innerRoot, candidates, allocator);
}

/// The first index key an ascending candidate walk must visit for `operator`
/// against `probeKey`. INCLUSIVE in every case, `gt` included, and that is not
/// an oversight: keys are truncated, so `value > probe` only implies
/// `key(value) >= key(probe)`, never `>`. A value longer than 256 bytes that
/// shares the probe's prefix, or a probe longer than 256 bytes, both land on
/// the probe's own key while genuinely comparing greater. Starting after it
/// would drop true matches and break the superset invariant. `lt` and `le`
/// have no lower bound, so they start at the empty key, which precedes every
/// key. O(1), no I/O.
fn candidateStartKey(operator: Operator, probeKey: []const u8) []const u8 {
    return switch (operator) {
        .lt, .le => "",
        .gt, .ge, .beginsWith => probeKey,
        // eq is served by a direct get and never walks; ne is not index-friendly.
        .eq, .ne => unreachable,
    };
}

/// Whether an ascending candidate walk that started at `candidateStartKey`
/// should still be collecting at `key`. The candidate range is contiguous in
/// byte order, so the first false ends the walk. INCLUSIVE at the high end for
/// `lt` for the mirror of the reason `gt` is inclusive at the low end:
/// `value < probe` only implies `key(value) <= key(probe)`. O(key length), no
/// I/O.
fn isWithinCandidateRange(operator: Operator, key: []const u8, probeKey: []const u8) bool {
    return switch (operator) {
        .beginsWith => std.mem.startsWith(u8, key, probeKey),
        .lt, .le => std.mem.order(u8, key, probeKey) != .gt,
        .gt, .ge => true,
        .eq, .ne => unreachable,
    };
}

// Append a superset of the objectKeys whose blob property satisfies
// `comparison` to `candidates`. `eq` is one descent; the four range operators
// and `beginsWith` are one descent plus an ascending walk that stops at the
// first key outside the candidate range. Keys are truncated, so what this
// yields over-matches by design and the caller's residual filter is what makes
// the answer exact. O(log n + candidates) with I/O.
//
// Unlike collectIntCandidates, this does not materialize the inner roots into
// a list before draining them: the int path does that because
// index.forEachEntryInRange reenters the same tree it is walking, while here
// the drain walks a DIFFERENT tree (a numeric inner set), so draining inside
// the callback is safe. The key slice is not held past the callback.
fn collectBytesCandidates(
    transaction: anytype,
    scan: *const Scan,
    comparison: Comparison,
    probeBytes: []const u8,
    candidates: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const valueIndexReference = scan.valueIndexReferences[comparison.property];
    const probeKey = blobIndexKey.truncated(probeBytes);
    if (comparison.operator == .eq) {
        const innerRoot = (try byteKeyIndex.get(transaction, valueIndexReference, probeKey)) orelse return;
        return collectInnerSet(transaction, innerRoot, candidates, allocator);
    }
    const Walk = struct {
        transaction: @TypeOf(transaction),
        operator: Operator,
        probeKey: []const u8,
        candidates: *std.ArrayList(u64),
        allocator: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, innerRoot: u64) anyerror!bool {
            if (!isWithinCandidateRange(self.operator, key, self.probeKey)) return false;
            try collectInnerSet(self.transaction, innerRoot, self.candidates, self.allocator);
            return true;
        }
    };
    _ = try byteKeyIndex.forEachEntryFromWhile(
        transaction,
        valueIndexReference,
        candidateStartKey(comparison.operator, probeKey),
        Walk{ .transaction = transaction, .operator = comparison.operator, .probeKey = probeKey, .candidates = candidates, .allocator = allocator },
        Walk.onEntry,
    );
}

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
            if (comparison.property >= scan.propertyCount or !scan.indexed[comparison.property] or
                !isIndexFriendly(comparison.operator, comparison.value, scan.propertyKinds[comparison.property]))
                return error.NoIndexPlan;
            return switch (comparison.value) {
                .int => |probeValue| collectIntCandidates(transaction, scan, comparison, probeValue, candidates, allocator),
                .bytes => |probeBytes| collectBytesCandidates(transaction, scan, comparison, probeBytes, candidates, allocator),
            };
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

// ---------------------------------------------------------------------------
// Tests of this file's own private invariants (candidateStartKey and
// isWithinCandidateRange are not pub, so their tests live here rather than in
// plannerTests.zig; the bulk suite for the pub API lives there).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "candidateStartKey: lt and le start at the empty key; gt, ge and beginsWith start at the probe" {
    try testing.expectEqualStrings("", candidateStartKey(.lt, "ban"));
    try testing.expectEqualStrings("", candidateStartKey(.le, "ban"));
    // gt starting AT the probe (not after it) is the assertion that proves the
    // inclusive start: truncation means value > probe only implies key(value)
    // >= key(probe), never strictly greater.
    try testing.expectEqualStrings("ban", candidateStartKey(.gt, "ban"));
    try testing.expectEqualStrings("ban", candidateStartKey(.ge, "ban"));
    try testing.expectEqualStrings("ban", candidateStartKey(.beginsWith, "ban"));
}

test "isWithinCandidateRange: beginsWith matches only keys carrying the probe as a byte prefix" {
    try testing.expect(isWithinCandidateRange(.beginsWith, "ban", "ban"));
    try testing.expect(isWithinCandidateRange(.beginsWith, "banana", "ban"));
    try testing.expect(!isWithinCandidateRange(.beginsWith, "ba", "ban"));
    try testing.expect(!isWithinCandidateRange(.beginsWith, "bao", "ban"));
}

test "isWithinCandidateRange: le is true up to and including the probe key" {
    try testing.expect(isWithinCandidateRange(.le, "a", "ban"));
    try testing.expect(isWithinCandidateRange(.le, "ban", "ban"));
    try testing.expect(!isWithinCandidateRange(.le, "bana", "ban"));
}

test "isWithinCandidateRange: lt is inclusive at the probe key itself, because truncation can map a smaller value onto it" {
    try testing.expect(isWithinCandidateRange(.lt, "ban", "ban"));
    try testing.expect(!isWithinCandidateRange(.lt, "bana", "ban"));
}

test "isWithinCandidateRange: gt and ge are true for every key, including one below the probe, because the walk started at the right place" {
    try testing.expect(isWithinCandidateRange(.gt, "aaa", "ban"));
    try testing.expect(isWithinCandidateRange(.gt, "ban", "ban"));
    try testing.expect(isWithinCandidateRange(.ge, "aaa", "ban"));
    try testing.expect(isWithinCandidateRange(.ge, "ban", "ban"));
}

test {
    _ = @import("plannerTests.zig");
}
