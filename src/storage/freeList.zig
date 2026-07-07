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
    /// bucket_pos[i] is extent i's position inside its size-class bucket.
    /// The back-pointer makes every bucket repair O(1): without it, removing
    /// an extent means linearly searching the moved element's bucket, which is
    /// O(bucket length) per removal and turned delete-heavy transactions
    /// quadratic once buckets reached tens of thousands of entries.
    bucket_pos: std.ArrayList(usize),
    /// size class -> indices into `extents` with that exact (rounded) length.
    /// Makes reuseExact a bucket probe instead of a linear scan over every
    /// extent -- the free-pool lookup sits on the hot allocation path of every
    /// copy-on-write node write.
    by_size: std.AutoHashMap(u64, std.ArrayList(usize)),

    pub fn init(allocator: std.mem.Allocator) FreeList {
        return .{
            .allocator = allocator,
            .extents = .empty,
            .bucket_pos = .empty,
            .by_size = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *FreeList) void {
        var it = self.by_size.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.by_size.deinit();
        self.bucket_pos.deinit(self.allocator);
        self.extents.deinit(self.allocator);
    }

    fn bucketAdd(self: *FreeList, size: u64, extentIndex: usize) !void {
        const gop = try self.by_size.getOrPut(size);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, extentIndex);
        self.bucket_pos.items[extentIndex] = gop.value_ptr.items.len - 1;
    }

    // Remove the bucket entry at `pos` inside the `class` bucket, repairing the
    // moved (former last) entry's back-pointer. O(1).
    fn bucketRemoveAt(self: *FreeList, class: u64, pos: usize) void {
        const list = self.by_size.getPtr(class).?;
        _ = list.swapRemove(pos);
        if (pos < list.items.len) {
            const moved_extent = list.items[pos];
            self.bucket_pos.items[moved_extent] = pos;
        }
    }

    // Swap-remove extent `extentIndex` (whose bucket entry is already gone), repairing
    // the moved (former last) extent's bucket entry via its back-pointer. O(1).
    fn removeExtentAt(self: *FreeList, extentIndex: usize) FreeExtent {
        const removed = self.extents.swapRemove(extentIndex);
        _ = self.bucket_pos.swapRemove(extentIndex);
        if (extentIndex < self.extents.items.len) {
            const moved = self.extents.items[extentIndex];
            const pos = self.bucket_pos.items[extentIndex];
            self.by_size.getPtr(moved.len).?.items[pos] = extentIndex;
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
        errdefer _ = self.extents.pop();
        try self.bucket_pos.append(self.allocator, 0); // set by bucketAdd
        errdefer _ = self.bucket_pos.pop();
        try self.bucketAdd(rounded.len, self.extents.items.len - 1);
    }

    // The persisted free list is a CHAIN of bounded chunks, not one node: a
    // single node's size grows with the extent count, and once heavy churn
    // pushed the list past the 16 MiB section cap the commit-path allocation
    // died with error.AllocTooLarge -- an unrecoverable commit failure.
    //
    // Chunk layout: [count u32 LE][next_ref u64 LE] then
    // count * ([offset u64][length u64][freed_version u64]) LE.
    pub const chunk_header_bytes: usize = 12;
    /// Extents per chunk: 12 + 65_536 * 24 bytes keeps every chunk allocation
    /// near 1.5 MiB, far below the section size.
    pub const chunk_extent_cap: usize = 65_536;
    /// Chain-walk bound (cycle guard); supports ~68 billion extents.
    pub const max_chunks: usize = 1 << 20;

    pub fn chunkByteLen(count: usize) usize {
        return chunk_header_bytes + count * extent_bytes;
    }

    pub fn encodeChunk(extents: []const FreeExtent, next_ref: u64, buffer: []u8) usize {
        std.debug.assert(buffer.len >= chunkByteLen(extents.len));
        std.mem.writeInt(u32, buffer[0..4], @intCast(extents.len), .little);
        std.mem.writeInt(u64, buffer[4..12], next_ref, .little);
        var off: usize = chunk_header_bytes;
        for (extents) |e| {
            std.mem.writeInt(u64, buffer[off..][0..8], e.offset, .little);
            std.mem.writeInt(u64, buffer[off + 8 ..][0..8], e.len, .little);
            std.mem.writeInt(u64, buffer[off + 16 ..][0..8], e.freed_version, .little);
            off += extent_bytes;
        }
        return off;
    }

    /// Clear this list in preparation for decoding a chain of chunks.
    pub fn reset(self: *FreeList) void {
        self.extents.clearRetainingCapacity();
        self.bucket_pos.clearRetainingCapacity();
        self.clearBuckets();
    }

    /// Append one decoded chunk's extents to this list; returns the chunk's
    /// next_ref (0 for the last chunk in the chain).
    pub fn decodeChunkAppend(self: *FreeList, buffer: []const u8) !u64 {
        if (buffer.len < chunk_header_bytes) return error.Corrupt;
        const count = std.mem.readInt(u32, buffer[0..4], .little);
        const next = std.mem.readInt(u64, buffer[4..12], .little);
        if (buffer.len < chunkByteLen(count)) return error.Corrupt;
        var off: usize = chunk_header_bytes;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            try self.add(.{
                .offset = std.mem.readInt(u64, buffer[off..][0..8], .little),
                .len = std.mem.readInt(u64, buffer[off + 8 ..][0..8], .little),
                .freed_version = std.mem.readInt(u64, buffer[off + 16 ..][0..8], .little),
            });
            off += extent_bytes;
        }
        return next;
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
        for (list.items, 0..) |extentIndex, i| {
            if (self.extents.items[extentIndex].freed_version <= horizon) {
                const off = self.extents.items[extentIndex].offset;
                self.bucketRemoveAt(want, i);
                _ = self.removeExtentAt(extentIndex);
                return off;
            }
        }
        return null;
    }
};

const testing = std.testing;

test "extent chunks encode and decode round-trip, preserving the chain link" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 64, .freed_version = 2 });
    try list.add(.{ .offset = 8192, .len = 128, .freed_version = 3 });
    try list.add(.{ .offset = 16384, .len = 8, .freed_version = 4 });
    var buffer: [4096]u8 = undefined;
    // Split across two chunks; the first names the second's ref.
    const n1 = FreeList.encodeChunk(list.extents.items[0..2], 0xDEAD_BEE8, buffer[0..]);
    const n2 = FreeList.encodeChunk(list.extents.items[2..], 0, buffer[n1..]);
    var list2 = FreeList.init(allocator);
    defer list2.deinit();
    list2.reset();
    try testing.expectEqual(@as(u64, 0xDEAD_BEE8), try list2.decodeChunkAppend(buffer[0..n1]));
    try testing.expectEqual(@as(u64, 0), try list2.decodeChunkAppend(buffer[n1 .. n1 + n2]));
    try testing.expectEqual(@as(usize, 3), list2.extents.items.len);
    try testing.expectEqual(@as(u64, 4096), list2.extents.items[0].offset);
    try testing.expectEqual(@as(u64, 16384), list2.extents.items[2].offset);
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
