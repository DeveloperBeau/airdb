const std = @import("std");
const Ref = @import("ref.zig").Ref;
const FreeList = @import("freelist.zig").FreeList;
const platform = @import("platform.zig");

const section_shift = platform.section_shift;
const section_size = platform.section_size;
const section_mask = platform.section_mask;

pub const Allocation = struct { ref: Ref, bytes: []u8 };

pub const Arena = struct {
    /// Append-only list of fixed-size sections owned by the FileStore. Never moved or
    /// remapped; growth appends new sections, so refs into existing sections stay valid.
    sections: []const platform.Section,
    top: usize, // next free offset (append-only in Phase 1)

    pub fn init(sections: []const platform.Section, data_start: usize) Arena {
        return .{ .sections = sections, .top = data_start };
    }

    /// Translate an absolute offset to the mutable backing slice for its section.
    /// The caller guarantees `[off, off + len)` does not cross a section boundary and
    /// that the section exists (true for any alloc result and any freed extent, since
    /// no allocation crosses a boundary).
    fn translate(self: *Arena, off: usize, len: usize) []u8 {
        const s = off >> section_shift;
        const w = off & section_mask;
        return self.sections[s].map[w .. w + len];
    }

    pub fn alloc(self: *Arena, size: usize) error{ OutOfSpace, AllocTooLarge }!Allocation {
        if (size > section_size) return error.AllocTooLarge;
        var aligned = std.mem.alignForward(usize, self.top, 8);
        // No allocation may cross a section boundary: if it would, pad to the next
        // section base (the tail of the current section is skipped and intentionally
        // lost). size <= section_size guarantees it then fits within one section.
        if ((aligned & section_mask) + size > section_size) {
            aligned = std.mem.alignForward(usize, aligned, section_size);
        }
        const s = aligned >> section_shift;
        if (s >= self.sections.len) return error.OutOfSpace; // caller grows + maps, then retries
        const ref: Ref = @intCast(aligned);
        self.top = aligned + size;
        return .{ .ref = ref, .bytes = self.translate(aligned, size) };
    }

    pub fn allocReusing(self: *Arena, size: usize, fl: *FreeList, horizon: u64) error{ OutOfSpace, AllocTooLarge }!Allocation {
        const aligned_size = std.mem.alignForward(usize, size, 8);
        if (fl.reuse(aligned_size, horizon)) |off| {
            const offu: usize = @intCast(off);
            return .{ .ref = off, .bytes = self.translate(offu, size) };
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
            return .{ .ref = off, .bytes = self.translate(offu, size) };
        }
        return null;
    }

    // The single bounds-checked chokepoint. All reads go through here.
    pub fn deref(self: *Arena, ref: Ref, len: usize) error{BadRef}![]const u8 {
        const off: usize = @intCast(ref);
        if (off == 0) return error.BadRef; // null ref
        if (off % 8 != 0) return error.BadRef; // misaligned
        if (len > section_size) return error.BadRef; // cannot span a section
        const s = off >> section_shift;
        const w = off & section_mask;
        if (s >= self.sections.len) return error.BadRef; // section not mapped
        if (w + len > section_size) return error.BadRef; // would cross a section boundary
        return self.sections[s].map[w .. w + len];
    }
};

const testing = std.testing;
const page = std.heap.page_size_min;
const page_align = std.mem.Alignment.fromByteUnits(page);

// Build a single Section wrapping a page-aligned heap allocation, for unit tests that
// only need a small backing region within section 0. The section's logical size is
// still section_size for boundary math; tests keep their offsets within `backing.len`.
// The handle is never used here (these sections are not unmapped), so on Windows it is
// left undefined; on POSIX it is the void sentinel.
fn testSection(backing: []align(page) u8) platform.Section {
    const handle = if (@import("builtin").os.tag == .windows) undefined else {};
    return .{ .map = backing, .handle = handle };
}

test "alloc returns a writable slice that deref reads back" {
    const backing = try testing.allocator.alignedAlloc(u8, page_align, 4096 * 4);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096); // data starts after the first (header) page
    const a = try arena.alloc(8);
    @memcpy(a.bytes, "ABCDEFGH");
    const got = try arena.deref(a.ref, 8);
    try testing.expectEqualStrings("ABCDEFGH", got);
}

test "deref rejects an out-of-range or misaligned or null ref" {
    const backing = try testing.allocator.alignedAlloc(u8, page_align, 4096 * 4);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096);
    // A ref in section 1, which is not mapped (only section 0 exists).
    try testing.expectError(error.BadRef, arena.deref(section_size, 8));
    try testing.expectError(error.BadRef, arena.deref(7, 8)); // misaligned
    try testing.expectError(error.BadRef, arena.deref(0, 8)); // null ref
}

test "allocReusing reuses a freed extent below the horizon, else bumps" {
    const backing = try testing.allocator.alignedAlloc(u8, page_align, 4096 * 4);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096);

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
    const backing = try testing.allocator.alignedAlloc(u8, page_align, 4096);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096);
    // Drive top to the end of the only section; the next alloc must pad past the
    // section boundary into a section that does not exist -> OutOfSpace.
    arena.top = section_size - 8;
    try testing.expectError(error.OutOfSpace, arena.alloc(16));
}

test "alloc pads across a section boundary and AllocTooLarge on oversize" {
    const b0 = try testing.allocator.alignedAlloc(u8, page_align, 4096);
    defer testing.allocator.free(b0);
    const b1 = try testing.allocator.alignedAlloc(u8, page_align, 4096);
    defer testing.allocator.free(b1);
    var secs = [_]platform.Section{ testSection(b0), testSection(b1) };
    var arena = Arena.init(&secs, 0);

    // Place top near the end of section 0 so the next alloc cannot fit and must pad
    // to section 1's base.
    arena.top = section_size - 16;
    const a = try arena.alloc(32);
    try testing.expectEqual(@as(Ref, @intCast(section_size)), a.ref); // landed at section 1 base
    @memcpy(a.bytes, "0123456789ABCDEF0123456789ABCDEF");
    const got = try arena.deref(a.ref, 32);
    try testing.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF", got);

    // A single allocation larger than a section is rejected.
    try testing.expectError(error.AllocTooLarge, arena.alloc(section_size + 1));
}
