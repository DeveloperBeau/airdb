// lookup_query -- measure read-side performance over a pre-populated database:
// point lookups by primary key (per-op latency percentiles) and two scan-style
// queries (an equality predicate on an indexed property and a full scan).
//
// The insert phase is setup only and is not timed. Point lookups hit random
// primary keys in [0, n); the indices come from a deterministic xorshift so the
// run is reproducible without any banned clock/RNG source.
//
// The query engine in query.zig has no index-seek fast path yet: both the
// equality query and the full scan walk the key->row index. They are timed and
// labeled for what they actually are -- "eq" is a scan with one eq predicate,
// "full" is a scan with no predicate (every live row).

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const catalog = airdb.catalog;
const objects = airdb.objects;
const query = airdb.query;

pub const name = "lookup_query";

// Rows committed per write transaction during the (untimed) insert phase.
const batch_size: usize = 10_000;

// Number of point lookups to sample for latency percentiles.
const lookup_count: usize = 100_000;

// Distinct category values; each row gets category = pk % category_mod.
const category_mod: u64 = 100;

// The category the equality query selects on.
const eq_category: u64 = 42;

// Monotonic wall-clock instance, matching the convention in file_store.zig.
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

    // --- Insert phase (setup only, not timed) --------------------------------
    var db = try airdb.Db.create(alloc, path);
    defer db.deinit();

    // Two-int type: {pk, category}. Property 0 is the primary key, property 1
    // is the low-cardinality category used by the equality query.
    var cat: Ref = blk: {
        var w = try db.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    var inserted: usize = 0;
    while (inserted < ctx.n) {
        const this_batch = @min(batch_size, ctx.n - inserted);
        var w = try db.beginWrite();
        cat = db.active_root; // reload the committed catalog ref
        var j: usize = 0;
        while (j < this_batch) : (j += 1) {
            const pk: u64 = inserted + j;
            const r = try objects.insert(&w, cat, &.{ pk, pk % category_mod });
            cat = r.cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
        inserted += this_batch;
    }

    // --- Point-lookup latency ------------------------------------------------
    var lat = harness.Latencies.init();
    defer lat.deinit(alloc);

    var rd = try db.beginRead();
    cat = rd.root();

    // Deterministic xorshift64 over a fixed seed; index = x % n keeps every
    // lookup inside [0, n). No clock/RNG dependency, so the run is reproducible.
    var x: u64 = 0x9E3779B97F4A7C15;
    const n_u64: u64 = @intCast(ctx.n);

    const lookup_start = nowNs(io);
    var k: usize = 0;
    while (k < lookup_count) : (k += 1) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        const pk: u64 = x % n_u64;
        var out: [2]u64 = undefined;
        const t0 = nowNs(io);
        _ = try objects.getByPk(&rd, cat, pk, &out);
        const dt: u64 = @intCast(nowNs(io) - t0);
        try lat.add(alloc, dt);
    }
    const lookup_ns: u64 = @intCast(nowNs(io) - lookup_start);

    // --- Query scans ---------------------------------------------------------
    // Equality query: category == eq_category (one eq predicate, scanned).
    const eq_start = nowNs(io);
    const rows_eq = try query.countWhere(
        &rd,
        cat,
        &.{.{ .prop = 1, .op = .eq, .value = eq_category }},
        alloc,
    );
    const eq_ns: u64 = @intCast(nowNs(io) - eq_start);

    // Full scan: no predicate matches every live row.
    const full_start = nowNs(io);
    _ = try query.countWhere(&rd, cat, &.{}, alloc);
    const full_ns: u64 = @intCast(nowNs(io) - full_start);

    rd.end();

    const note = try std.fmt.allocPrint(
        alloc,
        "eq={d}us full={d}ms rows_eq={d}",
        .{ eq_ns / std.time.ns_per_us, full_ns / std.time.ns_per_ms, rows_eq },
    );

    return .{
        .name = name,
        .ops = lookup_count,
        .wall_ns = lookup_ns,
        .p50_ns = lat.pct(50),
        .p99_ns = lat.pct(99),
        .max_ns = lat.pct(100),
        .file_bytes = try db.fileSize(),
        .logical_bytes = db.logicalSize(),
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
