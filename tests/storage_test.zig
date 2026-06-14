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
        var r = db.beginRead();
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
        var r = db.beginRead();
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
        var r = db.beginRead();
        try testing.expectEqualStrings("v2!!", try r.deref(r.root(), 4));
    }
}
