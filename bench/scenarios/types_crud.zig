// types_crud -- CRUD latency across a row that exercises every property kind the
// engine supports, not just plain ints. One type is built with a property of
// each kind, then the four CRUD phases (create / read / update / delete) are run
// over a capped dataset and their per-op latencies folded into a single mix.
//
// Prop layout (single catalog, type id 0 so the link can be a self-link):
//   0  int   primary key
//   1  int   a plain int value
//   2  int   a bool stored as 0/1 (the engine has no distinct bool kind, so a
//            bool is an int holding 0 or 1; recorded as "bool" in the note)
//   3  blob  a 32-byte inline string
//   4  link  self-link (link_target = 0) to another row's object key, or null
//   5  dict  a few string -> int entries
//   6  set   a few ints (elem = int)
//   7  set   a few byte members (elem = blob): the set-of-blob kind
//
// Kinds exercised: int, bool (as int), blob, link, dict, set, set_blob.
// Omitted by design: list and link_set. The task's kind list does not include
// them, and every other supported kind is covered above, so nothing is faked.
//
// Update phase note: Objects.updateTyped is `unreachable` for collection-bearing
// props, so a full-row typed update cannot run on this multi-kind type. The
// update phase instead mutates through the per-property collection mutators and
// the link setter (setAddInt + dictPut + setLink), which are the engine's real
// update path for those kinds and each bump the row version.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const catalog = airdb.catalog;
const objects = airdb.objects;
const collections = airdb.collections;
const links = airdb.links;
const Value = catalog.Value;

pub const name = "types_crud";

// Rows committed per write transaction across the create/update/delete phases.
const batch_size: usize = 5_000;

// Wide typed rows are far heavier than plain ints, so cap the dataset to keep a
// 1m-scale run well under a minute.
const max_rows: usize = 200_000;

// Per-phase sample ceilings for the read/update/delete phases.
const max_samples: usize = 50_000;

// Property indices.
const p_int = 1;
const p_bool = 2;
const p_blob = 3;
const p_link = 4;
const p_dict = 5;
const p_set_int = 6;
const p_set_blob = 7;
const prop_count = 8;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

// Deterministic 64-bit pseudo-random stream (xorshift64*), no clock/global state.
fn xorshift(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
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

    // One type carrying a property of each exercised kind.
    {
        var w = try db.beginWrite();
        const cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int }, // 0 pk
            .{ .kind = .int }, // 1 int
            .{ .kind = .int }, // 2 bool (0/1)
            .{ .kind = .blob }, // 3 string
            .{ .kind = .link, .link_target = 0 }, // 4 self-link
            .{ .kind = .dict }, // 5 dict
            .{ .kind = .set, .elem = .int }, // 6 set of int
            .{ .kind = .set, .elem = .blob }, // 7 set of blob
        });
        w.setRoot(cat);
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

    // --- CREATE phase --------------------------------------------------------
    {
        const phase_start = nowNs(io);
        var inserted: usize = 0;
        while (inserted < rows) {
            const this_batch = @min(batch_size, rows - inserted);
            var w = try db.beginWrite();
            var cat = w.new_root;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const pk: u64 = inserted + j;
                // okeys are assigned 0,1,2,... so okey == pk for a fresh insert.
                var rng: u64 = pk +% 0x9E3779B97F4A7C15;
                const iv = xorshift(&rng);

                var blob_buf: [32]u8 = undefined;
                for (&blob_buf, 0..) |*b, k| b.* = @truncate(iv +% k);

                const dict_entries = [_]catalog.DictEntry{
                    .{ .key = "alpha", .val = iv & 0xffff },
                    .{ .key = "beta", .val = (iv >> 16) & 0xffff },
                    .{ .key = "gamma", .val = (iv >> 32) & 0xffff },
                };
                const set_ints = [_]u64{ iv % 1000, (iv >> 10) % 1000, (iv >> 20) % 1000 };
                const set_blobs = [_][]const u8{ "m0", "m1", "m2" };

                const row = [prop_count]Value{
                    .{ .int = pk },
                    .{ .int = iv },
                    .{ .int = pk & 1 }, // bool
                    .{ .bytes = &blob_buf },
                    .{ .link = if (pk == 0) null else pk - 1 }, // self-link to prior okey
                    .{ .dict_int = &dict_entries },
                    .{ .set_int = &set_ints },
                    .{ .set_blob = &set_blobs },
                };

                const t0 = nowNs(io);
                const r = try objects.insertTyped(&w, cat, &row);
                const dt: u64 = @intCast(nowNs(io) - t0);
                cat = r.cat;
                try create_lat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(cat);
            _ = try w.commit();
            inserted += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // Sampling stride: spread picks evenly across the live key space.
    const read_n = @min(rows, max_samples);
    const update_n = @min(rows, max_samples);
    const delete_n = @min(rows, max_samples);
    const read_stride = @max(@as(usize, 1), rows / read_n);
    const update_stride = @max(@as(usize, 1), rows / update_n);
    const delete_stride = @max(@as(usize, 1), rows / delete_n);

    // --- READ phase: materialize every prop kind -----------------------------
    {
        const phase_start = nowNs(io);
        var r = try db.beginRead();
        const cat = r.root();
        var out: [prop_count]Value = undefined;
        var k: usize = 0;
        while (k < read_n) : (k += 1) {
            const pk: u64 = (k * read_stride) % rows;
            const t0 = nowNs(io);
            _ = try objects.getTyped(&r, cat, pk, &out); // int/bool/blob/link
            _ = try collections.dictCount(&r, cat, pk, p_dict);
            _ = try collections.dictGet(&r, cat, pk, p_dict, "alpha");
            _ = try collections.setCountInt(&r, cat, pk, p_set_int);
            _ = try collections.setCountBlob(&r, cat, pk, p_set_blob);
            _ = try collections.setContainsBlob(&r, cat, pk, p_set_blob, "m1");
            const dt: u64 = @intCast(nowNs(io) - t0);
            try read_lat.add(alloc, dt);
            try combined.add(alloc, dt);
        }
        r.end();
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // --- UPDATE phase: mutate a set, a dict, and the link (version bumps) -----
    {
        const phase_start = nowNs(io);
        var done: usize = 0;
        while (done < update_n) {
            const this_batch = @min(batch_size, update_n - done);
            var w = try db.beginWrite();
            var cat = w.new_root;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const pk: u64 = ((done + j) * update_stride) % rows;
                const target: u64 = (pk + 7) % rows;
                const t0 = nowNs(io);
                cat = try collections.setAddInt(&w, cat, pk, p_set_int, 1_000_000 + pk);
                cat = try collections.dictPut(&w, cat, pk, p_dict, "delta", pk);
                cat = try links.setLink(&w, cat, pk, p_link, target);
                const dt: u64 = @intCast(nowNs(io) - t0);
                try update_lat.add(alloc, dt);
                try combined.add(alloc, dt);
            }
            w.setRoot(cat);
            _ = try w.commit();
            done += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    // --- DELETE phase ---------------------------------------------------------
    var deleted: u64 = 0;
    {
        const phase_start = nowNs(io);
        var done: usize = 0;
        while (done < delete_n) {
            const this_batch = @min(batch_size, delete_n - done);
            var w = try db.beginWrite();
            var cat = w.new_root;
            var raw: [prop_count]u64 = undefined;
            var j: usize = 0;
            while (j < this_batch) : (j += 1) {
                const pk: u64 = ((done + j) * delete_stride) % rows;
                const ver = (try objects.getByPk(&w, cat, pk, &raw)) orelse continue;
                const t0 = nowNs(io);
                const dres = try objects.deleteTyped(&w, cat, pk, ver);
                const dt: u64 = @intCast(nowNs(io) - t0);
                switch (dres) {
                    .ok => |c| {
                        cat = c;
                        deleted += 1;
                        try delete_lat.add(alloc, dt);
                        try combined.add(alloc, dt);
                    },
                    else => {},
                }
            }
            w.setRoot(cat);
            _ = try w.commit();
            done += this_batch;
        }
        total_ns += @intCast(nowNs(io) - phase_start);
    }

    const file_bytes = try db.fileSize();
    const logical_bytes = db.logicalSize();

    const ops: u64 = @as(u64, rows) + read_n + update_n + deleted;

    const note = try std.fmt.allocPrint(
        alloc,
        "create_p50_us={d:.1} read_p50_us={d:.1} update_p50_us={d:.1} delete_p50_us={d:.1} rows={d} kinds=int,bool,blob,link,dict,set,set_blob",
        .{
            @as(f64, @floatFromInt(create_lat.pct(50))) / 1000.0,
            @as(f64, @floatFromInt(read_lat.pct(50))) / 1000.0,
            @as(f64, @floatFromInt(update_lat.pct(50))) / 1000.0,
            @as(f64, @floatFromInt(delete_lat.pct(50))) / 1000.0,
            rows,
        },
    );

    const result = harness.Result{
        .name = name,
        .ops = ops,
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
