const std = @import("std");

pub const leafCap: u16 = 64;
pub const fanout: u16 = 64;
pub const kind_leaf: u8 = 0;
pub const kind_inner: u8 = 1;
pub const headerSize: usize = 3; // [kind u8][count u16]
pub const leaf_node_size: usize = headerSize + @as(usize, leafCap) * 16; // (key,value)

// Inner layout: [kind u8][child_count u16] then child_count entries of
// (child_ref u64, low_key u64, subtree_count u64). The subtree count makes
// Index.count a single-node read instead of a full-tree walk, which is what
// keeps liveCount / shouldCompact O(1)-per-node on the compaction hot path.
pub const inner_stride: usize = 24;
pub const inner_node_size: usize = headerSize + @as(usize, fanout) * inner_stride;

pub fn encodeLeaf(buffer: []u8, keys: []const u64, vals: []const u64) usize {
    std.debug.assert(keys.len == vals.len and keys.len <= leafCap);
    buffer[0] = kind_leaf;
    std.mem.writeInt(u16, buffer[1..3], @intCast(keys.len), .little);
    var off: usize = headerSize;
    for (keys, vals) |k, v| {
        std.mem.writeInt(u64, buffer[off..][0..8], k, .little);
        std.mem.writeInt(u64, buffer[off + 8 ..][0..8], v, .little);
        off += 16;
    }
    return off;
}

pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    pub fn key(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + i * 16 ..][0..8], .little);
    }
    pub fn value(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + i * 16 + 8 ..][0..8], .little);
    }
    pub fn lowerBound(self: LeafView, k: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.key(mid) < k) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kind_leaf) return error.Corrupt;
    const leaf_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (leaf_count > leafCap) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, leaf_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = leaf_count };
}

// ---------------------------------------------------------------------------
// Inner-node encoding
// ---------------------------------------------------------------------------

pub fn encodeInner(buffer: []u8, refs: []const u64, lows: []const u64, counts: []const u64) usize {
    std.debug.assert(refs.len == lows.len and refs.len == counts.len and refs.len <= fanout);
    buffer[0] = kind_inner;
    std.mem.writeInt(u16, buffer[1..3], @intCast(refs.len), .little);
    var off: usize = headerSize;
    for (refs, lows, counts) |r, l, c| {
        std.mem.writeInt(u64, buffer[off..][0..8], r, .little);
        std.mem.writeInt(u64, buffer[off + 8 ..][0..8], l, .little);
        std.mem.writeInt(u64, buffer[off + 16 ..][0..8], c, .little);
        off += inner_stride;
    }
    return off;
}

pub const InnerView = struct {
    bytes: []const u8,
    child_count: u16,
    pub fn childRef(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + i * inner_stride ..][0..8], .little);
    }
    pub fn lowKey(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + i * inner_stride + 8 ..][0..8], .little);
    }
    pub fn subtreeCount(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + i * inner_stride + 16 ..][0..8], .little);
    }
    /// Total entries under this node: the sum of its children's subtree counts.
    pub fn totalCount(self: InnerView) u64 {
        var total: u64 = 0;
        var i: usize = 0;
        while (i < self.child_count) : (i += 1) total += self.subtreeCount(i);
        return total;
    }
};

pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kind_inner) return error.Corrupt;
    const child_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (child_count > fanout) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, child_count) * inner_stride) return error.Corrupt;
    return .{ .bytes = bytes, .child_count = child_count };
}
