const std = @import("std");
const Ref = @import("ref.zig").Ref;

pub const Slot = struct {
    version: u64,
    root_ref: Ref,
    free_list_ref: Ref,
    logical_size: u64,
    pub const size: usize = 36;

    pub fn encode(self: Slot, buf: []u8) void {
        std.debug.assert(buf.len >= size);
        std.mem.writeInt(u64, buf[0..8], self.version, .little);
        std.mem.writeInt(u64, buf[8..16], self.root_ref, .little);
        std.mem.writeInt(u64, buf[16..24], self.free_list_ref, .little);
        std.mem.writeInt(u64, buf[24..32], self.logical_size, .little);
        std.mem.writeInt(u32, buf[32..36], std.hash.Crc32.hash(buf[0..32]), .little);
    }

    pub fn decode(buf: []const u8) error{BadChecksum}!Slot {
        std.debug.assert(buf.len >= size);
        const stored = std.mem.readInt(u32, buf[32..36], .little);
        if (stored != std.hash.Crc32.hash(buf[0..32])) return error.BadChecksum;
        return .{
            .version = std.mem.readInt(u64, buf[0..8], .little),
            .root_ref = std.mem.readInt(u64, buf[8..16], .little),
            .free_list_ref = std.mem.readInt(u64, buf[16..24], .little),
            .logical_size = std.mem.readInt(u64, buf[24..32], .little),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "slot encode/decode round-trips and checksum validates" {
    var buf: [Slot.size]u8 = undefined;
    const s = Slot{ .version = 7, .root_ref = 4096, .free_list_ref = 8192, .logical_size = 12288 };
    s.encode(&buf);
    const decoded = try Slot.decode(&buf);
    try testing.expectEqual(@as(u64, 7), decoded.version);
    try testing.expectEqual(@as(u64, 4096), decoded.root_ref);
    try testing.expectEqual(@as(u64, 8192), decoded.free_list_ref);
    try testing.expectEqual(@as(u64, 12288), decoded.logical_size);
}

test "decode rejects a corrupted slot" {
    var buf: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .root_ref = 4096, .free_list_ref = 0, .logical_size = 8192 }).encode(&buf);
    buf[4] ^= 0xFF;
    try testing.expectError(error.BadChecksum, Slot.decode(&buf));
}
