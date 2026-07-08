//! Blob heap with a tagged small/large representation.
//!
//! A single arena allocation must fit within one mmap section
//! (`platform.sectionSize` = 16 MiB); larger requests fail with
//! `error.AllocTooLarge`. Blobs are therefore stored in one of two shapes,
//! distinguished by a leading tag byte:
//!
//!   Inline (length <= inlineMax):
//!     [tag=0 u8][length u32 LE][bytes...]
//!   Chunked (length > inlineMax): an index node
//!     [tag=1 u8][totalLen u64 LE][chunkCount u32 LE][chunkReference u64 LE * count]
//!   plus `chunkCount` separate chunk nodes, each holding up to `chunkSize`
//!   RAW bytes (no per-chunk header). All but the last chunk are exactly
//!   `chunkSize` bytes; the last is `totalLen - (chunkCount-1)*chunkSize`.
//!
//! Empty blob (zero-length bytes) is represented as the null reference (0); no node
//! is allocated for it.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const sectionSize = @import("../platform.zig").sectionSize;

/// Largest blob stored as a single inline node. The +5 node header (tag + length)
/// plus the bytes must stay under `sectionSize`; the 64-byte margin covers it.
const inlineMax: usize = sectionSize - 64;
/// Maximum RAW bytes per chunk node. Each chunk node is a bare byte allocation,
/// so it must itself fit within one section.
const chunkSize: usize = sectionSize - 64;

const tagInline: u8 = 0;
const tagChunked: u8 = 1;

// Inline node field offsets.
const inlineLenOff: usize = 1;
const inlineBytesOff: usize = 5;

// Chunked index node field offsets.
const totalLengthOffset: usize = 1;
const chunkCountOffset: usize = 9;
const chunkRefsOffset: usize = 13;

fn indexNodeSize(chunkCount: usize) usize {
    return chunkRefsOffset + 8 * chunkCount;
}

const ChunkedHeader = struct { totalLen: usize, chunkCount: u32, nodeSize: usize };

/// Read and VALIDATE a chunked-blob index header. These fields come straight
/// from the mapped file: an unvalidated chunkCount feeds lengths to transaction.free
/// (poisoning the free list with garbage extents -- corruption that spreads
/// after commit), underflows `totalLen - start`, and on 32-bit hosts can
/// overflow indexNodeSize into a too-short dereference. Sizes are computed in u64.
fn chunkedHeader(transaction: anytype, reference: Reference) !ChunkedHeader {
    const header = try transaction.dereference(reference, chunkRefsOffset);
    if (header[0] != tagChunked) return error.Corrupt;
    const totalLen = std.mem.readInt(u64, header[totalLengthOffset..][0..8], .little);
    const chunkCount = std.mem.readInt(u32, header[chunkCountOffset..][0..4], .little);
    const expected: u64 = (totalLen + chunkSize - 1) / chunkSize;
    if (chunkCount == 0 or chunkCount != expected) return error.Corrupt;
    const nodeSize: u64 = @as(u64, chunkRefsOffset) + 8 * @as(u64, chunkCount);
    if (nodeSize > sectionSize) return error.Corrupt;
    return .{ .totalLen = @intCast(totalLen), .chunkCount = chunkCount, .nodeSize = @intCast(nodeSize) };
}

/// Write `bytes` into the blob heap and return its Reference.
/// Returns the null reference (0) when `bytes` is empty -- no node is allocated.
/// Small blobs become a single inline node; blobs over `inlineMax` are split
/// into chunk nodes referenced by an index node.
pub fn put(transaction: *WriteTransaction, bytes: []const u8) !Reference {
    if (bytes.len == 0) return 0;

    if (bytes.len <= inlineMax) {
        const total = inlineBytesOff + bytes.len;
        const allocation = try transaction.alloc(total);
        allocation.bytes[0] = tagInline;
        std.mem.writeInt(u32, allocation.bytes[inlineLenOff..][0..4], @intCast(bytes.len), .little);
        @memcpy(allocation.bytes[inlineBytesOff .. inlineBytesOff + bytes.len], bytes);
        return allocation.reference;
    }

    const chunkCount = (bytes.len + chunkSize - 1) / chunkSize;

    // Allocate the index node first and write its header. Its mutable slice stays
    // valid across the chunk allocations below: sections never move on growth, and
    // chunk allocations land in distinct regions, so they never touch this node.
    const indexNode = try transaction.alloc(indexNodeSize(chunkCount));
    indexNode.bytes[0] = tagChunked;
    std.mem.writeInt(u64, indexNode.bytes[totalLengthOffset..][0..8], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, indexNode.bytes[chunkCountOffset..][0..4], @intCast(chunkCount), .little);

    var chunkIndex: usize = 0;
    while (chunkIndex < chunkCount) : (chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        const end = @min(start + chunkSize, bytes.len);
        const chunk = try transaction.alloc(end - start);
        // Copy this chunk's source bytes in immediately, before the next alloc.
        @memcpy(chunk.bytes, bytes[start..end]);
        std.mem.writeInt(u64, indexNode.bytes[chunkRefsOffset + 8 * chunkIndex ..][0..8], chunk.reference, .little);
    }

    return indexNode.reference;
}

/// Number of bytes stored at `reference`. Null reference -> 0.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn size(transaction: anytype, reference: Reference) !usize {
    if (reference == 0) return 0;
    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagInline) {
        const node = try transaction.dereference(reference, inlineBytesOff);
        return std.mem.readInt(u32, node[inlineLenOff..][0..4], .little);
    }
    return (try chunkedHeader(transaction, reference)).totalLen;
}

/// Zero-copy slice into an inline blob node. Null reference -> empty slice.
/// Returns `error.BlobChunked` for a chunked blob (it has no single contiguous
/// slice); callers use `readInto`/`getAlloc` for those.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn get(transaction: anytype, reference: Reference) ![]const u8 {
    if (reference == 0) return &.{};
    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagChunked) return error.BlobChunked;
    if (tag != tagInline) return error.Corrupt;
    const header = try transaction.dereference(reference, inlineBytesOff);
    const length = std.mem.readInt(u32, header[inlineLenOff..][0..4], .little);
    const node = try transaction.dereference(reference, inlineBytesOff + @as(usize, length));
    return node[inlineBytesOff .. inlineBytesOff + length];
}

/// Copy the blob at `reference` into `out`, which must be exactly `size(reference)` bytes.
/// No allocation; the caller owns `out`. Works for both inline and chunked blobs.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn readInto(transaction: anytype, reference: Reference, out: []u8) !void {
    std.debug.assert(out.len == try size(transaction, reference));
    if (reference == 0) return;

    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagInline) {
        const header = try transaction.dereference(reference, inlineBytesOff);
        const length = std.mem.readInt(u32, header[inlineLenOff..][0..4], .little);
        const node = try transaction.dereference(reference, inlineBytesOff + @as(usize, length));
        @memcpy(out, node[inlineBytesOff .. inlineBytesOff + length]);
        return;
    }

    const header = try chunkedHeader(transaction, reference);
    if (header.totalLen != out.len) return error.Corrupt;
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunkCount) : (chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        const chunkLength = @min(chunkSize, header.totalLen - start);
        // Re-dereference the index node each iteration so the read is independent of any
        // prior chunk dereference slices.
        const node = try transaction.dereference(reference, header.nodeSize);
        const chunkReference = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        const chunk = try transaction.dereference(chunkReference, chunkLength);
        @memcpy(out[start .. start + chunkLength], chunk);
    }
}

/// Allocate a buffer, copy the blob at `reference` into it, and return it. Caller frees.
pub fn getAlloc(transaction: anytype, reference: Reference, allocator: std.mem.Allocator) ![]u8 {
    const byteCount = try size(transaction, reference);
    const buffer = try allocator.alloc(u8, byteCount);
    errdefer allocator.free(buffer);
    try readInto(transaction, reference, buffer);
    return buffer;
}

/// Copy the blob at `sourceReference` (inline OR chunked) from a source database into `dst`,
/// returning its new Reference in the destination. The null reference (0) copies to 0.
/// Materializes the blob in RAM during the copy (acceptable for a maintenance
/// op); a future optimization could stream chunks without buffering the whole
/// blob. Accepts any source transaction exposing `dereference(reference, length) ![]const u8`.
pub fn copyInto(source: anytype, dst: *WriteTransaction, sourceReference: Reference) !Reference {
    if (sourceReference == 0) return 0;
    const buffer = try getAlloc(source, sourceReference, dst.database.store.allocator);
    defer dst.database.store.allocator.free(buffer);
    return try put(dst, buffer);
}

/// Release the blob at `reference` back to the storage engine.
/// Freeing the null reference (0) is a no-op. For a chunked blob, frees every chunk
/// node and then the index node.
pub fn free(transaction: *WriteTransaction, reference: Reference) !void {
    if (reference == 0) return;
    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagInline) {
        const header = try transaction.dereference(reference, inlineBytesOff);
        const length = std.mem.readInt(u32, header[inlineLenOff..][0..4], .little);
        try transaction.free(reference, inlineBytesOff + @as(usize, length));
        return;
    }

    const header = try chunkedHeader(transaction, reference);
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunkCount) : (chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        const chunkLength = @min(chunkSize, header.totalLen - start);
        // Read the chunk reference from the still-intact index node, then free the chunk.
        // free() only updates the free list; it does not touch the index node's bytes.
        const node = try transaction.dereference(reference, header.nodeSize);
        const chunkReference = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        // Bounds-validate the chunk reference before handing its extent to the free
        // list: a corrupt reference would poison the pool with live/garbage space.
        _ = try transaction.dereference(chunkReference, chunkLength);
        try transaction.free(chunkReference, chunkLength);
    }
    try transaction.free(reference, header.nodeSize);
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

test "blob put then get round-trips bytes; empty is the null reference" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const reference = try put(&writeTransaction, "hello world");
    try testing.expect(reference != 0);
    try testing.expectEqualStrings("hello world", try get(&writeTransaction, reference));
    try testing.expectEqual(@as(usize, 11), try size(&writeTransaction, reference));
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
    const reference = try put(&writeTransaction, "data");
    try free(&writeTransaction, reference); // must not error
    try free(&writeTransaction, 0); // freeing the null reference is a no-op
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
        const byteCount = inlineMax + 1;
        const source = try testing.allocator.alloc(u8, byteCount);
        defer testing.allocator.free(source);
        for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

        const reference = try put(&writeTransaction, source);
        try testing.expect(reference != 0);
        try testing.expectEqual(byteCount, try size(&writeTransaction, reference));
        try testing.expectError(error.BlobChunked, get(&writeTransaction, reference));

        const out = try getAlloc(&writeTransaction, reference, testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, source, out);

        try free(&writeTransaction, reference);
    }

    // A large blob spanning many chunks (~40 MiB).
    {
        const byteCount: usize = 40 * 1024 * 1024;
        const source = try testing.allocator.alloc(u8, byteCount);
        defer testing.allocator.free(source);
        for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

        const reference = try put(&writeTransaction, source);
        try testing.expect(reference != 0);
        try testing.expectEqual(byteCount, try size(&writeTransaction, reference));
        try testing.expectError(error.BlobChunked, get(&writeTransaction, reference));

        const out = try testing.allocator.alloc(u8, try size(&writeTransaction, reference));
        defer testing.allocator.free(out);
        try readInto(&writeTransaction, reference, out);

        // Full compare plus explicit checks at chunk boundaries.
        try testing.expectEqualSlices(u8, source, out);
        try testing.expectEqual(@as(u8, 0), out[0]);
        try testing.expectEqual(@as(u8, @intCast((chunkSize - 1) % 251)), out[chunkSize - 1]);
        try testing.expectEqual(@as(u8, @intCast(chunkSize % 251)), out[chunkSize]);
        try testing.expectEqual(@as(u8, @intCast((byteCount - 1) % 251)), out[byteCount - 1]);

        try free(&writeTransaction, reference);
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

    const byteCount = inlineMax + 1; // 2 chunks
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    @memset(source, 0xAB);
    const reference = try put(&writeTransaction, source);

    const offset: usize = @intCast(reference);
    // (a) chunkCount inconsistent with totalLen: previously underflowed
    // `totalLen - start` (panic) and fed garbage extents to the free list.
    std.mem.writeInt(u32, database.store.map[offset + chunkCountOffset ..][0..4], 1000, .little);
    try testing.expectError(error.Corrupt, size(&writeTransaction, reference));
    var outputBuffer: [16]u8 = undefined;
    try testing.expectError(error.Corrupt, readInto(&writeTransaction, reference, outputBuffer[0..]));
    const freesBefore = writeTransaction.inFlightFrees.items.len + writeTransaction.transactionReuse.extents.items.len;
    try testing.expectError(error.Corrupt, free(&writeTransaction, reference));
    try testing.expectEqual(freesBefore, writeTransaction.inFlightFrees.items.len + writeTransaction.transactionReuse.extents.items.len);

    // (b) an out-of-range tag byte is Corrupt everywhere.
    database.store.map[offset] = 7;
    try testing.expectError(error.Corrupt, get(&writeTransaction, reference));
    try testing.expectError(error.Corrupt, size(&writeTransaction, reference));
    try testing.expectError(error.Corrupt, free(&writeTransaction, reference));
}

test "free of a chunked blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    const byteCount = inlineMax + chunkSize + 7; // 3 chunks
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, position| byte.* = @intCast(position % 251);

    const reference = try put(&writeTransaction, source);
    try free(&writeTransaction, reference); // must not error
    writeTransaction.deinit();
}
