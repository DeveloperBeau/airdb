// nested_embedded -- cost of embedded-WITHIN-embedded objects at nesting depth
// 1, 2 and 3, to expose the depth-cost curve of the typedir embedded path.
//
// An embedded child can itself own an embedded child (the engine places no
// nesting cap: insertEmbedded works on any owner type that has a cascade to-one
// link, and the cascade-delete worker recurses to arbitrary depth). We exploit
// that with one directory carrying a single 4-type chain:
//
//   type 0  root        {int pk, link(cascade -> type 1)}   non-embedded
//   type 1  child        {int pk, link(cascade -> type 2)}   embedded
//   type 2  grandchild   {int pk, link(cascade -> type 3)}   embedded
//   type 3  greatchild   {int pk, int value}                 embedded leaf
//
// Depth d builds a root plus d embedded levels down the chain (depth 1 = one
// embedded child; depth 2 = child + grandchild; depth 3 = + great-grandchild).
// Every type owns an independent pk space, so each depth uses key = d*stride + i
// across all its levels to keep rows disjoint across the three depth passes
// while sharing one directory and one Db.
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
const typedir = airdb.typedir;
const Value = catalog.Value;

pub const name = "nested_embedded";

// Deepest nesting the engine supports for this scenario; measured up to here.
const max_depth: usize = 3;

// Embedded chains are heavy (one object + link per level), so cap the dataset
// to keep the three depth passes well under a minute at 1m scale.
const max_rows: usize = 50_000;

// Root rows committed per write transaction.
const batch_size: usize = 5_000;

// Disjoint pk band per depth; larger than max_rows so depth passes never alias.
const depth_stride: u64 = 1_000_000;

// A 4-type chain: types 0..2 carry a cascade to-one link to the next type;
// type 3 is the leaf. Type 0 is the non-embedded root, types 1..3 are embedded.
const chain_schema = [_][]const catalog.PropDef{
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 1, .del_rule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 2, .del_rule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 3, .del_rule = .cascade } },
    &.{ .{ .kind = .int }, .{ .kind = .int } },
};
const chain_embedded = [_]bool{ false, true, true, true };

// The to-one link prop is index 1 on every chain type.
const link_prop: usize = 1;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

pub fn run(ctx: *harness.Ctx) !harness.Result {
    const alloc = ctx.alloc;
    const io = sysIo();

    const rows = @min(ctx.n, max_rows);

    const path = try harness.scratchPath(ctx.*, name ++ ".airdb");
    defer alloc.free(path);
    defer harness.removeScratch(ctx.*, path);

    var db = try airdb.Db.create(alloc, path);
    errdefer db.deinit();

    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &chain_schema, &chain_embedded);
        w.setRoot(dir);
        _ = try w.commit();
    }

    var combined = harness.Latencies.init();
    defer combined.deinit(alloc);

    // Per-depth create/read p50s, in microseconds, indexed by depth-1.
    var create_p50_us = [_]f64{0} ** max_depth;
    var read_p50_us = [_]f64{0} ** max_depth;

    var total_ns: u64 = 0;
    var total_built: u64 = 0;

    var d: usize = 1;
    while (d <= max_depth) : (d += 1) {
        const key_base: u64 = @as(u64, @intCast(d)) * depth_stride;

        var create_lat = harness.Latencies.init();
        defer create_lat.deinit(alloc);
        var read_lat = harness.Latencies.init();
        defer read_lat.deinit(alloc);

        // --- CREATE: root + d embedded levels, one nested structure per row ----
        {
            const phase_start = nowNs(io);
            var inserted: usize = 0;
            while (inserted < rows) {
                const this_batch = @min(batch_size, rows - inserted);
                var w = try db.beginWrite();
                var dir = w.new_root;
                var j: usize = 0;
                while (j < this_batch) : (j += 1) {
                    const key: u64 = key_base + inserted + j;
                    const t0 = nowNs(io);
                    // Root row of type 0.
                    dir = (try typedir.insert(&w, dir, 0, &.{ .{ .int = key }, .{ .link = null } })).dir;
                    // Embedded levels 1..d. Each shares `key` in its own pk space.
                    var level: u16 = 0;
                    while (level < d) : (level += 1) {
                        const leaf = level + 1 == max_depth;
                        const child_vals: [2]Value = if (leaf)
                            .{ .{ .int = key }, .{ .int = key *% 2654435761 } }
                        else
                            .{ .{ .int = key }, .{ .link = null } };
                        dir = try typedir.insertEmbedded(&w, dir, level, key, link_prop, &child_vals);
                    }
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

        // --- READ: full descent through all d levels via getLinked ------------
        {
            const phase_start = nowNs(io);
            var r = try db.beginRead();
            const dir = r.root();
            var out: [2]Value = undefined;
            var i: usize = 0;
            while (i < rows) : (i += 1) {
                const key: u64 = key_base + i;
                const t0 = nowNs(io);
                var level: u16 = 0;
                while (level < d) : (level += 1) {
                    _ = try typedir.getLinked(&r, dir, level, key, link_prop, &out);
                }
                const dt: u64 = @intCast(nowNs(io) - t0);
                try read_lat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            r.end();
            total_ns += @intCast(nowNs(io) - phase_start);
        }

        create_p50_us[d - 1] = @as(f64, @floatFromInt(create_lat.pct(50))) / 1000.0;
        read_p50_us[d - 1] = @as(f64, @floatFromInt(read_lat.pct(50))) / 1000.0;
        total_built += rows;
    }

    const file_bytes = try db.fileSize();
    const logical_bytes = db.logicalSize();

    const note = try std.fmt.allocPrint(
        alloc,
        "d1_create_us={d:.1} d1_read_us={d:.1} d2_create_us={d:.1} d2_read_us={d:.1} d3_create_us={d:.1} d3_read_us={d:.1} rows={d} max_depth={d}",
        .{
            create_p50_us[0], read_p50_us[0],
            create_p50_us[1], read_p50_us[1],
            create_p50_us[2], read_p50_us[2],
            rows,             max_depth,
        },
    );

    const result = harness.Result{
        .name = name,
        .ops = total_built,
        .wall_ns = total_ns,
        .p50_ns = combined.pct(50),
        .p99_ns = combined.pct(99),
        .max_ns = combined.pct(100),
        .file_bytes = file_bytes,
        .logical_bytes = logical_bytes,
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };

    db.deinit();
    return result;
}
