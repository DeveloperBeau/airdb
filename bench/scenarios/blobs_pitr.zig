// blobs_pitr -- two read/write signals that the other scenarios don't cover:
//
//   Part A (large-blob throughput): write and read back a handful of multi-MiB
//   blobs to exercise the chunked blob path (blobs over ~16 MiB are split into
//   chunk nodes). Reports PUT and GET bandwidth in MiB/s. The blob count is a
//   fixed small constant (NOT scaled by ctx.n): each blob is 24 MiB, so eight of
//   them is ~192 MiB on disk -- scaling by the 1M/10M row count would write
//   hundreds of GiB.
//
//   Part B (point-in-time read overhead): build a small versioned int table with
//   a wide retention window, then compare point-lookup latency on the latest
//   snapshot against the same lookups on an early historical version via
//   beginReadAt. Reports both p50s and the historical overhead percentage.
//
// The two parts use two separate scratch databases (blobs.airdb, pitr.airdb).
// The reported file/logical sizes come from the blob database (the large one);
// the reported p50/p99/max latencies come from Part B's latest-snapshot reads.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const blob = airdb.blob;
const catalog = airdb.catalog;
const objects = airdb.objects;

pub const name = "blobs_pitr";

// --- Part A knobs -----------------------------------------------------------
// Bounded, NOT scaled by ctx.n. 24 MiB > the ~16 MiB inline cap, so each blob
// takes the chunked path. Eight blobs is ~192 MiB total.
const blob_bytes: usize = 24 * 1024 * 1024;
const blob_count: usize = 8;

// --- Part B knobs -----------------------------------------------------------
// Rows committed per write transaction during the (untimed) insert phase. The
// first batch establishes the historical version, so only pks in [0, pitr_batch)
// are guaranteed to exist at v_old; lookups stay inside that range.
const pitr_batch: usize = 100;
const pitr_rows: usize = 1_000;
const pitr_lookups: usize = 10_000;

// Monotonic wall-clock instance, matching the convention in file_store.zig.
inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

fn mibPerSec(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    const b: f64 = @floatFromInt(bytes);
    const t: f64 = @floatFromInt(ns);
    return (b * 1e9) / (t * 1048576.0);
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    // --- Part A: large-blob throughput --------------------------------------
    const blob_path = try harness.scratchPath(ctx.*, name ++ "-blobs.airdb");
    defer alloc.free(blob_path);
    defer harness.removeScratch(ctx.*, blob_path);

    // One deterministic 24 MiB source buffer, reused for every blob.
    const buf = try alloc.alloc(u8, blob_bytes);
    defer alloc.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761);

    var db = try airdb.Db.create(alloc, blob_path);
    errdefer db.deinit();

    var refs: [blob_count]Ref = undefined;

    // PUT: one blob per write transaction.
    var put_bytes: u64 = 0;
    const put_start = nowNs(io);
    var i: usize = 0;
    while (i < blob_count) : (i += 1) {
        var w = try db.beginWrite();
        refs[i] = try blob.put(&w, buf);
        _ = try w.commit();
        put_bytes += blob_bytes;
    }
    const put_ns: u64 = @intCast(nowNs(io) - put_start);

    // GET: read every blob back in a single read snapshot.
    var get_bytes: u64 = 0;
    const get_start = nowNs(io);
    var rd = try db.beginRead();
    i = 0;
    while (i < blob_count) : (i += 1) {
        const out = try blob.getAlloc(&rd, refs[i], alloc);
        defer alloc.free(out);
        get_bytes += out.len;
        // Correctness guard on the last blob: a chunked round-trip that silently
        // dropped or reordered bytes must fail the bench loudly.
        if (i == blob_count - 1) {
            if (out.len != blob_bytes or out[0] != buf[0] or out[out.len - 1] != buf[buf.len - 1]) {
                return error.BlobRoundTripMismatch;
            }
        }
    }
    rd.end();
    const get_ns: u64 = @intCast(nowNs(io) - get_start);

    // Capture the (large) blob-db metrics before closing it.
    const file_bytes = try db.fileSize();
    const logical_bytes = db.logicalSize();
    db.deinit();

    // --- Part B: point-in-time read overhead --------------------------------
    const pitr_path = try harness.scratchPath(ctx.*, name ++ "-pitr.airdb");
    defer alloc.free(pitr_path);
    defer harness.removeScratch(ctx.*, pitr_path);

    var pdb = try airdb.Db.create(alloc, pitr_path);
    defer pdb.deinit();

    // Retain everything so the early version's nodes stay readable.
    pdb.setRetainVersions(std.math.maxInt(u64));

    // Two-int type {pk, value}; property 0 is the primary key.
    {
        var w = try pdb.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
    }

    // Insert in batches; the first batch's commit fixes the historical version.
    var v_old: u64 = 0;
    var inserted: usize = 0;
    while (inserted < pitr_rows) {
        const this_batch = @min(pitr_batch, pitr_rows - inserted);
        var w = try pdb.beginWrite();
        var cat = pdb.active_root;
        var j: usize = 0;
        while (j < this_batch) : (j += 1) {
            const pk: u64 = inserted + j;
            const r = try objects.insert(&w, cat, &.{ pk, pk *% 7 });
            cat = r.cat;
        }
        w.setRoot(cat);
        const v = try w.commit();
        if (inserted == 0) v_old = v; // pks [0, pitr_batch) exist from here on
        inserted += this_batch;
    }

    // Deterministic xorshift64 over a fixed seed; pk stays in [0, pitr_batch) so
    // every lookup resolves at both the latest and the historical version.
    const pk_mod: u64 = pitr_batch;

    // Latest-snapshot lookups.
    var lat_latest = harness.Latencies.init();
    defer lat_latest.deinit(alloc);
    {
        var rl = try pdb.beginRead();
        const cat = rl.root();
        var x: u64 = 0x9E3779B97F4A7C15;
        var k: usize = 0;
        while (k < pitr_lookups) : (k += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const pk: u64 = x % pk_mod;
            var out: [2]u64 = undefined;
            const t0 = nowNs(io);
            _ = try objects.getByPk(&rl, cat, pk, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try lat_latest.add(alloc, dt);
        }
        rl.end();
    }

    // Historical-snapshot lookups at v_old (same pk sequence).
    var lat_hist = harness.Latencies.init();
    defer lat_hist.deinit(alloc);
    {
        var rh = try pdb.beginReadAt(v_old);
        const cat = rh.root();
        var x: u64 = 0x9E3779B97F4A7C15;
        var k: usize = 0;
        while (k < pitr_lookups) : (k += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const pk: u64 = x % pk_mod;
            var out: [2]u64 = undefined;
            const t0 = nowNs(io);
            _ = try objects.getByPk(&rh, cat, pk, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try lat_hist.add(alloc, dt);
        }
        rh.end();
    }

    const latest_p50 = lat_latest.pct(50);
    const hist_p50 = lat_hist.pct(50);
    const overhead_pct: f64 = if (latest_p50 == 0)
        0
    else
        (@as(f64, @floatFromInt(hist_p50)) - @as(f64, @floatFromInt(latest_p50))) /
            @as(f64, @floatFromInt(latest_p50)) * 100.0;

    const note = try std.fmt.allocPrint(
        alloc,
        "blobs={d}x{d}MiB(chunked) put_MiBps={d:.0} get_MiBps={d:.0} " ++
            "latest_p50_us={d:.2} hist_p50_us={d:.2} overhead_pct={d:.1} " ++
            "(file/logical from blob db; latencies from latest reads)",
        .{
            blob_count,
            blob_bytes / (1024 * 1024),
            mibPerSec(put_bytes, put_ns),
            mibPerSec(get_bytes, get_ns),
            @as(f64, @floatFromInt(latest_p50)) / 1000.0,
            @as(f64, @floatFromInt(hist_p50)) / 1000.0,
            overhead_pct,
        },
    );

    return .{
        .name = name,
        .ops = blob_count,
        .wall_ns = put_ns + get_ns,
        .p50_ns = latest_p50,
        .p99_ns = lat_latest.pct(99),
        .max_ns = lat_latest.pct(100),
        .file_bytes = file_bytes,
        .logical_bytes = logical_bytes,
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
