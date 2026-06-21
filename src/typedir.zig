// typedir.zig -- type directory node mapping type ids to catalog refs.
//
// Node layout: [type_count u16 LE @0][type_count * (catalog_ref u64 LE) @2]
// dirSize(tc) = 2 + tc * 8

const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Objects = @import("objects.zig");
const catalog = @import("catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");

pub const Schema = []const []const catalog.PropKind;
// Full schema: each type is a slice of PropDefs, so a multi-type directory can
// hold link and collection properties (not just scalar kinds).
pub const DefSchema = []const []const catalog.PropDef;
pub const Value = catalog.Value;
const PropKind = catalog.PropKind;
const PropDef = catalog.PropDef;

fn dirSize(tc: u16) usize {
    return 2 + @as(usize, tc) * 8;
}

// Pack `tc` catalog refs into a fresh directory node.
fn writeDir(txn: *WriteTxn, cat_refs: []const Ref) !Ref {
    const tc: u16 = @intCast(cat_refs.len);
    const a = try txn.alloc(dirSize(tc));
    std.mem.writeInt(u16, a.bytes[0..2], tc, .little);
    for (cat_refs, 0..) |cref, i| {
        std.mem.writeInt(u64, a.bytes[2 + i * 8 ..][0..8], cref, .little);
    }
    return a.ref;
}

// Create a directory from a full PropDef schema (supports links/collections).
pub fn createWithDefs(txn: *WriteTxn, schema: DefSchema) !Ref {
    std.debug.assert(schema.len <= 256);
    var cat_refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) cat_refs[t] = try catalog.createDefs(txn, schema[t]);
    return writeDir(txn, cat_refs[0..schema.len]);
}

// Scalar-kinds convenience: each property gets elem = int.
pub fn create(txn: *WriteTxn, schema: Schema) !Ref {
    std.debug.assert(schema.len <= 256);
    var cat_refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) {
        cat_refs[t] = try catalog.createTyped(txn, schema[t]);
    }
    return writeDir(txn, cat_refs[0..schema.len]);
}

fn loadDir(txn: anytype, dir: Ref) !struct { type_count: u16, bytes: []const u8 } {
    const tc_bytes = try txn.deref(dir, 2);
    const type_count = std.mem.readInt(u16, tc_bytes[0..2], .little);
    const bytes = try txn.deref(dir, dirSize(type_count));
    return .{ .type_count = type_count, .bytes = bytes };
}

pub fn typeCount(txn: anytype, dir: Ref) !u16 {
    const d = try loadDir(txn, dir);
    return d.type_count;
}

pub fn catalogRef(txn: anytype, dir: Ref, type_id: u16) !Ref {
    const d = try loadDir(txn, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    return std.mem.readInt(u64, d.bytes[2 + @as(usize, type_id) * 8 ..][0..8], .little);
}

pub fn setCatalogRef(txn: *WriteTxn, dir: Ref, type_id: u16, new_cat: Ref) !Ref {
    const d = try loadDir(txn, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    const a = try txn.writableCopy(dir, dirSize(d.type_count));
    std.mem.writeInt(u64, a.bytes[2 + @as(usize, type_id) * 8 ..][0..8], new_cat, .little);
    return a.ref;
}

// Append an already-created catalog to the directory; returns grown dir + id.
fn appendCatalog(txn: *WriteTxn, old_refs: []const Ref, new_cat: Ref) !Ref {
    const old_tc = old_refs.len;
    var refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < old_tc) : (t += 1) refs[t] = old_refs[t];
    refs[old_tc] = new_cat;
    return writeDir(txn, refs[0 .. old_tc + 1]);
}

// Snapshot existing catalog refs (before any file-growing create call).
fn snapshotRefs(txn: anytype, dir: Ref, out: *[256]Ref) !u16 {
    const d = try loadDir(txn, dir);
    var t: usize = 0;
    while (t < d.type_count) : (t += 1) {
        out[t] = std.mem.readInt(u64, d.bytes[2 + t * 8 ..][0..8], .little);
    }
    return d.type_count;
}

// Append a new type from a full PropDef schema (supports links/collections).
pub fn addTypeDefs(txn: *WriteTxn, dir: Ref, defs: []const PropDef) !struct { dir: Ref, type_id: u16 } {
    var old_refs: [256]Ref = undefined;
    const old_tc = try snapshotRefs(txn, dir, &old_refs);
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createDefs(txn, defs);
    const new_dir = try appendCatalog(txn, old_refs[0..old_tc], new_cat);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Append a new object type to the directory and return the grown directory ref
// plus the new type id. The new type's catalog is created from `type_schema`.
pub fn addType(txn: *WriteTxn, dir: Ref, type_schema: []const PropKind) !struct { dir: Ref, type_id: u16 } {
    // Capture existing catalog refs before createTyped, which can grow the file
    // and invalidate the directory deref slice.
    var old_refs: [256]Ref = undefined;
    const old_tc = blk: {
        const d = try loadDir(txn, dir);
        var t: usize = 0;
        while (t < d.type_count) : (t += 1) {
            old_refs[t] = std.mem.readInt(u64, d.bytes[2 + t * 8 ..][0..8], .little);
        }
        break :blk d.type_count;
    };
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createTyped(txn, type_schema);
    const new_tc: u16 = old_tc + 1;
    const a = try txn.alloc(dirSize(new_tc));
    std.mem.writeInt(u16, a.bytes[0..2], new_tc, .little);
    var t: usize = 0;
    while (t < old_tc) : (t += 1) {
        std.mem.writeInt(u64, a.bytes[2 + t * 8 ..][0..8], old_refs[t], .little);
    }
    std.mem.writeInt(u64, a.bytes[2 + @as(usize, old_tc) * 8 ..][0..8], new_cat, .little);
    return .{ .dir = a.ref, .type_id = old_tc };
}

pub fn validate(txn: anytype, dir: Ref, expected: Schema) !void {
    const tc = try typeCount(txn, dir);
    if (tc != expected.len) return error.SchemaMismatch;
    var t: u16 = 0;
    while (t < tc) : (t += 1) {
        const v = try catalog.loadCatalog(txn, try catalogRef(txn, dir, t));
        if (v.prop_count != expected[t].len) return error.SchemaMismatch;
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            if (v.kind(j) != expected[t][j]) return error.SchemaMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// Routing wrappers: read catalog ref for the type, do the op, COW the directory
// ---------------------------------------------------------------------------

pub const UpdateOk = struct { dir: Ref, version: u64 };
pub const UpdateResult = union(enum) { ok: UpdateOk, conflict: Objects.Conflict, not_found };
pub const DeleteResult = union(enum) { ok: Ref, conflict: Objects.Conflict, not_found };

pub fn insert(txn: *WriteTxn, dir: Ref, type_id: u16, values: []const Value) !struct { dir: Ref, row: u64 } {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.insertTyped(txn, cat, values);
    const new_dir = try setCatalogRef(txn, dir, type_id, r.cat);
    return .{ .dir = new_dir, .row = r.row };
}

pub fn get(txn: anytype, dir: Ref, type_id: u16, pk: u64, out: []Value) !?u64 {
    return Objects.getTyped(txn, try catalogRef(txn, dir, type_id), pk, out);
}

pub fn update(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, values: []const Value, expected_version: u64) !UpdateResult {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.updateTyped(txn, cat, pk, values, expected_version);
    return switch (r) {
        .ok => |o| .{ .ok = .{ .dir = try setCatalogRef(txn, dir, type_id, o.cat), .version = o.version } },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

pub fn delete(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, expected_version: u64) !DeleteResult {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.deleteTyped(txn, cat, pk, expected_version);
    return switch (r) {
        .ok => |c| .{ .ok = try setCatalogRef(txn, dir, type_id, c) },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

pub fn liveCount(txn: anytype, dir: Ref, type_id: u16) !u64 {
    return catalog.liveCount(txn, try catalogRef(txn, dir, type_id));
}

// --- link / to-many routing (mutators COW the directory) ---

pub fn getLink(txn: anytype, dir: Ref, type_id: u16, pk: u64, prop: usize) !?u64 {
    return links.getLink(txn, try catalogRef(txn, dir, type_id), pk, prop);
}

pub fn setLink(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: ?u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.setLink(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn backlinkCount(txn: anytype, dir: Ref, type_id: u16, prop: usize, target: u64) !u64 {
    return links.backlinkCount(txn, try catalogRef(txn, dir, type_id), prop, target);
}

pub fn linkSetAdd(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.linkSetAdd(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn linkSetRemove(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.linkSetRemove(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn linkSetContains(txn: anytype, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !bool {
    return links.linkSetContains(txn, try catalogRef(txn, dir, type_id), pk, prop, target);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tdTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "create builds a directory with one catalog per type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const schema = [_][]const catalog.PropKind{
        &.{ .int, .blob },
        &.{ .int, .int, .int },
    };
    const dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    const c0 = try catalogRef(&w, dir, 0);
    const c1 = try catalogRef(&w, dir, 1);
    try testing.expect(c0 != 0 and c1 != 0 and c0 != c1);
    try testing.expectEqual(@as(catalog.PropCount, 2), (try catalog.loadCatalog(&w, c0)).prop_count);
    try testing.expectEqual(@as(catalog.PropCount, 3), (try catalog.loadCatalog(&w, c1)).prop_count);
    w.deinit();
}

test "catalogRef rejects an out-of-range type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td1b.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const schema = [_][]const catalog.PropKind{&.{ .int, .int }};
    const dir = try create(&w, &schema);
    try testing.expectError(error.NoSuchType, catalogRef(&w, dir, 5));
    w.deinit();
}

test "validate accepts a matching schema and rejects a mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td2.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const catalog.PropKind{ &.{ .int, .blob }, &.{ .int, .int, .int } };
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        const dir = try create(&w, &schema);
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try validate(&r, r.root(), &schema); // matches
        const fewer = [_][]const catalog.PropKind{&.{ .int, .blob }};
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &fewer));
        const wrong_kind = [_][]const catalog.PropKind{ &.{ .int, .int }, &.{ .int, .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrong_kind));
        const wrong_count = [_][]const catalog.PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrong_count));
        r.end();
    }
}

test "two types route independently through the directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const schema = [_][]const PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
    var dir = try create(&w, &schema);

    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "Ada" } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .int = 42 } })).dir;

    var out0: [2]Value = undefined;
    _ = (try get(&w, dir, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    var out1: [2]Value = undefined;
    const ver1 = (try get(&w, dir, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 42), out1[1].int);

    const ur = try update(&w, dir, 1, 1, &.{ .{ .int = 1 }, .{ .int = 99 } }, ver1);
    dir = ur.ok.dir;
    _ = (try get(&w, dir, 1, 1, &out1)).?;
    try testing.expectEqual(@as(u64, 99), out1[1].int);
    _ = (try get(&w, dir, 0, 1, &out0)).?;
    try testing.expectEqualStrings("Ada", out0[1].bytes);

    // delete type 0's row
    const v0 = (try get(&w, dir, 0, 1, &out0)).?;
    const dr = try delete(&w, dir, 0, 1, v0);
    dir = dr.ok;
    try testing.expectEqual(@as(?u64, null), try get(&w, dir, 0, 1, &out0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1)); // type 1 unaffected
    w.deinit();
}

test "multiple types persist across reopen and validate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td4.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var dir = try create(&w, &schema);
        var i: u64 = 0;
        var buf: [16]u8 = undefined;
        while (i < 300) : (i += 1) {
            const s = try std.fmt.bufPrint(&buf, "p{d}", .{i});
            dir = (try insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } })).dir;
            dir = (try insert(&w, dir, 1, &.{ .{ .int = i }, .{ .int = i * 10 } })).dir;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try validate(&r, r.root(), &schema);
        try testing.expectEqual(@as(u64, 300), try liveCount(&r, r.root(), 0));
        try testing.expectEqual(@as(u64, 300), try liveCount(&r, r.root(), 1));
        var out0: [2]Value = undefined;
        _ = (try get(&r, r.root(), 0, 250, &out0)).?;
        try testing.expectEqualStrings("p250", out0[1].bytes);
        var out1: [2]Value = undefined;
        _ = (try get(&r, r.root(), 1, 250, &out1)).?;
        try testing.expectEqual(@as(u64, 2500), out1[1].int);
        r.end();
    }
}

test "addType grows the directory and routes the new type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const schema = [_][]const PropKind{&.{ .int, .blob }};
    var dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 1), try typeCount(&w, dir));
    const added = try addType(&w, dir, &.{ .int, .int, .int });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 1), added.type_id);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    // old type still works; new type accepts rows
    dir = (try insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = "x" } })).dir;
    dir = (try insert(&w, dir, 1, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } })).dir;
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 0));
    try testing.expectEqual(@as(u64, 1), try liveCount(&w, dir, 1));
    var out: [3]Value = undefined;
    _ = (try get(&w, dir, 1, 1, &out)).?;
    try testing.expectEqual(@as(u64, 3), out[2].int);
    w.deinit();
}

test "multi-type directory carries links and collections via createWithDefs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td6.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const PD = catalog.PropDef;
    // type 0: scalar (int pk, blob name); type 1: int pk + a to-one link + a to-many link_set
    const schema = [_][]const PD{
        &.{ .{ .kind = .int }, .{ .kind = .blob } },
        &.{ .{ .kind = .int }, .{ .kind = .link }, .{ .kind = .link_set } },
    };
    var dir = try createWithDefs(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));

    // insert two type-1 rows; row a links to nothing, b's set links to a.
    const a = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 10 }, .{ .link = null }, .{ .link_set = &.{} } });
    dir = try setCatalogRef(&w, dir, 1, a.cat);
    const b = try Objects.insertTyped(&w, try catalogRef(&w, dir, 1), &.{ .{ .int = 20 }, .{ .link = a.row }, .{ .link_set = &.{a.row} } });
    dir = try setCatalogRef(&w, dir, 1, b.cat);

    // route a to-many add through the directory
    dir = try linkSetAdd(&w, dir, 1, 20, 2, a.row); // already member -> no-op
    try testing.expect(try linkSetContains(&w, dir, 1, 20, 2, a.row));
    try testing.expectEqual(@as(?u64, a.row), try getLink(&w, dir, 1, 20, 1));
    // a has 2 inbound to-one? no: only b's to-one links a -> backlink on prop 1 == 1
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, dir, 1, 1, a.row));

    // addTypeDefs: append a type with a list property
    const added = try addTypeDefs(&w, dir, &.{ .{ .kind = .int }, .{ .kind = .list, .elem = .int } });
    dir = added.dir;
    try testing.expectEqual(@as(u16, 2), added.type_id);
    dir = (try insert(&w, dir, 2, &.{ .{ .int = 1 }, .{ .list_int = &.{ 7, 8, 9 } } })).dir;
    try testing.expectEqual(@as(?u64, 3), try collections.listLen(&w, try catalogRef(&w, dir, 2), 1, 1));
    w.deinit();
}
