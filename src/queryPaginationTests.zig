//! Behaviour suite for pages, ordering and cursors: `where` with a `Request`,
//! `first`, `exists`, `cursorAfter`, and `sortByProperty`. A second suite
//! beside queryTests.zig, following the precedent phase 1 set with
//! queryDifferentialTests.zig, so this file stays about pagination and
//! ordering rather than growing queryTests.zig further.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;
const Predicate = query.Predicate;
const Operator = query.Operator;
const Request = query.Request;
const where = query.where;

fn qpTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// Build a type with primaryKey(int) + age(int) and insert (primaryKey, age) rows.
fn seed(writeTransaction: anytype, pairs: []const [2]u64) !Reference {
    var catalogReference = try catalog.create(writeTransaction, 2);
    for (pairs) |pair| catalogReference = (try rows.insert(writeTransaction, catalogReference, &.{ pair[0], pair[1] })).catalogReference;
    return catalogReference;
}

test "P1: an unpaged request returns exactly what an unpaged phase 1 query returned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qpTmpPath(testing.allocator, &tmp, "p1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try seed(&writeTransaction, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    var hits1 = std.ArrayList(u64).empty;
    defer hits1.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = intComparison(1, .eq, 30) }, &hits1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits1.items.len);

    const conjunction2 = [_]Predicate{ intComparison(1, .gt, 25), intComparison(0, .lt, 4) };
    var hits2 = std.ArrayList(u64).empty;
    defer hits2.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = .{ .conjunction = &conjunction2 } }, &hits2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits2.items.len);

    var out: [2]u64 = undefined;
    const version2 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 2, version2)).ok;
    var hits3 = std.ArrayList(u64).empty;
    defer hits3.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = intComparison(1, .eq, 30) }, &hits3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits3.items.len);
    writeTransaction.deinit();
}
