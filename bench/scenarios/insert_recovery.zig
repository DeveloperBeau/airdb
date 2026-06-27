// insert_recovery -- bulk-insert N rows in batched write transactions, then
// measure the cost of closing and reopening the database (the recovery signal).
//
// There is no crash-injection hook in the public API, so "recovery" here is the
// honest reopen path: Db.open re-reads the header and remaps the file, and the
// first beginRead refreshes to the latest committed version and pins it. Both
// are timed and reported in Result.note, labeled for what they actually are.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Ref = airdb.Ref;
const catalog = airdb.catalog;
const objects = airdb.objects;

pub const name = "insert_recovery";

// Rows committed per write transaction.
const batch_size: usize = 10_000;

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

    // --- Insert phase --------------------------------------------------------
    const insert_start = nowNs(io);

    var db = try airdb.Db.create(alloc, path);
    errdefer db.deinit();

    // Simple two-int type: {pk, value}. The first value is the primary key.
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
            const r = try objects.insert(&w, cat, &.{ pk, pk });
            cat = r.cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
        inserted += this_batch;
    }

    const insert_ns: u64 = @intCast(nowNs(io) - insert_start);

    // --- Recovery signal: close, reopen, first read --------------------------
    const file_bytes = try db.fileSize();
    const logical_bytes = db.logicalSize();
    db.deinit();

    const reopen_start = nowNs(io);
    var reopened = try airdb.Db.open(alloc, path);
    defer reopened.deinit();
    const reopen_ns: u64 = @intCast(nowNs(io) - reopen_start);

    // First beginRead refreshes to the latest committed version and pins it,
    // forcing the freshly reopened mapping live. Time a single lookup with it.
    const read_start = nowNs(io);
    var r = try reopened.beginRead();
    cat = r.root();
    var out: [2]u64 = undefined;
    _ = try objects.getByPk(&r, cat, 0, &out);
    const first_read_ns: u64 = @intCast(nowNs(io) - read_start);
    r.end();

    const note = try std.fmt.allocPrint(
        alloc,
        "reopen={d}ms first_read={d}us",
        .{ reopen_ns / std.time.ns_per_ms, first_read_ns / std.time.ns_per_us },
    );

    return .{
        .name = name,
        .ops = ctx.n,
        .wall_ns = insert_ns,
        .file_bytes = file_bytes,
        .logical_bytes = logical_bytes,
        .peak_rss_bytes = airdb.peakResidentBytes(),
        .note = note,
    };
}
