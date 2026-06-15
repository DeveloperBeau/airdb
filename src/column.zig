const std = @import("std");

pub const LEAF_CAP: u16 = 64;
pub const FANOUT: u16 = 64;
const kind_leaf: u8 = 0;
const kind_inner: u8 = 1;

// Leaf layout: [kind u8][count u16 LE][count * u64 LE]
pub const leaf_node_size: usize = 1 + 2 + @as(usize, LEAF_CAP) * 8;
const leaf_header: usize = 3;

pub fn encodeLeaf(buf: []u8, values: []const u64) usize {
    std.debug.assert(values.len <= LEAF_CAP);
    buf[0] = kind_leaf;
    std.mem.writeInt(u16, buf[1..3], @intCast(values.len), .little);
    var off: usize = leaf_header;
    for (values) |v| {
        std.mem.writeInt(u64, buf[off..][0..8], v, .little);
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
    if (count > LEAF_CAP) return error.Corrupt;
    if (bytes.len < leaf_header + @as(usize, count) * 8) return error.Corrupt;
    return .{ .bytes = bytes, .count = count };
}

test "leaf encode/decode round-trips values" {
    var buf: [leaf_node_size]u8 = undefined;
    const vals = [_]u64{ 10, 20, 30 };
    const n = encodeLeaf(&buf, &vals);
    const view = try parseLeaf(buf[0..n]);
    try std.testing.expectEqual(@as(u16, 3), view.count);
    try std.testing.expectEqual(@as(u64, 20), view.value(1));
}

test "parseLeaf rejects a buffer too small for its declared count" {
    var buf: [16]u8 = undefined;
    buf[0] = 0; // kind = leaf
    std.mem.writeInt(u16, buf[1..3], 100, .little); // claims 100 values
    try std.testing.expectError(error.Corrupt, parseLeaf(buf[0..16]));
}
