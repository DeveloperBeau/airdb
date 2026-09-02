//! The anti-N+1 measurement for query/include.zig: the resolver measured in
//! isolation (R20, R21) and the end-to-end wiring proof (R22, R23).
//!
//! 1.2 of the spec: an end-to-end batch-vs-naive ratio can never exceed
//! ~1.33x on this workload (column reads dominate over the index descent), so
//! the phase's central claim is measured on `collectRowsForSortedKeys` alone,
//! against a `index.get` loop over the SAME keys through the SAME counting
//! transaction. The end-to-end wiring is then proved separately, by a
//! dense-vs-sparse DIFFERENCE (not a ratio) on two structurally identical
//! fixtures.
//!
//! Every expected value in this file is written out by hand from the
//! fixture's own construction, never read back from the code under test.
//! Every count bound is a literal derived from the fixture's sizes and the
//! node capacities in indexNode.zig, never from a measurement of this code.

const std = @import("std");
const testing = std.testing;
const database = @import("database.zig");
const Database = database.Database;
const WriteTransaction = database.WriteTransaction;
const ReadTransaction = database.ReadTransaction;
const Reference = @import("storage/reference.zig").Reference;
const catalog = @import("schema/catalog.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const bulk = @import("records/bulk.zig");
const index = @import("trees/index.zig");
const batch = @import("query/batch.zig");
const include = @import("query/include.zig");

const materializePage = include.materializePage;

/// Counts every dereference the wrapped transaction performs. This file owns
/// its own copy of the harness (queryLazinessTests.zig owns its own): the
/// two are never imported across files, exactly as the spec asks.
const CountingTransaction = struct {
    inner: *ReadTransaction,
    dereferenceCount: u64 = 0,

    pub fn dereference(self: *CountingTransaction, reference: Reference, length: usize) ![]const u8 {
        self.dereferenceCount += 1;
        return self.inner.dereference(reference, length);
    }
};

fn qicTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

const targetCount: usize = 40_000; // three levels deep at fanout = 64
const sourceCount: u64 = 200;

// Bulk-import `count` rows of a single int property (primaryKey = row index)
// into the EMPTY type at `catalogReference`, returning the new catalog
// reference: objectKey == row == the row's own index, by bulkImport's own
// documented convention. O(count).
fn bulkImportTargetRows(writeTransaction: *WriteTransaction, catalogReference: Reference, allocator: std.mem.Allocator, count: usize) !Reference {
    const values = try allocator.alloc(u64, count);
    defer allocator.free(values);
    const rowSlices = try allocator.alloc([]const u64, count);
    defer allocator.free(rowSlices);
    for (values, 0..) |*value, position| {
        value.* = @intCast(position);
        rowSlices[position] = values[position .. position + 1];
    }
    return bulk.bulkImport(writeTransaction, catalogReference, rowSlices, .{ .presorted = true });
}

// Build a fresh, standalone single-int-property type and fill it via
// bulkImportTargetRows. Used where no directory is needed at all (R20, R21).
fn buildTargetOnlyCatalog(writeTransaction: *WriteTransaction, allocator: std.mem.Allocator, count: usize) !Reference {
    const catalogReference = try catalog.createFromDefinitions(writeTransaction, &.{.{ .kind = .int }});
    return bulkImportTargetRows(writeTransaction, catalogReference, allocator, count);
}

const sourceType: u16 = 0;
const targetType: u16 = 1;
const sourceLinkProperty: usize = 1;

const LinkFormula = enum { dense, sparse };

fn targetFor(formula: LinkFormula, sourceIndex: u64) u64 {
    return switch (formula) {
        .dense => 20_000 + sourceIndex,
        .sparse => sourceIndex * 200,
    };
}

// Fixture C: Source (link) -> Target (int only), `targetCount` targets and
// `sourceCount` sources, identical between dense and sparse except which
// target each source links to (targetFor). Same row counts, same schemas,
// same tree heights: the only thing that can differ between the two is the
// span the target walk covers.
fn buildLinkedFixture(writeTransaction: *WriteTransaction, allocator: std.mem.Allocator, formula: LinkFormula) !Reference {
    const sourceDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = targetType },
    };
    const targetDefinitions = [_]catalog.PropertyDefinition{.{ .kind = .int }};
    var directoryReference = try typeDirectory.createWithDefinitions(writeTransaction, &.{ &sourceDefinitions, &targetDefinitions });

    const emptyTargetCatalog = try typeDirectory.catalogReference(writeTransaction, directoryReference, targetType);
    const filledTargetCatalog = try bulkImportTargetRows(writeTransaction, emptyTargetCatalog, allocator, targetCount);
    directoryReference = try typeDirectory.setCatalogReference(writeTransaction, directoryReference, targetType, filledTargetCatalog);

    var sourceIndex: u64 = 0;
    while (sourceIndex < sourceCount) : (sourceIndex += 1) {
        const inserted = try typeRouting.insert(writeTransaction, directoryReference, sourceType, &.{
            .{ .int = sourceIndex },
            .{ .link = targetFor(formula, sourceIndex) },
        });
        directoryReference = inserted.directoryReference;
    }
    return directoryReference;
}

// ---------------------------------------------------------------------------
// R20: one half of the phase's central claim, on the resolver alone: dense
// beats N descents. The other half, that the range bound is load-bearing
// rather than decorative, is R9 (src/query/batchTests.zig): R20's fixture is
// dense and all-hit, so its walk count is bit-identical whether or not the
// range bound does any pruning, and cannot show that half by itself.
// ---------------------------------------------------------------------------

test "R20: the resolver's one walk costs far less than N descents over a dense span" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qicTmpPath(testing.allocator, &tmp, "qic20.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    const targetCatalogReference = try buildTargetOnlyCatalog(&writeTransaction, testing.allocator, targetCount);
    const targetView = try catalog.loadCatalog(&writeTransaction, targetCatalogReference);
    const keyToRowIndexReference = targetView.keyToRowIndexReference;
    _ = try writeTransaction.commit();

    var denseKeys: [200]u64 = undefined;
    for (&denseKeys, 0..) |*key, position| key.* = 20_000 + position;

    var readTransaction = try testDatabase.beginRead();
    defer readTransaction.end();

    var walkCounter = CountingTransaction{ .inner = &readTransaction };
    var walkRowsOut: [200]?u64 = undefined;
    try batch.collectRowsForSortedKeys(&walkCounter, keyToRowIndexReference, &denseKeys, &walkRowsOut);
    const walkCount = walkCounter.dereferenceCount;

    var descentCounter = CountingTransaction{ .inner = &readTransaction };
    var descentRowsOut: [200]?u64 = undefined;
    for (denseKeys, 0..) |key, position| descentRowsOut[position] = try index.get(&descentCounter, keyToRowIndexReference, key);
    const descentCount = descentCounter.dereferenceCount;

    // False-positive guard: the cheap side is not cheap because it did nothing.
    try testing.expectEqualSlices(?u64, &walkRowsOut, &descentRowsOut);

    // Hand-derived: three levels, two dereferences per node, 200 contiguous
    // keys is at most four leaves plus two inner plus a root, ~14; 60 is
    // generous headroom for node-boundary effects.
    try testing.expect(walkCount < 60);
    // Hand-derived: 200 keys times three levels times two dereferences = 1200.
    try testing.expect(descentCount > 1000);
    try testing.expect(walkCount * 10 < descentCount);
}

// ---------------------------------------------------------------------------
// R21: the documented ceiling, on the resolver alone, sparse.
// ---------------------------------------------------------------------------

test "R21: the resolver's one walk over a sparse span costs as much as, or more than, N descents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qicTmpPath(testing.allocator, &tmp, "qic21.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    const targetCatalogReference = try buildTargetOnlyCatalog(&writeTransaction, testing.allocator, targetCount);
    const targetView = try catalog.loadCatalog(&writeTransaction, targetCatalogReference);
    const keyToRowIndexReference = targetView.keyToRowIndexReference;
    _ = try writeTransaction.commit();

    var sparseKeys: [200]u64 = undefined;
    for (&sparseKeys, 0..) |*key, position| key.* = position * 200;

    var readTransaction = try testDatabase.beginRead();
    defer readTransaction.end();

    var walkCounter = CountingTransaction{ .inner = &readTransaction };
    var walkRowsOut: [200]?u64 = undefined;
    try batch.collectRowsForSortedKeys(&walkCounter, keyToRowIndexReference, &sparseKeys, &walkRowsOut);
    const sparseWalkCount = walkCounter.dereferenceCount;

    var descentCounter = CountingTransaction{ .inner = &readTransaction };
    var descentRowsOut: [200]?u64 = undefined;
    for (sparseKeys, 0..) |key, position| descentRowsOut[position] = try index.get(&descentCounter, keyToRowIndexReference, key);
    const descentCount = descentCounter.dereferenceCount;

    try testing.expectEqualSlices(?u64, &walkRowsOut, &descentRowsOut);

    // Hand-derived: the walk reads the whole 40_000-entry span (~625 leaves at
    // two dereferences each); a number below that would mean the walk is not
    // doing what its doc comment says.
    try testing.expect(sparseWalkCount > 800);
    // This test asserts the opposite of R20 on purpose, exactly as
    // queryLazinessTests.zig:L10 does: no win when sparse. If a later phase
    // adds gap reseeking, THIS TEST must be deleted in the same commit that
    // changes batch.zig's doc comment.
    try testing.expect(sparseWalkCount > descentCount / 2);
}

// ---------------------------------------------------------------------------
// R22/R23: the end-to-end wiring proof, and a coarse regression bound.
// Combined into one test: both need the SAME dense fixture with real links,
// so building it once keeps this file's total row count bounded.
// ---------------------------------------------------------------------------

test "R22: materializePage shows the dense-vs-sparse span difference an N-descent implementation could not; R23: a coarse regression bound on the dense case" {
    const allocator = testing.allocator;

    var denseTmp = testing.tmpDir(.{});
    defer denseTmp.cleanup();
    const densePath = try qicTmpPath(allocator, &denseTmp, "qic22dense.airdb");
    defer allocator.free(densePath);
    var denseDatabase = try Database.create(allocator, densePath);
    defer denseDatabase.deinit();
    var denseWrite = try denseDatabase.beginWrite();
    const denseDirectory = try buildLinkedFixture(&denseWrite, allocator, .dense);
    _ = try denseWrite.commit();

    var sparseTmp = testing.tmpDir(.{});
    defer sparseTmp.cleanup();
    const sparsePath = try qicTmpPath(allocator, &sparseTmp, "qic22sparse.airdb");
    defer allocator.free(sparsePath);
    var sparseDatabase = try Database.create(allocator, sparsePath);
    defer sparseDatabase.deinit();
    var sparseWrite = try sparseDatabase.beginWrite();
    const sparseDirectory = try buildLinkedFixture(&sparseWrite, allocator, .sparse);
    _ = try sparseWrite.commit();

    var denseRead = try denseDatabase.beginRead();
    defer denseRead.end();
    var denseCounter = CountingTransaction{ .inner = &denseRead };
    var denseArena = std.heap.ArenaAllocator.init(allocator);
    defer denseArena.deinit();
    const denseRoots = try materializePage(
        &denseCounter,
        denseDirectory,
        sourceType,
        .{ .page = .{ .limit = sourceCount } },
        .{ .linkProperties = &.{sourceLinkProperty}, .depth = 1 },
        denseArena.allocator(),
    );
    const denseCost = denseCounter.dereferenceCount;

    var sparseRead = try sparseDatabase.beginRead();
    defer sparseRead.end();
    var sparseCounter = CountingTransaction{ .inner = &sparseRead };
    var sparseArena = std.heap.ArenaAllocator.init(allocator);
    defer sparseArena.deinit();
    const sparseRoots = try materializePage(
        &sparseCounter,
        sparseDirectory,
        sourceType,
        .{ .page = .{ .limit = sourceCount } },
        .{ .linkProperties = &.{sourceLinkProperty}, .depth = 1 },
        sparseArena.allocator(),
    );
    const sparseCost = sparseCounter.dereferenceCount;

    // False-positive guard: neither side is cheap because it resolved nothing.
    try testing.expectEqual(@as(usize, sourceCount), denseRoots.len);
    try testing.expectEqual(@as(usize, sourceCount), sparseRoots.len);
    for (denseRoots) |root| {
        switch (root.included[0].target) {
            .object => {},
            else => try testing.expect(false),
        }
    }
    for (sparseRoots) |root| {
        switch (root.included[0].target) {
            .object => {},
            else => try testing.expect(false),
        }
    }

    // R22, the decisive assertion: the two fixtures materialize the same
    // number of objects with the same schemas at the same tree heights, so
    // every column read, catalog load and arena allocation is identical
    // between them. The only thing that differs is the span the target walk
    // covers. An N-descent implementation would show NO difference (200
    // descents either way); a one-walk implementation shows ~1250.
    try testing.expect(sparseCost > denseCost + 600);

    // R23, a coarse end-to-end regression bound: NOT a proof of the batch
    // (see R20 for that), only a bound loose enough to catch a quadratic or
    // per-object-catalog-reload implementation. Hand-derived: 400 objects
    // (200 sources + 200 targets) times up to 3 column reads times up to 3
    // tree levels times two dereferences is ~7_200, plus the page walk and
    // catalog loads; 40_000 is deliberately loose.
    try testing.expect(denseCost < 40_000);
}
