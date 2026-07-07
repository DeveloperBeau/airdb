//! On-disk node formats for the key->value B+tree: fixed-size leaf and inner
//! encodings shared (via bTreeCore) by index.zig's inline numeric keys and
//! byteKeyIndex.zig's blob-ref byte keys.

const std = @import("std");

/// Maximum (key, value) pairs per leaf node.
pub const leafCap: u16 = 64;
/// Maximum children per inner node.
pub const fanout: u16 = 64;
/// Kind byte marking a leaf node.
pub const kindLeaf: u8 = 0;
/// Kind byte marking an inner node.
pub const kindInner: u8 = 1;
/// Byte offset of a node's first entry: [kind u8][count u16].
pub const headerSize: usize = 3;
/// Fixed leaf allocation size: the header plus leafCap (key, value) pairs.
pub const leafNodeSize: usize = headerSize + @as(usize, leafCap) * 16;

/// Bytes per inner-node child entry.
/// Inner layout: [kind u8][childCount u16] then childCount entries of
/// (childRef u64, lowKey u64, subtreeCount u64). The subtree count makes
/// Index.count a single-node read instead of a full-tree walk, which is what
/// keeps liveCount / shouldCompact O(1)-per-node on the compaction hot path.
pub const innerStride: usize = 24;
/// Fixed inner allocation size: the header plus fanout child entries.
pub const innerNodeSize: usize = headerSize + @as(usize, fanout) * innerStride;

/// Encode the parallel (keys, vals) pairs into `buffer` as a leaf node;
/// returns the encoded byte length.
pub fn encodeLeaf(buffer: []u8, keys: []const u64, vals: []const u64) usize {
    std.debug.assert(keys.len == vals.len and keys.len <= leafCap);
    buffer[0] = kindLeaf;
    std.mem.writeInt(u16, buffer[1..3], @intCast(keys.len), .little);
    var offset: usize = headerSize;
    for (keys, vals) |key, value| {
        std.mem.writeInt(u64, buffer[offset..][0..8], key, .little);
        std.mem.writeInt(u64, buffer[offset + 8 ..][0..8], value, .little);
        offset += 16;
    }
    return offset;
}

/// A validated read-only view of a leaf node; construct via parseLeaf.
pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    /// The stored key at `entryIndex`.
    pub fn key(self: LeafView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * 16 ..][0..8], .little);
    }
    /// The value stored alongside the key at `entryIndex`.
    pub fn value(self: LeafView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * 16 + 8 ..][0..8], .little);
    }
    /// First slot whose stored key is >= `searchKey` (== count when every
    /// key is smaller). Binary search, O(log leafCap); inline numeric keys
    /// only.
    pub fn lowerBound(self: LeafView, searchKey: u64) usize {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const midpoint = low + (high - low) / 2;
            if (self.key(midpoint) < searchKey) low = midpoint + 1 else high = midpoint;
        }
        return low;
    }
};

/// Validate `bytes` as a leaf node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized count, or a short buffer.
pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kindLeaf) return error.Corrupt;
    const leafCount = std.mem.readInt(u16, bytes[1..3], .little);
    if (leafCount > leafCap) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, leafCount) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = leafCount };
}

// ---------------------------------------------------------------------------
// Inner-node encoding
// ---------------------------------------------------------------------------

/// Encode the parallel (refs, lows, counts) child entries into `buffer` as an
/// inner node; returns the encoded byte length.
pub fn encodeInner(buffer: []u8, refs: []const u64, lows: []const u64, counts: []const u64) usize {
    std.debug.assert(refs.len == lows.len and refs.len == counts.len and refs.len <= fanout);
    buffer[0] = kindInner;
    std.mem.writeInt(u16, buffer[1..3], @intCast(refs.len), .little);
    var offset: usize = headerSize;
    for (refs, lows, counts) |ref, lowKey, count| {
        std.mem.writeInt(u64, buffer[offset..][0..8], ref, .little);
        std.mem.writeInt(u64, buffer[offset + 8 ..][0..8], lowKey, .little);
        std.mem.writeInt(u64, buffer[offset + 16 ..][0..8], count, .little);
        offset += innerStride;
    }
    return offset;
}

/// A validated read-only view of an inner node; construct via parseInner.
pub const InnerView = struct {
    bytes: []const u8,
    childCount: u16,
    /// The ref of child `entryIndex`.
    pub fn childRef(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride ..][0..8], .little);
    }
    /// The smallest key routed to child `entryIndex` (its recorded low).
    pub fn lowKey(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride + 8 ..][0..8], .little);
    }
    /// The number of entries stored under child `entryIndex`.
    pub fn subtreeCount(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride + 16 ..][0..8], .little);
    }
    /// Total entries under this node: the sum of its children's subtree counts.
    pub fn totalCount(self: InnerView) u64 {
        var total: u64 = 0;
        var entryIndex: usize = 0;
        while (entryIndex < self.childCount) : (entryIndex += 1) total += self.subtreeCount(entryIndex);
        return total;
    }
};

/// Validate `bytes` as an inner node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized child count, or a short buffer.
pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kindInner) return error.Corrupt;
    const childCount = std.mem.readInt(u16, bytes[1..3], .little);
    if (childCount > fanout) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, childCount) * innerStride) return error.Corrupt;
    return .{ .bytes = bytes, .childCount = childCount };
}
