const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");

pub const PropCount = u16;
pub const PropKind = enum(u8) { int = 0, blob = 1 };

// Catalog node layout:
// [prop_count u16 LE][next_row u64 LE][pk_index_ref u64 LE][version_col_ref u64 LE][live_col_ref u64 LE][prop_count * (prop_col_ref u64 LE)][prop_count * (kind u8)]
const off_prop_count: usize = 0; // u16, 2 bytes
const off_next_row: usize = 2; // u64, 8 bytes
const off_pk_index_ref: usize = 10; // u64, 8 bytes
const off_version_col_ref: usize = 18; // u64, 8 bytes
const off_live_col_ref: usize = 26; // u64, 8 bytes
const off_prop_cols: usize = 34; // prop_count * u64

// Maximum prop_count for stack-allocated ref buffers.
const max_prop_count: usize = 256;

fn catalogSize(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8 + pc;
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
    kinds: []const PropKind,
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
    const kinds_offset = off_prop_cols + @as(usize, prop_count) * 8;
    for (kinds, 0..) |k, i| {
        a.bytes[kinds_offset + i] = @intFromEnum(k);
    }
    return a.ref;
}

// createTyped allocates columns, a pk index, and a catalog node for an object
// whose property kinds are specified explicitly. kinds[0] must be .int (the pk).
pub fn createTyped(txn: *WriteTxn, kinds: []const PropKind) !Ref {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const prop_count: PropCount = @intCast(kinds.len);
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
        kinds,
    );
}

// Create prop_count property columns, a version column, a live column, and an
// empty pk index. All property kinds default to .int.
pub fn create(txn: *WriteTxn, prop_count: PropCount) !Ref {
    std.debug.assert(prop_count <= max_prop_count);
    var all_int: [max_prop_count]PropKind = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) all_int[i] = .int;
    return createTyped(txn, all_int[0..prop_count]);
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

    pub fn kind(self: CatalogView, i: usize) PropKind {
        const kinds_offset = off_prop_cols + @as(usize, self.prop_count) * 8;
        return @enumFromInt(self.bytes[kinds_offset + i]);
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
    var old_kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            old_prop_refs[j] = v.propColRef(j);
            old_kinds[j] = v.kind(j);
        }
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
        old_kinds[0..prop_count],
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
    var kinds: [256]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
        }
    }
    var ver_ref = v.version_col_ref;

    var i: usize = 0;
    while (i < pc) : (i += 1) prop_refs[i] = try Column.set(txn, prop_refs[i], row, values[i]);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc]);
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
    var kinds: [256]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
        }
    }
    var live_ref = v.live_col_ref;
    var ver_ref = v.version_col_ref;
    var idx_ref = v.pk_index_ref;

    live_ref = try Column.set(txn, live_ref, row, 0); // tombstone
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version); // bump version stamp
    idx_ref = try Index.remove(txn, idx_ref, pk); // remove pk from the index

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc]);
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

test "objects persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj6.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2); // pk + one value
        var i: u64 = 0;
        while (i < 1000) : (i += 1) cat = (try insert(&w, cat, &.{ i, i * 2 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 1000), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        _ = (try getByPk(&r, r.root(), 777, &out)).?;
        try testing.expectEqual(@as(u64, 777), out[0]);
        try testing.expectEqual(@as(u64, 1554), out[1]);
        try testing.expectEqual(@as(?u64, null), try getByPk(&r, r.root(), 5000, &out));
        r.end();
    }
}

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createTyped(&w, &.{ .int, .blob, .int });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.blob, v.kind(1));
    try testing.expectEqual(PropKind.int, v.kind(2));
    const cat2 = try create(&w, 2);
    const v2 = try loadCatalog(&w, cat2);
    try testing.expectEqual(PropKind.int, v2.kind(0));
    try testing.expectEqual(PropKind.int, v2.kind(1));
    w.deinit();
}

test "100k objects with updates and deletes match a reference map after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj7.airdb");
    defer testing.allocator.free(path);
    var ref = std.AutoHashMap(u64, u64).init(testing.allocator); // pk -> prop1 value, live only
    defer ref.deinit();
    const N: u64 = 100_000;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try create(&w, 2);
        var out: [2]u64 = undefined;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            const pk = (i *% 2654435761) % 5_000_011;
            if ((try getByPk(&w, cat, pk, &out)) != null) continue; // skip hash collision (dup pk)
            cat = (try insert(&w, cat, &.{ pk, i })).cat;
            try ref.put(pk, i);
        }
        // Snapshot the live keys, then update every 5th and delete every 7th.
        var keys = std.ArrayList(u64).empty;
        defer keys.deinit(testing.allocator);
        var kit = ref.keyIterator();
        while (kit.next()) |k| try keys.append(testing.allocator, k.*);
        for (keys.items, 0..) |pk, idx| {
            const ver = (try getByPk(&w, cat, pk, &out)).?;
            if (idx % 5 == 0) {
                const res = try update(&w, cat, pk, &.{ pk, out[1] +% 1 }, ver);
                cat = res.ok.cat;
                try ref.put(pk, out[1] +% 1);
            } else if (idx % 7 == 0) {
                const res = try delete(&w, cat, pk, ver);
                cat = res.ok;
                _ = ref.remove(pk);
            }
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, ref.count()), try liveCount(&r, r.root()));
        var out: [2]u64 = undefined;
        var it = ref.iterator();
        while (it.next()) |e| {
            const ver = try getByPk(&r, r.root(), e.key_ptr.*, &out);
            try testing.expect(ver != null);
            try testing.expectEqual(e.value_ptr.*, out[1]);
        }
        r.end();
    }
}
