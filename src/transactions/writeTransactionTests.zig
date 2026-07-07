const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Database = @import("../database.zig").Database;
const Reference = @import("../storage/reference.zig").Reference;

const catalog = @import("../schema/catalog.zig");

const rows = @import("../records/rows.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    return std.fs.path.join(allocator, &.{ dir_path, name });
}

// Churn a single-row int type across `n` commits: each iteration commits an insert
// then commits a delete, so every cycle frees committed nodes into the free pool.
// Returns the final logical size (arena high-water).
fn churnLogicalSize(path: []const u8, retain: u64, n: u64) !u64 {
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    database.setRetainVersions(retain);

    var catalogRef: Reference = blk: {
        var w = try database.beginWrite();
        const c = try catalog.create(&w, 1);
        w.setRoot(c);
        _ = try w.commit();
        break :blk c;
    };

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        {
            var w = try database.beginWrite();
            catalogRef = database.active_root; // reload the committed catalog ref
            const r = try rows.insert(&w, catalogRef, &.{i});
            catalogRef = r.catalogRef;
            w.setRoot(catalogRef);
            _ = try w.commit();
        }
        {
            var w = try database.beginWrite();
            catalogRef = database.active_root;
            var out: [1]u64 = undefined;
            const ver = (try rows.getByPk(&w, catalogRef, i, &out)).?;
            catalogRef = switch (try rows.delete(&w, catalogRef, i, ver)) {
                .ok => |c| c,
                else => unreachable,
            };
            w.setRoot(catalogRef);
            _ = try w.commit();
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
        var w = try database.beginWrite();
        const catalogRef = try catalog.create(&w, 2);
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    const batches: usize = 10;
    const inserts_per_batch: usize = 500;
    var pk: u64 = 0;
    var batch: usize = 0;
    while (batch < batches) : (batch += 1) {
        var w = try database.beginWrite();
        var catalogRef = w.new_root;
        var i: usize = 0;
        while (i < inserts_per_batch) : (i += 1) {
            catalogRef = (try rows.insert(&w, catalogRef, &.{ pk, pk })).catalogRef;
            pk += 1;
        }
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    // The committed list legitimately tracks the copy-on-write working set (the
    // committed nodes the last batch touched), which grows with tree depth and
    // plateaus. The failure mode this guards against is unusable extents
    // accumulating at roughly one per insert PER BATCH (the fragmentation
    // death spiral): after `batches` rounds that lands near
    // inserts_per_batch * batches, while the healthy working set stays under
    // one batch's width. Deriving the bound from the loop constant keeps the
    // assertion honest if someone retunes the batch size.
    try testing.expect(database.freeListLenForTest() < inserts_per_batch);
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "BASELINE");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const size_before = database.logicalSize();

    // Abort a transaction that bump-allocated a lot.
    {
        var w = try database.beginWrite();
        var i: usize = 0;
        while (i < 200) : (i += 1) _ = try w.alloc(4096);
        w.deinit(); // abort
    }
    try testing.expectEqual(size_before, database.logicalSize());

    // The next commit must not durably absorb the aborted region either.
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AFTERAB_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // One 8-byte node plus the free-list node: logical size grows by well under
    // the ~800 KiB the aborted transaction touched.
    try testing.expect(database.logicalSize() - size_before < 4096);
}

test "retention window withholds recently freed space from reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const p0 = try tmpFilePath(testing.allocator, &tmp, "retain0.airdb");
    defer testing.allocator.free(p0);
    const p1 = try tmpFilePath(testing.allocator, &tmp, "retainmax.airdb");
    defer testing.allocator.free(p1);

    const n: u64 = 200;
    const size0 = try churnLogicalSize(p0, 0, n); // reuse freed space
    const size1 = try churnLogicalSize(p1, 1_000_000, n); // retain everything -> no reuse

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

    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "ORIGINAL");
    const copy = try w.writableCopy(a.ref, 8);
    try testing.expect(copy.ref != a.ref);
    try testing.expectEqualStrings("ORIGINAL", copy.bytes);
    // The old node was allocated within this same uncommitted transaction, so freeing it
    // routes to the transaction-private reuse pool (immediately reusable), not in_flight_frees.
    try testing.expectEqual(@as(usize, 0), w.in_flight_frees.items.len);
    try testing.expectEqual(@as(usize, 1), w.transactionReuse.extents.items.len);
    try testing.expectEqual(a.ref, w.transactionReuse.extents.items[0].offset);
    w.deinit(); // releases the transaction-private pools without committing
}

test "a node freed within a transaction is reused by the next allocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "txnreuse.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const a = try w.alloc(64);
    try w.free(a.ref, 64);
    const b = try w.alloc(64);
    // Reused the just-freed transaction-private node; no file growth, no committed garbage.
    try testing.expectEqual(a.ref, b.ref);
    w.deinit();
}

test "a committed node freed within a transaction is not reused mid-transaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "committedsafe.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    { // commit a node so it belongs to a committed version
        var w0 = try database.beginWrite();
        const a = try w0.alloc(64);
        w0.setRoot(a.ref);
        _ = try w0.commit();
    }
    const committed_ref = database.active_root;
    var w = try database.beginWrite();
    try w.free(committed_ref, 64); // committed node -> deferred reclaim, NOT transaction-private
    const b = try w.alloc(64);
    // A committed node a reader might still pin must not be reused within this transaction.
    try testing.expect(b.ref != committed_ref);
    try testing.expectEqual(@as(usize, 0), w.transactionReuse.extents.items.len);
    try testing.expectEqual(@as(usize, 1), w.in_flight_frees.items.len);
    w.deinit();
}

test "single instance reuse works through the global horizon" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ghreuse.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const old_root = database.active_root;
    {
        var w = try database.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(old_root, 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    {
        var w = try database.beginWrite();
        const c = try w.alloc(8);
        try testing.expectEqual(old_root, c.ref);
        w.deinit();
    }
}
