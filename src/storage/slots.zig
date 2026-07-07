const std = @import("std");
const Reference = @import("reference.zig").Reference;

/// One of the two commit slots in the header page: the durable record of a
/// committed version -- its version number, root ref, persisted free-list
/// head, and logical file size -- protected by a CRC32.
pub const Slot = struct {
    version: u64,
    rootRef: Reference,
    freeListRef: Reference,
    logicalSize: u64,
    /// Encoded slot size in bytes: four u64 fields plus the CRC32.
    pub const size: usize = 36;

    /// Encode the slot into `buffer` (at least `size` bytes), stamping a
    /// CRC32 over the fields.
    pub fn encode(self: Slot, buffer: []u8) void {
        std.debug.assert(buffer.len >= size);
        std.mem.writeInt(u64, buffer[0..8], self.version, .little);
        std.mem.writeInt(u64, buffer[8..16], self.rootRef, .little);
        std.mem.writeInt(u64, buffer[16..24], self.freeListRef, .little);
        std.mem.writeInt(u64, buffer[24..32], self.logicalSize, .little);
        std.mem.writeInt(u32, buffer[32..36], std.hash.Crc32.hash(buffer[0..32]), .little);
    }

    /// Decode a slot from `buffer`, verifying its CRC32; error.BadChecksum
    /// when the stored checksum does not match the fields.
    pub fn decode(buffer: []const u8) error{BadChecksum}!Slot {
        std.debug.assert(buffer.len >= size);
        const stored = std.mem.readInt(u32, buffer[32..36], .little);
        if (stored != std.hash.Crc32.hash(buffer[0..32])) return error.BadChecksum;
        return .{
            .version = std.mem.readInt(u64, buffer[0..8], .little),
            .rootRef = std.mem.readInt(u64, buffer[8..16], .little),
            .freeListRef = std.mem.readInt(u64, buffer[16..24], .little),
            .logicalSize = std.mem.readInt(u64, buffer[24..32], .little),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "slot encode/decode round-trips and checksum validates" {
    var buffer: [Slot.size]u8 = undefined;
    const slot = Slot{ .version = 7, .rootRef = 4096, .freeListRef = 8192, .logicalSize = 12288 };
    slot.encode(&buffer);
    const decoded = try Slot.decode(&buffer);
    try testing.expectEqual(@as(u64, 7), decoded.version);
    try testing.expectEqual(@as(u64, 4096), decoded.rootRef);
    try testing.expectEqual(@as(u64, 8192), decoded.freeListRef);
    try testing.expectEqual(@as(u64, 12288), decoded.logicalSize);
}

test "decode rejects a corrupted slot" {
    var buffer: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .rootRef = 4096, .freeListRef = 0, .logicalSize = 8192 }).encode(&buffer);
    buffer[4] ^= 0xFF;
    try testing.expectError(error.BadChecksum, Slot.decode(&buffer));
}
