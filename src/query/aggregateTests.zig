//! Test suite for Aggregate.accumulate: pure, no database.

const std = @import("std");
const testing = std.testing;
const Aggregate = @import("aggregate.zig").Aggregate;

test "A1: the empty aggregate has zero count, zero sum, and null min/max" {
    const aggregate: Aggregate = .{};
    try testing.expectEqual(@as(u64, 0), aggregate.count);
    try testing.expectEqual(@as(u64, 0), aggregate.sum);
    try testing.expectEqual(@as(?u64, null), aggregate.min);
    try testing.expectEqual(@as(?u64, null), aggregate.max);
}

test "A2: one accumulate sets count 1, sum, min and max to that value" {
    var aggregate: Aggregate = .{};
    aggregate.accumulate(7);
    try testing.expectEqual(@as(u64, 1), aggregate.count);
    try testing.expectEqual(@as(u64, 7), aggregate.sum);
    try testing.expectEqual(@as(?u64, 7), aggregate.min);
    try testing.expectEqual(@as(?u64, 7), aggregate.max);
}

test "A3: accumulate over 5, 3, 9 gives count 3, sum 17, min 3, max 9" {
    var aggregate: Aggregate = .{};
    aggregate.accumulate(5);
    aggregate.accumulate(3);
    aggregate.accumulate(9);
    try testing.expectEqual(@as(u64, 3), aggregate.count);
    try testing.expectEqual(@as(u64, 17), aggregate.sum);
    try testing.expectEqual(@as(?u64, 3), aggregate.min);
    try testing.expectEqual(@as(?u64, 9), aggregate.max);
}

test "A4: failure/boundary, accumulate(maxInt) twice wraps sum" {
    var aggregate: Aggregate = .{};
    aggregate.accumulate(std.math.maxInt(u64));
    aggregate.accumulate(std.math.maxInt(u64));
    try testing.expectEqual(std.math.maxInt(u64) - 1, aggregate.sum);
}

test "A5: false-positive validation, min stays above 5 when every value is above 5" {
    var aggregate: Aggregate = .{};
    aggregate.accumulate(6);
    aggregate.accumulate(8);
    aggregate.accumulate(10);
    try testing.expect(aggregate.min.? > 5);
}

test "A6: false-negative validation, a later smaller value moves min" {
    var aggregate: Aggregate = .{};
    aggregate.accumulate(9);
    aggregate.accumulate(8);
    aggregate.accumulate(2);
    try testing.expectEqual(@as(?u64, 2), aggregate.min);
    try testing.expect(aggregate.min.? != 9);
}
