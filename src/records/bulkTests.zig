const std = @import("std");
const verification = @import("../verification.zig");
const bulk = @import("bulk.zig");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const cnode = @import("../trees/columnNode.zig");
const inode = @import("../trees/indexNode.zig");
const catalog = @import("../schema/catalog.zig");
const objects = @import("objects.zig");
const rawRows = @import("rows.zig");
const ValueObjectKeys = bulk.ValueObjectKeys;
const bulkColumn = bulk.bulkColumn;
const bulkIndex = bulk.bulkIndex;
const bulkValueIndex = bulk.bulkValueIndex;
const bulkImport = bulk.bulkImport;
const bulkAppend = bulk.bulkAppend;
const bulkAppendOrInsert = bulk.bulkAppendOrInsert;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const query = @import("../query.zig");

const typeDirectory = @import("../schema/typeDirectory.zig");

fn bulkTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "bulk append is refused when the batch does not clear the true max primaryKey" {
    // Regression: deleting the upper primaryKey range empties the primaryKey index's rightmost
    // leaf. A maxKey that followed only the rightmost path then reported the
    // type EMPTY, so bulkAppend admitted a batch below the surviving keys --
    // duplicate primaryKeys and broken leaf ordering. The batch must be NotAppendable
    // (and the fallback must handle it correctly instead).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_maxpk.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try catalog.create(&writeTransaction, 2);
    var primaryKey: u64 = 0;
    while (primaryKey <= 64) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey })).catalogReference; // primaryKey index splits
    var out: [2]u64 = undefined;
    primaryKey = 32;
    while (primaryKey <= 64) : (primaryKey += 1) {
        const version = (try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, primaryKey, &out)).?;
        catalogReference = (try rawRows.delete(&writeTransaction, catalogReference, primaryKey, version)).ok;
    }
    // primaryKeys 0..31 survive; a batch starting at 10 must NOT take the fast path.
    const rows = [_][]const u64{ &.{ 10, 1 }, &.{ 11, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &rows));
    // The orchestrator falls back to row-by-row, which detects the duplicate.
    try testing.expectError(error.DuplicateKey, bulkAppendOrInsert(&writeTransaction, catalogReference, &rows));
    // A batch that truly clears the surviving max qualifies.
    const okRows = [_][]const u64{ &.{ 100, 1 }, &.{ 101, 2 } };
    catalogReference = try bulkAppend(&writeTransaction, catalogReference, &okRows);
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 100, &out)) != null);
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 31, &out)) != null);
}

test "bulk append into a primaryKey-history gap takes the fallback" {
    // Regression: with primaryKeys 0..31 and 40..104 inserted then 40..104 deleted,
    // the rightmost primaryKey-index leaves are EMPTY but keep recorded lows (40, 72).
    // A batch of {33, 34} clears the surviving max (31) but sits BELOW the
    // stale low; the old fast path rebuilt the low-72 leaf with low 33 and the
    // appended rows became unreachable. Such a batch must fall back; a batch
    // clearing the stale low may still take the fast path.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_gap.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try catalog.create(&writeTransaction, 2);
    var primaryKey: u64 = 0;
    while (primaryKey <= 31) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey })).catalogReference;
    primaryKey = 40;
    while (primaryKey <= 104) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey })).catalogReference;
    var out: [2]u64 = undefined;
    primaryKey = 40;
    while (primaryKey <= 104) : (primaryKey += 1) {
        const version = (try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, primaryKey, &out)).?;
        catalogReference = (try rawRows.delete(&writeTransaction, catalogReference, primaryKey, version)).ok;
    }

    // Below the stale low: NotAppendable; the orchestrator's fallback must
    // leave every row reachable.
    const gapRows = [_][]const u64{ &.{ 33, 1 }, &.{ 34, 2 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &gapRows));
    catalogReference = try bulkAppendOrInsert(&writeTransaction, catalogReference, &gapRows);
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 33, &out)) != null);
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 34, &out)) != null);

    // Every surviving primaryKey still resolves (routing lows intact).
    primaryKey = 0;
    while (primaryKey <= 31) : (primaryKey += 1) try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, primaryKey, &out)) != null);
}

test "bulk append fallback refuses link-bearing schemas" {
    // objects.insert writes raw columns without backlink maintenance, so the
    // row-by-row fallback must reject link/linkSet types like bulkImport does
    // instead of silently corrupting the graph.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_links.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const rows = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkAppendOrInsert(&writeTransaction, catalogReference, &rows));
}

test "bulk append frees the replaced right-edge nodes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkappend_free.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a populated type so the old right edge is committed nodes.
    {
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.create(&writeTransaction, 2);
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey })).catalogReference;
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }

    // A qualifying append must record the replaced committed spine as
    // in-flight frees (deferred, MVCC-safe reclaim) instead of leaking it.
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const rows = [_][]const u64{ &.{ 1000, 1 }, &.{ 1001, 2 } };
    _ = try bulkAppend(&writeTransaction, writeTransaction.newRoot, &rows);
    try testing.expect(writeTransaction.inFlightFrees.items.len > 0);
}

fn checkColumnSize(writeTransaction: *WriteTransaction, valueCount: usize) !void {
    const values = try testing.allocator.alloc(u64, valueCount);
    defer testing.allocator.free(values);
    for (values, 0..) |*value, position| value.* = @as(u64, position) * 7;

    const built = try bulkColumn(writeTransaction, values);

    var seq = try Column.create(writeTransaction);
    for (values) |value| seq = try Column.append(writeTransaction, seq, value);

    try testing.expectEqual(try Column.length(writeTransaction, seq), try Column.length(writeTransaction, built));
    try testing.expectEqual(@as(u64, valueCount), try Column.length(writeTransaction, built));
    var index: u64 = 0;
    while (index < valueCount) : (index += 1) {
        try testing.expectEqual(try Column.get(writeTransaction, seq, index), try Column.get(writeTransaction, built, index));
    }
}

test "bulkColumn equals sequential appends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcol.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkColumnSize(&writeTransaction, 1000);
    writeTransaction.deinit();
}

test "bulkColumn boundary sizes: 0, 1, leafCap, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcolsizes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkColumnSize(&writeTransaction, 0);
    try checkColumnSize(&writeTransaction, 1);
    try checkColumnSize(&writeTransaction, cnode.leafCap); // single full leaf
    try checkColumnSize(&writeTransaction, @as(usize, cnode.leafCap) * cnode.fanout + 1); // 3 levels
    writeTransaction.deinit();
}

const IdxCollector = struct {
    keys: *std.ArrayList(u64),
    vals: *std.ArrayList(u64),
    fn onEntry(self: @This(), key: u64, val: u64) !void {
        try self.keys.append(testing.allocator, key);
        try self.vals.append(testing.allocator, val);
    }
};

fn checkIndexSize(writeTransaction: *WriteTransaction, entryCount: usize) !void {
    const keys = try testing.allocator.alloc(u64, entryCount);
    defer testing.allocator.free(keys);
    const vals = try testing.allocator.alloc(u64, entryCount);
    defer testing.allocator.free(vals);
    for (keys, vals, 0..) |*key, *value, keyI| {
        key.* = @intCast(keyI);
        value.* = @as(u64, keyI) * 10;
    }

    const built = try bulkIndex(writeTransaction, keys, vals);

    var seq = try Index.create(writeTransaction);
    for (keys, vals) |key, value| seq = try Index.insert(writeTransaction, seq, key, value);

    try testing.expectEqual(@as(u64, entryCount), try Index.count(writeTransaction, built));
    try testing.expectEqual(try Index.count(writeTransaction, seq), try Index.count(writeTransaction, built));

    var index: u64 = 0;
    while (index < entryCount) : (index += 1) {
        try testing.expectEqual(try Index.get(writeTransaction, seq, index), try Index.get(writeTransaction, built, index));
    }

    var collectedKeys = std.ArrayList(u64).empty;
    defer collectedKeys.deinit(testing.allocator);
    var collectedValues = std.ArrayList(u64).empty;
    defer collectedValues.deinit(testing.allocator);
    try Index.forEachEntry(writeTransaction, built, IdxCollector{ .keys = &collectedKeys, .vals = &collectedValues }, IdxCollector.onEntry);
    try testing.expectEqual(entryCount, collectedKeys.items.len);
    for (collectedKeys.items, collectedValues.items, 0..) |item, itemV, itemJ| {
        try testing.expectEqual(@as(u64, itemJ), item);
        try testing.expectEqual(@as(u64, itemJ) * 10, itemV);
    }
}

test "bulkIndex equals sequential inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidx.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkIndexSize(&writeTransaction, 1000);
    writeTransaction.deinit();
}

test "bulkIndex boundary sizes: 0, 1, leafCap, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidxsizes.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    try checkIndexSize(&writeTransaction, 0);
    try checkIndexSize(&writeTransaction, 1);
    try checkIndexSize(&writeTransaction, inode.leafCap);
    try checkIndexSize(&writeTransaction, @as(usize, inode.leafCap) * inode.fanout + 1);
    writeTransaction.deinit();
}

const SetCollector = struct {
    keys: *std.ArrayList(u64),
    fn onKey(self: @This(), key: u64) !void {
        try self.keys.append(testing.allocator, key);
    }
};

fn collectSet(writeTransaction: *WriteTransaction, setRoot: Reference, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    try Index.forEachKey(writeTransaction, setRoot, SetCollector{ .keys = out }, SetCollector.onKey);
}

test "bulkValueIndex equals sequential maintenance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkvi.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    const N: u64 = 1000;
    const numValues: u64 = 100;

    // Build the grouped entries: value v=i%100 maps to objectKeys {i : i%100==v}, ascending.
    var entries = std.ArrayList(ValueObjectKeys).empty;
    defer {
        for (entries.items) |entry| testing.allocator.free(entry.objectKeys);
        entries.deinit(testing.allocator);
    }
    var version: u64 = 0;
    while (version < numValues) : (version += 1) {
        var objectKeys = std.ArrayList(u64).empty;
        var index: u64 = version; // first objectKey with i%100==v
        while (index < N) : (index += numValues) try objectKeys.append(testing.allocator, index);
        try entries.append(testing.allocator, .{ .value = version, .objectKeys = try objectKeys.toOwnedSlice(testing.allocator) });
    }

    const built = try bulkValueIndex(&writeTransaction, entries.items);

    // Sequential maintenance mirror: for each (value, objectKey) add objectKey to the inner
    // set for value, exactly as rows.valueIndexAdd does.
    var seq = try Index.create(&writeTransaction);
    var index: u64 = 0;
    while (index < N) : (index += 1) {
        const value = index % numValues;
        const existing = try Index.get(&writeTransaction, seq, value);
        var setRoot = existing orelse try Index.create(&writeTransaction);
        setRoot = try Index.insert(&writeTransaction, setRoot, index, 1);
        seq = try Index.insert(&writeTransaction, seq, value, setRoot);
    }

    // Compare the inner objectKey set for every value.
    var builtSet = std.ArrayList(u64).empty;
    defer builtSet.deinit(testing.allocator);
    var seqSet = std.ArrayList(u64).empty;
    defer seqSet.deinit(testing.allocator);

    version = 0;
    while (version < numValues) : (version += 1) {
        const bInner = (try Index.get(&writeTransaction, built, version)) orelse return error.MissingValue;
        const sInner = (try Index.get(&writeTransaction, seq, version)) orelse return error.MissingValue;
        try collectSet(&writeTransaction, bInner, &builtSet);
        try collectSet(&writeTransaction, sInner, &seqSet);
        try testing.expectEqualSlices(u64, seqSet.items, builtSet.items);
    }
    writeTransaction.deinit();
}

// Schema shared by the orchestrator tests: int primaryKey, int value, int category (indexed).
const importDefinitions = [_]catalog.PropertyDefinition{
    .{ .kind = .int },
    .{ .kind = .int },
    .{ .kind = .int, .indexed = true },
};

test "bulkImport equals row-by-row for a scalar indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pathA = try bulkTmpPath(testing.allocator, &tmp, "import_a.airdb");
    defer testing.allocator.free(pathA);
    const pathB = try bulkTmpPath(testing.allocator, &tmp, "import_b.airdb");
    defer testing.allocator.free(pathB);

    const N: u64 = 5000;

    // Shuffled input order for the bulk import: primaryKeys arrive out of order, so the
    // import must sort them and reproduce the same objectKey-per-primaryKey mapping the
    // in-order row-by-row twin produces.
    const order = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(order);
    for (order, 0..) |*slot, index| slot.* = @intCast(index);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE12345678);
    prng.random().shuffle(u64, order);

    const storage = try testing.allocator.alloc([3]u64, N);
    defer testing.allocator.free(storage);
    const rowSlices = try testing.allocator.alloc([]const u64, N);
    defer testing.allocator.free(rowSlices);
    for (order, 0..) |primaryKey, key| {
        storage[key] = .{ primaryKey, primaryKey * 3, primaryKey % 50 };
        rowSlices[key] = &storage[key];
    }

    // database A: bulk import inside a one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, pathA);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&importDefinitions}, &.{false});
        const catalog0 = try typeDirectory.catalogReference(&writeTransaction, directoryReference, 0);
        const newCatalog = try bulkImport(&writeTransaction, catalog0, rowSlices, .{});
        const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, 0, newCatalog);
        writeTransaction.setRoot(newDirectoryReference);
        _ = try writeTransaction.commit();
        try verification.verifyIntegrity(&database); // both value-index directions, in memory
    }

    // database B: the same rows inserted one at a time, in ascending-primaryKey order.
    {
        var database = try Database.create(testing.allocator, pathB);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &importDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < N) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3, primaryKey % 50 })).catalogReference;
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var database = try Database.open(testing.allocator, pathA);
    defer database.deinit();
    try verification.verifyIntegrity(&database); // audit again after reopen
    var databaseB = try Database.open(testing.allocator, pathB);
    defer databaseB.deinit();

    var readTransactionA = try database.beginRead();
    defer readTransactionA.end();
    var readTransactionB = try databaseB.beginRead();
    defer readTransactionB.end();

    const catalogA = try typeDirectory.catalogReference(&readTransactionA, readTransactionA.root(), 0);
    const catalogB = readTransactionB.root();

    // Counts equal.
    try testing.expectEqual(N, try catalog.liveCount(&readTransactionA, catalogA));
    try testing.expectEqual(try catalog.liveCount(&readTransactionB, catalogB), try catalog.liveCount(&readTransactionA, catalogA));

    // Every primaryKey lookup equal: property values AND row version.
    var primaryKey: u64 = 0;
    while (primaryKey < N) : (primaryKey += 1) {
        var valuesA: [3]u64 = undefined;
        var valuesB: [3]u64 = undefined;
        const version = try rawRows.getByPrimaryKey(&readTransactionA, catalogA, primaryKey, &valuesA);
        const version2 = try rawRows.getByPrimaryKey(&readTransactionB, catalogB, primaryKey, &valuesB);
        try testing.expectEqual(version2, version);
        try testing.expectEqualSlices(u64, &valuesB, &valuesA);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var setA = std.ArrayList(u64).empty;
        defer setA.deinit(testing.allocator);
        var setB = std.ArrayList(u64).empty;
        defer setB.deinit(testing.allocator);
        try query.where(&readTransactionA, catalogA, .{ .predicate = .{ .conjunction = &.{} } }, &setA, testing.allocator);
        try query.where(&readTransactionB, catalogB, .{ .predicate = .{ .conjunction = &.{} } }, &setB, testing.allocator);
        try testing.expectEqualSlices(u64, setB.items, setA.items);
    }

    // Indexed query: category == 7, equal sorted objectKey sets.
    {
        var setA = std.ArrayList(u64).empty;
        defer setA.deinit(testing.allocator);
        var setB = std.ArrayList(u64).empty;
        defer setB.deinit(testing.allocator);
        try query.where(&readTransactionA, catalogA, .{ .predicate = .{ .comparison = .{ .property = 2, .operator = .eq, .value = .{ .int = 7 } } } }, &setA, testing.allocator);
        try query.where(&readTransactionB, catalogB, .{ .predicate = .{ .comparison = .{ .property = 2, .operator = .eq, .value = .{ .int = 7 } } } }, &setB, testing.allocator);
        std.mem.sort(u64, setA.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, setB.items, {}, std.sort.asc(u64));
        try testing.expectEqualSlices(u64, setB.items, setA.items);
        try testing.expectEqual(@as(usize, 100), setA.items.len); // primaryKey%50==7 over 0..5000
    }
}

test "bulkImport rejects a non-empty type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_nonempty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &importDefinitions);
    catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ 1, 3, 1 })).catalogReference;

    const more = [_][]const u64{ &.{ 10, 30, 5 }, &.{ 11, 33, 6 } };
    try testing.expectError(error.TypeNotEmpty, bulkImport(&writeTransaction, catalogReference, &more, .{}));

    // The type is unchanged: still one live row, intact.
    try testing.expectEqual(@as(u64, 1), try catalog.liveCount(&writeTransaction, catalogReference));
    var out: [3]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 3), out[1]);
    try testing.expectEqual(@as(u64, 1), out[2]);
    writeTransaction.deinit();
}

test "bulkImport rejects duplicate primaryKey before committing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_dup.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &importDefinitions);

    const dup = [_][]const u64{ &.{ 5, 1, 0 }, &.{ 6, 2, 0 }, &.{ 5, 3, 0 } };
    try testing.expectError(error.DuplicateKey, bulkImport(&writeTransaction, catalogReference, &dup, .{}));

    // Nothing was written: the type is still empty.
    try testing.expectEqual(@as(u64, 0), try catalog.liveCount(&writeTransaction, catalogReference));
    const view = try catalog.loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(@as(u64, 0), view.nextRow);
    try testing.expectEqual(@as(u64, 0), view.nextKey);
    writeTransaction.deinit();
}

test "bulkImport rejects a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const linkDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } };
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &linkDefinitions);

    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&writeTransaction, catalogReference, &rws, .{}));
    writeTransaction.deinit();
}

test "bulkImport rejects a type with an indexed blob property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_blob_indexed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } };
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);

    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&writeTransaction, catalogReference, &rws, .{}));
}

test "bulkImport on a type with an indexed blob property writes nothing: arena unchanged, the type stays empty and usable" {
    // Three assertions rather than one, because assertion 1 alone would be a
    // before-and-after self-comparison: it fails specifically when the
    // rejection is moved after freePreallocatedTrees, which is what
    // assertions 2 and 3 catch.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_blob_indexed_nothing.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } };
    const directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&definitions}, &.{false});
    const catalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, 0);

    const topBefore = database.arena.top;
    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&writeTransaction, catalogReference, &rws, .{}));

    // 1. The bump pointer did not move.
    try testing.expectEqual(topBefore, database.arena.top);

    // 2. The type's nextRow is still 0 and every pre-allocated tree is still
    // readable, which is what freePreallocatedTrees would have destroyed.
    const view = try catalog.loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(@as(u64, 0), view.nextRow);
    try testing.expectEqual(@as(u64, 0), try Index.count(&writeTransaction, view.valueIndexReference(1)));
    try testing.expectEqual(@as(u64, 0), try Column.length(&writeTransaction, view.propertyColumnReference(0)));

    // 3. A subsequent ordinary insert into the same type succeeds and
    // verifyIntegrity passes after commit.
    const inserted = try objects.insertTyped(&writeTransaction, catalogReference, &.{ .{ .int = 1 }, .{ .bytes = "hello" } });
    const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, 0, inserted.catalogReference);
    writeTransaction.setRoot(newDirectoryReference);
    _ = try writeTransaction.commit();
    try verification.verifyIntegrity(&database);
}

test "bulkImport on a type with an UNINDEXED blob property still succeeds" {
    // False-positive guard: without checking `indexed`, a rejection that
    // fired on every blob property would pass this test's absence check too.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_blob_unindexed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .blob } };
    const catalogReference = try catalog.createFromDefinitions(&writeTransaction, &definitions);

    const rws = [_][]const u64{ &.{ 1, 0 }, &.{ 2, 0 } };
    const newCatalog = try bulkImport(&writeTransaction, catalogReference, &rws, .{});
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&writeTransaction, newCatalog));
}

test "bulkImport edge sizes: empty, single, leafCap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sizes = [_]u64{ 0, 1, @as(u64, cnode.leafCap) };
    for (sizes, 0..) |count, si| {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "edge_{d}.airdb", .{si});
        const path = try bulkTmpPath(testing.allocator, &tmp, name);
        defer testing.allocator.free(path);

        const storage = try testing.allocator.alloc([3]u64, count);
        defer testing.allocator.free(storage);
        const rowSlices = try testing.allocator.alloc([]const u64, count);
        defer testing.allocator.free(rowSlices);
        var index: u64 = 0;
        while (index < count) : (index += 1) {
            storage[index] = .{ index, index * 3, index % 7 };
            rowSlices[index] = &storage[index];
        }

        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        {
            var writeTransaction = try database.beginWrite();
            const directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&importDefinitions}, &.{false});
            const catalog0 = try typeDirectory.catalogReference(&writeTransaction, directoryReference, 0);
            const newCatalog = try bulkImport(&writeTransaction, catalog0, rowSlices, .{ .presorted = true });
            const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, 0, newCatalog);
            writeTransaction.setRoot(newDirectoryReference);
            _ = try writeTransaction.commit();
        }
        try verification.verifyIntegrity(&database);

        var readTransaction = try database.beginRead();
        defer readTransaction.end();
        const catalogReference = try typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
        try testing.expectEqual(count, try catalog.liveCount(&readTransaction, catalogReference));
        const view = try catalog.loadCatalog(&readTransaction, catalogReference);
        try testing.expectEqual(count, view.nextRow);
        try testing.expectEqual(count, view.nextKey);
        if (count > 0) {
            var out: [3]u64 = undefined;
            const last = count - 1;
            try testing.expect((try rawRows.getByPrimaryKey(&readTransaction, catalogReference, last, &out)) != null);
            try testing.expectEqual(last, out[0]);
            try testing.expectEqual(last * 3, out[1]);
            try testing.expectEqual(last % 7, out[2]);
        }
    }
}

// A no-index, no-link scalar schema: int primaryKey, int value. Qualifies for append.
const appendDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int } };

test "bulkAppend equals row-by-row for a contiguous monotonic batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pathA = try bulkTmpPath(testing.allocator, &tmp, "append_eq_a.airdb");
    defer testing.allocator.free(pathA);
    const pathB = try bulkTmpPath(testing.allocator, &tmp, "append_eq_b.airdb");
    defer testing.allocator.free(pathB);

    const BASE: u64 = 1000;
    const APPEND: u64 = 500;
    const TOTAL = BASE + APPEND;

    // Batch rows: primaryKeys BASE..TOTAL, value = primaryKey*3 (ascending, above the base max).
    const storage = try testing.allocator.alloc([2]u64, APPEND);
    defer testing.allocator.free(storage);
    const batch = try testing.allocator.alloc([]const u64, APPEND);
    defer testing.allocator.free(batch);
    {
        var innerIndex: usize = 0;
        while (innerIndex < APPEND) : (innerIndex += 1) {
            const primaryKey = BASE + @as(u64, @intCast(innerIndex));
            storage[innerIndex] = .{ primaryKey, primaryKey * 3 };
            batch[innerIndex] = &storage[innerIndex];
        }
    }

    // database A: base via row-by-row insert, then the batch via bulkAppend, inside a
    // one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, pathA);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&appendDefinitions}, &.{false});
        var catalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, 0);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3 })).catalogReference;
        const newCatalog = try bulkAppend(&writeTransaction, catalogReference, batch);
        const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, 0, newCatalog);
        writeTransaction.setRoot(newDirectoryReference);
        _ = try writeTransaction.commit();
        try verification.verifyIntegrity(&database);
    }

    // database B: every row inserted one at a time, in ascending-primaryKey order.
    {
        var database = try Database.create(testing.allocator, pathB);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &appendDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < TOTAL) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3 })).catalogReference;
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var database = try Database.open(testing.allocator, pathA);
    defer database.deinit();
    try verification.verifyIntegrity(&database); // audit again after reopen
    var databaseB = try Database.open(testing.allocator, pathB);
    defer databaseB.deinit();

    var readTransactionA = try database.beginRead();
    defer readTransactionA.end();
    var readTransactionB = try databaseB.beginRead();
    defer readTransactionB.end();

    const catalogA = try typeDirectory.catalogReference(&readTransactionA, readTransactionA.root(), 0);
    const catalogB = readTransactionB.root();

    // Counts equal.
    try testing.expectEqual(TOTAL, try catalog.liveCount(&readTransactionA, catalogA));
    try testing.expectEqual(try catalog.liveCount(&readTransactionB, catalogB), try catalog.liveCount(&readTransactionA, catalogA));

    // Every primaryKey lookup equal: property values AND row version.
    var primaryKey: u64 = 0;
    while (primaryKey < TOTAL) : (primaryKey += 1) {
        var valuesA: [2]u64 = undefined;
        var valuesB: [2]u64 = undefined;
        const version = try rawRows.getByPrimaryKey(&readTransactionA, catalogA, primaryKey, &valuesA);
        const version2 = try rawRows.getByPrimaryKey(&readTransactionB, catalogB, primaryKey, &valuesB);
        try testing.expectEqual(version2, version);
        try testing.expectEqualSlices(u64, &valuesB, &valuesA);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var setA = std.ArrayList(u64).empty;
        defer setA.deinit(testing.allocator);
        var setB = std.ArrayList(u64).empty;
        defer setB.deinit(testing.allocator);
        try query.where(&readTransactionA, catalogA, .{ .predicate = .{ .conjunction = &.{} } }, &setA, testing.allocator);
        try query.where(&readTransactionB, catalogB, .{ .predicate = .{ .conjunction = &.{} } }, &setB, testing.allocator);
        try testing.expectEqualSlices(u64, setB.items, setA.items);
    }
}

test "bulkAppend returns NotAppendable for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_scatter.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &appendDefinitions);
    var primaryKey: u64 = 0;
    while (primaryKey < 100) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3 })).catalogReference;

    const before = try catalog.liveCount(&writeTransaction, catalogReference);
    var beforeRow: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 50, &beforeRow)) != null);

    // First batch primaryKey (50) is <= the current max (99): not a right-edge append.
    const batch = [_][]const u64{ &.{ 50, 150 }, &.{ 200, 600 }, &.{ 201, 603 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &batch));

    // The type is byte-unchanged: same count, and the sampled row is intact.
    try testing.expectEqual(before, try catalog.liveCount(&writeTransaction, catalogReference));
    var afterRow: [2]u64 = undefined;
    try testing.expect((try rawRows.getByPrimaryKey(&writeTransaction, catalogReference, 50, &afterRow)) != null);
    try testing.expectEqualSlices(u64, &beforeRow, &afterRow);
    writeTransaction.deinit();
}

test "bulkAppend returns NotAppendable for an indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_indexed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ 1, 10 })).catalogReference;

    // Even an ascending batch above the max is rejected: a pure right-edge append
    // cannot maintain the value index.
    const batch = [_][]const u64{ &.{ 100, 5 }, &.{ 101, 6 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &batch));
    writeTransaction.deinit();
}

test "bulkAppend returns NotAppendable for a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } });
    catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ 1, 0 })).catalogReference;

    const batch = [_][]const u64{ &.{ 100, 0 }, &.{ 101, 0 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &batch));
    writeTransaction.deinit();
}

test "bulkAppend returns NotAppendable for a non-ascending or duplicate batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_nonasc.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &appendDefinitions);
    catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ 1, 3 })).catalogReference;

    // Non-ascending batch (both primaryKeys above the max, but out of order).
    const desc = [_][]const u64{ &.{ 200, 600 }, &.{ 150, 450 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &desc));

    // In-batch duplicate primaryKey.
    const dup = [_][]const u64{ &.{ 300, 900 }, &.{ 300, 901 } };
    try testing.expectError(error.NotAppendable, bulkAppend(&writeTransaction, catalogReference, &dup));
    writeTransaction.deinit();
}

test "bulkAppendOrInsert falls back and equals row-by-row for a scattered batch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pathA = try bulkTmpPath(testing.allocator, &tmp, "fallback_a.airdb");
    defer testing.allocator.free(pathA);
    const pathB = try bulkTmpPath(testing.allocator, &tmp, "fallback_b.airdb");
    defer testing.allocator.free(pathB);

    const BASE: u64 = 100;
    // Scattered batch: all primaryKeys new (>= BASE) and distinct, but out of order, so
    // bulkAppend rejects and the orchestrator falls back to row-by-row insert.
    const scatteredPrimaryKeys = [_]u64{ 200, 100, 300, 150, 400, 250 };
    const TOTAL = BASE + scatteredPrimaryKeys.len;

    var storage: [scatteredPrimaryKeys.len][2]u64 = undefined;
    var batch: [scatteredPrimaryKeys.len][]const u64 = undefined;
    for (scatteredPrimaryKeys, 0..) |primaryKey, innerIndex| {
        storage[innerIndex] = .{ primaryKey, primaryKey * 3 };
        batch[innerIndex] = &storage[innerIndex];
    }

    // database A: base via insert, then the scattered batch via bulkAppendOrInsert,
    // inside a one-type directory so verifyIntegrity audits it.
    {
        var database = try Database.create(testing.allocator, pathA);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&appendDefinitions}, &.{false});
        var catalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, 0);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3 })).catalogReference;
        const newCatalog = try bulkAppendOrInsert(&writeTransaction, catalogReference, &batch);
        const newDirectoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, 0, newCatalog);
        writeTransaction.setRoot(newDirectoryReference);
        _ = try writeTransaction.commit();
        try verification.verifyIntegrity(&database);
    }

    // database B: base via insert, then the same scattered rows inserted one at a time
    // in the SAME order the fallback uses.
    {
        var database = try Database.create(testing.allocator, pathB);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &appendDefinitions);
        var primaryKey: u64 = 0;
        while (primaryKey < BASE) : (primaryKey += 1) catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey * 3 })).catalogReference;
        for (scatteredPrimaryKeys) |scatteredPrimaryKey| catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ scatteredPrimaryKey, scatteredPrimaryKey * 3 })).catalogReference;
        writeTransaction.setRoot(catalogReference);
        _ = try writeTransaction.commit();
    }

    var database = try Database.open(testing.allocator, pathA);
    defer database.deinit();
    try verification.verifyIntegrity(&database);
    var databaseB = try Database.open(testing.allocator, pathB);
    defer databaseB.deinit();

    var readTransactionA = try database.beginRead();
    defer readTransactionA.end();
    var readTransactionB = try databaseB.beginRead();
    defer readTransactionB.end();

    const catalogA = try typeDirectory.catalogReference(&readTransactionA, readTransactionA.root(), 0);
    const catalogB = readTransactionB.root();

    try testing.expectEqual(@as(u64, TOTAL), try catalog.liveCount(&readTransactionA, catalogA));
    try testing.expectEqual(try catalog.liveCount(&readTransactionB, catalogB), try catalog.liveCount(&readTransactionA, catalogA));

    // Every primaryKey over the union (and the absent gaps between) resolves identically.
    var primaryKey: u64 = 0;
    while (primaryKey <= 401) : (primaryKey += 1) {
        var valuesA: [2]u64 = undefined;
        var valuesB: [2]u64 = undefined;
        const version = try rawRows.getByPrimaryKey(&readTransactionA, catalogA, primaryKey, &valuesA);
        const version2 = try rawRows.getByPrimaryKey(&readTransactionB, catalogB, primaryKey, &valuesB);
        try testing.expectEqual(version2, version);
        if (version2 != null) try testing.expectEqualSlices(u64, &valuesB, &valuesA);
    }

    // Full-scan order equal (ascending objectKey for both).
    {
        var setA = std.ArrayList(u64).empty;
        defer setA.deinit(testing.allocator);
        var setB = std.ArrayList(u64).empty;
        defer setB.deinit(testing.allocator);
        try query.where(&readTransactionA, catalogA, .{ .predicate = .{ .conjunction = &.{} } }, &setA, testing.allocator);
        try query.where(&readTransactionB, catalogB, .{ .predicate = .{ .conjunction = &.{} } }, &setB, testing.allocator);
        try testing.expectEqualSlices(u64, setB.items, setA.items);
    }
}

test "bulkAppendOrInsert empty batch is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "append_empty.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &appendDefinitions);
    catalogReference = (try rawRows.insert(&writeTransaction, catalogReference, &.{ 1, 3 })).catalogReference;

    const before = try catalog.liveCount(&writeTransaction, catalogReference);
    const after = try bulkAppendOrInsert(&writeTransaction, catalogReference, &.{});
    try testing.expectEqual(catalogReference, after); // same reference, untouched
    try testing.expectEqual(before, try catalog.liveCount(&writeTransaction, after));
    writeTransaction.deinit();
}
