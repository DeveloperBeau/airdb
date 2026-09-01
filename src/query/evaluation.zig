//! Evaluates a predicate tree against one physical row's column values.

const predicateModule = @import("predicate.zig");
const Operator = predicateModule.Operator;
const Predicate = predicateModule.Predicate;
const Match = predicateModule.Match;
const maxPredicateDepth = predicateModule.maxPredicateDepth;
const Scan = @import("scan.zig").Scan;
const Column = @import("../trees/column.zig");

/// Whether `storedValue` satisfies `operator` against `probeValue`.
/// `beginsWith` has no int form and is rejected.
pub fn matches(operator: Operator, storedValue: u64, probeValue: u64) !bool {
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

/// Evaluate `predicate` against one physical row. Reads one column value per
/// comparison node reached, so O(nodes) tree reads; short-circuits, which is
/// sound only because `Predicate.validate` has already walked every node.
pub fn evaluatePredicate(transaction: anytype, scan: *const Scan, row: u64, predicate: Predicate) !Match {
    return evaluatePredicateAt(transaction, scan, row, predicate, 0);
}

fn evaluatePredicateAt(transaction: anytype, scan: *const Scan, row: u64, predicate: Predicate, depth: usize) !Match {
    if (depth >= maxPredicateDepth) return error.PredicateTooDeep;
    switch (predicate) {
        .comparison => |comparison| {
            const probeValue = switch (comparison.value) {
                .int => |value| value,
                .bytes => return error.UnsupportedPredicate,
            };
            const storedValue = try Column.get(transaction, scan.propertyReferences[comparison.property], row);
            return if (try matches(comparison.operator, storedValue, probeValue)) .matched else .unmatched;
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
