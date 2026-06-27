// file_store.zig -- header, mmap, and injectable Syncer for airdb.
//
// Zig 0.16 adaptations from the task spec:
//   - std.fs.File           -> std.Io.File  (std.fs.File removed in 0.16)
//   - std.fs.createFileAbsolute/openFileAbsolute
//                           -> std.Io.Dir.createFileAbsolute/openFileAbsolute(io, ...)
//   - File.setEndPos(n)     -> File.setLength(io, n)
//   - File.getEndPos()      -> File.length(io) -> u64
//   - File.sync()           -> File.sync(io)
//   - File.close()          -> File.close(io)
//   - mmap alignment        -> []align(std.heap.page_size_min) u8
//   - mmap flags            -> .{ .TYPE = .SHARED } (not .SHARED = true)
//   - page-size constant    -> std.heap.page_size_min (compile-time lower bound)
//   - Dir.realpathAlloc     -> Dir.realPath(io, buf) with stack buffer
//   - Io instance           -> std.Io.Threaded.global_single_threaded.io()
//       (always initialized; works in both test and production contexts)

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("platform.zig");
const Syncer = @import("syncer.zig").Syncer;
const RealSyncer = @import("syncer.zig").RealSyncer;

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

pub const airdb_magic: u64 = 0x6169726462_0001;
pub const default_page_size: u32 = 4096;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Endianness = enum(u8) { little = 1, big = 2 };

pub const Header = struct {
    magic: u64,
    page_size: u32,
    endianness: Endianness,
    active_slot: u8,
    logical_size: u64,
};

// ---------------------------------------------------------------------------
// FileStore
// ---------------------------------------------------------------------------

pub const FileStore = struct {
    allocator: std.mem.Allocator, // reserved for future allocations (buffer pool, catalog pages)
    file: Io.File,
    /// Always points at section 0's mapping. The header and the two commit slots live in
    /// section 0, so every `store.map[...]` access (header, slots) stays correct.
    map: []align(std.heap.page_size_min) u8,
    /// Append-only list of fixed-size sections covering the file. Existing entries are
    /// never remapped or moved on growth; growth only appends. Unmapped in deinit.
    sections: std.ArrayList(platform.Section),
    header: Header,
    syncer: Syncer,
    /// True when the header CRC32 matches the stored checksum at [28..32].
    /// Set by readHeader (open path) or to true after writeHeader (create/persistHeader path).
    /// Recovery in db.zig openWith reads this to decide whether to trust active_slot.
    header_checksum_ok: bool,
    /// Measurement-only counters accumulated since open. Total nanoseconds spent in
    /// blocking file.setLength (file growth) and the number of such calls. Read via
    /// Db.metrics(); never affect behavior.
    setlength_ns: u64 = 0,
    setlength_calls: u64 = 0,

    /// Per-open maximum file size; caps the number of sections (max_sections =
    /// max_reserved / section_size). See `platform.max_reserved` for the host-size split.
    pub const max_reserved: usize = platform.max_reserved;

    /// Returns the blocking Io instance used for all file operations.
    /// This is always initialized (compile-time constant vtable), so it
    /// works in both test and production contexts without passing Io around.
    // Phase 1 single-process/single-thread only. Phase 4 (multi-process/threaded) must replace this global Io.
    inline fn sysIo() Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    /// Create a new database file at the given absolute path, truncating any
    /// existing file. Maps section 0 and writes the header.
    pub fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        syncer: Syncer,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = true,
        });
        errdefer file.close(io);

        var fs = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = .{
                .magic = airdb_magic,
                .page_size = default_page_size,
                .endianness = .little,
                .active_slot = 0,
                .logical_size = default_page_size,
            },
            .syncer = syncer,
            .header_checksum_ok = false, // set to true after writeHeader below
        };
        errdefer {
            for (fs.sections.items) |*s| s.unmap();
            fs.sections.deinit(allocator);
        }

        // Extend the file to one section and map it; header + commit slots live here.
        try fs.ensureMapped(platform.section_size);

        fs.writeHeader();
        fs.header_checksum_ok = true;
        try fs.syncer.flush(fs.file);
        return fs;
    }

    /// Open an existing database file at the given absolute path.
    /// Validates the header magic and endianness.
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        syncer: Syncer,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const file_len = try file.length(io);
        if (file_len < default_page_size) return error.Corrupt;

        var fs = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = undefined,
            .syncer = syncer,
            .header_checksum_ok = false, // set by readHeader below
        };
        errdefer {
            for (fs.sections.items) |*s| s.unmap();
            fs.sections.deinit(allocator);
        }

        // Map all sections covering the existing file. ensureMapped rounds the file up to
        // a whole-section multiple first (an old file whose length is not a section
        // multiple is extended via setLength before mapping), so every section is fully
        // backed before any deref.
        try fs.ensureMapped(@intCast(file_len));
        try fs.readHeader();
        return fs;
    }

    /// Unmap every section and close the file.
    pub fn deinit(self: *FileStore) void {
        for (self.sections.items) |*s| s.unmap();
        self.sections.deinit(self.allocator);
        self.file.close(sysIo());
    }

    // Header byte layout (fixed):
    //   [0..8]   magic        u64 LE
    //   [8..12]  page_size    u32 LE
    //   [12]     endianness   u8
    //   [13]     active_slot  u8
    //   [14..16] reserved     (zero)
    //   [16..24] logical_size u64 LE
    //   [24..28] reserved     (zero, covered by checksum)
    //   [28..32] checksum     CRC32 of [0..28], u32 LE

    const off = struct {
        const magic: usize = 0;
        const page_size: usize = 8;
        const endianness: usize = 12;
        const active_slot: usize = 13;
        const logical_size: usize = 16;
        // [24..28] reserved -- zeroed before hashing, covered by checksum
        const checksum: usize = 28;
    };

    fn writeHeader(self: *FileStore) void {
        std.mem.writeInt(u64, self.map[off.magic..][0..8], self.header.magic, .little);
        std.mem.writeInt(u32, self.map[off.page_size..][0..4], self.header.page_size, .little);
        self.map[off.endianness] = @intFromEnum(self.header.endianness);
        self.map[off.active_slot] = self.header.active_slot;
        // [14..16] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[14..16], 0);
        std.mem.writeInt(u64, self.map[off.logical_size..][0..8], self.header.logical_size, .little);
        // [24..28] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[24..28], 0);
        // CRC32 over [0..28] written little-endian at [28..32]
        const crc = std.hash.Crc32.hash(self.map[0..28]);
        std.mem.writeInt(u32, self.map[off.checksum..][0..4], crc, .little);
    }

    pub fn readHeader(self: *FileStore) !void {
        if (self.map.len < default_page_size) return error.Corrupt;

        const magic = std.mem.readInt(u64, self.map[off.magic..][0..8], .little);
        if (magic != airdb_magic) return error.BadMagic;

        const page_size = std.mem.readInt(u32, self.map[off.page_size..][0..4], .little);

        const endianness_byte = self.map[off.endianness];
        // Zig 0.16: std.meta.intToEnum removed; use std.enums.fromInt instead.
        const endianness = std.enums.fromInt(Endianness, endianness_byte) orelse
            return error.UnsupportedEndianness;
        if (endianness != .little) return error.UnsupportedEndianness;

        const active_slot = self.map[off.active_slot];
        const logical_size = std.mem.readInt(u64, self.map[off.logical_size..][0..8], .little);

        // Validate header CRC32: hash [0..28], compare to stored u32 at [28..32].
        // A mismatch sets header_checksum_ok = false but does NOT hard-fail;
        // db.zig openWith decides how to recover.
        const stored_crc = std.mem.readInt(u32, self.map[off.checksum..][0..4], .little);
        const computed_crc = std.hash.Crc32.hash(self.map[0..28]);
        self.header_checksum_ok = (stored_crc == computed_crc);

        self.header = .{
            .magic = magic,
            .page_size = page_size,
            .endianness = endianness,
            .active_slot = active_slot,
            .logical_size = logical_size,
        };
    }

    /// Ensure the file is mapped by enough sections to cover `byte_len` bytes.
    /// Extends the file to a whole-section multiple, then maps each not-yet-mapped
    /// section. Existing sections are never remapped or moved, so live pointers stay
    /// valid. `self.map` is (re)pointed at section 0 afterwards.
    /// Returns `error.FileTooLarge` if the required size exceeds `max_reserved`.
    pub fn ensureMapped(self: *FileStore, byte_len: usize) !void {
        const max_sections = max_reserved >> platform.section_shift;
        const needed = @max((byte_len + platform.section_size - 1) >> platform.section_shift, 1);
        if (needed > max_sections) return error.FileTooLarge;

        const want_bytes: u64 = @as(u64, needed) << platform.section_shift;
        if (try self.file.length(sysIo()) < want_bytes) {
            // Measurement only: time the blocking setLength; no behavior change.
            const io = sysIo();
            const sl_start = Io.Clock.now(.awake, io).nanoseconds;
            try self.file.setLength(io, want_bytes);
            self.setlength_ns += @intCast(Io.Clock.now(.awake, io).nanoseconds - sl_start);
            self.setlength_calls += 1;
        }

        var i: usize = self.sections.items.len;
        while (i < needed) : (i += 1) {
            const s = try platform.mapSection(self.file, @as(u64, i) << platform.section_shift, platform.section_size);
            try self.sections.append(self.allocator, s);
        }
        self.map = self.sections.items[0].map;
    }

    /// Grow the file and its mapping to cover at least `min_len` bytes by appending
    /// sections. Existing section base pointers never change; live pointers remain valid.
    /// Returns `error.FileTooLarge` if `min_len` exceeds `max_reserved`.
    pub fn grow(self: *FileStore, min_len: usize) !void {
        if (min_len <= self.sections.items.len * platform.section_size) return;
        try self.ensureMapped(min_len);
    }

    /// Return the current on-disk file length in bytes (a whole-section multiple).
    pub fn fileLen(self: *FileStore) !u64 {
        return self.file.length(sysIo());
    }

    /// The live section table, for the arena's ref translation.
    pub fn sectionsView(self: *FileStore) []const platform.Section {
        return self.sections.items;
    }

    /// Re-encode header fields into the mmap'd page (does not flush).
    // Writes the in-memory header into the mmap'd buffer. Durability requires a subsequent Syncer.flush.
    pub fn persistHeader(self: *FileStore) void {
        self.writeHeader();
        self.header_checksum_ok = true;
    }

    /// Test-only: re-parse the header from the current mmap contents.
    /// Used to observe header_checksum_ok after in-place map tampering.
    pub fn reReadHeaderForTest(self: *FileStore) !void {
        try self.readHeader();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "real syncer flush succeeds (exercises the platform durability path)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "fsync.airdb" });
    defer testing.allocator.free(file_path);
    var fs = try FileStore.create(testing.allocator, file_path, RealSyncer.any());
    defer fs.deinit();
    try fs.syncer.flush(fs.file); // explicit second flush must also succeed
}

test "header checksum validates on a clean file and fails when the header is tampered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const file_path = try std.fs.path.join(testing.allocator, &.{ path_buf[0..path_len], "hcrc.airdb" });
    defer testing.allocator.free(file_path);
    {
        var fs = try FileStore.create(testing.allocator, file_path, RealSyncer.any());
        defer fs.deinit();
        try testing.expect(fs.header_checksum_ok);
    }
    {
        var fs = try FileStore.open(testing.allocator, file_path, RealSyncer.any());
        defer fs.deinit();
        try testing.expect(fs.header_checksum_ok);
        fs.map[13] ^= 0xFF; // scramble active_slot byte
        try fs.reReadHeaderForTest();
        try testing.expect(!fs.header_checksum_ok);
    }
}

test "create writes a header that reopen reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Zig 0.16: Dir.realpathAlloc no longer exists.
    // Use Dir.realPath(io, buf) with a stack buffer instead.
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];

    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "wsk.airdb" });
    defer testing.allocator.free(file_path);

    {
        var fs = try FileStore.create(testing.allocator, file_path, RealSyncer.any());
        defer fs.deinit();
        try testing.expectEqual(@as(u32, default_page_size), fs.header.page_size);
        try testing.expectEqual(Endianness.little, fs.header.endianness);
    }
    {
        var fs = try FileStore.open(testing.allocator, file_path, RealSyncer.any());
        defer fs.deinit();
        try testing.expectEqual(airdb_magic, fs.header.magic);
    }
}

test "grow adds sections, section 0 base stable, existing bytes preserved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    const fpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "grow.airdb" });
    defer testing.allocator.free(fpath);
    var fs = try FileStore.create(testing.allocator, fpath, RealSyncer.any());
    defer fs.deinit();
    const sections_before = fs.sections.items.len;
    const base_before = @intFromPtr(fs.map.ptr);
    fs.map[4096] = 0xAB;
    // Cross into a second section.
    try fs.grow(platform.section_size + 4096 * 10);
    try testing.expect(fs.sections.items.len > sections_before);
    // Section 0 (where `map` points) is never remapped or moved.
    try testing.expectEqual(base_before, @intFromPtr(fs.map.ptr));
    try testing.expectEqual(@as(u8, 0xAB), fs.map[4096]);
}

test "grow beyond the reservation fails cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    const fpath = try std.fs.path.join(testing.allocator, &.{ path_buf[0..dlen], "toobig.airdb" });
    defer testing.allocator.free(fpath);
    var fs = try FileStore.create(testing.allocator, fpath, RealSyncer.any());
    defer fs.deinit();
    // The check rejects before any setLength, so no oversized file is created.
    try testing.expectError(error.FileTooLarge, fs.grow(FileStore.max_reserved + default_page_size));
}
