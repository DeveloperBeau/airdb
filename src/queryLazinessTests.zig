//! Measures the work each delivery path does, in dereferences, rather than
//! inspecting returned rows: a materialize-everything implementation returns
//! the same rows a lazy one does, so laziness can only be proven by counting
//! reads. Every bound below is a literal, hand-written against the fixture
//! sizes; none is computed from production code or from another measurement.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const ReadTransaction = @import("database.zig").ReadTransaction;
const Predicate = query.Predicate;
const Operator = query.Operator;
const Request = query.Request;
const where = query.where;
const first = query.first;
const exists = query.exists;

/// Counts every dereference the query engine performs, so a test can assert
/// that a bounded page does bounded work. Satisfies the read-only transaction
/// capability the tree and column layers require.
const CountingTransaction = struct {
    inner: *ReadTransaction,
    dereferenceCount: u64 = 0,

    pub fn dereference(self: *CountingTransaction, reference: Reference, length: usize) ![]const u8 {
        self.dereferenceCount += 1;
        return self.inner.dereference(reference, length);
    }
};

fn qlTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// Build and commit a type: property0 = primaryKey, property1 = indexed
// (primaryKey % 100), property2 = unindexed (primaryKey % 100). Returns the
// catalog's own Reference, which is the database root.
fn buildFixture(allocator: std.mem.Allocator, path: []const u8, rowCount: u64) !Database {
    var database = try Database.create(allocator, path);
    var writeTransaction = try database.beginWrite();
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);
    var rowIndex: u64 = 0;
    while (rowIndex < rowCount) : (rowIndex += 1) {
        catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ rowIndex, rowIndex % 100, rowIndex % 100 })).catalogReference;
    }
    writeTransaction.setRoot(catalogReference);
    _ = try writeTransaction.commit();
    return database;
}

fn measureWhere(readTransaction: *ReadTransaction, catalogReference: Reference, request: Request) !u64 {
    var counting = CountingTransaction{ .inner = readTransaction };
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try where(&counting, catalogReference, request, &out, testing.allocator);
    return counting.dereferenceCount;
}

fn measureFirst(readTransaction: *ReadTransaction, catalogReference: Reference, request: Request) !u64 {
    var counting = CountingTransaction{ .inner = readTransaction };
    _ = try first(&counting, catalogReference, request, testing.allocator);
    return counting.dereferenceCount;
}

fn measureExists(readTransaction: *ReadTransaction, catalogReference: Reference, request: Request) !u64 {
    var counting = CountingTransaction{ .inner = readTransaction };
    _ = try exists(&counting, catalogReference, request, testing.allocator);
    return counting.dereferenceCount;
}

test "L1: a bounded objectKey-ascending page does far less work than an unbounded scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l1.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const paged = try measureWhere(&readTransaction, catalogReference, .{ .page = .{ .limit = 10 } });
    try testing.expect(paged < 500);

    // False-positive guard for the whole file: the unpaged scan must be
    // genuinely large, or "paged < 500" would mean nothing (e.g. a fixture
    // that accidentally seeded 3 rows would pass every other line here).
    const unpaged = try measureWhere(&readTransaction, catalogReference, .{});
    try testing.expect(unpaged > 20_000);
}

test "L2: a bounded objectKey-descending page does far less work than a full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l2.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const paged = try measureWhere(&readTransaction, catalogReference, .{ .ordering = .{ .order = .descending }, .page = .{ .limit = 10 } });
    try testing.expect(paged < 500);
}

test "L3: a bounded indexed-property-ascending page does far less work than a full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l3.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const paged = try measureWhere(&readTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } }, .page = .{ .limit = 10 } });
    try testing.expect(paged < 500);
}

test "L4: a bounded indexed-property-descending page does far less work than a full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l4.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const paged = try measureWhere(&readTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending }, .page = .{ .limit = 10 } });
    try testing.expect(paged < 500);
}

test "L5: a limit-zero page does only the catalog load, for any ordering" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l5.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const configurations = [_]Request{
        .{ .page = .{ .limit = 0 } },
        .{ .ordering = .{ .order = .descending }, .page = .{ .limit = 0 } },
        .{ .ordering = .{ .sortKey = .{ .property = 1 } }, .page = .{ .limit = 0 } },
        .{ .ordering = .{ .sortKey = .{ .property = 1 }, .order = .descending }, .page = .{ .limit = 0 } },
    };
    for (configurations) |request| {
        const count = try measureWhere(&readTransaction, catalogReference, request);
        try testing.expect(count < 10);
    }
}

test "L6: first with a predicate matched by the first row does bounded work" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l6.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const count = try measureFirst(&readTransaction, catalogReference, .{ .predicate = intComparison(0, .eq, 0) });
    try testing.expect(count < 500);
}

test "L7: exists with a predicate matched early does bounded work" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l7.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const count = try measureExists(&readTransaction, catalogReference, .{ .predicate = intComparison(0, .eq, 0) });
    try testing.expect(count < 500);
}

test "L8: a deep offset page costs far more than reaching the same page by cursor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l8.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const offsetCount = try measureWhere(&readTransaction, catalogReference, .{ .page = .{ .start = .{ .offset = 7000 }, .limit = 10 } });
    try testing.expect(offsetCount > 20_000);

    const cursor = query.Cursor{ .lastValue = 6999, .lastObjectKey = 6999 };
    const cursorCount = try measureWhere(&readTransaction, catalogReference, .{ .page = .{ .start = .{ .after = cursor }, .limit = 10 } });
    try testing.expect(cursorCount < 500);
}

test "L9: the cost of a bounded page barely grows between a 1000-row and an 8000-row fixture" {
    var smallTmp = testing.tmpDir(.{});
    defer smallTmp.cleanup();
    const smallPath = try qlTmpPath(testing.allocator, &smallTmp, "l9_small.airdb");
    defer testing.allocator.free(smallPath);
    var smallDatabase = try buildFixture(testing.allocator, smallPath, 1000);
    defer smallDatabase.deinit();
    var smallReadTransaction = try smallDatabase.beginRead();
    defer smallReadTransaction.end();
    const smallCount = try measureWhere(&smallReadTransaction, smallReadTransaction.root(), .{ .page = .{ .limit = 10 } });

    var largeTmp = testing.tmpDir(.{});
    defer largeTmp.cleanup();
    const largePath = try qlTmpPath(testing.allocator, &largeTmp, "l9_large.airdb");
    defer testing.allocator.free(largePath);
    var largeDatabase = try buildFixture(testing.allocator, largePath, 8000);
    defer largeDatabase.deinit();
    var largeReadTransaction = try largeDatabase.beginRead();
    defer largeReadTransaction.end();
    const largeCount = try measureWhere(&largeReadTransaction, largeReadTransaction.root(), .{ .page = .{ .limit = 10 } });

    try testing.expect(largeCount < smallCount + 100);
}

test "L10: unindexed property ordering is NOT lazy, pinning the documented non-lazy path" {
    // This test asserts the opposite of every other test in this file on
    // purpose: it makes the "NOT lazy" sentence in
    // deliverBySortedMaterialization's doc comment a checked claim. If a
    // later phase makes that path lazy, this test starts failing and must be
    // deleted in the same commit that changes the doc comment.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qlTmpPath(testing.allocator, &tmp, "l10.airdb");
    defer testing.allocator.free(path);
    var database = try buildFixture(testing.allocator, path, 8000);
    defer database.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = readTransaction.root();

    const count = try measureWhere(&readTransaction, catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 2 } }, .page = .{ .limit = 10 } });
    try testing.expect(count > 8000);
}
