const std = @import("std");

pub const LEAF_CAP: u16 = 64;
pub const FANOUT: u16 = 64;
pub const kind_leaf: u8 = 0;
pub const kind_inner: u8 = 1;
pub const hdr: usize = 3; // [kind u8][count u16]
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
    const leaf_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (leaf_count > LEAF_CAP) return error.Corrupt;
    if (bytes.len < hdr + @as(usize, leaf_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = leaf_count };
}

// ---------------------------------------------------------------------------
// Inner-node encoding
// ---------------------------------------------------------------------------

pub fn encodeInner(buf: []u8, refs: []const u64, lows: []const u64) usize {
    std.debug.assert(refs.len == lows.len and refs.len <= FANOUT);
    buf[0] = kind_inner;
    std.mem.writeInt(u16, buf[1..3], @intCast(refs.len), .little);
    var off: usize = hdr;
    for (refs, lows) |r, l| {
        std.mem.writeInt(u64, buf[off..][0..8], r, .little);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], l, .little);
        off += 16;
    }
    return off;
}

pub const InnerView = struct {
    bytes: []const u8,
    child_count: u16,
    pub fn childRef(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 ..][0..8], .little);
    }
    pub fn lowKey(self: InnerView, i: usize) u64 {
        return std.mem.readInt(u64, self.bytes[hdr + i * 16 + 8 ..][0..8], .little);
    }
};

pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < hdr) return error.Corrupt;
    if (bytes[0] != kind_inner) return error.Corrupt;
    const child_count = std.mem.readInt(u16, bytes[1..3], .little);
    if (child_count > FANOUT) return error.Corrupt;
    if (bytes.len < hdr + @as(usize, child_count) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .child_count = child_count };
}
