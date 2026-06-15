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
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

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

/// Injectable flush interface.
pub const Syncer = struct {
    ptr: *anyopaque,
    flushFn: *const fn (ptr: *anyopaque, file: Io.File) anyerror!void,

    pub fn flush(self: Syncer, file: Io.File) !void {
        return self.flushFn(self.ptr, file);
    }
};

/// Durability barrier: uses F_FULLFSYNC on Apple targets (forces drive write-cache flush),
/// plain fsync everywhere else.
///
/// In Zig 0.16, std.posix.fcntl does not exist. We call std.c.fcntl (the libc extern)
/// with std.c.F.FULLFSYNC (value 51, Darwin-only) and check the result via std.c.errno.
/// The comptime isDarwin() guard ensures the Darwin branch is never compiled on other targets.
fn fullSync(file: Io.File) !void {
    if (comptime builtin.target.os.tag.isDarwin()) {
        // F_FULLFSYNC (51) forces the drive's write cache to platter, unlike plain fsync.
        // Fall back to file.sync if the underlying filesystem does not support it (e.g. tmpfs).
        const rc = std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
        if (std.c.errno(rc) != .SUCCESS) {
            try file.sync(std.Io.Threaded.global_single_threaded.io());
        }
    } else {
        try file.sync(std.Io.Threaded.global_single_threaded.io());
    }
}

/// Production syncer that calls the platform durability barrier.
pub const RealSyncer = struct {
    var instance: RealSyncer = .{};

    fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        _ = ptr;
        try fullSync(file);
    }

    pub fn any() Syncer {
        return .{
            .ptr = &instance,
            .flushFn = flushImpl,
        };
    }
};

// ---------------------------------------------------------------------------
// FileStore
// ---------------------------------------------------------------------------

pub const FileStore = struct {
    allocator: std.mem.Allocator, // reserved for future allocations (buffer pool, catalog pages)
    file: Io.File,
    map: []align(std.heap.page_size_min) u8,
    header: Header,
    syncer: Syncer,
    /// True when the header CRC32 matches the stored checksum at [28..32].
    /// Set by readHeader (open path) or to true after writeHeader (create/persistHeader path).
    /// Recovery in db.zig openWith reads this to decide whether to trust active_slot.
    header_checksum_ok: bool,

    const initial_capacity: usize = default_page_size * 256;

    /// Returns the blocking Io instance used for all file operations.
    /// This is always initialized (compile-time constant vtable), so it
    /// works in both test and production contexts without passing Io around.
    // Phase 1 single-process/single-thread only. Phase 4 (multi-process/threaded) must replace this global Io.
    inline fn sysIo() Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    /// Create a new database file at the given absolute path, truncating any
    /// existing file. Maps initial_capacity bytes and writes the header.
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

        try file.setLength(io, initial_capacity);

        const map = try std.posix.mmap(
            null,
            initial_capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(map);

        var fs = FileStore{
            .allocator = allocator,
            .file = file,
            .map = map,
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

        const map = try std.posix.mmap(
            null,
            @intCast(file_len),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(map);

        var fs = FileStore{
            .allocator = allocator,
            .file = file,
            .map = map,
            .header = undefined,
            .syncer = syncer,
            .header_checksum_ok = false, // set by readHeader below
        };
        try fs.readHeader();
        return fs;
    }

    /// Unmap and close the file.
    pub fn deinit(self: *FileStore) void {
        std.posix.munmap(self.map);
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

/// Test syncer that fails the Nth flush call (1-based) to simulate a crash
/// at a precise commit step. Non-failing calls perform the real sync.
pub const FailingSyncer = struct {
    count: usize = 0,
    fail_on: usize,

    pub fn flushImpl(ptr: *anyopaque, file: Io.File) anyerror!void {
        const self: *FailingSyncer = @ptrCast(@alignCast(ptr));
        self.count += 1;
        if (self.count == self.fail_on) return error.SimulatedCrash;
        try fullSync(file);
    }

    pub fn any(self: *FailingSyncer) Syncer {
        return .{ .ptr = self, .flushFn = &FailingSyncer.flushImpl };
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
