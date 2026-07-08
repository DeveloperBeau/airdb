//! Header, mmap, and injectable Syncing for airdb.
//!
//! Zig 0.16 API adaptations used throughout:
//!   - std.fs.File           -> std.Io.File  (std.fs.File removed in 0.16)
//!   - std.fs.createFileAbsolute/openFileAbsolute
//!                           -> std.Io.Dir.createFileAbsolute/openFileAbsolute(io, ...)
//!   - File.setEndPos(n)     -> File.setLength(io, n)
//!   - File.getEndPos()      -> File.length(io) -> u64
//!   - File.sync()           -> File.sync(io)
//!   - File.close()          -> File.close(io)
//!   - mmap alignment        -> []align(std.heap.page_size_min) u8
//!   - mmap flags            -> .{ .TYPE = .SHARED } (not .SHARED = true)
//!   - page-size constant    -> std.heap.page_size_min (compile-time lower bound)
//!   - Dir.realpathAlloc     -> Dir.realPath(io, buffer) with stack buffer
//!   - Io instance           -> std.Io.Threaded.global_single_threaded.io()
//!       (always initialized; works in both test and production contexts)

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("../platform.zig");
const Syncing = @import("syncer.zig").Syncing;
const FileSyncer = @import("syncer.zig").FileSyncer;

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

/// File magic doubling as the format version ("airdb" + _NNNN).
/// _0002: the free list is persisted as a chain of bounded chunks
/// ([count u32][nextRef u64][extents...]), not a single unbounded node.
pub const airdbMagic: u64 = 0x6169726462_0002;
/// Size of the header page; the header and both commit slots live in it.
pub const defaultPageSize: u32 = 4096;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// On-disk byte-order marker recorded in the header (only .little is accepted).
pub const Endianness = enum(u8) { little = 1, big = 2 };

/// The decoded fixed file header: magic, page size, endianness, the active
/// commit slot, and the logical (in-use) file size.
pub const Header = struct {
    magic: u64,
    pageSize: u32,
    endianness: Endianness,
    activeSlot: u8,
    logicalSize: u64,
};

// ---------------------------------------------------------------------------
// FileStore
// ---------------------------------------------------------------------------

/// The mapped database file: owns the file handle, the append-only section
/// mappings, the parsed header, and the injected durability barrier.
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
    syncer: Syncing,
    /// True when the header CRC32 matches the stored checksum at [28..32].
    /// Set by readHeader (open path) or to true after writeHeader (create/persistHeader path).
    /// Recovery in database.zig openWith reads this to decide whether to trust activeSlot.
    headerChecksumOk: bool,
    /// Measurement-only counters accumulated since open. Total nanoseconds spent in
    /// blocking file.setLength (file growth) and the number of such calls. Read via
    /// Database.metrics(); never affect behavior.
    setlengthNs: u64 = 0,
    setlengthCalls: u64 = 0,

    /// Per-open maximum file size; caps the number of sections (maxSections =
    /// maxReserved / sectionSize). See `platform.maxReserved` for the host-size split.
    pub const maxReserved: usize = platform.maxReserved;

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
        syncer: Syncing,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = true,
        });
        errdefer file.close(io);

        var store = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = .{
                .magic = airdbMagic,
                .pageSize = defaultPageSize,
                .endianness = .little,
                .activeSlot = 0,
                .logicalSize = defaultPageSize,
            },
            .syncer = syncer,
            .headerChecksumOk = false, // set to true after writeHeader below
        };
        errdefer {
            for (store.sections.items) |*section| section.unmap();
            store.sections.deinit(allocator);
        }

        // Extend the file to one section and map it; header + commit slots live here.
        try store.ensureMapped(platform.sectionSize);

        store.writeHeader();
        store.headerChecksumOk = true;
        try store.syncer.flush(store.file);
        return store;
    }

    /// Open an existing database file at the given absolute path.
    /// Validates the header magic and endianness.
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        syncer: Syncing,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const openedLength = try file.length(io);
        if (openedLength < defaultPageSize) return error.Corrupt;

        var store = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = undefined,
            .syncer = syncer,
            .headerChecksumOk = false, // set by readHeader below
        };
        errdefer {
            for (store.sections.items) |*section| section.unmap();
            store.sections.deinit(allocator);
        }

        // Map all sections covering the existing file. ensureMapped rounds the file up to
        // a whole-section multiple first (an old file whose length is not a section
        // multiple is extended via setLength before mapping), so every section is fully
        // backed before any deref.
        try store.ensureMapped(@intCast(openedLength));
        try store.readHeader();
        return store;
    }

    /// Unmap every section and close the file.
    pub fn deinit(self: *FileStore) void {
        for (self.sections.items) |*section| section.unmap();
        self.sections.deinit(self.allocator);
        self.file.close(sysIo());
    }

    // Header byte layout (fixed):
    //   [0..8]   magic        u64 LE
    //   [8..12]  pageSize    u32 LE
    //   [12]     endianness   u8
    //   [13]     activeSlot  u8
    //   [14..16] reserved     (zero)
    //   [16..24] logicalSize u64 LE
    //   [24..28] reserved     (zero, covered by checksum)
    //   [28..32] checksum     CRC32 of [0..28], u32 LE

    const offset = struct {
        const magic: usize = 0;
        const pageSize: usize = 8;
        const endianness: usize = 12;
        const activeSlot: usize = 13;
        const logicalSize: usize = 16;
        // [24..28] reserved -- zeroed before hashing, covered by checksum
        const checksum: usize = 28;
    };

    fn writeHeader(self: *FileStore) void {
        std.mem.writeInt(u64, self.map[offset.magic..][0..8], self.header.magic, .little);
        std.mem.writeInt(u32, self.map[offset.pageSize..][0..4], self.header.pageSize, .little);
        self.map[offset.endianness] = @intFromEnum(self.header.endianness);
        self.map[offset.activeSlot] = self.header.activeSlot;
        // [14..16] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[14..16], 0);
        std.mem.writeInt(u64, self.map[offset.logicalSize..][0..8], self.header.logicalSize, .little);
        // [24..28] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[24..28], 0);
        // CRC32 over [0..28] written little-endian at [28..32]
        const crc = std.hash.Crc32.hash(self.map[0..28]);
        std.mem.writeInt(u32, self.map[offset.checksum..][0..4], crc, .little);
    }

    /// Parse and validate the header from the mapping: a wrong magic or
    /// endianness is a hard error, while the CRC32 verdict is only recorded
    /// in headerChecksumOk (never a failure) so database recovery can decide
    /// whether to trust activeSlot.
    pub fn readHeader(self: *FileStore) !void {
        if (self.map.len < defaultPageSize) return error.Corrupt;

        const magic = std.mem.readInt(u64, self.map[offset.magic..][0..8], .little);
        if (magic != airdbMagic) return error.BadMagic;

        const pageSize = std.mem.readInt(u32, self.map[offset.pageSize..][0..4], .little);

        const endiannessByte = self.map[offset.endianness];
        // Zig 0.16: std.meta.intToEnum removed; use std.enums.fromInt instead.
        const endianness = std.enums.fromInt(Endianness, endiannessByte) orelse
            return error.UnsupportedEndianness;
        if (endianness != .little) return error.UnsupportedEndianness;

        const activeSlot = self.map[offset.activeSlot];
        const logicalSize = std.mem.readInt(u64, self.map[offset.logicalSize..][0..8], .little);

        // Validate header CRC32: hash [0..28], compare to stored u32 at [28..32].
        // A mismatch sets headerChecksumOk = false but does NOT hard-fail;
        // database.zig openWith decides how to recover.
        const storedCrc = std.mem.readInt(u32, self.map[offset.checksum..][0..4], .little);
        const computedCrc = std.hash.Crc32.hash(self.map[0..28]);
        self.headerChecksumOk = (storedCrc == computedCrc);

        self.header = .{
            .magic = magic,
            .pageSize = pageSize,
            .endianness = endianness,
            .activeSlot = activeSlot,
            .logicalSize = logicalSize,
        };
    }

    /// Ensure the file is mapped by enough sections to cover `byteLen` bytes.
    /// Extends the file to a whole-section multiple, then maps each not-yet-mapped
    /// section. Existing sections are never remapped or moved, so live pointers stay
    /// valid. `self.map` is (re)pointed at section 0 afterwards.
    /// Returns `error.FileTooLarge` if the required size exceeds `maxReserved`.
    pub fn ensureMapped(self: *FileStore, byteLen: usize) !void {
        const maxSections = maxReserved >> platform.sectionShift;
        const needed = @max((byteLen + platform.sectionSize - 1) >> platform.sectionShift, 1);
        if (needed > maxSections) return error.FileTooLarge;

        const wantBytes: u64 = @as(u64, needed) << platform.sectionShift;
        if (try self.file.length(sysIo()) < wantBytes) {
            // Measurement only: time the blocking setLength; no behavior change.
            const io = sysIo();
            const slStart = Io.Clock.now(.awake, io).nanoseconds;
            try self.file.setLength(io, wantBytes);
            self.setlengthNs += @intCast(Io.Clock.now(.awake, io).nanoseconds - slStart);
            self.setlengthCalls += 1;
        }

        var sectionIndex: usize = self.sections.items.len;
        while (sectionIndex < needed) : (sectionIndex += 1) {
            const section = try platform.mapSection(self.file, @as(u64, sectionIndex) << platform.sectionShift, platform.sectionSize);
            try self.sections.append(self.allocator, section);
        }
        self.map = self.sections.items[0].map;
    }

    /// Grow the file and its mapping to cover at least `minLen` bytes by appending
    /// sections. Existing section base pointers never change; live pointers remain valid.
    /// Returns `error.FileTooLarge` if `minLen` exceeds `maxReserved`.
    pub fn grow(self: *FileStore, minLen: usize) !void {
        if (minLen <= self.sections.items.len * platform.sectionSize) return;
        try self.ensureMapped(minLen);
    }

    /// Return the current on-disk file length in bytes (a whole-section multiple).
    pub fn fileLength(self: *FileStore) !u64 {
        return self.file.length(sysIo());
    }

    /// The live section table, for the arena's ref translation.
    pub fn sectionsView(self: *FileStore) []const platform.Section {
        return self.sections.items;
    }

    /// Re-encode the in-memory header into the mmap'd page and mark the
    /// checksum valid. Does not flush: durability requires a subsequent
    /// Syncing.flush.
    pub fn persistHeader(self: *FileStore) void {
        self.writeHeader();
        self.headerChecksumOk = true;
    }

    /// Test-only: re-parse the header from the current mmap contents.
    /// Used to observe headerChecksumOk after in-place map tampering.
    pub fn reReadHeaderForTest(self: *FileStore) !void {
        try self.readHeader();
    }
};

// ---------------------------------------------------------------------------
// Durable-file helpers
// ---------------------------------------------------------------------------

/// Delete an absolute path, treating a missing file as success. Used to remove
/// coordination files during the publish step of in-place compaction. Any other
/// failure is swallowed best-effort: the data file is already published by the
/// atomic rename, and a leftover/stale coordination file is recreated fresh by Database.open
/// (openOrCreate), so it cannot corrupt the published data. Does I/O.
pub fn deleteAbsoluteIgnoreMissing(io: Io, absPath: []const u8) void {
    Io.Dir.deleteFileAbsolute(io, absPath) catch {};
}

/// Make the directory ENTRY for `path` durable by fsync'ing its parent directory.
/// Uses libc fsync directly on the directory fd, which is the portable POSIX way:
/// the std.Io File sync wrapper panics with BADF on a directory handle on Linux.
/// Best-effort -- errors are swallowed. No-op on Windows. Does I/O.
pub fn syncParentDirectory(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const directoryPath = std.fs.path.dirname(path) orelse return;
    var parentDirectory = std.Io.Dir.openDirAbsolute(io, directoryPath, .{}) catch return;
    defer parentDirectory.close(io);
    _ = std.c.fsync(parentDirectory.handle);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "real syncer flush succeeds (exercises the platform durability path)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const directoryPath = pathBuffer[0..pathLen];
    const filePath = try std.fs.path.join(testing.allocator, &.{ directoryPath, "fsync.airdb" });
    defer testing.allocator.free(filePath);
    var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
    defer store.deinit();
    try store.syncer.flush(store.file); // explicit second flush must also succeed
}

test "header checksum validates on a clean file and fails when the header is tampered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const filePath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "hcrc.airdb" });
    defer testing.allocator.free(filePath);
    {
        var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expect(store.headerChecksumOk);
    }
    {
        var store = try FileStore.open(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expect(store.headerChecksumOk);
        store.map[13] ^= 0xFF; // scramble activeSlot byte
        try store.reReadHeaderForTest();
        try testing.expect(!store.headerChecksumOk);
    }
}

test "create writes a header that reopen reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Zig 0.16: Dir.realpathAlloc no longer exists.
    // Use Dir.realPath(io, buffer) with a stack buffer instead.
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const directoryPath = pathBuffer[0..pathLen];

    const filePath = try std.fs.path.join(testing.allocator, &.{ directoryPath, "wsk.airdb" });
    defer testing.allocator.free(filePath);

    {
        var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expectEqual(@as(u32, defaultPageSize), store.header.pageSize);
        try testing.expectEqual(Endianness.little, store.header.endianness);
    }
    {
        var store = try FileStore.open(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expectEqual(airdbMagic, store.header.magic);
    }
}

test "grow adds sections, section 0 base stable, existing bytes preserved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const fpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "grow.airdb" });
    defer testing.allocator.free(fpath);
    var store = try FileStore.create(testing.allocator, fpath, FileSyncer.any());
    defer store.deinit();
    const sectionsBefore = store.sections.items.len;
    const baseBefore = @intFromPtr(store.map.ptr);
    store.map[4096] = 0xAB;
    // Cross into a second section.
    try store.grow(platform.sectionSize + 4096 * 10);
    try testing.expect(store.sections.items.len > sectionsBefore);
    // Section 0 (where `map` points) is never remapped or moved.
    try testing.expectEqual(baseBefore, @intFromPtr(store.map.ptr));
    try testing.expectEqual(@as(u8, 0xAB), store.map[4096]);
}

test "grow beyond the reservation fails cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const fpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "toobig.airdb" });
    defer testing.allocator.free(fpath);
    var store = try FileStore.create(testing.allocator, fpath, FileSyncer.any());
    defer store.deinit();
    // The check rejects before any setLength, so no oversized file is created.
    try testing.expectError(error.FileTooLarge, store.grow(FileStore.maxReserved + defaultPageSize));
}
