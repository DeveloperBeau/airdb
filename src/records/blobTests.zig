// blobTests.zig -- companion suite for blob.zig: compare/startsWith over both
// the inline and chunked representations, the null-reference-is-empty-string
// rule, corruption handling, and the streaming property that separates these
// helpers from a materializing implementation.
//
// Fixture rule (spec): an expected value is either a hand-written literal or
// computed by std over bytes the test holds in RAM. Never an answer read back
// through blob.get/getAlloc, and never a second call into the helper under
// test.
//
// Chunked (over-inlineMax) fixtures are expensive: one chunk is 16,777,152
// bytes. To respect the cap on how many such fixtures this suite builds, T-B10
// is folded into the T-B9 test and T-B14 is folded into the T-B8 test, since
// each pair already shares the same two-chunk fixture shape; every other test
// below matches the spec's test plan one for one.

const std = @import("std");
const testing = std.testing;
const blob = @import("blob.zig");
const Database = @import("../database.zig").Database;
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Io = std.Io;

fn blobTestTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

/// Counts every dereference a blob helper performs, so a test can prove the
/// helpers stream rather than materialize. Exposes `dereference` and nothing
/// else, so a helper that reached for any other transaction capability would
/// fail to compile against it.
const CountingTransaction = struct {
    inner: *WriteTransaction,
    dereferenceCount: u64 = 0,

    pub fn dereference(self: *CountingTransaction, reference: Reference, length: usize) ![]const u8 {
        self.dereferenceCount += 1;
        return self.inner.dereference(reference, length);
    }
};

// Fills `bytes` with a pattern whose period (251) does not divide chunkSize, so
// no two chunks hold identical content and a chunk read from the wrong offset
// produces a different answer rather than the same one.
fn fillPattern(bytes: []u8) void {
    for (bytes, 0..) |*byte, position| byte.* = @intCast(position % 251);
}

test "T-B1: inlineMax and chunkSize are what the suite assumes" {
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024 - 64), blob.inlineMax);
    try testing.expectEqual(blob.inlineMax, blob.chunkSize);
}

test "T-B2: compare over inline blobs, hand-written orders" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const Case = struct { stored: []const u8, probe: []const u8, expected: std.math.Order };
    // "zoo"/"apple" and "apple"/"zo" are the pairs where content order and
    // length order disagree; "\x00"/"" and "\x80"/"\x7f" pin NUL-as-content
    // and unsigned byte comparison respectively.
    const cases = [_]Case{
        .{ .stored = "apple", .probe = "banana", .expected = .lt },
        .{ .stored = "banana", .probe = "apple", .expected = .gt },
        .{ .stored = "apple", .probe = "apple", .expected = .eq },
        .{ .stored = "apple", .probe = "applesauce", .expected = .lt },
        .{ .stored = "applesauce", .probe = "apple", .expected = .gt },
        .{ .stored = "apple", .probe = "", .expected = .gt },
        .{ .stored = "zoo", .probe = "apple", .expected = .gt },
        .{ .stored = "apple", .probe = "zo", .expected = .lt },
        .{ .stored = "\x00", .probe = "", .expected = .gt },
        .{ .stored = "\x80", .probe = "\x7f", .expected = .gt },
    };
    for (cases) |case| {
        const reference = try blob.put(&writeTransaction, case.stored);
        try testing.expectEqual(case.expected, try blob.compare(&writeTransaction, reference, case.probe));
    }
}

test "T-B3: the null reference is the empty string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    // False positive it must not fire on: the null reference against "" is
    // .eq, not .lt.
    try testing.expectEqual(std.math.Order.eq, try blob.compare(&writeTransaction, 0, ""));
    try testing.expectEqual(std.math.Order.lt, try blob.compare(&writeTransaction, 0, "a"));

    const reference = try blob.put(&writeTransaction, "");
    try testing.expectEqual(@as(Reference, 0), reference);
    try testing.expectEqual(std.math.Order.eq, try blob.compare(&writeTransaction, reference, ""));
}

test "T-B4: startsWith over inline blobs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const reference = try blob.put(&writeTransaction, "applesauce");
    try testing.expect(try blob.startsWith(&writeTransaction, reference, ""));
    try testing.expect(try blob.startsWith(&writeTransaction, reference, "a"));
    try testing.expect(try blob.startsWith(&writeTransaction, reference, "apple"));
    // Equal-length prefix: must be true. Separates >= from a missing length check.
    try testing.expect(try blob.startsWith(&writeTransaction, reference, "applesauce"));
    // One byte longer than the value: must be false. Separates >= from >.
    try testing.expect(!(try blob.startsWith(&writeTransaction, reference, "applesauces")));
    try testing.expect(!(try blob.startsWith(&writeTransaction, reference, "applesaucf")));
    try testing.expect(!(try blob.startsWith(&writeTransaction, reference, "b")));
    // Case sensitivity (D2): no folding.
    try testing.expect(!(try blob.startsWith(&writeTransaction, reference, "Apple")));
}

test "T-B5: startsWith on the null reference" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    try testing.expect(try blob.startsWith(&writeTransaction, 0, ""));
    try testing.expect(!(try blob.startsWith(&writeTransaction, 0, "a")));
}

test "T-B6: chunked, a difference only in the last chunk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b6.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = 2 * blob.chunkSize + 7;
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    fillPattern(source);
    const reference = try blob.put(&writeTransaction, source);

    // False positive control: an exact copy must compare equal.
    const exactCopy = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(exactCopy);
    try testing.expectEqual(std.math.Order.eq, try blob.compare(&writeTransaction, reference, exactCopy));

    // Mutated upward: the reference (stored) sorts below the probe.
    const higher = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(higher);
    higher[byteCount - 3] += 1;
    try testing.expectEqual(std.mem.order(u8, source, higher), try blob.compare(&writeTransaction, reference, higher));
    try testing.expectEqual(std.math.Order.lt, try blob.compare(&writeTransaction, reference, higher));

    // Mutated downward: the reference (stored) sorts above the probe.
    const lower = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(lower);
    lower[byteCount - 3] -= 1;
    try testing.expectEqual(std.mem.order(u8, source, lower), try blob.compare(&writeTransaction, reference, lower));
    try testing.expectEqual(std.math.Order.gt, try blob.compare(&writeTransaction, reference, lower));
}

test "T-B7: chunked, operands straddling a chunk boundary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b7.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = 2 * blob.chunkSize + 7;
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    fillPattern(source);
    const reference = try blob.put(&writeTransaction, source);

    // 1: differs at the last byte of chunk 0.
    {
        const probe = try testing.allocator.dupe(u8, source);
        defer testing.allocator.free(probe);
        probe[blob.chunkSize - 1] += 1;
        try testing.expectEqual(std.mem.order(u8, source, probe), try blob.compare(&writeTransaction, reference, probe));
    }

    // 2: differs at the first byte of chunk 1. This is the case that catches a
    // chunk window computed from the wrong `start`.
    {
        const probe = try testing.allocator.dupe(u8, source);
        defer testing.allocator.free(probe);
        probe[blob.chunkSize] += 1;
        try testing.expectEqual(std.mem.order(u8, source, probe), try blob.compare(&writeTransaction, reference, probe));
    }

    // 3: probe ends precisely on the chunk boundary; the stored blob
    // continues. This is the case that catches an off-by-one in the
    // `start >= probe.len` guard.
    {
        const probe = try testing.allocator.dupe(u8, source[0..blob.chunkSize]);
        defer testing.allocator.free(probe);
        try testing.expectEqual(std.math.Order.gt, try blob.compare(&writeTransaction, reference, probe));
    }

    // 4: probe ends inside the final chunk.
    {
        const probe = try testing.allocator.dupe(u8, source[0 .. 2 * blob.chunkSize + 3]);
        defer testing.allocator.free(probe);
        try testing.expectEqual(std.math.Order.gt, try blob.compare(&writeTransaction, reference, probe));
    }
}

test "T-B8: chunked, probe longer than the blob; and (T-B14) a corrupted chunk header errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b8.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = blob.inlineMax + 1; // 2 chunks
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    fillPattern(source);
    const reference = try blob.put(&writeTransaction, source);

    const probe = try testing.allocator.alloc(u8, byteCount + 1);
    defer testing.allocator.free(probe);
    @memcpy(probe[0..byteCount], source);
    probe[byteCount] = 0;
    try testing.expectEqual(std.math.Order.lt, try blob.compare(&writeTransaction, reference, probe));

    // T-B14: write a chunkCount of 1000 over this same two-chunk blob's
    // header and expect error.Corrupt from both helpers. Pins that the new
    // helpers validate through chunkedHeader rather than reading the header
    // fields raw. Offset per blob.zig's documented chunked layout:
    // [tag=1 u8][totalLen u64 LE][chunkCount u32 LE]..., so chunkCount sits at
    // tag(1) + totalLen(8) = 9.
    const chunkCountOffset = 9;
    const offset: usize = @intCast(reference);
    std.mem.writeInt(u32, database.store.map[offset + chunkCountOffset ..][0..4], 1000, .little);
    try testing.expectError(error.Corrupt, blob.compare(&writeTransaction, reference, source));
    try testing.expectError(error.Corrupt, blob.startsWith(&writeTransaction, reference, source));
}

test "T-B9: startsWith across a chunk boundary, a short probe within chunk 0; and (T-B10) the helpers serve what get cannot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b9.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = blob.chunkSize + 10; // 2 chunks, second chunk 10 bytes
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    fillPattern(source);
    const reference = try blob.put(&writeTransaction, source);

    const prefixLength = blob.chunkSize + 5;

    // Spans the boundary: true.
    {
        const prefix = try testing.allocator.dupe(u8, source[0..prefixLength]);
        defer testing.allocator.free(prefix);
        try testing.expect(try blob.startsWith(&writeTransaction, reference, prefix));
    }

    // Same prefix, last byte flipped: false.
    {
        const prefix = try testing.allocator.dupe(u8, source[0..prefixLength]);
        defer testing.allocator.free(prefix);
        prefix[prefixLength - 1] += 1;
        try testing.expect(!(try blob.startsWith(&writeTransaction, reference, prefix)));
    }

    // Same prefix, byte at chunkSize - 1 (last byte of chunk 0) flipped: false.
    {
        const prefix = try testing.allocator.dupe(u8, source[0..prefixLength]);
        defer testing.allocator.free(prefix);
        prefix[blob.chunkSize - 1] += 1;
        try testing.expect(!(try blob.startsWith(&writeTransaction, reference, prefix)));
    }

    // One byte longer than the whole blob: false.
    {
        const prefix = try testing.allocator.alloc(u8, byteCount + 1);
        defer testing.allocator.free(prefix);
        @memcpy(prefix[0..byteCount], source);
        prefix[byteCount] = 0;
        try testing.expect(!(try blob.startsWith(&writeTransaction, reference, prefix)));
    }

    // Empty prefix: true.
    try testing.expect(try blob.startsWith(&writeTransaction, reference, ""));

    // A probe shorter than one chunk (10 bytes, entirely inside chunk 0)
    // against this genuinely chunked value: the most common real use of
    // beginsWith/eq is a short search string against a large stored blob, and
    // every other case in this test uses a probe that is chunk-scale or
    // larger. Both sides come from RAM buffers this test owns; only compare
    // and startsWith touch storage.
    {
        const shortProbe = try testing.allocator.dupe(u8, source[0..10]);
        defer testing.allocator.free(shortProbe);
        try testing.expectEqual(std.mem.order(u8, source, shortProbe), try blob.compare(&writeTransaction, reference, shortProbe));
        try testing.expect(try blob.startsWith(&writeTransaction, reference, shortProbe));
    }

    // Same short probe, last byte flipped: compare's order flips and
    // startsWith turns false.
    {
        const shortProbe = try testing.allocator.dupe(u8, source[0..10]);
        defer testing.allocator.free(shortProbe);
        shortProbe[9] += 1;
        try testing.expectEqual(std.mem.order(u8, source, shortProbe), try blob.compare(&writeTransaction, reference, shortProbe));
        try testing.expect(!(try blob.startsWith(&writeTransaction, reference, shortProbe)));
    }

    // T-B10: get() cannot serve a chunked blob; compare/startsWith can. This is
    // the direct proof that the helpers do not route through get, and the test
    // that fails first if the implementation is "simplified" into materializing.
    try testing.expectError(error.BlobChunked, blob.get(&writeTransaction, reference));
    _ = try blob.compare(&writeTransaction, reference, source);
    _ = try blob.startsWith(&writeTransaction, reference, source[0..prefixLength]);
}

test "T-B11: streaming, measured in dereferences" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b11.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const byteCount = 2 * blob.chunkSize + 7;
    const source = try testing.allocator.alloc(u8, byteCount);
    defer testing.allocator.free(source);
    fillPattern(source);
    const reference = try blob.put(&writeTransaction, source);

    // Correction to the brief: a failing allocator cannot be wired into these
    // helpers, because they take no allocator parameter at all; allocation
    // freedom is structural here (no allocator in the signature, and
    // CountingTransaction exposes only dereference, so any other transaction
    // capability would fail to compile). This test pins the part that is not
    // structural: streaming.
    const earlyProbe = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(earlyProbe);
    earlyProbe[0] += 1;

    const lateProbe = try testing.allocator.dupe(u8, source);
    defer testing.allocator.free(lateProbe);
    lateProbe[byteCount - 1] += 1;

    var earlyCounting = CountingTransaction{ .inner = &writeTransaction };
    _ = try blob.compare(&earlyCounting, reference, earlyProbe);
    const earlyCount = earlyCounting.dereferenceCount;

    var lateCounting = CountingTransaction{ .inner = &writeTransaction };
    _ = try blob.compare(&lateCounting, reference, lateProbe);
    const lateCount = lateCounting.dereferenceCount;

    // 1 tag read + 1 index-header read + 1 index-node read + 1 chunk read = 4
    // for a first-chunk difference.
    try testing.expect(earlyCount <= 5);
    // 2 (tag + header) + 3 chunks * 2 (node + chunk) reads = 8 when all three
    // chunks are examined.
    try testing.expect(lateCount >= 7);
    try testing.expect(lateCount > earlyCount);
    // Fails if the implementation ever dereferences per byte rather than per
    // chunk.
    try testing.expect(lateCount <= 12);
}

test "T-B12: fuzz, compare and startsWith agree with std.mem over random short byte strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b12.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    const alphabet = "ab\x00";

    var iteration: usize = 0;
    while (iteration < 500) : (iteration += 1) {
        const storedLength = random.intRangeLessThan(usize, 0, 9);
        const probeLength = random.intRangeLessThan(usize, 0, 9);
        var storedBuffer: [8]u8 = undefined;
        var probeBuffer: [8]u8 = undefined;
        for (storedBuffer[0..storedLength]) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, 3)];
        for (probeBuffer[0..probeLength]) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, 3)];
        const stored = storedBuffer[0..storedLength];
        const probe = probeBuffer[0..probeLength];

        const reference = try blob.put(&writeTransaction, stored);
        const order = try blob.compare(&writeTransaction, reference, probe);
        try testing.expectEqual(std.mem.order(u8, stored, probe), order);
        try testing.expectEqual(std.mem.startsWith(u8, stored, probe), try blob.startsWith(&writeTransaction, reference, probe));
        if (order == .eq) try testing.expectEqual(stored.len, probe.len);
    }
}

test "T-B13: a corrupt tag is error.Corrupt from both compare and startsWith" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try blobTestTmpPath(testing.allocator, &tmp, "b13.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    const reference = try blob.put(&writeTransaction, "hello");
    const offset: usize = @intCast(reference);
    database.store.map[offset] = 7;
    try testing.expectError(error.Corrupt, blob.compare(&writeTransaction, reference, "hello"));
    try testing.expectError(error.Corrupt, blob.startsWith(&writeTransaction, reference, "hello"));
}
