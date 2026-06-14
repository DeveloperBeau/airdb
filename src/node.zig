const std = @import("std");

pub const NodeKind = enum(u8) { leaf_values, inner_refs, raw_bytes };

pub const NodeHeader = struct {
    kind: NodeKind,
    element_count: u32,
    pub const size: usize = 5; // [kind:u8][element_count:u32 LE]

    pub fn encode(buf: []u8, h: NodeHeader) EncodeResult {
        std.debug.assert(buf.len >= size);
        buf[0] = @intFromEnum(h.kind);
        std.mem.writeInt(u32, buf[1..5], h.element_count, .little);
        return .{ .header_len = size };
    }
    pub const EncodeResult = struct {
        header_len: usize,
        pub fn total_len_with_payload(self: EncodeResult, payload_len: usize) usize {
            return self.header_len + payload_len;
        }
    };
};

pub const NodeView = struct {
    header: NodeHeader,
    payload: []const u8,
    pub fn parse(bytes: []const u8) error{Corrupt}!NodeView {
        if (bytes.len < NodeHeader.size) return error.Corrupt;
        const raw_kind = bytes[0];
        if (raw_kind > @intFromEnum(NodeKind.raw_bytes)) return error.Corrupt;
        return .{
            .header = .{
                .kind = @enumFromInt(raw_kind),
                .element_count = std.mem.readInt(u32, bytes[1..5], .little),
            },
            .payload = bytes[NodeHeader.size..],
        };
    }
};

const testing = std.testing;

test "encode then decode node header round-trips" {
    var buf: [16]u8 = undefined;
    const written = NodeHeader.encode(&buf, .{ .kind = .leaf_values, .element_count = 300 });
    const view = try NodeView.parse(buf[0..written.total_len_with_payload(0)]);
    try testing.expectEqual(NodeKind.leaf_values, view.header.kind);
    try testing.expectEqual(@as(u32, 300), view.header.element_count);
}

test "parse rejects a truncated buffer" {
    const tiny = [_]u8{0x01};
    try testing.expectError(error.Corrupt, NodeView.parse(&tiny));
}
