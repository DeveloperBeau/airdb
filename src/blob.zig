// blob.zig -- blob heap with a tagged small/large representation.
//
// A single arena allocation must fit within one mmap section
// (`platform.section_size` = 16 MiB); larger requests fail with
// `error.AllocTooLarge`. Blobs are therefore stored in one of two shapes,
// distinguished by a leading tag byte:
//
//   Inline (len <= inline_max):
//     [tag=0 u8][len u32 LE][bytes...]
//   Chunked (len > inline_max): an index node
//     [tag=1 u8][total_len u64 LE][chunk_count u32 LE][chunk_ref u64 LE * count]
//   plus `chunk_count` separate chunk nodes, each holding up to `chunk_size`
//   RAW bytes (no per-chunk header). All but the last chunk are exactly
//   `chunk_size` bytes; the last is `total_len - (chunk_count-1)*chunk_size`.
//
// Empty blob (zero-length bytes) is represented as the null ref (0); no node
// is allocated for it.

const std = @import("std");
const Ref = @import("ref.zig").Ref;
const WriteTxn = @import("db.zig").WriteTxn;
const section_size = @import("platform.zig").section_size;

/// Largest blob stored as a single inline node. The +5 node header (tag + len)
/// plus the bytes must stay under `section_size`; the 64-byte margin covers it.
const inline_max: usize = section_size - 64;
/// Maximum RAW bytes per chunk node. Each chunk node is a bare byte allocation,
/// so it must itself fit within one section.
const chunk_size: usize = section_size - 64;

const tag_inline: u8 = 0;
const tag_chunked: u8 = 1;

// Inline node field offsets.
const inline_len_off: usize = 1;
const inline_bytes_off: usize = 5;

// Chunked index node field offsets.
const idx_total_off: usize = 1;
const idx_count_off: usize = 9;
const idx_refs_off: usize = 13;

fn indexNodeSize(chunk_count: usize) usize {
    return idx_refs_off + 8 * chunk_count;
}

/// Write `bytes` into the blob heap and return its Ref.
/// Returns the null ref (0) when `bytes` is empty -- no node is allocated.
/// Small blobs become a single inline node; blobs over `inline_max` are split
/// into chunk nodes referenced by an index node.
pub fn put(txn: *WriteTxn, bytes: []const u8) !Ref {
    if (bytes.len == 0) return 0;

    if (bytes.len <= inline_max) {
        const total = inline_bytes_off + bytes.len;
        const a = try txn.alloc(total);
        a.bytes[0] = tag_inline;
        std.mem.writeInt(u32, a.bytes[inline_len_off..][0..4], @intCast(bytes.len), .little);
        @memcpy(a.bytes[inline_bytes_off .. inline_bytes_off + bytes.len], bytes);
        return a.ref;
    }

    const chunk_count = (bytes.len + chunk_size - 1) / chunk_size;

    // Allocate the index node first and write its header. Its mutable slice stays
    // valid across the chunk allocations below: sections never move on growth, and
    // chunk allocations land in distinct regions, so they never touch this node.
    const idx = try txn.alloc(indexNodeSize(chunk_count));
    idx.bytes[0] = tag_chunked;
    std.mem.writeInt(u64, idx.bytes[idx_total_off..][0..8], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, idx.bytes[idx_count_off..][0..4], @intCast(chunk_count), .little);

    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, bytes.len);
        const c = try txn.alloc(end - start);
        // Copy this chunk's source bytes in immediately, before the next alloc.
        @memcpy(c.bytes, bytes[start..end]);
        std.mem.writeInt(u64, idx.bytes[idx_refs_off + 8 * i ..][0..8], c.ref, .little);
    }

    return idx.ref;
}

/// Number of bytes stored at `ref`. Null ref -> 0.
/// Accepts any transaction type exposing `deref(ref, len) ![]const u8`.
pub fn size(txn: anytype, ref: Ref) !usize {
    if (ref == 0) return 0;
    const tag = (try txn.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const node = try txn.deref(ref, inline_bytes_off);
        return std.mem.readInt(u32, node[inline_len_off..][0..4], .little);
    }
    const node = try txn.deref(ref, idx_refs_off);
    return @intCast(std.mem.readInt(u64, node[idx_total_off..][0..8], .little));
}

/// Zero-copy slice into an inline blob node. Null ref -> empty slice.
/// Returns `error.BlobChunked` for a chunked blob (it has no single contiguous
/// slice); callers use `readInto`/`getAlloc` for those.
/// Accepts any transaction type exposing `deref(ref, len) ![]const u8`.
pub fn get(txn: anytype, ref: Ref) ![]const u8 {
    if (ref == 0) return &.{};
    const tag = (try txn.deref(ref, 1))[0];
    if (tag != tag_inline) return error.BlobChunked;
    const hdr = try txn.deref(ref, inline_bytes_off);
    const len = std.mem.readInt(u32, hdr[inline_len_off..][0..4], .little);
    const node = try txn.deref(ref, inline_bytes_off + @as(usize, len));
    return node[inline_bytes_off .. inline_bytes_off + len];
}

/// Copy the blob at `ref` into `out`, which must be exactly `size(ref)` bytes.
/// No allocation; the caller owns `out`. Works for both inline and chunked blobs.
/// Accepts any transaction type exposing `deref(ref, len) ![]const u8`.
pub fn readInto(txn: anytype, ref: Ref, out: []u8) !void {
    std.debug.assert(out.len == try size(txn, ref));
    if (ref == 0) return;

    const tag = (try txn.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const hdr = try txn.deref(ref, inline_bytes_off);
        const len = std.mem.readInt(u32, hdr[inline_len_off..][0..4], .little);
        const node = try txn.deref(ref, inline_bytes_off + @as(usize, len));
        @memcpy(out, node[inline_bytes_off .. inline_bytes_off + len]);
        return;
    }

    const total_len = out.len;
    const hdr = try txn.deref(ref, idx_refs_off);
    const chunk_count = std.mem.readInt(u32, hdr[idx_count_off..][0..4], .little);
    const node_size = indexNodeSize(chunk_count);
    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const start = i * chunk_size;
        const clen = @min(chunk_size, total_len - start);
        // Re-deref the index node each iteration so the read is independent of any
        // prior chunk deref slices.
        const node = try txn.deref(ref, node_size);
        const chunk_ref = std.mem.readInt(u64, node[idx_refs_off + 8 * i ..][0..8], .little);
        const chunk = try txn.deref(chunk_ref, clen);
        @memcpy(out[start .. start + clen], chunk);
    }
}

/// Allocate a buffer, copy the blob at `ref` into it, and return it. Caller frees.
pub fn getAlloc(txn: anytype, ref: Ref, allocator: std.mem.Allocator) ![]u8 {
    const n = try size(txn, ref);
    const buf = try allocator.alloc(u8, n);
    errdefer allocator.free(buf);
    try readInto(txn, ref, buf);
    return buf;
}

/// Copy the blob at `src_ref` (inline OR chunked) from a source db into `dst`,
/// returning its new Ref in the destination. The null ref (0) copies to 0.
/// Materializes the blob in RAM during the copy (acceptable for a maintenance
/// op); a future optimization could stream chunks without buffering the whole
/// blob. Accepts any source transaction exposing `deref(ref, len) ![]const u8`.
pub fn copyInto(src: anytype, dst: *WriteTxn, src_ref: Ref) !Ref {
    if (src_ref == 0) return 0;
    const buf = try getAlloc(src, src_ref, dst.db.store.allocator);
    defer dst.db.store.allocator.free(buf);
    return try put(dst, buf);
}

/// Release the blob at `ref` back to the storage engine.
/// Freeing the null ref (0) is a no-op. For a chunked blob, frees every chunk
/// node and then the index node.
pub fn free(txn: *WriteTxn, ref: Ref) !void {
    if (ref == 0) return;
    const tag = (try txn.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const hdr = try txn.deref(ref, inline_bytes_off);
        const len = std.mem.readInt(u32, hdr[inline_len_off..][0..4], .little);
        try txn.free(ref, inline_bytes_off + @as(usize, len));
        return;
    }

    const hdr = try txn.deref(ref, idx_refs_off);
    const total_len: usize = @intCast(std.mem.readInt(u64, hdr[idx_total_off..][0..8], .little));
    const chunk_count = std.mem.readInt(u32, hdr[idx_count_off..][0..4], .little);
    const node_size = indexNodeSize(chunk_count);
    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const start = i * chunk_size;
        const clen = @min(chunk_size, total_len - start);
        // Read the chunk ref from the still-intact index node, then free the chunk.
        // free() only updates the free list; it does not touch the index node's bytes.
        const node = try txn.deref(ref, node_size);
        const chunk_ref = std.mem.readInt(u64, node[idx_refs_off + 8 * i ..][0..8], .little);
        try txn.free(chunk_ref, clen);
    }
    try txn.free(ref, node_size);
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
    try testing.expectEqual(@as(usize, 11), try size(&w, ref));
    const empty = try put(&w, "");
    try testing.expectEqual(@as(Ref, 0), empty);
    try testing.expectEqualStrings("", try get(&w, empty));
    try testing.expectEqual(@as(usize, 0), try size(&w, empty));
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

test "chunked blob over the inline cap round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    // Just past the inline cap: forces the chunked representation (2 chunks).
    {
        const n = inline_max + 1;
        const src = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(src);
        for (src, 0..) |*b, i| b.* = @intCast(i % 251);

        const ref = try put(&w, src);
        try testing.expect(ref != 0);
        try testing.expectEqual(n, try size(&w, ref));
        try testing.expectError(error.BlobChunked, get(&w, ref));

        const out = try getAlloc(&w, ref, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, src, out);

        try free(&w, ref);
    }

    // A large blob spanning many chunks (~40 MiB).
    {
        const n: usize = 40 * 1024 * 1024;
        const src = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(src);
        for (src, 0..) |*b, i| b.* = @intCast(i % 251);

        const ref = try put(&w, src);
        try testing.expect(ref != 0);
        try testing.expectEqual(n, try size(&w, ref));
        try testing.expectError(error.BlobChunked, get(&w, ref));

        const out = try testing.allocator.alloc(u8, try size(&w, ref));
        defer testing.allocator.free(out);
        try readInto(&w, ref, out);

        // Full compare plus explicit checks at chunk boundaries.
        try testing.expectEqualSlices(u8, src, out);
        try testing.expectEqual(@as(u8, 0), out[0]);
        try testing.expectEqual(@as(u8, @intCast((chunk_size - 1) % 251)), out[chunk_size - 1]);
        try testing.expectEqual(@as(u8, @intCast(chunk_size % 251)), out[chunk_size]);
        try testing.expectEqual(@as(u8, @intCast((n - 1) % 251)), out[n - 1]);

        try free(&w, ref);
    }

    w.deinit();
}

test "free of a chunked blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    const n = inline_max + chunk_size + 7; // 3 chunks
    const src = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(src);
    for (src, 0..) |*b, i| b.* = @intCast(i % 251);

    const ref = try put(&w, src);
    try free(&w, ref); // must not error
    w.deinit();
}
