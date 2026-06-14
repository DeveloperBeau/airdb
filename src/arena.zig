const std = @import("std");
const Ref = @import("ref.zig").Ref;

pub const Allocation = struct { ref: Ref, bytes: []u8 };

pub const Arena = struct {
    map: []u8,
    top: usize, // next free offset (append-only in Phase 1)

    pub fn init(map: []u8, data_start: usize) Arena {
        return .{ .map = map, .top = data_start };
    }

    pub fn alloc(self: *Arena, size: usize) error{OutOfSpace}!Allocation {
        const aligned = std.mem.alignForward(usize, self.top, 8);
        // Overflow-safe: check size alone, then use subtraction to avoid aligned+size overflow.
        if (size > self.map.len) return error.OutOfSpace;
        if (aligned > self.map.len - size) return error.OutOfSpace;
        const ref: Ref = @intCast(aligned);
        self.top = aligned + size;
        return .{ .ref = ref, .bytes = self.map[aligned .. aligned + size] };
    }

    // The single bounds-checked chokepoint. All reads go through here.
    pub fn deref(self: *Arena, ref: Ref, len: usize) error{BadRef}![]const u8 {
        const offv: usize = @intCast(ref);
        if (offv == 0) return error.BadRef; // null ref
        if (offv % 8 != 0) return error.BadRef; // misaligned
        // Overflow-safe: check len alone, then compare via subtraction.
        if (len > self.map.len) return error.BadRef;
        if (offv > self.map.len - len) return error.BadRef;
        return self.map[offv .. offv + len];
    }
};

const testing = std.testing;

test "alloc returns a writable slice that deref reads back" {
    const backing = try testing.allocator.alloc(u8, 4096 * 4);
    defer testing.allocator.free(backing);
    var arena = Arena.init(backing, 4096); // data starts after the first (header) page
    const a = try arena.alloc(8);
    @memcpy(a.bytes, "ABCDEFGH");
    const got = try arena.deref(a.ref, 8);
    try testing.expectEqualStrings("ABCDEFGH", got);
}

test "deref rejects an out-of-range or misaligned or null ref" {
    const backing = try testing.allocator.alloc(u8, 4096 * 4);
    defer testing.allocator.free(backing);
    var arena = Arena.init(backing, 4096);
    try testing.expectError(error.BadRef, arena.deref(backing.len + 8, 8));
    try testing.expectError(error.BadRef, arena.deref(7, 8)); // misaligned
    try testing.expectError(error.BadRef, arena.deref(0, 8)); // null ref
}

test "alloc fails cleanly when the arena is full" {
    const backing = try testing.allocator.alloc(u8, 4096 + 16);
    defer testing.allocator.free(backing);
    var arena = Arena.init(backing, 4096);
    _ = try arena.alloc(16);
    try testing.expectError(error.OutOfSpace, arena.alloc(8));
}
