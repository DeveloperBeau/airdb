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
const Reference = airdb.Reference;
const blob = airdb.blob;
const catalog = airdb.catalog;
const rows = airdb.rows;

pub const name = "blobs_pitr";

// --- Part A knobs -----------------------------------------------------------
// Bounded, NOT scaled by ctx.n. 24 MiB > the ~16 MiB inline cap, so each blob
// takes the chunked path. Eight blobs is ~192 MiB total.
const blobBytes: usize = 24 * 1024 * 1024;
const blobCount: usize = 8;

// --- Part B knobs -----------------------------------------------------------
// Rows committed per write transaction during the (untimed) insert phase. The
// first batch establishes the historical version, so only primaryKeys in [0, pitrBatch)
// are guaranteed to exist at vOld; lookups stay inside that range.
const pitrBatch: usize = 100;
const pitrRows: usize = 1_000;
const pitrLookups: usize = 10_000;

// Monotonic wall-clock instance, matching the convention in fileStore.zig.
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
    const blobPath = try harness.scratchPath(ctx.*, name ++ "-blobs.airdb");
    defer alloc.free(blobPath);
    defer harness.removeScratch(ctx.*, blobPath);

    // One deterministic 24 MiB source buffer, reused for every blob.
    const buffer = try alloc.alloc(u8, blobBytes);
    defer alloc.free(buffer);
    for (buffer, 0..) |*b, i| b.* = @truncate(i *% 2654435761);

    var database = try airdb.Database.create(alloc, blobPath);
    errdefer database.deinit();

    var refs: [blobCount]Reference = undefined;

    // PUT: one blob per write transaction.
    var putBytes: u64 = 0;
    const putStart = nowNs(io);
    var i: usize = 0;
    while (i < blobCount) : (i += 1) {
        var w = try database.beginWrite();
        refs[i] = try blob.put(&w, buffer);
        _ = try w.commit();
        putBytes += blobBytes;
    }
    const putNs: u64 = @intCast(nowNs(io) - putStart);

    // GET: read every blob back in a single read snapshot.
    var getBytes: u64 = 0;
    const getStart = nowNs(io);
    var rd = try database.beginRead();
    i = 0;
    while (i < blobCount) : (i += 1) {
        const out = try blob.getAlloc(&rd, refs[i], alloc);
        defer alloc.free(out);
        getBytes += out.len;
        // Correctness guard on the last blob: a chunked round-trip that silently
        // dropped or reordered bytes must fail the bench loudly.
        if (i == blobCount - 1) {
            if (out.len != blobBytes or out[0] != buffer[0] or out[out.len - 1] != buffer[buffer.len - 1]) {
                return error.BlobRoundTripMismatch;
            }
        }
    }
    rd.end();
    const getNs: u64 = @intCast(nowNs(io) - getStart);

    // Capture the (large) blob-database metrics before closing it.
    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();
    database.deinit();

    // --- Part B: point-in-time read overhead --------------------------------
    const pitrPath = try harness.scratchPath(ctx.*, name ++ "-pitr.airdb");
    defer alloc.free(pitrPath);
    defer harness.removeScratch(ctx.*, pitrPath);

    var pitrDatabase = try airdb.Database.create(alloc, pitrPath);
    defer pitrDatabase.deinit();

    // Retain everything so the early version's nodes stay readable.
    pitrDatabase.setRetainVersions(std.math.maxInt(u64));

    // Two-int type {primaryKey, value}; property 0 is the primary key.
    {
        var w = try pitrDatabase.beginWrite();
        const c = try catalog.create(&w, 2);
        w.setRoot(c);
        _ = try w.commit();
    }

    // Insert in batches; the first batch's commit fixes the historical version.
    var vOld: u64 = 0;
    var inserted: usize = 0;
    while (inserted < pitrRows) {
        const thisBatch = @min(pitrBatch, pitrRows - inserted);
        var w = try pitrDatabase.beginWrite();
        var catalogRef = pitrDatabase.activeRoot;
        var j: usize = 0;
        while (j < thisBatch) : (j += 1) {
            const primaryKey: u64 = inserted + j;
            const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey *% 7 });
            catalogRef = r.catalogRef;
        }
        w.setRoot(catalogRef);
        const v = try w.commit();
        if (inserted == 0) vOld = v; // primaryKeys [0, pitrBatch) exist from here on
        inserted += thisBatch;
    }

    // Deterministic xorshift64 over a fixed seed; primaryKey stays in [0, pitrBatch) so
    // every lookup resolves at both the latest and the historical version.
    const primaryKeyModulus: u64 = pitrBatch;

    // Latest-snapshot lookups.
    var latLatest = harness.Latencies.init();
    defer latLatest.deinit(alloc);
    {
        var rl = try pitrDatabase.beginRead();
        const catalogRef = rl.root();
        var x: u64 = 0x9E3779B97F4A7C15;
        var k: usize = 0;
        while (k < pitrLookups) : (k += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const primaryKey: u64 = x % primaryKeyModulus;
            var out: [2]u64 = undefined;
            const t0 = nowNs(io);
            _ = try rows.getByPrimaryKey(&rl, catalogRef, primaryKey, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try latLatest.add(alloc, dt);
        }
        rl.end();
    }

    // Historical-snapshot lookups at vOld (same primaryKey sequence).
    var latHist = harness.Latencies.init();
    defer latHist.deinit(alloc);
    {
        var rh = try pitrDatabase.beginReadAt(vOld);
        const catalogRef = rh.root();
        var x: u64 = 0x9E3779B97F4A7C15;
        var k: usize = 0;
        while (k < pitrLookups) : (k += 1) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            const primaryKey: u64 = x % primaryKeyModulus;
            var out: [2]u64 = undefined;
            const t0 = nowNs(io);
            _ = try rows.getByPrimaryKey(&rh, catalogRef, primaryKey, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try latHist.add(alloc, dt);
        }
        rh.end();
    }

    const latestP50 = latLatest.percentile(50);
    const histP50 = latHist.percentile(50);
    const overheadPercent: f64 = if (latestP50 == 0)
        0
    else
        (@as(f64, @floatFromInt(histP50)) - @as(f64, @floatFromInt(latestP50))) /
            @as(f64, @floatFromInt(latestP50)) * 100.0;

    const note = try std.fmt.allocPrint(
        alloc,
        "blobs={d}x{d}MiB(chunked) put_MiBps={d:.0} get_MiBps={d:.0} " ++
            "latest_p50_us={d:.2} hist_p50_us={d:.2} overhead_pct={d:.1} " ++
            "(file/logical from blob db; latencies from latest reads)",
        .{
            blobCount,
            blobBytes / (1024 * 1024),
            mibPerSec(putBytes, putNs),
            mibPerSec(getBytes, getNs),
            @as(f64, @floatFromInt(latestP50)) / 1000.0,
            @as(f64, @floatFromInt(histP50)) / 1000.0,
            overheadPercent,
        },
    );

    return .{
        .name = name,
        .ops = blobCount,
        .wallNs = putNs + getNs,
        .p50Ns = latestP50,
        .p99Ns = latLatest.percentile(99),
        .maxNs = latLatest.percentile(100),
        .fileBytes = fileBytes,
        .logicalBytes = logicalBytes,
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
