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
