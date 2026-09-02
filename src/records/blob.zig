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
//! is allocated for it. The null reference is therefore a VALUE (the empty
//! string), not an absence: nullity must come from a null bitmap, never from
//! `reference == 0`, or every legitimately empty string is reclassified as null.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const sectionSize = @import("../platform.zig").sectionSize;

/// Largest blob stored as a single inline node. The +5 node header (tag + length)
/// plus the bytes must stay under `sectionSize`; the 64-byte margin covers it.
/// A blob of this size or smaller has a single contiguous slice and is readable
/// with `get`; anything larger is chunked.
pub const inlineMax: usize = sectionSize - 64;
/// Maximum RAW bytes per chunk node. Each chunk node is a bare byte allocation,
/// so it must itself fit within one section.
pub const chunkSize: usize = sectionSize - 64;

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

/// Copy up to `out.len` leading bytes of the blob at `reference` into `out`
/// and return how many were copied, which is `@min(out.len, value length)`.
/// Reads only the chunks the prefix touches, so a 256-byte prefix of a 40 MiB
/// value costs one chunk read. The null reference copies zero bytes.
/// No allocation. O(bytes copied) with I/O.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn readPrefix(transaction: anytype, reference: Reference, out: []u8) !usize {
    if (reference == 0) return 0;
    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagInline) {
        const stored = try get(transaction, reference);
        const copyLength = @min(stored.len, out.len);
        @memcpy(out[0..copyLength], stored[0..copyLength]);
        return copyLength;
    }
    const header = try chunkedHeader(transaction, reference);
    var copied: usize = 0;
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunkCount and copied < out.len) : (chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        const chunkLength = @min(chunkSize, header.totalLen - start);
        // Re-dereference the index node each iteration, as readInto does, so the
        // read is independent of any prior chunk dereference slice.
        const node = try transaction.dereference(reference, header.nodeSize);
        const chunkReference = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        const wanted = @min(chunkLength, out.len - copied);
        const chunk = try transaction.dereference(chunkReference, wanted);
        @memcpy(out[copied .. copied + wanted], chunk[0..wanted]);
        copied += wanted;
    }
    return copied;
}

/// The stored blob's total size and the order of its first `min(size,
/// probe.len)` bytes against the head of `probe`. `.eq` means the two agree
/// over that overlap, which leaves only the lengths to break the tie.
/// `storedByteCount` is the blob's full length, not the number of bytes the
/// comparison actually examined.
const HeadComparison = struct { order: std.math.Order, storedByteCount: usize };

/// Compare the blob at `reference` against `probe` over the bytes they share,
/// materializing neither side. Stops at the first difference, so a difference in
/// the first chunk costs one chunk read whatever the total size.
/// O(bytes examined) with I/O: one node read for an inline blob, two per chunk
/// touched for a chunked one.
fn compareHead(transaction: anytype, reference: Reference, probe: []const u8) !HeadComparison {
    if (reference == 0) return .{ .order = .eq, .storedByteCount = 0 };
    const tag = (try transaction.dereference(reference, 1))[0];
    if (tag == tagInline) {
        const stored = try get(transaction, reference);
        const overlap = @min(stored.len, probe.len);
        return .{ .order = std.mem.order(u8, stored[0..overlap], probe[0..overlap]), .storedByteCount = stored.len };
    }
    return compareChunkedHead(transaction, reference, probe);
}

/// `compareHead` for the chunked representation. Walks chunks in order,
/// comparing each chunk against the window of `probe` that lines up with it, so
/// a probe that ends inside a chunk compares only the overlap and a probe that
/// ends before a chunk starts stops the walk. O(bytes examined) with I/O.
fn compareChunkedHead(transaction: anytype, reference: Reference, probe: []const u8) !HeadComparison {
    const header = try chunkedHeader(transaction, reference);
    var chunkIndex: usize = 0;
    while (chunkIndex < header.chunkCount) : (chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        if (start >= probe.len) break;
        const chunkLength = @min(chunkSize, header.totalLen - start);
        // Re-dereference the index node each iteration, as readInto does, so the
        // read is independent of any prior chunk dereference slice.
        const node = try transaction.dereference(reference, header.nodeSize);
        const chunkReference = std.mem.readInt(u64, node[chunkRefsOffset + 8 * chunkIndex ..][0..8], .little);
        const overlap = @min(chunkLength, probe.len - start);
        const chunk = try transaction.dereference(chunkReference, chunkLength);
        const outcome = std.mem.order(u8, chunk[0..overlap], probe[start .. start + overlap]);
        if (outcome != .eq) return .{ .order = outcome, .storedByteCount = header.totalLen };
    }
    return .{ .order = .eq, .storedByteCount = header.totalLen };
}

/// The order of the blob at `reference` RELATIVE TO `probe`, comparing bytes
/// unsigned and lexicographically, exactly as `std.mem.order` would over the
/// same bytes. The null reference (0) is the empty byte string, so it orders
/// before every non-empty probe and equal to an empty one. No allocation and no
/// contiguous copy: works for a chunked blob, which `get` cannot serve.
/// O(bytes examined) with I/O. `error.Corrupt` for a bad tag or a chunked header
/// whose chunk count disagrees with its length.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn compare(transaction: anytype, reference: Reference, probe: []const u8) !std.math.Order {
    const head = try compareHead(transaction, reference, probe);
    if (head.order != .eq) return head.order;
    return std.math.order(head.storedByteCount, probe.len);
}

/// Whether the blob at `reference` begins with `prefix`. An empty prefix is a
/// prefix of everything, including the null reference; a prefix longer than the
/// blob is not a prefix of it. No allocation and no contiguous copy: works for a
/// chunked blob, and for a prefix that spans a chunk boundary.
/// O(prefix length) with I/O. Same `error.Corrupt` conditions as `compare`.
/// Accepts any transaction type exposing `dereference(reference, length) ![]const u8`.
pub fn startsWith(transaction: anytype, reference: Reference, prefix: []const u8) !bool {
    const head = try compareHead(transaction, reference, prefix);
    return head.order == .eq and head.storedByteCount >= prefix.len;
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

test "readPrefix of an inline value shorter than out copies exactly those bytes and leaves the tail untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const reference = try put(&writeTransaction, "hi");
    var out: [8]u8 = undefined;
    @memset(&out, 0xAA);
    const copied = try readPrefix(&writeTransaction, reference, &out);
    try testing.expectEqual(@as(usize, 2), copied);
    try testing.expectEqualSlices(u8, "hi", out[0..2]);
    for (out[2..]) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
}

test "readPrefix of an inline value longer than out copies exactly out.len bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const reference = try put(&writeTransaction, "hello world");
    var out: [5]u8 = undefined;
    const copied = try readPrefix(&writeTransaction, reference, &out);
    try testing.expectEqual(@as(usize, 5), copied);
    try testing.expectEqualSlices(u8, "hello", out[0..5]);
}

test "readPrefix of a chunked value returns the correct byte count and bytes at three boundary points" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix_chunked.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = 2 * chunkSize + 7; // 3 chunks: chunkSize, chunkSize, 7.
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, position| byte.* = @truncate(position);

    const reference = try put(&writeTransaction, source);

    // (a) inside chunk 0.
    {
        var out: [100]u8 = undefined;
        const copied = try readPrefix(&writeTransaction, reference, &out);
        try testing.expectEqual(@as(usize, 100), copied);
        try testing.expectEqualSlices(u8, source[0..100], out[0..]);
    }
    // (b) exactly on the chunk 0 boundary.
    {
        const out = try testing.allocator.alloc(u8, chunkSize);
        defer testing.allocator.free(out);
        const copied = try readPrefix(&writeTransaction, reference, out);
        try testing.expectEqual(chunkSize, copied);
        try testing.expectEqualSlices(u8, source[0..chunkSize], out);
    }
    // (c) inside chunk 1.
    {
        const wanted = chunkSize + 50;
        const out = try testing.allocator.alloc(u8, wanted);
        defer testing.allocator.free(out);
        const copied = try readPrefix(&writeTransaction, reference, out);
        try testing.expectEqual(wanted, copied);
        try testing.expectEqualSlices(u8, source[0..wanted], out);
    }
}

test "readPrefix(reference = 0, out) returns 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix_null.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try readPrefix(&writeTransaction, 0, &out));
}

test "readPrefix against a bad tag byte is error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix_corrupt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const allocation = try writeTransaction.alloc(16);
    allocation.bytes[0] = 7;
    var out: [4]u8 = undefined;
    try testing.expectError(error.Corrupt, readPrefix(&writeTransaction, allocation.reference, &out));
}

test "readPrefix with out.len == 0 returns 0 for both inline and chunked representations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTmpPath(testing.allocator, &tmp, "blob_readprefix_zero.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var empty: [0]u8 = undefined;
    const inlineReference = try put(&writeTransaction, "hello");
    try testing.expectEqual(@as(usize, 0), try readPrefix(&writeTransaction, inlineReference, &empty));

    const chunkedSource = try testing.allocator.alloc(u8, inlineMax + 1);
    defer testing.allocator.free(chunkedSource);
    @memset(chunkedSource, 1);
    const chunkedReference = try put(&writeTransaction, chunkedSource);
    try testing.expectEqual(@as(usize, 0), try readPrefix(&writeTransaction, chunkedReference, &empty));
}

test {
    _ = @import("blobTests.zig");
}
