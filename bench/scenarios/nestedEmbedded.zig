// nested_embedded -- cost of embedded-WITHIN-embedded objects at nesting depth
// 1, 2 and 3, to expose the depth-cost curve of the typeDirectory embedded path.
//
// An embedded child can itself own an embedded child (the engine places no
// nesting cap: insertEmbedded works on any owner type that has a cascade to-one
// link, and the cascade-delete worker recurses to arbitrary depth). We exploit
// that with one directory carrying a single 4-type chain:
//
//   type 0  root        {int primaryKey, link(cascade -> type 1)}   non-embedded
//   type 1  child        {int primaryKey, link(cascade -> type 2)}   embedded
//   type 2  grandchild   {int primaryKey, link(cascade -> type 3)}   embedded
//   type 3  greatchild   {int primaryKey, int value}                 embedded leaf
//
// Depth d builds a root plus d embedded levels down the chain (depth 1 = one
// embedded child; depth 2 = child + grandchild; depth 3 = + great-grandchild).
// Every type owns an independent primaryKey space, so each depth uses key = d*stride + i
// across all its levels to keep rows disjoint across the three depth passes
// while sharing one directory and one Database.
//
// Phase honesty:
//   CREATE  insert the root row + chain insertEmbedded down d levels (timed as
//           one nested-structure build per row).
//   READ    walk all d levels via getLinked, materializing each level (timed as
//           one full descent per row).
// Per-depth create/read p50s land in the note; all per-op samples across every
// depth fold into one combined mix for p50/p99/max.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const catalog = airdb.catalog;
const typeDirectory = airdb.typeDirectory;
const typeRouting = airdb.typeRouting;
const Value = catalog.Value;

pub const name = "nested_embedded";

// Deepest nesting the engine supports for this scenario; measured up to here.
const maxDepth: usize = 3;

// Embedded chains are heavy (one object + link per level), so cap the dataset
// to keep the three depth passes well under a minute at 1m scale.
const maxRows: usize = 50_000;

// Root rows committed per write transaction.
const batchSize: usize = 5_000;

// Disjoint primaryKey band per depth; larger than maxRows so depth passes never alias.
const depthStride: u64 = 1_000_000;

// A 4-type chain: types 0..2 carry a cascade to-one link to the next type;
// type 3 is the leaf. Type 0 is the non-embedded root, types 1..3 are embedded.
const chainSchema = [_][]const catalog.PropertyDefinition{
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 1, .deletionRule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 2, .deletionRule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 3, .deletionRule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .int } },
};
const chainEmbedded = [_]bool{ false, true, true, true };

// The to-one link property is index 1 on every chain type.
const linkProperty: usize = 1;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const rows = @min(ctx.rowCount, maxRows);

    const path = try harness.scratchPath(ctx.*, name ++ ".airdb");
    defer alloc.free(path);
    defer harness.removeScratch(ctx.*, path);

    var database = try airdb.Database.create(alloc, path);
    errdefer database.deinit();

    {
        var writeTransaction = try database.beginWrite();
        const dir = try typeDirectory.createTypes(&writeTransaction, &chainSchema, &chainEmbedded);
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    var combined = harness.Latencies.init();
    defer combined.deinit(alloc);

    // Per-depth create/read p50s, in microseconds, indexed by depth-1.
    var createP50Us = [_]f64{0} ** maxDepth;
    var readP50Us = [_]f64{0} ** maxDepth;

    var totalNs: u64 = 0;
    var totalBuilt: u64 = 0;

    var payload: usize = 1;
    while (payload <= maxDepth) : (payload += 1) {
        const keyBase: u64 = @as(u64, @intCast(payload)) * depthStride;

        var createLat = harness.Latencies.init();
        defer createLat.deinit(alloc);
        var readLat = harness.Latencies.init();
        defer readLat.deinit(alloc);

        // --- CREATE: root + d embedded levels, one nested structure per row ----
        {
            const phaseStart = nowNs(io);
            var inserted: usize = 0;
            while (inserted < rows) {
                const thisBatch = @min(batchSize, rows - inserted);
                var writeTransaction = try database.beginWrite();
                var dir = writeTransaction.newRoot;
                var innerIndex: usize = 0;
                while (innerIndex < thisBatch) : (innerIndex += 1) {
                    const key: u64 = keyBase + inserted + innerIndex;
                    const startNs = nowNs(io);
                    // Root row of type 0.
                    dir = (try typeRouting.insert(&writeTransaction, dir, 0, &.{ .{ .int = key }, .{ .link = null } })).dir;
                    // Embedded levels 1..d. Each shares `key` in its own primaryKey space.
                    var level: u16 = 0;
                    while (level < payload) : (level += 1) {
                        const leaf = level + 1 == maxDepth;
                        const childVals: [2]Value = if (leaf)
                            .{ .{ .int = key }, .{ .int = key *% 2654435761 } }
                        else
                            .{ .{ .int = key }, .{ .link = null } };
                        dir = try typeDirectory.insertEmbedded(&writeTransaction, dir, level, key, linkProperty, &childVals);
                    }
                    const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
                    try createLat.add(alloc, elapsedNs);
                    try combined.add(alloc, elapsedNs);
                }
                writeTransaction.setRoot(dir);
                _ = try writeTransaction.commit();
                inserted += thisBatch;
            }
            totalNs += @intCast(nowNs(io) - phaseStart);
        }

        // --- READ: full descent through all d levels via getLinked ------------
        {
            const phaseStart = nowNs(io);
            var readTransaction = try database.beginRead();
            const dir = readTransaction.root();
            var out: [2]Value = undefined;
            var index: usize = 0;
            while (index < rows) : (index += 1) {
                const key: u64 = keyBase + index;
                const startNs = nowNs(io);
                var level: u16 = 0;
                while (level < payload) : (level += 1) {
                    _ = try typeRouting.getLinked(&readTransaction, dir, level, key, linkProperty, &out);
                }
                const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
                try readLat.add(alloc, elapsedNs);
                try combined.add(alloc, elapsedNs);
            }
            readTransaction.end();
            totalNs += @intCast(nowNs(io) - phaseStart);
        }

        createP50Us[payload - 1] = @as(f64, @floatFromInt(createLat.percentile(50))) / 1000.0;
        readP50Us[payload - 1] = @as(f64, @floatFromInt(readLat.percentile(50))) / 1000.0;
        totalBuilt += rows;
    }

    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();

    const note = try std.fmt.allocPrint(
        alloc,
        "d1_create_us={d:.1} d1_read_us={d:.1} d2_create_us={d:.1} d2_read_us={d:.1} d3_create_us={d:.1} d3_read_us={d:.1} rows={d} max_depth={d}",
        .{
            createP50Us[0], readP50Us[0],
            createP50Us[1], readP50Us[1],
            createP50Us[2], readP50Us[2],
            rows,           maxDepth,
        },
    );

    const result = harness.Result{
        .name = name,
        .ops = totalBuilt,
        .wallNs = totalNs,
        .p50Ns = combined.percentile(50),
        .p99Ns = combined.percentile(99),
        .maxNs = combined.percentile(100),
        .fileBytes = fileBytes,
        .logicalBytes = logicalBytes,
        .peakRssBytes = airdb.peakResidentBytes(),
        .note = note,
    };

    database.deinit();
    return result;
}
