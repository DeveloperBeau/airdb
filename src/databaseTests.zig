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
const coordMod = @import("transactions/coordination.zig");
const typedir = @import("schema/typeDirectory.zig");
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "HELLOAID");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        const rootRef = r.root();
        try testing.expect(rootRef != 0);
        const bytes = try r.deref(rootRef, 8);
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "PINDATA_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    var r1 = try database.beginRead();
    var r2 = try database.beginRead(); // same version, pin count 2
    const v = r1.version;
    r1.end();
    r1.end(); // must be a no-op, not a second decrement
    try testing.expectEqual(@as(u32, 1), database.pins.get(v).?); // r2 still pinned
    try testing.expectEqual(v, database.horizon());
    r2.end();
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

    var r1 = try database.beginRead();
    const v = database.activeVersion;
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "NEWDATA_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    try testing.expectEqual(v, database.horizon()); // r1 still pinned at v
    r1.end();
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRSTVAL");
        const b = try w.writableCopy(a.ref, 8); // frees the old node at this version
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expect(database.freeListLenForTest() >= 1);
    }
}

test "verifyIntegrity passes on a freshly committed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    try verification.verifyIntegrity(&database); // void on clean database
}

test "verifyIntegrity detects a root reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
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
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
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
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
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
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
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
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Seed 200 rows; value = primaryKey % 16 so many rows share each inner set.
    {
        var w = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey % 16 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Churn: update the value of every even primaryKey, delete every 5th primaryKey.
    {
        var w = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 200) : (primaryKey += 1) {
            var out: [2]catalog.Value = undefined;
            const version = (try typeRouting.get(&w, dir, tid, primaryKey, &out)).?;
            if (primaryKey % 5 == 0) {
                dir = switch (try typeRouting.delete(&w, dir, tid, primaryKey, version)) {
                    .ok => |d| d,
                    else => unreachable,
                };
            } else if (primaryKey % 2 == 0) {
                const ur = try typeRouting.update(&w, dir, tid, primaryKey, &.{ .{ .int = primaryKey }, .{ .int = (primaryKey + 7) % 16 } }, version);
                dir = ur.ok.dir;
            }
        }
        // Insert a fresh batch with reused values.
        while (primaryKey < 260) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey % 16 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
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
    const p: usize = 1; // the indexed property

    {
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 8) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption

    // White-box corruption: register an existing live objectKey under a value that no
    // row actually has. The forward direction still holds (every row stays
    // covered), so this exercises the backward check: the bogus entry resolves to
    // a live row whose property value differs from the indexed value.
    {
        var w = try database.beginWrite();
        const dir = database.activeRoot;
        const catalogRef = try typedir.catalogRef(&w, dir, tid);
        const cv = try catalog.loadCatalog(&w, catalogRef);
        const objectKey = (try catalog.primaryKeyToObjectKey(&w, catalogRef, 0)).?; // row primaryKey 0 has value 0
        const bogusValue: u64 = 999_999; // no row carries this value
        var setRoot = try Index.create(&w);
        setRoot = try Index.insert(&w, setRoot, objectKey, 1);
        const newVi = try Index.insert(&w, cv.valueIndexRef(p), bogusValue, setRoot);
        const newCatalog = try catalog.setValueIndexRef(&w, catalogRef, p, newVi);
        const newDir = try typedir.setCatalogRef(&w, dir, tid, newCatalog);
        w.setRoot(newDir);
        _ = try w.commit();
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
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: target type
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 }, .{ .kind = .linkSet, .linkTarget = 0 } }, // 1: source
        }, &.{ false, false });
        const a = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "A" } });
        dir = a.dir;
        const b = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .bytes = "B" } });
        dir = b.dir;
        dir = (try typeRouting.insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = a.objectKey }, .{ .linkSet = &.{ a.objectKey, b.objectKey } } })).dir;
        dir = (try typeRouting.insert(&w, dir, 1, &.{ .{ .int = 2 }, .{ .link = b.objectKey }, .{ .linkSet = &.{} } })).dir;
        // Churn: move source 1's to-one link, drop one set member.
        dir = try typeRouting.setLink(&w, dir, 1, 1, 1, b.objectKey);
        const sourceCatalog = try typedir.catalogRef(&w, dir, 1);
        const newCatalog = try links.linkSetRemove(&w, sourceCatalog, 1, 2, a.objectKey);
        dir = try typedir.setCatalogRef(&w, dir, 1, newCatalog);
        w.setRoot(dir);
        _ = try w.commit();
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
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } },
        }, &.{false});
        const a = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        dir = a.dir;
        targetObjectKey = a.objectKey;
        dir = (try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .link = targetObjectKey } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption

    // White-box corruption: drop the target's backlink entry while the source's
    // link column still points at it. Forward audit must flag the divergence.
    {
        var w = try database.beginWrite();
        const dir = database.activeRoot;
        const catalogRef = try typedir.catalogRef(&w, dir, 0);
        const cv = try catalog.loadCatalog(&w, catalogRef);
        const newBl = try Index.remove(&w, cv.backlinkRef(1), targetObjectKey);
        const newCatalog = try catalog.setBacklinkRef(&w, catalogRef, 1, newBl);
        const newDir = try typedir.setCatalogRef(&w, dir, 0, newCatalog);
        w.setRoot(newDir);
        _ = try w.commit();
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
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 50) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey * 3 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
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
        var i: usize = 0;
        while (i < opened) : (i += 1) instances[i].deinit();
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
    var a = try Database.create(testing.allocator, path);
    defer a.deinit();
    var b = try Database.open(testing.allocator, path);
    defer b.deinit();
    try testing.expectEqual(@as(u32, 2), a.coord.attachCount());
}

test "a second Database instance sees a commit made by the first after refresh-on-read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vis.airdb");
    defer testing.allocator.free(path);
    var a = try Database.create(testing.allocator, path);
    defer a.deinit();
    var b = try Database.open(testing.allocator, path);
    defer b.deinit();
    {
        var w = try a.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "SHARED!!");
        w.setRoot(x.ref);
        _ = try w.commit();
    }
    var r = try b.beginRead();
    try testing.expectEqualStrings("SHARED!!", try r.deref(r.root(), 8));
    r.end();
}

test "a second writer is excluded while the first holds the write lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "excl.airdb");
    defer testing.allocator.free(path);
    var a = try Database.create(testing.allocator, path);
    defer a.deinit();
    var b = try Database.open(testing.allocator, path);
    defer b.deinit();
    var wa = try a.beginWrite();
    try testing.expectError(error.WouldBlock, b.beginWriteTry());
    const x = try wa.alloc(8);
    @memcpy(x.bytes, "FIRST!!!");
    wa.setRoot(x.ref);
    _ = try wa.commit();
    var wb = try b.beginWriteTry();
    wb.deinit();
}

test "Database publishes its minimum pinned version to its participant slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pub.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "VERSION2");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No readers: this process publishes the sentinel (imposes no horizon constraint).
    try testing.expectEqual(coordMod.sentinelMax, database.coord.slotMinPinnedForTest(database.participantSlot.?));
    var r = try database.beginRead(); // pins the current version
    try testing.expectEqual(database.activeVersion, database.coord.slotMinPinnedForTest(database.participantSlot.?));
    r.end();
    try testing.expectEqual(coordMod.sentinelMax, database.coord.slotMinPinnedForTest(database.participantSlot.?));
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
        var w = try database.beginWrite();
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            const a = try w.alloc(4096);
            a.bytes[0] = @intCast(i & 0xff);
            lastRef = a.ref;
        }
        w.setRoot(lastRef);
        _ = try w.commit();
        try testing.expect(database.store.map.len > 4096 * 256);
    }
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        var r = try database.beginRead();
        const got = try r.deref(r.root(), 4096);
        try testing.expectEqual(@as(u8, @intCast(399 & 0xff)), got[0]);
        r.end();
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRST!!!");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No open reader: the oldest pinned version is the active version.
    try testing.expectEqual(database.activeVersion, database.oldestPinnedVersion());

    // Hold a reader at the current version, then commit a newer version.
    var r = try database.beginRead();
    {
        var w = try database.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "SECOND!!");
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    // The held reader pins the older version, below the new active version.
    try testing.expect(database.oldestPinnedVersion() < database.activeVersion);

    try testing.expectEqual(@as(u32, 1), database.attachedProcesses());
    try testing.expect(database.logicalSize() > 0);
    try testing.expect((try database.fileSize()) >= database.logicalSize());

    r.end();
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const oldRoot = database.activeRoot;
    {
        var w = try database.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(oldRoot, 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }

    const m = database.metrics();
    try testing.expect(m.mappedLen >= 4096 * 256);
    try testing.expectEqual(database.activeVersion, m.latestVersion);
    try testing.expect(m.freeExtentCount >= 1);
    try testing.expect(m.reclaimableBytes >= 8);
    try testing.expectEqual(database.activeVersion, m.oldestPinnedVersion); // no readers
    try testing.expect(!m.poisoned);
}

test "version->root ring records committed versions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ring.airdb");
    defer testing.allocator.free(path);

    const k: u64 = 5;
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        // Version 1 (the initial slot) was never written into the ring.
        try testing.expectEqual(@as(?u64, null), database.versionRoot(1));

        var i: u64 = 0;
        while (i < k) : (i += 1) {
            var w = try database.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "RINGDATA");
            w.setRoot(a.ref);
            _ = try w.commit();
        }

        // Each committed version (2..activeVersion) maps to a non-zero root.
        var v: u64 = 2;
        while (v <= database.activeVersion) : (v += 1) {
            const r = database.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
        }
        // A version that was never committed yet is null.
        try testing.expectEqual(@as(?u64, null), database.versionRoot(database.activeVersion + 1));
    }

    // The ring lives in the durable header page, so it survives reopen.
    {
        var database = try Database.open(testing.allocator, path);
        defer database.deinit();
        try testing.expectEqual(@as(u64, 1 + k), database.activeVersion);
        var v: u64 = 2;
        while (v <= database.activeVersion) : (v += 1) {
            const r = database.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
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
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "WRAPDATA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }

    const newest = database.activeVersion; // 1 + total
    const oldestLive = newest - @as(u64, ringCapacity) + 1;

    // The most recent ringCapacity versions are all present.
    try testing.expectEqual(oldestLive, database.oldestRetainedVersion());
    var v: u64 = oldestLive;
    while (v <= newest) : (v += 1) {
        const r = database.versionRoot(v) orelse return error.TestUnexpectedNull;
        try testing.expect(r != 0);
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

    var a = try Database.create(testing.allocator, path);
    defer a.deinit();
    {
        var w = try a.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "VERSION2");
        w.setRoot(x.ref);
        _ = try w.commit();
    }

    var b = try Database.open(testing.allocator, path);
    defer b.deinit();
    const bVersion = b.activeVersion;
    const bFlLen = b.freeListLenForTest();

    // a commits a version with a non-empty free list, then its node is
    // corrupted in the shared mapping so b's refresh decode must fail.
    {
        var w = try a.beginWrite();
        const oldRoot = a.activeRoot;
        const x = try w.alloc(8);
        @memcpy(x.bytes, "VERSION3");
        try w.free(oldRoot, 8);
        w.setRoot(x.ref);
        _ = try w.commit();
    }
    try testing.expect(a.freeListNodeRef != 0);
    const nodeOff: usize = @intCast(a.freeListNodeRef);
    // An absurd extent count makes the node length exceed the mapping.
    std.mem.writeInt(u32, a.store.map[nodeOff..][0..4], 0xFFFF_FFFF, .little);

    try testing.expectError(error.BadRef, b.beginRead());
    try testing.expectEqual(bVersion, b.activeVersion);
    try testing.expectEqual(bFlLen, b.freeListLenForTest());
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
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "BASELINE");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const vTarget = database.activeVersion + 1;

    // Aborted attempt at vTarget: the ring entry lands, the flush fails.
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "ABORTED!");
        w.setRoot(a.ref);
        try testing.expectError(error.Durability, w.commit());
    }

    // Retry commits vTarget for real with different data.
    {
        var w = try database.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "REALDATA");
        w.setRoot(a.ref);
        try testing.expectEqual(vTarget, try w.commit());
    }

    // The past-version read must resolve to the committed root.
    var r = try database.beginReadAt(vTarget);
    defer r.end();
    try testing.expectEqualStrings("REALDATA", try r.deref(r.root(), 8));
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
    var va: u64 = undefined;
    var vb: u64 = undefined;
    var vc: u64 = undefined;
    {
        var w = try database.beginWrite();
        var catalogRef = try catalog.create(&w, 2);
        catalogRef = (try rows.insert(&w, catalogRef, &.{ 1, 100 })).catalogRef;
        w.setRoot(catalogRef);
        va = try w.commit();
    }
    {
        var w = try database.beginWrite();
        const catalogRef = (try rows.insert(&w, w.newRoot, &.{ 2, 200 })).catalogRef;
        w.setRoot(catalogRef);
        vb = try w.commit();
    }
    {
        var w = try database.beginWrite();
        const catalogRef = (try rows.insert(&w, w.newRoot, &.{ 3, 300 })).catalogRef;
        w.setRoot(catalogRef);
        vc = try w.commit();
    }

    var out: [2]u64 = undefined;
    // Past snapshot at vA: only primaryKey 1 exists.
    {
        var r = try database.beginReadAt(va);
        defer r.end();
        try testing.expectEqual(@as(u64, 1), try compaction.liveCount(&r, r.root()));
        try testing.expect((try rows.getByPrimaryKey(&r, r.root(), 1, &out)) != null);
        try testing.expectEqual(@as(?u64, null), try rows.getByPrimaryKey(&r, r.root(), 2, &out));
    }
    // Past snapshot at vB: primaryKey 1 and 2.
    {
        var r = try database.beginReadAt(vb);
        defer r.end();
        try testing.expectEqual(@as(u64, 2), try compaction.liveCount(&r, r.root()));
    }
    // Latest: all three.
    {
        var r = try database.beginRead();
        defer r.end();
        try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, r.root()));
    }
    // A future version is unavailable.
    try testing.expectError(error.VersionUnavailable, database.beginReadAt(vc + 5));
}

test "the retention window is shared across instances and survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "retain_shared.airdb");
    defer testing.allocator.free(path);
    {
        var a = try Database.create(testing.allocator, path);
        defer a.deinit();
        var b = try Database.open(testing.allocator, path);
        defer b.deinit();
        // A raises the floor; B sees it immediately through the shared mapping.
        a.setRetainVersions(100);
        try testing.expectEqual(@as(u64, 100), b.retainVersions());
        // Make the header page durable via a commit.
        var w = try a.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "RETAINED");
        w.setRoot(x.ref);
        _ = try w.commit();
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
    var a = try Database.create(testing.allocator, path);
    defer a.deinit();
    var b = try Database.open(testing.allocator, path);
    defer b.deinit();
    // Instance a (the "reader" side) demands full retention; b never called
    // setRetainVersions and would previously reuse freed space immediately.
    a.setRetainVersions(std.math.maxInt(u64));

    // b commits a node, then frees it and commits again: with the shared floor
    // the freed extent must NOT be reused by b's next allocation.
    {
        var w = try b.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "AAAAAAAA");
        w.setRoot(x.ref);
        _ = try w.commit();
    }
    const oldRoot = b.activeRoot;
    {
        var w = try b.beginWrite();
        const y = try w.alloc(8);
        @memcpy(y.bytes, "BBBBBBBB");
        try w.free(oldRoot, 8);
        w.setRoot(y.ref);
        _ = try w.commit();
    }
    {
        var w = try b.beginWrite();
        const z = try w.alloc(8);
        // Without the shared window this allocation reused oldRoot.
        try testing.expect(z.ref != oldRoot);
        w.deinit();
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
    var va: u64 = undefined;
    {
        var w = try database.beginWrite();
        var catalogRef = try catalog.create(&w, 2);
        catalogRef = (try rows.insert(&w, catalogRef, &.{ 1, 100 })).catalogRef;
        w.setRoot(catalogRef);
        va = try w.commit();
    }
    {
        var w = try database.beginWrite();
        const catalogRef = (try rows.insert(&w, w.newRoot, &.{ 2, 200 })).catalogRef;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }
    // vA is older than active - retainVersions(0) -> aged out.
    try testing.expectError(error.VersionUnavailable, database.beginReadAt(va));
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
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Seed the live set (primaryKeys [0, live)).
    var hi: u64 = 0;
    {
        var w = try database.beginWrite();
        var dir = database.activeRoot;
        while (hi < live) : (hi += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = hi }, .{ .int = hi } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    var lo: u64 = 0;
    var iter: u64 = 0;
    while (iter < iters) : (iter += 1) {
        {
            var w = try database.beginWrite();
            var dir = database.activeRoot;
            // Insert `live` fresh rows.
            var k: u64 = 0;
            while (k < live) : (k += 1) {
                dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = hi }, .{ .int = hi } })).dir;
                hi += 1;
            }
            // Delete the `live` oldest live rows.
            k = 0;
            while (k < live) : (k += 1) {
                var out: [2]catalog.Value = undefined;
                const version = (try typeRouting.get(&w, dir, tid, lo, &out)).?;
                dir = switch (try typeRouting.delete(&w, dir, tid, lo, version)) {
                    .ok => |d| d,
                    else => unreachable,
                };
                lo += 1;
            }
            w.setRoot(dir);
            _ = try w.commit();
        }
        // Opt-in: drive the incremental step loop so the type stays packed.
        if (database.autoCompact) {
            while (true) {
                const res = try maintenance.maybeCompactStep(&database, tid, 4);
                if (!res.ran or res.done) break;
            }
        }
    }

    var r = try database.beginRead();
    defer r.end();
    const catalogRef = try typedir.catalogRef(&r, r.root(), tid);
    return .{
        .nextRow = (try catalog.loadCatalog(&r, catalogRef)).nextRow,
        .live = try compaction.liveCount(&r, catalogRef),
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
            var w = try database.beginWrite();
            errdefer w.deinit();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "POISON!!");
            w.setRoot(a.ref);
            try testing.expectError(error.Durability, w.commit());
        }
        try testing.expectError(error.CommitIndeterminate, database.beginWrite());
        try testing.expect(database.metrics().poisoned);
    }
    // Reopen resolves the header and writes flow again.
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "RESOLVED");
    w.setRoot(a.ref);
    _ = try w.commit();
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
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var w = try database.beginWrite();
        var dir = database.activeRoot;
        var primaryKey: u64 = 0;
        while (primaryKey < 10) : (primaryKey += 1) dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        var out: [2]catalog.Value = undefined;
        primaryKey = 0;
        while (primaryKey < 8) : (primaryKey += 1) {
            const version = (try typeRouting.get(&w, dir, tid, primaryKey, &out)).?;
            dir = switch (try typeRouting.delete(&w, dir, tid, primaryKey, version)) {
                .ok => |d| d,
                else => unreachable,
            };
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // The compaction step's commit fails its data barrier.
    try testing.expectError(error.Durability, maintenance.maybeCompactStep(&database, tid, 100));

    // The write lock must be free and the data intact.
    var w = try database.beginWriteTry();
    w.deinit();
    var r = try database.beginRead();
    defer r.end();
    try testing.expectEqual(@as(u64, 2), try typeRouting.liveCount(&r, r.root(), tid));
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
        var w = try database.beginWrite();
        const dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .int } },
            &.{ .{ .kind = .int }, .{ .kind = .int } },
        }, &.{ false, false });
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var w = try database.beginWrite();
        var dir = database.activeRoot;
        var t: u16 = 0;
        while (t < 2) : (t += 1) {
            var primaryKey: u64 = 0;
            while (primaryKey < 12) : (primaryKey += 1) dir = (try typeRouting.insert(&w, dir, t, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
            var out: [2]catalog.Value = undefined;
            primaryKey = 0;
            while (primaryKey < 8) : (primaryKey += 1) {
                const version = (try typeRouting.get(&w, dir, t, primaryKey, &out)).?;
                dir = switch (try typeRouting.delete(&w, dir, t, primaryKey, version)) {
                    .ok => |d| d,
                    else => unreachable,
                };
            }
            w.setRoot(dir);
        }
        _ = try w.commit();
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
    var r = try database.beginRead();
    defer r.end();
    var t: u16 = 0;
    while (t < 2) : (t += 1) {
        try testing.expectEqual(@as(u64, 4), try typeRouting.liveCount(&r, r.root(), t));
        var out: [2]catalog.Value = undefined;
        var primaryKey: u64 = 8;
        while (primaryKey < 12) : (primaryKey += 1) {
            try testing.expect((try typeRouting.get(&r, r.root(), t, primaryKey, &out)) != null);
        }
        const catalogRef = try typedir.catalogRef(&r, r.root(), t);
        try testing.expectEqual(@as(u64, 4), (try catalog.loadCatalog(&r, catalogRef)).nextRow);
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
            var w = try database.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "AAAAAAAA");
            w.setRoot(a.ref);
            _ = try w.commit();
        }
        const oldRoot = database.activeRoot;
        {
            var w = try database.beginWrite();
            const b = try w.alloc(8);
            @memcpy(b.bytes, "BBBBBBBB");
            try w.free(oldRoot, 8);
            w.setRoot(b.ref);
            _ = try w.commit();
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
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 3) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    const res = try maintenance.maybeCompactStep(&database, tid, 4);
    try testing.expect(!res.ran);
    try testing.expectEqual(@as(usize, 0), res.moved);
    try testing.expect(!res.done);

    // The type is untouched: all three rows remain live and packed.
    var r = try database.beginRead();
    defer r.end();
    const catalogRef = try typedir.catalogRef(&r, r.root(), tid);
    try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, catalogRef));
    try testing.expectEqual(@as(u64, 3), (try catalog.loadCatalog(&r, catalogRef)).nextRow);
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
        var w = try database.beginWrite();
        for (refs) |*r| r.* = (try w.alloc(8)).ref;
        const root = try w.alloc(8);
        @memcpy(root.bytes, "CHUNKED!");
        w.setRoot(root.ref);
        _ = try w.commit();
    }
    {
        var w = try database.beginWrite();
        for (refs) |r| try w.free(r, 8);
        const root = try w.alloc(8);
        @memcpy(root.bytes, "CHUNKED2");
        w.setRoot(root.ref);
        _ = try w.commit();
    }
    try testing.expect(database.freeListLenForTest() >= nExtents);
    database.deinit();

    var database2 = try Database.open(testing.allocator, path);
    defer database2.deinit();
    try testing.expect(database2.freeListLenForTest() >= nExtents);
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
            var w = try database.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "CYCLBASE");
            w.setRoot(a.ref);
            _ = try w.commit();
        }
        const oldRoot = database.activeRoot;
        {
            var w = try database.beginWrite();
            const b = try w.alloc(8);
            @memcpy(b.bytes, "CYCLNEXT");
            try w.free(oldRoot, 8);
            w.setRoot(b.ref);
            _ = try w.commit();
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
