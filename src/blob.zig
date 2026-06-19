// blob.zig -- blob heap with length-prefixed byte nodes.
//
// Node layout: [len u32 LE][bytes...]
// Empty blob (zero-length bytes) is represented as the null ref (0); no node
// is allocated for it.

const std = @import("std");
const Ref = @import("ref.zig").Ref;
const WriteTxn = @import("db.zig").WriteTxn;

/// Write `bytes` into the blob heap and return its Ref.
/// Returns the null ref (0) when `bytes` is empty -- no node is allocated.
pub fn put(txn: *WriteTxn, bytes: []const u8) !Ref {
    if (bytes.len == 0) return 0;
    const total = 4 + bytes.len;
    const a = try txn.alloc(total);
    std.mem.writeInt(u32, a.bytes[0..4], @intCast(bytes.len), .little);
    @memcpy(a.bytes[4 .. 4 + bytes.len], bytes);
    return a.ref;
}

/// Read the blob stored at `ref` and return a slice into the mapped storage.
/// Accepts any transaction type that exposes `deref(ref, len) ![]const u8`.
/// Returns an empty slice for the null ref (0).
pub fn get(txn: anytype, ref: Ref) ![]const u8 {
    if (ref == 0) return &.{};
    const hdr = try txn.deref(ref, 4);
    const len = std.mem.readInt(u32, hdr[0..4], .little);
    const node = try txn.deref(ref, 4 + @as(usize, len));
    return node[4 .. 4 + len];
}

/// Release the blob node at `ref` back to the storage engine.
/// Freeing the null ref (0) is a no-op.
pub fn free(txn: *WriteTxn, ref: Ref) !void {
    if (ref == 0) return;
    const hdr = try txn.deref(ref, 4);
    const len = std.mem.readInt(u32, hdr[0..4], .little);
    try txn.free(ref, 4 + @as(usize, len));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const Io = std.Io;

fn blobTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "blob put then get round-trips bytes; empty is the null ref" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const ref = try put(&w, "hello world");
    try testing.expect(ref != 0);
    try testing.expectEqualStrings("hello world", try get(&w, ref));
    const empty = try put(&w, "");
    try testing.expectEqual(@as(Ref, 0), empty);
    try testing.expectEqualStrings("", try get(&w, empty));
    w.deinit();
}

test "free releases a blob node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const ref = try put(&w, "data");
    try free(&w, ref); // must not error
    try free(&w, 0); // freeing the null ref is a no-op
    w.deinit();
}
