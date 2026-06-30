// harness.zig -- shared infrastructure for the standalone airdb bench suite.
//
// Responsibilities split:
//   - This file owns argument parsing, the scratch-directory lifecycle, latency
//     bookkeeping, the result table, and JSON output.
//   - Individual scenarios (added in later tasks) own opening a Db, inserting
//     rows, and measuring. The harness never opens a Db itself; it only hands a
//     `Ctx` (allocator, row count, scratch dir) to each scenario.
//
// Zig 0.16 idioms used here (mirrors src/file_store.zig):
//   - Io instance       -> std.Io.Threaded.global_single_threaded.io()
//   - stdout writer     -> Io.File.Writer over Io.File.stdout()
//   - file create/open  -> Io.Dir.cwd().createFile(io, ...)
//   - dir create/delete -> Io.Dir.cwd().createDirPath / deleteTree
//   - JSON              -> std.json.fmt(value, .{}) via the "{f}" placeholder

const std = @import("std");
const airdb = @import("airdb");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// Returns the blocking Io instance used for all file/dir operations. Always
// initialized (compile-time vtable), matching the convention in file_store.zig.
inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const Scale = enum { m1, m10 };

fn scaleStr(scale: Scale) []const u8 {
    return switch (scale) {
        .m1 => "1m",
        .m10 => "10m",
    };
}

/// Parsed command-line options. `json_path` and `only`, when set, are owned
/// (duped) heap strings; call `deinit` to free them.
pub const Opts = struct {
    scale: Scale = .m1,
    json_path: ?[]const u8 = null,
    only: ?[]const u8 = null,

    pub fn deinit(self: Opts, alloc: Allocator) void {
        if (self.json_path) |p| alloc.free(p);
        if (self.only) |o| alloc.free(o);
    }
};

/// Per-scenario context. Scenarios open their own Db under `tmp_dir`.
pub const Ctx = struct {
    alloc: Allocator,
    n: usize,
    tmp_dir: []const u8,
};

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub const Result = struct {
    name: []const u8,
    ops: u64,
    wall_ns: u64,
    p50_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,
    file_bytes: u64 = 0,
    logical_bytes: u64 = 0,
    peak_rss_bytes: u64 = 0,
    note: []const u8 = "",

    /// Operations per second over the wall-clock window. Returns 0 when no time
    /// elapsed (avoids divide-by-zero).
    pub fn throughputPerSec(self: Result) f64 {
        if (self.wall_ns == 0) return 0;
        const ops_f: f64 = @floatFromInt(self.ops);
        const wall_f: f64 = @floatFromInt(self.wall_ns);
        return ops_f * 1e9 / wall_f;
    }
};

/// Collects per-operation latency samples so a scenario can report percentiles.
/// Backed by an unmanaged ArrayList; the caller supplies the allocator.
pub const Latencies = struct {
    samples: std.ArrayList(u64),

    pub fn init() Latencies {
        return .{ .samples = .empty };
    }

    pub fn deinit(self: *Latencies, alloc: Allocator) void {
        self.samples.deinit(alloc);
    }

    pub fn add(self: *Latencies, alloc: Allocator, ns: u64) !void {
        try self.samples.append(alloc, ns);
    }

    /// Returns the p-th percentile sample (p in 0..=100), sorting in place.
    /// Returns 0 when there are no samples.
    pub fn pct(self: *Latencies, p: u64) u64 {
        const items = self.samples.items;
        if (items.len == 0) return 0;
        std.mem.sort(u64, items, {}, std.sort.asc(u64));
        const idx = (items.len - 1) * p / 100;
        return items[idx];
    }
};

// ---------------------------------------------------------------------------
// Unit conversion helpers
// ---------------------------------------------------------------------------

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn bytesToMib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1048576.0;
}

// ---------------------------------------------------------------------------
// Table output
// ---------------------------------------------------------------------------

/// Writes an ASCII table of results to `w` (a `*std.Io.Writer`). Numbers are
/// right-aligned in fixed columns; latency columns show "-" for scenarios that
/// recorded no per-op samples (p99_ns == 0).
pub fn printTable(results: []const Result, w: anytype) !void {
    try w.print(
        "{s:<24} {s:>12} {s:>14} {s:>10} {s:>10} {s:>10} {s:>11} {s:>11} {s:>11}\n",
        .{ "name", "ops", "ops/s", "p50 us", "p99 us", "max us", "file MiB", "logical MiB", "rss MiB" },
    );
    for (results) |r| {
        if (r.p99_ns == 0) {
            try w.print(
                "{s:<24} {d:12} {d:14.0} {s:>10} {s:>10} {s:>10} {d:11.1} {d:11.1} {d:11.1}\n",
                .{
                    r.name,                       r.ops,
                    r.throughputPerSec(),         "-",
                    "-",                          "-",
                    bytesToMib(r.file_bytes),     bytesToMib(r.logical_bytes),
                    bytesToMib(r.peak_rss_bytes),
                },
            );
        } else {
            try w.print(
                "{s:<24} {d:12} {d:14.0} {d:10.1} {d:10.1} {d:10.1} {d:11.1} {d:11.1} {d:11.1}\n",
                .{
                    r.name,                       r.ops,
                    r.throughputPerSec(),         nsToUs(r.p50_ns),
                    nsToUs(r.p99_ns),             nsToUs(r.max_ns),
                    bytesToMib(r.file_bytes),     bytesToMib(r.logical_bytes),
                    bytesToMib(r.peak_rss_bytes),
                },
            );
        }
    }
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

/// Appends one JSON object per result (newline-delimited) to the file at
/// `path`, creating it if absent and preserving any existing contents.
pub fn appendJson(path: []const u8, scale: Scale, results: []const Result, alloc: Allocator) !void {
    const Record = struct {
        scenario: []const u8,
        scale: []const u8,
        ops: u64,
        ops_per_sec: f64,
        p50_us: f64,
        p99_us: f64,
        max_us: f64,
        file_mib: f64,
        logical_mib: f64,
        rss_mib: f64,
        note: []const u8,
    };

    const io = sysIo();
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const start = try file.length(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (results) |r| {
        const rec = Record{
            .scenario = r.name,
            .scale = scaleStr(scale),
            .ops = r.ops,
            .ops_per_sec = r.throughputPerSec(),
            .p50_us = nsToUs(r.p50_ns),
            .p99_us = nsToUs(r.p99_ns),
            .max_us = nsToUs(r.max_ns),
            .file_mib = bytesToMib(r.file_bytes),
            .logical_mib = bytesToMib(r.logical_bytes),
            .rss_mib = bytesToMib(r.peak_rss_bytes),
            .note = r.note,
        };
        const line = try std.fmt.allocPrint(alloc, "{f}\n", .{std.json.fmt(rec, .{})});
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }

    if (buf.items.len > 0) try file.writePositionalAll(io, buf.items, start);
}

// ---------------------------------------------------------------------------
// Scratch-file helpers
// ---------------------------------------------------------------------------

/// Joins `ctx.tmp_dir` and `name` into an absolute path. Caller frees.
pub fn scratchPath(ctx: Ctx, name: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.alloc, &.{ ctx.tmp_dir, name });
}

/// Deletes a scratch file, ignoring any error (best-effort cleanup).
pub fn removeScratch(ctx: Ctx, path: []const u8) void {
    _ = ctx;
    Io.Dir.cwd().deleteFile(sysIo(), path) catch {};
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const default_json_path = "bench-results.json";

fn usage() void {
    std.debug.print(
        \\usage: airdb-bench [options]
        \\  --scale=1m|10m   row count to drive scenarios (default 1m)
        \\  --json[=PATH]    append results as JSON (default {s})
        \\  --only=NAME      run only the named scenario
        \\
    , .{default_json_path});
}

/// Parses argv (slice from `init.minimal.args.toSlice`) into `Opts`. Retained
/// strings are duped into `alloc`; free with `Opts.deinit`. Unknown flags or an
/// invalid --scale value print usage to stderr and return an error.
pub fn parseArgs(alloc: Allocator, args: []const [:0]const u8) !Opts {
    var opts: Opts = .{};
    errdefer opts.deinit(alloc);

    var i: usize = 1; // skip the program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--scale=")) {
            const v = arg["--scale=".len..];
            if (std.mem.eql(u8, v, "1m")) {
                opts.scale = .m1;
            } else if (std.mem.eql(u8, v, "10m")) {
                opts.scale = .m10;
            } else {
                usage();
                return error.InvalidScale;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            try setJsonPath(&opts, alloc, default_json_path);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            try setJsonPath(&opts, alloc, arg["--json=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--only=")) {
            if (opts.only) |o| alloc.free(o);
            opts.only = try alloc.dupe(u8, arg["--only=".len..]);
        } else {
            usage();
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn setJsonPath(opts: *Opts, alloc: Allocator, path: []const u8) !void {
    if (opts.json_path) |p| alloc.free(p);
    opts.json_path = try alloc.dupe(u8, path);
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

const Scenario = struct {
    name: []const u8,
    run: *const fn (*Ctx) anyerror!Result,
};

/// Runs every registered scenario (filtered by `opts.only`), prints the result
/// table to stdout, and optionally appends JSON. Manages the scratch directory.
pub fn runAll(alloc: Allocator, opts: Opts) !void {
    const n: usize = if (opts.scale == .m1) 1_000_000 else 10_000_000;

    const io = sysIo();
    const scratch = scratchDir();
    // Start from a clean slate, then guarantee removal on the way out.
    Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try Io.Dir.cwd().createDirPath(io, scratch);
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};

    // scenarios registered here as they land
    const insert_recovery = @import("scenarios/insert_recovery.zig");
    const lookup_query = @import("scenarios/lookup_query.zig");
    const churn_compaction = @import("scenarios/churn_compaction.zig");
    const blobs_pitr = @import("scenarios/blobs_pitr.zig");
    const types_crud = @import("scenarios/types_crud.zig");
    const embedded_crud = @import("scenarios/embedded_crud.zig");
    const nested_embedded = @import("scenarios/nested_embedded.zig");
    const bulk_import = @import("scenarios/bulk_import.zig");
    const scenarios = [_]Scenario{
        .{ .name = insert_recovery.name, .run = insert_recovery.run },
        .{ .name = lookup_query.name, .run = lookup_query.run },
        .{ .name = churn_compaction.name, .run = churn_compaction.run },
        .{ .name = blobs_pitr.name, .run = blobs_pitr.run },
        .{ .name = types_crud.name, .run = types_crud.run },
        .{ .name = embedded_crud.name, .run = embedded_crud.run },
        .{ .name = nested_embedded.name, .run = nested_embedded.run },
        .{ .name = bulk_import.name, .run = bulk_import.run },
    };

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(alloc);

    for (scenarios) |s| {
        if (opts.only) |only| {
            if (!std.mem.eql(u8, only, s.name)) continue;
        }
        var ctx = Ctx{ .alloc = alloc, .n = n, .tmp_dir = scratch };
        try results.append(alloc, try s.run(&ctx));
    }

    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    try printTable(results.items, w);
    try w.flush();

    if (opts.json_path) |jp| {
        try appendJson(jp, opts.scale, results.items, alloc);
    }
}

// POSIX scratch directory. The repo's C smoke test already assumes a fixed
// "/tmp" path for POSIX hosts; we follow that convention here.
fn scratchDir() []const u8 {
    return "/tmp/airdb-bench";
}

// ---------------------------------------------------------------------------
// Tests
//
// These do not depend on the airdb module, so they run standalone with
//   zig test bench/harness.zig
// ---------------------------------------------------------------------------

test "Latencies percentiles pick the right sample" {
    const alloc = std.testing.allocator;
    var lat = Latencies.init();
    defer lat.deinit(alloc);

    var v: u64 = 1;
    while (v <= 100) : (v += 1) try lat.add(alloc, v);

    try std.testing.expectEqual(@as(u64, 50), lat.pct(50));
    try std.testing.expectEqual(@as(u64, 100), lat.pct(100));
    try std.testing.expectEqual(@as(u64, 1), lat.pct(0));
}

test "Latencies percentiles on an empty set are zero" {
    const alloc = std.testing.allocator;
    var lat = Latencies.init();
    defer lat.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 0), lat.pct(50));
}

test "Result throughput math" {
    const r = Result{ .name = "x", .ops = 1000, .wall_ns = 1_000_000_000 };
    try std.testing.expectEqual(@as(f64, 1000), r.throughputPerSec());
}

test "Result throughput guards zero wall time" {
    const r = Result{ .name = "x", .ops = 1000, .wall_ns = 0 };
    try std.testing.expectEqual(@as(f64, 0), r.throughputPerSec());
}
