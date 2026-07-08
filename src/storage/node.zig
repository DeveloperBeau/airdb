const std = @import("std");

/// Kind byte of a generic storage node: leaf values, inner references, or raw bytes.
pub const NodeKind = enum(u8) { leafValues, innerReferences, rawBytes };

/// The header every generic storage node starts with: a kind byte plus a
/// little-endian element count.
pub const NodeHeader = struct {
    kind: NodeKind,
    elementCount: u32,
    /// Encoded header size: [kind:u8][elementCount:u32 LE].
    pub const size: usize = 5;

    /// Encode the header into the first `size` bytes of `buffer` (the caller
    /// supplies at least `size` bytes).
    pub fn encode(buffer: []u8, header: NodeHeader) EncodeResult {
        // Caller must provide >= size bytes. Under ReleaseSafe (this project's build mode) this assert is a safe trap, not UB.
        std.debug.assert(buffer.len >= size);
        buffer[0] = @intFromEnum(header.kind);
        std.mem.writeInt(u32, buffer[1..5], header.elementCount, .little);
        return .{ .headerLen = size };
    }
    /// The encoded header length, with a helper to size the full node.
    pub const EncodeResult = struct {
        headerLen: usize,
        /// Total node length: the header plus a `payloadLen`-byte payload.
        pub fn totalLengthWithPayload(self: EncodeResult, payloadLen: usize) usize {
            return self.headerLen + payloadLen;
        }
    };
};

/// A parsed node: its header plus the payload slice that follows it.
pub const NodeView = struct {
    header: NodeHeader,
    payload: []const u8,
    /// Validate and split `bytes` into header and payload; error.Corrupt on a
    /// short buffer or an out-of-range kind byte.
    pub fn parse(bytes: []const u8) error{Corrupt}!NodeView {
        if (bytes.len < NodeHeader.size) return error.Corrupt;
        const rawKind = bytes[0];
        if (rawKind > @intFromEnum(NodeKind.rawBytes)) return error.Corrupt;
        return .{
            .header = .{
                .kind = @enumFromInt(rawKind),
                .elementCount = std.mem.readInt(u32, bytes[1..5], .little),
            },
            .payload = bytes[NodeHeader.size..],
        };
    }
};

const testing = std.testing;

test "encode then decode node header round-trips for every kind" {
    const cases = [_]struct { kind: NodeKind, count: u32 }{
        .{ .kind = .leafValues, .count = 0 },
        .{ .kind = .innerReferences, .count = 300 },
        .{ .kind = .rawBytes, .count = 4294967295 },
    };
    for (cases) |testCase| {
        var buffer: [16]u8 = undefined;
        const written = NodeHeader.encode(&buffer, .{ .kind = testCase.kind, .elementCount = testCase.count });
        const view = try NodeView.parse(buffer[0..written.totalLengthWithPayload(0)]);
        try testing.expectEqual(testCase.kind, view.header.kind);
        try testing.expectEqual(testCase.count, view.header.elementCount);
    }
}

test "parse rejects a truncated buffer" {
    const tiny = [_]u8{0x01};
    try testing.expectError(error.Corrupt, NodeView.parse(&tiny));
}

test "parse rejects an out-of-range kind byte" {
    var buffer: [NodeHeader.size]u8 = undefined;
    buffer[0] = 3; // one past rawBytes (2)
    std.mem.writeInt(u32, buffer[1..5], 0, .little);
    try testing.expectError(error.Corrupt, NodeView.parse(&buffer));
}
