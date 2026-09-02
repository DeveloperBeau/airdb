//! Behaviour suite for query/include.zig: materializePage end to end, against
//! fixture D (books/authors/publishers) and fixture R (fixture D plus a
//! relocated author).
//!
//! Every expected value in this file is written out by hand from the
//! fixture's own construction, never read back from the code under test.
//! Every count bound is a literal derived from the fixture's sizes and the
//! node capacities in indexNode.zig, never from a measurement of this code.

const std = @import("std");
const testing = std.testing;
const database = @import("database.zig");
const Database = database.Database;
const WriteTransaction = database.WriteTransaction;
const Reference = @import("storage/reference.zig").Reference;
const catalog = @import("schema/catalog.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const relocation = @import("storage/relocation.zig");
const rows = @import("records/rows.zig");
const links = @import("records/links.zig");
const Column = @import("trees/column.zig");
const include = @import("query/include.zig");
const materialized = @import("query/materialized.zig");
const query = @import("query.zig");

const materializePage = include.materializePage;
const Relations = materialized.Relations;
const RelationTarget = materialized.RelationTarget;
const PropertyValue = materialized.PropertyValue;
const MaterializedObject = materialized.MaterializedObject;
const Predicate = query.Predicate;
const Operator = query.Operator;
const Request = query.Request;

fn qiTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

fn intComparison(property: usize, operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = property, .operator = operator, .value = .{ .int = value } } };
}

// ---------------------------------------------------------------------------
// Fixture D: Book (0) -> Author (1, self-referential) -> Publisher (2, unused).
// ---------------------------------------------------------------------------

const bookType: u16 = 0;
const authorType: u16 = 1;
const publisherType: u16 = 2;
const authorLinkProperty: usize = 1; // Book.author
const mentorProperty: usize = 1; // Author.mentor

const authorCount = 4;
const bookCount = 6;

const authorBirthYears = [authorCount]u64{ 1900, 1910, 1920, 1930 };
// Index into authorKeys, or null. Author 3's mentor is author 2 and author
// 2's is author 3: the two-cycle (R15).
const authorMentorIndex = [authorCount]?usize{ null, 0, 3, 2 };

const bookYears = [bookCount]u64{ 2001, 2002, 2003, 2004, 2005, 2006 };
const bookTitles = [bookCount][]const u8{ "Book 0", "Book 1", "Book 2", "Book 3", "Book 4", "Book 5" };
// Index into authorKeys, or null. Books 1 and 2 share author 1 (R19); book 5
// is unattributed (R18).
const bookAuthorIndex = [bookCount]?usize{ 0, 1, 1, 2, 3, null };

const IncludeFixture = struct {
    directoryReference: Reference,
    authorKeys: [authorCount]u64,
    bookKeys: [bookCount]u64,
};

fn buildIncludeFixture(writeTransaction: *WriteTransaction) !IncludeFixture {
    const bookDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = authorType },
        .{ .kind = .int },
        .{ .kind = .blob },
    };
    const authorDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = authorType },
        .{ .kind = .int },
    };
    const publisherDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .int },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(writeTransaction, &.{ &bookDefinitions, &authorDefinitions, &publisherDefinitions });

    // Authors first, so their object keys are pinned to 0..3 before any book
    // exists (6.2 of the spec).
    var authorKeys: [authorCount]u64 = undefined;
    var authorIndex: usize = 0;
    while (authorIndex < authorCount) : (authorIndex += 1) {
        const inserted = try typeRouting.insert(writeTransaction, directoryReference, authorType, &.{
            .{ .int = @intCast(authorIndex) },
            .{ .link = null },
            .{ .int = authorBirthYears[authorIndex] },
        });
        directoryReference = inserted.directoryReference;
        try testing.expectEqual(@as(u64, authorIndex), inserted.objectKey);
        authorKeys[authorIndex] = inserted.objectKey;
    }
    // Wire mentors now that every author's key is known.
    authorIndex = 0;
    while (authorIndex < authorCount) : (authorIndex += 1) {
        if (authorMentorIndex[authorIndex]) |targetIndex| {
            directoryReference = try typeRouting.setLink(writeTransaction, directoryReference, authorType, @intCast(authorIndex), mentorProperty, authorKeys[targetIndex]);
        }
    }

    var bookKeys: [bookCount]u64 = undefined;
    var bookIndex: usize = 0;
    while (bookIndex < bookCount) : (bookIndex += 1) {
        const authorTarget: ?u64 = if (bookAuthorIndex[bookIndex]) |authorIdx| authorKeys[authorIdx] else null;
        const inserted = try typeRouting.insert(writeTransaction, directoryReference, bookType, &.{
            .{ .int = @intCast(bookIndex) },
            .{ .link = authorTarget },
            .{ .int = bookYears[bookIndex] },
            .{ .bytes = bookTitles[bookIndex] },
        });
        directoryReference = inserted.directoryReference;
        try testing.expectEqual(@as(u64, bookIndex), inserted.objectKey);
        bookKeys[bookIndex] = inserted.objectKey;
    }

    return .{ .directoryReference = directoryReference, .authorKeys = authorKeys, .bookKeys = bookKeys };
}

fn expectObject(target: RelationTarget) *const MaterializedObject {
    return switch (target) {
        .object => |object| object,
        else => {
            std.debug.print("expected .object, found {any}\n", .{target});
            unreachable;
        },
    };
}

// ---------------------------------------------------------------------------
// R9-R12: flat fetch, the link decode, objectKey-vs-row, and lifetime.
// ---------------------------------------------------------------------------

test "R9: flat fetch at depth 0 exposes every root's raw link, with an empty included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi9.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{},
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 0 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, bookCount), roots.len);
    for (roots, 0..) |root, index| {
        try testing.expectEqual(fixture.bookKeys[index], root.objectKey);
        try testing.expectEqual(bookType, root.typeId);
        try testing.expectEqual(@as(usize, 4), root.values.len);
        try testing.expectEqual(PropertyValue{ .int = @intCast(index) }, root.values[0]);
        switch (root.values[3]) {
            .blobReference => {},
            else => try testing.expect(false),
        }
        try testing.expectEqual(@as(usize, 0), root.included.len);
    }
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[0] }, roots[0].values[authorLinkProperty]);
    try testing.expectEqual(PropertyValue{ .link = null }, roots[5].values[authorLinkProperty]);
}

test "R10: the link decode, a same-index target, and a null link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi10.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{},
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 0 },
        resultArena.allocator(),
    );

    // Book 3 links to author 2: a dropped `- 1` would turn this into 3.
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[2] }, roots[3].values[authorLinkProperty]);
    // Book 0 links to author 0: a dropped `- 1` turns this into 1.
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[0] }, roots[0].values[authorLinkProperty]);
    // Book 5's link is unset: a dropped null check underflows or returns maxInt.
    try testing.expectEqual(PropertyValue{ .link = null }, roots[5].values[authorLinkProperty]);
}

test "R11: objectKey is not row, a relocated target resolves through its physical row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi11.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);
    var directoryReference = fixture.directoryReference;

    // Author 2's version, hand-carried from before relocation ever touches it
    // (spec 6.6, R11: the materialized author's version must be the version
    // author 2 actually had, not whatever the abandoned slot's corrupted
    // version cell holds).
    var preRelocationValues: [3]u64 = undefined;
    const authorTwoVersionBeforeRelocation = (try rows.getByObjectKey(
        &writeTransaction,
        try typeDirectory.catalogReference(&writeTransaction, directoryReference, authorType),
        fixture.authorKeys[2],
        &preRelocationValues,
    )).?;

    // Open a dead slot: insert a throwaway author, then delete it (the recipe
    // in queryTests.zig, "query returns stable object keys after relocation").
    const throwaway = try typeRouting.insert(&writeTransaction, directoryReference, authorType, &.{ .{ .int = 99 }, .{ .link = null }, .{ .int = 0 } });
    directoryReference = throwaway.directoryReference;
    var authorCatalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, authorType);
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, authorCatalogReference, throwaway.objectKey)).?;
    var valuesOutBuffer: [3]u64 = undefined;
    const throwawayVersion = (try rows.getByPrimaryKey(&writeTransaction, authorCatalogReference, 99, &valuesOutBuffer)).?;
    const deleteResult = try typeRouting.delete(&writeTransaction, directoryReference, authorType, 99, throwawayVersion);
    directoryReference = switch (deleteResult) {
        .ok => |newDirectory| newDirectory,
        else => unreachable,
    };

    // Relocate author 2 into the freed slot.
    authorCatalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, authorType);
    const newAuthorCatalog = try relocation.relocateRow(&writeTransaction, authorCatalogReference, fixture.authorKeys[2], deadRow);
    directoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, authorType, newAuthorCatalog);

    // The divergence must actually have happened, or this test is vacuous.
    try testing.expect((try catalog.objectKeyToRow(&writeTransaction, newAuthorCatalog, fixture.authorKeys[2])).? != fixture.authorKeys[2]);

    // Corrupt the abandoned slot: relocateRow only clears the live bit and
    // leaves an identical readable copy there (storage/relocation.zig:30-31),
    // so a row/objectKey transposition would still read the right answer by
    // coincidence. This corruption is what makes the test load-bearing and
    // never redundant: without it, a transposed read passes silently.
    const abandonedRow = fixture.authorKeys[2];
    var authorSnapshot = try catalog.CatalogSnapshot.load(&writeTransaction, newAuthorCatalog);
    authorSnapshot.properties[2].column = try Column.set(&writeTransaction, authorSnapshot.properties[2].column, abandonedRow, 0xDEAD_BEEF);
    authorSnapshot.versionColumnReference = try Column.set(&writeTransaction, authorSnapshot.versionColumnReference, abandonedRow, 0xDEAD_BEEF);
    const corruptedAuthorCatalog = try authorSnapshot.replace(&writeTransaction);
    directoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, authorType, corruptedAuthorCatalog);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const bookLinkingToAuthor2 = 3; // bookAuthorIndex[3] == 2
    const roots = try materializePage(
        &writeTransaction,
        directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, bookLinkingToAuthor2) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    const authorObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(fixture.authorKeys[2], authorObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = authorBirthYears[2] }, authorObject.values[2]);
    // A transposed read would return the abandoned slot's corrupted version,
    // 0xDEAD_BEEF, in place of author 2's real one.
    try testing.expectEqual(authorTwoVersionBeforeRelocation, authorObject.version);
}

test "R12: identity and plain values survive the producing transaction's end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi12.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    const fixture = try buildIncludeFixture(&writeTransaction);
    _ = try writeTransaction.commit();

    var readTransaction = try testDatabase.beginRead();
    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &readTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 1) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    const authorObject = expectObject(roots[0].included[0].target);

    readTransaction.end();

    // Rule 2.2.3: typeId, objectKey, version, .int and .link stay meaningful
    // after end(). .blobReference is deliberately NOT read here: rule 2.2.4
    // says it means nothing after end(), and this is why it is skipped.
    try testing.expectEqual(fixture.bookKeys[1], roots[0].objectKey);
    try testing.expectEqual(PropertyValue{ .int = 1 }, roots[0].values[0]);
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[1] }, roots[0].values[authorLinkProperty]);
    try testing.expectEqual(fixture.authorKeys[1], authorObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 1 }, authorObject.values[0]);
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[0] }, authorObject.values[mentorProperty]);
}

// ---------------------------------------------------------------------------
// R13-R19b: depth, boundary, cycle and sharing.
// ---------------------------------------------------------------------------

test "R13: depth 1 resolves the root's link; the resolved object's own link stays a bare key at the bound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi13.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 1) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    try testing.expectEqual(authorLinkProperty, roots[0].included[0].property);
    const authorObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(fixture.authorKeys[1], authorObject.objectKey);
    try testing.expectEqual(authorType, authorObject.typeId);
    try testing.expectEqual(@as(usize, 0), authorObject.included.len);
    try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[0] }, authorObject.values[mentorProperty]);
}

test "R14: depth 2 resolves one level past the bound, and the second object sits at the new bound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi14.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 1) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 2 },
        resultArena.allocator(),
    );

    const authorObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(@as(usize, 1), authorObject.included.len);
    const mentorObject = expectObject(authorObject.included[0].target);
    try testing.expectEqual(fixture.authorKeys[0], mentorObject.objectKey);
    try testing.expectEqual(@as(usize, 0), mentorObject.included.len);
}

test "R15: a two-cycle inside the bound terminates with a back edge, not a second copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi15.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 3) }, // book 3 -> author 2 -> author 3 -> author 2
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 3 },
        resultArena.allocator(),
    );

    const author2 = expectObject(roots[0].included[0].target);
    try testing.expectEqual(fixture.authorKeys[2], author2.objectKey);
    const author3 = expectObject(author2.included[0].target);
    try testing.expectEqual(fixture.authorKeys[3], author3.objectKey);
    switch (author3.included[0].target) {
        .key => |key| try testing.expectEqual(fixture.authorKeys[2], key),
        else => try testing.expect(false),
    }
}

test "R16: a self-link terminates as a back edge to the same object, never a second copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi16.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();

    // An isolated two-type schema (a self-link on one author is enough): kept
    // separate from fixture D so R9's "six roots" and R13-R19's specific keys
    // are not disturbed by an extra book/author pair.
    const bookDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = authorType } };
    const authorDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = authorType } };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{ &bookDefinitions, &authorDefinitions });
    const insertedAuthor = try typeRouting.insert(&writeTransaction, directoryReference, authorType, &.{ .{ .int = 0 }, .{ .link = null } });
    directoryReference = insertedAuthor.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedAuthor.objectKey);
    directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, authorType, 0, mentorProperty, insertedAuthor.objectKey);
    const insertedBook = try typeRouting.insert(&writeTransaction, directoryReference, bookType, &.{ .{ .int = 0 }, .{ .link = insertedAuthor.objectKey } });
    directoryReference = insertedBook.directoryReference;

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        directoryReference,
        bookType,
        .{},
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 3 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    const authorObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(insertedAuthor.objectKey, authorObject.objectKey);
    switch (authorObject.included[0].target) {
        .key => |key| try testing.expectEqual(insertedAuthor.objectKey, key),
        else => try testing.expect(false),
    }
}

test "R17: an un-included relation stays a bare key in values, and an empty root list stops the walk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi17.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    inline for (.{ 1, 2 }) |depth| {
        var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
        defer resultArena.deinit();
        const roots = try materializePage(
            &writeTransaction,
            fixture.directoryReference,
            bookType,
            .{},
            .{ .linkProperties = &.{}, .depth = depth },
            resultArena.allocator(),
        );
        try testing.expectEqual(@as(usize, bookCount), roots.len);
        for (roots, 0..) |root, index| {
            try testing.expectEqual(@as(usize, 0), root.included.len);
            const expectedLink: ?u64 = if (bookAuthorIndex[index]) |authorIndex| fixture.authorKeys[authorIndex] else null;
            try testing.expectEqual(PropertyValue{ .link = expectedLink }, root.values[authorLinkProperty]);
        }
    }
}

test "R18: a null link inside an included property resolves to absent, not an object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi18.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{},
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots[5].included.len);
    try testing.expectEqual(authorLinkProperty, roots[5].included[0].property);
    switch (roots[5].included[0].target) {
        .absent => {},
        else => try testing.expect(false),
    }
    // Every other root's target is the object it should be: book 5 alone is absent.
    for (roots, 0..) |root, index| {
        if (index == 5) continue;
        _ = expectObject(root.included[0].target);
    }
}

test "R19: two parents linking to one target share one object by pointer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi19.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{},
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    const book1Author = expectObject(roots[1].included[0].target);
    const book2Author = expectObject(roots[2].included[0].target);
    try testing.expectEqual(book1Author, book2Author);
}

test "R19b: a target that is also a root is a back edge, never a second object" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi19b.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        authorType,
        .{},
        .{ .linkProperties = &.{mentorProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, authorCount), roots.len);
    // Author 1's mentor is author 0, itself a root: a back edge, not an object.
    switch (roots[1].included[0].target) {
        .key => |key| try testing.expectEqual(fixture.authorKeys[0], key),
        else => try testing.expect(false),
    }
    // No target across the whole page ever resolves to `.object`: every
    // mentor is either unset or already a root.
    for (roots) |root| {
        for (root.included) |relation| {
            switch (relation.target) {
                .object => try testing.expect(false),
                .absent, .key => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// R30-R31: spec edge case 8, a target that stays .key rather than failing
// the fetch.
// ---------------------------------------------------------------------------

test "R30: a link to a key nobody ever inserted stays .key, the fetch does not fail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi30.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);
    var directoryReference = fixture.directoryReference;

    // links.setLink never checks that its target exists, so an ordinary
    // caller can point a link at a key nobody ever inserted (spec 4, edge
    // case 8, first half). Book 5's author link is unset (bookAuthorIndex[5]
    // == null); repoint it at a key that was never allocated in this fixture.
    const neverInsertedAuthorKey: u64 = 999;
    directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, bookType, 5, authorLinkProperty, neverInsertedAuthorKey);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 5) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(fixture.bookKeys[5], roots[0].objectKey);
    // The root fetched normally: its own values are intact.
    try testing.expectEqual(PropertyValue{ .int = 5 }, roots[0].values[0]);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    switch (roots[0].included[0].target) {
        .key => |key| try testing.expectEqual(neverInsertedAuthorKey, key),
        else => try testing.expect(false),
    }
}

test "R31: a tombstoned target with a stale index entry stays .key, the fetch does not fail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi31.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);
    var directoryReference = fixture.directoryReference;

    // rows.delete always tombstones a row and removes its key-to-row index
    // entry in the same step, so a live tombstone with a still-resolving
    // index entry cannot arise through any exposed write path. Build one by
    // hand to exercise the guard anyway (spec 4, edge case 8, second half):
    // insert a fifth author, link book 5 to it, then tombstone its row
    // directly without touching the index, leaving the index entry stale.
    const extraAuthor = try typeRouting.insert(&writeTransaction, directoryReference, authorType, &.{ .{ .int = 50 }, .{ .link = null }, .{ .int = 1950 } });
    directoryReference = extraAuthor.directoryReference;
    directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, bookType, 5, authorLinkProperty, extraAuthor.objectKey);

    var authorCatalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, authorType);
    const extraAuthorRow = (try catalog.objectKeyToRow(&writeTransaction, authorCatalogReference, extraAuthor.objectKey)).?;
    var authorSnapshot = try catalog.CatalogSnapshot.load(&writeTransaction, authorCatalogReference);
    authorSnapshot.liveColumnReference = try Column.set(&writeTransaction, authorSnapshot.liveColumnReference, extraAuthorRow, 0);
    authorCatalogReference = try authorSnapshot.replace(&writeTransaction);
    directoryReference = try typeDirectory.setCatalogReference(&writeTransaction, directoryReference, authorType, authorCatalogReference);

    // The corruption must actually have happened: the index still resolves
    // the key, but the row it names is now dead, or this test is vacuous.
    try testing.expectEqual(@as(?u64, extraAuthorRow), try catalog.objectKeyToRow(&writeTransaction, authorCatalogReference, extraAuthor.objectKey));

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        directoryReference,
        bookType,
        .{ .predicate = intComparison(0, .eq, 5) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(fixture.bookKeys[5], roots[0].objectKey);
    try testing.expectEqual(PropertyValue{ .int = 5 }, roots[0].values[0]);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    switch (roots[0].included[0].target) {
        .key => |key| try testing.expectEqual(extraAuthor.objectKey, key),
        else => try testing.expect(false),
    }
}

// ---------------------------------------------------------------------------
// R24-R27: composition with paging/predicate, error surface, and empty results.
// ---------------------------------------------------------------------------

test "R24: paging composes with materialization, ascending and descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi24.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    {
        var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
        defer resultArena.deinit();
        const roots = try materializePage(
            &writeTransaction,
            fixture.directoryReference,
            bookType,
            .{ .page = .{ .limit = 2 } },
            .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
            resultArena.allocator(),
        );
        try testing.expectEqual(@as(usize, 2), roots.len);
        try testing.expectEqual(fixture.bookKeys[0], roots[0].objectKey);
        try testing.expectEqual(fixture.bookKeys[1], roots[1].objectKey);
        try testing.expectEqual(@as(usize, 1), roots[0].included.len);
        try testing.expectEqual(@as(usize, 1), roots[1].included.len);
    }
    {
        var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
        defer resultArena.deinit();
        const roots = try materializePage(
            &writeTransaction,
            fixture.directoryReference,
            bookType,
            .{ .page = .{ .limit = 2 }, .ordering = .{ .order = .descending } },
            .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
            resultArena.allocator(),
        );
        try testing.expectEqual(@as(usize, 2), roots.len);
        try testing.expectEqual(fixture.bookKeys[5], roots[0].objectKey);
        try testing.expectEqual(fixture.bookKeys[4], roots[1].objectKey);

        // The batch resolver works in ASCENDING sorted-key order (book 4
        // before book 5), while this page is DESCENDING (book 5 before book
        // 4): the two orders disagree here, which is exactly the case a
        // page-order/sorted-order transposition in the row scatter would get
        // wrong. Pin `values`, not just `objectKey`, on both roots, by hand
        // from the fixture's own construction (property 0 is the primary
        // key, property 2 is the year).
        try testing.expectEqual(PropertyValue{ .int = fixture.bookKeys[5] }, roots[0].values[0]);
        try testing.expectEqual(PropertyValue{ .int = bookYears[5] }, roots[0].values[2]);
        try testing.expectEqual(PropertyValue{ .link = null }, roots[0].values[1]);
        try testing.expectEqual(PropertyValue{ .int = fixture.bookKeys[4] }, roots[1].values[0]);
        try testing.expectEqual(PropertyValue{ .int = bookYears[4] }, roots[1].values[2]);
        try testing.expectEqual(PropertyValue{ .link = fixture.authorKeys[3] }, roots[1].values[1]);
    }
}

test "R25: a predicate composes with materialization" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi25.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(2, .eq, bookYears[3]) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(fixture.bookKeys[3], roots[0].objectKey);
}

test "R26: a typeId outside the directory is error.NoSuchType" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi26a.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    try testing.expectError(error.NoSuchType, materializePage(&writeTransaction, fixture.directoryReference, 7, .{}, .{}, resultArena.allocator()));
}

test "R26: an int property request is error.UnsupportedInclude" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi26b.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    try testing.expectError(error.UnsupportedInclude, materializePage(&writeTransaction, fixture.directoryReference, bookType, .{}, .{ .linkProperties = &.{2} }, resultArena.allocator()));
}

test "R26: a depth past maxIncludeDepth is error.IncludeTooDeep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi26c.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    try testing.expectError(error.IncludeTooDeep, materializePage(&writeTransaction, fixture.directoryReference, bookType, .{}, .{ .linkProperties = &.{authorLinkProperty}, .depth = 9 }, resultArena.allocator()));
}

test "R26: a cursor on an unindexed sort property is still error.CursorRequiresIndexedSort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi26d.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const request = Request{
        .ordering = .{ .sortKey = .{ .property = 2 }, .order = .ascending },
        .page = .{ .start = .{ .after = .{ .lastValue = 0, .lastObjectKey = 0 } } },
    };
    try testing.expectError(error.CursorRequiresIndexedSort, materializePage(&writeTransaction, fixture.directoryReference, bookType, request, .{}, resultArena.allocator()));
}

test "R27: an empty page returns an empty slice without erroring" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi27a.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .page = .{ .limit = 0 } },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );
    try testing.expectEqual(@as(usize, 0), roots.len);
}

test "R27: a predicate matching nothing returns an empty slice without erroring" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi27b.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildIncludeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        bookType,
        .{ .predicate = intComparison(2, .eq, 999_999) },
        .{ .linkProperties = &.{authorLinkProperty}, .depth = 1 },
        resultArena.allocator(),
    );
    try testing.expectEqual(@as(usize, 0), roots.len);
}

// ---------------------------------------------------------------------------
// R29: multi-target-type fan-out, expandLevel's per-type run split.
// ---------------------------------------------------------------------------

const hubType: u16 = 0;
const alphaType: u16 = 1;
const betaType: u16 = 2;
const hubToAlphaProperty: usize = 1;
const hubToBetaProperty: usize = 2;

const MultiTargetTypeFixture = struct {
    directoryReference: Reference,
    alphaKey: u64,
    betaKey: u64,
};

// Hub (0) carries two link properties, to Alpha (1) and to Beta (2): the one
// fixture in the whole suite where a single level's pending list holds two
// distinct target types, exercising expandLevel's contiguous-run split
// (query/include.zig's runStart/runEnd loop). Alpha and Beta each get object
// key 0 (independent per-type key spaces, same as fixture D's authors and
// publishers), so a run split that collapsed both types into one run would
// resolve both targets against the SAME catalog and land on the SAME object,
// rather than two distinct ones.
fn buildMultiTargetTypeFixture(writeTransaction: *WriteTransaction) !MultiTargetTypeFixture {
    const hubDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = alphaType },
        .{ .kind = .link, .linkTarget = betaType },
    };
    const alphaDefinitions = [_]catalog.PropertyDefinition{.{ .kind = .int }};
    const betaDefinitions = [_]catalog.PropertyDefinition{.{ .kind = .int }};
    var directoryReference = try typeDirectory.createWithDefinitions(writeTransaction, &.{ &hubDefinitions, &alphaDefinitions, &betaDefinitions });

    const insertedAlpha = try typeRouting.insert(writeTransaction, directoryReference, alphaType, &.{.{ .int = 111 }});
    directoryReference = insertedAlpha.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedAlpha.objectKey);

    const insertedBeta = try typeRouting.insert(writeTransaction, directoryReference, betaType, &.{.{ .int = 222 }});
    directoryReference = insertedBeta.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedBeta.objectKey);

    const insertedHub = try typeRouting.insert(writeTransaction, directoryReference, hubType, &.{
        .{ .int = 0 },
        .{ .link = insertedAlpha.objectKey },
        .{ .link = insertedBeta.objectKey },
    });
    directoryReference = insertedHub.directoryReference;

    return .{ .directoryReference = directoryReference, .alphaKey = insertedAlpha.objectKey, .betaKey = insertedBeta.objectKey };
}

// ---------------------------------------------------------------------------
// R32: a level's pending list spans two source types, gatherPending's
// reload-on-type-change branch.
// ---------------------------------------------------------------------------

const gammaType: u16 = 3;
const deltaType: u16 = 4;
const alphaToGammaProperty: usize = 1;
const betaToDeltaProperty: usize = 1;

const MultiSourceTypeFixture = struct {
    directoryReference: Reference,
    alphaKey: u64,
    betaKey: u64,
    gammaKey: u64,
    deltaKey: u64,
};

// Extends the hub/alpha/beta shape with a further level: Alpha (1) and Beta
// (2) each carry a second property, a link onward to a distinct target type
// (Gamma, 3, and Delta, 4 respectively) at the SAME property index (1) in
// their own catalogs. Depth 2 makes level 1's pending list come from
// expandLevel's parents = [alphaObject, betaObject], the one point in the
// whole suite where gatherPending's `objects` slice spans two distinct
// SOURCE types (not just two target types, R29's case): processing alpha
// then beta must reload the source catalog view when `object.typeId`
// changes, or beta's `relation.property` (1) is looked up against Alpha's
// catalog, which also calls property 1 a link, but to Gamma, not Delta.
// Gamma and Delta each get object key 0 (independent per-type key spaces),
// so a skipped reload does not error: it silently resolves Beta's link
// against Gamma's catalog and collapses the two distinct targets onto one
// object.
fn buildMultiSourceTypeFixture(writeTransaction: *WriteTransaction) !MultiSourceTypeFixture {
    const hubDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = alphaType },
        .{ .kind = .link, .linkTarget = betaType },
    };
    const alphaDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = gammaType },
    };
    const betaDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = deltaType },
    };
    const gammaDefinitions = [_]catalog.PropertyDefinition{.{ .kind = .int }};
    const deltaDefinitions = [_]catalog.PropertyDefinition{.{ .kind = .int }};
    var directoryReference = try typeDirectory.createWithDefinitions(writeTransaction, &.{
        &hubDefinitions, &alphaDefinitions, &betaDefinitions, &gammaDefinitions, &deltaDefinitions,
    });

    const insertedGamma = try typeRouting.insert(writeTransaction, directoryReference, gammaType, &.{.{ .int = 333 }});
    directoryReference = insertedGamma.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedGamma.objectKey);

    const insertedDelta = try typeRouting.insert(writeTransaction, directoryReference, deltaType, &.{.{ .int = 444 }});
    directoryReference = insertedDelta.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedDelta.objectKey);

    const insertedAlpha = try typeRouting.insert(writeTransaction, directoryReference, alphaType, &.{
        .{ .int = 111 },
        .{ .link = insertedGamma.objectKey },
    });
    directoryReference = insertedAlpha.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedAlpha.objectKey);

    const insertedBeta = try typeRouting.insert(writeTransaction, directoryReference, betaType, &.{
        .{ .int = 222 },
        .{ .link = insertedDelta.objectKey },
    });
    directoryReference = insertedBeta.directoryReference;
    try testing.expectEqual(@as(u64, 0), insertedBeta.objectKey);

    const insertedHub = try typeRouting.insert(writeTransaction, directoryReference, hubType, &.{
        .{ .int = 0 },
        .{ .link = insertedAlpha.objectKey },
        .{ .link = insertedBeta.objectKey },
    });
    directoryReference = insertedHub.directoryReference;

    return .{
        .directoryReference = directoryReference,
        .alphaKey = insertedAlpha.objectKey,
        .betaKey = insertedBeta.objectKey,
        .gammaKey = insertedGamma.objectKey,
        .deltaKey = insertedDelta.objectKey,
    };
}

test "R32: a level's pending list spans two source types, each resolved against its own catalog" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi32.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildMultiSourceTypeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        hubType,
        .{},
        .{ .linkProperties = &.{ hubToAlphaProperty, hubToBetaProperty }, .depth = 2 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(usize, 2), roots[0].included.len);

    const alphaObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(alphaType, alphaObject.typeId);
    try testing.expectEqual(fixture.alphaKey, alphaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 111 }, alphaObject.values[0]);
    try testing.expectEqual(@as(usize, 1), alphaObject.included.len);

    const betaObject = expectObject(roots[0].included[1].target);
    try testing.expectEqual(betaType, betaObject.typeId);
    try testing.expectEqual(fixture.betaKey, betaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 222 }, betaObject.values[0]);
    try testing.expectEqual(@as(usize, 1), betaObject.included.len);

    // Alpha's own link (property 1) must resolve against Alpha's catalog,
    // which calls it a link to Gamma.
    const gammaObject = expectObject(alphaObject.included[0].target);
    try testing.expectEqual(gammaType, gammaObject.typeId);
    try testing.expectEqual(fixture.gammaKey, gammaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 333 }, gammaObject.values[0]);
    try testing.expectEqual(@as(usize, 0), gammaObject.included.len); // depth bound

    // Beta's own link (same property index, 1) must resolve against Beta's
    // catalog, which calls it a link to Delta, not against a reused Alpha
    // view left over from the previous object in gatherPending's loop.
    const deltaObject = expectObject(betaObject.included[0].target);
    try testing.expectEqual(deltaType, deltaObject.typeId);
    try testing.expectEqual(fixture.deltaKey, deltaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 444 }, deltaObject.values[0]);
    try testing.expectEqual(@as(usize, 0), deltaObject.included.len); // depth bound

    // A skipped reload resolves Beta's link against Gamma's catalog and
    // Gamma's key space (both objects sit at key 0), collapsing the two
    // distinct targets onto one materialized object.
    try testing.expect(gammaObject != deltaObject);
}

test "R29: a level fanning out to two target types resolves each in its own run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi29.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();
    const fixture = try buildMultiTargetTypeFixture(&writeTransaction);

    var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
    defer resultArena.deinit();
    const roots = try materializePage(
        &writeTransaction,
        fixture.directoryReference,
        hubType,
        .{},
        .{ .linkProperties = &.{ hubToAlphaProperty, hubToBetaProperty }, .depth = 1 },
        resultArena.allocator(),
    );

    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(usize, 2), roots[0].included.len);

    const alphaObject = expectObject(roots[0].included[0].target);
    try testing.expectEqual(alphaType, alphaObject.typeId);
    try testing.expectEqual(fixture.alphaKey, alphaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 111 }, alphaObject.values[0]);

    const betaObject = expectObject(roots[0].included[1].target);
    try testing.expectEqual(betaType, betaObject.typeId);
    try testing.expectEqual(fixture.betaKey, betaObject.objectKey);
    try testing.expectEqual(PropertyValue{ .int = 222 }, betaObject.values[0]);

    // The two targets must not have collapsed onto one object: a run split
    // that ignored the type boundary would resolve both against Alpha's
    // catalog (the lower typeId, sorted first) and land both on this object.
    try testing.expect(alphaObject != betaObject);
}

// ---------------------------------------------------------------------------
// R28: fuzz over the shape.
// ---------------------------------------------------------------------------

fn walkAndCheck(
    transaction: anytype,
    catalogReference: Reference,
    object: *const MaterializedObject,
    depth: usize,
    depthBound: usize,
    depthOf: *std.AutoHashMap(u64, usize),
    steps: *usize,
    sawKey: *bool,
    sawAbsent: *bool,
    sawObject: *bool,
) !void {
    steps.* += 1;
    try testing.expect(steps.* <= 10_000);
    try testing.expect(depth <= depthBound);
    if (depthOf.get(object.objectKey)) |existingDepth| {
        try testing.expectEqual(existingDepth, depth);
    } else {
        try depthOf.put(object.objectKey, depth);
    }
    if (depth == depthBound) try testing.expectEqual(@as(usize, 0), object.included.len);

    const primaryKey = object.values[0].int;
    switch (object.values[1]) {
        .link => |target| {
            const expected = try links.getLink(transaction, catalogReference, primaryKey, 1);
            try testing.expectEqual(expected, target);
        },
        else => try testing.expect(false),
    }

    for (object.included) |relation| {
        switch (relation.target) {
            .absent => sawAbsent.* = true,
            .key => sawKey.* = true,
            .object => |child| {
                sawObject.* = true;
                try walkAndCheck(transaction, catalogReference, child, depth + 1, depthBound, depthOf, steps, sawKey, sawAbsent, sawObject);
            },
        }
    }
}

test "R28: fuzz, acyclicity, the depth bound, and link agreement hold for every (pageLimit, depth) pair" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qiTmpPath(testing.allocator, &tmp, "qi28.airdb");
    defer testing.allocator.free(path);
    var testDatabase = try Database.create(testing.allocator, path);
    defer testDatabase.deinit();
    var writeTransaction = try testDatabase.beginWrite();
    defer writeTransaction.deinit();

    const nodeType: u16 = 0;
    const mentorLink: usize = 1;
    const nodeCount: u64 = 60;

    const nodeDefinitions = [_]catalog.PropertyDefinition{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = nodeType },
    };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{&nodeDefinitions});

    var randomNumberGenerator = std.Random.DefaultPrng.init(0xC1DE);
    const random = randomNumberGenerator.random();

    var nodeIndex: u64 = 0;
    while (nodeIndex < nodeCount) : (nodeIndex += 1) {
        const inserted = try typeRouting.insert(&writeTransaction, directoryReference, nodeType, &.{ .{ .int = nodeIndex }, .{ .link = null } });
        directoryReference = inserted.directoryReference;
        try testing.expectEqual(nodeIndex, inserted.objectKey);
    }
    // One in three unset (null); otherwise a uniformly random target, so
    // self-links and short cycles are common.
    nodeIndex = 0;
    while (nodeIndex < nodeCount) : (nodeIndex += 1) {
        if (random.uintLessThan(u8, 3) == 0) continue;
        const target = random.uintLessThan(u64, nodeCount);
        directoryReference = try typeRouting.setLink(&writeTransaction, directoryReference, nodeType, nodeIndex, mentorLink, target);
    }

    const nodeCatalogReference = try typeDirectory.catalogReference(&writeTransaction, directoryReference, nodeType);

    var sawKey = false;
    var sawAbsent = false;
    var sawObject = false;

    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        const pageLimit = random.uintLessThan(u64, 21); // 0..20
        const depth = random.uintLessThan(usize, 5); // 0..4

        var resultArena = std.heap.ArenaAllocator.init(testing.allocator);
        defer resultArena.deinit();
        const roots = try materializePage(
            &writeTransaction,
            directoryReference,
            nodeType,
            .{ .page = .{ .limit = pageLimit } },
            .{ .linkProperties = &.{mentorLink}, .depth = depth },
            resultArena.allocator(),
        );

        var depthOf = std.AutoHashMap(u64, usize).init(testing.allocator);
        defer depthOf.deinit();
        var steps: usize = 0;
        for (roots) |*root| {
            try walkAndCheck(&writeTransaction, nodeCatalogReference, root, 0, depth, &depthOf, &steps, &sawKey, &sawAbsent, &sawObject);
        }
    }

    // False-positive guard: a run that degenerated to all-keys (or never
    // resolved anything) must not pass silently.
    try testing.expect(sawKey);
    try testing.expect(sawAbsent);
    try testing.expect(sawObject);
}
