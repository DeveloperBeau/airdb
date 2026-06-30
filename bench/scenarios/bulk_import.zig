// bulk_import -- load N rows two ways and contrast the cost. Path A drives the
// bottom-up bulkImport orchestrator in a single write transaction; Path B inserts
// the identical rows one at a time in batched commits (the realistic baseline,
// mirroring insert_recovery's batching). We report the load-time speedup, the
// page-fault delta for each path, and the commit count for each so the win is
// documented in numbers rather than asserted.
//
// Baseline choice: Path B uses batched commits (batch_size rows per commit), not
// auto-commit per row, because that is how a sane bulk loader would use the
// row-by-row API today. It is the honest baseline bulkImport competes against.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const catalog = airdb.catalog;
const objects = airdb.objects;
const bulk = airdb.bulk;

pub const name = "bulk_import";

// Rows committed per write transaction on the row-by-row path. Matches
// insert_recovery so the baseline is apples-to-apples.
const batch_size: usize = 10_000;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const path_a = try harness.scratchPath(ctx.*, name ++ "_bulk.airdb");
    defer alloc.free(path_a);
    defer harness.removeScratch(ctx.*, path_a);
    const path_b = try harness.scratchPath(ctx.*, name ++ "_rowwise.airdb");
    defer alloc.free(path_b);
    defer harness.removeScratch(ctx.*, path_b);

    // --- Build the rows once, shared by both paths. Two-int type {pk, value};
    // pk = i, value = i. A flat backing buffer sliced into per-row windows so
    // bulkImport sees a []const []const u64.
    const storage = try alloc.alloc([2]u64, ctx.n);
    defer alloc.free(storage);
    const rows = try alloc.alloc([]const u64, ctx.n);
    defer alloc.free(rows);
    for (storage, rows, 0..) |*cells, *row, i| {
        cells.* = .{ @intCast(i), @intCast(i) };
        row.* = &cells.*;
    }

    // --- Path A: bulk import in one write transaction -----------------------
    var db_a = try airdb.Db.create(alloc, path_a);
    errdefer db_a.deinit();

    // Empty two-int catalog committed as the root, so the bulk write transaction
    // sees it via w.new_root. bulkImport requires the type to be empty.
    {
        var w = try db_a.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
    }

    const a_commits_before = db_a.metrics().commit_count;
    const a_pf_before = airdb.pageFaults();
    const bulk_start = nowNs(io);
    {
        var w = try db_a.beginWrite();
        const new_cat = try bulk.bulkImport(&w, w.new_root, rows, .{});
        w.setRoot(new_cat);
        _ = try w.commit();
    }
    const bulk_ns: u64 = @intCast(nowNs(io) - bulk_start);
    const a_pf_after = airdb.pageFaults();
    const bulk_faults = (a_pf_after.minor - a_pf_before.minor) + (a_pf_after.major - a_pf_before.major);
    const bulk_commits = db_a.metrics().commit_count - a_commits_before;

    const file_bytes = try db_a.fileSize();
    const logical_bytes = db_a.logicalSize();

    // --- Path B: row-by-row inserts in batched commits ----------------------
    var db_b = try airdb.Db.create(alloc, path_b);
    errdefer db_b.deinit();
    var cat: Ref = blk: {
        var w = try db_b.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    const b_commits_before = db_b.metrics().commit_count;
    const b_pf_before = airdb.pageFaults();
    const rowwise_start = nowNs(io);
    var inserted: usize = 0;
    while (inserted < ctx.n) {
        const this_batch = @min(batch_size, ctx.n - inserted);
        var w = try db_b.beginWrite();
        cat = db_b.active_root; // reload the committed catalog ref
        var j: usize = 0;
        while (j < this_batch) : (j += 1) {
            const pk: u64 = inserted + j;
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

    const speedup: f64 = if (bulk_ns == 0)
        0
    else
        @as(f64, @floatFromInt(rowwise_ns)) / @as(f64, @floatFromInt(bulk_ns));

    const note = try std.fmt.allocPrint(
        alloc,
        "bulk_ms={d} rowwise_ms={d} speedup={d:.1}x bulk_faults={d} rowwise_faults={d} bulk_commits={d} rowwise_commits={d}",
        .{
            bulk_ns / std.time.ns_per_ms,
            rowwise_ns / std.time.ns_per_ms,
            speedup,
            bulk_faults,
            rowwise_faults,
            bulk_commits,
            rowwise_commits,
        },
    );

    db_a.deinit();
    db_b.deinit();

    return .{
        .name = name,
        .ops = ctx.n,
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
