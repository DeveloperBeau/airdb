// churn_compaction -- hold a fixed live working set under steady insert/delete
// churn while incremental compaction keeps the type packed, and measure that the
// dead-row ratio (and therefore the file footprint) stays bounded over time.
//
// Each iteration inserts k fresh rows (new, monotonically increasing primaryKeys) and
// deletes the k oldest live primaryKeys, so the live count stays flat at W while dead
// rows accumulate at the bottom of the column. After every iteration we drive
// compaction.compactStep to repack the live tail rows into the holes and
// truncate the dead tail, timing each step for latency percentiles.
//
// The reported throughput is total rows relocated by compaction (Result.ops)
// over the whole churn+compaction wall window. The steady-state dead ratio is
// recorded in the note; if it ever exceeds the bound we record the real value
// rather than passing silently.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const rows = airdb.rows;
const compaction = airdb.compaction;

pub const name = "churn_compaction";

// Rows churned (inserted and deleted) per iteration.
const k: usize = 1000;

// Maximum live working-set size. Capped so the per-step compaction walk over the
// key->row index stays bounded regardless of scale. compactStep cost scales with
// the live-set size (it scans the whole key->row index per call), not the budget,
// so this cap dominates churn runtime.
const max_working_set: usize = 20_000;

// Churn iterations are capped independent of scale: the steady-state dead ratio
// stabilizes within a few iterations, and each iteration drives a full compaction
// pass over the working set, so an uncapped count would make the bench run for
// many minutes at 1M+ without changing the measured steady state.
const max_iters: u64 = 40;

// Relocations attempted per compactStep call.
const compact_budget: usize = 4096;

// Dead-ratio bound the steady state is expected to hold below.
const dead_ratio_bound: f64 = 0.5;

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

    const working_set: u64 = @min(ctx.n, max_working_set);
    // Total churn work scales with the requested row count but stays bounded:
    // iters * k inserts + iters * k deletes.
    const iters: u64 = @min(max_iters, @max(@as(u64, 1), @as(u64, @intCast(ctx.n)) / k));

    var database = try airdb.Database.create(alloc, path);
    defer database.deinit();

    // Two-int type: {primaryKey, value}. Property 0 is the primary key.
    var catalogRef: Reference = blk: {
        var w = try database.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    // --- Seed the live working set (setup only, not timed) -------------------
    {
        var w = try database.beginWrite();
        catalogRef = database.active_root;
        var primaryKey: u64 = 0;
        while (primaryKey < working_set) : (primaryKey += 1) {
            const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey });
            catalogRef = r.catalogRef;
        }
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // Live primaryKeys form a sliding window [oldestPrimaryKey, nextPrimaryKey); its width stays at
    // working_set, so deletes always target rows that exist.
    var nextPrimaryKey: u64 = working_set;
    var oldestPrimaryKey: u64 = 0;

    var step_lat = harness.Latencies.init();
    defer step_lat.deinit(alloc);

    var total_moved: u64 = 0;

    // --- Churn + compaction (timed) ------------------------------------------
    const phase_start = nowNs(io);

    var it: u64 = 0;
    while (it < iters) : (it += 1) {
        // Churn: insert k fresh rows and delete the k oldest live primaryKeys in one transaction.
        {
            var w = try database.beginWrite();
            catalogRef = database.active_root;

            var j: usize = 0;
            while (j < k) : (j += 1) {
                const primaryKey = nextPrimaryKey + j;
                const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey });
                catalogRef = r.catalogRef;
            }

            j = 0;
            while (j < k) : (j += 1) {
                const primaryKey = oldestPrimaryKey + j;
                var out: [2]u64 = undefined;
                const version = (try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)) orelse unreachable;
                catalogRef = switch (try rows.delete(&w, catalogRef, primaryKey, version)) {
                    .ok => |c| c,
                    else => unreachable,
                };
            }

            w.setRoot(catalogRef);
            _ = try w.commit();

            nextPrimaryKey += k;
            oldestPrimaryKey += k;
        }

        // Compaction: repack the type until fully packed, one step per write transaction.
        while (true) {
            var w = try database.beginWrite();
            catalogRef = database.active_root;
            const t0 = nowNs(io);
            const res = try compaction.compactStep(&w, catalogRef, 0, compact_budget);
            const dt: u64 = @intCast(nowNs(io) - t0);
            catalogRef = res.catalogRef;
            w.setRoot(catalogRef);
            _ = try w.commit();

            try step_lat.add(alloc, dt);
            total_moved += res.moved;
            if (res.done or res.moved == 0) break;
        }
    }

    const phase_ns: u64 = @intCast(nowNs(io) - phase_start);

    // --- Steady-state dead ratio ---------------------------------------------
    var live: u64 = 0;
    var next_row: u64 = 0;
    {
        var rd = try database.beginRead();
        defer rd.end();
        catalogRef = rd.root();
        live = try compaction.liveCount(&rd, catalogRef);
        next_row = (try catalog.loadCatalog(&rd, catalogRef)).next_row;
    }
    const dead_ratio: f64 = if (next_row == 0)
        0
    else
        @as(f64, @floatFromInt(next_row - live)) / @as(f64, @floatFromInt(next_row));

    // A bound breach is a real finding, not a crash: record the actual ratio and
    // flag it in the note instead of asserting.
    const breach = dead_ratio >= dead_ratio_bound;

    const note = try std.fmt.allocPrint(
        alloc,
        "live={d} next_row={d} dead_ratio={d:.2} W={d} iters={d} bound={s} comparison=skipped",
        .{ live, next_row, dead_ratio, working_set, iters, if (breach) "BREACHED" else "held" },
    );

    return .{
        .name = name,
        .ops = total_moved,
        .wall_ns = phase_ns,
        .p50_ns = step_lat.percentile(50),
        .p99_ns = step_lat.percentile(99),
        .max_ns = step_lat.percentile(100),
        .file_bytes = try database.fileSize(),
        .logical_bytes = database.logicalSize(),
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
