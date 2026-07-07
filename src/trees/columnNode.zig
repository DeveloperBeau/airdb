const std = @import("std");

pub const leafCap: u16 = 64;
pub const fanout: u16 = 64;
pub const kind_leaf: u8 = 0;
pub const kind_inner: u8 = 1;

// Leaf layout: [kind u8][count u16 LE][count * u64 LE]
pub const leaf_node_size: usize = 1 + 2 + @as(usize, leafCap) * 8;
pub const leaf_header: usize = 3;

// Inner layout: [kind u8][child_count u16 LE][child_count * (child_ref u64 LE, subtree_count u64 LE)]
pub const inner_node_size: usize = 1 + 2 + @as(usize, fanout) * 16;
pub const inner_header: usize = 3;

pub fn encodeLeaf(buffer: []u8, values: []const u64) usize {
    std.debug.assert(values.len <= leafCap);
    buffer[0] = kind_leaf;
    std.mem.writeInt(u16, buffer[1..3], @intCast(values.len), .little);
    var off: usize = leaf_header;
    for (values) |v| {
        std.mem.writeInt(u64, buffer[off..][0..8], v, .little);
        off += 8;
    }
    return off;
}

pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    pub fn value(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[leaf_header + i * 8 ..][0..8], .little);
    }
};

pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < leaf_header) return error.Corrupt;
    if (bytes[0] != kind_leaf) return error.Corrupt;
    const count = std.mem.readInt(u16, bytes[1..3], .little);
    if (count > leafCap) return error.Corrupt;
    if (bytes.len < leaf_header + @as(usize, count) * 8) return error.Corrupt;
    return .{ .bytes = bytes, .count = count };
}

pub fn encodeInner(buffer: []u8, child_refs: []const u64, child_counts: []const u64) usize {
    std.debug.assert(child_refs.len == child_counts.len);
    std.debug.assert(child_refs.len <= fanout);
    buffer[0] = kind_inner;
    std.mem.writeInt(u16, buffer[1..3], @intCast(child_refs.len), .little);
    var off: usize = inner_header;
    for (child_refs, child_counts) |r, c| {
        std.mem.writeInt(u64, buffer[off..][0..8], r, .little);
        off += 8;
        std.mem.writeInt(u64, buffer[off..][0..8], c, .little);
        off += 8;
    }
    return off;
}

pub const InnerView = struct {
    bytes: []const u8,
    child_count: u16,
    pub fn childRef(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[inner_header + i * 16 ..][0..8], .little);
    }
    pub fn childCount(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[inner_header + i * 16 + 8 ..][0..8], .little);
    }
};

pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < inner_header) return error.Corrupt;
    if (bytes[0] != kind_inner) return error.Corrupt;
    const child_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (child_count > fanout) return error.Corrupt;
    if (bytes.len < inner_header + @as(usize, child_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .child_count = child_count };
}
