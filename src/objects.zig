const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");

pub const PropCount = u16;

// Catalog node layout:
// [prop_count u16 LE][next_row u64 LE][pk_index_ref u64 LE][version_col_ref u64 LE][live_col_ref u64 LE][prop_count * (prop_col_ref u64 LE)]
const off_prop_count: usize = 0; // u16, 2 bytes
const off_next_row: usize = 2; // u64, 8 bytes
const off_pk_index_ref: usize = 10; // u64, 8 bytes
const off_version_col_ref: usize = 18; // u64, 8 bytes
const off_live_col_ref: usize = 26; // u64, 8 bytes
const off_prop_cols: usize = 34; // prop_count * u64

// Maximum prop_count for stack-allocated ref buffers.
const max_prop_count: usize = 256;

fn catalogSize(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8;
}

// Allocate and encode a fresh catalog node; return its ref.
fn writeCatalog(
    txn: *WriteTxn,
    prop_count: PropCount,
    next_row: u64,
    pk_index_ref: Ref,
    version_col_ref: Ref,
    live_col_ref: Ref,
    prop_col_refs: []const Ref,
) !Ref {
    const a = try txn.alloc(catalogSize(prop_count));
    std.mem.writeInt(u16, a.bytes[off_prop_count..][0..2], prop_count, .little);
    std.mem.writeInt(u64, a.bytes[off_next_row..][0..8], next_row, .little);
    std.mem.writeInt(u64, a.bytes[off_pk_index_ref..][0..8], pk_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_version_col_ref..][0..8], version_col_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_live_col_ref..][0..8], live_col_ref, .little);
    for (prop_col_refs, 0..) |ref, i| {
        std.mem.writeInt(u64, a.bytes[off_prop_cols + i * 8 ..][0..8], ref, .little);
    }
    return a.ref;
}

// Create prop_count property columns, a version column, a live column, and an
// empty pk index. Write a catalog node encoding all refs and return its ref.
pub fn create(txn: *WriteTxn, prop_count: PropCount) !Ref {
    std.debug.assert(prop_count <= max_prop_count);
    var prop_col_refs: [max_prop_count]Ref = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        prop_col_refs[i] = try Column.create(txn);
    }
    const version_col_ref = try Column.create(txn);
    const live_col_ref = try Column.create(txn);
    const pk_index_ref = try Index.create(txn);
    return writeCatalog(
        txn,
        prop_count,
        0,
        pk_index_ref,
        version_col_ref,
        live_col_ref,
        prop_col_refs[0..prop_count],
    );
}

pub const CatalogView = struct {
    prop_count: PropCount,
    next_row: u64,
    pk_index_ref: Ref,
    version_col_ref: Ref,
    live_col_ref: Ref,
    bytes: []const u8,

    pub fn propColRef(self: CatalogView, i: usize) Ref {
        return std.mem.readInt(u64, self.bytes[off_prop_cols + i * 8 ..][0..8], .little);
    }
};

// Deref the catalog at cat, read prop_count, then deref the full node and parse
// all fixed fields. Returns a CatalogView whose bytes slice is valid for the
// lifetime of the transaction.
fn loadCatalog(txn: anytype, cat: Ref) !CatalogView {
    const pc_bytes = try txn.deref(cat, 2);
    const prop_count = std.mem.readInt(u16, pc_bytes[0..2], .little);
    std.debug.assert(prop_count <= max_prop_count);
    const bytes = try txn.deref(cat, catalogSize(prop_count));
    return CatalogView{
        .prop_count = prop_count,
        .next_row = std.mem.readInt(u64, bytes[off_next_row..][0..8], .little),
        .pk_index_ref = std.mem.readInt(u64, bytes[off_pk_index_ref..][0..8], .little),
        .version_col_ref = std.mem.readInt(u64, bytes[off_version_col_ref..][0..8], .little),
        .live_col_ref = std.mem.readInt(u64, bytes[off_live_col_ref..][0..8], .little),
        .bytes = bytes,
    };
}

pub fn propCount(txn: anytype, cat: Ref) !PropCount {
    const view = try loadCatalog(txn, cat);
    return view.prop_count;
}

// liveCount returns the number of live rows tracked by the pk index.
pub fn liveCount(txn: anytype, cat: Ref) !u64 {
    const view = try loadCatalog(txn, cat);
    return Index.count(txn, view.pk_index_ref);
}

// insert appends a new row to all columns and updates the pk index.
// values.len must equal the prop_count stored in the catalog.
// Returns error.DuplicateKey if values[0] (the primary key) already exists.
pub fn insert(txn: *WriteTxn, cat: Ref, values: []const u64) !struct { cat: Ref, row: u64 } {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(values.len == v.prop_count);

    // Capture all refs from the view into locals before any mutation so the
    // bytes slice backing CatalogView cannot be invalidated by file growth.
    const old_pk_index_ref = v.pk_index_ref;
    const old_version_col_ref = v.version_col_ref;
    const old_live_col_ref = v.live_col_ref;
    var old_prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) old_prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    const row = v.next_row;

    const pk = values[0];
    if ((try Index.get(txn, old_pk_index_ref, pk)) != null) return error.DuplicateKey;

    // COW-append to each property column.
    var new_prop_refs: [max_prop_count]Ref = undefined;
    {
        var i: usize = 0;
        while (i < prop_count) : (i += 1) {
            new_prop_refs[i] = try Column.append(txn, old_prop_refs[i], values[i]);
        }
    }
    const new_version_col = try Column.append(txn, old_version_col_ref, txn.new_version);
    const new_live_col = try Column.append(txn, old_live_col_ref, 1);
    const new_index = try Index.insert(txn, old_pk_index_ref, pk, row);

    const new_cat = try writeCatalog(
        txn,
        prop_count,
        row + 1,
        new_index,
        new_version_col,
        new_live_col,
        new_prop_refs[0..prop_count],
    );
    return .{ .cat = new_cat, .row = row };
}

pub const Conflict = struct { current_version: u64 };
pub const UpdateResult = union(enum) {
    ok: struct { cat: Ref, version: u64 },
    conflict: Conflict,
    not_found,
};

pub const DeleteResult = union(enum) {
    ok: Ref, // new catalog
    conflict: Conflict,
    not_found,
};

pub fn update(txn: *WriteTxn, cat: Ref, pk: u64, values: []const u64, expected_version: u64) !UpdateResult {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(values.len == v.prop_count);
    std.debug.assert(values[0] == pk); // pk is identity, must not change
    const row = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const cur = try Column.get(txn, v.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };

    // Capture refs into locals before mutating (avoid relying on the catalog deref slice).
    const pc = v.prop_count;
    const idx_ref = v.pk_index_ref;
    const live_ref = v.live_col_ref;
    const next_row = v.next_row;
    var prop_refs: [256]Ref = undefined;
    { var j: usize = 0; while (j < pc) : (j += 1) prop_refs[j] = v.propColRef(j); }
    var ver_ref = v.version_col_ref;

    var i: usize = 0;
    while (i < pc) : (i += 1) prop_refs[i] = try Column.set(txn, prop_refs[i], row, values[i]);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc]);
    return .{ .ok = .{ .cat = new_cat, .version = txn.new_version } };
}

pub fn delete(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const row = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const cur = try Column.get(txn, v.version_col_ref, row);
    if (cur != expected_version) return .{ .conflict = .{ .current_version = cur } };

    // Capture refs into locals before mutating.
    const pc = v.prop_count;
    const next_row = v.next_row;
    var prop_refs: [256]Ref = undefined;
    { var j: usize = 0; while (j < pc) : (j += 1) prop_refs[j] = v.propColRef(j); }
    var live_ref = v.live_col_ref;
    var ver_ref = v.version_col_ref;
    var idx_ref = v.pk_index_ref;

    live_ref = try Column.set(txn, live_ref, row, 0);             // tombstone
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version); // bump version stamp
    idx_ref = try Index.remove(txn, idx_ref, pk);                 // remove pk from the index

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc]);
    return .{ .ok = new_cat };
}

pub fn getByPk(txn: anytype, cat: Ref, pk: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    // Capture refs before any potential file growth from other ops.
    const pk_index_ref = v.pk_index_ref;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    const row = (try Index.get(txn, pk_index_ref, pk)) orelse return null;
    if ((try Column.get(txn, live_col_ref, row)) == 0) return null;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        out[i] = try Column.get(txn, prop_refs[i], row);
    }
    return try Column.get(txn, version_col_ref, row);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "create allocates an empty type and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try create(&w, 3);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, cat));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, cat));
    w.deinit();
}

test "insert appends rows and rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    const r1 = try insert(&w, cat, &.{ 100, 7, 1 });
    cat = r1.cat;
    const r2 = try insert(&w, cat, &.{ 200, 8, 0 });
    cat = r2.cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    try testing.expectError(error.DuplicateKey, insert(&w, cat, &.{ 100, 9, 1 }));
    w.deinit();
}

test "getByPk reads property values and the row version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;

    var out: [3]u64 = undefined;
    const ver = try getByPk(&w, cat, 200, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(u64, 0), out[2]);
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 999, &out));
    w.deinit();
}

test "update applies on a matching version and conflicts on a stale one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var cat: Ref = undefined;
    var fetched_version: u64 = undefined;
    {
        var w = try db.beginWrite();
        cat = try create(&w, 3);
        cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        fetched_version = (try getByPk(&r, r.root(), 100, &out)).?;
        r.end();
    }
    {
        var w = try db.beginWrite();
        const res = try update(&w, w.new_root, 100, &.{ 100, 77, 1 }, fetched_version);
        try testing.expect(res == .ok);
        cat = res.ok.cat;
        const res2 = try update(&w, cat, 100, &.{ 100, 88, 1 }, fetched_version); // stale now
        try testing.expect(res2 == .conflict);
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var r = try db.beginRead();
        var out: [3]u64 = undefined;
        _ = try getByPk(&r, r.root(), 100, &out);
        try testing.expectEqual(@as(u64, 77), out[1]);
        r.end();
    }
}

test "delete tombstones a row and conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;

    const stale = try delete(&w, cat, 100, v100 + 1);
    try testing.expect(stale == .conflict);

    const ok = try delete(&w, cat, 100, v100);
    try testing.expect(ok == .ok);
    cat = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, cat));
    // pk 100 can be reinserted after deletion
    cat = (try insert(&w, cat, &.{ 100, 70, 1 })).cat;
    try testing.expectEqual(@as(u64, 2), try liveCount(&w, cat));
    w.deinit();
}
