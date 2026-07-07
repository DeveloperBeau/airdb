const std = @import("std");

pub const NodeKind = enum(u8) { leafValues, innerRefs, rawBytes };

pub const NodeHeader = struct {
    kind: NodeKind,
    elementCount: u32,
    pub const size: usize = 5; // [kind:u8][elementCount:u32 LE]

    pub fn encode(buffer: []u8, header: NodeHeader) EncodeResult {
        // Caller must provide >= size bytes. Under ReleaseSafe (this project's build mode) this assert is a safe trap, not UB.
        std.debug.assert(buffer.len >= size);
        buffer[0] = @intFromEnum(header.kind);
        std.mem.writeInt(u32, buffer[1..5], header.elementCount, .little);
        return .{ .headerLen = size };
    }
    pub const EncodeResult = struct {
        headerLen: usize,
        pub fn totalLenWithPayload(self: EncodeResult, payloadLen: usize) usize {
            return self.headerLen + payloadLen;
        }
    };
};

pub const NodeView = struct {
    header: NodeHeader,
    payload: []const u8,
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
        .{ .kind = .innerRefs, .count = 300 },
        .{ .kind = .rawBytes, .count = 4294967295 },
    };
    for (cases) |testCase| {
        var buffer: [16]u8 = undefined;
        const written = NodeHeader.encode(&buffer, .{ .kind = testCase.kind, .elementCount = testCase.count });
        const view = try NodeView.parse(buffer[0..written.totalLenWithPayload(0)]);
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
