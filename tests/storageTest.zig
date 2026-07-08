const std = @import("std");
const airdb = @import("airdb");
const testing = std.testing;
const Io = std.Io;

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const dirPath = pathBuffer[0..pathLen];
    return std.fs.path.join(allocator, &.{ dirPath, name });
}

test "recovery survives a corrupted header by falling back to the best valid slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "hdr.airdb");
    defer testing.allocator.free(path);
    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "GOODDATA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    { // scramble activeSlot (offset 13) and the header crc (offset 28) on disk, leaving slots intact
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &[_]u8{0xAB}, 13);
        try file.writePositionalAll(io, &[_]u8{ 0, 0, 0, 0 }, 28);
        try file.sync(io);
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("GOODDATA", try readTransaction.deref(readTransaction.root(), 8));
        readTransaction.end();
    }
}

test "data-barrier flush failure during commit leaves the prior version intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "crash1.airdb");
    defer testing.allocator.free(path);
    { // commit v1 with a real syncer
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(4);
        @memcpy(allocation.bytes, "v1__");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    { // attempt v2; fail the FIRST flush of this session (the data barrier)
        var fsync = airdb.FailingSyncer{ .failOn = 1 };
        var database = try airdb.Database.openWith(testing.allocator, path, fsync.any());
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(4);
        @memcpy(allocation.bytes, "v2!!");
        writeTransaction.setRoot(allocation.ref);
        const preVersion = database.activeVersion;
        const preRoot = database.activeRoot;
        try testing.expectError(error.Durability, writeTransaction.commit());
        try testing.expectEqual(preVersion, database.activeVersion);
        try testing.expectEqual(preRoot, database.activeRoot);
    }
    { // reopen with a real syncer: must still see v1
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("v1__", try readTransaction.deref(readTransaction.root(), 4));
    }
}

test "header-flush failure during commit does not publish v2" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "crash2.airdb");
    defer testing.allocator.free(path);
    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(4);
        @memcpy(allocation.bytes, "v1__");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        // failOn = 2: data barrier (1) succeeds, header flush (2) fails -> revert, no publish.
        var fsync = airdb.FailingSyncer{ .failOn = 2 };
        var database = try airdb.Database.openWith(testing.allocator, path, fsync.any());
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(4);
        @memcpy(allocation.bytes, "v2!!");
        writeTransaction.setRoot(allocation.ref);
        const preVersion = database.activeVersion;
        const preRoot = database.activeRoot;
        try testing.expectError(error.Durability, writeTransaction.commit());
        try testing.expectEqual(preVersion, database.activeVersion);
        try testing.expectEqual(preRoot, database.activeRoot);
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("v1__", try readTransaction.deref(readTransaction.root(), 4));
    }
}

test "opening a file with bad magic fails cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "bad.airdb");
    defer testing.allocator.free(path);

    // Create a real database, then corrupt the magic bytes on disk.
    {
        var database = try airdb.Database.create(testing.allocator, path);
        database.deinit();
    }
    {
        // Overwrite the first 8 bytes (the magic) with garbage using Zig 0.16
        // positional writes (file.writePositionalAll), which map to pwrite syscall.
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0 }, 0);
        try file.sync(io);
    }
    try testing.expectError(error.BadMagic, airdb.Database.open(testing.allocator, path));
}

test "second commit supersedes the first on reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "two.airdb");
    defer testing.allocator.free(path);

    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();

        var writeTransaction1 = try database.beginWrite();
        const allocation = try writeTransaction1.alloc(4);
        @memcpy(allocation.bytes, "v1__");
        writeTransaction1.setRoot(allocation.ref);
        _ = try writeTransaction1.commit();

        var writeTransaction2 = try database.beginWrite();
        const allocationB = try writeTransaction2.alloc(4);
        @memcpy(allocationB.bytes, "v2!!");
        writeTransaction2.setRoot(allocationB.ref);
        _ = try writeTransaction2.commit();
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("v2!!", try readTransaction.deref(readTransaction.root(), 4));
    }
}

test "a reader pinned to an old version still reads its data after the writer reuses freed space" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "mvcc.airdb");
    defer testing.allocator.free(path);
    var database = try airdb.Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AAAAAAAA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    var reader = try database.beginRead();
    try testing.expectEqualStrings("AAAAAAAA", try reader.deref(reader.root(), 8));

    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BBBBBBBB");
        try writeTransaction.free(reader.root(), 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    try testing.expectEqualStrings("AAAAAAAA", try reader.deref(reader.root(), 8));
    reader.end();

    var readTransaction2 = try database.beginRead();
    try testing.expectEqualStrings("BBBBBBBB", try readTransaction2.deref(readTransaction2.root(), 8));
    readTransaction2.end();
}

test "freed space is reused only after the pinning reader releases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "reclaim.airdb");
    defer testing.allocator.free(path);
    var database = try airdb.Database.create(testing.allocator, path);
    defer database.deinit();

    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AAAAAAAA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    var reader = try database.beginRead();
    const oldRoot = reader.root();

    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BBBBBBBB");
        try writeTransaction.free(oldRoot, 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    // Reader still pinned: a fresh allocation must NOT land on oldRoot yet.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        try testing.expect(allocation.ref != oldRoot);
        writeTransaction.deinit(); // abandon the probe (no commit)
    }

    reader.end(); // horizon advances past the freed version

    // Now a fresh allocation may reuse oldRoot.
    {
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        try testing.expectEqual(oldRoot, allocation.ref);
        writeTransaction.deinit();
    }
}

test "after a data-barrier flush failure, the reopened database passes verifyIntegrity and shows the prior version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cm1.airdb");
    defer testing.allocator.free(path);
    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BASELINE");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var fsync = airdb.FailingSyncer{ .failOn = 1 }; // fail the data barrier
        var database = try airdb.Database.openWith(testing.allocator, path, fsync.any());
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "NEWERVAL");
        writeTransaction.setRoot(allocation.ref);
        try testing.expectError(error.Durability, writeTransaction.commit());
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        try airdb.verification.verifyIntegrity(&database);
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("BASELINE", try readTransaction.deref(readTransaction.root(), 8));
        readTransaction.end();
    }
}

test "after a header-flush failure, the reopened database passes verifyIntegrity and shows the prior version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "cm2.airdb");
    defer testing.allocator.free(path);
    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BASELINE");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }
    {
        var fsync = airdb.FailingSyncer{ .failOn = 2 }; // data barrier ok, header flush fails
        var database = try airdb.Database.openWith(testing.allocator, path, fsync.any());
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "NEWERVAL");
        writeTransaction.setRoot(allocation.ref);
        try testing.expectError(error.Durability, writeTransaction.commit());
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        try airdb.verification.verifyIntegrity(&database);
        var readTransaction = try database.beginRead();
        try testing.expectEqualStrings("BASELINE", try readTransaction.deref(readTransaction.root(), 8));
        readTransaction.end();
    }
}

test "a writer does not reuse space a reader in another instance still pins" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "xpin.airdb");
    defer testing.allocator.free(path);
    var databaseA = try airdb.Database.create(testing.allocator, path);
    defer databaseA.deinit();
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "AAAAAAAA");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    var databaseB = try airdb.Database.open(testing.allocator, path);
    defer databaseB.deinit();
    var readTransactionB = try databaseB.beginRead(); // b pins the current version in its participant slot
    const pinnedRoot = readTransactionB.root();
    try testing.expectEqualStrings("AAAAAAAA", try readTransactionB.deref(pinnedRoot, 8));

    // a frees the old root at the new version and commits new data.
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BBBBBBBB");
        try writeTransaction.free(pinnedRoot, 8);
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    // a tries another allocation: the freed extent must NOT be reused, because b still
    // pins a version below the freeing-version (global horizon respects b's reader).
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        try testing.expect(allocation.ref != pinnedRoot);
        writeTransaction.deinit();
    }

    // b's data is intact (never overwritten).
    try testing.expectEqualStrings("AAAAAAAA", try readTransactionB.deref(pinnedRoot, 8));
    readTransactionB.end(); // b publishes the sentinel -> the freed extent becomes reclaimable

    // Now a may reuse the freed extent.
    {
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        try testing.expectEqual(pinnedRoot, allocation.ref);
        writeTransaction.deinit();
    }
}

test "an abandoned writer releases the lock and never publishes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "abandon.airdb");
    defer testing.allocator.free(path);
    var databaseA = try airdb.Database.create(testing.allocator, path);
    defer databaseA.deinit();
    var databaseB = try airdb.Database.open(testing.allocator, path);
    defer databaseB.deinit();

    { // baseline commit via a
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "BASELINE");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    { // a begins a write but ABANDONS it (deinit without commit): releases lock, no publish
        var writeTransaction = try databaseA.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "DROPPED!");
        writeTransaction.setRoot(allocation.ref);
        writeTransaction.deinit();
    }

    // b can now acquire the write lock (proves the abandoned writer released it) and commit.
    {
        var writeTransaction = try databaseB.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "SECONDWR");
        writeTransaction.setRoot(allocation.ref);
        _ = try writeTransaction.commit();
    }

    // a refreshes on read and sees SECONDWR, never the abandoned DROPPED! value.
    var readTransaction = try databaseA.beginRead();
    try testing.expectEqualStrings("SECONDWR", try readTransaction.deref(readTransaction.root(), 8));
    readTransaction.end();
}

test "a database grown well past the initial size reopens and verifies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "large.airdb");
    defer testing.allocator.free(path);
    {
        var database = try airdb.Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        var index: usize = 0;
        var root: u64 = 0;
        while (index < 600) : (index += 1) { // ~2.4 MiB of 4 KiB nodes, forces multiple grows past 1 MiB
            const allocation = try writeTransaction.alloc(4096);
            @memset(allocation.bytes, @intCast(index & 0xff));
            root = allocation.ref;
        }
        writeTransaction.setRoot(root);
        _ = try writeTransaction.commit();
    }
    {
        var database = try airdb.Database.open(testing.allocator, path);
        defer database.deinit();
        try airdb.verification.verifyIntegrity(&database);
        var readTransaction = try database.beginRead();
        const got = try readTransaction.deref(readTransaction.root(), 4096);
        try testing.expectEqual(@as(u8, @intCast(599 & 0xff)), got[0]);
        readTransaction.end();
    }
}
