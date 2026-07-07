// embedded_crud -- CRUD latency for EMBEDDED objects (subentities): owner rows
// that each own exactly one embedded child via a cascade-rule to-one link.
//
// Embedded objects live under the typedir multi-type API, not the raw single
// catalog. The directory carries two types:
//   type 0  owner  {int primaryKey, link(cascade -> type 1)}   non-embedded
//   type 1  child  {int primaryKey, int value}                 embedded (single-owner)
// The owner's property 1 is the to-one link the embedded child hangs off; declaring
// type 1 embedded marks it single-owner. insertEmbedded/clearEmbedded drive the
// child lifecycle through that link (mirrors the typedir embedded tests).
//
// Phase honesty:
//   CREATE  insert owner row + insertEmbedded one child (timed together).
//   READ    getLinked materializes the embedded child's values.
//   UPDATE  clearEmbedded then insertEmbedded -- the explicit replace path.
//   DELETE  clearEmbedded -- deletes the embedded child and nullifies the
//           owner's inbound link; the owner row itself is left in place.
// All per-op latencies fold into one combined mix for p50/p99/max.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const typedir = airdb.typedir;
const typeRouting = airdb.typeRouting;
const Value = catalog.Value;

pub const name = "embedded_crud";

// Owner rows committed per write transaction across create/update/delete.
const batchSize: usize = 5_000;

// Embedded rows are heavier than plain ints (two objects + a link per owner),
// so cap the dataset to keep a 1m-scale run well under a minute.
const maxOwners: usize = 200_000;

// Per-phase sample ceilings for read/update/delete.
const maxSamples: usize = 50_000;

// Directory type ids and the owner's embedded-link property index.
const ownerType: u16 = 0;
const childType: u16 = 1;
const embeddedProperty: usize = 1;
const childProperties: usize = 2;

// Owner: {int primaryKey, link(cascade -> child)}. Child: {int primaryKey, int value}, embedded.
const ownerSchema = [_][]const catalog.PropertyDefinition{
    &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = childType, .delRule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .int } },
};

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const owners = @min(ctx.n, maxOwners);

    const path = try harness.scratchPath(ctx.*, name ++ ".airdb");
    defer alloc.free(path);
    defer harness.removeScratch(ctx.*, path);

    var database = try airdb.Database.create(alloc, path);
    errdefer database.deinit();

    // Build the directory: non-embedded owner + embedded child.
    {
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &ownerSchema, &.{ false, true });
        w.setRoot(dir);
        _ = try w.commit();
    }

    var combined = harness.Latencies.init();
    defer combined.deinit(alloc);
    var createLat = harness.Latencies.init();
    defer createLat.deinit(alloc);
    var readLat = harness.Latencies.init();
    defer readLat.deinit(alloc);
    var updateLat = harness.Latencies.init();
    defer updateLat.deinit(alloc);
    var deleteLat = harness.Latencies.init();
    defer deleteLat.deinit(alloc);

    var totalNs: u64 = 0;

    // --- CREATE phase: owner row + one embedded child ------------------------
    {
        const phaseStart = nowNs(io);
        var inserted: usize = 0;
        while (inserted < owners) {
            const thisBatch = @min(batchSize, owners - inserted);
            var w = try database.beginWrite();
            var dir = w.newRoot;
            var j: usize = 0;
            while (j < thisBatch) : (j += 1) {
                const primaryKey: u64 = inserted + j;
                const t0 = nowNs(io);
                dir = (try typeRouting.insert(&w, dir, ownerType, &.{ .{ .int = primaryKey }, .{ .link = null } })).dir;
                dir = try typedir.insertEmbedded(&w, dir, ownerType, primaryKey, embeddedProperty, &.{ .{ .int = primaryKey }, .{ .int = primaryKey *% 2654435761 } });
                const dt: u64 = @intCast(nowNs(io) - t0);
                try createLat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(dir);
            _ = try w.commit();
            inserted += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // Sampling strides spread picks evenly across the owner key space.
    const readN = @min(owners, maxSamples);
    const updateN = @min(owners, maxSamples);
    const deleteN = @min(owners, maxSamples);
    const readStride = @max(@as(usize, 1), owners / readN);
    const updateStride = @max(@as(usize, 1), owners / updateN);
    const deleteStride = @max(@as(usize, 1), owners / deleteN);

    // --- READ phase: materialize the embedded child --------------------------
    {
        const phaseStart = nowNs(io);
        var r = try database.beginRead();
        const dir = r.root();
        var out: [childProperties]Value = undefined;
        var k: usize = 0;
        while (k < readN) : (k += 1) {
            const primaryKey: u64 = (k * readStride) % owners;
            const t0 = nowNs(io);
            _ = try typeRouting.getLinked(&r, dir, ownerType, primaryKey, embeddedProperty, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try readLat.add(alloc, dt);
            try combined.add(alloc, dt);
        }
        r.end();
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // --- UPDATE phase: replace the embedded child (clear + insert) -----------
    {
        const phaseStart = nowNs(io);
        var done: usize = 0;
        while (done < updateN) {
            const thisBatch = @min(batchSize, updateN - done);
            var w = try database.beginWrite();
            var dir = w.newRoot;
            var j: usize = 0;
            while (j < thisBatch) : (j += 1) {
                const primaryKey: u64 = ((done + j) * updateStride) % owners;
                const t0 = nowNs(io);
                dir = try typedir.clearEmbedded(&w, dir, ownerType, primaryKey, embeddedProperty);
                dir = try typedir.insertEmbedded(&w, dir, ownerType, primaryKey, embeddedProperty, &.{ .{ .int = primaryKey }, .{ .int = primaryKey *% 40503 } });
                const dt: u64 = @intCast(nowNs(io) - t0);
                try updateLat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(dir);
            _ = try w.commit();
            done += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // --- DELETE phase: clearEmbedded (drops the child, keeps the owner) -------
    var deleted: u64 = 0;
    {
        const phaseStart = nowNs(io);
        var done: usize = 0;
        while (done < deleteN) {
            const thisBatch = @min(batchSize, deleteN - done);
            var w = try database.beginWrite();
            var dir = w.newRoot;
            var j: usize = 0;
            while (j < thisBatch) : (j += 1) {
                const primaryKey: u64 = ((done + j) * deleteStride) % owners;
                const hadChild = (try typeRouting.getLink(&w, dir, ownerType, primaryKey, embeddedProperty)) != null;
                const t0 = nowNs(io);
                dir = try typedir.clearEmbedded(&w, dir, ownerType, primaryKey, embeddedProperty);
                const dt: u64 = @intCast(nowNs(io) - t0);
                if (hadChild) {
                    deleted += 1;
                    try deleteLat.add(alloc, dt);
                    try combined.add(alloc, dt);
                }
            }
            w.setRoot(dir);
            _ = try w.commit();
            done += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();

    const ops: u64 = @as(u64, owners) + readN + updateN + deleted;

    const note = try std.fmt.allocPrint(
        alloc,
        "create_p50_us={d:.1} read_p50_us={d:.1} update_p50_us={d:.1} delete_p50_us={d:.1} owners={d} child_props={d}",
        .{
            @as(f64, @floatFromInt(createLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(readLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(updateLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(deleteLat.percentile(50))) / 1000.0,
            owners,
            childProperties,
        },
    );

    const result = harness.Result{
        .name = name,
        .ops = ops,
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
