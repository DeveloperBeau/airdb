const std = @import("std");

pub const FreeExtent = struct { offset: u64, len: u64, freed_version: u64 };
const extent_bytes: usize = 24;

/// All recorded lengths are rounded up to 8 bytes. The arena 8-aligns every
/// allocation start, so the bytes between an allocation's logical end and the
/// next 8-boundary are dead padding owned by nobody; folding them into the
/// extent unifies the free pool into 8-byte size classes. That keeps exact
/// matching effective (a 1027-byte leaf and a 1027-byte request both become
/// 1032) and keeps carved remainders 8-aligned and class-sized.
fn round8(n: u64) u64 {
    return (n + 7) & ~@as(u64, 7);
}

pub const FreeList = struct {
    allocator: std.mem.Allocator,
    extents: std.ArrayList(FreeExtent),
    /// size class -> indices into `extents` with that exact (rounded) len.
    /// Makes reuseExact a bucket probe instead of a linear scan over every
    /// extent -- the free-pool lookup sits on the hot allocation path of every
    /// copy-on-write node write.
    by_size: std.AutoHashMap(u64, std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator) FreeList {
        return .{
            .allocator = allocator,
            .extents = .empty,
            .by_size = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *FreeList) void {
        var it = self.by_size.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.by_size.deinit();
        self.extents.deinit(self.allocator);
    }

    fn bucketAdd(self: *FreeList, size: u64, idx: usize) !void {
        const gop = try self.by_size.getOrPut(size);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, idx);
    }

    // Remove extent index `idx` from its size bucket (it must be present).
    fn bucketRemove(self: *FreeList, size: u64, idx: usize) void {
        const list = self.by_size.getPtr(size).?;
        for (list.items, 0..) |v, i| {
            if (v == idx) {
                _ = list.swapRemove(i);
                return;
            }
        }
        unreachable; // bucket bookkeeping out of sync
    }

    // Swap-remove extent `idx` and repair the moved element's bucket entry.
    fn removeExtentAt(self: *FreeList, idx: usize) FreeExtent {
        const removed = self.extents.swapRemove(idx);
        if (idx < self.extents.items.len) {
            // The former last element now lives at idx; re-point its bucket entry.
            const moved = self.extents.items[idx];
            const list = self.by_size.getPtr(moved.len).?;
            for (list.items, 0..) |v, i| {
                if (v == self.extents.items.len) {
                    list.items[i] = idx;
                    break;
                }
            }
        }
        return removed;
    }

    fn clearBuckets(self: *FreeList) void {
        var it = self.by_size.valueIterator();
        while (it.next()) |list| list.clearRetainingCapacity();
    }

    pub fn add(self: *FreeList, e: FreeExtent) !void {
        if (e.len == 0) return;
        const rounded = FreeExtent{ .offset = e.offset, .len = round8(e.len), .freed_version = e.freed_version };
        try self.extents.append(self.allocator, rounded);
        try self.bucketAdd(rounded.len, self.extents.items.len - 1);
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
        self.clearBuckets();
        var off: usize = 4;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try self.add(.{
                .offset = std.mem.readInt(u64, buf[off..][0..8], .little),
                .len = std.mem.readInt(u64, buf[off + 8 ..][0..8], .little),
                .freed_version = std.mem.readInt(u64, buf[off + 16 ..][0..8], .little),
            });
            off += extent_bytes;
        }
    }

    /// Reuse space of exactly `size` (rounded to its 8-byte class) whose
    /// freed_version <= horizon. Exact-class only, via a bucket probe: the
    /// copy-on-write cycle frees and reallocates a small fixed set of node
    /// sizes, so exact matching keeps the pool fragment-free. Deliberately no
    /// carving and no coalescing -- both were tried and shredded the class
    /// pool: carving a smaller request out of a node-class extent strands a
    /// sub-node fragment, and merging adjacent node extents destroys the very
    /// classes the next batch of allocations needs.
    pub fn reuseExact(self: *FreeList, size: u64, horizon: u64) ?u64 {
        const want = round8(size);
        const list = self.by_size.getPtr(want) orelse return null;
        for (list.items, 0..) |idx, i| {
            if (self.extents.items[idx].freed_version <= horizon) {
                const off = self.extents.items[idx].offset;
                _ = list.swapRemove(i);
                _ = self.removeExtentAt(idx);
                return off;
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

test "reuseExact returns an extent only when freed_version <= horizon" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 64, .freed_version = 5 });
    try testing.expect(list.reuseExact(64, 4) == null);
    const r = list.reuseExact(64, 5).?;
    try testing.expectEqual(@as(u64, 4096), r);
    try testing.expectEqual(@as(usize, 0), list.extents.items.len);
}

test "reuseExact matches by 8-byte size class within the horizon" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    // Odd sizes land in their rounded class: 1027 -> 1032, 515 -> 520.
    try list.add(.{ .offset = 4096, .len = 1027, .freed_version = 2 });
    try list.add(.{ .offset = 8192, .len = 515, .freed_version = 2 });
    // A 515 request takes the exact 520-class extent only.
    try testing.expectEqual(@as(u64, 8192), list.reuseExact(515, 5).?);
    try testing.expectEqual(@as(usize, 1), list.extents.items.len);
    // Horizon too low: the remaining extent (freed_version 2) is not reusable at 1.
    try testing.expect(list.reuseExact(1027, 1) == null);
    // Exact class match within horizon.
    try testing.expectEqual(@as(u64, 4096), list.reuseExact(1027, 2).?);
    try testing.expectEqual(@as(usize, 0), list.extents.items.len);
}

test "reuseExact never carves a different class" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    // A 520-class extent (a freed column leaf) must not be shredded by a
    // smaller request nor serve a larger one; it stays whole for the next
    // exact 520-class allocation.
    try list.add(.{ .offset = 4096, .len = 520, .freed_version = 1 });
    try testing.expect(list.reuseExact(112, 10) == null);
    try testing.expect(list.reuseExact(1027, 10) == null);
    try testing.expectEqual(@as(u64, 4096), list.reuseExact(515, 10).?);
}
