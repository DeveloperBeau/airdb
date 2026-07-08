const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Database = @import("../database.zig").Database;
const Reference = @import("../storage/reference.zig").Reference;

const catalog = @import("../schema/catalog.zig");

const rows = @import("../records/rows.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const dirPath = pathBuffer[0..pathLen];
    return std.fs.path.join(allocator, &.{ dirPath, name });
}

// Churn a single-row int type across `n` commits: each iteration commits an insert
// then commits a delete, so every cycle frees committed nodes into the free pool.
// Returns the final logical size (arena high-water).
fn churnLogicalSize(path: []const u8, retain: u64, rounds: u64) !u64 {
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    database.setRetainVersions(retain);

    var catalogRef: Reference = blk: {
        var writeTransaction = try database.beginWrite();
        const valueC = try catalog.create(&writeTransaction, 1);
        writeTransaction.setRoot(valueC);
        _ = try writeTransaction.commit();
        break :blk valueC;
    };

    var index: u64 = 0;
    while (index < rounds) : (index += 1) {
        {
            var writeTransaction = try database.beginWrite();
            catalogRef = database.activeRoot; // reload the committed catalog ref
            const inserted = try rows.insert(&writeTransaction, catalogRef, &.{index});
            catalogRef = inserted.catalogRef;
            writeTransaction.setRoot(catalogRef);
            _ = try writeTransaction.commit();
        }
        {
            var writeTransaction = try database.beginWrite();
            catalogRef = database.activeRoot;
            var out: [1]u64 = undefined;
            const version = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, index, &out)).?;
            catalogRef = switch (try rows.delete(&writeTransaction, catalogRef, index, version)) {
                .ok => |newCatalog| newCatalog,
                else => unreachable,
            };
            writeTransaction.setRoot(catalogRef);
            _ = try writeTransaction.commit();
        }
    }
    return database.logicalSize();
}

test "steady-state batched inserts keep the free list bounded" {
    // Regression for the free-pool death spiral: every insert rewrites the
    // catalog node, and if those nodes are not freed (or if carving/coalescing
    // shreds the node-size classes), the committed free list grows by hundreds
    // of unusable extents per batch and commit cost explodes at scale. With
    // catalog recycling and exact-class reuse the list must stay tiny.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "steadystate.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const catalogRef = try catalog.create(&writeTransaction, 2);
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    const batches: usize = 10;
    const insertsPerBatch: usize = 500;
    var primaryKey: u64 = 0;
    var batch: usize = 0;
    while (batch < batches) : (batch += 1) {
        var writeTransaction = try database.beginWrite();
        var catalogRef = writeTransaction.newRoot;
        var index: usize = 0;
        while (index < insertsPerBatch) : (index += 1) {
            catalogRef = (try rows.insert(&writeTransaction, catalogRef, &.{ primaryKey, primaryKey })).catalogRef;
            primaryKey += 1;
        }
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    // The committed list legitimately tracks the copy-on-write working set (the
    // committed nodes the last batch touched), which grows with tree depth and
    // plateaus. The failure mode this guards against is unusable extents
    // accumulating at roughly one per insert PER BATCH (the fragmentation
    // death spiral): after `batches` rounds that lands near
    // insertsPerBatch * batches, while the healthy working set stays under
    // one batch's width. Deriving the bound from the loop constant keeps the
    // assertion honest if someone retunes the batch size.
    try testing.expect(database.freeListLengthForTest() < insertsPerBatch);
}

test "an abandoned transaction's bump allocations are rolled back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "abortspace.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a baseline so logical size is stable.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BASELINE");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    const sizeBefore = database.logicalSize();

    // Abort a transaction that bump-allocated a lot.
    {
        var writeTransaction = try database.beginWrite();
        var index: usize = 0;
        while (index < 200) : (index += 1) _ = try writeTransaction.alloc(4096);
        writeTransaction.deinit(); // abort
    }
    try testing.expectEqual(sizeBefore, database.logicalSize());

    // The next commit must not durably absorb the aborted region either.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AFTERAB_");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    // One 8-byte node plus the free-list node: logical size grows by well under
    // the ~800 KiB the aborted transaction touched.
    try testing.expect(database.logicalSize() - sizeBefore < 4096);
}

test "retention window withholds recently freed space from reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pathRetain0 = try tmpFilePath(testing.allocator, &tmp, "retain0.airdb");
    defer testing.allocator.free(pathRetain0);
    const pathRetainMax = try tmpFilePath(testing.allocator, &tmp, "retainmax.airdb");
    defer testing.allocator.free(pathRetainMax);

    const count: u64 = 200;
    const size0 = try churnLogicalSize(pathRetain0, 0, count); // reuse freed space
    const size1 = try churnLogicalSize(pathRetainMax, 1_000_000, count); // retain everything -> no reuse

    // Retaining all recently-freed space prevents reuse, so the arena must grow
    // strictly larger than the reuse-enabled run.
    try testing.expect(size1 > size0);
}

test "writableCopy allocates a new node, copies bytes, and records the old as freed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cow.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "ORIGINAL");
    const copy = try writeTransaction.writableCopy(allocation.ref, 8);
    try testing.expect(copy.ref != allocation.ref);
    try testing.expectEqualStrings("ORIGINAL", copy.bytes);
    // The old node was allocated within this same uncommitted transaction, so freeing it
    // routes to the transaction-private reuse pool (immediately reusable), not inFlightFrees.
    try testing.expectEqual(@as(usize, 0), writeTransaction.inFlightFrees.items.len);
    try testing.expectEqual(@as(usize, 1), writeTransaction.transactionReuse.extents.items.len);
    try testing.expectEqual(allocation.ref, writeTransaction.transactionReuse.extents.items[0].offset);
    writeTransaction.deinit(); // releases the transaction-private pools without committing
}

test "a node freed within a transaction is reused by the next allocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "txnreuse.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(64);
    try writeTransaction.free(allocation.ref, 64);
    const allocationB = try writeTransaction.alloc(64);
    // Reused the just-freed transaction-private node; no file growth, no committed garbage.
    try testing.expectEqual(allocation.ref, allocationB.ref);
    writeTransaction.deinit();
}

test "a committed node freed within a transaction is not reused mid-transaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "committedsafe.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    { // commit a node so it belongs to a committed version
        var writeTransaction0 = try database.beginWrite();
        const allocation = try writeTransaction0.alloc(64);
        writeTransaction0.setRoot(allocation.ref);
        _ = try writeTransaction0.commit();
    }
    const committedRef = database.activeRoot;
    var writeTransaction = try database.beginWrite();
    try writeTransaction.free(committedRef, 64); // committed node -> deferred reclaim, NOT transaction-private
    const allocation = try writeTransaction.alloc(64);
    // A committed node a reader might still pin must not be reused within this transaction.
    try testing.expect(allocation.ref != committedRef);
    try testing.expectEqual(@as(usize, 0), writeTransaction.transactionReuse.extents.items.len);
    try testing.expectEqual(@as(usize, 1), writeTransaction.inFlightFrees.items.len);
    writeTransaction.deinit();
}

test "single instance reuse works through the global horizon" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ghreuse.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AAAAAAAA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    const oldRoot = database.activeRoot;
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BBBBBBBB");
        try writeTransaction.free(oldRoot, 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        try testing.expectEqual(oldRoot, allocation.ref);
        writeTransaction.deinit();
    }
}
