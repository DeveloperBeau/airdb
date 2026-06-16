const std = @import("std");
const Ref = @import("ref.zig").Ref;
const FreeList = @import("freelist.zig").FreeList;

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

    pub fn allocReusing(self: *Arena, size: usize, fl: *FreeList, horizon: u64) error{OutOfSpace}!Allocation {
        const aligned_size = std.mem.alignForward(usize, size, 8);
        if (fl.reuse(aligned_size, horizon)) |off| {
            const offu: usize = @intCast(off);
            return .{ .ref = off, .bytes = self.map[offu .. offu + size] };
        }
        return self.alloc(size);
    }

    // Reuse an EXACT-size node extent from a pool whose freed_version <= horizon, else null
    // (no bump fallback, no carving). Exact-size matching keeps fixed-size node allocation
    // fragment-free and the pool scan short. For a transaction-private pool (always safe to
    // reuse) pass horizon = maxInt; for the committed pool pass the reclaim horizon.
    pub fn allocFromPool(self: *Arena, fl: *FreeList, size: usize, horizon: u64) ?Allocation {
        if (fl.reuseExact(@intCast(size), horizon)) |off| {
            const offu: usize = @intCast(off);
            return .{ .ref = off, .bytes = self.map[offu .. offu + size] };
        }
        return null;
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

test "allocReusing reuses a freed extent below the horizon, else bumps" {
    const backing = try testing.allocator.alloc(u8, 4096 * 4);
    defer testing.allocator.free(backing);
    var arena = Arena.init(backing, 4096);

    var fl = @import("freelist.zig").FreeList.init(testing.allocator);
    defer fl.deinit();
    try fl.add(.{ .offset = 4096, .len = 64, .freed_version = 2 });

    const bumped = try arena.allocReusing(16, &fl, 1); // horizon 1 < freed 2: bump
    try testing.expect(bumped.ref >= 4096);
    try testing.expectEqual(@as(usize, 1), fl.extents.items.len);

    const reused = try arena.allocReusing(16, &fl, 2); // horizon 2 >= freed 2: reuse
    try testing.expectEqual(@as(u64, 4096), reused.ref);
}

test "alloc fails cleanly when the arena is full" {
    const backing = try testing.allocator.alloc(u8, 4096 + 16);
    defer testing.allocator.free(backing);
    var arena = Arena.init(backing, 4096);
    _ = try arena.alloc(16);
    try testing.expectError(error.OutOfSpace, arena.alloc(8));
}
