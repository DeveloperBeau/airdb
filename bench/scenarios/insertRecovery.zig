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
    var catalogRef: Reference = blk: {
        var w = try database.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    var inserted: usize = 0;
    while (inserted < ctx.n) {
        const thisBatch = @min(batchSize, ctx.n - inserted);
        var w = try database.beginWrite();
        catalogRef = database.activeRoot; // reload the committed catalog ref
        var j: usize = 0;
        while (j < thisBatch) : (j += 1) {
            const primaryKey: u64 = inserted + j;
            const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey });
            catalogRef = r.catalogRef;
        }
        w.setRoot(catalogRef);
        _ = try w.commit();
        inserted += thisBatch;
    }

    const insertNs: u64 = @intCast(nowNs(io) - insertStart);
    const pfAfter = airdb.pageFaults();
    const minfltDelta = pfAfter.minor - pfBefore.minor;
    const majfltDelta = pfAfter.major - pfBefore.major;

    // --- Recovery signal: close, reopen, first read --------------------------
    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();
    const m = database.metrics(); // measurement-only commit/file-growth cost counters
    database.deinit();

    const reopenStart = nowNs(io);
    var reopened = try airdb.Database.open(alloc, path);
    defer reopened.deinit();
    const reopenNs: u64 = @intCast(nowNs(io) - reopenStart);

    // First beginRead refreshes to the latest committed version and pins it,
    // forcing the freshly reopened mapping live. Time a single lookup with it.
    const readStart = nowNs(io);
    var r = try reopened.beginRead();
    catalogRef = r.root();
    var out: [2]u64 = undefined;
    _ = try rows.getByPrimaryKey(&r, catalogRef, 0, &out);
    const firstReadNs: u64 = @intCast(nowNs(io) - readStart);
    r.end();

    const note = try std.fmt.allocPrint(
        alloc,
        "reopen={d}ms first_read={d}us fl_encode_ms={d} fl_extents_total={d} commits={d} setlength_ms={d} setlength_calls={d} fl_rebuild_ms={d} fl_clone_ms={d} minflt={d} majflt={d}",
        .{
            reopenNs / std.time.ns_per_ms,
            firstReadNs / std.time.ns_per_us,
            m.flEncodeNs / std.time.ns_per_ms,
            m.flExtentsEncoded,
            m.commitCount,
            m.setlengthNs / std.time.ns_per_ms,
            m.setlengthCalls,
            m.flRebuildNs / std.time.ns_per_ms,
            m.flCloneNs / std.time.ns_per_ms,
            minfltDelta,
            majfltDelta,
        },
    );

    return .{
        .name = name,
        .ops = ctx.n,
        .wallNs = insertNs,
        .fileBytes = fileBytes,
        .logicalBytes = logicalBytes,
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
