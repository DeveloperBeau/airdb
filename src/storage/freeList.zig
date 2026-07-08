const std = @import("std");

/// One reclaimable byte range: its arena offset, its (8-byte-rounded) length,
/// and the version whose commit freed it -- reusable only once no reader pins
/// a version at or below freedVersion.
pub const FreeExtent = struct { offset: u64, len: u64, freedVersion: u64 };
const extentBytes: usize = 24;

/// All recorded lengths are rounded up to 8 bytes. The arena 8-aligns every
/// allocation start, so the bytes between an allocation's logical end and the
/// next 8-boundary are dead padding owned by nobody; folding them into the
/// extent unifies the free pool into 8-byte size classes. That keeps exact
/// matching effective (a 1027-byte leaf and a 1027-byte request both become
/// 1032) and keeps carved remainders 8-aligned and class-sized.
fn round8(size: u64) u64 {
    return (size + 7) & ~@as(u64, 7);
}

/// The in-memory pool of reclaimable extents, bucketed by exact 8-byte size
/// class so the copy-on-write allocation path reuses space with an O(1)
/// bucket probe instead of a scan.
pub const FreeList = struct {
    allocator: std.mem.Allocator,
    extents: std.ArrayList(FreeExtent),
    /// bucketPos[i] is extent i's position inside its size-class bucket.
    /// The back-pointer makes every bucket repair O(1): without it, removing
    /// an extent means linearly searching the moved element's bucket, which is
    /// O(bucket length) per removal and turned delete-heavy transactions
    /// quadratic once buckets reached tens of thousands of entries.
    bucketPos: std.ArrayList(usize),
    /// size class -> indices into `extents` with that exact (rounded) length.
    /// Makes reuseExact a bucket probe instead of a linear scan over every
    /// extent -- the free-pool lookup sits on the hot allocation path of every
    /// copy-on-write node write.
    bySize: std.AutoHashMap(u64, std.ArrayList(usize)),

    /// An empty free list whose bookkeeping lives in `allocator`.
    pub fn init(allocator: std.mem.Allocator) FreeList {
        return .{
            .allocator = allocator,
            .extents = .empty,
            .bucketPos = .empty,
            .bySize = std.AutoHashMap(u64, std.ArrayList(usize)).init(allocator),
        };
    }

    /// Release the extent list, back-pointers, and size-class buckets.
    pub fn deinit(self: *FreeList) void {
        var iterator = self.bySize.valueIterator();
        while (iterator.next()) |list| list.deinit(self.allocator);
        self.bySize.deinit();
        self.bucketPos.deinit(self.allocator);
        self.extents.deinit(self.allocator);
    }

    fn bucketAdd(self: *FreeList, size: u64, extentIndex: usize) !void {
        const gop = try self.bySize.getOrPut(size);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, extentIndex);
        self.bucketPos.items[extentIndex] = gop.value_ptr.items.len - 1;
    }

    // Remove the bucket entry at `pos` inside the `class` bucket, repairing the
    // moved (former last) entry's back-pointer. O(1).
    fn bucketRemoveAt(self: *FreeList, class: u64, pos: usize) void {
        const list = self.bySize.getPtr(class).?;
        _ = list.swapRemove(pos);
        if (pos < list.items.len) {
            const movedExtent = list.items[pos];
            self.bucketPos.items[movedExtent] = pos;
        }
    }

    // Swap-remove extent `extentIndex` (whose bucket entry is already gone), repairing
    // the moved (former last) extent's bucket entry via its back-pointer. O(1).
    fn removeExtentAt(self: *FreeList, extentIndex: usize) FreeExtent {
        const removed = self.extents.swapRemove(extentIndex);
        _ = self.bucketPos.swapRemove(extentIndex);
        if (extentIndex < self.extents.items.len) {
            const moved = self.extents.items[extentIndex];
            const pos = self.bucketPos.items[extentIndex];
            self.bySize.getPtr(moved.len).?.items[pos] = extentIndex;
        }
        return removed;
    }

    fn clearBuckets(self: *FreeList) void {
        var iterator = self.bySize.valueIterator();
        while (iterator.next()) |list| list.clearRetainingCapacity();
    }

    /// Record `extent` as reclaimable, rounding its length up to the 8-byte
    /// size class; a zero-length extent is ignored. Amortized O(1).
    pub fn add(self: *FreeList, extent: FreeExtent) !void {
        if (extent.len == 0) return;
        const rounded = FreeExtent{ .offset = extent.offset, .len = round8(extent.len), .freedVersion = extent.freedVersion };
        try self.extents.append(self.allocator, rounded);
        errdefer _ = self.extents.pop();
        try self.bucketPos.append(self.allocator, 0); // set by bucketAdd
        errdefer _ = self.bucketPos.pop();
        try self.bucketAdd(rounded.len, self.extents.items.len - 1);
    }

    /// Byte size of a persisted chunk's [count u32 LE][nextReference u64 LE] header.
    ///
    /// The persisted free list is a CHAIN of bounded chunks, not one node: a
    /// single node's size grows with the extent count, and once heavy churn
    /// pushed the list past the 16 MiB section cap the commit-path allocation
    /// died with error.AllocTooLarge -- an unrecoverable commit failure.
    ///
    /// Chunk layout: [count u32 LE][nextReference u64 LE] then
    /// count * ([offset u64][length u64][freedVersion u64]) LE.
    pub const chunkHeaderBytes: usize = 12;
    /// Extents per chunk: 12 + 65_536 * 24 bytes keeps every chunk allocation
    /// near 1.5 MiB, far below the section size.
    pub const chunkExtentCap: usize = 65_536;
    /// Chain-walk bound (cycle guard); supports ~68 billion extents.
    pub const maxChunks: usize = 1 << 20;

    /// Encoded byte length of a chunk holding `count` extents.
    pub fn chunkByteLength(count: usize) usize {
        return chunkHeaderBytes + count * extentBytes;
    }

    /// Encode `extents` plus the next chunk's reference into `buffer` as one chunk;
    /// returns the encoded byte length. O(extents).
    pub fn encodeChunk(extents: []const FreeExtent, nextReference: u64, buffer: []u8) usize {
        std.debug.assert(buffer.len >= chunkByteLength(extents.len));
        std.mem.writeInt(u32, buffer[0..4], @intCast(extents.len), .little);
        std.mem.writeInt(u64, buffer[4..12], nextReference, .little);
        var offset: usize = chunkHeaderBytes;
        for (extents) |extent| {
            std.mem.writeInt(u64, buffer[offset..][0..8], extent.offset, .little);
            std.mem.writeInt(u64, buffer[offset + 8 ..][0..8], extent.len, .little);
            std.mem.writeInt(u64, buffer[offset + 16 ..][0..8], extent.freedVersion, .little);
            offset += extentBytes;
        }
        return offset;
    }

    /// Clear this list in preparation for decoding a chain of chunks.
    pub fn reset(self: *FreeList) void {
        self.extents.clearRetainingCapacity();
        self.bucketPos.clearRetainingCapacity();
        self.clearBuckets();
    }

    /// Append one decoded chunk's extents to this list; returns the chunk's
    /// nextReference (0 for the last chunk in the chain).
    pub fn decodeChunkAppend(self: *FreeList, buffer: []const u8) !u64 {
        if (buffer.len < chunkHeaderBytes) return error.Corrupt;
        const count = std.mem.readInt(u32, buffer[0..4], .little);
        const next = std.mem.readInt(u64, buffer[4..12], .little);
        if (buffer.len < chunkByteLength(count)) return error.Corrupt;
        var offset: usize = chunkHeaderBytes;
        var entryIndex: u32 = 0;
        while (entryIndex < count) : (entryIndex += 1) {
            try self.add(.{
                .offset = std.mem.readInt(u64, buffer[offset..][0..8], .little),
                .len = std.mem.readInt(u64, buffer[offset + 8 ..][0..8], .little),
                .freedVersion = std.mem.readInt(u64, buffer[offset + 16 ..][0..8], .little),
            });
            offset += extentBytes;
        }
        return next;
    }

    /// Reuse space of exactly `size` (rounded to its 8-byte class) whose
    /// freedVersion <= horizon. Exact-class only, via a bucket probe: the
    /// copy-on-write cycle frees and reallocates a small fixed set of node
    /// sizes, so exact matching keeps the pool fragment-free. Deliberately no
    /// carving and no coalescing -- both were tried and shredded the class
    /// pool: carving a smaller request out of a node-class extent strands a
    /// sub-node fragment, and merging adjacent node extents destroys the very
    /// classes the next batch of allocations needs.
    pub fn reuseExact(self: *FreeList, size: u64, horizon: u64) ?u64 {
        const want = round8(size);
        const list = self.bySize.getPtr(want) orelse return null;
        for (list.items, 0..) |extentIndex, bucketPosition| {
            if (self.extents.items[extentIndex].freedVersion <= horizon) {
                const offset = self.extents.items[extentIndex].offset;
                self.bucketRemoveAt(want, bucketPosition);
                _ = self.removeExtentAt(extentIndex);
                return offset;
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
    try list.add(.{ .offset = 4096, .len = 64, .freedVersion = 2 });
    try list.add(.{ .offset = 8192, .len = 128, .freedVersion = 3 });
    try list.add(.{ .offset = 16384, .len = 8, .freedVersion = 4 });
    var buffer: [4096]u8 = undefined;
    // Split across two chunks; the first names the second's reference.
    const firstChunkLength = FreeList.encodeChunk(list.extents.items[0..2], 0xDEAD_BEE8, buffer[0..]);
    const secondChunkLength = FreeList.encodeChunk(list.extents.items[2..], 0, buffer[firstChunkLength..]);
    var list2 = FreeList.init(allocator);
    defer list2.deinit();
    list2.reset();
    try testing.expectEqual(@as(u64, 0xDEAD_BEE8), try list2.decodeChunkAppend(buffer[0..firstChunkLength]));
    try testing.expectEqual(@as(u64, 0), try list2.decodeChunkAppend(buffer[firstChunkLength .. firstChunkLength + secondChunkLength]));
    try testing.expectEqual(@as(usize, 3), list2.extents.items.len);
    try testing.expectEqual(@as(u64, 4096), list2.extents.items[0].offset);
    try testing.expectEqual(@as(u64, 16384), list2.extents.items[2].offset);
}

test "reuseExact returns an extent only when freedVersion <= horizon" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    try list.add(.{ .offset = 4096, .len = 64, .freedVersion = 5 });
    try testing.expect(list.reuseExact(64, 4) == null);
    const reused = list.reuseExact(64, 5).?;
    try testing.expectEqual(@as(u64, 4096), reused);
    try testing.expectEqual(@as(usize, 0), list.extents.items.len);
}

test "reuseExact matches by 8-byte size class within the horizon" {
    const allocator = testing.allocator;
    var list = FreeList.init(allocator);
    defer list.deinit();
    // Odd sizes land in their rounded class: 1027 -> 1032, 515 -> 520.
    try list.add(.{ .offset = 4096, .len = 1027, .freedVersion = 2 });
    try list.add(.{ .offset = 8192, .len = 515, .freedVersion = 2 });
    // A 515 request takes the exact 520-class extent only.
    try testing.expectEqual(@as(u64, 8192), list.reuseExact(515, 5).?);
    try testing.expectEqual(@as(usize, 1), list.extents.items.len);
    // Horizon too low: the remaining extent (freedVersion 2) is not reusable at 1.
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
    try list.add(.{ .offset = 4096, .len = 520, .freedVersion = 1 });
    try testing.expect(list.reuseExact(112, 10) == null);
    try testing.expect(list.reuseExact(1027, 10) == null);
    try testing.expectEqual(@as(u64, 4096), list.reuseExact(515, 10).?);
}
