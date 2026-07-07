// blob.zig -- blob heap with a tagged small/large representation.
//
// A single arena allocation must fit within one mmap section
// (`platform.section_size` = 16 MiB); larger requests fail with
// `error.AllocTooLarge`. Blobs are therefore stored in one of two shapes,
// distinguished by a leading tag byte:
//
//   Inline (length <= inline_max):
//     [tag=0 u8][length u32 LE][bytes...]
//   Chunked (length > inline_max): an index node
//     [tag=1 u8][total_len u64 LE][chunk_count u32 LE][chunk_ref u64 LE * count]
//   plus `chunk_count` separate chunk nodes, each holding up to `chunk_size`
//   RAW bytes (no per-chunk header). All but the last chunk are exactly
//   `chunk_size` bytes; the last is `total_len - (chunk_count-1)*chunk_size`.
//
// Empty blob (zero-length bytes) is represented as the null ref (0); no node
// is allocated for it.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const WriteTransaction = @import("../database.zig").WriteTransaction;
const section_size = @import("../platform.zig").section_size;

/// Largest blob stored as a single inline node. The +5 node header (tag + length)
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
const totalLengthOffset: usize = 1;
const chunkCountOffset: usize = 9;
const chunkRefsOffset: usize = 13;

fn indexNodeSize(chunk_count: usize) usize {
    return chunkRefsOffset + 8 * chunk_count;
}

const ChunkedHeader = struct { total_len: usize, chunk_count: u32, node_size: usize };

/// Read and VALIDATE a chunked-blob index header. These fields come straight
/// from the mapped file: an unvalidated chunk_count feeds lengths to transaction.free
/// (poisoning the free list with garbage extents -- corruption that spreads
/// after commit), underflows `total_len - start`, and on 32-bit hosts can
/// overflow indexNodeSize into a too-short deref. Sizes are computed in u64.
fn chunkedHeader(transaction: anytype, ref: Reference) !ChunkedHeader {
    const header = try transaction.deref(ref, chunkRefsOffset);
    if (header[0] != tag_chunked) return error.Corrupt;
    const total_len = std.mem.readInt(u64, header[totalLengthOffset..][0..8], .little);
    const chunk_count = std.mem.readInt(u32, header[chunkCountOffset..][0..4], .little);
    const expected: u64 = (total_len + chunk_size - 1) / chunk_size;
    if (chunk_count == 0 or chunk_count != expected) return error.Corrupt;
    const node_size: u64 = @as(u64, chunkRefsOffset) + 8 * @as(u64, chunk_count);
    if (node_size > section_size) return error.Corrupt;
    return .{ .total_len = @intCast(total_len), .chunk_count = chunk_count, .node_size = @intCast(node_size) };
}

/// Write `bytes` into the blob heap and return its Reference.
/// Returns the null ref (0) when `bytes` is empty -- no node is allocated.
/// Small blobs become a single inline node; blobs over `inline_max` are split
/// into chunk nodes referenced by an index node.
pub fn put(transaction: *WriteTransaction, bytes: []const u8) !Reference {
    if (bytes.len == 0) return 0;

    if (bytes.len <= inline_max) {
        const total = inline_bytes_off + bytes.len;
        const allocation = try transaction.alloc(total);
        allocation.bytes[0] = tag_inline;
        std.mem.writeInt(u32, allocation.bytes[inline_len_off..][0..4], @intCast(bytes.len), .little);
        @memcpy(allocation.bytes[inline_bytes_off .. inline_bytes_off + bytes.len], bytes);
        return allocation.ref;
    }

    const chunk_count = (bytes.len + chunk_size - 1) / chunk_size;

    // Allocate the index node first and write its header. Its mutable slice stays
    // valid across the chunk allocations below: sections never move on growth, and
    // chunk allocations land in distinct regions, so they never touch this node.
    const indexNode = try transaction.alloc(indexNodeSize(chunk_count));
    indexNode.bytes[0] = tag_chunked;
    std.mem.writeInt(u64, indexNode.bytes[totalLengthOffset..][0..8], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, indexNode.bytes[chunkCountOffset..][0..4], @intCast(chunk_count), .little);

    var chunkIndex: usize = 0;
    while (chunkIndex < chunk_count) : (chunkIndex += 1) {
        const start = chunkIndex * chunk_size;
        const end = @min(start + chunk_size, bytes.len);
        const chunk = try transaction.alloc(end - start);
        // Copy this chunk's source bytes in immediately, before the next alloc.
        @memcpy(chunk.bytes, bytes[start..end]);
        std.mem.writeInt(u64, indexNode.bytes[chunkRefsOffset + 8 * chunkIndex ..][0..8], chunk.ref, .little);
    }

    return indexNode.ref;
}

/// Number of bytes stored at `ref`. Null ref -> 0.
/// Accepts any transaction type exposing `deref(ref, length) ![]const u8`.
pub fn size(transaction: anytype, ref: Reference) !usize {
    if (ref == 0) return 0;
    const tag = (try transaction.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const node = try transaction.deref(ref, inline_bytes_off);
        return std.mem.readInt(u32, node[inline_len_off..][0..4], .little);
    }
    return (try chunkedHeader(transaction, ref)).total_len;
}

/// Zero-copy slice into an inline blob node. Null ref -> empty slice.
/// Returns `error.BlobChunked` for a chunked blob (it has no single contiguous
/// slice); callers use `readInto`/`getAlloc` for those.
/// Accepts any transaction type exposing `deref(ref, length) ![]const u8`.
pub fn get(transaction: anytype, ref: Reference) ![]const u8 {
    if (ref == 0) return &.{};
    const tag = (try transaction.deref(ref, 1))[0];
    if (tag == tag_chunked) return error.BlobChunked;
    if (tag != tag_inline) return error.Corrupt;
    const header = try transaction.deref(ref, inline_bytes_off);
    const length = std.mem.readInt(u32, header[inline_len_off..][0..4], .little);
    const node = try transaction.deref(ref, inline_bytes_off + @as(usize, length));
    return node[inline_bytes_off .. inline_bytes_off + length];
}

/// Copy the blob at `ref` into `out`, which must be exactly `size(ref)` bytes.
/// No allocation; the caller owns `out`. Works for both inline and chunked blobs.
/// Accepts any transaction type exposing `deref(ref, length) ![]const u8`.
pub fn readInto(transaction: anytype, ref: Reference, out: []u8) !void {
    std.debug.assert(out.len == try size(transaction, ref));
    if (ref == 0) return;

    const tag = (try transaction.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const header = try transaction.deref(ref, inline_bytes_off);
        const length = std.mem.readInt(u32, header[inline_len_off..][0..4], .little);
        const node = try transaction.deref(ref, inline_bytes_off + @as(usize, length));
        @memcpy(out, node[inline_bytes_off .. inline_bytes_off + length]);
        return;
    }

    const header = try chunkedHeader(transaction, ref);
    if (header.total_len != out.len) return error.Corrupt;
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunk_count) : (chunkIndex += 1) {
        const start = chunkIndex * chunk_size;
        const chunkLength = @min(chunk_size, header.total_len - start);
        // Re-deref the index node each iteration so the read is independent of any
        // prior chunk deref slices.
        const node = try transaction.deref(ref, header.node_size);
        const chunk_ref = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        const chunk = try transaction.deref(chunk_ref, chunkLength);
        @memcpy(out[start .. start + chunkLength], chunk);
    }
}

/// Allocate a buffer, copy the blob at `ref` into it, and return it. Caller frees.
pub fn getAlloc(transaction: anytype, ref: Reference, allocator: std.mem.Allocator) ![]u8 {
    const byteCount = try size(transaction, ref);
    const buffer = try allocator.alloc(u8, byteCount);
    errdefer allocator.free(buffer);
    try readInto(transaction, ref, buffer);
    return buffer;
}

/// Copy the blob at `src_ref` (inline OR chunked) from a source database into `dst`,
/// returning its new Reference in the destination. The null ref (0) copies to 0.
/// Materializes the blob in RAM during the copy (acceptable for a maintenance
/// op); a future optimization could stream chunks without buffering the whole
/// blob. Accepts any source transaction exposing `deref(ref, length) ![]const u8`.
pub fn copyInto(source: anytype, dst: *WriteTransaction, src_ref: Reference) !Reference {
    if (src_ref == 0) return 0;
    const buffer = try getAlloc(source, src_ref, dst.database.store.allocator);
    defer dst.database.store.allocator.free(buffer);
    return try put(dst, buffer);
}

/// Release the blob at `ref` back to the storage engine.
/// Freeing the null ref (0) is a no-op. For a chunked blob, frees every chunk
/// node and then the index node.
pub fn free(transaction: *WriteTransaction, ref: Reference) !void {
    if (ref == 0) return;
    const tag = (try transaction.deref(ref, 1))[0];
    if (tag == tag_inline) {
        const header = try transaction.deref(ref, inline_bytes_off);
        const length = std.mem.readInt(u32, header[inline_len_off..][0..4], .little);
        try transaction.free(ref, inline_bytes_off + @as(usize, length));
        return;
    }

    const header = try chunkedHeader(transaction, ref);
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunk_count) : (chunkIndex += 1) {
        const start = chunkIndex * chunk_size;
        const chunkLength = @min(chunk_size, header.total_len - start);
        // Read the chunk ref from the still-intact index node, then free the chunk.
        // free() only updates the free list; it does not touch the index node's bytes.
        const node = try transaction.deref(ref, header.node_size);
        const chunk_ref = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        // Bounds-validate the chunk ref before handing its extent to the free
        // list: a corrupt ref would poison the pool with live/garbage space.
        _ = try transaction.deref(chunk_ref, chunkLength);
        try transaction.free(chunk_ref, chunkLength);
    }
    try transaction.free(ref, header.node_size);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Database = @import("../database.zig").Database;
const Io = std.Io;

fn blobTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "blob put then get round-trips bytes; empty is the null ref" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const ref = try put(&writeTransaction, "hello world");
    try testing.expect(ref != 0);
    try testing.expectEqualStrings("hello world", try get(&writeTransaction, ref));
    try testing.expectEqual(@as(usize, 11), try size(&writeTransaction, ref));
    const empty = try put(&writeTransaction, "");
    try testing.expectEqual(@as(Reference, 0), empty);
    try testing.expectEqualStrings("", try get(&writeTransaction, empty));
    try testing.expectEqual(@as(usize, 0), try size(&writeTransaction, empty));
    writeTransaction.deinit();
}

test "free releases a blob node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const ref = try put(&writeTransaction, "data");
    try free(&writeTransaction, ref); // must not error
    try free(&writeTransaction, 0); // freeing the null ref is a no-op
    writeTransaction.deinit();
}

test "chunked blob over the inline cap round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    // Just past the inline cap: forces the chunked representation (2 chunks).
    {
        const byteCount = inline_max + 1;
        const source = try testing.allocator.alloc(u8, byteCount);
        defer testing.allocator.free(source);
        for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

        const ref = try put(&writeTransaction, source);
        try testing.expect(ref != 0);
        try testing.expectEqual(byteCount, try size(&writeTransaction, ref));
        try testing.expectError(error.BlobChunked, get(&writeTransaction, ref));

        const out = try getAlloc(&writeTransaction, ref, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, source, out);

        try free(&writeTransaction, ref);
    }

    // A large blob spanning many chunks (~40 MiB).
    {
        const byteCount: usize = 40 * 1024 * 1024;
        const source = try testing.allocator.alloc(u8, byteCount);
        defer testing.allocator.free(source);
        for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

        const ref = try put(&writeTransaction, source);
        try testing.expect(ref != 0);
        try testing.expectEqual(byteCount, try size(&writeTransaction, ref));
        try testing.expectError(error.BlobChunked, get(&writeTransaction, ref));

        const out = try testing.allocator.alloc(u8, try size(&writeTransaction, ref));
        defer testing.allocator.free(out);
        try readInto(&writeTransaction, ref, out);

        // Full compare plus explicit checks at chunk boundaries.
        try testing.expectEqualSlices(u8, source, out);
        try testing.expectEqual(@as(u8, 0), out[0]);
        try testing.expectEqual(@as(u8, @intCast((chunk_size - 1) % 251)), out[chunk_size - 1]);
        try testing.expectEqual(@as(u8, @intCast(chunk_size % 251)), out[chunk_size]);
        try testing.expectEqual(@as(u8, @intCast((byteCount - 1) % 251)), out[byteCount - 1]);

        try free(&writeTransaction, ref);
    }

    writeTransaction.deinit();
}

test "a corrupt chunked header is an error, not a panic or a poisoned free list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_corrupt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = inline_max + 1; // 2 chunks
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    @memset(source, 0xAB);
    const ref = try put(&writeTransaction, source);

    const offset: usize = @intCast(ref);
    // (a) chunk_count inconsistent with total_len: previously underflowed
    // `total_len - start` (panic) and fed garbage extents to the free list.
    std.mem.writeInt(u32, database.store.map[offset + chunkCountOffset ..][0..4], 1000, .little);
    try testing.expectError(error.Corrupt, size(&writeTransaction, ref));
    var outputBuffer: [16]u8 = undefined;
    try testing.expectError(error.Corrupt, readInto(&writeTransaction, ref, outputBuffer[0..]));
    const frees_before = writeTransaction.in_flight_frees.items.len + writeTransaction.transactionReuse.extents.items.len;
    try testing.expectError(error.Corrupt, free(&writeTransaction, ref));
    try testing.expectEqual(frees_before, writeTransaction.in_flight_frees.items.len + writeTransaction.transactionReuse.extents.items.len);

    // (b) an out-of-range tag byte is Corrupt everywhere.
    database.store.map[offset] = 7;
    try testing.expectError(error.Corrupt, get(&writeTransaction, ref));
    try testing.expectError(error.Corrupt, size(&writeTransaction, ref));
    try testing.expectError(error.Corrupt, free(&writeTransaction, ref));
}

test "free of a chunked blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    const byteCount = inline_max + chunk_size + 7; // 3 chunks
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

    const ref = try put(&writeTransaction, source);
    try free(&writeTransaction, ref); // must not error
    writeTransaction.deinit();
}
