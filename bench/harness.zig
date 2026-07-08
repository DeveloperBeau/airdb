// harness.zig -- shared infrastructure for the standalone airdb bench suite.
//
// Responsibilities split:
//   - This file owns argument parsing, the scratch-directory lifecycle, latency
//     bookkeeping, the result table, and JSON output.
//   - Individual scenarios (added in later tasks) own opening a Database, inserting
//     rows, and measuring. The harness never opens a Database itself; it only hands a
//     `Ctx` (allocator, row count, scratch dir) to each scenario.
//
// Zig 0.16 idioms used here (mirrors src/fileStore.zig):
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
// initialized (compile-time vtable), matching the convention in fileStore.zig.
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

/// Parsed command-line options. `jsonPath` and `only`, when set, are owned
/// (duped) heap strings; call `deinit` to free them.
pub const Opts = struct {
    scale: Scale = .m1,
    jsonPath: ?[]const u8 = null,
    only: ?[]const u8 = null,

    pub fn deinit(self: Opts, alloc: Allocator) void {
        if (self.jsonPath) |jsonPath| alloc.free(jsonPath);
        if (self.only) |onlyFilter| alloc.free(onlyFilter);
    }
};

/// Per-scenario context. Scenarios open their own Database under `tmpDir`.
pub const Ctx = struct {
    alloc: Allocator,
    rowCount: usize,
    tmpDir: []const u8,
};

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub const Result = struct {
    name: []const u8,
    ops: u64,
    wallNs: u64,
    p50Ns: u64 = 0,
    p99Ns: u64 = 0,
    maxNs: u64 = 0,
    fileBytes: u64 = 0,
    logicalBytes: u64 = 0,
    peakRssBytes: u64 = 0,
    note: []const u8 = "",

    /// Operations per second over the wall-clock window. Returns 0 when no time
    /// elapsed (avoids divide-by-zero).
    pub fn throughputPerSec(self: Result) f64 {
        if (self.wallNs == 0) return 0;
        const opsF: f64 = @floatFromInt(self.ops);
        const wallF: f64 = @floatFromInt(self.wallNs);
        return opsF * 1e9 / wallF;
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
    pub fn percentile(self: *Latencies, percentileRank: u64) u64 {
        const items = self.samples.items;
        if (items.len == 0) return 0;
        std.mem.sort(u64, items, {}, std.sort.asc(u64));
        const rank = (items.len - 1) * percentileRank / 100;
        return items[rank];
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
/// recorded no per-op samples (p99Ns == 0).
pub fn printTable(results: []const Result, writer: anytype) !void {
    try writer.print(
        "{s:<24} {s:>12} {s:>14} {s:>10} {s:>10} {s:>10} {s:>11} {s:>11} {s:>11}\n",
        .{ "name", "ops", "ops/s", "p50 us", "p99 us", "max us", "file MiB", "logical MiB", "rss MiB" },
    );
    for (results) |result| {
        if (result.p99Ns == 0) {
            try writer.print(
                "{s:<24} {d:12} {d:14.0} {s:>10} {s:>10} {s:>10} {d:11.1} {d:11.1} {d:11.1}\n",
                .{
                    result.name,                     result.ops,
                    result.throughputPerSec(),       "-",
                    "-",                             "-",
                    bytesToMib(result.fileBytes),    bytesToMib(result.logicalBytes),
                    bytesToMib(result.peakRssBytes),
                },
            );
        } else {
            try writer.print(
                "{s:<24} {d:12} {d:14.0} {d:10.1} {d:10.1} {d:10.1} {d:11.1} {d:11.1} {d:11.1}\n",
                .{
                    result.name,                     result.ops,
                    result.throughputPerSec(),       nsToUs(result.p50Ns),
                    nsToUs(result.p99Ns),            nsToUs(result.maxNs),
                    bytesToMib(result.fileBytes),    bytesToMib(result.logicalBytes),
                    bytesToMib(result.peakRssBytes),
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

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);
    for (results) |result| {
        const rec = Record{
            .scenario = result.name,
            .scale = scaleStr(scale),
            .ops = result.ops,
            .ops_per_sec = result.throughputPerSec(),
            .p50_us = nsToUs(result.p50Ns),
            .p99_us = nsToUs(result.p99Ns),
            .max_us = nsToUs(result.maxNs),
            .file_mib = bytesToMib(result.fileBytes),
            .logical_mib = bytesToMib(result.logicalBytes),
            .rss_mib = bytesToMib(result.peakRssBytes),
            .note = result.note,
        };
        const line = try std.fmt.allocPrint(alloc, "{f}\n", .{std.json.fmt(rec, .{})});
        defer alloc.free(line);
        try buffer.appendSlice(alloc, line);
    }

    if (buffer.items.len > 0) try file.writePositionalAll(io, buffer.items, start);
}

// ---------------------------------------------------------------------------
// Scratch-file helpers
// ---------------------------------------------------------------------------

/// Joins `ctx.tmpDir` and `name` into an absolute path. Caller frees.
pub fn scratchPath(ctx: Ctx, name: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.alloc, &.{ ctx.tmpDir, name });
}

/// Deletes a scratch file, ignoring any error (best-effort cleanup).
pub fn removeScratch(ctx: Ctx, path: []const u8) void {
    _ = ctx;
    Io.Dir.cwd().deleteFile(sysIo(), path) catch {};
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const defaultJsonPath = "bench-results.json";

fn usage() void {
    std.debug.print(
        \\usage: airdb-bench [options]
        \\  --scale=1m|10m   row count to drive scenarios (default 1m)
        \\  --json[=PATH]    append results as JSON (default {s})
        \\  --only=NAME      run only the named scenario
        \\
    , .{defaultJsonPath});
}

/// Parses argv (slice from `init.minimal.args.toSlice`) into `Opts`. Retained
/// strings are duped into `alloc`; free with `Opts.deinit`. Unknown flags or an
/// invalid --scale value print usage to stderr and return an error.
pub fn parseArgs(alloc: Allocator, args: []const [:0]const u8) !Opts {
    var opts: Opts = .{};
    errdefer opts.deinit(alloc);

    var index: usize = 1; // skip the program name
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.startsWith(u8, arg, "--scale=")) {
            const version = arg["--scale=".len..];
            if (std.mem.eql(u8, version, "1m")) {
                opts.scale = .m1;
            } else if (std.mem.eql(u8, version, "10m")) {
                opts.scale = .m10;
            } else {
                usage();
                return error.InvalidScale;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            try setJsonPath(&opts, alloc, defaultJsonPath);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            try setJsonPath(&opts, alloc, arg["--json=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--only=")) {
            if (opts.only) |onlyFilter| alloc.free(onlyFilter);
            opts.only = try alloc.dupe(u8, arg["--only=".len..]);
        } else {
            usage();
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn setJsonPath(opts: *Opts, alloc: Allocator, path: []const u8) !void {
    if (opts.jsonPath) |jsonPath| alloc.free(jsonPath);
    opts.jsonPath = try alloc.dupe(u8, path);
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
    const count: usize = if (opts.scale == .m1) 1_000_000 else 10_000_000;

    const io = sysIo();
    const scratch = scratchDir();
    // Start from a clean slate, then guarantee removal on the way out.
    Io.Dir.cwd().deleteTree(io, scratch) catch {};
    try Io.Dir.cwd().createDirPath(io, scratch);
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};

    // scenarios registered here as they land
    const insertRecovery = @import("scenarios/insertRecovery.zig");
    const lookupQuery = @import("scenarios/lookupQuery.zig");
    const churnCompaction = @import("scenarios/churnCompaction.zig");
    const blobsPitr = @import("scenarios/blobsPitr.zig");
    const typesCrud = @import("scenarios/typesCrud.zig");
    const embeddedCrud = @import("scenarios/embeddedCrud.zig");
    const nestedEmbedded = @import("scenarios/nestedEmbedded.zig");
    const bulkImport = @import("scenarios/bulkImport.zig");
    const bulkAppend = @import("scenarios/bulkAppend.zig");
    const scenarios = [_]Scenario{
        .{ .name = insertRecovery.name, .run = insertRecovery.run },
        .{ .name = lookupQuery.name, .run = lookupQuery.run },
        .{ .name = churnCompaction.name, .run = churnCompaction.run },
        .{ .name = blobsPitr.name, .run = blobsPitr.run },
        .{ .name = typesCrud.name, .run = typesCrud.run },
        .{ .name = embeddedCrud.name, .run = embeddedCrud.run },
        .{ .name = nestedEmbedded.name, .run = nestedEmbedded.run },
        .{ .name = bulkImport.name, .run = bulkImport.run },
        .{ .name = bulkAppend.name, .run = bulkAppend.run },
    };

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(alloc);

    for (scenarios) |scenario| {
        if (opts.only) |only| {
            if (!std.mem.eql(u8, only, scenario.name)) continue;
        }
        var ctx = Ctx{ .alloc = alloc, .rowCount = count, .tmpDir = scratch };
        try results.append(alloc, try scenario.run(&ctx));
    }

    var buffer: [4096]u8 = undefined;
    var fileWriter: Io.File.Writer = .init(.stdout(), io, &buffer);
    const writeTransaction = &fileWriter.interface;
    try printTable(results.items, writeTransaction);
    try writeTransaction.flush();

    if (opts.jsonPath) |jsonPath| {
        try appendJson(jsonPath, opts.scale, results.items, alloc);
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

    var version: u64 = 1;
    while (version <= 100) : (version += 1) try lat.add(alloc, version);

    try std.testing.expectEqual(@as(u64, 50), lat.percentile(50));
    try std.testing.expectEqual(@as(u64, 100), lat.percentile(100));
    try std.testing.expectEqual(@as(u64, 1), lat.percentile(0));
}

test "Latencies percentiles on an empty set are zero" {
    const alloc = std.testing.allocator;
    var lat = Latencies.init();
    defer lat.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 0), lat.percentile(50));
}

test "Result throughput math" {
    const result = Result{ .name = "x", .ops = 1000, .wallNs = 1_000_000_000 };
    try std.testing.expectEqual(@as(f64, 1000), result.throughputPerSec());
}

test "Result throughput guards zero wall time" {
    const result = Result{ .name = "x", .ops = 1000, .wallNs = 0 };
    try std.testing.expectEqual(@as(f64, 0), result.throughputPerSec());
}
