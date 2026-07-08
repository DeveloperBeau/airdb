// bulk_append -- append a contiguous, right-edge batch to a POPULATED type two
// ways and contrast the cost. Both databases are seeded identically with a base
// of N/2 rows; then the same N/2-row contiguous batch (primaryKeys above the current
// max, monotonic) is added. Path A drives the right-edge bulkAppendOrInsert fast
// path in a single write transaction; Path B inserts the identical batch one row
// at a time in batched commits (the realistic baseline). We report the load-time
// speedup, the page-fault delta for each path, and the commit count for each so
// the win is documented in numbers rather than asserted.
//
// We also exercise the fallback: a scattered (non-ascending) batch must return
// error.NotAppendable with nothing written, so bulkAppendOrInsert would replay
// it row-by-row. That correctness smoke is recorded as fallback_ok in the note.
//
// Baseline choice: Path B uses batched commits (batchSize rows per commit), not
// auto-commit per row, because that is how a sane bulk loader would use the
// row-by-row API today. It is the honest baseline bulkAppend competes against.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const rows = airdb.rows;
const bulk = airdb.bulk;

pub const name = "bulk_append";

// Rows committed per write transaction on the row-by-row path. Matches
// bulk_import / insert_recovery so the baseline is apples-to-apples.
const batchSize: usize = 10_000;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

// Seed a fresh two-int type with `base` rows (primaryKeys 0..base-1, value = primaryKey) using
// bulkImport in one transaction, so both databases start from an identical,
// already-populated base. Returns nothing; the committed catalog is the root.
fn seedBase(database: *airdb.Database, baseRows: []const []const u64) !void {
    var writeTransaction = try database.beginWrite();
    const catalogReference = try catalog.create(&writeTransaction, 2);
    const seeded = try bulk.bulkImport(&writeTransaction, catalogReference, baseRows, .{ .presorted = true });
    writeTransaction.setRoot(seeded);
    _ = try writeTransaction.commit();
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const base: usize = ctx.rowCount / 2;
    const metrics: usize = ctx.rowCount / 2;

    const pathA = try harness.scratchPath(ctx.*, name ++ "_bulk.airdb");
    defer alloc.free(pathA);
    defer harness.removeScratch(ctx.*, pathA);
    const pathB = try harness.scratchPath(ctx.*, name ++ "_rowwise.airdb");
    defer alloc.free(pathB);
    defer harness.removeScratch(ctx.*, pathB);
    const pathC = try harness.scratchPath(ctx.*, name ++ "_fallback.airdb");
    defer alloc.free(pathC);
    defer harness.removeScratch(ctx.*, pathC);

    // --- Build the base rows (0..base-1) and the append batch (base..base+m-1).
    // Each is a flat backing buffer sliced into per-row []const u64 windows.
    const baseStorage = try alloc.alloc([2]u64, base);
    defer alloc.free(baseStorage);
    const baseRows = try alloc.alloc([]const u64, base);
    defer alloc.free(baseRows);
    for (baseStorage, baseRows, 0..) |*cells, *row, rowIndex| {
        cells.* = .{ @intCast(rowIndex), @intCast(rowIndex) };
        row.* = &cells.*;
    }

    const batchStorage = try alloc.alloc([2]u64, metrics);
    defer alloc.free(batchStorage);
    const batch = try alloc.alloc([]const u64, metrics);
    defer alloc.free(batch);
    for (batchStorage, batch, 0..) |*cells, *row, rowIndex| {
        const primaryKey: u64 = @intCast(base + rowIndex);
        cells.* = .{ primaryKey, primaryKey };
        row.* = &cells.*;
    }

    // --- Seed both databases identically with the populated base. ----------
    var databaseA = try airdb.Database.create(alloc, pathA);
    errdefer databaseA.deinit();
    try seedBase(&databaseA, baseRows);

    var databaseB = try airdb.Database.create(alloc, pathB);
    errdefer databaseB.deinit();
    try seedBase(&databaseB, baseRows);

    // --- Path A: bulk append the batch in one write transaction. -----------
    const aCommitsBefore = databaseA.metrics().commitCount;
    const aPfBefore = airdb.pageFaults();
    const bulkStart = nowNs(io);
    {
        var writeTransaction = try databaseA.beginWrite();
        const newCatalog = try bulk.bulkAppendOrInsert(&writeTransaction, writeTransaction.newRoot, batch);
        writeTransaction.setRoot(newCatalog);
        _ = try writeTransaction.commit();
    }
    const bulkNs: u64 = @intCast(nowNs(io) - bulkStart);
    const aPfAfter = airdb.pageFaults();
    const bulkFaults = (aPfAfter.minor - aPfBefore.minor) + (aPfAfter.major - aPfBefore.major);
    const bulkCommits = databaseA.metrics().commitCount - aCommitsBefore;

    const fileBytes = try databaseA.fileSize();
    const logicalBytes = databaseA.logicalSize();

    // --- Path B: row-by-row inserts of the same batch in batched commits. --
    const bCommitsBefore = databaseB.metrics().commitCount;
    const bPfBefore = airdb.pageFaults();
    const rowwiseStart = nowNs(io);
    var inserted: usize = 0;
    while (inserted < metrics) {
        const thisBatch = @min(batchSize, metrics - inserted);
        var writeTransaction = try databaseB.beginWrite();
        var catalogReference: Reference = databaseB.activeRoot; // reload the committed catalog reference
        var innerIndex: usize = 0;
        while (innerIndex < thisBatch) : (innerIndex += 1) {
            const primaryKey: u64 = base + inserted + innerIndex;
            const result = try rows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey });
            catalogReference = result.catalogReference;
        }
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
        inserted += thisBatch;
    }
    const rowwiseNs: u64 = @intCast(nowNs(io) - rowwiseStart);
    const bPfAfter = airdb.pageFaults();
    const rowwiseFaults = (bPfAfter.minor - bPfBefore.minor) + (bPfAfter.major - bPfBefore.major);
    const rowwiseCommits = databaseB.metrics().commitCount - bCommitsBefore;

    // --- Fallback smoke: a scattered (non-ascending) batch must be rejected
    // with NotAppendable and nothing written. Kept cheap: a tiny seeded type.
    var fallbackOk = false;
    {
        var databaseC = try airdb.Database.create(alloc, pathC);
        defer databaseC.deinit();
        var smallStorage: [4][2]u64 = undefined;
        var smallRows: [4][]const u64 = undefined;
        for (&smallStorage, &smallRows, 0..) |*cells, *row, rowIndex| {
            cells.* = .{ @intCast(rowIndex), @intCast(rowIndex) };
            row.* = &cells.*;
        }
        try seedBase(&databaseC, &smallRows);

        // primaryKeys 100, 102, 101: above the max but NOT strictly ascending.
        const scattered = [_][]const u64{ &.{ 100, 100 }, &.{ 102, 102 }, &.{ 101, 101 } };
        var writeTransaction = try databaseC.beginWrite();
        if (bulk.bulkAppend(&writeTransaction, writeTransaction.newRoot, &scattered)) |_| {
            // Unexpectedly appendable: leave fallbackOk false.
        } else |err| switch (err) {
            error.NotAppendable => fallbackOk = true,
            else => return err,
        }
        writeTransaction.deinit(); // abort: nothing should have been written anyway
    }

    const speedup: f64 = if (bulkNs == 0)
        0
    else
        @as(f64, @floatFromInt(rowwiseNs)) / @as(f64, @floatFromInt(bulkNs));

    const note = try std.fmt.allocPrint(
        alloc,
        "bulk_ms={d} rowwise_ms={d} speedup={d:.1}x bulk_faults={d} rowwise_faults={d} bulk_commits={d} rowwise_commits={d} base={d} m={d} fallback_ok={}",
        .{
            bulkNs / std.time.ns_per_ms,
            rowwiseNs / std.time.ns_per_ms,
            speedup,
            bulkFaults,
            rowwiseFaults,
            bulkCommits,
            rowwiseCommits,
            base,
            metrics,
            fallbackOk,
        },
    );

    databaseA.deinit();
    databaseB.deinit();

    return .{
        .name = name,
        .ops = metrics,
        .wallNs = bulkNs,
        .p50Ns = 0,
        .p99Ns = 0,
        .maxNs = 0,
        .fileBytes = fileBytes,
        .logicalBytes = logicalBytes,
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
