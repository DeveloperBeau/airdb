const std = @import("std");

pub const LEAF_CAP: u16 = 64;
pub const FANOUT: u16 = 64;
const kind_leaf: u8 = 0;
const kind_inner: u8 = 1;
const hdr: usize = 3; // [kind u8][count u16]
pub const leaf_node_size: usize = hdr + @as(usize, LEAF_CAP) * 16; // (key,value)
pub const inner_node_size: usize = hdr + @as(usize, FANOUT) * 16; // (child_ref,low_key)

pub fn encodeLeaf(buf: []u8, keys: []const u64, vals: []const u64) usize {
    std.debug.assert(keys.len == vals.len and keys.len <= LEAF_CAP);
    buf[0] = kind_leaf;
    std.mem.writeInt(u16, buf[1..3], @intCast(keys.len), .little);
    var off: usize = hdr;
    for (keys, vals) |k, v| {
        std.mem.writeInt(u64, buf[off..][0..8], k, .little);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], v, .little);
        off += 16;
    }
    return off;
}

pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    pub fn key(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 ..][0..8], .little);
    }
    pub fn value(self: LeafView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 + 8 ..][0..8], .little);
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
    if (bytes.len < hdr) return error.Corrupt;
    if (bytes[0] != kind_leaf) return error.Corrupt;
    const count = std.mem.readInt(u16, bytes[1..3], .little);
    if (count > LEAF_CAP) return error.Corrupt;
    if (bytes.len < hdr + @as(usize, count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = count };
}

test "leaf encode/decode round-trips sorted pairs" {
    var buf: [leaf_node_size]u8 = undefined;
    const keys = [_]u64{ 1, 5, 9 };
    const vals = [_]u64{ 10, 50, 90 };
    const n = encodeLeaf(&buf, &keys, &vals);
    const v = try parseLeaf(buf[0..n]);
    try std.testing.expectEqual(@as(u16, 3), v.count);
    try std.testing.expectEqual(@as(u64, 5), v.key(1));
    try std.testing.expectEqual(@as(u64, 90), v.value(2));
}

test "lowerBound finds the first index whose key is >= the search key" {
    var buf: [leaf_node_size]u8 = undefined;
    const keys = [_]u64{ 2, 4, 6, 8 };
    const vals = [_]u64{ 0, 0, 0, 0 };
    const n = encodeLeaf(&buf, &keys, &vals);
    const v = try parseLeaf(buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), v.lowerBound(1));
    try std.testing.expectEqual(@as(usize, 1), v.lowerBound(4));
    try std.testing.expectEqual(@as(usize, 2), v.lowerBound(5));
    try std.testing.expectEqual(@as(usize, 4), v.lowerBound(9));
}
