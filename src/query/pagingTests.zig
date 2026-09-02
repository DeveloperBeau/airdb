//! Test suite for PageCollector: pure, no database.

const std = @import("std");
const testing = std.testing;
const ordering = @import("ordering.zig");
const Page = ordering.Page;
const Cursor = ordering.Cursor;
const paging = @import("paging.zig");
const PageCollector = paging.PageCollector;

test "D1: with no limit every offered key is collected" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var collector = PageCollector.init(.{}, &out, testing.allocator);
    for ([_]u64{ 10, 20, 30 }) |key| try testing.expect(try collector.collect(key));
    try testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, out.items);
}

test "D2: offset skips exactly offset keys" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var collector = PageCollector.init(.{ .start = .{ .offset = 3 } }, &out, testing.allocator);
    var key: u64 = 0;
    while (key < 10) : (key += 1) _ = try collector.collect(key);
    try testing.expectEqualSlices(u64, &.{ 3, 4, 5, 6, 7, 8, 9 }, out.items);
}

test "D3: limit zero is full before the first offer" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var collector = PageCollector.init(.{ .limit = 0 }, &out, testing.allocator);
    try testing.expect(collector.isFull());
    try testing.expect(!(try collector.collect(1)));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "D4: collect returns false on the key that fills the page, and true on the one before it" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var collector = PageCollector.init(.{ .limit = 2 }, &out, testing.allocator);
    try testing.expect(try collector.collect(1));
    try testing.expect(!(try collector.collect(2)));
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, out.items);
}

test "D5: offset maxInt with limit maxInt collects nothing and does not overflow" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    var collector = PageCollector.init(.{ .start = .{ .offset = std.math.maxInt(u64) }, .limit = std.math.maxInt(u64) }, &out, testing.allocator);
    for ([_]u64{ 1, 2, 3, 4, 5 }) |key| try testing.expect(try collector.collect(key));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "D6: a cursor start skips nothing" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    const cursor = Cursor{ .lastValue = 7, .lastObjectKey = 7 };
    var collector = PageCollector.init(.{ .start = .{ .after = cursor } }, &out, testing.allocator);
    try testing.expect(try collector.collect(8));
    try testing.expectEqualSlices(u64, &.{8}, out.items);
}

test "D8: a collector appends to a list that already has items without disturbing them" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try out.append(testing.allocator, 111);
    try out.append(testing.allocator, 222);
    var collector = PageCollector.init(.{}, &out, testing.allocator);
    _ = try collector.collect(333);
    try testing.expectEqualSlices(u64, &.{ 111, 222, 333 }, out.items);
}

test "D7: fuzz, the collected slice equals the reference slice" {
    var seed: u64 = 0;
    while (seed < 500) : (seed += 1) {
        errdefer std.debug.print("D7 failed at seed {d}\n", .{seed});
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        const offset = random.intRangeAtMost(u64, 0, 20);
        const hasLimit = random.boolean();
        const limit: ?u64 = if (hasLimit) random.intRangeAtMost(u64, 0, 20) else null;
        const sequenceLength = random.intRangeAtMost(usize, 0, 30);
        var sequence = std.ArrayList(u64).empty;
        defer sequence.deinit(testing.allocator);
        var nextKey: u64 = 0;
        while (sequence.items.len < sequenceLength) : (nextKey += 1) {
            try sequence.append(testing.allocator, nextKey * 3 + seed);
        }

        // Reference: slice the sequence with plain arithmetic.
        const start = @min(offset, sequence.items.len);
        const end = if (limit) |pageLimit| @min(start +| pageLimit, sequence.items.len) else sequence.items.len;
        const expected = sequence.items[start..end];

        var out = std.ArrayList(u64).empty;
        defer out.deinit(testing.allocator);
        var collector = PageCollector.init(.{ .start = .{ .offset = offset }, .limit = limit }, &out, testing.allocator);
        for (sequence.items) |key| {
            if (!(try collector.collect(key))) break;
        }
        try testing.expectEqualSlices(u64, expected, out.items);
        if (limit) |pageLimit| try testing.expect(out.items.len <= pageLimit);
    }
}
