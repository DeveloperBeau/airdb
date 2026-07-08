const std = @import("std");
const Reference = @import("reference.zig").Reference;
const FreeList = @import("freeList.zig").FreeList;
const platform = @import("../platform.zig");

const sectionShift = platform.sectionShift;
const sectionSize = platform.sectionSize;
const sectionMask = platform.sectionMask;

/// A fresh or reused arena extent: its stable reference and the writable mapped
/// bytes behind it.
pub const Allocation = struct { reference: Reference, bytes: []u8 };

/// Bump allocator over the file's mapped sections, with exact-class reuse
/// from a FreeList pool, and the single bounds-checked dereference chokepoint every
/// reference read goes through.
pub const Arena = struct {
    /// Append-only list of fixed-size sections owned by the FileStore. Never moved or
    /// remapped; growth appends new sections, so references into existing sections stay valid.
    sections: []const platform.Section,
    top: usize, // next free offset (append-only in Phase 1)

    /// An arena over `sections` whose bump pointer starts at `dataStart`.
    pub fn init(sections: []const platform.Section, dataStart: usize) Arena {
        return .{ .sections = sections, .top = dataStart };
    }

    /// Translate an absolute offset to the mutable backing slice for its section.
    /// The caller guarantees `[off, off + length)` does not cross a section boundary and
    /// that the section exists (true for any alloc result and any freed extent, since
    /// no allocation crosses a boundary).
    fn translate(self: *Arena, offset: usize, length: usize) []u8 {
        const sectionIndex = offset >> sectionShift;
        const withinSection = offset & sectionMask;
        return self.sections[sectionIndex].map[withinSection .. withinSection + length];
    }

    /// Bump-allocate `size` bytes, 8-aligned and never crossing a section
    /// boundary (a request that would is padded to the next section base).
    /// error.AllocTooLarge above one section; error.OutOfSpace when no mapped
    /// section remains -- the caller grows and maps the file, then retries.
    pub fn alloc(self: *Arena, size: usize) error{ OutOfSpace, AllocTooLarge }!Allocation {
        if (size > sectionSize) return error.AllocTooLarge;
        var aligned = std.mem.alignForward(usize, self.top, 8);
        // No allocation may cross a section boundary: if it would, pad to the next
        // section base (the tail of the current section is skipped and intentionally
        // lost). size <= sectionSize guarantees it then fits within one section.
        if ((aligned & sectionMask) + size > sectionSize) {
            aligned = std.mem.alignForward(usize, aligned, sectionSize);
        }
        const sectionIndex = aligned >> sectionShift;
        if (sectionIndex >= self.sections.len) return error.OutOfSpace; // caller grows + maps, then retries
        const reference: Reference = @intCast(aligned);
        self.top = aligned + size;
        return .{ .reference = reference, .bytes = self.translate(aligned, size) };
    }

    /// Reuse an EXACT-size node extent from `pool` whose freedVersion <=
    /// horizon, else null (no bump fallback, no carving). Exact-size matching
    /// keeps fixed-size node allocation fragment-free and the pool probe
    /// short. For a transaction-private pool (always safe to reuse) pass
    /// horizon = maxInt; for the committed pool pass the reclaim horizon.
    pub fn allocFromPool(self: *Arena, pool: *FreeList, size: usize, horizon: u64) ?Allocation {
        if (pool.reuseExact(@intCast(size), horizon)) |offset| {
            const offu: usize = @intCast(offset);
            return .{ .reference = offset, .bytes = self.translate(offu, size) };
        }
        return null;
    }

    /// Translate `reference` into a read-only slice of `length` bytes. The single
    /// bounds-checked chokepoint all reads go through: a null, misaligned,
    /// unmapped, oversize, or section-crossing reference is error.BadReference.
    pub fn dereference(self: *Arena, reference: Reference, length: usize) error{BadReference}![]const u8 {
        const offset: usize = @intCast(reference);
        if (offset == 0) return error.BadReference; // null reference
        if (offset % 8 != 0) return error.BadReference; // misaligned
        if (length > sectionSize) return error.BadReference; // cannot span a section
        const sectionIndex = offset >> sectionShift;
        const withinSection = offset & sectionMask;
        if (sectionIndex >= self.sections.len) return error.BadReference; // section not mapped
        if (withinSection + length > sectionSize) return error.BadReference; // would cross a section boundary
        return self.sections[sectionIndex].map[withinSection .. withinSection + length];
    }
};

const testing = std.testing;
const page = std.heap.page_size_min;
const pageAlign = std.mem.Alignment.fromByteUnits(page);

// Build a single Section wrapping a page-aligned heap allocation, for unit tests that
// only need a small backing region within section 0. The section's logical size is
// still sectionSize for boundary math; tests keep their offsets within `backing.len`.
// The handle is never used here (these sections are not unmapped), so on Windows it is
// left undefined; on POSIX it is the void sentinel.
fn testSection(backing: []align(page) u8) platform.Section {
    const handle = if (@import("builtin").os.tag == .windows) undefined else {};
    return .{ .map = backing, .handle = handle };
}

test "alloc returns a writable slice that dereference reads back" {
    const backing = try testing.allocator.alignedAlloc(u8, pageAlign, 4096 * 4);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096); // data starts after the first (header) page
    const allocation = try arena.alloc(8);
    @memcpy(allocation.bytes, "ABCDEFGH");
    const got = try arena.dereference(allocation.reference, 8);
    try testing.expectEqualStrings("ABCDEFGH", got);
}

test "dereference rejects an out-of-range or misaligned or null reference" {
    const backing = try testing.allocator.alignedAlloc(u8, pageAlign, 4096 * 4);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096);
    // A reference in section 1, which is not mapped (only section 0 exists).
    try testing.expectError(error.BadReference, arena.dereference(sectionSize, 8));
    try testing.expectError(error.BadReference, arena.dereference(7, 8)); // misaligned
    try testing.expectError(error.BadReference, arena.dereference(0, 8)); // null reference
}

test "alloc fails cleanly when the arena is full" {
    const backing = try testing.allocator.alignedAlloc(u8, pageAlign, 4096);
    defer testing.allocator.free(backing);
    var secs = [_]platform.Section{testSection(backing)};
    var arena = Arena.init(&secs, 4096);
    // Drive top to the end of the only section; the next alloc must pad past the
    // section boundary into a section that does not exist -> OutOfSpace.
    arena.top = sectionSize - 8;
    try testing.expectError(error.OutOfSpace, arena.alloc(16));
}

test "alloc pads across a section boundary and AllocTooLarge on oversize" {
    const firstBuffer = try testing.allocator.alignedAlloc(u8, pageAlign, 4096);
    defer testing.allocator.free(firstBuffer);
    const secondBuffer = try testing.allocator.alignedAlloc(u8, pageAlign, 4096);
    defer testing.allocator.free(secondBuffer);
    var secs = [_]platform.Section{ testSection(firstBuffer), testSection(secondBuffer) };
    var arena = Arena.init(&secs, 0);

    // Place top near the end of section 0 so the next alloc cannot fit and must pad
    // to section 1's base.
    arena.top = sectionSize - 16;
    const allocation = try arena.alloc(32);
    try testing.expectEqual(@as(Reference, @intCast(sectionSize)), allocation.reference); // landed at section 1 base
    @memcpy(allocation.bytes, "0123456789ABCDEF0123456789ABCDEF");
    const got = try arena.dereference(allocation.reference, 32);
    try testing.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF", got);

    // A single allocation larger than a section is rejected.
    try testing.expectError(error.AllocTooLarge, arena.alloc(sectionSize + 1));
}
