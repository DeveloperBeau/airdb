const std = @import("std");
const airdb = @import("airdb");
const testing = std.testing;
const Io = std.Io;

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    return std.fs.path.join(allocator, &.{ dir_path, name });
}

test "recovery survives a corrupted header by falling back to the best valid slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "hdr.airdb");
    defer testing.allocator.free(path);
    {
        var db = try airdb.Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "GOODDATA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    { // scramble active_slot (offset 13) and the header crc (offset 28) on disk, leaving slots intact
        const io = std.Io.Threaded.global_single_threaded.io();
        var f = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &[_]u8{0xAB}, 13);
        try f.writePositionalAll(io, &[_]u8{ 0, 0, 0, 0 }, 28);
        try f.sync(io);
    }
    {
        var db = try airdb.Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqualStrings("GOODDATA", try r.deref(r.root(), 8));
        r.end();
    }
}

test "data-barrier flush failure during commit leaves the prior version intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "crash1.airdb");
    defer testing.allocator.free(path);
    { // commit v1 with a real syncer
        var db = try airdb.Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(4);
        @memcpy(a.bytes, "v1__");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    { // attempt v2; fail the FIRST flush of this session (the data barrier)
        var fsync = airdb.FailingSyncer{ .fail_on = 1 };
        var db = try airdb.Db.openWith(testing.allocator, path, fsync.any());
        defer db.deinit();
        var w = try db.beginWrite();
        const b = try w.alloc(4);
        @memcpy(b.bytes, "v2!!");
        w.setRoot(b.ref);
        const pre_version = db.active_version;
        const pre_root = db.active_root;
        try testing.expectError(error.Durability, w.commit());
        try testing.expectEqual(pre_version, db.active_version);
        try testing.expectEqual(pre_root, db.active_root);
    }
    { // reopen with a real syncer: must still see v1
        var db = try airdb.Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqualStrings("v1__", try r.deref(r.root(), 4));
    }
}

test "header-flush failure during commit does not publish v2" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "crash2.airdb");
    defer testing.allocator.free(path);
    {
        var db = try airdb.Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const a = try w.alloc(4);
        @memcpy(a.bytes, "v1__");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    {
        // fail_on = 2: data barrier (1) succeeds, header flush (2) fails -> revert, no publish.
        var fsync = airdb.FailingSyncer{ .fail_on = 2 };
        var db = try airdb.Db.openWith(testing.allocator, path, fsync.any());
        defer db.deinit();
        var w = try db.beginWrite();
        const b = try w.alloc(4);
        @memcpy(b.bytes, "v2!!");
        w.setRoot(b.ref);
        const pre_version = db.active_version;
        const pre_root = db.active_root;
        try testing.expectError(error.Durability, w.commit());
        try testing.expectEqual(pre_version, db.active_version);
        try testing.expectEqual(pre_root, db.active_root);
    }
    {
        var db = try airdb.Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqualStrings("v1__", try r.deref(r.root(), 4));
    }
}

test "opening a file with bad magic fails cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "bad.airdb");
    defer testing.allocator.free(path);

    // Create a real db, then corrupt the magic bytes on disk.
    {
        var db = try airdb.Db.create(testing.allocator, path);
        db.deinit();
    }
    {
        // Overwrite the first 8 bytes (the magic) with garbage using Zig 0.16
        // positional writes (file.writePositionalAll), which map to pwrite syscall.
        const io = std.Io.Threaded.global_single_threaded.io();
        const f = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0 }, 0);
        try f.sync(io);
    }
    try testing.expectError(error.BadMagic, airdb.Db.open(testing.allocator, path));
}

test "second commit supersedes the first on reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "two.airdb");
    defer testing.allocator.free(path);

    {
        var db = try airdb.Db.create(testing.allocator, path);
        defer db.deinit();

        var w1 = try db.beginWrite();
        const a = try w1.alloc(4);
        @memcpy(a.bytes, "v1__");
        w1.setRoot(a.ref);
        _ = try w1.commit();

        var w2 = try db.beginWrite();
        const b = try w2.alloc(4);
        @memcpy(b.bytes, "v2!!");
        w2.setRoot(b.ref);
        _ = try w2.commit();
    }
    {
        var db = try airdb.Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqualStrings("v2!!", try r.deref(r.root(), 4));
    }
}

test "a reader pinned to an old version still reads its data after the writer reuses freed space" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "mvcc.airdb");
    defer testing.allocator.free(path);
    var db = try airdb.Db.create(testing.allocator, path);
    defer db.deinit();

    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }

    var reader = try db.beginRead();
    try testing.expectEqualStrings("AAAAAAAA", try reader.deref(reader.root(), 8));

    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(reader.root(), 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }

    try testing.expectEqualStrings("AAAAAAAA", try reader.deref(reader.root(), 8));
    reader.end();

    var r2 = try db.beginRead();
    try testing.expectEqualStrings("BBBBBBBB", try r2.deref(r2.root(), 8));
    r2.end();
}

test "freed space is reused only after the pinning reader releases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "reclaim.airdb");
    defer testing.allocator.free(path);
    var db = try airdb.Db.create(testing.allocator, path);
    defer db.deinit();

    {
        var w = try db.beginWrite();
        const a = try w.alloc(8);
        @memcpy(a.bytes, "AAAAAAAA");
        w.setRoot(a.ref);
        _ = try w.commit();
    }
    var reader = try db.beginRead();
    const old_root = reader.root();

    {
        var w = try db.beginWrite();
        const b = try w.alloc(8);
        @memcpy(b.bytes, "BBBBBBBB");
        try w.free(old_root, 8);
        w.setRoot(b.ref);
        _ = try w.commit();
    }

    // Reader still pinned: a fresh allocation must NOT land on old_root yet.
    {
        var w = try db.beginWrite();
        const c = try w.alloc(8);
        try testing.expect(c.ref != old_root);
        w.deinit(); // abandon the probe (no commit)
    }

    reader.end(); // horizon advances past the freed version

    // Now a fresh allocation may reuse old_root.
    {
        var w = try db.beginWrite();
        const d = try w.alloc(8);
        try testing.expectEqual(old_root, d.ref);
        w.deinit();
    }
}
