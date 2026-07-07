const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");

const maxPropertyCount: usize = 256;

// Move object `objectKey`'s live row to physical slot `newRow` (which must be a dead
// slot), updating the key->row index so the key and all links stay valid. Does
// not shrink columns. Returns the new catalog ref.
pub fn relocateRow(transaction: *WriteTransaction, catalogRef: Reference, objectKey: u64, newRow: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const oldRow = (try Index.get(transaction, snapshot.keyrowIndexRef, objectKey)) orelse return catalogRef;
    if (oldRow == newRow) return catalogRef;
    // Bijection / safety guards.
    std.debug.assert((try Column.get(transaction, snapshot.liveColRef, oldRow)) == 1);
    std.debug.assert((try Column.get(transaction, snapshot.liveColRef, newRow)) == 0);

    // Copy each property cell + the version cell from oldRow to newRow.
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        const cell = try Column.get(transaction, snapshot.properties[propertyIndex].col, oldRow);
        snapshot.properties[propertyIndex].col = try Column.set(transaction, snapshot.properties[propertyIndex].col, newRow, cell);
    }
    const oldver = try Column.get(transaction, snapshot.versionColRef, oldRow);
    snapshot.versionColRef = try Column.set(transaction, snapshot.versionColRef, newRow, oldver);
    snapshot.liveColRef = try Column.set(transaction, snapshot.liveColRef, newRow, 1);
    snapshot.liveColRef = try Column.set(transaction, snapshot.liveColRef, oldRow, 0);
    snapshot.keyrowIndexRef = try Index.insert(transaction, snapshot.keyrowIndexRef, objectKey, newRow);

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

    var catalogRef = try catalog.create(&writeTransaction, 2);
    const r1 = try rows.insert(&writeTransaction, catalogRef, &.{ 1, 100 });
    catalogRef = r1.catalogRef;
    const r2 = try rows.insert(&writeTransaction, catalogRef, &.{ 2, 200 });
    catalogRef = r2.catalogRef;
    const objectKeyB = r2.row;
    const r3 = try rows.insert(&writeTransaction, catalogRef, &.{ 3, 300 });
    catalogRef = r3.catalogRef;
    const objectKeyC = r3.row;

    // Free b's physical slot by deleting primaryKey 2.
    const bRow = (try catalog.objectKeyToRow(&writeTransaction, catalogRef, objectKeyB)).?;
    var valuesOut: [2]u64 = undefined;
    const v2 = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 2, &valuesOut)).?;
    const del = try rows.delete(&writeTransaction, catalogRef, 2, v2);
    catalogRef = del.ok;
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&writeTransaction, catalogRef));

    // Relocate c into b's now-dead slot.
    catalogRef = try relocateRow(&writeTransaction, catalogRef, objectKeyC, bRow);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogRef, objectKeyC, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    try testing.expect((try rows.getByPrimaryKey(&writeTransaction, catalogRef, 3, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    // Live count is unchanged: relocation does not add or remove live rows.
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&writeTransaction, catalogRef));
    // c now lives in b's old slot.
    try testing.expectEqual(@as(?u64, bRow), try catalog.objectKeyToRow(&writeTransaction, catalogRef, objectKeyC));
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

    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .link } });

    // Throwaway opens a dead slot; then two targets and the source.
    const dead = try rows.insert(&writeTransaction, catalogRef, &.{ 99, 0 });
    catalogRef = dead.catalogRef;
    const t1 = try rows.insert(&writeTransaction, catalogRef, &.{ 1, 0 });
    catalogRef = t1.catalogRef;
    const t2 = try rows.insert(&writeTransaction, catalogRef, &.{ 2, 0 });
    catalogRef = t2.catalogRef;
    const src = try rows.insert(&writeTransaction, catalogRef, &.{ 3, 0 });
    catalogRef = src.catalogRef;

    // Free the throwaway's physical slot and relocate the SOURCE into it, so
    // the source's row and objectKey diverge.
    const deadRow = (try catalog.objectKeyToRow(&writeTransaction, catalogRef, dead.row)).?;
    var out: [2]u64 = undefined;
    const dv = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 99, &out)).?;
    catalogRef = (try rows.delete(&writeTransaction, catalogRef, 99, dv)).ok;
    catalogRef = try relocateRow(&writeTransaction, catalogRef, src.row, deadRow);
    try testing.expect((try catalog.objectKeyToRow(&writeTransaction, catalogRef, src.row)).? != src.row);

    // Link src -> t1, then move it to t2: counts must track exactly.
    catalogRef = try links.setLink(&writeTransaction, catalogRef, 3, 1, t1.row);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogRef, 1, t1.row));
    catalogRef = try links.setLink(&writeTransaction, catalogRef, 3, 1, t2.row);
    try testing.expectEqual(@as(u64, 0), try links.backlinkCount(&writeTransaction, catalogRef, 1, t1.row));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogRef, 1, t2.row));

    // Deleting t2 must nullify the relocated source's link (backlink resolves
    // through the objectKey), leaving t1 and the source's other data untouched.
    const t2v = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 2, &out)).?;
    catalogRef = switch (try objects.deleteAndNullify(&writeTransaction, catalogRef, 2, t2v)) {
        .ok => |newCatalog| newCatalog,
        else => unreachable,
    };
    try testing.expectEqual(@as(?u64, null), try links.getLink(&writeTransaction, catalogRef, 3, 1));
    try testing.expect((try rows.getByPrimaryKey(&writeTransaction, catalogRef, 1, &out)) != null);
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
    var catalogRef = try catalog.createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link },
    });

    // Throwaway object to free a dead slot.
    const rd = try rows.insert(&writeTransaction, catalogRef, &.{ 10, 0 });
    catalogRef = rd.catalogRef;
    const objectKeyD = rd.row;

    const rt = try rows.insert(&writeTransaction, catalogRef, &.{ 1, 0 });
    catalogRef = rt.catalogRef;
    const targetObjectKey = rt.row;

    const rs = try rows.insert(&writeTransaction, catalogRef, &.{ 2, 0 });
    catalogRef = rs.catalogRef;

    // S (primaryKey 2) links to T.
    catalogRef = try links.setLink(&writeTransaction, catalogRef, 2, 1, targetObjectKey);
    try testing.expectEqual(@as(?u64, targetObjectKey), try links.getLink(&writeTransaction, catalogRef, 2, 1));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogRef, 1, targetObjectKey));

    // Free the throwaway's slot.
    const dRow = (try catalog.objectKeyToRow(&writeTransaction, catalogRef, objectKeyD)).?;
    var valuesOut: [2]u64 = undefined;
    const v10 = (try rows.getByPrimaryKey(&writeTransaction, catalogRef, 10, &valuesOut)).?;
    const del = try rows.delete(&writeTransaction, catalogRef, 10, v10);
    catalogRef = del.ok;

    // Relocate T into the freed slot.
    catalogRef = try relocateRow(&writeTransaction, catalogRef, targetObjectKey, dRow);

    // Link, value, and backlink all still resolve through the stable objectKey.
    try testing.expectEqual(@as(?u64, targetObjectKey), try links.getLink(&writeTransaction, catalogRef, 2, 1));
    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&writeTransaction, catalogRef, targetObjectKey, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&writeTransaction, catalogRef, 1, targetObjectKey));
    writeTransaction.deinit();
}
