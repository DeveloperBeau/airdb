// bulk_append -- append a contiguous, right-edge batch to a POPULATED type two
// ways and contrast the cost. Both databases are seeded identically with a base
// of N/2 rows; then the same N/2-row contiguous batch (pks above the current
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
// Baseline choice: Path B uses batched commits (batch_size rows per commit), not
// auto-commit per row, because that is how a sane bulk loader would use the
// row-by-row API today. It is the honest baseline bulkAppend competes against.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const catalog = airdb.catalog;
const objects = airdb.objects;
const bulk = airdb.bulk;

pub const name = "bulk_append";

// Rows committed per write transaction on the row-by-row path. Matches
// bulk_import / insert_recovery so the baseline is apples-to-apples.
const batch_size: usize = 10_000;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

// Seed a fresh two-int type with `base` rows (pks 0..base-1, value = pk) using
// bulkImport in one transaction, so both databases start from an identical,
// already-populated base. Returns nothing; the committed catalog is the root.
fn seedBase(db: *airdb.Db, base_rows: []const []const u64) !void {
    var w = try db.beginWrite();
    const c = try catalog.create(&w, 2);
    const seeded = try bulk.bulkImport(&w, c, base_rows, .{ .presorted = true });
    w.setRoot(seeded);
    _ = try w.commit();
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const base: usize = ctx.n / 2;
    const m: usize = ctx.n / 2;

    const path_a = try harness.scratchPath(ctx.*, name ++ "_bulk.airdb");
    defer alloc.free(path_a);
    defer harness.removeScratch(ctx.*, path_a);
    const path_b = try harness.scratchPath(ctx.*, name ++ "_rowwise.airdb");
    defer alloc.free(path_b);
    defer harness.removeScratch(ctx.*, path_b);
    const path_c = try harness.scratchPath(ctx.*, name ++ "_fallback.airdb");
    defer alloc.free(path_c);
    defer harness.removeScratch(ctx.*, path_c);

    // --- Build the base rows (0..base-1) and the append batch (base..base+m-1).
    // Each is a flat backing buffer sliced into per-row []const u64 windows.
    const base_storage = try alloc.alloc([2]u64, base);
    defer alloc.free(base_storage);
    const base_rows = try alloc.alloc([]const u64, base);
    defer alloc.free(base_rows);
    for (base_storage, base_rows, 0..) |*cells, *row, i| {
        cells.* = .{ @intCast(i), @intCast(i) };
        row.* = &cells.*;
    }

    const batch_storage = try alloc.alloc([2]u64, m);
    defer alloc.free(batch_storage);
    const batch = try alloc.alloc([]const u64, m);
    defer alloc.free(batch);
    for (batch_storage, batch, 0..) |*cells, *row, i| {
        const pk: u64 = @intCast(base + i);
        cells.* = .{ pk, pk };
        row.* = &cells.*;
    }

    // --- Seed both databases identically with the populated base. ----------
    var db_a = try airdb.Db.create(alloc, path_a);
    errdefer db_a.deinit();
    try seedBase(&db_a, base_rows);

    var db_b = try airdb.Db.create(alloc, path_b);
    errdefer db_b.deinit();
    try seedBase(&db_b, base_rows);

    // --- Path A: bulk append the batch in one write transaction. -----------
    const a_commits_before = db_a.metrics().commit_count;
    const a_pf_before = airdb.pageFaults();
    const bulk_start = nowNs(io);
    {
        var w = try db_a.beginWrite();
        const new_cat = try bulk.bulkAppendOrInsert(&w, w.new_root, batch);
        w.setRoot(new_cat);
        _ = try w.commit();
    }
    const bulk_ns: u64 = @intCast(nowNs(io) - bulk_start);
    const a_pf_after = airdb.pageFaults();
    const bulk_faults = (a_pf_after.minor - a_pf_before.minor) + (a_pf_after.major - a_pf_before.major);
    const bulk_commits = db_a.metrics().commit_count - a_commits_before;

    const file_bytes = try db_a.fileSize();
    const logical_bytes = db_a.logicalSize();

    // --- Path B: row-by-row inserts of the same batch in batched commits. --
    const b_commits_before = db_b.metrics().commit_count;
    const b_pf_before = airdb.pageFaults();
    const rowwise_start = nowNs(io);
    var inserted: usize = 0;
    while (inserted < m) {
        const this_batch = @min(batch_size, m - inserted);
        var w = try db_b.beginWrite();
        var cat: Ref = db_b.active_root; // reload the committed catalog ref
        var j: usize = 0;
        while (j < this_batch) : (j += 1) {
            const pk: u64 = base + inserted + j;
            const r = try objects.insert(&w, cat, &.{ pk, pk });
            cat = r.cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
        inserted += this_batch;
    }
    const rowwise_ns: u64 = @intCast(nowNs(io) - rowwise_start);
    const b_pf_after = airdb.pageFaults();
    const rowwise_faults = (b_pf_after.minor - b_pf_before.minor) + (b_pf_after.major - b_pf_before.major);
    const rowwise_commits = db_b.metrics().commit_count - b_commits_before;

    // --- Fallback smoke: a scattered (non-ascending) batch must be rejected
    // with NotAppendable and nothing written. Kept cheap: a tiny seeded type.
    var fallback_ok = false;
    {
        var db_c = try airdb.Db.create(alloc, path_c);
        defer db_c.deinit();
        var small_storage: [4][2]u64 = undefined;
        var small_rows: [4][]const u64 = undefined;
        for (&small_storage, &small_rows, 0..) |*cells, *row, i| {
            cells.* = .{ @intCast(i), @intCast(i) };
            row.* = &cells.*;
        }
        try seedBase(&db_c, &small_rows);

        // pks 100, 102, 101: above the max but NOT strictly ascending.
        const scattered = [_][]const u64{ &.{ 100, 100 }, &.{ 102, 102 }, &.{ 101, 101 } };
        var w = try db_c.beginWrite();
        if (bulk.bulkAppend(&w, w.new_root, &scattered)) |_| {
            // Unexpectedly appendable: leave fallback_ok false.
        } else |e| switch (e) {
            error.NotAppendable => fallback_ok = true,
            else => return e,
        }
        w.deinit(); // abort: nothing should have been written anyway
    }

    const speedup: f64 = if (bulk_ns == 0)
        0
    else
        @as(f64, @floatFromInt(rowwise_ns)) / @as(f64, @floatFromInt(bulk_ns));

    const note = try std.fmt.allocPrint(
        alloc,
        "bulk_ms={d} rowwise_ms={d} speedup={d:.1}x bulk_faults={d} rowwise_faults={d} bulk_commits={d} rowwise_commits={d} base={d} m={d} fallback_ok={}",
        .{
            bulk_ns / std.time.ns_per_ms,
            rowwise_ns / std.time.ns_per_ms,
            speedup,
            bulk_faults,
            rowwise_faults,
            bulk_commits,
            rowwise_commits,
            base,
            m,
            fallback_ok,
        },
    );

    db_a.deinit();
    db_b.deinit();

    return .{
        .name = name,
        .ops = m,
        .wall_ns = bulk_ns,
        .p50_ns = 0,
        .p99_ns = 0,
        .max_ns = 0,
        .file_bytes = file_bytes,
        .logical_bytes = logical_bytes,
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
