//! The index key of a blob value: its leading bytes, truncated.
//!
//! An indexed `.blob` property's value index is keyed by the stored bytes
//! truncated to `maxLength`, so the key a write inserts and the key a query
//! probes with are produced here and nowhere else.
//!
//! Truncation is sound because the query planner residual-filters every
//! candidate it draws from a value index (see query/planner.zig): the true
//! match set is a subset of the prefix-match set, and the filter removes the
//! rest. A blob value index is therefore a CANDIDATE index, not a covering
//! one, and no caller may treat the presence of a key as proof that a row
//! matches.
//!
//! Two reasons the bound exists. The ordering reason is binding:
//! byteKeyIndex's comparator dereferences a key with `blob.get`, which fails
//! with `error.BlobChunked` above `blob.inlineMax`, so an unbounded key would
//! be unorderable rather than merely large. The cost reason is secondary: a
//! B+tree split duplicates the boundary key into an independently owned blob
//! (bTreeCore.zig, `Keying.duplicateKey`), and every insert puts the key bytes
//! into the blob heap, so long keys cost heap space per row.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const blob = @import("blob.zig");

/// Longest index key a blob value produces. Values longer than this share the
/// key of every other value with the same 256-byte prefix.
pub const maxLength: usize = 256;

/// The index key of the blob at `reference`: its first `maxLength` bytes, or
/// all of them when the value is shorter, copied into `buffer` and returned as
/// a slice of it. The null reference is the empty value and yields an empty
/// key. Allocates nothing and works for chunked values.
/// O(bytes copied) with I/O.
pub fn read(transaction: anytype, reference: Reference, buffer: *[maxLength]u8) ![]const u8 {
    const length = try blob.readPrefix(transaction, reference, buffer);
    return buffer[0..length];
}

/// The index key of `bytes` held in memory: its first `maxLength` bytes, or
/// all of them when shorter. O(1), no I/O and no copy, the result aliases
/// `bytes`.
pub fn truncated(bytes: []const u8) []const u8 {
    return bytes[0..@min(bytes.len, maxLength)];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Database = @import("../database.zig").Database;

fn blobIndexKeyTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

test "truncated on lengths 0, 1, 255, 256, 257 and 1000 returns lengths 0, 1, 255, 256, 256, 256" {
    var buffer: [1000]u8 = undefined;
    @memset(&buffer, 'x');
    const lengths = [_]usize{ 0, 1, 255, 256, 257, 1000 };
    const expected = [_]usize{ 0, 1, 255, 256, 256, 256 };
    for (lengths, expected) |length, expectedLength| {
        try testing.expectEqual(expectedLength, truncated(buffer[0..length]).len);
    }
}

test "truncated aliases the input rather than copying" {
    var buffer: [300]u8 = undefined;
    @memset(&buffer, 'y');
    const key = truncated(&buffer);
    try testing.expectEqual(@as(usize, 256), key.len);
    try testing.expect(key.ptr == &buffer);
}

test "read of a 300-byte value returns 256 bytes equal to the first 256 bytes of the RAM copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobIndexKeyTmpPath(testing.allocator, &tmp, "bik_read.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var source: [300]u8 = undefined;
    for (&source, 0..) |*byte, position| byte.* = @truncate(position);
    const reference = try blob.put(&writeTransaction, &source);

    var keyBuffer: [maxLength]u8 = undefined;
    const key = try read(&writeTransaction, reference, &keyBuffer);
    try testing.expectEqual(@as(usize, 256), key.len);
    try testing.expectEqualSlices(u8, source[0..256], key);
}

test "read of the null reference yields an empty key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobIndexKeyTmpPath(testing.allocator, &tmp, "bik_read_null.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var keyBuffer: [maxLength]u8 = undefined;
    const key = try read(&writeTransaction, 0, &keyBuffer);
    try testing.expectEqual(@as(usize, 0), key.len);
}

test "MUST NOT trigger truncation: a 256-byte value round-trips whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobIndexKeyTmpPath(testing.allocator, &tmp, "bik_no_trunc.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, position| byte.* = @truncate(position * 7);
    // In-RAM truncated: the literal 256 this depends on.
    try testing.expectEqual(@as(usize, 256), truncated(&source).len);
    try testing.expect(std.mem.eql(u8, truncated(&source), &source));

    const reference = try blob.put(&writeTransaction, &source);
    var keyBuffer: [maxLength]u8 = undefined;
    const key = try read(&writeTransaction, reference, &keyBuffer);
    try testing.expectEqualSlices(u8, &source, key);
}

test "MUST trigger truncation: a 257-byte value differs from its input and equals input[0..256]" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobIndexKeyTmpPath(testing.allocator, &tmp, "bik_trunc.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var source: [257]u8 = undefined;
    for (&source, 0..) |*byte, position| byte.* = @truncate(position * 3 + 1);
    try testing.expect(!std.mem.eql(u8, truncated(&source), &source));
    try testing.expectEqualSlices(u8, source[0..256], truncated(&source));

    const reference = try blob.put(&writeTransaction, &source);
    var keyBuffer: [maxLength]u8 = undefined;
    const key = try read(&writeTransaction, reference, &keyBuffer);
    try testing.expect(!std.mem.eql(u8, &source, key));
    try testing.expectEqualSlices(u8, source[0..256], key);
}

// Node-shape coupling test, pinning section 1.1 of the phase 5 spec: Index and
// byteKeyIndex both instantiate bTreeCore.BTreeCore(...).create, which
// allocates leafNodeSize and encodes an identical empty leaf, so
// catalog.createFromDefinitions may create either root for an empty value
// index and produce byte-identical bytes. This fails the moment the two
// instantiations diverge in on-disk shape.
test "Index.create and byteKeyIndex.create produce byte-identical empty leaf nodes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobIndexKeyTmpPath(testing.allocator, &tmp, "bik_node_shape.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const Index = @import("../trees/index.zig");
    const byteKeyIndex = @import("../trees/byteKeyIndex.zig");
    const indexNode = @import("../trees/indexNode.zig");

    const numericRoot = try Index.create(&writeTransaction);
    const byteRoot = try byteKeyIndex.create(&writeTransaction);
    const numericBytes = try writeTransaction.dereference(numericRoot, indexNode.leafNodeSize);
    const byteBytes = try writeTransaction.dereference(byteRoot, indexNode.leafNodeSize);
    try testing.expectEqualSlices(u8, numericBytes, byteBytes);
}
