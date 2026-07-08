// bulk_import -- load N rows two ways and contrast the cost. Path A drives the
// bottom-up bulkImport orchestrator in a single write transaction; Path B inserts
// the identical rows one at a time in batched commits (the realistic baseline,
// mirroring insert_recovery's batching). We report the load-time speedup, the
// page-fault delta for each path, and the commit count for each so the win is
// documented in numbers rather than asserted.
//
// Baseline choice: Path B uses batched commits (batchSize rows per commit), not
// auto-commit per row, because that is how a sane bulk loader would use the
// row-by-row API today. It is the honest baseline bulkImport competes against.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const rawRows = airdb.rows;
const bulk = airdb.bulk;

pub const name = "bulk_import";

// Rows committed per write transaction on the row-by-row path. Matches
// insert_recovery so the baseline is apples-to-apples.
const batchSize: usize = 10_000;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const pathA = try harness.scratchPath(ctx.*, name ++ "_bulk.airdb");
    defer alloc.free(pathA);
    defer harness.removeScratch(ctx.*, pathA);
    const pathB = try harness.scratchPath(ctx.*, name ++ "_rowwise.airdb");
    defer alloc.free(pathB);
    defer harness.removeScratch(ctx.*, pathB);

    // --- Build the rows once, shared by both paths. Two-int type {primaryKey, value};
    // primaryKey = i, value = i. A flat backing buffer sliced into per-row windows so
    // bulkImport sees a []const []const u64.
    const storage = try alloc.alloc([2]u64, ctx.rowCount);
    defer alloc.free(storage);
    const rows = try alloc.alloc([]const u64, ctx.rowCount);
    defer alloc.free(rows);
    for (storage, rows, 0..) |*cells, *row, rowIndex| {
        cells.* = .{ @intCast(rowIndex), @intCast(rowIndex) };
        row.* = &cells.*;
    }

    // --- Path A: bulk import in one write transaction -----------------------
    var databaseA = try airdb.Database.create(alloc, pathA);
    errdefer databaseA.deinit();

    // Empty two-int catalog committed as the root, so the bulk write transaction
    // sees it via w.newRoot. bulkImport requires the type to be empty.
    {
        var writeTransaction = try databaseA.beginWrite();
        const catalogReference = try catalog.create(&writeTransaction, 2);
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }

    const aCommitsBefore = databaseA.metrics().commitCount;
    const aPfBefore = airdb.pageFaults();
    const bulkStart = nowNs(io);
    {
        var writeTransaction = try databaseA.beginWrite();
        const newCatalog = try bulk.bulkImport(&writeTransaction, writeTransaction.newRoot, rows, .{});
        writeTransaction.setRoot(newCatalog);
        _ = try writeTransaction.commit();
    }
    const bulkNs: u64 = @intCast(nowNs(io) - bulkStart);
    const aPfAfter = airdb.pageFaults();
    const bulkFaults = (aPfAfter.minor - aPfBefore.minor) + (aPfAfter.major - aPfBefore.major);
    const bulkCommits = databaseA.metrics().commitCount - aCommitsBefore;

    const fileBytes = try databaseA.fileSize();
    const logicalBytes = databaseA.logicalSize();

    // --- Path B: row-by-row inserts in batched commits ----------------------
    var databaseB = try airdb.Database.create(alloc, pathB);
    errdefer databaseB.deinit();
    var catalogReference: Reference = blk: {
        var writeTransaction = try databaseB.beginWrite();
        const catalogReference = try catalog.create(&writeTransaction, 2);
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
        break :blk catalogReference;
    };

    const bCommitsBefore = databaseB.metrics().commitCount;
    const bPfBefore = airdb.pageFaults();
    const rowwiseStart = nowNs(io);
    var inserted: usize = 0;
    while (inserted < ctx.rowCount) {
        const thisBatch = @min(batchSize, ctx.rowCount - inserted);
        var writeTransaction = try databaseB.beginWrite();
        catalogReference = databaseB.activeRoot; // reload the committed catalog reference
        var innerIndex: usize = 0;
        while (innerIndex < thisBatch) : (innerIndex += 1) {
            const primaryKey: u64 = inserted + innerIndex;
            const result = try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey });
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

    const speedup: f64 = if (bulkNs == 0)
        0
    else
        @as(f64, @floatFromInt(rowwiseNs)) / @as(f64, @floatFromInt(bulkNs));

    const note = try std.fmt.allocPrint(
        alloc,
        "bulk_ms={d} rowwise_ms={d} speedup={d:.1}x bulk_faults={d} rowwise_faults={d} bulk_commits={d} rowwise_commits={d}",
        .{
            bulkNs / std.time.ns_per_ms,
            rowwiseNs / std.time.ns_per_ms,
            speedup,
            bulkFaults,
            rowwiseFaults,
            bulkCommits,
            rowwiseCommits,
        },
    );

    databaseA.deinit();
    databaseB.deinit();

    return .{
        .name = name,
        .ops = ctx.rowCount,
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
