// types_crud -- CRUD latency across a row that exercises every property kind the
// engine supports, not just plain ints. One type is built with a property of
// each kind, then the four CRUD phases (create / read / update / delete) are run
// over a capped dataset and their per-op latencies folded into a single mix.
//
// Property layout (single catalog, type id 0 so the link can be a self-link):
//   0  int   primary key
//   1  int   a plain int value
//   2  int   a bool stored as 0/1 (the engine has no distinct bool kind, so a
//            bool is an int holding 0 or 1; recorded as "bool" in the note)
//   3  blob  a 32-byte inline string
//   4  link  self-link (linkTarget = 0) to another row's object key, or null
//   5  dict  a few string -> int entries
//   6  set   a few ints (element = int)
//   7  set   a few byte members (element = blob): the set-of-blob kind
//
// Kinds exercised: int, bool (as int), blob, link, dict, set, setBlob.
// Omitted by design: list and linkSet. The task's kind list does not include
// them, and every other supported kind is covered above, so nothing is faked.
//
// Update phase note: Objects.updateTyped is `unreachable` for collection-bearing
// properties, so a full-row typed update cannot run on this multi-kind type. The
// update phase instead mutates through the per-property collection mutators and
// the link setter (setAddInt + dictPut + setLink), which are the engine's real
// update path for those kinds and each bump the row version.

const std = @import("std");
const airdb = @import("airdb");
const harness = @import("../harness.zig");

const Io = std.Io;
const Reference = airdb.Reference;
const catalog = airdb.catalog;
const objects = airdb.objects;
const rawRows = airdb.rows;
const collections = airdb.collections;
const links = airdb.links;
const Value = catalog.Value;

pub const name = "types_crud";

// Rows committed per write transaction across the create/update/delete phases.
const batchSize: usize = 5_000;

// Wide typed rows are far heavier than plain ints, so cap the dataset to keep a
// 1m-scale run well under a minute.
const maxRows: usize = 200_000;

// Per-phase sample ceilings for the read/update/delete phases.
const maxSamples: usize = 50_000;

// Property indices.
const pInt = 1;
const pBool = 2;
const pBlob = 3;
const pLink = 4;
const pDict = 5;
const pSetInt = 6;
const pSetBlob = 7;
const propertyCount = 8;

inline fn sysIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs(io: Io) i96 {
    return Io.Clock.now(.awake, io).nanoseconds;
}

// Deterministic 64-bit pseudo-random stream (xorshift64*), no clock/global state.
fn xorshift(state: *u64) u64 {
    var value = state.*;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    state.* = value;
    return value *% 0x2545F4914F6CDD1D;
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

    // One type carrying a property of each exercised kind.
    {
        var writeTransaction = try database.beginWrite();
        const catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{
            .{ .kind = .int }, // 0 primaryKey
            .{ .kind = .int }, // 1 int
            .{ .kind = .int }, // 2 bool (0/1)
            .{ .kind = .blob }, // 3 string
            .{ .kind = .link, .linkTarget = 0 }, // 4 self-link
            .{ .kind = .dict }, // 5 dict
            .{ .kind = .set, .element = .int }, // 6 set of int
            .{ .kind = .set, .element = .blob }, // 7 set of blob
        });
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
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

    // --- CREATE phase --------------------------------------------------------
    {
        const phaseStart = nowNs(io);
        var inserted: usize = 0;
        while (inserted < rows) {
            const thisBatch = @min(batchSize, rows - inserted);
            var writeTransaction = try database.beginWrite();
            var catalogRef = writeTransaction.newRoot;
            var innerIndex: usize = 0;
            while (innerIndex < thisBatch) : (innerIndex += 1) {
                const primaryKey: u64 = inserted + innerIndex;
                // objectKeys are assigned 0,1,2,... so objectKey == primaryKey for a fresh insert.
                var rng: u64 = primaryKey +% 0x9E3779B97F4A7C15;
                const randomValue = xorshift(&rng);

                var blobBuffer: [32]u8 = undefined;
                for (&blobBuffer, 0..) |*byte, byteK| byte.* = @truncate(randomValue +% byteK);

                const dictEntries = [_]catalog.DictEntry{
                    .{ .key = "alpha", .value = randomValue & 0xffff },
                    .{ .key = "beta", .value = (randomValue >> 16) & 0xffff },
                    .{ .key = "gamma", .value = (randomValue >> 32) & 0xffff },
                };
                const setInts = [_]u64{ randomValue % 1000, (randomValue >> 10) % 1000, (randomValue >> 20) % 1000 };
                const setBlobs = [_][]const u8{ "m0", "m1", "m2" };

                const row = [propertyCount]Value{
                    .{ .int = primaryKey },
                    .{ .int = randomValue },
                    .{ .int = primaryKey & 1 }, // bool
                    .{ .bytes = &blobBuffer },
                    .{ .link = if (primaryKey == 0) null else primaryKey - 1 }, // self-link to prior objectKey
                    .{ .dictInt = &dictEntries },
                    .{ .setInt = &setInts },
                    .{ .setBlob = &setBlobs },
                };

                const startNs = nowNs(io);
                const result = try objects.insertTyped(&writeTransaction, catalogRef, &row);
                const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
                catalogRef = result.catalogRef;
                try createLat.add(alloc, elapsedNs);
                try combined.add(alloc, elapsedNs);
            }
            writeTransaction.setRoot(catalogRef);
            _ = try writeTransaction.commit();
            inserted += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // Sampling stride: spread picks evenly across the live key space.
    const readN = @min(rows, maxSamples);
    const updateN = @min(rows, maxSamples);
    const deleteN = @min(rows, maxSamples);
    const readStride = @max(@as(usize, 1), rows / readN);
    const updateStride = @max(@as(usize, 1), rows / updateN);
    const deleteStride = @max(@as(usize, 1), rows / deleteN);

    // --- READ phase: materialize every property kind -----------------------------
    {
        const phaseStart = nowNs(io);
        var readTransaction = try database.beginRead();
        const catalogRef = readTransaction.root();
        var out: [propertyCount]Value = undefined;
        var key: usize = 0;
        while (key < readN) : (key += 1) {
            const primaryKey: u64 = (key * readStride) % rows;
            const startNs = nowNs(io);
            _ = try objects.getTyped(&readTransaction, catalogRef, primaryKey, &out); // int/bool/blob/link
            _ = try collections.dictCount(&readTransaction, catalogRef, primaryKey, pDict);
            _ = try collections.dictGet(&readTransaction, catalogRef, primaryKey, pDict, "alpha");
            _ = try collections.setCountInt(&readTransaction, catalogRef, primaryKey, pSetInt);
            _ = try collections.setCountBlob(&readTransaction, catalogRef, primaryKey, pSetBlob);
            _ = try collections.setContainsBlob(&readTransaction, catalogRef, primaryKey, pSetBlob, "m1");
            const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
            try readLat.add(alloc, elapsedNs);
            try combined.add(alloc, elapsedNs);
        }
        readTransaction.end();
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // --- UPDATE phase: mutate a set, a dict, and the link (version bumps) -----
    {
        const phaseStart = nowNs(io);
        var done: usize = 0;
        while (done < updateN) {
            const thisBatch = @min(batchSize, updateN - done);
            var writeTransaction = try database.beginWrite();
            var catalogRef = writeTransaction.newRoot;
            var innerIndex: usize = 0;
            while (innerIndex < thisBatch) : (innerIndex += 1) {
                const primaryKey: u64 = ((done + innerIndex) * updateStride) % rows;
                const target: u64 = (primaryKey + 7) % rows;
                const startNs = nowNs(io);
                catalogRef = try collections.setAddInt(&writeTransaction, catalogRef, primaryKey, pSetInt, 1_000_000 + primaryKey);
                catalogRef = try collections.dictPut(&writeTransaction, catalogRef, primaryKey, pDict, "delta", primaryKey);
                catalogRef = try links.setLink(&writeTransaction, catalogRef, primaryKey, pLink, target);
                const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
                try updateLat.add(alloc, elapsedNs);
                try combined.add(alloc, elapsedNs);
            }
            writeTransaction.setRoot(catalogRef);
            _ = try writeTransaction.commit();
            done += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    // --- DELETE phase ---------------------------------------------------------
    var deleted: u64 = 0;
    {
        const phaseStart = nowNs(io);
        var done: usize = 0;
        while (done < deleteN) {
            const thisBatch = @min(batchSize, deleteN - done);
            var writeTransaction = try database.beginWrite();
            var catalogRef = writeTransaction.newRoot;
            var raw: [propertyCount]u64 = undefined;
            var innerIndex: usize = 0;
            while (innerIndex < thisBatch) : (innerIndex += 1) {
                const primaryKey: u64 = ((done + innerIndex) * deleteStride) % rows;
                const version = (try rawRows.getByPrimaryKey(&writeTransaction, catalogRef, primaryKey, &raw)) orelse continue;
                const startNs = nowNs(io);
                const dres = try objects.deleteTyped(&writeTransaction, catalogRef, primaryKey, version);
                const elapsedNs: u64 = @intCast(nowNs(io) - startNs);
                switch (dres) {
                    .ok => |newCatalog| {
                        catalogRef = newCatalog;
                        deleted += 1;
                        try deleteLat.add(alloc, elapsedNs);
                        try combined.add(alloc, elapsedNs);
                    },
                    else => {},
                }
            }
            writeTransaction.setRoot(catalogRef);
            _ = try writeTransaction.commit();
            done += thisBatch;
        }
        totalNs += @intCast(nowNs(io) - phaseStart);
    }

    const fileBytes = try database.fileSize();
    const logicalBytes = database.logicalSize();

    const ops: u64 = @as(u64, rows) + readN + updateN + deleted;

    const note = try std.fmt.allocPrint(
        alloc,
        "create_p50_us={d:.1} read_p50_us={d:.1} update_p50_us={d:.1} delete_p50_us={d:.1} rows={d} kinds=int,bool,blob,link,dict,set,set_blob",
        .{
            @as(f64, @floatFromInt(createLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(readLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(updateLat.percentile(50))) / 1000.0,
            @as(f64, @floatFromInt(deleteLat.percentile(50))) / 1000.0,
            rows,
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
