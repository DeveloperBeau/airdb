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

pub const Schema = []const []const Objects.PropKind;
pub const Value = Objects.Value;
const PropKind = Objects.PropKind;

fn dirSize(tc: u16) usize {
    return 2 + @as(usize, tc) * 8;
}

pub fn create(txn: *WriteTxn, schema: Schema) !Ref {
    std.debug.assert(schema.len <= 256);
    var cat_refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) {
        cat_refs[t] = try Objects.createTyped(txn, schema[t]);
    }
    const tc: u16 = @intCast(schema.len);
    const a = try txn.alloc(dirSize(tc));
    std.mem.writeInt(u16, a.bytes[0..2], tc, .little);
    var i: usize = 0;
    while (i < schema.len) : (i += 1) {
        std.mem.writeInt(u64, a.bytes[2 + i * 8 ..][0..8], cat_refs[i], .little);
    }
    return a.ref;
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

pub fn validate(txn: anytype, dir: Ref, expected: Schema) !void {
    const tc = try typeCount(txn, dir);
    if (tc != expected.len) return error.SchemaMismatch;
    var t: u16 = 0;
    while (t < tc) : (t += 1) {
        const v = try Objects.loadCatalog(txn, try catalogRef(txn, dir, t));
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
    return Objects.liveCount(txn, try catalogRef(txn, dir, type_id));
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
    const schema = [_][]const Objects.PropKind{
        &.{ .int, .blob },
        &.{ .int, .int, .int },
    };
    const dir = try create(&w, &schema);
    try testing.expectEqual(@as(u16, 2), try typeCount(&w, dir));
    const c0 = try catalogRef(&w, dir, 0);
    const c1 = try catalogRef(&w, dir, 1);
    try testing.expect(c0 != 0 and c1 != 0 and c0 != c1);
    try testing.expectEqual(@as(Objects.PropCount, 2), (try Objects.loadCatalog(&w, c0)).prop_count);
    try testing.expectEqual(@as(Objects.PropCount, 3), (try Objects.loadCatalog(&w, c1)).prop_count);
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
    const schema = [_][]const Objects.PropKind{&.{ .int, .int }};
    const dir = try create(&w, &schema);
    try testing.expectError(error.NoSuchType, catalogRef(&w, dir, 5));
    w.deinit();
}

test "validate accepts a matching schema and rejects a mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tdTmpPath(testing.allocator, &tmp, "td2.airdb");
    defer testing.allocator.free(path);
    const schema = [_][]const Objects.PropKind{ &.{ .int, .blob }, &.{ .int, .int, .int } };
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
        const fewer = [_][]const Objects.PropKind{&.{ .int, .blob }};
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &fewer));
        const wrong_kind = [_][]const Objects.PropKind{ &.{ .int, .int }, &.{ .int, .int, .int } };
        try testing.expectError(error.SchemaMismatch, validate(&r, r.root(), &wrong_kind));
        const wrong_count = [_][]const Objects.PropKind{ &.{ .int, .blob }, &.{ .int, .int } };
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
