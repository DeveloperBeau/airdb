//! Indexed-vs-scan equivalence and fuzz tests for a `.blob` property carrying a
//! value index keyed by its truncated bytes (records/blobIndexKey.zig).
//!
//! The core obligation this file pins: for every operator and probe, the
//! indexed path (property 2) and the scan path (property 1) both agree with a
//! THIRD, independent RAM oracle computed with std.mem over the values the
//! test holds in memory. The indexed and scan paths agreeing with EACH OTHER
//! is never itself the assertion -- both run through
//! evaluation.matchesBytes/matchesInt underneath, so a pair that shares a bug
//! there would still agree with each other. Only agreement with the
//! independently-computed RAM oracle proves correctness.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const objects = @import("records/objects.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const blobModule = @import("records/blob.zig");
const verification = @import("verification.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;

const Predicate = query.Predicate;
const Operator = query.Operator;
const where = query.where;

fn qisTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn bytesComparison(property: usize, operator: Operator, value: []const u8) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .bytes = value } } };
}

fn whereSorted(transaction: anytype, catalogReference: Reference, predicate: Predicate, out: *std.ArrayList(u64)) !void {
    try where(transaction, catalogReference, .{ .predicate = predicate }, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// ---------------------------------------------------------------------------
// Fixture: property0 = primaryKey(int), property1 = blob (unindexed),
// property2 = blob (indexed), both blob properties carrying the SAME bytes
// per row.
// ---------------------------------------------------------------------------

const valueCount = 11;

const Fixture = struct {
    catalogReference: Reference,
    objectKeys: [valueCount]u64,
    values: [valueCount][]const u8,
};

// Every boundary the truncation and ordering logic cares about, written out by
// hand or computed by std over bytes held in RAM: the literal lengths 255,
// 256, and 260 are the ones blobIndexKey.maxLength (256) and its neighbors
// depend on.
var value255: [255]u8 = undefined;
var value256: [256]u8 = undefined;
var sharedPrefix: [260]u8 = undefined;
var sharedA: [263]u8 = undefined; // sharedPrefix ++ "AAA"
var sharedB: [263]u8 = undefined; // sharedPrefix ++ "BBB"

fn seedIndexedStringCatalog(writeTransaction: *WriteTransaction) !Fixture {
    @memset(&value255, 'p');
    @memset(&value256, 'q');
    @memset(&sharedPrefix, 'x');
    @memcpy(sharedA[0..260], &sharedPrefix);
    @memcpy(sharedA[260..263], "AAA");
    @memcpy(sharedB[0..260], &sharedPrefix);
    @memcpy(sharedB[260..263], "BBB");

    const values = [valueCount][]const u8{
        "",       "a",      "apple",   "banana",  "bananas",
        "Banana", "cherry", &value255, &value256, &sharedA,
        &sharedB,
    };

    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob },
        .{ .kind = .blob, .indexed = true },
    };
    var catalogReference = try catalog.createFromDefinitions(writeTransaction, &definitions);
    var objectKeys: [valueCount]u64 = undefined;
    for (values, 0..) |value, index| {
        const inserted = try objects.insertTyped(writeTransaction, catalogReference, &.{ .{ .int = @intCast(index) }, .{ .bytes = value }, .{ .bytes = value } });
        catalogReference = inserted.catalogReference;
        objectKeys[index] = inserted.objectKey;
    }
    return .{ .catalogReference = catalogReference, .objectKeys = objectKeys, .values = values };
}

// A directory-backed twin of Fixture, for tests that must commit and reopen
// (a bare catalog.createFromDefinitions reference is never registered
// anywhere the header's root can find, so verifyIntegrity's typeDirectory
// walk would silently find nothing to audit against it).
const DirectoryFixture = struct {
    directoryReference: Reference,
    objectKeys: [valueCount]u64,
    values: [valueCount][]const u8,
};

const directoryTypeId: u16 = 0;

fn seedIndexedStringDirectory(writeTransaction: *WriteTransaction) !DirectoryFixture {
    @memset(&value255, 'p');
    @memset(&value256, 'q');
    @memset(&sharedPrefix, 'x');
    @memcpy(sharedA[0..260], &sharedPrefix);
    @memcpy(sharedA[260..263], "AAA");
    @memcpy(sharedB[0..260], &sharedPrefix);
    @memcpy(sharedB[260..263], "BBB");

    const values = [valueCount][]const u8{
        "",       "a",      "apple",   "banana",  "bananas",
        "Banana", "cherry", &value255, &value256, &sharedA,
        &sharedB,
    };

    const definitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .blob },
        .{ .kind = .blob, .indexed = true },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(writeTransaction, &.{&definitions});
    var objectKeys: [valueCount]u64 = undefined;
    for (values, 0..) |value, index| {
        const inserted = try typeRouting.insert(writeTransaction, directoryReference, directoryTypeId, &.{ .{ .int = @intCast(index) }, .{ .bytes = value }, .{ .bytes = value } });
        directoryReference = inserted.directoryReference;
        objectKeys[index] = inserted.objectKey;
    }
    return .{ .directoryReference = directoryReference, .objectKeys = objectKeys, .values = values };
}

// The RAM oracle: which of `values` match `operator` against `probe`, mapped
// through `objectKeys`, sorted ascending. This is the third, independent
// source of truth every indexed/scan comparison in this file is checked
// against.
fn expectedObjectKeys(operator: Operator, probe: []const u8, values: []const []const u8, objectKeys: []const u64, allocator: std.mem.Allocator) ![]u64 {
    var list = std.ArrayList(u64).empty;
    errdefer list.deinit(allocator);
    for (values, 0..) |value, index| {
        const isMatch = switch (operator) {
            .eq => std.mem.eql(u8, value, probe),
            .ne => !std.mem.eql(u8, value, probe),
            .lt => std.mem.order(u8, value, probe) == .lt,
            .le => std.mem.order(u8, value, probe) != .gt,
            .gt => std.mem.order(u8, value, probe) == .gt,
            .ge => std.mem.order(u8, value, probe) != .lt,
            .beginsWith => std.mem.startsWith(u8, value, probe),
        };
        if (isMatch) try list.append(allocator, objectKeys[index]);
    }
    std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
    return list.toOwnedSlice(allocator);
}

const matrixOperators = [_]Operator{ .eq, .lt, .le, .gt, .ge, .beginsWith };

test "R10: indexed and scan paths both equal a RAM oracle, over a hand-written probe/operator matrix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_matrix.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    const probes = [_][]const u8{ "", "b", "banana", &value256, &sharedA };

    for (probes) |probe| {
        for (matrixOperators) |operator| {
            const expected = try expectedObjectKeys(operator, probe, &fixture.values, &fixture.objectKeys, testing.allocator);
            defer testing.allocator.free(expected);

            var indexedHits = std.ArrayList(u64).empty;
            defer indexedHits.deinit(testing.allocator);
            try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, operator, probe), &indexedHits);
            try testing.expectEqualSlices(u64, expected, indexedHits.items);

            var scanHits = std.ArrayList(u64).empty;
            defer scanHits.deinit(testing.allocator);
            try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(1, operator, probe), &scanHits);
            try testing.expectEqualSlices(u64, expected, scanHits.items);
        }
    }
}

test "R1: two values sharing a 256-byte prefix are separated by the residual filter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_r1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, .eq, &sharedA), &hits);
    // Both rows 9 (sharedA) and 10 (sharedB) share the truncated 256-byte key,
    // so the index proposes both; only sharedA's row matches on full bytes.
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[9]}, hits.items);
}

test "gt on a shared-prefix probe returns the BBB row, proving the inclusive start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_gt_shared.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, .gt, &sharedA), &hits);
    // sharedB > sharedA by full-byte order; every other value is < sharedA.
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[10]}, hits.items);
}

test "beginsWith with a prefix longer than 256 bytes returns only the exactly-matching row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_beginswith_long.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, .beginsWith, &sharedA), &hits);
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[9]}, hits.items);
}

test "M4 guard: collectCandidates for beginsWith stops at the first non-matching key, not merely filtering after the fact" {
    // The final where() result is unaffected by an over-collecting walk (the
    // residual filter cleans it up either way), so this asserts the raw
    // candidate set planner.collectCandidates produces directly: with probe
    // "b" the ascending walk must stop at "cherry" (which sorts after
    // "banana"/"bananas" but does not begin with "b"), not continue picking up
    // every later key (value255, value256, and the shared-prefix pair).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_m4_guard.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    const scan = try Scan.open(&writeTransaction, fixture.catalogReference);
    var candidates = std.ArrayList(u64).empty;
    defer candidates.deinit(testing.allocator);
    try planner.collectCandidates(&writeTransaction, &scan, bytesComparison(2, .beginsWith, "b"), &candidates, testing.allocator, 0);
    std.mem.sort(u64, candidates.items, {}, std.sort.asc(u64));

    // Hand-known from the fixture: only "banana" (index 3) and "bananas"
    // (index 4) begin with "b".
    var expected = [_]u64{ fixture.objectKeys[3], fixture.objectKeys[4] };
    std.mem.sort(u64, &expected, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &expected, candidates.items);
}

test "beginsWith the empty prefix returns every live row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_beginswith_empty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, .beginsWith, ""), &hits);
    var expectedKeys = fixture.objectKeys;
    std.mem.sort(u64, &expectedKeys, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &expectedKeys, hits.items);
}

test "eq \"\" returns exactly the empty-value row: an empty blob is a real key, not an absence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_eq_empty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try whereSorted(&writeTransaction, fixture.catalogReference, bytesComparison(2, .eq, ""), &hits);
    try testing.expectEqualSlices(u64, &.{fixture.objectKeys[0]}, hits.items);
}

test "countWhere over a blob eq equals the hand-counted number, including the shared-prefix probe where the candidate count is 2 and the answer is 1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_count.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    try testing.expectEqual(@as(u64, 1), try query.countWhere(&writeTransaction, fixture.catalogReference, bytesComparison(2, .eq, "banana"), testing.allocator));
    // The shared-prefix probe: the index's candidate set is 2 (sharedA and
    // sharedB share the truncated key), but the true count is 1. If anything
    // ever treated the blob index as covering, this would return 2.
    try testing.expectEqual(@as(u64, 1), try query.countWhere(&writeTransaction, fixture.catalogReference, bytesComparison(2, .eq, &sharedA), testing.allocator));
}

test "update and delete churn: the full operator matrix against an updated RAM oracle still holds, and verifyIntegrity passes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_churn.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const fixture = try seedIndexedStringDirectory(&writeTransaction);
    writeTransaction.setRoot(fixture.directoryReference);
    _ = try writeTransaction.commit();

    var mutableValues = fixture.values;

    // Update three rows: one onto a shared prefix, one off a shared prefix, one
    // to a plain new value. Delete two more. Every routing call threads the
    // returned directoryReference forward, exactly as a real caller must.
    var updateTransaction = try database.beginWrite();
    var directoryReference = database.activeRoot;
    var propertyBuffer: [3]catalog.Value = undefined;
    {
        // Row 1 ("a") moves ONTO the shared prefix (now matches sharedA's key).
        const primaryKeyRow1: u64 = 1;
        const version1 = (try typeRouting.get(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow1, &propertyBuffer)).?;
        directoryReference = (try typeRouting.update(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow1, &.{ .{ .int = primaryKeyRow1 }, .{ .bytes = &sharedA }, .{ .bytes = &sharedA } }, version1)).ok.directoryReference;
        mutableValues[1] = &sharedA;

        // Row 9 (sharedA) moves OFF the shared prefix, to "zzz".
        const primaryKeyRow9: u64 = 9;
        const version9 = (try typeRouting.get(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow9, &propertyBuffer)).?;
        directoryReference = (try typeRouting.update(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow9, &.{ .{ .int = primaryKeyRow9 }, .{ .bytes = "zzz" }, .{ .bytes = "zzz" } }, version9)).ok.directoryReference;
        mutableValues[9] = "zzz";

        // Row 6 ("cherry") moves to a plain new value.
        const primaryKeyRow6: u64 = 6;
        const version6 = (try typeRouting.get(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow6, &propertyBuffer)).?;
        directoryReference = (try typeRouting.update(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow6, &.{ .{ .int = primaryKeyRow6 }, .{ .bytes = "kiwi" }, .{ .bytes = "kiwi" } }, version6)).ok.directoryReference;
        mutableValues[6] = "kiwi";

        // Delete rows 3 ("banana") and 4 ("bananas").
        const primaryKeyRow3: u64 = 3;
        const version3 = (try typeRouting.get(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow3, &propertyBuffer)).?;
        directoryReference = (try typeRouting.delete(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow3, version3)).ok;
        const primaryKeyRow4: u64 = 4;
        const version4 = (try typeRouting.get(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow4, &propertyBuffer)).?;
        directoryReference = (try typeRouting.delete(&updateTransaction, directoryReference, directoryTypeId, primaryKeyRow4, version4)).ok;
    }
    updateTransaction.setRoot(directoryReference);
    _ = try updateTransaction.commit();

    // Live set: every original index except 3 and 4.
    var liveValues = std.ArrayList([]const u8).empty;
    defer liveValues.deinit(testing.allocator);
    var liveKeys = std.ArrayList(u64).empty;
    defer liveKeys.deinit(testing.allocator);
    for (mutableValues, 0..) |value, index| {
        if (index == 3 or index == 4) continue;
        try liveValues.append(testing.allocator, value);
        try liveKeys.append(testing.allocator, fixture.objectKeys[index]);
    }

    var verifyTransaction = try database.beginWrite();
    defer verifyTransaction.deinit();
    const finalCatalogReference = try typeDirectory.catalogReference(&verifyTransaction, database.activeRoot, directoryTypeId);
    const probes = [_][]const u8{ "", "b", "banana", &value256, &sharedA };
    for (probes) |probe| {
        for (matrixOperators) |operator| {
            const expected = try expectedObjectKeys(operator, probe, liveValues.items, liveKeys.items, testing.allocator);
            defer testing.allocator.free(expected);

            var indexedHits = std.ArrayList(u64).empty;
            defer indexedHits.deinit(testing.allocator);
            try whereSorted(&verifyTransaction, finalCatalogReference, bytesComparison(2, operator, probe), &indexedHits);
            try testing.expectEqualSlices(u64, expected, indexedHits.items);
        }
    }

    try verification.verifyIntegrity(&database);
}

test "R2: an insert and update in one transaction leaves no stale index key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_r2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Uses the raw catalog/objects API, not typeDirectory/typeRouting: routing
    // through typeDirectory would call setCatalogReference after this row's
    // own insert, freeing an 11-byte directory node into the SAME free-list
    // bucket (round8(11) == round8(10) == 16) as the "alpha"/"gamma" blob
    // value below, ahead of it in the reuse queue -- which shields the exact
    // aliasing this test exists to catch (see the section 4.4 fix this test
    // pins). The bare catalog reference this creates is never registered
    // under a type directory, so verifyIntegrity's typeDirectory walk below
    // finds nothing to audit and returns cleanly without having checked
    // anything further; the where() queries above it are what actually prove
    // the invariant.
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } });
    const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = "alpha" } });
    catalogReference = inserted.catalogReference;
    var propertyBuffer: [2]catalog.Value = undefined;
    const insertedVersion = (try objects.getTyped(&writeTransaction, catalogReference, 1, &propertyBuffer)).?;
    // "alpha" and "gamma" are the same length, which is what makes the freed
    // extent exactly reusable and would trigger the bug section 4.4 fixes.
    catalogReference = (try objects.updateTyped(&writeTransaction, catalogReference, 1, &.{ .{ .int = 1 }, .{ .bytes = "gamma" } }, insertedVersion)).ok.catalogReference;
    writeTransaction.setRoot(catalogReference);
    _ = try writeTransaction.commit();

    var readTransaction = try database.beginWrite();
    defer readTransaction.deinit();
    var alphaHits = std.ArrayList(u64).empty;
    defer alphaHits.deinit(testing.allocator);
    try where(&readTransaction, database.activeRoot, .{ .predicate = bytesComparison(1, .eq, "alpha") }, &alphaHits, testing.allocator);
    try testing.expectEqual(@as(usize, 0), alphaHits.items.len);

    var gammaHits = std.ArrayList(u64).empty;
    defer gammaHits.deinit(testing.allocator);
    try where(&readTransaction, database.activeRoot, .{ .predicate = bytesComparison(1, .eq, "gamma") }, &gammaHits, testing.allocator);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, gammaHits.items);

    try verification.verifyIntegrity(&database);
}

test "no-op guard: a same-bytes blob update on a multi-blob-property type leaves the index and the other blob property intact" {
    // Same mechanism family as R2/M8: updateTyped always reallocates and
    // frees the old blob for every .blob property present, even when the
    // caller passes back the SAME bytes. A no-op "update" still runs the
    // free/put/remove/add sequence, which is exactly where the aliasing R2
    // pins lives -- this pins the false-positive direction: a no-op must not
    // accidentally delete the row from its own index, and a second blob
    // property on the same row, also passed back unchanged, must not be
    // corrupted by property 1's own free/put cycle either. Raw catalog/
    // objects API, not typeDirectory/typeRouting, for the same
    // free-list-bucket-contamination reason R2's comment explains.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_noop.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .blob, .indexed = true },
        .{ .kind = .blob },
    });
    const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = "alpha" }, .{ .bytes = "static" } });
    catalogReference = inserted.catalogReference;
    var propertyBuffer: [3]catalog.Value = undefined;
    const insertedVersion = (try objects.getTyped(&writeTransaction, catalogReference, 1, &propertyBuffer)).?;
    // The no-op: identical bytes on both blob properties, same length.
    catalogReference = (try objects.updateTyped(&writeTransaction, catalogReference, 1, &.{ .{ .int = 1 }, .{ .bytes = "alpha" }, .{ .bytes = "static" } }, insertedVersion)).ok.catalogReference;
    writeTransaction.setRoot(catalogReference);
    _ = try writeTransaction.commit();

    var readTransaction = try database.beginWrite();
    defer readTransaction.deinit();
    var alphaHits = std.ArrayList(u64).empty;
    defer alphaHits.deinit(testing.allocator);
    try where(&readTransaction, database.activeRoot, .{ .predicate = bytesComparison(1, .eq, "alpha") }, &alphaHits, testing.allocator);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, alphaHits.items);

    var afterBuffer: [3]catalog.Value = undefined;
    _ = (try objects.getTypedByObjectKey(&readTransaction, database.activeRoot, inserted.objectKey, &afterBuffer)).?;
    try testing.expectEqualStrings("alpha", afterBuffer[1].bytes);
    try testing.expectEqualStrings("static", afterBuffer[2].bytes);
}

// Runs `updateCount` updates of property 1 (a blob), each in its own
// committed transaction, and returns the arena's total growth over the loop.
// `sizeAt(updateIndex)` decides each iteration's replacement length: a
// constant makes every replacement the same size (exact-size-class reuse can
// apply), while a strictly increasing function makes every replacement a
// fresh size (reuse can never apply, the baseline for "no reclamation is
// possible here regardless of the fix").
fn arenaGrowthOverUpdateLoop(path: []const u8, updateCount: usize, sizeAt: fn (usize) usize) !u64 {
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } };
    const initialBytes = try testing.allocator.alloc(u8, sizeAt(0));
    defer testing.allocator.free(initialBytes);
    @memset(initialBytes, 0);
    {
        var writeTransaction = try database.beginWrite();
        var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});
        const inserted = try typeRouting.insert(&writeTransaction, directoryReference, directoryTypeId, &.{ .{ .int = 1 }, .{ .bytes = initialBytes } });
        directoryReference = inserted.directoryReference;
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }

    const topAfterSetup = database.arena.top;
    var updateIndex: usize = 0;
    while (updateIndex < updateCount) : (updateIndex += 1) {
        const buffer = try testing.allocator.alloc(u8, sizeAt(updateIndex));
        defer testing.allocator.free(buffer);
        @memset(buffer, @truncate(updateIndex));
        var writeTransaction = try database.beginWrite();
        var propertyBuffer: [2]catalog.Value = undefined;
        const version = (try typeRouting.get(&writeTransaction, database.activeRoot, directoryTypeId, 1, &propertyBuffer)).?;
        const directoryReference = (try typeRouting.update(&writeTransaction, database.activeRoot, directoryTypeId, 1, &.{ .{ .int = 1 }, .{ .bytes = buffer } }, version)).ok.directoryReference;
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
    }
    return database.arena.top - topAfterSetup;
}

fn constantBlobSize(_: usize) usize {
    return 1000;
}

fn increasingBlobSize(updateIndex: usize) usize {
    return 1000 + updateIndex; // strictly distinct every iteration: never reusable
}

test "M7 guard: reclaiming a same-size replacement grows the arena measurably less than a scenario where reuse is impossible" {
    // R2's correctness assertions (eq "alpha" empty, eq "gamma" present) do not
    // fail if freeReplacedBlobs is deleted entirely: a leaked old blob is
    // still a valid, readable node the query engine never looks at again, so
    // the result set is unaffected. What a deleted freeReplacedBlobs call DOES
    // do is stop reclaiming space, which this test measures directly and
    // self-calibrates against a baseline where reclamation cannot help even
    // when it runs, rather than asserting a hand-guessed byte threshold.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const reusablePath = try qisTmpPath(testing.allocator, &tmp, "qis_m7_reusable.airdb");
    defer testing.allocator.free(reusablePath);
    const neverReusablePath = try qisTmpPath(testing.allocator, &tmp, "qis_m7_never_reusable.airdb");
    defer testing.allocator.free(neverReusablePath);

    const updateCount = 100;
    const reusableGrowth = try arenaGrowthOverUpdateLoop(reusablePath, updateCount, constantBlobSize);
    const neverReusableGrowth = try arenaGrowthOverUpdateLoop(neverReusablePath, updateCount, increasingBlobSize);

    // With freeReplacedBlobs freeing the old same-size extent each time, later
    // commits reuse it; when no replacement can ever be reused (sizes always
    // differ), nothing is ever reclaimable regardless of the fix. If
    // freeReplacedBlobs were deleted, neither loop would ever reclaim
    // anything, and this inequality would collapse.
    // A fixed absolute margin, not a ratio: per-transaction overhead unrelated
    // to the blob payload (catalog COW, version/live columns, free-list
    // bookkeeping) is paid by both loops alike, so only a margin comfortably
    // smaller than the measured reuse saving (~49,000 bytes over 100
    // iterations) survives; deleting freeReplacedBlobs collapses the gap
    // between the two loops to near zero.
    try testing.expect(reusableGrowth + 20_000 < neverReusableGrowth);
}

test "a chunked value on the indexed property: beginsWith on its first 256 bytes finds it, eq on the full copy finds it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_chunked.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } };
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);

    const byteCount = blobModule.chunkSize + 10;
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

    const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = source } });
    catalogReference = inserted.catalogReference;

    var prefix256: [256]u8 = undefined;
    @memcpy(&prefix256, source[0..256]);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&writeTransaction, catalogReference, .{ .predicate = bytesComparison(1, .beginsWith, &prefix256) }, &hits, testing.allocator);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, hits.items);

    const exactCopy = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(exactCopy);
    hits.clearRetainingCapacity();
    try where(&writeTransaction, catalogReference, .{ .predicate = bytesComparison(1, .eq, exactCopy) }, &hits, testing.allocator);
    try testing.expectEqualSlices(u64, &.{inserted.objectKey}, hits.items);
}

// ---------------------------------------------------------------------------
// 12.7: refusals that must stay refusals.
// ---------------------------------------------------------------------------

test "query.minimum and query.maximum on an indexed blob property are still error.UnsupportedAggregate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_endpoint_refusal.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    try testing.expectError(error.UnsupportedAggregate, query.minimum(&writeTransaction, fixture.catalogReference, 2, testing.allocator));
    try testing.expectError(error.UnsupportedAggregate, query.maximum(&writeTransaction, fixture.catalogReference, 2, testing.allocator));
}

test "a cursor against a blob property ordering is rejected before the ordering check reaches any index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_cursor_refusal.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try seedIndexedStringCatalog(&writeTransaction);

    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    const request = query.Request{
        .ordering = .{ .sortKey = .{ .property = 2 } },
        .page = .{ .start = .{ .after = .{ .lastValue = 0, .lastObjectKey = 0 } } },
    };
    // The property-kind check in Request.validate runs before the
    // cursor-requires-index check, so this fails with UnsupportedOrdering, not
    // CursorRequiresIndexedSort: kind is checked first regardless of the page.
    try testing.expectError(error.UnsupportedOrdering, where(&writeTransaction, fixture.catalogReference, request, &hits, testing.allocator));
}

// ---------------------------------------------------------------------------
// 12.9: fuzz.
// ---------------------------------------------------------------------------

// The 4-symbol alphabet makes short shared prefixes common rather than
// astronomically rare, which is what exercises byte ordering (including the
// 0xFF high-bit case) and the superset/verifyIntegrity invariants below over
// many seeds. It does NOT make a 256-byte shared-prefix collision reachable:
// two independently drawn values agreeing on 256 consecutive bytes from a
// uniform 4-symbol alphabet has probability 4^-256, so neither this generator
// nor the fixed 257-byte `longX` probe below will ever exercise that case
// over any realistic seed count. That case is instead covered by five
// hand-written tests: R1, the `gt` shared-prefix test, the >256-byte
// `beginsWith` test, the `countWhere` shared-prefix test, and the churn test.
fn generateFuzzValue(random: std.Random, allocator: std.mem.Allocator) ![]u8 {
    const boundaryLengths = [_]usize{ 0, 1, 2, 255, 256, 257 };
    const length = if (random.boolean())
        boundaryLengths[random.intRangeLessThan(usize, 0, boundaryLengths.len)]
    else
        random.intRangeLessThan(usize, 0, 301);
    const alphabet = [_]u8{ 'a', 'b', 'x', 0xFF };
    const bytes = try allocator.alloc(u8, length);
    for (bytes) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
    return bytes;
}

fn fuzzExpectedObjectKeys(operator: Operator, probe: []const u8, values: []const []const u8, objectKeys: []const u64, allocator: std.mem.Allocator) ![]u64 {
    return expectedObjectKeys(operator, probe, values, objectKeys, allocator);
}

const planner = @import("query/planner.zig");
const Scan = @import("query/scan.zig").Scan;

test "R11: fuzz, indexed and scan and oracle agree over random byte values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qisTmpPath(testing.allocator, &tmp, "qis_fuzz.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var writeTransaction = try database.beginWrite();
        const definitions = [_]catalog.PropertyDefinition{
            .{ .kind = .int },
            .{ .kind = .blob },
            .{ .kind = .blob, .indexed = true },
        };
        // A fresh directory per seed (not a bare catalog) so this seed's data
        // is reachable from database.activeRoot, which is what makes the
        // verifyIntegrity call below a real audit rather than an unconditional
        // pass on a root that is not a type directory.
        var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&definitions});

        var values = try allocator.alloc([]const u8, 40);
        var objectKeys = try allocator.alloc(u64, 40);
        var rowIndex: usize = 0;
        while (rowIndex < 40) : (rowIndex += 1) {
            const value = try generateFuzzValue(random, allocator);
            values[rowIndex] = value;
            const inserted = try typeRouting.insert(&writeTransaction, directoryReference, directoryTypeId, &.{ .{ .int = @intCast(rowIndex) }, .{ .bytes = value }, .{ .bytes = value } });
            directoryReference = inserted.directoryReference;
            objectKeys[rowIndex] = inserted.objectKey;
        }

        // Third invariant: verifyIntegrity passes after each seed's inserts.
        // Commit and set root so it audits this seed's freshly built type.
        writeTransaction.setRoot(directoryReference);
        _ = try writeTransaction.commit();
        writeTransaction.deinit();
        try verification.verifyIntegrity(&database);

        var readTransaction = try database.beginWrite();
        defer readTransaction.deinit();
        const catalogReference = try typeDirectory.catalogReference(&readTransaction, database.activeRoot, directoryTypeId);

        var probes = try allocator.alloc([]const u8, 12);
        var probeIndex: usize = 0;
        while (probeIndex < 5) : (probeIndex += 1) probes[probeIndex] = values[random.intRangeLessThan(usize, 0, values.len)];
        while (probeIndex < 10) : (probeIndex += 1) probes[probeIndex] = try generateFuzzValue(random, allocator);
        probes[10] = "";
        const longX = try allocator.alloc(u8, 257);
        @memset(longX, 'x');
        probes[11] = longX;

        const operators = [_]Operator{ .eq, .lt, .le, .gt, .ge, .beginsWith };
        for (probes) |probe| {
            for (operators) |operator| {
                const expected = try fuzzExpectedObjectKeys(operator, probe, values, objectKeys, allocator);

                var indexedHits = std.ArrayList(u64).empty;
                defer indexedHits.deinit(testing.allocator);
                try whereSorted(&readTransaction, catalogReference, bytesComparison(2, operator, probe), &indexedHits);

                var scanHits = std.ArrayList(u64).empty;
                defer scanHits.deinit(testing.allocator);
                try whereSorted(&readTransaction, catalogReference, bytesComparison(1, operator, probe), &scanHits);

                if (!std.mem.eql(u64, expected, indexedHits.items) or !std.mem.eql(u64, expected, scanHits.items)) {
                    std.debug.print("R11 fuzz failure: seed {d}, probe {x}, operator {}\n", .{ seed, probe, operator });
                    try testing.expectEqualSlices(u64, expected, indexedHits.items);
                    try testing.expectEqualSlices(u64, expected, scanHits.items);
                }

                // Second invariant: the planner's own candidate set (before the
                // residual filter) is a SUPERSET of the RAM oracle's answer.
                const scan = try Scan.open(&readTransaction, catalogReference);
                const predicate = bytesComparison(2, operator, probe);
                if (planner.canDriveFromIndex(&scan, predicate)) {
                    var candidates = std.ArrayList(u64).empty;
                    defer candidates.deinit(allocator);
                    try planner.collectCandidates(&readTransaction, &scan, predicate, &candidates, allocator, 0);
                    for (expected) |expectedKey| {
                        if (std.mem.indexOfScalar(u64, candidates.items, expectedKey) == null) {
                            std.debug.print("R11 fuzz superset failure: seed {d}, probe {x}, operator {}\n", .{ seed, probe, operator });
                            try testing.expect(false);
                        }
                    }
                }
            }
        }
    }
}
