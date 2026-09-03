//! The running aggregate a query terminal folds a set of property values into.

/// The result of aggregating one int or link property over a set of rows:
/// matched-row count, wrapping sum, and the smallest and largest value seen.
/// `min` and `max` are null until the first value arrives, so `.{}` is the
/// empty aggregate.
pub const Aggregate = struct {
    count: u64 = 0,
    sum: u64 = 0,
    min: ?u64 = null,
    max: ?u64 = null,

    /// Fold one property value in: bumps `count`, adds to `sum` wrapping on
    /// overflow, and widens `min` and `max`. O(1), no I/O.
    pub fn accumulate(self: *Aggregate, value: u64) void {
        self.count += 1;
        self.sum +%= value;
        if (self.min == null or value < self.min.?) self.min = value;
        if (self.max == null or value > self.max.?) self.max = value;
    }
};

test {
    _ = @import("aggregateTests.zig");
}
