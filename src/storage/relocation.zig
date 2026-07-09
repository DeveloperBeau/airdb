const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");

const maxPropertyCount: usize = 256;

/// Move object `objectKey`'s live row to physical slot `newRow` (which must
/// be a dead slot), updating the key->row index so the key and all links stay
/// valid. Does not shrink columns. Returns the new catalog reference. One column
/// walk per property plus the index update, O(propertyCount x log n).
pub fn relocateRow(transaction: *WriteTransaction, catalogReference: Reference, objectKey: u64, newRow: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    const oldRow = (try Index.get(transaction, snapshot.keyToRowIndexReference, objectKey)) orelse return catalogReference;
    if (oldRow == newRow) return catalogReference;
    // Bijection / safety guards.
    std.debug.assert((try Column.get(transaction, snapshot.liveColumnReference, oldRow)) == 1);
    std.debug.assert((try Column.get(transaction, snapshot.liveColumnReference, newRow)) == 0);

    // Copy each property cell + the version cell from oldRow to newRow.
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        const cell = try Column.get(transaction, snapshot.properties[propertyIndex].column, oldRow);
        snapshot.properties[propertyIndex].column = try Column.set(transaction, snapshot.properties[propertyIndex].column, newRow, cell);
    }
    const oldver = try Column.get(transaction, snapshot.versionColumnReference, oldRow);
    snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, newRow, oldver);
    snapshot.liveColumnReference = try Column.set(transaction, snapshot.liveColumnReference, newRow, 1);
    snapshot.liveColumnReference = try Column.set(transaction, snapshot.liveColumnReference, oldRow, 0);
    snapshot.keyToRowIndexReference = try Index.insert(transaction, snapshot.keyToRowIndexReference, objectKey, newRow);

    return snapshot.replace(transaction);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Database = @import("../database.zig").Database;
const testing = std.testing;
const objects = @import("../records/objects.zig");
const rows = @import("../records/rows.zig");
const links = @import("../records/links.zig");

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "relocateRow moves a row and keeps key, primaryKey, and value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    var catalogReference = try catalog.create(&writeTransaction, 2);
    const r1 = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 100 });
    catalogReference = r1.catalogReference;
    const r2 = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 200 });
    catalogReference = r2.catalogReference;
    const objectKeyB = r2.objectKey;
    const r3 = try rows.insert(&writeTransaction, catalogReference, &.{ 3, 300 });
    catalogReference = r3.catalogReference;
    const objectKeyC = r3.objectKey;

    // Free b's physical slot by deleting primaryKey 2.
    const bRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, objectKeyB)).?;
    var valuesOut: [2]u64 = undefined;
    const v2 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 2, &valuesOut)).?;
    const del = try rows.delete(&writeTransaction, catalogReference, 2, v2);
    catalogReference = del.ok;
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&writeTransaction, catalogReference));

    // Relocate c into b's now-dead slot.
    catalogReference = try relocateRow(&writeTransaction, catalogReference, objectKeyC, bRow);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogReference, objectKeyC, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    try testing.expect((try rows.getByPrimaryKey(&writeTransaction, catalogReference, 3, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    // Live count is unchanged: relocation does not add or remove live rows.
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&writeTransaction, catalogReference));
    // c now lives in b's old slot.
    try testing.expectEqual(@as(?u64, bRow), try catalog.objectKeyToRow(&writeTransaction, catalogReference, objectKeyC));
    writeTransaction.deinit();
}

test "setLink after relocating the SOURCE keeps the backlink graph exact" {
    // Regression: setLink/linkSetAdd/linkSetRemove recorded the source's
    // PHYSICAL ROW as the backlink source, while every consumer treats sources
    // as stable objectKeys. Once a source row was relocated the two diverged:
    // removals missed, stale entries inflated counts, and nullify could clear
    // an unrelated object's link. Backlink sources must be objectKeys.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();

    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });

    // Throwaway opens a dead slot; then two targets and the source.
    const dead = try rows.insert(&writeTransaction, catalogReference, &.{ 99, 0 });
    catalogReference = dead.catalogReference;
    const t1 = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 0 });
    catalogReference = t1.catalogReference;
    const t2 = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 0 });
    catalogReference = t2.catalogReference;
    const src = try rows.insert(&writeTransaction, catalogReference, &.{ 3, 0 });
    catalogReference = src.catalogReference;

    // Free the throwaway's physical slot and relocate the SOURCE into it, so
    // the source's row and objectKey diverge.
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, dead.objectKey)).?;
    var out: [2]u64 = undefined;
    const dv = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 99, &out)).?;
    catalogReference = (try rows.delete(&writeTransaction, catalogReference, 99, dv)).ok;
    catalogReference = try relocateRow(&writeTransaction, catalogReference, src.objectKey, deadRow);
    try testing.expect((try catalog.objectKeyToRow(&writeTransaction, catalogReference, src.objectKey)).? != src.objectKey);

    // Link src -> t1, then move it to t2: counts must track exactly.
    catalogReference = try links.setLink(&writeTransaction, catalogReference, 3, 1, t1.objectKey);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogReference, 1, t1.objectKey));
    catalogReference = try links.setLink(&writeTransaction, catalogReference, 3, 1, t2.objectKey);
    try testing.expectEqual(@as(u64, 0), try links.backlinkCount(&writeTransaction, catalogReference, 1, t1.objectKey));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogReference, 1, t2.objectKey));

    // Deleting t2 must nullify the relocated source's link (backlink resolves
    // through the objectKey), leaving t1 and the source's other data untouched.
    const t2v = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 2, &out)).?;
    catalogReference = switch (try objects.deleteAndNullify(&writeTransaction, catalogReference, 2, t2v)) {
        .ok => |newCatalog| newCatalog,
        else => unreachable,
    };
    try testing.expectEqual(@as(?u64, null), try links.getLink(&writeTransaction, catalogReference, 3, 1));
    try testing.expect((try rows.getByPrimaryKey(&writeTransaction, catalogReference, 1, &out)) != null);
}

test "a same-type link to a relocated object still resolves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();

    // primaryKey + a single .link property (property index 1).
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link },
    });

    // Throwaway object to free a dead slot.
    const rd = try rows.insert(&writeTransaction, catalogReference, &.{ 10, 0 });
    catalogReference = rd.catalogReference;
    const objectKeyD = rd.objectKey;

    const rt = try rows.insert(&writeTransaction, catalogReference, &.{ 1, 0 });
    catalogReference = rt.catalogReference;
    const targetObjectKey = rt.objectKey;

    const rs = try rows.insert(&writeTransaction, catalogReference, &.{ 2, 0 });
    catalogReference = rs.catalogReference;

    // S (primaryKey 2) links to T.
    catalogReference = try links.setLink(&writeTransaction, catalogReference, 2, 1, targetObjectKey);
    try testing.expectEqual(@as(?u64, targetObjectKey), try links.getLink(&writeTransaction, catalogReference, 2, 1));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogReference, 1, targetObjectKey));

    // Free the throwaway's slot.
    const dRow = (try catalog.objectKeyToRow(&writeTransaction, catalogReference, objectKeyD)).?;
    var valuesOut: [2]u64 = undefined;
    const v10 = (try rows.getByPrimaryKey(&writeTransaction, catalogReference, 10, &valuesOut)).?;
    const del = try rows.delete(&writeTransaction, catalogReference, 10, v10);
    catalogReference = del.ok;

    // Relocate T into the freed slot.
    catalogReference = try relocateRow(&writeTransaction, catalogReference, targetObjectKey, dRow);

    // Link, value, and backlink all still resolve through the stable objectKey.
    try testing.expectEqual(@as(?u64, targetObjectKey), try links.getLink(&writeTransaction, catalogReference, 2, 1));
    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogReference, targetObjectKey, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogReference, 1, targetObjectKey));
    writeTransaction.deinit();
}
