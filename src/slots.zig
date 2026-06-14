const std = @import("std");
const Ref = @import("ref.zig").Ref;

pub const Slot = struct {
    version: u64,
    root_ref: Ref,
    logical_size: u64,
    pub const size: usize = 28;

    pub fn encode(self: Slot, buf: []u8) void {
        std.debug.assert(buf.len >= size);
        std.mem.writeInt(u64, buf[0..8], self.version, .little);
        std.mem.writeInt(u64, buf[8..16], self.root_ref, .little);
        std.mem.writeInt(u64, buf[16..24], self.logical_size, .little);
        const crc = std.hash.Crc32.hash(buf[0..24]);
        std.mem.writeInt(u32, buf[24..28], crc, .little);
    }

    pub fn decode(buf: []const u8) error{BadChecksum}!Slot {
        std.debug.assert(buf.len >= size);
        const stored = std.mem.readInt(u32, buf[24..28], .little);
        const actual = std.hash.Crc32.hash(buf[0..24]);
        if (stored != actual) return error.BadChecksum;
        return .{
            .version = std.mem.readInt(u64, buf[0..8], .little),
            .root_ref = std.mem.readInt(u64, buf[8..16], .little),
            .logical_size = std.mem.readInt(u64, buf[16..24], .little),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "slot encode/decode round-trips and checksum validates" {
    var buf: [Slot.size]u8 = undefined;
    const s = Slot{ .version = 7, .root_ref = 4096, .logical_size = 8192 };
    s.encode(&buf);
    const decoded = try Slot.decode(&buf);
    try testing.expectEqual(@as(u64, 7), decoded.version);
    try testing.expectEqual(@as(u64, 4096), decoded.root_ref);
}

test "decode rejects a corrupted slot" {
    var buf: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .root_ref = 4096, .logical_size = 8192 }).encode(&buf);
    buf[4] ^= 0xFF;
    try testing.expectError(error.BadChecksum, Slot.decode(&buf));
}
