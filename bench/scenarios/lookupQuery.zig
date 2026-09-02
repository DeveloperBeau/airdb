// lookup_query -- measure read-side performance over a pre-populated database:
// point lookups by primary key (per-op latency percentiles) and two scan-style
// queries (an equality predicate on an indexed property and a full scan).
//
// The insert phase is setup only and is not timed. Point lookups hit random
// primary keys in [0, n); the indices come from a deterministic xorshift so the
// run is reproducible without any banned clock/RNG source.
//
// Property 1 (category) is declared indexed, so each insert also maintains a
// value index for it. The equality query (category == eqCategory) is routed
// by the planner through that value index -- it is index-backed, not a scan.
// The full scan has no predicate and still walks the key->row index. Labels:
// "eq" is the single-eq query (index-backed), "full" is the no-predicate scan,
// and "idxEqUs" is the measured per-call latency of the index-backed eq.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const rows = airdb.rows;
const query = airdb.query;

pub const name = "lookup_query";

// Rows committed per write transaction during the (untimed) insert phase.
const batchSize: usize = 10_000;

// Number of point lookups to sample for latency percentiles.
const lookupCount: usize = 100_000;

// Distinct category values; each row gets category = primaryKey % categoryMod.
const categoryMod: u64 = 100;

// The category the equality query selects on.
const eqCategory: u64 = 42;

// Repetitions of the index-backed equality query used to derive its per-call
// latency (averaged), small enough to keep the run well under a minute.
const indexedEqRepetitions: usize = 1000;

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

    // --- Insert phase (setup only, not timed) --------------------------------
    var database = try airdb.Database.create(alloc, path);
    defer database.deinit();

    // Two-int type: {primaryKey, category}. Property 0 is the primary key, property 1
    // is the low-cardinality category, declared indexed so the equality query
    // is served by its value index rather than a full scan.
    var catalogReference: Reference = blk: {
        var writeTransaction = try database.beginWrite();
        const valueC = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int },
            .{ .kind = .int, .indexed = true },
        });
        writeTransaction.setRoot(valueC);
        _ = try writeTransaction.commit();
        break :blk valueC;
    };

    var inserted: usize = 0;
    while (inserted < ctx.rowCount) {
        const thisBatch = @min(batchSize, ctx.rowCount - inserted);
        var writeTransaction = try database.beginWrite();
        catalogReference = database.activeRoot; // reload the committed catalog reference
        var innerIndex: usize = 0;
        while (innerIndex < thisBatch) : (innerIndex += 1) {
            const primaryKey: u64 = inserted + innerIndex;
            const result = try rows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey % categoryMod });
            catalogReference = result.catalogReference;
        }
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
        inserted += thisBatch;
    }

    // --- Point-lookup latency ------------------------------------------------
    var lat = harness.Latencies.init();
    defer lat.deinit(alloc);

    var readTransaction = try database.beginRead();
    catalogReference = readTransaction.root();

    // Deterministic xorshift64 over a fixed seed; index = x % n keeps every
    // lookup inside [0, n). No clock/RNG dependency, so the run is reproducible.
    var state: u64 = 0x9E3779B97F4A7C15;
    const nU64: u64 = @intCast(ctx.rowCount);

    const lookupStart = nowNs(io);
    var key: usize = 0;
    while (key < lookupCount) : (key += 1) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const primaryKey: u64 = state % nU64;
        var out: [2]u64 = undefined;
        const startNs = nowNs(io);
        _ = try rows.getByPrimaryKey(&readTransaction, catalogReference, primaryKey, &out);
        const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
        try lat.add(alloc, elapsedNs);
    }
    const lookupNs: u64 = @intCast(nowNs(io) - lookupStart);

    // --- Query scans ---------------------------------------------------------
    // Index-backed equality query: category == eqCategory. The planner routes
    // this through the value index on property 1. Timed once for the "eq" note
    // and over many repetitions for the per-call "idxEqUs" latency.
    var rowsEq: u64 = 0;
    const eqStart = nowNs(io);
    var err: usize = 0;
    while (err < indexedEqRepetitions) : (err += 1) {
        rowsEq = try query.countWhere(
            &readTransaction,
            catalogReference,
            .{ .comparison = .{ .property = 1, .operator = .eq, .value = .{ .int = eqCategory } } },
            alloc,
        );
    }
    const eqTotalNs: u64 = @intCast(nowNs(io) - eqStart);
    const indexedEqNs: u64 = eqTotalNs / indexedEqRepetitions;

    // Full scan: no predicate matches every live row.
    const fullStart = nowNs(io);
    _ = try query.countWhere(&readTransaction, catalogReference, .{ .conjunction = &.{} }, alloc);
    const fullNs: u64 = @intCast(nowNs(io) - fullStart);

    readTransaction.end();

    const note = try std.fmt.allocPrint(
        alloc,
        "eq={d}us full={d}ms idx_eq_us={d} rows_eq={d}",
        .{
            indexedEqNs / std.time.ns_per_us,
            fullNs / std.time.ns_per_ms,
            indexedEqNs / std.time.ns_per_us,
            rowsEq,
        },
    );

    return .{
        .name = name,
        .ops = lookupCount,
        .wallNs = lookupNs,
        .p50Ns = lat.percentile(50),
        .p99Ns = lat.percentile(99),
        .maxNs = lat.percentile(100),
        .fileBytes = try database.fileSize(),
        .logicalBytes = database.logicalSize(),
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
