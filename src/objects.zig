const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

const loadCatalog = catalog.loadCatalog;
const writeCatalog = catalog.writeCatalog;

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
    var old_elems: [max_prop_count]ElemKind = undefined;
    var old_backlinks: [max_prop_count]Ref = undefined;
    var old_targets: [max_prop_count]u16 = undefined;
    var old_rules: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            old_prop_refs[j] = v.propColRef(j);
            old_kinds[j] = v.kind(j);
            old_elems[j] = v.elemKind(j);
            old_backlinks[j] = v.backlinkRef(j);
            old_targets[j] = v.linkTarget(j);
            old_rules[j] = v.delRule(j);
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
        old_elems[0..prop_count],
        old_backlinks[0..prop_count],
        old_targets[0..prop_count],
        old_rules[0..prop_count],
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
    var elems_buf: [max_prop_count]ElemKind = undefined;
    var bl_buf: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
            bl_buf[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
        }
    }
    var ver_ref = v.version_col_ref;

    var i: usize = 0;
    while (i < pc) : (i += 1) prop_refs[i] = try Column.set(txn, prop_refs[i], row, values[i]);
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version);

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc], bl_buf[0..pc], targets_buf[0..pc], rules_buf[0..pc]);
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
    var elems_buf: [max_prop_count]ElemKind = undefined;
    var bl_buf: [max_prop_count]Ref = undefined;
    var targets_buf: [max_prop_count]u16 = undefined;
    var rules_buf: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop_refs[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems_buf[j] = v.elemKind(j);
            bl_buf[j] = v.backlinkRef(j);
            targets_buf[j] = v.linkTarget(j);
            rules_buf[j] = v.delRule(j);
        }
    }
    var live_ref = v.live_col_ref;
    var ver_ref = v.version_col_ref;
    var idx_ref = v.pk_index_ref;

    live_ref = try Column.set(txn, live_ref, row, 0); // tombstone
    ver_ref = try Column.set(txn, ver_ref, row, txn.new_version); // bump version stamp
    idx_ref = try Index.remove(txn, idx_ref, pk); // remove pk from the index

    const new_cat = try writeCatalog(txn, pc, next_row, idx_ref, ver_ref, live_ref, prop_refs[0..pc], kinds[0..pc], elems_buf[0..pc], bl_buf[0..pc], targets_buf[0..pc], rules_buf[0..pc]);
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

// Read a row by its stable object key (okey == the row assigned at insert).
// Returns the row version, or null if the okey is out of range or tombstoned.
pub fn getByObjectKey(txn: anytype, cat: Ref, okey: u64, out: []u64) !?u64 {
    const v = try loadCatalog(txn, cat);
    std.debug.assert(out.len == v.prop_count);
    if (okey >= v.next_row) return null;
    const live_col_ref = v.live_col_ref;
    const version_col_ref = v.version_col_ref;
    var prop_refs: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) prop_refs[j] = v.propColRef(j);
    }
    const prop_count = v.prop_count;
    if ((try Column.get(txn, live_col_ref, okey)) == 0) return null;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) out[i] = try Column.get(txn, prop_refs[i], okey);
    return try Column.get(txn, version_col_ref, okey);
}

// insertTyped encodes a []Value row into raw u64 storage, allocating a blob
// node for each .blob property, then delegates to insert.
pub fn insertTyped(txn: *WriteTxn, cat: Ref, values: []const Value) !struct { cat: Ref, row: u64 } {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(values.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds and elems into local buffers before any mutation that could
    // invalidate the deref slice backing CatalogView.
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
        }
    }
    var raw: [max_prop_count]u64 = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        raw[i] = switch (kinds[i]) {
            .int => values[i].int,
            .blob => try blob.put(txn, values[i].bytes),
            .list => switch (elems[i]) {
                .int => try collections.buildListInt(txn, values[i].list_int),
                .blob => try collections.buildListBlob(txn, values[i].list_blob),
            },
            .set => switch (elems[i]) {
                .int => try collections.buildSetInt(txn, values[i].set_int),
                .blob => unreachable, // set of blob out of scope this phase
            },
            .link => if (values[i].link) |k| k + 1 else 0,
            .link_set => try collections.buildSetInt(txn, values[i].link_set),
        };
    }
    const r = try insert(txn, cat, raw[0..pc]);
    // Maintain backlinks for any links the new row carries.
    var cat_ref = r.cat;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            switch (kinds[p]) {
                .link => {
                    if (values[p].link) |target| {
                        cat_ref = try links.addBacklink(txn, cat_ref, p, target, r.row);
                    }
                },
                .link_set => {
                    for (values[p].link_set) |target| {
                        cat_ref = try links.addBacklink(txn, cat_ref, p, target, r.row);
                    }
                },
                else => {},
            }
        }
    }
    return .{ .cat = cat_ref, .row = r.row };
}

// getTyped reads a row by primary key and decodes each property into a Value.
// .blob properties are zero-copy slices into the mapped storage.
// Returns the row version, or null when the key is not found.
pub fn getTyped(txn: anytype, cat: Ref, pk: u64, out: []Value) !?u64 {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(out.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds before the getByPk call may touch other catalog nodes.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    var raw: [max_prop_count]u64 = undefined;
    const ver = (try getByPk(txn, cat, pk, raw[0..pc])) orelse return null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        out[i] = switch (kinds[i]) {
            .int => .{ .int = raw[i] },
            .blob => .{ .bytes = try blob.get(txn, raw[i]) },
            .list, .set, .link_set => .{ .coll_root = raw[i] },
            .link => .{ .link = if (raw[i] == 0) null else raw[i] - 1 },
        };
    }
    return ver;
}

// getTypedByOkey decodes a row addressed by stable object key into Values.
pub fn getTypedByOkey(txn: anytype, cat: Ref, okey: u64, out: []Value) !?u64 {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(out.len == pc);
    std.debug.assert(pc <= max_prop_count);
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    var raw: [max_prop_count]u64 = undefined;
    const ver = (try getByObjectKey(txn, cat, okey, raw[0..pc])) orelse return null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        out[i] = switch (kinds[i]) {
            .int => .{ .int = raw[i] },
            .blob => .{ .bytes = try blob.get(txn, raw[i]) },
            .list, .set, .link_set => .{ .coll_root = raw[i] },
            .link => .{ .link = if (raw[i] == 0) null else raw[i] - 1 },
        };
    }
    return ver;
}

// Delete an object and keep the graph consistent: nullify inbound links and
// clean the deleted object's outbound backlink entries.
pub fn deleteAndNullify(txn: *WriteTxn, cat: Ref, pk: u64, expected_version: u64) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const okey = (try Index.get(txn, v.pk_index_ref, pk)) orelse return .not_found;
    const cur_ver = try Column.get(txn, v.version_col_ref, okey);
    if (cur_ver != expected_version) return .{ .conflict = .{ .current_version = cur_ver } };
    const fixed = try links.fixBacklinksForDelete(txn, cat, okey);
    return try delete(txn, fixed, pk, expected_version);
}

// updateTyped is MVCC-safe: it does NOT free any blob unless the version check
// passes. Steps: read current row, check version, then on the apply path free
// old blobs and allocate new ones before delegating to update.
pub fn updateTyped(
    txn: *WriteTxn,
    cat: Ref,
    pk: u64,
    values: []const Value,
    expected_version: u64,
) !UpdateResult {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(values.len == pc);
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds before any mutation.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    // Step 1: read the current row into cur_raw.
    var cur_raw: [max_prop_count]u64 = undefined;
    const current_version = (try getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
    // Step 2: version check BEFORE freeing or allocating any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: apply path -- free old blobs and allocate new ones.
    var new_raw: [max_prop_count]u64 = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        new_raw[i] = switch (kinds[i]) {
            .int => values[i].int,
            .blob => blk: {
                try blob.free(txn, cur_raw[i]);
                break :blk try blob.put(txn, values[i].bytes);
            },
            .list, .set, .link_set => unreachable, // collection update not yet implemented
            .link => if (values[i].link) |k| k + 1 else 0,
        };
    }
    // Step 4: delegate to the core update; it will re-check the version (match).
    return try update(txn, cat, pk, new_raw[0..pc], expected_version);
}

// deleteTyped is MVCC-safe: blobs are freed only on the apply path, never on
// conflict or not_found.
pub fn deleteTyped(
    txn: *WriteTxn,
    cat: Ref,
    pk: u64,
    expected_version: u64,
) !DeleteResult {
    const v = try loadCatalog(txn, cat);
    const pc = v.prop_count;
    std.debug.assert(pc <= max_prop_count);
    // Capture kinds before any mutation.
    var kinds: [max_prop_count]PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) kinds[j] = v.kind(j);
    }
    // Step 1: read the current row.
    var cur_raw: [max_prop_count]u64 = undefined;
    const current_version = (try getByPk(txn, cat, pk, cur_raw[0..pc])) orelse return .not_found;
    // Step 2: version check BEFORE freeing any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: apply path -- free all blob props.
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        if (kinds[i] == .blob) try blob.free(txn, cur_raw[i]);
    }
    // Step 4: delegate to the graph-safe delete (nullifies inbound links).
    return try deleteAndNullify(txn, cat, pk, expected_version);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const create = catalog.create;
const createTyped = catalog.createTyped;
const propCount = catalog.propCount;
const liveCount = catalog.liveCount;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "insert appends a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_append.airdb");
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
    w.deinit();
}

test "insert rejects a duplicate primary key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj2_dup.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
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

test "update applies on a matching version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_apply.airdb");
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

test "update conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj4_conflict.airdb");
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
        w.deinit();
    }
}

test "delete conflicts on a stale version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_conflict.airdb");
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
    w.deinit();
}

test "delete tombstones a row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_tombstone.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    const ok = try delete(&w, cat, 100, v100);
    try testing.expect(ok == .ok);
    cat = ok.ok;
    try testing.expectEqual(@as(?u64, null), try getByPk(&w, cat, 100, &out));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, cat));
    w.deinit();
}

test "a deleted primary key can be reinserted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj5_reinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 3);
    cat = (try insert(&w, cat, &.{ 100, 7, 1 })).cat;
    cat = (try insert(&w, cat, &.{ 200, 8, 0 })).cat;
    var out: [3]u64 = undefined;
    const v100 = (try getByPk(&w, cat, 100, &out)).?;
    cat = (try delete(&w, cat, 100, v100)).ok;
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

test "typed insert and get round-trip a string property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob, .int });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 30 } })).cat;
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "Linus" }, .{ .int = 54 } })).cat;
    var out: [3]Value = undefined;
    const ver = try getTyped(&w, cat, 2, &out);
    try testing.expect(ver != null);
    try testing.expectEqual(@as(u64, 2), out[0].int);
    try testing.expectEqualStrings("Linus", out[1].bytes);
    try testing.expectEqual(@as(u64, 54), out[2].int);
    w.deinit();
}

test "typed update on a stale version does not free the old blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_stale.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    // stale-version update must NOT free the old blob (conflict path)
    const conflict = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "X" } }, ver + 1);
    try testing.expect(conflict == .conflict);
    _ = (try getTyped(&w, cat, 1, &out)).?;
    try testing.expectEqualStrings("short", out[1].bytes);
    w.deinit();
}

test "typed update replaces a string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_replace.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const ver = (try getTyped(&w, cat, 1, &out)).?;
    const ures = try updateTyped(&w, cat, 1, &.{ .{ .int = 1 }, .{ .bytes = "a much longer value" } }, ver);
    cat = ures.ok.cat;
    _ = try getTyped(&w, cat, 1, &out);
    try testing.expectEqualStrings("a much longer value", out[1].bytes);
    w.deinit();
}

test "typed delete removes the row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str2_delete.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try createTyped(&w, &.{ .int, .blob });
    cat = (try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "short" } })).cat;
    var out: [2]Value = undefined;
    const v2 = (try getTyped(&w, cat, 1, &out)).?;
    const dres = try deleteTyped(&w, cat, 1, v2);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getTyped(&w, cat, 1, &out));
    w.deinit();
}

test "strings persist across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "str3.airdb");
    defer testing.allocator.free(path);
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try createTyped(&w, &.{ .int, .blob });
        var i: u64 = 0;
        var buf: [32]u8 = undefined;
        while (i < 500) : (i += 1) {
            const s = try std.fmt.bufPrint(&buf, "name-{d}", .{i});
            cat = (try insertTyped(&w, cat, &.{ .{ .int = i }, .{ .bytes = s } })).cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        var out: [2]Value = undefined;
        _ = (try getTyped(&r, r.root(), 321, &out)).?;
        try testing.expectEqualStrings("name-321", out[1].bytes);
        r.end();
    }
}

test "getByObjectKey reads a row by its stable object key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "okey.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    const r0 = try insert(&w, cat, &.{ 100, 7 });
    cat = r0.cat;
    const r1 = try insert(&w, cat, &.{ 200, 8 });
    cat = r1.cat;
    var out: [2]u64 = undefined;
    const v1 = try getByObjectKey(&w, cat, r1.row, &out);
    try testing.expect(v1 != null);
    try testing.expectEqual(@as(u64, 200), out[0]);
    try testing.expectEqual(@as(u64, 8), out[1]);
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, 999, &out));
    const vk = (try getByObjectKey(&w, cat, r0.row, &out)).?;
    const dres = try delete(&w, cat, 100, vk);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getByObjectKey(&w, cat, r0.row, &out));
    w.deinit();
}
