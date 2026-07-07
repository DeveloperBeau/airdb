const std = @import("std");
const verification = @import("../verification.zig");
const Io = std.Io;
const compaction = @import("compaction.zig");
const catalog = @import("../schema/catalog.zig");
const links = @import("../records/links.zig");
const typedir = @import("../schema/typeDirectory.zig");
const typeRouting = @import("../schema/typeRouting.zig");
const objects = @import("../records/objects.zig");
const rows = @import("../records/rows.zig");
const blob = @import("../records/blob.zig");
const liveCount = compaction.liveCount;
const shouldCompact = compaction.shouldCompact;
const compactType = compaction.compactType;
const compactStep = compaction.compactStep;
const copyTypeRows = compaction.copyTypeRows;
const rebuildBacklinks = compaction.rebuildBacklinks;
const compactToNewFile = compaction.compactToNewFile;
const compactInPlace = compaction.compactInPlace;

const testing = std.testing;

const Database = @import("../database.zig").Database;

const collections = @import("../records/collections.zig");

fn cmpTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "compactType packs live rows and drops dead ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "pack.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var primaryKey: u64 = 0;
    while (primaryKey < 10) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 10 });
        catalogRef = r.catalogRef;
    }

    for ([_]u64{ 2, 5, 8 }) |deletedPrimaryKey| {
        var out: [2]u64 = undefined;
        const ver = (try rows.getByPrimaryKey(&w, catalogRef, deletedPrimaryKey, &out)).?;
        catalogRef = switch (try rows.delete(&w, catalogRef, deletedPrimaryKey, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    catalogRef = try compactType(&w, catalogRef);

    try testing.expectEqual(@as(u64, 7), (try catalog.loadCatalog(&w, catalogRef)).next_row);
    try testing.expectEqual(@as(u64, 7), try liveCount(&w, catalogRef));

    primaryKey = 0;
    while (primaryKey < 10) : (primaryKey += 1) {
        var out: [2]u64 = undefined;
        const got = try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out);
        if (primaryKey == 2 or primaryKey == 5 or primaryKey == 8) {
            try testing.expect(got == null);
        } else {
            try testing.expect(got != null);
            try testing.expectEqual(primaryKey * 10, out[1]);
        }
    }
}

test "compactType frees the replaced column set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "packfree.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    // Commit a type with rows and holes so compaction has real work.
    {
        var w = try database.beginWrite();
        var catalogRef = try catalog.create(&w, 2);
        var primaryKey: u64 = 0;
        while (primaryKey < 100) : (primaryKey += 1) catalogRef = (try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 10 })).catalogRef;
        primaryKey = 0;
        while (primaryKey < 100) : (primaryKey += 5) {
            var out: [2]u64 = undefined;
            const ver = (try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
            catalogRef = (try rows.delete(&w, catalogRef, primaryKey, ver)).ok;
        }
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // A full compact must record the old committed columns and key->row index
    // as in-flight frees rather than leaving them as unreclaimable garbage.
    var w = try database.beginWrite();
    defer w.deinit();
    _ = try compactType(&w, w.new_root);
    try testing.expect(w.in_flight_frees.items.len > 0);
}

test "object keys and links survive compaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "links.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });

    const a = try objects.insertTyped(&w, catalogRef, &.{ .{ .int = 1 }, .{ .link = null } });
    catalogRef = a.catalogRef;
    const objectKeyA = a.row;
    const b = try objects.insertTyped(&w, catalogRef, &.{ .{ .int = 2 }, .{ .link = null } });
    catalogRef = b.catalogRef;
    const c = try objects.insertTyped(&w, catalogRef, &.{ .{ .int = 3 }, .{ .link = objectKeyA } });
    catalogRef = c.catalogRef;

    // delete B (primaryKey 2) -- creates a hole
    var out: [2]u64 = undefined;
    const ver = (try rows.getByPrimaryKey(&w, catalogRef, 2, &out)).?;
    catalogRef = switch (try rows.delete(&w, catalogRef, 2, ver)) {
        .ok => |x| x,
        else => unreachable,
    };

    catalogRef = try compactType(&w, catalogRef);

    // C still links to A by object key
    try testing.expectEqual(objectKeyA, (try links.getLink(&w, catalogRef, 3, 1)).?);
    // A is still resolvable by its object key
    var ao: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&w, catalogRef, objectKeyA, &ao)) != null);
    try testing.expectEqual(@as(u64, 1), ao[0]);
    // backlink from C -> A survived
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, catalogRef, 1, objectKeyA));
}

test "shouldCompact reflects dead ratio" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "ratio.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 1);
    var primaryKey: u64 = 0;
    while (primaryKey < 10) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{primaryKey});
        catalogRef = r.catalogRef;
    }
    try testing.expect(!(try shouldCompact(&w, catalogRef)));

    primaryKey = 0;
    while (primaryKey < 6) : (primaryKey += 1) {
        var out: [1]u64 = undefined;
        const ver = (try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
        catalogRef = switch (try rows.delete(&w, catalogRef, primaryKey, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }
    try testing.expect(try shouldCompact(&w, catalogRef));
}

test "compaction reclaims under churn (scale)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "scale.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    const n: u64 = 200_000;
    var catalogRef = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ i, i });
        catalogRef = r.catalogRef;
    }

    // delete every even primaryKey; all rows carry version == w.new_version this transaction
    i = 0;
    while (i < n) : (i += 2) {
        catalogRef = switch (try rows.delete(&w, catalogRef, i, w.new_version)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    catalogRef = try compactType(&w, catalogRef);

    try testing.expectEqual(@as(u64, 100_000), (try catalog.loadCatalog(&w, catalogRef)).next_row);
    try testing.expectEqual(@as(u64, 100_000), try liveCount(&w, catalogRef));

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByPrimaryKey(&w, catalogRef, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[1]);
    try testing.expect((try rows.getByPrimaryKey(&w, catalogRef, 99_999, &out)) != null);
    try testing.expectEqual(@as(u64, 99_999), out[1]);
    try testing.expect((try rows.getByPrimaryKey(&w, catalogRef, 100_001, &out)) != null);
    try testing.expectEqual(@as(u64, 100_001), out[1]);
    try testing.expect((try rows.getByPrimaryKey(&w, catalogRef, 2, &out)) == null);
}

test "all value kinds deep-copy across databases preserving keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "src.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "dst.airdb");
    defer testing.allocator.free(dst_path);

    var sourceDatabase = try Database.create(testing.allocator, src_path);
    defer sourceDatabase.deinit();
    var destinationDatabase = try Database.create(testing.allocator, dst_path);
    defer destinationDatabase.deinit();

    var primaryKey1ObjectKey: u64 = undefined;
    var src_next_key: u64 = undefined;

    // Build the source database: 3 rows across every value kind, then delete one.
    {
        var w = try sourceDatabase.beginWrite();
        var catalogRef = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .blob },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .link, .link_target = 0 },
        });
        const r1 = try objects.insertTyped(&w, catalogRef, &.{
            .{ .int = 1 }, .{ .bytes = "a" }, .{ .list_int = &.{ 10, 20 } }, .{ .set_int = &.{ 5, 6 } }, .{ .link = null },
        });
        catalogRef = r1.catalogRef;
        primaryKey1ObjectKey = r1.row;
        const r2 = try objects.insertTyped(&w, catalogRef, &.{
            .{ .int = 2 }, .{ .bytes = "bb" }, .{ .list_int = &.{} }, .{ .set_int = &.{7} }, .{ .link = primaryKey1ObjectKey },
        });
        catalogRef = r2.catalogRef;
        const r3 = try objects.insertTyped(&w, catalogRef, &.{
            .{ .int = 3 }, .{ .bytes = "ccc" }, .{ .list_int = &.{ 1, 2, 3 } }, .{ .set_int = &.{} }, .{ .link = null },
        });
        catalogRef = r3.catalogRef;

        // Delete primaryKey 3 -- leaves a gap in the source.
        var dout: [5]catalog.Value = undefined;
        const v3 = (try objects.getTyped(&w, catalogRef, 3, &dout)).?;
        catalogRef = (try objects.deleteTyped(&w, catalogRef, 3, v3)).ok;

        src_next_key = (try catalog.loadCatalog(&w, catalogRef)).next_key;
        w.setRoot(catalogRef);
        _ = try w.commit();
    }

    // Deep-copy the live rows into the destination database.
    {
        var src_read = try sourceDatabase.beginRead();
        const sourceCatalog = src_read.root();
        var dst_w = try destinationDatabase.beginWrite();
        var destinationCatalog = try copyTypeRows(&src_read, sourceCatalog, &dst_w);
        destinationCatalog = try rebuildBacklinks(&dst_w, destinationCatalog);
        dst_w.setRoot(destinationCatalog);
        _ = try dst_w.commit();
        src_read.end();
    }

    // Reopen the destination and verify every value kind round-tripped.
    {
        var reopenedDestination = try Database.open(testing.allocator, dst_path);
        defer reopenedDestination.deinit();
        var r = try reopenedDestination.beginRead();
        defer r.end();
        const catalogRef = r.root();

        // primaryKey 1 and primaryKey 2 readable with identical int + blob.
        var o1: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, catalogRef, 1, &o1)) != null);
        try testing.expectEqual(@as(u64, 1), o1[0].int);
        try testing.expectEqualStrings("a", o1[1].bytes);
        var o2: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, catalogRef, 2, &o2)) != null);
        try testing.expectEqual(@as(u64, 2), o2[0].int);
        try testing.expectEqualStrings("bb", o2[1].bytes);

        // list/set contents match.
        try testing.expectEqual(@as(?u64, 2), try collections.listLen(&r, catalogRef, 1, 2));
        try testing.expectEqual(@as(u64, 10), try collections.listGetInt(&r, catalogRef, 1, 2, 0));
        try testing.expectEqual(@as(u64, 20), try collections.listGetInt(&r, catalogRef, 1, 2, 1));
        try testing.expectEqual(@as(?u64, 2), try collections.setCountInt(&r, catalogRef, 1, 3));
        try testing.expect(try collections.setContainsInt(&r, catalogRef, 1, 3, 5));
        try testing.expect(try collections.setContainsInt(&r, catalogRef, 1, 3, 6));
        try testing.expectEqual(@as(?u64, 0), try collections.listLen(&r, catalogRef, 2, 2));
        try testing.expectEqual(@as(?u64, 1), try collections.setCountInt(&r, catalogRef, 2, 3));
        try testing.expect(try collections.setContainsInt(&r, catalogRef, 2, 3, 7));

        // The link on primaryKey 2 still equals primaryKey 1's original object key and resolves to primaryKey 1.
        try testing.expectEqual(@as(?u64, primaryKey1ObjectKey), try links.getLink(&r, catalogRef, 2, 4));
        var ob: [5]u64 = undefined;
        try testing.expect((try rows.getByObjectKey(&r, catalogRef, primaryKey1ObjectKey, &ob)) != null);
        try testing.expectEqual(@as(u64, 1), ob[0]);

        // Backlink rebuilt from the copied forward link.
        try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&r, catalogRef, 4, primaryKey1ObjectKey));

        // primaryKey 3 was dead in the source and must be absent.
        var o3: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, catalogRef, 3, &o3)) == null);

        // next_key preserved across the copy.
        try testing.expectEqual(src_next_key, (try catalog.loadCatalog(&r, catalogRef)).next_key);
    }
}

test "compactToNewFile produces a verified, smaller, equivalent file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "fullsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "fulldst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropertyDefinition;
    var authorObjectKeys: [300]u64 = undefined;

    // Build the source: two types, ~300 authors + ~300 books, delete ~100 books.
    {
        var database = try Database.create(testing.allocator, src_path);
        defer database.deinit();
        var w = try database.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author{int primaryKey, blob name}
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 }, .{ .kind = .set, .elem = .int } }, // 1: Book{int primaryKey, link author, set tags}
        };
        var dir = try typedir.createTypes(&w, &schema, &.{ false, false });

        var i: u64 = 0;
        var nbuf: [32]u8 = undefined;
        while (i < 300) : (i += 1) {
            const s = try std.fmt.bufPrint(&nbuf, "author-{d}", .{i});
            const r = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } });
            dir = r.dir;
            authorObjectKeys[@intCast(i)] = r.row;
        }
        i = 0;
        while (i < 300) : (i += 1) {
            const objectKeyA = authorObjectKeys[@intCast(i % 300)];
            const r = try typeRouting.insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = objectKeyA }, .{ .set_int = &.{ i, i + 1000 } } });
            dir = r.dir;
        }
        // Delete every third book (~100): primaryKeys 0,3,...,297.
        i = 0;
        while (i < 300) : (i += 3) {
            var out: [3]catalog.Value = undefined;
            const ver = (try typeRouting.get(&w, dir, 1, i, &out)).?;
            const dres = try typeRouting.deleteNullifyX(&w, dir, 1, i, ver);
            dir = dres.ok;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction (opens src, writes + verifies + commits dst).
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // The fresh file holds no garbage, so its live data footprint must be smaller
    // than the churned source's. Compare logical size (high-water of live bytes),
    // since the physical file length floors at the 1MB initial mmap for both.
    var src_size: u64 = undefined;
    var dst_size: u64 = undefined;
    {
        var reopenedSource = try Database.open(testing.allocator, src_path);
        src_size = reopenedSource.arena.top;
        reopenedSource.deinit();
        var reopenedDestination = try Database.open(testing.allocator, dst_path);
        dst_size = reopenedDestination.arena.top;
        reopenedDestination.deinit();
    }
    try testing.expect(dst_size < src_size);

    // The destination is published; verify equivalence on the live data.
    var reopenedDestination = try Database.open(testing.allocator, dst_path);
    defer reopenedDestination.deinit();
    var r = try reopenedDestination.beginRead();
    defer r.end();
    const dir = r.root();

    try testing.expectEqual(@as(u64, 300), try typeRouting.liveCount(&r, dir, 0));
    try testing.expectEqual(@as(u64, 200), try typeRouting.liveCount(&r, dir, 1));

    // A surviving author reads back with identical values.
    var ao: [2]catalog.Value = undefined;
    _ = (try typeRouting.get(&r, dir, 0, 42, &ao)).?;
    try testing.expectEqual(@as(u64, 42), ao[0].int);
    try testing.expectEqualStrings("author-42", ao[1].bytes);

    // A surviving book (primaryKey 1, not divisible by 3) keeps its author link, and the
    // link resolves to the same author object.
    var bo: [3]catalog.Value = undefined;
    _ = (try typeRouting.get(&r, dir, 1, 1, &bo)).?;
    try testing.expectEqual(@as(?u64, authorObjectKeys[1]), try typeRouting.getLink(&r, dir, 1, 1, 1));
    var la: [2]catalog.Value = undefined;
    _ = (try typeRouting.getLinked(&r, dir, 1, 1, 1, &la)).?;
    try testing.expectEqual(@as(u64, 1), la[0].int);

    // A deleted book (primaryKey 3) is absent.
    var b3: [3]catalog.Value = undefined;
    try testing.expectEqual(@as(?u64, null), try typeRouting.get(&r, dir, 1, 3, &b3));
}

test "compaction preserves dict and set-of-blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "bindexsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "bindexdst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropertyDefinition;

    // Build the source: a type with {int primaryKey, dict, set(elem=blob)}, two rows with
    // dict entries + blob-set members, then delete one row to leave a gap.
    {
        var database = try Database.create(testing.allocator, src_path);
        defer database.deinit();
        var w = try database.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .dict }, .{ .kind = .set, .elem = .blob } },
        };
        var dir = try typedir.createTypes(&w, &schema, &.{false});

        const r1 = try typeRouting.insert(&w, dir, 0, &.{
            .{ .int = 1 },
            .{ .dict_int = &.{ .{ .key = "a", .val = 1 }, .{ .key = "b", .val = 2 } } },
            .{ .set_blob = &.{ "x", "yy" } },
        });
        dir = r1.dir;
        const r2 = try typeRouting.insert(&w, dir, 0, &.{
            .{ .int = 2 },
            .{ .dict_int = &.{.{ .key = "c", .val = 3 }} },
            .{ .set_blob = &.{"zzz"} },
        });
        dir = r2.dir;

        // Delete primaryKey 2 -- leaves a gap in the source.
        var out: [3]catalog.Value = undefined;
        const ver = (try typeRouting.get(&w, dir, 0, 2, &out)).?;
        const dres = try typeRouting.deleteNullifyX(&w, dir, 0, 2, ver);
        dir = dres.ok;

        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction: opens src, deep-copies live rows, verifies, commits dst.
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // Reopen the destination and verify the surviving row's dict + blob-set survived.
    {
        var reopenedDestination = try Database.open(testing.allocator, dst_path);
        defer reopenedDestination.deinit();
        var r = try reopenedDestination.beginRead();
        defer r.end();
        const dir = r.root();
        const catalogRef = try typedir.catalogRef(&r, dir, 0);

        try testing.expectEqual(@as(u64, 1), try typeRouting.liveCount(&r, dir, 0));

        // Surviving row primaryKey 1: dict entries preserved.
        try testing.expectEqual(@as(?u64, 2), try collections.dictCount(&r, catalogRef, 1, 1));
        try testing.expectEqual(@as(?u64, 1), try collections.dictGet(&r, catalogRef, 1, 1, "a"));
        try testing.expectEqual(@as(?u64, 2), try collections.dictGet(&r, catalogRef, 1, 1, "b"));
        try testing.expectEqual(@as(?u64, null), try collections.dictGet(&r, catalogRef, 1, 1, "c"));

        // Surviving row primaryKey 1: blob-set members preserved.
        try testing.expectEqual(@as(?u64, 2), try collections.setCountBlob(&r, catalogRef, 1, 2));
        try testing.expect(try collections.setContainsBlob(&r, catalogRef, 1, 2, "x"));
        try testing.expect(try collections.setContainsBlob(&r, catalogRef, 1, 2, "yy"));
        try testing.expect(!(try collections.setContainsBlob(&r, catalogRef, 1, 2, "zzz")));

        // Deleted row primaryKey 2 is absent.
        var o2: [3]catalog.Value = undefined;
        try testing.expectEqual(@as(?u64, null), try typeRouting.get(&r, dir, 0, 2, &o2));
    }
}

test "compaction preserves a large (chunked) blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "bigblobsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "bigblobdst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropertyDefinition;

    // A blob well past the inline cap (section_size is 16 MiB) is stored chunked.
    const n: usize = 20 * 1024 * 1024;
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 251);

    // Build the source: a type {int primaryKey, blob}, one large blob and one small.
    {
        var database = try Database.create(testing.allocator, src_path);
        defer database.deinit();
        var w = try database.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } },
        };
        var dir = try typedir.createTypes(&w, &schema, &.{false});
        dir = (try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = big } })).dir;
        dir = (try typeRouting.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .bytes = "small" } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction: deep-copies live rows (incl. the chunked blob), verifies, commits.
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // Reopen the destination and verify both blobs survived.
    {
        var reopenedDestination = try Database.open(testing.allocator, dst_path);
        defer reopenedDestination.deinit();
        var r = try reopenedDestination.beginRead();
        defer r.end();
        const dir = r.root();

        // The large blob materializes byte-identical via its ref.
        var o1: [2]catalog.Value = undefined;
        try testing.expect((try typeRouting.get(&r, dir, 0, 1, &o1)) != null);
        try testing.expect(o1[1] == .blob_ref);
        const got = try blob.getAlloc(&r, o1[1].blob_ref, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, big, got);

        // The small blob still reads via a zero-copy slice.
        var o2: [2]catalog.Value = undefined;
        try testing.expect((try typeRouting.get(&r, dir, 0, 2, &o2)) != null);
        try testing.expect(o2[1] == .bytes);
        try testing.expectEqualStrings("small", o2[1].bytes);
    }
}

test "compactStep packs a delete-heavy type across several small steps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var objectKeys: [12]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 12) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 100 });
        catalogRef = r.catalogRef;
        objectKeys[@intCast(primaryKey)] = r.row;
    }

    const dels = [_]u64{ 0, 2, 3, 5, 7, 8, 11 };
    for (dels) |deletedPrimaryKey| {
        var out: [2]u64 = undefined;
        const ver = (try rows.getByPrimaryKey(&w, catalogRef, deletedPrimaryKey, &out)).?;
        catalogRef = switch (try rows.delete(&w, catalogRef, deletedPrimaryKey, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    // Pack in small budgeted steps until done.
    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&w, catalogRef, 0, 2);
        catalogRef = res.catalogRef;
        try testing.expect(res.moved <= 2);
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    // Fully packed: next_row == live count.
    try testing.expectEqual(try liveCount(&w, catalogRef), (try catalog.loadCatalog(&w, catalogRef)).next_row);

    // Every survivor reads back its exact values; deleted keys are gone.
    primaryKey = 0;
    while (primaryKey < 12) : (primaryKey += 1) {
        const is_del = blk: {
            for (dels) |d| if (d == primaryKey) break :blk true;
            break :blk false;
        };
        var out: [2]catalog.Value = undefined;
        const got = try objects.getTypedByObjectKey(&w, catalogRef, objectKeys[@intCast(primaryKey)], &out);
        if (is_del) {
            try testing.expect(got == null);
        } else {
            try testing.expect(got != null);
            try testing.expectEqual(primaryKey, out[0].int);
            try testing.expectEqual(primaryKey * 100, out[1].int);
        }
    }
}

test "compactStep on an all-dead type truncates to zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var primaryKey: u64 = 0;
    while (primaryKey < 6) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey });
        catalogRef = r.catalogRef;
    }
    primaryKey = 0;
    while (primaryKey < 6) : (primaryKey += 1) {
        var out: [2]u64 = undefined;
        const ver = (try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
        catalogRef = switch (try rows.delete(&w, catalogRef, primaryKey, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&w, catalogRef, 0, 2);
        catalogRef = res.catalogRef;
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    try testing.expectEqual(@as(u64, 0), (try catalog.loadCatalog(&w, catalogRef)).next_row);
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, catalogRef));
}

test "compactStep is a no-op on an already-packed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.create(&w, 2);
    var objectKeys: [5]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 5) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 7 });
        catalogRef = r.catalogRef;
        objectKeys[@intCast(primaryKey)] = r.row;
    }

    const res = try compactStep(&w, catalogRef, 0, 4);
    catalogRef = res.catalogRef;
    try testing.expect(res.done);
    try testing.expectEqual(@as(usize, 0), res.moved);

    primaryKey = 0;
    while (primaryKey < 5) : (primaryKey += 1) {
        var out: [2]catalog.Value = undefined;
        const got = try objects.getTypedByObjectKey(&w, catalogRef, objectKeys[@intCast(primaryKey)], &out);
        try testing.expect(got != null);
        try testing.expectEqual(primaryKey, out[0].int);
        try testing.expectEqual(primaryKey * 7, out[1].int);
    }
}

test "compactStep cursor path packs identically to the scan path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const step_path = try cmpTmpPath(testing.allocator, &tmp, "ident_step.airdb");
    defer testing.allocator.free(step_path);
    const ctrl_path = try cmpTmpPath(testing.allocator, &tmp, "ident_ctrl.airdb");
    defer testing.allocator.free(ctrl_path);

    // A scattered, delete-heavy pattern that strands live rows both below and
    // above the live-count boundary.
    const dels = [_]u64{ 0, 1, 4, 6, 7, 9, 12, 13, 15, 18, 19 };
    const isDel = struct {
        fn f(primaryKey: u64) bool {
            for (dels) |d| if (d == primaryKey) return true;
            return false;
        }
    }.f;

    // Build the SAME data in two databases.
    var stepDatabase = try Database.create(testing.allocator, step_path);
    defer stepDatabase.deinit();
    var controlDatabase = try Database.create(testing.allocator, ctrl_path);
    defer controlDatabase.deinit();

    var step_w = try stepDatabase.beginWrite();
    defer step_w.deinit();
    var ctrl_w = try controlDatabase.beginWrite();
    defer ctrl_w.deinit();

    var stepCatalog = try catalog.create(&step_w, 2);
    var controlCatalog = try catalog.create(&ctrl_w, 2);
    var stepObjectKeys: [20]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 20) : (primaryKey += 1) {
        const rs = try rows.insert(&step_w, stepCatalog, &.{ primaryKey, primaryKey * 100 });
        stepCatalog = rs.catalogRef;
        stepObjectKeys[@intCast(primaryKey)] = rs.row;
        const rc = try rows.insert(&ctrl_w, controlCatalog, &.{ primaryKey, primaryKey * 100 });
        controlCatalog = rc.catalogRef;
    }
    for (dels) |deletedPrimaryKey| {
        var out: [2]u64 = undefined;
        const vs = (try rows.getByPrimaryKey(&step_w, stepCatalog, deletedPrimaryKey, &out)).?;
        stepCatalog = (try rows.delete(&step_w, stepCatalog, deletedPrimaryKey, vs)).ok;
        const vc = (try rows.getByPrimaryKey(&ctrl_w, controlCatalog, deletedPrimaryKey, &out)).?;
        controlCatalog = (try rows.delete(&ctrl_w, controlCatalog, deletedPrimaryKey, vc)).ok;
    }

    // Control: one full-pass compaction.
    controlCatalog = try compactType(&ctrl_w, controlCatalog);

    // Step path: budgeted cursor steps until done.
    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&step_w, stepCatalog, 0, 3);
        stepCatalog = res.catalogRef;
        try testing.expect(res.moved <= 3);
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    // Both fully packed to the same dense length.
    const step_len = (try catalog.loadCatalog(&step_w, stepCatalog)).next_row;
    try testing.expectEqual(try liveCount(&step_w, stepCatalog), step_len);
    try testing.expectEqual((try catalog.loadCatalog(&ctrl_w, controlCatalog)).next_row, step_len);
    try testing.expectEqual(try liveCount(&ctrl_w, controlCatalog), try liveCount(&step_w, stepCatalog));

    // Every survivor reads its exact values via its stable object key in the
    // stepped database; deleted keys are gone. Cross-check primaryKey presence vs the control.
    primaryKey = 0;
    while (primaryKey < 20) : (primaryKey += 1) {
        var so: [2]catalog.Value = undefined;
        const sg = try objects.getTypedByObjectKey(&step_w, stepCatalog, stepObjectKeys[@intCast(primaryKey)], &so);
        var co: [2]u64 = undefined;
        const cg = try rows.getByPrimaryKey(&ctrl_w, controlCatalog, primaryKey, &co);
        if (isDel(primaryKey)) {
            try testing.expect(sg == null);
            try testing.expect(cg == null);
        } else {
            try testing.expect(sg != null);
            try testing.expect(cg != null);
            try testing.expectEqual(primaryKey, so[0].int);
            try testing.expectEqual(primaryKey * 100, so[1].int);
            // Same primary key reads back in the control (survivor sets match).
            var sp: [2]u64 = undefined;
            try testing.expect((try rows.getByPrimaryKey(&step_w, stepCatalog, primaryKey, &sp)) != null);
            try testing.expectEqual(primaryKey * 100, sp[1]);
        }
    }
}

test "compactStep truncation never drops a live row at the top" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "trunc_top.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    // Insert 10 rows at physical 0..9, then delete the LOW primaryKeys (0..4). The five
    // survivors (primaryKeys 5..9) all sit at physical rows >= live_count (=5): every
    // live row is a "high" row that must be relocated downward before truncation.
    var catalogRef = try catalog.create(&w, 2);
    var objectKeys: [10]u64 = undefined;
    var primaryKey: u64 = 0;
    while (primaryKey < 10) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey * 1000 });
        catalogRef = r.catalogRef;
        objectKeys[@intCast(primaryKey)] = r.row;
    }
    primaryKey = 0;
    while (primaryKey < 5) : (primaryKey += 1) {
        var out: [2]u64 = undefined;
        const ver = (try rows.getByPrimaryKey(&w, catalogRef, primaryKey, &out)).?;
        catalogRef = (try rows.delete(&w, catalogRef, primaryKey, ver)).ok;
    }
    try testing.expectEqual(@as(u64, 5), try liveCount(&w, catalogRef));

    // Pack in tiny steps; the downward cursor must examine the entire top range.
    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&w, catalogRef, 0, 2);
        catalogRef = res.catalogRef;
        try testing.expect(res.moved <= 2);
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    try testing.expectEqual(@as(u64, 5), (try catalog.loadCatalog(&w, catalogRef)).next_row);
    // Every top-stranded survivor is intact with its exact values.
    primaryKey = 5;
    while (primaryKey < 10) : (primaryKey += 1) {
        var out: [2]catalog.Value = undefined;
        const got = try objects.getTypedByObjectKey(&w, catalogRef, objectKeys[@intCast(primaryKey)], &out);
        try testing.expect(got != null);
        try testing.expectEqual(primaryKey, out[0].int);
        try testing.expectEqual(primaryKey * 1000, out[1].int);
    }
}

test "compactStep moves at most budget rows per call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "budget.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    // A large set with heavy churn so many high rows need relocating.
    const n: u64 = 400;
    var catalogRef = try catalog.create(&w, 2);
    var primaryKey: u64 = 0;
    while (primaryKey < n) : (primaryKey += 1) {
        const r = try rows.insert(&w, catalogRef, &.{ primaryKey, primaryKey });
        catalogRef = r.catalogRef;
    }
    // Delete every even primaryKey -> ~200 holes scattered through the low half.
    primaryKey = 0;
    while (primaryKey < n) : (primaryKey += 2) {
        catalogRef = switch (try rows.delete(&w, catalogRef, primaryKey, w.new_version)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    const budget: usize = 7;
    var guard: usize = 0;
    var saw_full_budget = false;
    while (true) {
        const res = try compactStep(&w, catalogRef, 0, budget);
        catalogRef = res.catalogRef;
        try testing.expect(res.moved <= budget);
        if (res.moved == budget) saw_full_budget = true;
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 1000);
    }
    // The set is large enough that at least one step hit the cap.
    try testing.expect(saw_full_budget);
    try testing.expectEqual(try liveCount(&w, catalogRef), (try catalog.loadCatalog(&w, catalogRef)).next_row);
}

test "compactInPlace preserves value indexes and passes verifyIntegrity" {
    // Regression: the full-file copy created value indexes empty and nothing
    // repopulated them, so routine maintenance silently emptied every indexed
    // query and produced a file the integrity checker itself called corrupt.
    const query = @import("../query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "inplace_vidx.airdb");
    defer testing.allocator.free(path);

    {
        var database = try Database.create(testing.allocator, path);
        var w = try database.beginWrite();
        var dir = try typedir.createTypes(&w, &.{
            &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } },
        }, &.{false});
        var primaryKey: u64 = 0;
        while (primaryKey < 50) : (primaryKey += 1) {
            dir = (try typeRouting.insert(&w, dir, 0, &.{ .{ .int = primaryKey }, .{ .int = primaryKey % 5 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
        database.deinit();
    }

    try compactInPlace(testing.allocator, path);

    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try verification.verifyIntegrity(&database); // the audit must agree the indexes are intact
    var r = try database.beginRead();
    defer r.end();
    const catalogRef = try typedir.catalogRef(&r, r.root(), 0);
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&r, catalogRef, &.{.{ .property = 1, .op = .eq, .value = 3 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 10), hits.items.len);
}

test "compactInPlace shrinks and preserves data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "inplace.airdb");
    defer testing.allocator.free(path);

    const PD = catalog.PropertyDefinition;

    // Build a churned database (two types) at `path`, then CLOSE it so no handle
    // remains while compactInPlace replaces the file. Capture the logical size
    // (arena high-water) before closing to compare against the compacted file.
    var pre_top: u64 = undefined;
    var authorObjectKeys: [200]u64 = undefined;
    {
        var database = try Database.create(testing.allocator, path);
        var w = try database.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author{int primaryKey, blob name}
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book{int primaryKey, link author}
        };
        var dir = try typedir.createTypes(&w, &schema, &.{ false, false });

        var i: u64 = 0;
        var nbuf: [32]u8 = undefined;
        while (i < 200) : (i += 1) {
            const s = try std.fmt.bufPrint(&nbuf, "author-{d}", .{i});
            const r = try typeRouting.insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } });
            dir = r.dir;
            authorObjectKeys[@intCast(i)] = r.row;
        }
        i = 0;
        while (i < 200) : (i += 1) {
            const r = try typeRouting.insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = authorObjectKeys[@intCast(i)] } });
            dir = r.dir;
        }
        // Churn: delete every even-primaryKey book (~100 holes).
        i = 0;
        while (i < 200) : (i += 2) {
            var out: [2]catalog.Value = undefined;
            const ver = (try typeRouting.get(&w, dir, 1, i, &out)).?;
            const dres = try typeRouting.deleteNullifyX(&w, dir, 1, i, ver);
            dir = dres.ok;
        }
        w.setRoot(dir);
        _ = try w.commit();

        pre_top = database.arena.top;
        database.deinit();
    }

    // Compact in place over the SAME path.
    try compactInPlace(testing.allocator, path);

    // The ".compacting" temp data file must have been renamed away.
    {
        const temp_data = try std.fmt.allocPrint(testing.allocator, "{s}.compacting", .{path});
        defer testing.allocator.free(temp_data);
        const io = std.Io.Threaded.global_single_threaded.io();
        try testing.expectError(error.FileNotFound, Io.Dir.openFileAbsolute(io, temp_data, .{}));
    }

    // Reopen the SAME path and verify the live data survived intact.
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();

    // The compacted file's logical footprint must not exceed the churned source's.
    try testing.expect(database.arena.top <= pre_top);

    var r = try database.beginRead();
    defer r.end();
    const dir = r.root();

    // All 200 authors survive; only the 100 odd-primaryKey books remain.
    try testing.expectEqual(@as(u64, 200), try typeRouting.liveCount(&r, dir, 0));
    try testing.expectEqual(@as(u64, 100), try typeRouting.liveCount(&r, dir, 1));

    // A surviving author reads back identically.
    var ao: [2]catalog.Value = undefined;
    _ = (try typeRouting.get(&r, dir, 0, 137, &ao)).?;
    try testing.expectEqual(@as(u64, 137), ao[0].int);
    try testing.expectEqualStrings("author-137", ao[1].bytes);

    // A surviving (odd-primaryKey) book keeps its author link, resolving to the same author.
    var bo: [2]catalog.Value = undefined;
    _ = (try typeRouting.get(&r, dir, 1, 137, &bo)).?;
    try testing.expectEqual(@as(?u64, authorObjectKeys[137]), try typeRouting.getLink(&r, dir, 1, 137, 1));
    var la: [2]catalog.Value = undefined;
    _ = (try typeRouting.getLinked(&r, dir, 1, 137, 1, &la)).?;
    try testing.expectEqual(@as(u64, 137), la[0].int);

    // A deleted (even-primaryKey) book is absent.
    var b2: [2]catalog.Value = undefined;
    try testing.expectEqual(@as(?u64, null), try typeRouting.get(&r, dir, 1, 42, &b2));
}
