const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");

const max_prop_count: usize = 256;

// Move object `okey`'s live row to physical slot `new_row` (which must be a dead
// slot), updating the key->row index so the key and all links stay valid. Does
// not shrink columns. Returns the new catalog ref.
pub fn relocateRow(transaction: *WriteTransaction, catalogRef: Reference, okey: u64, new_row: u64) !Reference {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const old_row = (try Index.get(transaction, s.keyrow_index_ref, okey)) orelse return catalogRef;
    if (old_row == new_row) return catalogRef;
    // Bijection / safety guards.
    std.debug.assert((try Column.get(transaction, s.live_col_ref, old_row)) == 1);
    std.debug.assert((try Column.get(transaction, s.live_col_ref, new_row)) == 0);

    // Copy each property cell + the version cell from old_row to new_row.
    var i: usize = 0;
    while (i < s.prop_count) : (i += 1) {
        const cell = try Column.get(transaction, s.props[i].col, old_row);
        s.props[i].col = try Column.set(transaction, s.props[i].col, new_row, cell);
    }
    const oldver = try Column.get(transaction, s.version_col_ref, old_row);
    s.version_col_ref = try Column.set(transaction, s.version_col_ref, new_row, oldver);
    s.live_col_ref = try Column.set(transaction, s.live_col_ref, new_row, 1);
    s.live_col_ref = try Column.set(transaction, s.live_col_ref, old_row, 0);
    s.keyrow_index_ref = try Index.insert(transaction, s.keyrow_index_ref, okey, new_row);

    return s.replace(transaction);
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
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "relocateRow moves a row and keeps key, pk, and value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();

    var catalogRef = try catalog.create(&w, 2);
    const r1 = try rows.insert(&w, catalogRef, &.{ 1, 100 });
    catalogRef = r1.catalogRef;
    const r2 = try rows.insert(&w, catalogRef, &.{ 2, 200 });
    catalogRef = r2.catalogRef;
    const b_okey = r2.row;
    const r3 = try rows.insert(&w, catalogRef, &.{ 3, 300 });
    catalogRef = r3.catalogRef;
    const c_okey = r3.row;

    // Free b's physical slot by deleting pk 2.
    const b_row = (try catalog.okeyToRow(&w, catalogRef, b_okey)).?;
    var ver_out: [2]u64 = undefined;
    const v2 = (try rows.getByPk(&w, catalogRef, 2, &ver_out)).?;
    const del = try rows.delete(&w, catalogRef, 2, v2);
    catalogRef = del.ok;
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&w, catalogRef));

    // Relocate c into b's now-dead slot.
    catalogRef = try relocateRow(&w, catalogRef, c_okey, b_row);

    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&w, catalogRef, c_okey, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    try testing.expect((try rows.getByPk(&w, catalogRef, 3, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    // Live count is unchanged: relocation does not add or remove live rows.
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&w, catalogRef));
    // c now lives in b's old slot.
    try testing.expectEqual(@as(?u64, b_row), try catalog.okeyToRow(&w, catalogRef, c_okey));
    w.deinit();
}

test "setLink after relocating the SOURCE keeps the backlink graph exact" {
    // Regression: setLink/linkSetAdd/linkSetRemove recorded the source's
    // PHYSICAL ROW as the backlink source, while every consumer treats sources
    // as stable okeys. Once a source row was relocated the two diverged:
    // removals missed, stale entries inflated counts, and nullify could clear
    // an unrelated object's link. Backlink sources must be okeys.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();

    var catalogRef = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });

    // Throwaway opens a dead slot; then two targets and the source.
    const dead = try rows.insert(&w, catalogRef, &.{ 99, 0 });
    catalogRef = dead.catalogRef;
    const t1 = try rows.insert(&w, catalogRef, &.{ 1, 0 });
    catalogRef = t1.catalogRef;
    const t2 = try rows.insert(&w, catalogRef, &.{ 2, 0 });
    catalogRef = t2.catalogRef;
    const src = try rows.insert(&w, catalogRef, &.{ 3, 0 });
    catalogRef = src.catalogRef;

    // Free the throwaway's physical slot and relocate the SOURCE into it, so
    // the source's row and okey diverge.
    const dead_row = (try catalog.okeyToRow(&w, catalogRef, dead.row)).?;
    var out: [2]u64 = undefined;
    const dv = (try rows.getByPk(&w, catalogRef, 99, &out)).?;
    catalogRef = (try rows.delete(&w, catalogRef, 99, dv)).ok;
    catalogRef = try relocateRow(&w, catalogRef, src.row, dead_row);
    try testing.expect((try catalog.okeyToRow(&w, catalogRef, src.row)).? != src.row);

    // Link src -> t1, then move it to t2: counts must track exactly.
    catalogRef = try links.setLink(&w, catalogRef, 3, 1, t1.row);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, catalogRef, 1, t1.row));
    catalogRef = try links.setLink(&w, catalogRef, 3, 1, t2.row);
    try testing.expectEqual(@as(u64, 0), try links.backlinkCount(&w, catalogRef, 1, t1.row));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, catalogRef, 1, t2.row));

    // Deleting t2 must nullify the relocated source's link (backlink resolves
    // through the okey), leaving t1 and the source's other data untouched.
    const t2v = (try rows.getByPk(&w, catalogRef, 2, &out)).?;
    catalogRef = switch (try objects.deleteAndNullify(&w, catalogRef, 2, t2v)) {
        .ok => |c| c,
        else => unreachable,
    };
    try testing.expectEqual(@as(?u64, null), try links.getLink(&w, catalogRef, 3, 1));
    try testing.expect((try rows.getByPk(&w, catalogRef, 1, &out)) != null);
}

test "a same-type link to a relocated object still resolves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();

    // pk + a single .link prop (prop index 1).
    var catalogRef = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link },
    });

    // Throwaway object to free a dead slot.
    const rd = try rows.insert(&w, catalogRef, &.{ 10, 0 });
    catalogRef = rd.catalogRef;
    const d_okey = rd.row;

    const rt = try rows.insert(&w, catalogRef, &.{ 1, 0 });
    catalogRef = rt.catalogRef;
    const t_okey = rt.row;

    const rs = try rows.insert(&w, catalogRef, &.{ 2, 0 });
    catalogRef = rs.catalogRef;

    // S (pk 2) links to T.
    catalogRef = try links.setLink(&w, catalogRef, 2, 1, t_okey);
    try testing.expectEqual(@as(?u64, t_okey), try links.getLink(&w, catalogRef, 2, 1));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, catalogRef, 1, t_okey));

    // Free the throwaway's slot.
    const d_row = (try catalog.okeyToRow(&w, catalogRef, d_okey)).?;
    var ver_out: [2]u64 = undefined;
    const v10 = (try rows.getByPk(&w, catalogRef, 10, &ver_out)).?;
    const del = try rows.delete(&w, catalogRef, 10, v10);
    catalogRef = del.ok;

    // Relocate T into the freed slot.
    catalogRef = try relocateRow(&w, catalogRef, t_okey, d_row);

    // Link, value, and backlink all still resolve through the stable okey.
    try testing.expectEqual(@as(?u64, t_okey), try links.getLink(&w, catalogRef, 2, 1));
    var out: [2]u64 = undefined;
    try testing.expect((try rows.getByObjectKey(&w, catalogRef, t_okey, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, catalogRef, 1, t_okey));
    w.deinit();
}
