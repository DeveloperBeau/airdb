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
const batch_size: usize = 5_000;

// Embedded rows are heavier than plain ints (two objects + a link per owner),
// so cap the dataset to keep a 1m-scale run well under a minute.
const max_owners: usize = 200_000;

// Per-phase sample ceilings for read/update/delete.
const max_samples: usize = 50_000;

// Directory type ids and the owner's embedded-link property index.
const owner_type: u16 = 0;
const child_type: u16 = 1;
const embeddedProperty: usize = 1;
const childProperties: usize = 2;

// Owner: {int primaryKey, link(cascade -> child)}. Child: {int primaryKey, int value}, embedded.
const owner_schema = [_][]const catalog.PropertyDefinition{
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = child_type, .del_rule = .cascade } },
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

    const owners = @min(ctx.n, max_owners);

    const path = try harness.scratchPath(ctx.*, name ++ ".airdb");
    defer alloc.free(path);
    defer harness.removeScratch(ctx.*, path);

    var database = try airdb.Database.create(alloc, path);
    errdefer database.deinit();

    // Build the directory: non-embedded owner + embedded child.
    {
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &owner_schema, &.{ false, true });
        w.setRoot(dir);
        _ = try w.commit();
    }

    var combined = harness.Latencies.init();
    defer combined.deinit(alloc);
    var create_lat = harness.Latencies.init();
    defer create_lat.deinit(alloc);
    var read_lat = harness.Latencies.init();
    defer read_lat.deinit(alloc);
    var update_lat = harness.Latencies.init();
    defer update_lat.deinit(alloc);
    var delete_lat = harness.Latencies.init();
    defer delete_lat.deinit(alloc);

    var total_ns: u64 = 0;

    // --- CREATE phase: owner row + one embedded child ------------------------
    {
        const phase_start = nowNs(io);
        var inserted: usize = 0;
        while (inserted < owners) {
            const this_batch = @min(batch_size, owners - inserted);
            var w = try database.beginWrite();
            var dir = w.new_root;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const primaryKey: u64 = inserted + j;
                const t0 = nowNs(io);
                dir = (try typeRouting.insert(&w, dir, owner_type, &.{ .{ .int = primaryKey }, .{ .link = null } })).dir;
                dir = try typedir.insertEmbedded(&w, dir, owner_type, primaryKey, embeddedProperty, &.{ .{ .int = primaryKey }, .{ .int = primaryKey *% 2654435761 } });
                const dt: u64 = @intCast(nowNs(io) - t0);
                try create_lat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(dir);
            _ = try w.commit();
            inserted += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // Sampling strides spread picks evenly across the owner key space.
    const read_n = @min(owners, max_samples);
    const update_n = @min(owners, max_samples);
    const delete_n = @min(owners, max_samples);
    const read_stride = @max(@as(usize, 1), owners / read_n);
    const update_stride = @max(@as(usize, 1), owners / update_n);
    const delete_stride = @max(@as(usize, 1), owners / delete_n);

    // --- READ phase: materialize the embedded child --------------------------
    {
        const phase_start = nowNs(io);
        var r = try database.beginRead();
        const dir = r.root();
        var out: [childProperties]Value = undefined;
        var k: usize = 0;
        while (k < read_n) : (k += 1) {
            const primaryKey: u64 = (k * read_stride) % owners;
            const t0 = nowNs(io);
            _ = try typeRouting.getLinked(&r, dir, owner_type, primaryKey, embeddedProperty, &out);
            const dt: u64 = @intCast(nowNs(io) - t0);
            try read_lat.add(alloc, dt);
            try combined.add(alloc, dt);
        }
        r.end();
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // --- UPDATE phase: replace the embedded child (clear + insert) -----------
    {
        const phase_start = nowNs(io);
        var done: usize = 0;
        while (done < update_n) {
            const this_batch = @min(batch_size, update_n - done);
            var w = try database.beginWrite();
            var dir = w.new_root;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const primaryKey: u64 = ((done + j) * update_stride) % owners;
                const t0 = nowNs(io);
                dir = try typedir.clearEmbedded(&w, dir, owner_type, primaryKey, embeddedProperty);
                dir = try typedir.insertEmbedded(&w, dir, owner_type, primaryKey, embeddedProperty, &.{ .{ .int = primaryKey }, .{ .int = primaryKey *% 40503 } });
                const dt: u64 = @intCast(nowNs(io) - t0);
                try update_lat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(dir);
            _ = try w.commit();
            done += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // --- DELETE phase: clearEmbedded (drops the child, keeps the owner) -------
    var deleted: u64 = 0;
    {
        const phase_start = nowNs(io);
        var done: usize = 0;
        while (done < delete_n) {
            const this_batch = @min(batch_size, delete_n - done);
            var w = try database.beginWrite();
            var dir = w.new_root;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const primaryKey: u64 = ((done + j) * delete_stride) % owners;
                const had_child = (try typeRouting.getLink(&w, dir, owner_type, primaryKey, embeddedProperty)) != null;
                const t0 = nowNs(io);
                dir = try typedir.clearEmbedded(&w, dir, owner_type, primaryKey, embeddedProperty);
                const dt: u64 = @intCast(nowNs(io) - t0);
                if (had_child) {
                    deleted += 1;
                    try delete_lat.add(alloc, dt);
                    try combined.add(alloc, dt);
                }
            }
            w.setRoot(dir);
            _ = try w.commit();
            done += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    const file_bytes = try database.fileSize();
    const logical_bytes = database.logicalSize();

    const ops: u64 = @as(u64, owners) + read_n + update_n + deleted;

    const note = try std.fmt.allocPrint(
        alloc,
        "create_p50_us={d:.1} read_p50_us={d:.1} update_p50_us={d:.1} delete_p50_us={d:.1} owners={d} child_props={d}",
        .{
            @as(f64, @floatFromInt(create_lat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(read_lat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(update_lat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(delete_lat.percentile(50))) / 1000.0,
            owners,
            childProperties,
        },
    );

    const result = harness.Result{
        .name = name,
        .ops = ops,
        .wall_ns = total_ns,
        .p50_ns = combined.percentile(50),
        .p99_ns = combined.percentile(99),
        .max_ns = combined.percentile(100),
        .file_bytes = file_bytes,
        .logical_bytes = logical_bytes,
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };

    database.deinit();
    return result;
}
