const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");

const max_prop_count: usize = 256;

// Move object `okey`'s live row to physical slot `new_row` (which must be a dead
// slot), updating the key->row index so the key and all links stay valid. Does
// not shrink columns. Returns the new catalog ref.
pub fn relocateRow(txn: *WriteTxn, cat: Ref, okey: u64, new_row: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const old_row = (try Index.get(txn, v.keyrow_index_ref, okey)) orelse return cat;
    if (old_row == new_row) return cat;
    // Bijection / safety guards.
    std.debug.assert((try Column.get(txn, v.live_col_ref, old_row)) == 1);
    std.debug.assert((try Column.get(txn, v.live_col_ref, new_row)) == 0);

    // Capture all view-backed values into locals before the first Column.set,
    // since growing the file can invalidate the bytes backing CatalogView.
    const pc = v.prop_count;
    const next_row = v.next_row;
    const next_key = v.next_key;
    const idx_ref = v.pk_index_ref;
    var keyrow = v.keyrow_index_ref;
    var ver_ref = v.version_col_ref;
    var live_ref = v.live_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]catalog.PropKind = undefined;
    var elems: [max_prop_count]catalog.ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
        }
    }
    // Copy each property cell + the version cell from old_row to new_row.
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        const cell = try Column.get(txn, prop_refs[i], old_row);
        prop_refs[i] = try Column.set(txn, prop_refs[i], new_row, cell);
    }
    const oldver = try Column.get(txn, ver_ref, old_row);
    ver_ref = try Column.set(txn, ver_ref, new_row, oldver);
    live_ref = try Column.set(txn, live_ref, new_row, 1);
    live_ref = try Column.set(txn, live_ref, old_row, 0);
    keyrow = try Index.insert(txn, keyrow, okey, new_row);

    return catalog.writeCatalog(
        txn,
        pc,
        next_row,
        keyrow,
        next_key,
        idx_ref,
        ver_ref,
        live_ref,
        prop_refs[0..pc],
        kinds[0..pc],
        elems[0..pc],
        bl[0..pc],
        targets[0..pc],
        rules[0..pc],
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Db = @import("db.zig").Db;
const testing = std.testing;
const objects = @import("objects.zig");
const links = @import("links.zig");

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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    var cat = try catalog.create(&w, 2);
    const r1 = try objects.insert(&w, cat, &.{ 1, 100 });
    cat = r1.cat;
    const r2 = try objects.insert(&w, cat, &.{ 2, 200 });
    cat = r2.cat;
    const b_okey = r2.row;
    const r3 = try objects.insert(&w, cat, &.{ 3, 300 });
    cat = r3.cat;
    const c_okey = r3.row;

    // Free b's physical slot by deleting pk 2.
    const b_row = (try catalog.okeyToRow(&w, cat, b_okey)).?;
    var ver_out: [2]u64 = undefined;
    const v2 = (try objects.getByPk(&w, cat, 2, &ver_out)).?;
    const del = try objects.delete(&w, cat, 2, v2);
    cat = del.ok;
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&w, cat));

    // Relocate c into b's now-dead slot.
    cat = try relocateRow(&w, cat, c_okey, b_row);

    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, c_okey, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    try testing.expect((try objects.getByPk(&w, cat, 3, &out)) != null);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 300), out[1]);

    // Live count is unchanged: relocation does not add or remove live rows.
    try testing.expectEqual(@as(u64, 2), try catalog.liveCount(&w, cat));
    // c now lives in b's old slot.
    try testing.expectEqual(@as(?u64, b_row), try catalog.okeyToRow(&w, cat, c_okey));
    w.deinit();
}

test "a same-type link to a relocated object still resolves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "reloc2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    // pk + a single .link prop (prop index 1).
    var cat = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link },
    });

    // Throwaway object to free a dead slot.
    const rd = try objects.insert(&w, cat, &.{ 10, 0 });
    cat = rd.cat;
    const d_okey = rd.row;

    const rt = try objects.insert(&w, cat, &.{ 1, 0 });
    cat = rt.cat;
    const t_okey = rt.row;

    const rs = try objects.insert(&w, cat, &.{ 2, 0 });
    cat = rs.cat;

    // S (pk 2) links to T.
    cat = try links.setLink(&w, cat, 2, 1, t_okey);
    try testing.expectEqual(@as(?u64, t_okey), try links.getLink(&w, cat, 2, 1));
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, cat, 1, t_okey));

    // Free the throwaway's slot.
    const d_row = (try catalog.okeyToRow(&w, cat, d_okey)).?;
    var ver_out: [2]u64 = undefined;
    const v10 = (try objects.getByPk(&w, cat, 10, &ver_out)).?;
    const del = try objects.delete(&w, cat, 10, v10);
    cat = del.ok;

    // Relocate T into the freed slot.
    cat = try relocateRow(&w, cat, t_okey, d_row);

    // Link, value, and backlink all still resolve through the stable okey.
    try testing.expectEqual(@as(?u64, t_okey), try links.getLink(&w, cat, 2, 1));
    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, t_okey, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, cat, 1, t_okey));
    w.deinit();
}
