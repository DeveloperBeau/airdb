const std = @import("std");
const verification = @import("verification.zig");
const maintenance = @import("maintenance.zig");
const testing = std.testing;
const Io = std.Io;
const databaseModule = @import("database.zig");
const Database = databaseModule.Database;
const ringCapacity = databaseModule.ringCapacity;
const Reference = @import("storage/reference.zig").Reference;
const FreeList = @import("storage/freeList.zig").FreeList;
const sentinelMax = @import("transactions/coordination.zig").sentinelMax;
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const compaction = @import("storage/compaction.zig");
const catalog = @import("schema/catalog.zig");
const Index = @import("trees/index.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const dirPath = pathBuffer[0..pathLen];
    return std.fs.path.join(allocator, &.{ dirPath, name });
}

test "commit then reopen sees the committed root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "database.airdb");
    defer testing.allocator.free(path);

    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "HELLOAID");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        const rootRef = readTransaction.root();
        try testing.expect(rootRef != 0);
        const bytes = try readTransaction.deref(rootRef, 8);
        try testing.expectEqualStrings("HELLOAID", bytes);
    }
}

test "ending a read transaction twice does not release another reader's pin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "doubleend.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "PINDATA_");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    var readTransaction1 = try database.beginRead();
    var readTransaction2 = try database.beginRead(); // same version, pin count 2
    const version = readTransaction1.version;
    readTransaction1.end();
    readTransaction1.end(); // must be a no-op, not a second decrement
    try testing.expectEqual(@as(u32, 1), database.pins.get(version).?); // r2 still pinned
    try testing.expectEqual(version, database.horizon());
    readTransaction2.end();
    try testing.expectEqual(database.activeVersion, database.horizon());
}

test "version horizon tracks the oldest live reader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "horizon.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    try testing.expectEqual(database.activeVersion, database.horizon());

    var readTransaction1 = try database.beginRead();
    const version = database.activeVersion;
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "NEWDATA_");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    try testing.expectEqual(version, database.horizon()); // r1 still pinned at v
    readTransaction1.end();
    try testing.expectEqual(database.activeVersion, database.horizon());
}

test "free list persists across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "fl.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "FIRSTVAL");
        const allocationB = try writeTransaction.writableCopy(allocation.ref, 8); // frees the old node at this version
        writeTransaction.setRoot(allocationB.ref);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expect(database.freeListLengthForTest() >= 1);
    }
}

test "verifyIntegrity passes on a freshly committed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    try verification.verifyIntegrity(&database); // void on clean database
}

test "verifyIntegrity detects a root reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    database.activeRoot = database.store.map.len + 8; // point past the mapped region
    try testing.expectError(error.RootRefOutOfBounds, verification.verifyIntegrity(&database));
}

test "verifyIntegrity detects a corrupt header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_hdr.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    database.store.headerChecksumOk = false; // simulate an unreadable header
    try testing.expectError(error.HeaderCorrupt, verification.verifyIntegrity(&database));
}

test "verifyIntegrity detects a free-list node reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_fln.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    database.freeListNodeRef = @intCast(database.store.map.len + 8); // past the mapped region (8-aligned)
    database.freeListNodeLen = 16;
    try testing.expectError(error.FreeListCorrupt, verification.verifyIntegrity(&database));
}

test "verifyIntegrity detects a free extent out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_ext.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    // Inject an extent whose offset is past the mapped region.
    try database.freeList.extents.append(database.store.allocator, .{ .offset = @intCast(database.store.map.len + 8), .len = 8, .freedVersion = 1 });
    try testing.expectError(error.FreeExtentOutOfBounds, verification.verifyIntegrity(&database));
}

test "verifyIntegrity passes after churn on an indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_idx_churn.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const tid: u16 = 0;

    // One type: int primaryKey + one indexed int property.
    {
        var writeTransaction = try database.beginWrite();
        const dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    // Seed 200 rows; value = primaryKey % 16 so many rows share each inner set.
    {
        var writeTransaction = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey % 16 } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    // Churn: update the value of every even primaryKey, delete every 5th primaryKey.
    {
        var writeTransaction = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) {
            var out: [2]catalog.Value = undefined;
            const version = (try typeRouting.get(&writeTransaction, dir, tid, primaryKey, &out)).?;
            if (primaryKey % 5 == 0) {
                dir = switch (try typeRouting.delete(&writeTransaction, dir, tid, primaryKey, version)) {
                    .ok => |newDir| newDir,
                    else => unreachable,
                };
            } else if (primaryKey % 2 == 0) {
                const updateResult = try typeRouting.update(&writeTransaction, dir, tid, primaryKey, &.{ .{ .int = primaryKey }, .{ .int = (primaryKey + 7) % 16 } }, version);
                dir = updateResult.ok.dir;
            }
        }
        // Insert a fresh batch with reused values.
        while (primaryKey < 260) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey % 16 } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    try verification.verifyIntegrity(&database); // forward + backward audit must find no divergence
}

test "verifyIntegrity detects a corrupted value index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_idx_corrupt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const tid: u16 = 0;
    const propertyIndex: usize = 1; // the indexed property

    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 8) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption

    // White-box corruption: register an existing live objectKey under a value that no
    // row actually has. The forward direction still holds (every row stays
    // covered), so this exercises the backward check: the bogus entry resolves to
    // a live row whose property value differs from the indexed value.
    {
        var writeTransaction = try database.beginWrite();
        const dir = database.activeRoot;
        const catalogRef = try typeDirectory.catalogRef(&writeTransaction, dir, tid);
        const view = try catalog.loadCatalog(&writeTransaction, catalogRef);
        const objectKey = (try catalog.primaryKeyToObjectKey(&writeTransaction, catalogRef, 0)).?; // row primaryKey 0 has value 0
        const bogusValue: u64 = 999_999; // no row carries this value
        var setRoot = try Index.create(&writeTransaction);
        setRoot = try Index.insert(&writeTransaction, setRoot, objectKey, 1);
        const newVi = try Index.insert(&writeTransaction, view.valueIndexRef(propertyIndex), bogusValue, setRoot);
        const newCatalog = try catalog.setValueIndexRef(&writeTransaction, catalogRef, propertyIndex, newVi);
        const newDir = try typeDirectory.setCatalogRef(&writeTransaction, dir, tid, newCatalog);
        writeTransaction.setRoot(newDir);
        _ = try writeTransaction.commit();
    }

    try testing.expectError(error.ValueIndexStaleEntry, verification.verifyIntegrity(&database));
}

test "verifyIntegrity passes on a clean link graph after churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_bl_clean.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const links = @import("records/links.zig");

    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: target type
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 }, .{ .kind = .linkSet, .linkTarget = 0 } }, // 1: source
        }, &.{ false, false });
        const insertedA = try typeRouting.insert(&writeTransaction, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "A" } });
        dir = insertedA.dir;
        const insertedB = try typeRouting.insert(&writeTransaction, dir, 0, &.{ .{ .int = 2 }, .{ .bytes = "B" } });
        dir = insertedB.dir;
        dir = (try typeRouting.insert(&writeTransaction, dir, 1, &.{ .{ .int = 1 }, .{ .link = insertedA.objectKey }, .{ .linkSet = &.{ insertedA.objectKey, insertedB.objectKey } } })).dir;
        dir = (try typeRouting.insert(&writeTransaction, dir, 1, &.{ .{ .int = 2 }, .{ .link = insertedB.objectKey }, .{ .linkSet = &.{} } })).dir;
        // Churn: move source 1's to-one link, drop one set member.
        dir = try typeRouting.setLink(&writeTransaction, dir, 1, 1, 1, insertedB.objectKey);
        const sourceCatalog = try typeDirectory.catalogRef(&writeTransaction, dir, 1);
        const newCatalog = try links.linkSetRemove(&writeTransaction, sourceCatalog, 1, 2, insertedA.objectKey);
        dir = try typeDirectory.setCatalogRef(&writeTransaction, dir, 1, newCatalog);
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // forward + backward backlink audit finds no divergence
}

test "verifyIntegrity detects a corrupted backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_bl_corrupt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var targetObjectKey: u64 = undefined;

    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } },
        }, &.{false});
        const insertedA = try typeRouting.insert(&writeTransaction, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        dir = insertedA.dir;
        targetObjectKey = insertedA.objectKey;
        dir = (try typeRouting.insert(&writeTransaction, dir, 0, &.{ .{ .int = 2 }, .{ .link = targetObjectKey } })).dir;
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption

    // White-box corruption: drop the target's backlink entry while the source's
    // link column still points at it. Forward audit must flag the divergence.
    {
        var writeTransaction = try database.beginWrite();
        const dir = database.activeRoot;
        const catalogRef = try typeDirectory.catalogRef(&writeTransaction, dir, 0);
        const view = try catalog.loadCatalog(&writeTransaction, catalogRef);
        const newBl = try Index.remove(&writeTransaction, view.backlinkRef(1), targetObjectKey);
        const newCatalog = try catalog.setBacklinkRef(&writeTransaction, catalogRef, 1, newBl);
        const newDir = try typeDirectory.setCatalogRef(&writeTransaction, dir, 0, newCatalog);
        writeTransaction.setRoot(newDir);
        _ = try writeTransaction.commit();
    }
    try testing.expectError(error.BacklinkMissingEntry, verification.verifyIntegrity(&database));
}

test "verifyIntegrity passes on a non-indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_noidx.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    const tid: u16 = 0;

    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 50) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey * 3 } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    try verification.verifyIntegrity(&database); // no indexed property -> audit must not false-positive
}

test "the 65th attach is refused rather than reading with invisible pins" {
    // A Database without a participant slot cannot advertise its reader pins, so
    // concurrent writers would reclaim under its snapshots. open/create now
    // refuse the attach outright.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "slots64.airdb");
    defer testing.allocator.free(path);

    var instances: [64]Database = undefined;
    var opened: usize = 0;
    defer {
        var index: usize = 0;
        while (index < opened) : (index += 1) instances[index].deinit();
    }
    instances[0] = try Database.create(testing.allocator, path);
    opened = 1;
    while (opened < 64) : (opened += 1) {
        instances[opened] = try Database.open(testing.allocator, path);
    }
    try testing.expectError(error.TooManyAttachments, Database.open(testing.allocator, path));
}

test "two Database instances on one file share a coordination attach count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "share.airdb");
    defer testing.allocator.free(path);
    var databaseA = try Database.create(testing.allocator, path);
    defer databaseA.deinit();
    var databaseB = try Database.open(testing.allocator, path);
    defer databaseB.deinit();
    try testing.expectEqual(@as(u32, 2), databaseA.coordination.attachCount());
}

test "a second Database instance sees a commit made by the first after refresh-on-read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vis.airdb");
    defer testing.allocator.free(path);
    var databaseA = try Database.create(testing.allocator, path);
    defer databaseA.deinit();
    var databaseB = try Database.open(testing.allocator, path);
    defer databaseB.deinit();
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "SHARED!!");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    var readTransaction = try databaseB.beginRead();
    try testing.expectEqualStrings("SHARED!!", try readTransaction.deref(readTransaction.root(), 8));
    readTransaction.end();
}

test "a second writer is excluded while the first holds the write lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "excl.airdb");
    defer testing.allocator.free(path);
    var databaseA = try Database.create(testing.allocator, path);
    defer databaseA.deinit();
    var databaseB = try Database.open(testing.allocator, path);
    defer databaseB.deinit();
    var writeTransactionA = try databaseA.beginWrite();
    try testing.expectError(error.WouldBlock, databaseB.beginWriteTry());
    const allocation = try writeTransactionA.alloc(8);
    @memcpy(allocation.bytes, "FIRST!!!");
    writeTransactionA.setRoot(allocation.ref);
    _ = try writeTransactionA.commit();
    var writeTransactionB = try databaseB.beginWriteTry();
    writeTransactionB.deinit();
}

test "Database publishes its minimum pinned version to its participant slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pub.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "VERSION2");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    // No readers: this process publishes the sentinel (imposes no horizon constraint).
    try testing.expectEqual(sentinelMax, database.coordination.slotMinPinnedForTest(database.participantSlot.?));
    var readTransaction = try database.beginRead(); // pins the current version
    try testing.expectEqual(database.activeVersion, database.coordination.slotMinPinnedForTest(database.participantSlot.?));
    readTransaction.end();
    try testing.expectEqual(sentinelMax, database.coordination.slotMinPinnedForTest(database.participantSlot.?));
}

test "allocations beyond the initial mapping grow the file and data survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "biggrow.airdb");
    defer testing.allocator.free(path);
    var lastRef: Reference = 0;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var index: usize = 0;
        while (index < 400) : (index += 1) {
            const allocation = try writeTransaction.alloc(4096);
            allocation.bytes[0] = @intCast(index & 0xff);
            lastRef = allocation.ref;
        }
        writeTransaction.setRoot(lastRef);
        _ = try writeTransaction.commit();
        try testing.expect(database.store.map.len > 4096 * 256);
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        const got = try readTransaction.deref(readTransaction.root(), 4096);
        try testing.expectEqual(@as(u8, @intCast(399 & 0xff)), got[0]);
        readTransaction.end();
    }
}

test "observability: pinned version and storage size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "obs.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // First write+commit advances activeVersion.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "FIRST!!!");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    // No open reader: the oldest pinned version is the active version.
    try testing.expectEqual(database.activeVersion, database.oldestPinnedVersion());

    // Hold a reader at the current version, then commit a newer version.
    var readTransaction = try database.beginRead();
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "SECOND!!");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    // The held reader pins the older version, below the new active version.
    try testing.expect(database.oldestPinnedVersion() < database.activeVersion);

    try testing.expectEqual(@as(u32, 1), database.attachedProcesses());
    try testing.expect(database.logicalSize() > 0);
    try testing.expect((try database.fileSize()) >= database.logicalSize());

    readTransaction.end();
    try testing.expectEqual(database.activeVersion, database.oldestPinnedVersion());
}

test "metrics report mapped length, versions, and reclaimable bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "metrics.airdb");
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

    const metricsSnapshot = database.metrics();
    try testing.expect(metricsSnapshot.mappedLen >= 4096 * 256);
    try testing.expectEqual(database.activeVersion, metricsSnapshot.latestVersion);
    try testing.expect(metricsSnapshot.freeExtentCount >= 1);
    try testing.expect(metricsSnapshot.reclaimableBytes >= 8);
    try testing.expectEqual(database.activeVersion, metricsSnapshot.oldestPinnedVersion); // no readers
    try testing.expect(!metricsSnapshot.poisoned);
}

test "version->root ring records committed versions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ring.airdb");
    defer testing.allocator.free(path);

    const key: u64 = 5;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        // Version 1 (the initial slot) was never written into the ring.
        try testing.expectEqual(@as(?u64, null), database.versionRoot(1));

        var index: u64 = 0;
        while (index < key) : (index += 1) {
            var writeTransaction = try database.beginWrite();
            const allocation = try writeTransaction.alloc(8);
            @memcpy(allocation.bytes, "RINGDATA");
            writeTransaction.setRoot(allocation.ref);
            _ = try writeTransaction.commit();
        }

        // Each committed version (2..activeVersion) maps to a non-zero root.
        var version: u64 = 2;
        while (version <= database.activeVersion) : (version += 1) {
            const rootRef = database.versionRoot(version) orelse return error.TestUnexpectedNull;
            try testing.expect(rootRef != 0);
        }
        // A version that was never committed yet is null.
        try testing.expectEqual(@as(?u64, null), database.versionRoot(database.activeVersion + 1));
    }

    // The ring lives in the durable header page, so it survives reopen.
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expectEqual(@as(u64, 1 + key), database.activeVersion);
        var version: u64 = 2;
        while (version <= database.activeVersion) : (version += 1) {
            const rootRef = database.versionRoot(version) orelse return error.TestUnexpectedNull;
            try testing.expect(rootRef != 0);
        }
    }
}

test "ring wraps after capacity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ringwrap.airdb");
    defer testing.allocator.free(path);

    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit more than ringCapacity times so the ring wraps and evicts old entries.
    const total: u64 = @as(u64, ringCapacity) + 12;
    var index: u64 = 0;
    while (index < total) : (index += 1) {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "WRAPDATA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    const newest = database.activeVersion; // 1 + total
    const oldestLive = newest - @as(u64, ringCapacity) + 1;

    // The most recent ringCapacity versions are all present.
    try testing.expectEqual(oldestLive, database.oldestRetainedVersion());
    var version: u64 = oldestLive;
    while (version <= newest) : (version += 1) {
        const rootRef = database.versionRoot(version) orelse return error.TestUnexpectedNull;
        try testing.expect(rootRef != 0);
    }

    // Versions older than the live window were evicted.
    try testing.expectEqual(@as(?u64, null), database.versionRoot(oldestLive - 1));
    try testing.expectEqual(@as(?u64, null), database.versionRoot(2));
}

test "a failed refresh leaves version and free list untouched" {
    // Regression: refreshToLatest must be all-or-nothing. If the published
    // free-list node cannot be decoded, the instance keeps its old version AND
    // its old free list; previously it advanced with an empty list, which the
    // next commit would persist, durably dropping every reclaimable extent.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "refresh_atomic.airdb");
    defer testing.allocator.free(path);

    var databaseA = try Database.create(testing.allocator, path);
    defer databaseA.deinit();
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "VERSION2");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    var databaseB = try Database.open(testing.allocator, path);
    defer databaseB.deinit();
    const bVersion = databaseB.activeVersion;
    const bFlLen = databaseB.freeListLengthForTest();

    // a commits a version with a non-empty free list, then its node is
    // corrupted in the shared mapping so b's refresh decode must fail.
    {
        var writeTransaction = try databaseA.beginWrite();
        const oldRoot = databaseA.activeRoot;
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "VERSION3");
        try writeTransaction.free(oldRoot, 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    try testing.expect(databaseA.freeListNodeRef != 0);
    const nodeOff: usize = @intCast(databaseA.freeListNodeRef);
    // An absurd extent count makes the node length exceed the mapping.
    std.mem.writeInt(u32, databaseA.store.map[nodeOff..][0..4], 0xFFFF_FFFF, .little);

    try testing.expectError(error.BadRef, databaseB.beginRead());
    try testing.expectEqual(bVersion, databaseB.activeVersion);
    try testing.expectEqual(bFlLen, databaseB.freeListLengthForTest());
}

test "a retried commit's ring entry wins over the aborted duplicate" {
    // A commit that fails its data barrier leaves its (version, root) ring entry
    // behind; the retry reuses the same version number and appends a second
    // entry. versionRoot must return the retry's root (the committed one), not
    // the aborted duplicate, or beginReadAt would expose never-committed data.
    const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ringdup.airdb");
    defer testing.allocator.free(path);

    // Flush sequence: create=2 flushes, first commit=2, so the second commit's
    // data barrier is flush #5.
    var fsync = FailingSyncer{ .failOn = 5 };
    var database = try Database.createWith(testing.allocator, path, fsync.any());
    defer database.deinit();
    database.setRetainVersions(std.math.maxInt(u64));

    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BASELINE");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    const vTarget = database.activeVersion + 1;

    // Aborted attempt at vTarget: the ring entry lands, the flush fails.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "ABORTED!");
        writeTransaction.setRoot(allocation.ref);
        try testing.expectError(error.Durability, writeTransaction.commit());
    }

    // Retry commits vTarget for real with different data.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "REALDATA");
        writeTransaction.setRoot(allocation.ref);
        try testing.expectEqual(vTarget, try writeTransaction.commit());
    }

    // The past-version read must resolve to the committed root.
    var readTransaction = try database.beginReadAt(vTarget);
    defer readTransaction.end();
    try testing.expectEqualStrings("REALDATA", try readTransaction.deref(readTransaction.root(), 8));
}

test "beginReadAt opens a past version within the retention window" {
    const rows = @import("records/rows.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    database.setRetainVersions(std.math.maxInt(u64)); // retain everything

    // vA: primaryKey 1 ; vB: + primaryKey 2 ; vC: + primaryKey 3 (additive, so each version's live set differs)
    var versionA: u64 = undefined;
    var versionB: u64 = undefined;
    var versionC: u64 = undefined;
    {
        var writeTransaction = try database.beginWrite();
        var catalogRef = try catalog.create(&writeTransaction, 2);
        catalogRef = (try rows.insert(&writeTransaction, catalogRef, &.{ 1, 100 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        versionA = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        const catalogRef = (try rows.insert(&writeTransaction, writeTransaction.newRoot, &.{ 2, 200 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        versionB = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        const catalogRef = (try rows.insert(&writeTransaction, writeTransaction.newRoot, &.{ 3, 300 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        versionC = try writeTransaction.commit();
    }

    var out: [2]u64 = undefined;
    // Past snapshot at vA: only primaryKey 1 exists.
    {
        var readTransaction = try database.beginReadAt(versionA);
        defer readTransaction.end();
        try testing.expectEqual(@as(u64, 1), try compaction.liveCount(&readTransaction, readTransaction.root()));
        try testing.expect((try rows.getByPrimaryKey(&readTransaction, readTransaction.root(), 1, &out)) != null);
        try testing.expectEqual(@as(?u64, null), try rows.getByPrimaryKey(&readTransaction, readTransaction.root(), 2, &out));
    }
    // Past snapshot at vB: primaryKey 1 and 2.
    {
        var readTransaction = try database.beginReadAt(versionB);
        defer readTransaction.end();
        try testing.expectEqual(@as(u64, 2), try compaction.liveCount(&readTransaction, readTransaction.root()));
    }
    // Latest: all three.
    {
        var readTransaction = try database.beginRead();
        defer readTransaction.end();
        try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&readTransaction, readTransaction.root()));
    }
    // A future version is unavailable.
    try testing.expectError(error.VersionUnavailable, database.beginReadAt(versionC + 5));
}

test "the retention window is shared across instances and survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "retain_shared.airdb");
    defer testing.allocator.free(path);
    {
        var databaseA = try Database.create(testing.allocator, path);
        defer databaseA.deinit();
        var databaseB = try Database.open(testing.allocator, path);
        defer databaseB.deinit();
        // A raises the floor; B sees it immediately through the shared mapping.
        databaseA.setRetainVersions(100);
        try testing.expectEqual(@as(u64, 100), databaseB.retainVersions());
        // Make the header page durable via a commit.
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "RETAINED");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expectEqual(@as(u64, 100), database.retainVersions());
    }
}

test "a writer honors a retention floor raised by another instance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "retain_writer.airdb");
    defer testing.allocator.free(path);
    var databaseA = try Database.create(testing.allocator, path);
    defer databaseA.deinit();
    var databaseB = try Database.open(testing.allocator, path);
    defer databaseB.deinit();
    // Instance a (the "reader" side) demands full retention; b never called
    // setRetainVersions and would previously reuse freed space immediately.
    databaseA.setRetainVersions(std.math.maxInt(u64));

    // b commits a node, then frees it and commits again: with the shared floor
    // the freed extent must NOT be reused by b's next allocation.
    {
        var writeTransaction = try databaseB.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AAAAAAAA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    const oldRoot = databaseB.activeRoot;
    {
        var writeTransaction = try databaseB.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BBBBBBBB");
        try writeTransaction.free(oldRoot, 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var writeTransaction = try databaseB.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        // Without the shared window this allocation reused oldRoot.
        try testing.expect(allocation.ref != oldRoot);
        writeTransaction.deinit();
    }
}

test "beginReadAt rejects a version aged out of the retention window" {
    const rows = @import("records/rows.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    // retainVersions defaults to 0: only the active version is readable.
    var versionA: u64 = undefined;
    {
        var writeTransaction = try database.beginWrite();
        var catalogRef = try catalog.create(&writeTransaction, 2);
        catalogRef = (try rows.insert(&writeTransaction, catalogRef, &.{ 1, 100 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        versionA = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        const catalogRef = (try rows.insert(&writeTransaction, writeTransaction.newRoot, &.{ 2, 200 })).catalogRef;
        writeTransaction.setRoot(catalogRef);
        _ = try writeTransaction.commit();
    }
    // vA is older than active - retainVersions(0) -> aged out.
    try testing.expectError(error.VersionUnavailable, database.beginReadAt(versionA));
    try testing.expect(database.oldestReadableVersion() == database.activeVersion);
}

// Churn a single int-primaryKey type at `path` with a steady live set: seed `live`
// rows, then on each iteration insert `live` fresh rows and delete the `live`
// oldest live rows (net-zero live count). Dead rows accumulate, so nextRow
// grows without bound unless compaction reclaims it. When `auto` is set, the
// caller drives maybeCompactStep after each iteration until the type is packed.
// Returns the final nextRow (physical row high-water) and live count.
fn churnNetZero(path: []const u8, live: u64, iters: u64, auto: bool) !struct { nextRow: u64, live: u64 } {
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    database.autoCompact = auto;
    const tid: u16 = 0;

    // Single type: int primaryKey + one int property.
    {
        var writeTransaction = try database.beginWrite();
        const dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    // Seed the live set (primaryKeys [0, live)).
    var high: u64 = 0;
    {
        var writeTransaction = try database.beginWrite();
        var dir = database.activeRoot;
        while (high < live) : (high += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = high }, .{ .int = high } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    var low: u64 = 0;
    var iter: u64 = 0;
    while (iter < iters) : (iter += 1) {
        {
            var writeTransaction = try database.beginWrite();
            var dir = database.activeRoot;
            // Insert `live` fresh rows.
            var key: u64 = 0;
            while (key < live) : (key += 1) {
                dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = high }, .{ .int = high } })).dir;
                high += 1;
            }
            // Delete the `live` oldest live rows.
            key = 0;
            while (key < live) : (key += 1) {
                var out: [2]catalog.Value = undefined;
                const version = (try typeRouting.get(&writeTransaction, dir, tid, low, &out)).?;
                dir = switch (try typeRouting.delete(&writeTransaction, dir, tid, low, version)) {
                    .ok => |newDir| newDir,
                    else => unreachable,
                };
                low += 1;
            }
            writeTransaction.setRoot(dir);
            _ = try writeTransaction.commit();
        }
        // Opt-in: drive the incremental step loop so the type stays packed.
        if (database.autoCompact) {
            while (true) {
                const res = try maintenance.maybeCompactStep(&database, tid, 4);
                if (!res.ran or res.done) break;
            }
        }
    }

    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogRef = try typeDirectory.catalogRef(&readTransaction, readTransaction.root(), tid);
    return .{
        .nextRow = (try catalog.loadCatalog(&readTransaction, catalogRef)).nextRow,
        .live = try compaction.liveCount(&readTransaction, catalogRef),
    };
}

test "a failed commit-point flush poisons the instance until reopen" {
    // The flipped header pointer sits in the mapped page before the failed
    // barrier, so its on-disk fate is indeterminate; further writes from this
    // instance could scribble the maybe-published version. Reopen resolves.
    const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "poison.airdb");
    defer testing.allocator.free(path);

    // create = 2 flushes; the first commit's data barrier is #3 and its
    // HEADER flush (the commit point) is #4.
    var fsync = FailingSyncer{ .failOn = 4 };
    {
        var database = try Database.createWith(testing.allocator, path, fsync.any());
        defer database.deinit();
        {
            var writeTransaction = try database.beginWrite();
            errdefer writeTransaction.deinit();
            const allocation = try writeTransaction.alloc(8);
            @memcpy(allocation.bytes, "POISON!!");
            writeTransaction.setRoot(allocation.ref);
            try testing.expectError(error.Durability, writeTransaction.commit());
        }
        try testing.expectError(error.CommitIndeterminate, database.beginWrite());
        try testing.expect(database.metrics().poisoned);
    }
    // Reopen resolves the header and writes flow again.
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "RESOLVED");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
}

test "a failed commit inside maybeCompactStep neither crashes nor wedges the write lock" {
    // Regression for the commit error contract: maybeCompactStep holds
    // `errdefer w.deinit()` across commit. Commit used to deinit the transaction's
    // lists itself on error, so the errdefer double-freed them (heap
    // corruption); and non-durability commit errors leaked the cross-process
    // write lock. Commit now concludes uniformly and deinit is a no-op after.
    const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "compactfail.airdb");
    defer testing.allocator.free(path);

    // Flushes: create = 2, type commit = 2, churn commit = 2 -> the compact
    // step's data barrier is flush #7.
    var fsync = FailingSyncer{ .failOn = 7 };
    var database = try Database.createWith(testing.allocator, path, fsync.any());
    defer database.deinit();
    const tid: u16 = 0;
    {
        var writeTransaction = try database.beginWrite();
        const dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 10) : (primaryKey += 1) dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        var out: [2]catalog.Value = undefined;
        primaryKey = 0;
        while (primaryKey < 8) : (primaryKey += 1) {
            const version = (try typeRouting.get(&writeTransaction, dir, tid, primaryKey, &out)).?;
            dir = switch (try typeRouting.delete(&writeTransaction, dir, tid, primaryKey, version)) {
                .ok => |newDir| newDir,
                else => unreachable,
            };
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    // The compaction step's commit fails its data barrier.
    try testing.expectError(error.Durability, maintenance.maybeCompactStep(&database, tid, 100));

    // The write lock must be free and the data intact.
    var writeTransaction = try database.beginWriteTry();
    writeTransaction.deinit();
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    try testing.expectEqual(@as(u64, 2), try typeRouting.liveCount(&readTransaction, readTransaction.root(), tid));
}

test "the compaction cursor never resumes across types" {
    // Regression: the cursor was keyed only on (liveCount, nextRow), which
    // two different types can share. Resuming type A's high-water cursor while
    // stepping type B left B's tail unexamined and the final truncate would
    // have dropped live rows. The cursor now also pins the exact catalog ref.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cursor_types.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Two identically shaped types with identical churn: both end with
    // live=4, nextRow=12 and dead tails.
    {
        var writeTransaction = try database.beginWrite();
        const dir = try typeDirectory.createTypes(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .int } },
            &.{ .{ .kind = .int }, .{ .kind = .int } },
        }, &.{ false, false });
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        var dir = database.activeRoot;
        var typeId: u16 = 0;
        while (typeId < 2) : (typeId += 1) {
            var primaryKey: u64 = 0;
            while (primaryKey < 12) : (primaryKey += 1) dir = (try typeRouting.insert(&writeTransaction, dir, typeId, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
            var out: [2]catalog.Value = undefined;
            primaryKey = 0;
            while (primaryKey < 8) : (primaryKey += 1) {
                const version = (try typeRouting.get(&writeTransaction, dir, typeId, primaryKey, &out)).?;
                dir = switch (try typeRouting.delete(&writeTransaction, dir, typeId, primaryKey, version)) {
                    .ok => |newDir| newDir,
                    else => unreachable,
                };
            }
            writeTransaction.setRoot(dir);
        }
        _ = try writeTransaction.commit();
    }

    // Partial step on type 0 persists a cursor; type 1 must NOT resume it.
    _ = try maintenance.maybeCompactStep(&database, 0, 1);
    while (true) {
        const res = try maintenance.maybeCompactStep(&database, 1, 2);
        if (!res.ran or res.done) break;
    }
    while (true) {
        const res = try maintenance.maybeCompactStep(&database, 0, 2);
        if (!res.ran or res.done) break;
    }

    // Every surviving row of both types is intact and both are fully packed.
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    var typeId: u16 = 0;
    while (typeId < 2) : (typeId += 1) {
        try testing.expectEqual(@as(u64, 4), try typeRouting.liveCount(&readTransaction, readTransaction.root(), typeId));
        var out: [2]catalog.Value = undefined;
        var primaryKey: u64 = 8;
        while (primaryKey < 12) : (primaryKey += 1) {
            try testing.expect((try typeRouting.get(&readTransaction, readTransaction.root(), typeId, primaryKey, &out)) != null);
        }
        const catalogRef = try typeDirectory.catalogRef(&readTransaction, readTransaction.root(), typeId);
        try testing.expectEqual(@as(u64, 4), (try catalog.loadCatalog(&readTransaction, catalogRef)).nextRow);
    }
}

test "a corrupt persisted free-list extent fails open instead of poisoning reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "flcorrupt.airdb");
    defer testing.allocator.free(path);
    var nodeRef: Reference = 0;
    {
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
        nodeRef = database.freeListNodeRef;
        try testing.expect(nodeRef != 0);
        // Corrupt the first extent's offset into something misaligned.
        const off: usize = @intCast(nodeRef);
        std.mem.writeInt(u64, database.store.map[off + 12 ..][0..8], 12345, .little); // % 8 != 0
        try database.store.syncer.flush(database.store.file);
    }
    try testing.expectError(error.Corrupt, Database.open(testing.allocator, path));
}

test "maybeCompactStep bounds dead rows under churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const offPath = try tmpFilePath(testing.allocator, &tmp, "churnoff.airdb");
    defer testing.allocator.free(offPath);
    const onPath = try tmpFilePath(testing.allocator, &tmp, "churnon.airdb");
    defer testing.allocator.free(onPath);

    // Identical churn, run twice: without auto-compaction, then with it.
    const without = try churnNetZero(offPath, 10, 40, false);
    const with = try churnNetZero(onPath, 10, 40, true);

    // Live data is preserved identically in both runs.
    try testing.expectEqual(without.live, with.live);
    // Compaction reclaims the dead-row space: the physical high-water is strictly
    // smaller when the step loop runs.
    try testing.expect(with.nextRow < without.nextRow);
}

test "maybeCompactStep is a no-op when nothing to compact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "nocompact.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    const tid: u16 = 0;
    {
        var writeTransaction = try database.beginWrite();
        var dir = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 3) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&writeTransaction, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        }
        writeTransaction.setRoot(dir);
        _ = try writeTransaction.commit();
    }

    const res = try maintenance.maybeCompactStep(&database, tid, 4);
    try testing.expect(!res.ran);
    try testing.expectEqual(@as(usize, 0), res.moved);
    try testing.expect(!res.done);

    // The type is untouched: all three rows remain live and packed.
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogRef = try typeDirectory.catalogRef(&readTransaction, readTransaction.root(), tid);
    try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&readTransaction, catalogRef));
    try testing.expectEqual(@as(u64, 3), (try catalog.loadCatalog(&readTransaction, catalogRef)).nextRow);
}

test "a free list spanning multiple chunks survives commit and reopen" {
    // Regression: the free list was persisted as ONE node whose size grew
    // with the extent count; once heavy churn pushed it past the 16 MiB
    // section cap, the commit-path allocation failed with error.AllocTooLarge
    // and the database could no longer commit at all. The list is now a chain
    // of bounded chunks; a list overflowing one chunk must persist, reload,
    // and verify.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "flchain.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    errdefer database.deinit();

    const nExtents = FreeList.chunkExtentCap + 500;
    const refs = try testing.allocator.alloc(u64, nExtents);
    defer testing.allocator.free(refs);
    {
        var writeTransaction = try database.beginWrite();
        for (refs) |*ref| ref.* = (try writeTransaction.alloc(8)).ref;
        const root = try writeTransaction.alloc(8);
        @memcpy(root.bytes, "CHUNKED!");
        writeTransaction.setRoot(root.ref);
        _ = try writeTransaction.commit();
    }
    {
        var writeTransaction = try database.beginWrite();
        for (refs) |ref| try writeTransaction.free(ref, 8);
        const root = try writeTransaction.alloc(8);
        @memcpy(root.bytes, "CHUNKED2");
        writeTransaction.setRoot(root.ref);
        _ = try writeTransaction.commit();
    }
    try testing.expect(database.freeListLengthForTest() >= nExtents);
    database.deinit();

    var database2 = try Database.open(testing.allocator, path);
    defer database2.deinit();
    try testing.expect(database2.freeListLengthForTest() >= nExtents);
    try verification.verifyIntegrity(&database2);
}

test "a free-list chain whose next ref points up-chain is rejected as corrupt" {
    // Regression: a forged or bit-rotted nextRef forming a cycle re-decoded
    // the same chunk's extents on every hop -- an out-of-memory death, not an
    // error, long before the hop guard tripped. Legitimate chains have
    // strictly decreasing refs (chunks are written back-to-front), so a
    // self-referencing head must fail the open cheaply with error.Corrupt.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "flcycle.airdb");
    defer testing.allocator.free(path);
    var nodeRef: u64 = 0;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        {
            var writeTransaction = try database.beginWrite();
            const allocation = try writeTransaction.alloc(8);
            @memcpy(allocation.bytes, "CYCLBASE");
            writeTransaction.setRoot(allocation.ref);
            _ = try writeTransaction.commit();
        }
        const oldRoot = database.activeRoot;
        {
            var writeTransaction = try database.beginWrite();
            const allocation = try writeTransaction.alloc(8);
            @memcpy(allocation.bytes, "CYCLNEXT");
            try writeTransaction.free(oldRoot, 8);
            writeTransaction.setRoot(allocation.ref);
            _ = try writeTransaction.commit();
        }
        nodeRef = database.freeListNodeRef;
        try testing.expect(nodeRef != 0);
        // Point the head chunk's nextRef at itself.
        const off: usize = @intCast(nodeRef);
        std.mem.writeInt(u64, database.store.map[off + 4 ..][0..8], nodeRef, .little);
        try database.store.syncer.flush(database.store.file);
    }
    try testing.expectError(error.Corrupt, Database.open(testing.allocator, path));
}
