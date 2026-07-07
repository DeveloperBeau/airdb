const std = @import("std");
const testing = std.testing;
const coord = @import("coord.zig");
const platform = @import("platform.zig");
const Coord = coord.Coord;
const coordIo = coord.coordIo;
const sentinel_max = coord.sentinel_max;

test "coord create initializes magic and zero attach count, reopen reads them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "x.coord" });
    defer testing.allocator.free(cpath);

    var c1 = try Coord.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 1), c1.attach());
    var c2 = try Coord.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 2), c2.attach());
    try testing.expectEqual(@as(u32, 1), c2.detach());
    c2.deinit();
    _ = c1.detach();
    c1.deinit();
}

test "a second openOrCreate preserves live coordination state" {
    // Regression: the init path must never re-zero an already-stamped page.
    // Attach count, claimed slot, published pin, and latest version written by
    // the first opener must all survive a second open of the same file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "keep.coord" });
    defer testing.allocator.free(cpath);

    var c1 = try Coord.openOrCreate(cpath);
    defer c1.deinit();
    _ = c1.attach();
    const slot = (try c1.claimSlot()).?;
    c1.publishMinPinned(slot, 7);
    c1.setLatestVersion(42);

    var c2 = try Coord.openOrCreate(cpath);
    defer c2.deinit();
    try testing.expectEqual(@as(u32, 1), c2.attachCount());
    try testing.expectEqual(@as(u64, 7), c2.slotMinPinnedForTest(slot));
    try testing.expectEqual(@as(u64, 42), c2.latestVersion());
    c1.releaseSlot(slot);
    _ = c1.detach();
}

test "openOrCreate succeeds while another holder owns the coord flock" {
    // The init fast path must not block behind the write lock: an existing
    // (stamped) coord file opens without touching the flock.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "locked.coord" });
    defer testing.allocator.free(cpath);

    var a = try Coord.openOrCreate(cpath);
    defer a.deinit();
    try a.lockExclusive(); // simulate a writer mid-transaction

    var b = try Coord.openOrCreate(cpath); // must not deadlock
    b.deinit();
    a.unlock();
}

test "latest_version round-trips through the mapping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "y.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    c.setLatestVersion(42);
    try testing.expectEqual(@as(u64, 42), c.latestVersion());
}

test "exclusive lock blocks a second holder via the same coord file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "z.coord" });
    defer testing.allocator.free(cpath);

    var a = try Coord.openOrCreate(cpath);
    defer a.deinit();
    var b = try Coord.openOrCreate(cpath); // separate open file description -> independent flock that contends
    defer b.deinit();

    try a.lockExclusive();
    try testing.expectError(error.WouldBlock, b.tryLockExclusive());
    a.unlock();
    try b.tryLockExclusive();
    b.unlock();
}

test "claim returns a slot index, publish and read back min_pinned, release frees it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "p.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const idx = (try c.claimSlot()).?;
    c.publishMinPinned(idx, 7);
    try testing.expectEqual(@as(u64, 7), c.slotMinPinnedForTest(idx));
    c.releaseSlot(idx);
    try testing.expectEqual(@as(u32, 0), c.slotPidForTest(idx));
}

test "two claims get distinct slots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "p2.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const a = (try c.claimSlot()).?;
    const b = (try c.claimSlot()).?;
    try testing.expect(a != b);
    c.releaseSlot(a);
    c.releaseSlot(b);
}

test "globalHorizon is the min of live slots min_pinned, clamped to fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "gh.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const a = (try c.claimSlot()).?;
    c.publishMinPinned(a, 5);
    try testing.expectEqual(@as(u64, 5), c.globalHorizon(100));
    c.publishMinPinned(a, sentinel_max);
    try testing.expectEqual(@as(u64, 100), c.globalHorizon(100));
    c.releaseSlot(a);
}

test "globalHorizon ignores and reclaims a dead-pid slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "dead.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();
    const live = (try c.claimSlot()).?;
    c.publishMinPinned(live, sentinel_max);
    c.forgeSlotForTest(1, 0x7fffffff, 0, 3); // an almost-certainly-dead pid with a low min_pinned
    try testing.expectEqual(@as(u64, 50), c.globalHorizon(50));
    try testing.expectEqual(@as(u32, 0), c.slotPidForTest(1)); // reclaimed
    c.releaseSlot(live);
}

test "globalHorizon reclaims a slot whose live pid has the wrong incarnation token" {
    // A recycled pid must not keep a dead reader's pin alive: the slot names a
    // LIVE pid (our own) but a token from a different process incarnation, so
    // the horizon must ignore and reclaim it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "recycled.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();

    const my_pid: u32 = @intCast(platform.currentPid());
    const my_token: u32 = @truncate(platform.processStartToken(my_pid) orelse return error.SkipZigTest);
    c.forgeSlotForTest(2, my_pid, my_token +% 1, 3); // alive pid, wrong incarnation
    try testing.expectEqual(@as(u64, 50), c.globalHorizon(50));
    try testing.expectEqual(@as(u32, 0), c.slotPidForTest(2)); // reclaimed

    // A correctly claimed slot (matching token) still pins the horizon.
    const idx = (try c.claimSlot()).?;
    c.publishMinPinned(idx, 7);
    try testing.expectEqual(@as(u64, 7), c.globalHorizon(50));
    c.releaseSlot(idx);
}

test "globalHorizon keeps a live-pid slot whose stored token is zero" {
    // A claimer that could not obtain its own start token stores 0. Treating
    // that as a token mismatch would reclaim a LIVE reader's slot and drop its
    // pin; the horizon must honor the pin (pid-only liveness) instead.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &path_buf);
    const cpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "zerotoken.coord" });
    defer testing.allocator.free(cpath);
    var c = try Coord.openOrCreate(cpath);
    defer c.deinit();

    const my_pid: u32 = @intCast(platform.currentPid());
    c.forgeSlotForTest(1, my_pid, 0, 5); // alive pid, unknown incarnation
    try testing.expectEqual(@as(u64, 5), c.globalHorizon(50));
    try testing.expectEqual(my_pid, c.slotPidForTest(1)); // not reclaimed
    c.releaseSlot(1);
}
