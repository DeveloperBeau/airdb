//! The predicate language: comparisons combined with and/or/not into a tree.
//! Pure data plus pure validation, no I/O and no dependency on any storage
//! type beyond the property kinds a caller already has from the catalog.

const std = @import("std");
const catalog = @import("../schema/catalog.zig");

/// Deepest predicate nesting accepted. Predicates are caller-supplied and will
/// eventually arrive across the C ABI, which is an untrusted boundary.
pub const maxPredicateDepth: usize = 32;

/// Comparison a predicate applies to one property's value.
pub const Operator = enum { eq, ne, lt, le, gt, ge, beginsWith };

/// The right-hand side of a comparison: a raw u64 for int and link properties,
/// or bytes for blob properties.
pub const ComparisonValue = union(enum) { int: u64, bytes: []const u8 };

/// One filter clause: property `property` compared against `value` with `operator`.
pub const Comparison = struct {
    property: usize,
    operator: Operator,
    value: ComparisonValue,
};

/// A filter tree. Slices and the pointer break the recursion, so a caller
/// builds a tree from plain literals and the API allocates nothing. An empty
/// conjunction is vacuously true (it matches every live row); an empty
/// disjunction matches nothing.
pub const Predicate = union(enum) {
    comparison: Comparison,
    conjunction: []const Predicate,
    disjunction: []const Predicate,
    negation: *const Predicate,

    /// Reject a malformed tree before execution: a property index outside
    /// `propertyKinds`, a value whose type does not match the property's kind,
    /// or nesting past `maxPredicateDepth`. Walks every node, O(nodes), no I/O.
    pub fn validate(self: Predicate, propertyKinds: []const catalog.PropertyKind) !void {
        return validateAt(self, propertyKinds, 0);
    }
};

fn validateAt(self: Predicate, propertyKinds: []const catalog.PropertyKind, depth: usize) !void {
    if (depth >= maxPredicateDepth) return error.PredicateTooDeep;
    switch (self) {
        .comparison => |comparison| {
            if (comparison.property >= propertyKinds.len) return error.BadProperty;
            const kind = propertyKinds[comparison.property];
            switch (comparison.value) {
                .int => if (kind == .blob) return error.BadPredicate,
                .bytes => {
                    if (kind != .blob) return error.BadPredicate;
                    return error.UnsupportedPredicate;
                },
            }
            if (comparison.operator == .beginsWith and kind != .blob) return error.BadPredicate;
        },
        .conjunction, .disjunction => |children| for (children) |child| try validateAt(child, propertyKinds, depth + 1),
        .negation => |child| try validateAt(child.*, propertyKinds, depth + 1),
    }
}

/// Three-valued outcome of evaluating a predicate against one row. Every
/// property is non-null today, so `unknown` is never produced yet; the
/// combinators below already implement the Kleene tables so that adding a
/// source of `unknown` later changes no logic here.
pub const Match = enum {
    matched,
    unmatched,
    unknown,

    /// Kleene AND of two outcomes.
    pub fn conjoined(self: Match, other: Match) Match {
        if (self == .unmatched or other == .unmatched) return .unmatched;
        if (self == .unknown or other == .unknown) return .unknown;
        return .matched;
    }

    /// Kleene OR of two outcomes.
    pub fn disjoined(self: Match, other: Match) Match {
        if (self == .matched or other == .matched) return .matched;
        if (self == .unknown or other == .unknown) return .unknown;
        return .unmatched;
    }

    /// Kleene NOT: `unknown` negates to `unknown`.
    pub fn negated(self: Match) Match {
        return switch (self) {
            .matched => .unmatched,
            .unmatched => .matched,
            .unknown => .unknown,
        };
    }
};

test {
    _ = @import("predicateTests.zig");
}
