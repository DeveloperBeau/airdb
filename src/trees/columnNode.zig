//! On-disk node formats for the column tree (row index -> u64 value):
//! fixed-size leaf and inner encodings shared by column.zig's walkers and
//! the bottom-up bulk builders.

const std = @import("std");

/// Maximum values per leaf node.
pub const leafCap: u16 = 64;
/// Maximum children per inner node.
pub const fanout: u16 = 64;
/// Kind byte marking a leaf node.
pub const kindLeaf: u8 = 0;
/// Kind byte marking an inner node.
pub const kindInner: u8 = 1;

/// Fixed leaf allocation size.
/// Leaf layout: [kind u8][count u16 LE][count * u64 LE].
pub const leafNodeSize: usize = 1 + 2 + @as(usize, leafCap) * 8;
/// Byte offset of a leaf's first value slot (past kind and count).
pub const leafHeader: usize = 3;

/// Fixed inner allocation size.
/// Inner layout: [kind u8][childCount u16 LE][childCount * (childRef u64 LE, subtreeCount u64 LE)].
pub const innerNodeSize: usize = 1 + 2 + @as(usize, fanout) * 16;
/// Byte offset of an inner node's first child entry (past kind and count).
pub const innerHeader: usize = 3;

/// Encode `values` into `buffer` as a leaf node; returns the encoded byte
/// length.
pub fn encodeLeaf(buffer: []u8, values: []const u64) usize {
    std.debug.assert(values.len <= leafCap);
    buffer[0] = kindLeaf;
    std.mem.writeInt(u16, buffer[1..3], @intCast(values.len), .little);
    var offset: usize = leafHeader;
    for (values) |value| {
        std.mem.writeInt(u64, buffer[offset..][0..8], value, .little);
        offset += 8;
    }
    return offset;
}

/// A validated read-only view of a leaf node; construct via parseLeaf.
pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    /// The value stored at `entryIndex`.
    pub fn value(self: LeafView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[leafHeader + entryIndex * 8 ..][0..8], .little);
    }
};

/// Validate `bytes` as a leaf node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized count, or a short buffer.
pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < leafHeader) return error.Corrupt;
    if (bytes[0] != kindLeaf) return error.Corrupt;
    const count = std.mem.readInt(u16, bytes[1..3], .little);
    if (count > leafCap) return error.Corrupt;
    if (bytes.len < leafHeader + @as(usize, count) * 8) return error.Corrupt;
    return .{ .bytes = bytes, .count = count };
}

/// Encode the parallel (childRefs, childCounts) entries into `buffer` as an
/// inner node; returns the encoded byte length.
pub fn encodeInner(buffer: []u8, childRefs: []const u64, childCounts: []const u64) usize {
    std.debug.assert(childRefs.len == childCounts.len);
    std.debug.assert(childRefs.len <= fanout);
    buffer[0] = kindInner;
    std.mem.writeInt(u16, buffer[1..3], @intCast(childRefs.len), .little);
    var offset: usize = innerHeader;
    for (childRefs, childCounts) |ref, count| {
        std.mem.writeInt(u64, buffer[offset..][0..8], ref, .little);
        offset += 8;
        std.mem.writeInt(u64, buffer[offset..][0..8], count, .little);
        offset += 8;
    }
    return offset;
}

/// A validated read-only view of an inner node; construct via parseInner.
pub const InnerView = struct {
    bytes: []const u8,
    childCount: u16,
    /// The ref of child `entryIndex`.
    pub fn childRef(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[innerHeader + entryIndex * 16 ..][0..8], .little);
    }
    /// The number of values stored under child `entryIndex`.
    pub fn subtreeCount(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[innerHeader + entryIndex * 16 + 8 ..][0..8], .little);
    }
};

/// Validate `bytes` as an inner node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized child count, or a short buffer.
pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < innerHeader) return error.Corrupt;
    if (bytes[0] != kindInner) return error.Corrupt;
    const childCount = std.mem.readInt(u16, bytes[1..3], .little);
    if (childCount > fanout) return error.Corrupt;
    if (bytes.len < innerHeader + @as(usize, childCount) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .childCount = childCount };
}
