const std = @import("std");
const verification = @import("verification.zig");
const maintenance = @import("maintenance.zig");
const testing = std.testing;
const Io = std.Io;
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const ring_capacity = db_mod.ring_capacity;
const Ref = @import("ref.zig").Ref;
const FreeList = @import("freelist.zig").FreeList;
const coord_mod = @import("coord.zig");
const typedir = @import("typedir.zig");
const typeRouting = @import("typeRouting.zig");
const compaction = @import("compaction.zig");
const catalog = @import("catalog.zig");
const Index = @import("index.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    return std.fs.path.join(allocator, &.{ dir_path, name });
}

test "commit then reopen sees the committed root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "db.airdb");
    defer testing.allocator.free(path);

    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "HELLOAID");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        const root_ref = r.root();
        try testing.expect(root_ref != 0);
        const bytes = try r.deref(root_ref, 8);
        try testing.expectEqualStrings("HELLOAID", bytes);
    }
}

test "ending a read transaction twice does not release another reader's pin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "doubleend.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "PINDATA_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    var r1 = try db.beginRead();
    var r2 = try db.beginRead(); // same version, pin count 2
    const v = r1.version;
    r1.end();
    r1.end(); // must be a no-op, not a second decrement
    try testing.expectEqual(@as(u32, 1), db.pins.get(v).?); // r2 still pinned
    try testing.expectEqual(v, db.horizon());
    r2.end();
    try testing.expectEqual(db.active_version, db.horizon());
}

test "version horizon tracks the oldest live reader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "horizon.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    try testing.expectEqual(db.active_version, db.horizon());

    var r1 = try db.beginRead();
    const v = db.active_version;
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "NEWDATA_");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    try testing.expectEqual(v, db.horizon()); // r1 still pinned at v
    r1.end();
    try testing.expectEqual(db.active_version, db.horizon());
}

test "free list persists across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "fl.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRSTVAL");
        const b = try w.writableCopy(a.ref, 8); // frees the old node at this version
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expect(db.freeListLenForTest() >= 1);
    }
}

test "verifyIntegrity passes on a freshly committed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    try verification.verifyIntegrity(&db); // void on clean db
}

test "verifyIntegrity detects a root reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.active_root = db.store.map.len + 8; // point past the mapped region
    try testing.expectError(error.RootRefOutOfBounds, verification.verifyIntegrity(&db));
}

test "verifyIntegrity detects a corrupt header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_hdr.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.store.header_checksum_ok = false; // simulate an unreadable header
    try testing.expectError(error.HeaderCorrupt, verification.verifyIntegrity(&db));
}

test "verifyIntegrity detects a free-list node reference out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_fln.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    db.free_list_node_ref = @intCast(db.store.map.len + 8); // past the mapped region (8-aligned)
    db.free_list_node_len = 16;
    try testing.expectError(error.FreeListCorrupt, verification.verifyIntegrity(&db));
}

test "verifyIntegrity detects a free extent out of bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_ext.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "INTEGER_");
    w.setRoot(a.ref);
    _ = try w.commit();
    // Inject an extent whose offset is past the mapped region.
    try db.free_list.extents.append(db.store.allocator, .{ .offset = @intCast(db.store.map.len + 8), .len = 8, .freed_version = 1 });
    try testing.expectError(error.FreeExtentOutOfBounds, verification.verifyIntegrity(&db));
}

test "verifyIntegrity passes after churn on an indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_idx_churn.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    const tid: u16 = 0;

    // One type: int pk + one indexed int property.
    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Seed 200 rows; value = pk % 16 so many rows share each inner set.
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
        var pk: u64 = 0;
        while (pk < 200) : (pk += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk % 16 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Churn: update the value of every even pk, delete every 5th pk.
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
        var pk: u64 = 0;
        while (pk < 200) : (pk += 1) {
            var out: [2]catalog.Value = undefined;
            const ver = (try typeRouting.get(&w, dir, tid, pk, &out)).?;
            if (pk % 5 == 0) {
                dir = switch (try typeRouting.delete(&w, dir, tid, pk, ver)) {
                    .ok => |d| d,
                    else => unreachable,
                };
            } else if (pk % 2 == 0) {
                const ur = try typeRouting.update(&w, dir, tid, pk, &.{ .{ .int = pk }, .{ .int = (pk + 7) % 16 } }, ver);
                dir = ur.ok.dir;
            }
        }
        // Insert a fresh batch with reused values.
        while (pk < 260) : (pk += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk % 16 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    try verification.verifyIntegrity(&db); // forward + backward audit must find no divergence
}

test "verifyIntegrity detects a corrupted value index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_idx_corrupt.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    const tid: u16 = 0;
    const p: usize = 1; // the indexed property

    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
        var pk: u64 = 0;
        while (pk < 8) : (pk += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&db); // clean before corruption

    // White-box corruption: register an existing live okey under a value that no
    // row actually has. The forward direction still holds (every row stays
    // covered), so this exercises the backward check: the bogus entry resolves to
    // a live row whose property value differs from the indexed value.
    {
        var w = try db.beginWrite();
        const dir = db.active_root;
        const cat = try typedir.catalogRef(&w, dir, tid);
        const cv = try catalog.loadCatalog(&w, cat);
        const okey = (try catalog.pkToOkey(&w, cat, 0)).?; // row pk 0 has value 0
        const bogus_value: u64 = 999_999; // no row carries this value
        var set_root = try Index.create(&w);
        set_root = try Index.insert(&w, set_root, okey, 1);
        const new_vi = try Index.insert(&w, cv.valueIndexRef(p), bogus_value, set_root);
        const new_cat = try catalog.setValueIndexRef(&w, cat, p, new_vi);
        const new_dir = try typedir.setCatalogRef(&w, dir, tid, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
    }

    try testing.expectError(error.ValueIndexStaleEntry, verification.verifyIntegrity(&db));
}

test "verifyIntegrity passes on a clean link graph after churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_bl_clean.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    const links = @import("links.zig");

    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: target type
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 }, .{ .kind = .link_set, .link_target = 0 } }, // 1: source
        }, &.{ false, false });
        const a = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "A" } });
        dir = a.dir;
        const b = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .bytes = "B" } });
        dir = b.dir;
        dir = (try typeRouting.insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .link = a.row }, .{ .link_set = &.{ a.row, b.row } } })).dir;
        dir = (try typeRouting.insert(&w, dir, 1, &.{ .{ .int = 2 }, .{ .link = b.row }, .{ .link_set = &.{} } })).dir;
        // Churn: move source 1's to-one link, drop one set member.
        dir = try typeRouting.setLink(&w, dir, 1, 1, 1, b.row);
        const src_cat = try typedir.catalogRef(&w, dir, 1);
        const new_cat = try links.linkSetRemove(&w, src_cat, 1, 2, a.row);
        dir = try typedir.setCatalogRef(&w, dir, 1, new_cat);
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&db); // forward + backward backlink audit finds no divergence
}

test "verifyIntegrity detects a corrupted backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_bl_corrupt.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var target_okey: u64 = undefined;

    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } },
        }, &.{false});
        const a = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .link = null } });
        dir = a.dir;
        target_okey = a.row;
        dir = (try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .link = target_okey } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }
    try verification.verifyIntegrity(&db); // clean before corruption

    // White-box corruption: drop the target's backlink entry while the source's
    // link column still points at it. Forward audit must flag the divergence.
    {
        var w = try db.beginWrite();
        const dir = db.active_root;
        const cat = try typedir.catalogRef(&w, dir, 0);
        const cv = try catalog.loadCatalog(&w, cat);
        const new_bl = try Index.remove(&w, cv.backlinkRef(1), target_okey);
        const new_cat = try catalog.setBacklinkRef(&w, cat, 1, new_bl);
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
    }
    try testing.expectError(error.BacklinkMissingEntry, verification.verifyIntegrity(&db));
}

test "verifyIntegrity passes on a non-indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_noidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    const tid: u16 = 0;

    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var pk: u64 = 0;
        while (pk < 50) : (pk += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk * 3 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    try verification.verifyIntegrity(&db); // no indexed prop -> audit must not false-positive
}

test "the 65th attach is refused rather than reading with invisible pins" {
    // A Db without a participant slot cannot advertise its reader pins, so
    // concurrent writers would reclaim under its snapshots. open/create now
    // refuse the attach outright.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "slots64.airdb");
    defer testing.allocator.free(path);

    var instances: [64]Db = undefined;
    var opened: usize = 0;
    defer {
        var i: usize = 0;
        while (i < opened) : (i += 1) instances[i].deinit();
    }
    instances[0] = try Db.create(testing.allocator, path);
    opened = 1;
    while (opened < 64) : (opened += 1) {
        instances[opened] = try Db.open(testing.allocator, path);
    }
    try testing.expectError(error.TooManyAttachments, Db.open(testing.allocator, path));
}

test "two Db instances on one file share a coordination attach count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "share.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
    defer b.deinit();
    try testing.expectEqual(@as(u32, 2), a.coord.attachCount());
}

test "a second Db instance sees a commit made by the first after refresh-on-read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vis.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
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
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
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

test "Db publishes its minimum pinned version to its participant slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pub.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "VERSION2");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No readers: this process publishes the sentinel (imposes no horizon constraint).
    try testing.expectEqual(coord_mod.sentinel_max, db.coord.slotMinPinnedForTest(db.participant_slot.?));
    var r = try db.beginRead(); // pins the current version
    try testing.expectEqual(db.active_version, db.coord.slotMinPinnedForTest(db.participant_slot.?));
    r.end();
    try testing.expectEqual(coord_mod.sentinel_max, db.coord.slotMinPinnedForTest(db.participant_slot.?));
}

test "allocations beyond the initial mapping grow the file and data survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "biggrow.airdb");
    defer testing.allocator.free(path);
    var last_ref: Ref = 0;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            const a = try w.alloc(4096);
            a.bytes[0] = @intCast(i & 0xff);
            last_ref = a.ref;
        }
        w.setRoot(last_ref);
        _ = try w.commit();
        try testing.expect(db.store.map.len > 4096 * 256);
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // First write+commit advances active_version.
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "FIRST!!!");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    // No open reader: the oldest pinned version is the active version.
    try testing.expectEqual(db.active_version, db.oldestPinnedVersion());

    // Hold a reader at the current version, then commit a newer version.
    var r = try db.beginRead();
    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "SECOND!!");
        w.setRoot(b.ref);
        _ = try w.commit();
    }
    // The held reader pins the older version, below the new active version.
    try testing.expect(db.oldestPinnedVersion() < db.active_version);

    try testing.expectEqual(@as(u32, 1), db.attachedProcesses());
    try testing.expect(db.logicalSize() > 0);
    try testing.expect((try db.fileSize()) >= db.logicalSize());

    r.end();
    try testing.expectEqual(db.active_version, db.oldestPinnedVersion());
}

test "metrics report mapped length, versions, and reclaimable bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "metrics.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const old_root = db.active_root;
    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(old_root, 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }

    const m = db.metrics();
    try testing.expect(m.mapped_len >= 4096 * 256);
    try testing.expectEqual(db.active_version, m.latest_version);
    try testing.expect(m.free_extent_count >= 1);
    try testing.expect(m.reclaimable_bytes >= 8);
    try testing.expectEqual(db.active_version, m.oldest_pinned_version); // no readers
    try testing.expect(!m.poisoned);
}

test "version->root ring records committed versions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ring.airdb");
    defer testing.allocator.free(path);

    const k: u64 = 5;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        // Version 1 (the initial slot) was never written into the ring.
        try testing.expectEqual(@as(?u64, null), db.versionRoot(1));

        var i: u64 = 0;
        while (i < k) : (i += 1) {
            var w = try db.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "RINGDATA");
            w.setRoot(a.ref);
            _ = try w.commit();
        }

        // Each committed version (2..active_version) maps to a non-zero root.
        var v: u64 = 2;
        while (v <= db.active_version) : (v += 1) {
            const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
        }
        // A version that was never committed yet is null.
        try testing.expectEqual(@as(?u64, null), db.versionRoot(db.active_version + 1));
    }

    // The ring lives in the durable header page, so it survives reopen.
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expectEqual(@as(u64, 1 + k), db.active_version);
        var v: u64 = 2;
        while (v <= db.active_version) : (v += 1) {
            const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
            try testing.expect(r != 0);
        }
    }
}

test "ring wraps after capacity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ringwrap.airdb");
    defer testing.allocator.free(path);

    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Commit more than ring_capacity times so the ring wraps and evicts old entries.
    const total: u64 = @as(u64, ring_capacity) + 12;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "WRAPDATA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }

    const newest = db.active_version; // 1 + total
    const oldest_live = newest - @as(u64, ring_capacity) + 1;

    // The most recent ring_capacity versions are all present.
    try testing.expectEqual(oldest_live, db.oldestRetainedVersion());
    var v: u64 = oldest_live;
    while (v <= newest) : (v += 1) {
        const r = db.versionRoot(v) orelse return error.TestUnexpectedNull;
        try testing.expect(r != 0);
    }

    // Versions older than the live window were evicted.
    try testing.expectEqual(@as(?u64, null), db.versionRoot(oldest_live - 1));
    try testing.expectEqual(@as(?u64, null), db.versionRoot(2));
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

    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    {
        var w = try a.beginWrite();
        const x = try w.alloc(8);
        @memcpy(x.bytes, "VERSION2");
        w.setRoot(x.ref);
        _ = try w.commit();
    }

    var b = try Db.open(testing.allocator, path);
    defer b.deinit();
    const b_version = b.active_version;
    const b_fl_len = b.freeListLenForTest();

    // a commits a version with a non-empty free list, then its node is
    // corrupted in the shared mapping so b's refresh decode must fail.
    {
        var w = try a.beginWrite();
        const old_root = a.active_root;
        const x = try w.alloc(8);
        @memcpy(x.bytes, "VERSION3");
        try w.free(old_root, 8);
        w.setRoot(x.ref);
        _ = try w.commit();
    }
    try testing.expect(a.free_list_node_ref != 0);
    const node_off: usize = @intCast(a.free_list_node_ref);
    // An absurd extent count makes the node length exceed the mapping.
    std.mem.writeInt(u32, a.store.map[node_off..][0..4], 0xFFFF_FFFF, .little);

    try testing.expectError(error.BadRef, b.beginRead());
    try testing.expectEqual(b_version, b.active_version);
    try testing.expectEqual(b_fl_len, b.freeListLenForTest());
}

test "a retried commit's ring entry wins over the aborted duplicate" {
    // A commit that fails its data barrier leaves its (version, root) ring entry
    // behind; the retry reuses the same version number and appends a second
    // entry. versionRoot must return the retry's root (the committed one), not
    // the aborted duplicate, or beginReadAt would expose never-committed data.
    const FailingSyncer = @import("syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "ringdup.airdb");
    defer testing.allocator.free(path);

    // Flush sequence: create=2 flushes, first commit=2, so the second commit's
    // data barrier is flush #5.
    var fsync = FailingSyncer{ .fail_on = 5 };
    var db = try Db.createWith(testing.allocator, path, fsync.any());
    defer db.deinit();
    db.setRetainVersions(std.math.maxInt(u64));

    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "BASELINE");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    const v_target = db.active_version + 1;

    // Aborted attempt at v_target: the ring entry lands, the flush fails.
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "ABORTED!");
        w.setRoot(a.ref);
        try testing.expectError(error.Durability, w.commit());
    }

    // Retry commits v_target for real with different data.
    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "REALDATA");
        w.setRoot(a.ref);
        try testing.expectEqual(v_target, try w.commit());
    }

    // The past-version read must resolve to the committed root.
    var r = try db.beginReadAt(v_target);
    defer r.end();
    try testing.expectEqualStrings("REALDATA", try r.deref(r.root(), 8));
}

test "beginReadAt opens a past version within the retention window" {
    const rows = @import("rows.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    db.setRetainVersions(std.math.maxInt(u64)); // retain everything

    // v_a: pk 1 ; v_b: + pk 2 ; v_c: + pk 3 (additive, so each version's live set differs)
    var va: u64 = undefined;
    var vb: u64 = undefined;
    var vc: u64 = undefined;
    {
        var w = try db.beginWrite();
        var cat = try catalog.create(&w, 2);
        cat = (try rows.insert(&w, cat, &.{ 1, 100 })).cat;
        w.setRoot(cat);
        va = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try rows.insert(&w, w.new_root, &.{ 2, 200 })).cat;
        w.setRoot(cat);
        vb = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try rows.insert(&w, w.new_root, &.{ 3, 300 })).cat;
        w.setRoot(cat);
        vc = try w.commit();
    }

    var out: [2]u64 = undefined;
    // Past snapshot at v_a: only pk 1 exists.
    {
        var r = try db.beginReadAt(va);
        defer r.end();
        try testing.expectEqual(@as(u64, 1), try compaction.liveCount(&r, r.root()));
        try testing.expect((try rows.getByPk(&r, r.root(), 1, &out)) != null);
        try testing.expectEqual(@as(?u64, null), try rows.getByPk(&r, r.root(), 2, &out));
    }
    // Past snapshot at v_b: pk 1 and 2.
    {
        var r = try db.beginReadAt(vb);
        defer r.end();
        try testing.expectEqual(@as(u64, 2), try compaction.liveCount(&r, r.root()));
    }
    // Latest: all three.
    {
        var r = try db.beginRead();
        defer r.end();
        try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, r.root()));
    }
    // A future version is unavailable.
    try testing.expectError(error.VersionUnavailable, db.beginReadAt(vc + 5));
}

test "the retention window is shared across instances and survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "retain_shared.airdb");
    defer testing.allocator.free(path);
    {
        var a = try Db.create(testing.allocator, path);
        defer a.deinit();
        var b = try Db.open(testing.allocator, path);
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
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        try testing.expectEqual(@as(u64, 100), db.retainVersions());
    }
}

test "a writer honors a retention floor raised by another instance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "retain_writer.airdb");
    defer testing.allocator.free(path);
    var a = try Db.create(testing.allocator, path);
    defer a.deinit();
    var b = try Db.open(testing.allocator, path);
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
    const old_root = b.active_root;
    {
        var w = try b.beginWrite();
        const y = try w.alloc(8);
        @memcpy(y.bytes, "BBBBBBBB");
        try w.free(old_root, 8);
        w.setRoot(y.ref);
        _ = try w.commit();
    }
    {
        var w = try b.beginWrite();
        const z = try w.alloc(8);
        // Without the shared window this allocation reused old_root.
        try testing.expect(z.ref != old_root);
        w.deinit();
    }
}

test "beginReadAt rejects a version aged out of the retention window" {
    const rows = @import("rows.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "pit2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    // retain_versions defaults to 0: only the active version is readable.
    var va: u64 = undefined;
    {
        var w = try db.beginWrite();
        var cat = try catalog.create(&w, 2);
        cat = (try rows.insert(&w, cat, &.{ 1, 100 })).cat;
        w.setRoot(cat);
        va = try w.commit();
    }
    {
        var w = try db.beginWrite();
        const cat = (try rows.insert(&w, w.new_root, &.{ 2, 200 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    // v_a is older than active - retain_versions(0) -> aged out.
    try testing.expectError(error.VersionUnavailable, db.beginReadAt(va));
    try testing.expect(db.oldestReadableVersion() == db.active_version);
}

// Churn a single int-pk type at `path` with a steady live set: seed `live`
// rows, then on each iteration insert `live` fresh rows and delete the `live`
// oldest live rows (net-zero live count). Dead rows accumulate, so next_row
// grows without bound unless compaction reclaims it. When `auto` is set, the
// caller drives maybeCompactStep after each iteration until the type is packed.
// Returns the final next_row (physical row high-water) and live count.
fn churnNetZero(path: []const u8, live: u64, iters: u64, auto: bool) !struct { next_row: u64, live: u64 } {
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    db.auto_compact = auto;
    const tid: u16 = 0;

    // Single type: int pk + one int prop.
    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Seed the live set (pks [0, live)).
    var hi: u64 = 0;
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
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
            var w = try db.beginWrite();
            var dir = db.active_root;
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
                const ver = (try typeRouting.get(&w, dir, tid, lo, &out)).?;
                dir = switch (try typeRouting.delete(&w, dir, tid, lo, ver)) {
                    .ok => |d| d,
                    else => unreachable,
                };
                lo += 1;
            }
            w.setRoot(dir);
            _ = try w.commit();
        }
        // Opt-in: drive the incremental step loop so the type stays packed.
        if (db.auto_compact) {
            while (true) {
                const res = try maintenance.maybeCompactStep(&db, tid, 4);
                if (!res.ran or res.done) break;
            }
        }
    }

    var r = try db.beginRead();
    defer r.end();
    const cat = try typedir.catalogRef(&r, r.root(), tid);
    return .{
        .next_row = (try catalog.loadCatalog(&r, cat)).next_row,
        .live = try compaction.liveCount(&r, cat),
    };
}

test "a failed commit-point flush poisons the instance until reopen" {
    // The flipped header pointer sits in the mapped page before the failed
    // barrier, so its on-disk fate is indeterminate; further writes from this
    // instance could scribble the maybe-published version. Reopen resolves.
    const FailingSyncer = @import("syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "poison.airdb");
    defer testing.allocator.free(path);

    // create = 2 flushes; the first commit's data barrier is #3 and its
    // HEADER flush (the commit point) is #4.
    var fsync = FailingSyncer{ .fail_on = 4 };
    {
        var db = try Db.createWith(testing.allocator, path, fsync.any());
        defer db.deinit();
        {
            var w = try db.beginWrite();
            errdefer w.deinit();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "POISON!!");
            w.setRoot(a.ref);
            try testing.expectError(error.Durability, w.commit());
        }
        try testing.expectError(error.CommitIndeterminate, db.beginWrite());
        try testing.expect(db.metrics().poisoned);
    }
    // Reopen resolves the header and writes flow again.
    var db = try Db.open(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const a = try w.alloc(8);
    @memcpy(a.bytes, "RESOLVED");
    w.setRoot(a.ref);
    _ = try w.commit();
}

test "a failed commit inside maybeCompactStep neither crashes nor wedges the write lock" {
    // Regression for the commit error contract: maybeCompactStep holds
    // `errdefer w.deinit()` across commit. Commit used to deinit the txn's
    // lists itself on error, so the errdefer double-freed them (heap
    // corruption); and non-durability commit errors leaked the cross-process
    // write lock. Commit now concludes uniformly and deinit is a no-op after.
    const FailingSyncer = @import("syncer.zig").FailingSyncer;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "compactfail.airdb");
    defer testing.allocator.free(path);

    // Flushes: create = 2, type commit = 2, churn commit = 2 -> the compact
    // step's data barrier is flush #7.
    var fsync = FailingSyncer{ .fail_on = 7 };
    var db = try Db.createWith(testing.allocator, path, fsync.any());
    defer db.deinit();
    const tid: u16 = 0;
    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
        var pk: u64 = 0;
        while (pk < 10) : (pk += 1) dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk } })).dir;
        var out: [2]catalog.Value = undefined;
        pk = 0;
        while (pk < 8) : (pk += 1) {
            const ver = (try typeRouting.get(&w, dir, tid, pk, &out)).?;
            dir = switch (try typeRouting.delete(&w, dir, tid, pk, ver)) {
                .ok => |d| d,
                else => unreachable,
            };
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // The compaction step's commit fails its data barrier.
    try testing.expectError(error.Durability, maintenance.maybeCompactStep(&db, tid, 100));

    // The write lock must be free and the data intact.
    var w = try db.beginWriteTry();
    w.deinit();
    var r = try db.beginRead();
    defer r.end();
    try testing.expectEqual(@as(u64, 2), try typeRouting.liveCount(&r, r.root(), tid));
}

test "the compaction cursor never resumes across types" {
    // Regression: the cursor was keyed only on (live_count, next_row), which
    // two different types can share. Resuming type A's high-water cursor while
    // stepping type B left B's tail unexamined and the final truncate would
    // have dropped live rows. The cursor now also pins the exact catalog ref.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cursor_types.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    // Two identically shaped types with identical churn: both end with
    // live=4, next_row=12 and dead tails.
    {
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .int } },
            &.{ .{ .kind = .int }, .{ .kind = .int } },
        }, &.{ false, false });
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var w = try db.beginWrite();
        var dir = db.active_root;
        var t: u16 = 0;
        while (t < 2) : (t += 1) {
            var pk: u64 = 0;
            while (pk < 12) : (pk += 1) dir = (try typeRouting.insert(&w, dir, t, &.{ .{ .int = pk }, .{ .int = pk } })).dir;
            var out: [2]catalog.Value = undefined;
            pk = 0;
            while (pk < 8) : (pk += 1) {
                const ver = (try typeRouting.get(&w, dir, t, pk, &out)).?;
                dir = switch (try typeRouting.delete(&w, dir, t, pk, ver)) {
                    .ok => |d| d,
                    else => unreachable,
                };
            }
            w.setRoot(dir);
        }
        _ = try w.commit();
    }

    // Partial step on type 0 persists a cursor; type 1 must NOT resume it.
    _ = try maintenance.maybeCompactStep(&db, 0, 1);
    while (true) {
        const res = try maintenance.maybeCompactStep(&db, 1, 2);
        if (!res.ran or res.done) break;
    }
    while (true) {
        const res = try maintenance.maybeCompactStep(&db, 0, 2);
        if (!res.ran or res.done) break;
    }

    // Every surviving row of both types is intact and both are fully packed.
    var r = try db.beginRead();
    defer r.end();
    var t: u16 = 0;
    while (t < 2) : (t += 1) {
        try testing.expectEqual(@as(u64, 4), try typeRouting.liveCount(&r, r.root(), t));
        var out: [2]catalog.Value = undefined;
        var pk: u64 = 8;
        while (pk < 12) : (pk += 1) {
            try testing.expect((try typeRouting.get(&r, r.root(), t, pk, &out)) != null);
        }
        const cat = try typedir.catalogRef(&r, r.root(), t);
        try testing.expectEqual(@as(u64, 4), (try catalog.loadCatalog(&r, cat)).next_row);
    }
}

test "a corrupt persisted free-list extent fails open instead of poisoning reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "flcorrupt.airdb");
    defer testing.allocator.free(path);
    var node_ref: Ref = 0;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        {
            var w = try db.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "AAAAAAAA");
            w.setRoot(a.ref);
            _ = try w.commit();
        }
        const old_root = db.active_root;
        {
            var w = try db.beginWrite();
            const b = try w.alloc(8);
            @memcpy(b.bytes, "BBBBBBBB");
            try w.free(old_root, 8);
            w.setRoot(b.ref);
            _ = try w.commit();
        }
        node_ref = db.free_list_node_ref;
        try testing.expect(node_ref != 0);
        // Corrupt the first extent's offset into something misaligned.
        const off: usize = @intCast(node_ref);
        std.mem.writeInt(u64, db.store.map[off + 12 ..][0..8], 12345, .little); // % 8 != 0
        try db.store.syncer.flush(db.store.file);
    }
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, path));
}

test "maybeCompactStep bounds dead rows under churn" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const off_path = try tmpFilePath(testing.allocator, &tmp, "churnoff.airdb");
    defer testing.allocator.free(off_path);
    const on_path = try tmpFilePath(testing.allocator, &tmp, "churnon.airdb");
    defer testing.allocator.free(on_path);

    // Identical churn, run twice: without auto-compaction, then with it.
    const without = try churnNetZero(off_path, 10, 40, false);
    const with = try churnNetZero(on_path, 10, 40, true);

    // Live data is preserved identically in both runs.
    try testing.expectEqual(without.live, with.live);
    // Compaction reclaims the dead-row space: the physical high-water is strictly
    // smaller when the step loop runs.
    try testing.expect(with.next_row < without.next_row);
}

test "maybeCompactStep is a no-op when nothing to compact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "nocompact.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    const tid: u16 = 0;
    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{ .{ .kind = .int }, .{ .kind = .int } }}, &.{false});
        var pk: u64 = 0;
        while (pk < 3) : (pk += 1) {
            dir = (try typeRouting.insert(&w, dir, tid, &.{ .{ .int = pk }, .{ .int = pk } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    const res = try maintenance.maybeCompactStep(&db, tid, 4);
    try testing.expect(!res.ran);
    try testing.expectEqual(@as(usize, 0), res.moved);
    try testing.expect(!res.done);

    // The type is untouched: all three rows remain live and packed.
    var r = try db.beginRead();
    defer r.end();
    const cat = try typedir.catalogRef(&r, r.root(), tid);
    try testing.expectEqual(@as(u64, 3), try compaction.liveCount(&r, cat));
    try testing.expectEqual(@as(u64, 3), (try catalog.loadCatalog(&r, cat)).next_row);
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
    var db = try Db.create(testing.allocator, path);
    errdefer db.deinit();

    const n_extents = FreeList.chunk_extent_cap + 500;
    const refs = try testing.allocator.alloc(u64, n_extents);
    defer testing.allocator.free(refs);
    {
        var w = try db.beginWrite();
        for (refs) |*r| r.* = (try w.alloc(8)).ref;
        const root = try w.alloc(8);
        @memcpy(root.bytes, "CHUNKED!");
        w.setRoot(root.ref);
        _ = try w.commit();
    }
    {
        var w = try db.beginWrite();
        for (refs) |r| try w.free(r, 8);
        const root = try w.alloc(8);
        @memcpy(root.bytes, "CHUNKED2");
        w.setRoot(root.ref);
        _ = try w.commit();
    }
    try testing.expect(db.freeListLenForTest() >= n_extents);
    db.deinit();

    var db2 = try Db.open(testing.allocator, path);
    defer db2.deinit();
    try testing.expect(db2.freeListLenForTest() >= n_extents);
    try verification.verifyIntegrity(&db2);
}

test "a free-list chain whose next ref points up-chain is rejected as corrupt" {
    // Regression: a forged or bit-rotted next_ref forming a cycle re-decoded
    // the same chunk's extents on every hop -- an out-of-memory death, not an
    // error, long before the hop guard tripped. Legitimate chains have
    // strictly decreasing refs (chunks are written back-to-front), so a
    // self-referencing head must fail the open cheaply with error.Corrupt.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "flcycle.airdb");
    defer testing.allocator.free(path);
    var node_ref: u64 = 0;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        {
            var w = try db.beginWrite();
            const a = try w.alloc(8);
            @memcpy(a.bytes, "CYCLBASE");
            w.setRoot(a.ref);
            _ = try w.commit();
        }
        const old_root = db.active_root;
        {
            var w = try db.beginWrite();
            const b = try w.alloc(8);
            @memcpy(b.bytes, "CYCLNEXT");
            try w.free(old_root, 8);
            w.setRoot(b.ref);
            _ = try w.commit();
        }
        node_ref = db.free_list_node_ref;
        try testing.expect(node_ref != 0);
        // Point the head chunk's next_ref at itself.
        const off: usize = @intCast(node_ref);
        std.mem.writeInt(u64, db.store.map[off + 4 ..][0..8], node_ref, .little);
        try db.store.syncer.flush(db.store.file);
    }
    try testing.expectError(error.Corrupt, Db.open(testing.allocator, path));
}
