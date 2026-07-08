// insert_recovery -- bulk-insert N rows in batched write transactions, then
// measure the cost of closing and reopening the database (the recovery signal).
//
// There is no crash-injection hook in the public API, so "recovery" here is the
// honest reopen path: Database.open re-reads the header and remaps the file, and the
// first beginRead refreshes to the latest committed version and pins it. Both
// are timed and reported in Result.note, labeled for what they actually are.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const rows = airdb.rows;

pub const name = "insert_recovery";

// Rows committed per write transaction.
const batchSize: usize = 10_000;

// Monotonic wall-clock instance, matching the convention in fileStore.zig.
inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const path = try harness.scratchPath(ctx.*, name ++ ".airdb");
    defer alloc.free(path);
    defer harness.removeScratch(ctx.*, path);

    // --- Insert phase --------------------------------------------------------
    const pfBefore = airdb.pageFaults();
    const insertStart = nowNs(io);

    var database = try airdb.Database.create(alloc, path);
    errdefer database.deinit();

    // Simple two-int type: {primaryKey, value}. The first value is the primary key.
    var catalogReference: Reference = blk: {
        var writeTransaction = try database.beginWrite();
        const catalogReference = try catalog.create(&writeTransaction, 2);
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
        break :blk catalogReference;
    };

    var inserted: usize = 0;
    while (inserted < ctx.rowCount) {
        const thisBatch = @min(batchSize, ctx.rowCount - inserted);
        var writeTransaction = try database.beginWrite();
        catalogReference = database.activeRoot; // reload the committed catalog reference
        var innerIndex: usize = 0;
        while (innerIndex < thisBatch) : (innerIndex += 1) {
            const primaryKey: u64 = inserted + innerIndex;
            const result = try rows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey });
            catalogReference = result.catalogReference;
        }
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
        inserted += thisBatch;
    }

    const insertNs: u64 = @intCast(nowNs(io) - insertStart);
    const pfAfter = airdb.pageFaults();
    const minfltDelta = pfAfter.minor - pfBefore.minor;
    const majfltDelta = pfAfter.major - pfBefore.major;

    // --- Recovery signal: close, reopen, first read --------------------------
    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();
    const metrics = database.metrics(); // measurement-only commit/file-growth cost counters
    database.deinit();

    const reopenStart = nowNs(io);
    var reopened = try airdb.Database.open(alloc, path);
    defer reopened.deinit();
    const reopenNs: u64 = @intCast(nowNs(io) - reopenStart);

    // First beginRead refreshes to the latest committed version and pins it,
    // forcing the freshly reopened mapping live. Time a single lookup with it.
    const readStart = nowNs(io);
    var readTransaction = try reopened.beginRead();
    catalogReference = readTransaction.root();
    var out: [2]u64 = undefined;
    _ = try rows.getByPrimaryKey(&readTransaction, catalogReference, 0, &out);
    const firstReadNs: u64 = @intCast(nowNs(io) - readStart);
    readTransaction.end();

    const note = try std.fmt.allocPrint(
        alloc,
        "reopen={d}ms first_read={d}us fl_encode_ms={d} fl_extents_total={d} commits={d} setlength_ms={d} setlength_calls={d} fl_rebuild_ms={d} fl_clone_ms={d} minflt={d} majflt={d}",
        .{
            reopenNs / std.time.ns_per_ms,
            firstReadNs / std.time.ns_per_us,
            metrics.flEncodeNs / std.time.ns_per_ms,
            metrics.flExtentsEncoded,
            metrics.commitCount,
            metrics.setlengthNs / std.time.ns_per_ms,
            metrics.setlengthCalls,
            metrics.flRebuildNs / std.time.ns_per_ms,
            metrics.flCloneNs / std.time.ns_per_ms,
            minfltDelta,
            majfltDelta,
        },
    );

    return .{
        .name = name,
        .ops = ctx.rowCount,
        .wallNs = insertNs,
        .fileBytes = fileBytes,
        .logicalBytes = logicalBytes,
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
