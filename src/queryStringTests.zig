//! Facade-level suite for string predicates over `.blob` properties: the
//! seven operators end to end through `where`/`countWhere`/`first`/`exists`,
//! the empty-blob (null-reference) row, the indexed-vs-unindexed blob
//! property (the C4 regression), composition with int predicates, a
//! differential fuzz against a brute-force reference, and the chunked path
//! reachable through the public facade.
//!
//! Fixture rule (spec): every expected value here is either a hand-written
//! literal or computed by std over bytes the test holds in RAM -- never a
//! second call into the engine under test.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const objects = @import("records/objects.zig");
const blobModule = @import("records/blob.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;

const Predicate = query.Predicate;
const Operator = query.Operator;
const where = query.where;

fn qsTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn bytesComparison(property: usize, operator: Operator, value: []const u8) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .bytes = value } } };
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

fn whereSorted(transaction: anytype, catalogReference: Reference, predicate: Predicate, out: *std.ArrayList(u64)) !void {
    try where(transaction, catalogReference, .{ .predicate = predicate }, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Sorted objectKeys of `objectKeys[i]` for each `i` in `indices`.
fn collectExpected(objectKeys: [6]u64, indices: []const usize, allocator: std.mem.Allocator) ![]u64 {
    const list = try allocator.alloc(u64, indices.len);
    for (indices, 0..) |index, position| list[position] = objectKeys[index];
    std.mem.sort(u64, list, {}, std.sort.asc(u64));
    return list;
}

// property0 = primaryKey(int), property1 = blob (unindexed), property2 = blob
// (indexed), mirroring property1. Seed values, in insertion order: "apple",
// "banana", "cherry", "", "bananas", "Banana". objectKeys are captured rather
// than assumed to equal the insertion ordinal.
const StringFixture = struct { catalogReference: Reference, objectKeys: [6]u64 };

fn seedStringCatalog(writeTransaction: *WriteTransaction) !StringFixture {
    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob },
        .{ .kind = .blob, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    const values = [_][]const u8{ "apple", "banana", "cherry", "", "bananas", "Banana" };
    var objectKeys: [6]u64 = undefined;
    for (values, 0..) |value, index| {
        const inserted = try objects.insertTyped(writeTransaction, catalogReference, &.{ .{ .int = @intCast(index) }, .{ .bytes = value }, .{ .bytes = value } });
        catalogReference = inserted.catalogReference;
        objectKeys[index] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .objectKeys = objectKeys };
}

// Index sets against probe "banana" for each operator, worked out by hand from
// the seed values apple=0, banana=1, cherry=2, ""=3, bananas=4, Banana=5.
const bananaEq = [_]usize{1};
const bananaNe = [_]usize{ 0, 2, 3, 4, 5 };
const bananaLt = [_]usize{ 0, 3, 5 };
const bananaLe = [_]usize{ 0, 1, 3, 5 };
const bananaGt = [_]usize{ 2, 4 };
const bananaGe = [_]usize{ 1, 2, 4 };
const bananaBeginsWith = [_]usize{ 1, 4 };

fn expectSevenOperatorsAgainstBanana(writeTransaction: *WriteTransaction, catalogReference: Reference, objectKeys: [6]u64, property: usize) !void {
    const Case = struct { operator: Operator, indices: []const usize };
    const cases = [_]Case{
        .{ .operator = .eq, .indices = &bananaEq },
        .{ .operator = .ne, .indices = &bananaNe },
        .{ .operator = .lt, .indices = &bananaLt },
        .{ .operator = .le, .indices = &bananaLe },
        .{ .operator = .gt, .indices = &bananaGt },
        .{ .operator = .ge, .indices = &bananaGe },
        .{ .operator = .beginsWith, .indices = &bananaBeginsWith },
    };
    for (cases) |case| {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(writeTransaction, catalogReference, bytesComparison(property, case.operator, "banana"), &hits);
        const expected = try collectExpected(objectKeys, case.indices, testing.allocator);
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(u64, expected, hits.items);
    }
}

test "T-Q1: seven operators end to end, probe \"banana\", unindexed property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);
    try expectSevenOperatorsAgainstBanana(&writeTransaction, fixture.catalogReference, fixture.objectKeys, 1);
}

test "T-Q2: the empty row's membership in each of the seven results, keyed to the D1 table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);
    const emptyRowKey = fixture.objectKeys[3];

    const Case = struct { operator: Operator, expectedMember: bool };
    const cases = [_]Case{
        .{ .operator = .eq, .expectedMember = false },
        .{ .operator = .ne, .expectedMember = true },
        .{ .operator = .lt, .expectedMember = true },
        .{ .operator = .le, .expectedMember = true },
        .{ .operator = .gt, .expectedMember = false },
        .{ .operator = .ge, .expectedMember = false },
        .{ .operator = .beginsWith, .expectedMember = false },
    };
    for (cases) |case| {
        var hits = std.ArrayList(u64).empty;
        defer hits.deinit(testing.allocator);
        try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(1, case.operator, "banana"), &hits);
        const isMember = std.mem.indexOfScalar(u64, hits.items, emptyRowKey) != null;
        try testing.expectEqual(case.expectedMember, isMember);
    }
}

test "T-Q3: an indexed blob property is not driven from the index (C4 regression); identical results to T-Q1" {
    // Before the C4 fix, isIndexFriendly did not consult the comparison's value
    // kind, so an eq on this indexed blob property took the index path and
    // collectCandidates's .bytes arm failed the whole query with
    // error.NoIndexPlan. This test would fail with that error pre-fix.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);
    try expectSevenOperatorsAgainstBanana(&writeTransaction, fixture.catalogReference, fixture.objectKeys, 2);
}

test "T-Q4: composition, negation/conjunction/disjunction over bytes and int predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);

    // not (property1 eq "banana") is the complement: everything but index 1.
    const eqBanana = bytesComparison(1, .eq, "banana");
    var negationHits = std.ArrayList(u64).empty;
    defer negationHits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, .{ .negation = &eqBanana }, &negationHits);
    const expectedNegation = try collectExpected(fixture.objectKeys, &bananaNe, testing.allocator);
    defer testing.allocator.free(expectedNegation);
    try testing.expectEqualSlices(u64, expectedNegation, negationHits.items);

    // property0 lt 3 (primaryKey values 0, 1, 2) and property1 beginsWith "b"
    // (indices 1 and 4) intersect at index 1 only.
    const conjunctionChildren = [_]Predicate{ intComparison(0, .lt, 3), bytesComparison(1, .beginsWith, "b") };
    var conjunctionHits = std.ArrayList(u64).empty;
    defer conjunctionHits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, .{ .conjunction = &conjunctionChildren }, &conjunctionHits);
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[1]}, conjunctionHits.items);

    // property1 eq "apple" or property1 eq "cherry": indices 0 and 2.
    const disjunctionChildren = [_]Predicate{ bytesComparison(1, .eq, "apple"), bytesComparison(1, .eq, "cherry") };
    var disjunctionHits = std.ArrayList(u64).empty;
    defer disjunctionHits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, .{ .disjunction = &disjunctionChildren }, &disjunctionHits);
    const expectedDisjunction = try collectExpected(fixture.objectKeys, &.{ 0, 2 }, testing.allocator);
    defer testing.allocator.free(expectedDisjunction);
    try testing.expectEqualSlices(u64, expectedDisjunction, disjunctionHits.items);
}

test "T-Q5: countWhere, first, and exists over a bytes predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);

    // beginsWith "b" matches indices 1 (banana) and 4 (bananas): count 2.
    const beginsB = bytesComparison(1, .beginsWith, "b");
    try testing.expectEqual(@as(u64, 2), try query.countWhere(&writeTransaction, fixture.catalogReference, beginsB, testing.allocator));

    const expectedFirst = @min(fixture.objectKeys[1], fixture.objectKeys[4]);
    const firstResult = try query.first(&writeTransaction, fixture.catalogReference, .{ .predicate = beginsB }, testing.allocator);
    try testing.expectEqual(expectedFirst, firstResult.?);

    try testing.expect(try query.exists(&writeTransaction, fixture.catalogReference, .{ .predicate = bytesComparison(1, .eq, "banana") }, testing.allocator));
    try testing.expect(!(try query.exists(&writeTransaction, fixture.catalogReference, .{ .predicate = bytesComparison(1, .eq, "durian") }, testing.allocator)));
}

test "T-Q6: ordering by a blob property is rejected with error.UnsupportedOrdering, indexed and unindexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedOrdering, where(&writeTransaction, fixture.catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 1 } } }, &hits, testing.allocator));
    try testing.expectError(error.UnsupportedOrdering, where(&writeTransaction, fixture.catalogReference, .{ .ordering = .{ .sortKey = .{ .property = 2 } } }, &hits, testing.allocator));
}

test "T-Q7: differential fuzz against a brute-force reference over std.mem" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob } };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);

    var prng = std.Random.DefaultPrng.init(20260902);
    const random = prng.random();
    const alphabet = "abc";

    const RowRecord = struct { objectKey: u64, bytes: [5]u8, length: usize };
    var records: [40]RowRecord = undefined;
    var rowIndex: usize = 0;
    while (rowIndex < 40) : (rowIndex += 1) {
        const length = random.intRangeLessThan(usize, 0, 6);
        var bytes: [5]u8 = undefined;
        for (bytes[0..length]) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, 3)];
        const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = @as(u64, rowIndex) }, .{ .bytes = bytes[0..length] } });
        catalogReference = inserted.catalogReference;
        records[rowIndex] = .{ .objectKey = inserted.objectKey, .bytes = bytes, .length = length };
    }

    const operators = [_]Operator{ .eq, .ne, .lt, .le, .gt, .ge, .beginsWith };
    var probeIndex: usize = 0;
    while (probeIndex < 20) : (probeIndex += 1) {
        // Force the empty probe and one probe longer than any stored value (max
        // stored length is 5) so the length tie-break is always exercised, per
        // the spec's failure-mode note; the rest are drawn at random.
        const probeLength = switch (probeIndex) {
            0 => 0,
            1 => 6,
            else => random.intRangeLessThan(usize, 0, 7),
        };
        var probeBuffer: [6]u8 = undefined;
        for (probeBuffer[0..probeLength]) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, 3)];
        const probe = probeBuffer[0..probeLength];

        for (operators) |operator| {
            var expected = std.ArrayList(u64).empty;
            defer expected.deinit(testing.allocator);
            for (records) |record| {
                const stored = record.bytes[0..record.length];
                const isMatch = switch (operator) {
                    .eq => std.mem.eql(u8, stored, probe),
                    .ne => !std.mem.eql(u8, stored, probe),
                    .lt => std.mem.order(u8, stored, probe) == .lt,
                    .le => std.mem.order(u8, stored, probe) != .gt,
                    .gt => std.mem.order(u8, stored, probe) == .gt,
                    .ge => std.mem.order(u8, stored, probe) != .lt,
                    .beginsWith => std.mem.startsWith(u8, stored, probe),
                };
                if (isMatch) try expected.append(testing.allocator, record.objectKey);
            }
            std.mem.sort(u64, expected.items, {}, std.sort.asc(u64));

            var actual = std.ArrayList(u64).empty;
            defer actual.deinit(testing.allocator);
            try whereSorted(&writeTransaction, catalogReference, bytesComparison(1, operator, probe), &actual);

            try testing.expectEqualSlices(u64, expected.items, actual.items);
        }
    }
}

test "T-Q8: a chunked value end to end through the facade" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qsTmpPath(testing.allocator, &tmp, "q8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob } };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);

    // 2 chunks, second chunk 10 bytes -- large enough that a chunkSize + 5
    // prefix (below) lands inside the blob rather than past its end.
    const byteCount = blobModule.chunkSize + 10;
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

    const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = source } });
    catalogReference = inserted.catalogReference;

    const exactCopy = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(exactCopy);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, catalogReference, bytesComparison(1, .eq, exactCopy), &hits);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, hits.items);

    const flipped = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(flipped);
    flipped[byteCount - 1] += 1;
    hits.clearRetainingCapacity();
    try whereSorted(&writeTransaction, catalogReference, bytesComparison(1, .eq, flipped), &hits);
    try testing.expectEqual(@as(usize, 0), hits.items.len);

    const prefix = try testing.allocator.dupe(u8, source[0 .. blobModule.chunkSize + 5]);
    defer testing.allocator.free(prefix);
    hits.clearRetainingCapacity();
    try whereSorted(&writeTransaction, catalogReference, bytesComparison(1, .beginsWith, prefix), &hits);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, hits.items);
}
