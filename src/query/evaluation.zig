//! Evaluates a predicate tree against one physical row's column values.

const std = @import("std");
const predicateModule = @import("predicate.zig");
const Operator = predicateModule.Operator;
const Predicate = predicateModule.Predicate;
const Match = predicateModule.Match;
const maxPredicateDepth = predicateModule.maxPredicateDepth;
const Scan = @import("scan.zig").Scan;
const Column = @import("../trees/column.zig");
const Reference = @import("../storage/reference.zig").Reference;
const blob = @import("../records/blob.zig");

/// Whether `storedValue` satisfies `operator` against `probeValue`.
/// `beginsWith` has no int form and is rejected.
pub fn matchesInt(operator: Operator, storedValue: u64, probeValue: u64) !bool {
    return switch (operator) {
        .eq => storedValue == probeValue,
        .ne => storedValue != probeValue,
        .lt => storedValue < probeValue,
        .le => storedValue <= probeValue,
        .gt => storedValue > probeValue,
        .ge => storedValue >= probeValue,
        .beginsWith => error.UnsupportedPredicate,
    };
}

/// Whether `order`, the order of a stored value relative to a probe, satisfies
/// `operator`. `beginsWith` is not an order comparison and is rejected. O(1),
/// no I/O.
pub fn matchesOrder(operator: Operator, order: std.math.Order) !bool {
    return switch (operator) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
        .beginsWith => error.UnsupportedPredicate,
    };
}

/// Whether the blob at `storedReference` satisfies `operator` against `probe`,
/// comparing bytes unsigned and lexicographically. The null reference is the
/// empty byte string. Streams the stored bytes, so a chunked blob costs no
/// allocation. O(bytes examined) with I/O.
pub fn matchesBytes(transaction: anytype, operator: Operator, storedReference: Reference, probe: []const u8) !bool {
    // The query language says beginsWith; the byte layer says startsWith.
    if (operator == .beginsWith) return blob.startsWith(transaction, storedReference, probe);
    return matchesOrder(operator, try blob.compare(transaction, storedReference, probe));
}

/// Evaluate `predicate` against one physical row. Reads one column value per
/// comparison node reached (plus, for a bytes comparison, the blob reads that
/// comparison needs), so O(nodes) tree reads plus O(bytes examined);
/// short-circuits, which is sound only because `Predicate.validate` has
/// already walked every node.
pub fn evaluatePredicate(transaction: anytype, scan: *const Scan, row: u64, predicate: Predicate) !Match {
    return evaluatePredicateAt(transaction, scan, row, predicate, 0);
}

fn evaluatePredicateAt(transaction: anytype, scan: *const Scan, row: u64, predicate: Predicate, depth: usize) !Match {
    if (depth >= maxPredicateDepth) return error.PredicateTooDeep;
    switch (predicate) {
        .comparison => |comparison| {
            // A blob column's word IS the blob's storage reference, which is what
            // matchesBytes dereferences; every other supported kind's word is the
            // value itself.
            const storedValue = try Column.get(transaction, scan.propertyReferences[comparison.property], row);
            const satisfied = switch (comparison.value) {
                .int => |probeValue| try matchesInt(comparison.operator, storedValue, probeValue),
                .bytes => |probeBytes| try matchesBytes(transaction, comparison.operator, storedValue, probeBytes),
            };
            return if (satisfied) .matched else .unmatched;
        },
        .conjunction => |children| {
            var outcome: Match = .matched;
            for (children) |child| {
                outcome = outcome.conjoined(try evaluatePredicateAt(transaction, scan, row, child, depth + 1));
                if (outcome == .unmatched) return .unmatched;
            }
            return outcome;
        },
        .disjunction => |children| {
            var outcome: Match = .unmatched;
            for (children) |child| {
                outcome = outcome.disjoined(try evaluatePredicateAt(transaction, scan, row, child, depth + 1));
                if (outcome == .matched) return .matched;
            }
            return outcome;
        },
        .negation => |child| return (try evaluatePredicateAt(transaction, scan, row, child.*, depth + 1)).negated(),
    }
}

/// Whether `row` is live and evaluates to `.matched`. One live-column read
/// plus the predicate's reads.
pub fn isLiveMatch(transaction: anytype, scan: *const Scan, row: u64, predicate: Predicate) !bool {
    if ((try Column.get(transaction, scan.liveColumnReference, row)) == 0) return false;
    return (try evaluatePredicate(transaction, scan, row, predicate)) == .matched;
}

test {
    _ = @import("evaluationTests.zig");
}
