const std = @import("std");

pub const FreeExtent = struct { offset: u64, len: u64, freed_version: u64 };
const extent_bytes: usize = 24;

pub const FreeList = struct {
    allocator: std.mem.Allocator,
    extents: std.ArrayList(FreeExtent),

    pub fn init(allocator: std.mem.Allocator) FreeList {
        return .{ .allocator = allocator, .extents = .empty };
    }
    pub fn deinit(self: *FreeList) void {
        self.extents.deinit(self.allocator);
    }
    pub fn add(self: *FreeList, e: FreeExtent) !void {
        if (e.len == 0) return;
        try self.extents.append(self.allocator, e);
    }
    // [count:u32 LE] then count * ([offset u64][len u64][freed_version u64]) LE.
    pub fn encode(self: *FreeList, buf: []u8) usize {
        const count: u32 = @intCast(self.extents.items.len);
        std.debug.assert(buf.len >= self.byteLen());
        std.mem.writeInt(u32, buf[0..4], count, .little);
        var off: usize = 4;
        for (self.extents.items) |e| {
            std.mem.writeInt(u64, buf[off..][0..8], e.offset, .little);
            std.mem.writeInt(u64, buf[off + 8 ..][0..8], e.len, .little);
            std.mem.writeInt(u64, buf[off + 16 ..][0..8], e.freed_version, .little);
            off += extent_bytes;
        }
        return off;
    }
    pub fn byteLen(self: *FreeList) usize {
        return 4 + self.extents.items.len * extent_bytes;
    }
    pub fn decode(self: *FreeList, buf: []const u8) !void {
        if (buf.len < 4) return error.Corrupt;
        const count = std.mem.readInt(u32, buf[0..4], .little);
        if (buf.len < 4 + @as(usize, count) * extent_bytes) return error.Corrupt;
        self.extents.clearRetainingCapacity();
        var off: usize = 4;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try self.extents.append(self.allocator, .{
                .offset = std.mem.readInt(u64, buf[off..][0..8], .little),
                .len = std.mem.readInt(u64, buf[off + 8 ..][0..8], .little),
                .freed_version = std.mem.readInt(u64, buf[off + 16 ..][0..8], .little),
            });
            off += extent_bytes;
        }
    }
    // First-fit reusable extent of at least `size` whose freed_version <= horizon. Shrinks remainder.
    pub fn reuse(self: *FreeList, size: u64, horizon: u64) ?u64 {
        var i: usize = 0;
        while (i < self.extents.items.len) : (i += 1) {
            const e = self.extents.items[i];
            if (e.freed_version <= horizon and e.len >= size) {
                const offset = e.offset;
                if (e.len == size) {
                    _ = self.extents.orderedRemove(i);
                } else {
                    self.extents.items[i] = .{ .offset = e.offset + size, .len = e.len - size, .freed_version = e.freed_version };
                }
                return offset;
            }
        }
        return null;
    }
};

const testing = std.testing;

test "extent array encodes and decodes round-trip" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 64, .freed_version = 2 });
    try list.add(.{ .offset = 8192, .len = 128, .freed_version = 3 });
    var buf: [4096]u8 = undefined;
    const n = list.encode(&buf);
    var list2 = FreeList.init(allocator);
    defer list2.deinit();
    try list2.decode(buf[0..n]);
    try testing.expectEqual(@as(usize, 2), list2.extents.items.len);
    try testing.expectEqual(@as(u64, 4096), list2.extents.items[0].offset);
}

test "reuse returns an extent only when freed_version <= horizon" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 64, .freed_version = 5 });
    try testing.expect(list.reuse(64, 4) == null);
    const r = list.reuse(64, 5).?;
    try testing.expectEqual(@as(u64, 4096), r);
    try testing.expectEqual(@as(usize, 0), list.extents.items.len);
}

test "reuse picks an extent at least as large and shrinks remainder" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 256, .freed_version = 1 });
    const r = list.reuse(64, 10).?;
    try testing.expectEqual(@as(u64, 4096), r);
    try testing.expectEqual(@as(usize, 1), list.extents.items.len);
    try testing.expectEqual(@as(u64, 4096 + 64), list.extents.items[0].offset);
    try testing.expectEqual(@as(u64, 256 - 64), list.extents.items[0].len);
}
