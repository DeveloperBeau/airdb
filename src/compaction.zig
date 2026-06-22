const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");

const max_prop_count = catalog.max_prop_count;

const Pair = struct { okey: u64, row: u64 };

pub fn liveCount(txn: anytype, cat: Ref) !u64 {
    const v = try catalog.loadCatalog(txn, cat);
    return Index.count(txn, v.keyrow_index_ref);
}

pub fn shouldCompact(txn: anytype, cat: Ref) !bool {
    const v = try catalog.loadCatalog(txn, cat);
    const n = v.next_row;
    if (n == 0) return false;
    const live = try Index.count(txn, v.keyrow_index_ref);
    return (n - live) * 2 > n; // more than half the rows are dead
}

// Rebuild the type's columns to contain only live rows, packed densely, and
// remap the key->row index. Object keys, pk index, and backlink indexes are
// preserved (keyed by object key). Returns the new catalog ref.
pub fn compactType(txn: *WriteTxn, cat: Ref) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_key = v.next_key;
    const pk_index_ref = v.pk_index_ref;
    const old_ver = v.version_col_ref;
    const old_live = v.live_col_ref;
    const old_keyrow = v.keyrow_index_ref;
    var old_prop: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]catalog.PropKind = undefined;
    var elems: [max_prop_count]catalog.ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            old_prop[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
        }
    }
    const alloc = txn.db.store.allocator;
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(alloc);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: u64, val: u64) !void {
            try self.list.append(self.alloc, .{ .okey = key, .row = val });
        }
    };
    try Index.forEachEntry(txn, old_keyrow, Collector{ .list = &pairs, .alloc = alloc }, Collector.onEntry);

    // Build fresh dense columns.
    var new_prop: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) new_prop[j] = try Column.create(txn);
    }
    var new_ver = try Column.create(txn);
    var new_live = try Column.create(txn);
    var new_keyrow = try Index.create(txn);

    var new_row: u64 = 0;
    for (pairs.items) |pr| {
        // defensive live check (delete already drops dead keys from keyrow)
        if ((try Column.get(txn, old_live, pr.row)) == 0) continue;
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const cell = try Column.get(txn, old_prop[j], pr.row);
            new_prop[j] = try Column.append(txn, new_prop[j], cell);
        }
        const ver = try Column.get(txn, old_ver, pr.row);
        new_ver = try Column.append(txn, new_ver, ver);
        new_live = try Column.append(txn, new_live, 1);
        new_keyrow = try Index.insert(txn, new_keyrow, pr.okey, new_row);
        new_row += 1;
    }

    return catalog.writeCatalog(txn, pc, new_row, new_keyrow, next_key, pk_index_ref, new_ver, new_live, new_prop[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets[0..pc], rules[0..pc]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const objects = @import("objects.zig");
const links = @import("links.zig");

fn cmpTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "compactType packs live rows and drops dead ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "pack.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var pk: u64 = 0;
    while (pk < 10) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{ pk, pk * 10 });
        cat = r.cat;
    }

    for ([_]u64{ 2, 5, 8 }) |dpk| {
        var out: [2]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, dpk, &out)).?;
        cat = switch (try objects.delete(&w, cat, dpk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    cat = try compactType(&w, cat);

    try testing.expectEqual(@as(u64, 7), (try catalog.loadCatalog(&w, cat)).next_row);
    try testing.expectEqual(@as(u64, 7), try liveCount(&w, cat));

    pk = 0;
    while (pk < 10) : (pk += 1) {
        var out: [2]u64 = undefined;
        const got = try objects.getByPk(&w, cat, pk, &out);
        if (pk == 2 or pk == 5 or pk == 8) {
            try testing.expect(got == null);
        } else {
            try testing.expect(got != null);
            try testing.expectEqual(pk * 10, out[1]);
        }
    }
}

test "object keys and links survive compaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "links.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });

    const a = try objects.insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const a_okey = a.row;
    const b = try objects.insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = null } });
    cat = b.cat;
    const c = try objects.insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = a_okey } });
    cat = c.cat;

    // delete B (pk 2) -- creates a hole
    var out: [2]u64 = undefined;
    const ver = (try objects.getByPk(&w, cat, 2, &out)).?;
    cat = switch (try objects.delete(&w, cat, 2, ver)) {
        .ok => |x| x,
        else => unreachable,
    };

    cat = try compactType(&w, cat);

    // C still links to A by object key
    try testing.expectEqual(a_okey, (try links.getLink(&w, cat, 3, 1)).?);
    // A is still resolvable by its object key
    var ao: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, a_okey, &ao)) != null);
    try testing.expectEqual(@as(u64, 1), ao[0]);
    // backlink from C -> A survived
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, cat, 1, a_okey));
}

test "shouldCompact reflects dead ratio" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "ratio.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 1);
    var pk: u64 = 0;
    while (pk < 10) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{pk});
        cat = r.cat;
    }
    try testing.expect(!(try shouldCompact(&w, cat)));

    pk = 0;
    while (pk < 6) : (pk += 1) {
        var out: [1]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, pk, &out)).?;
        cat = switch (try objects.delete(&w, cat, pk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }
    try testing.expect(try shouldCompact(&w, cat));
}

test "compaction reclaims under churn (scale)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "scale.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    const n: u64 = 200_000;
    var cat = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const r = try objects.insert(&w, cat, &.{ i, i });
        cat = r.cat;
    }

    // delete every even pk; all rows carry version == w.new_version this txn
    i = 0;
    while (i < n) : (i += 2) {
        cat = switch (try objects.delete(&w, cat, i, w.new_version)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    cat = try compactType(&w, cat);

    try testing.expectEqual(@as(u64, 100_000), (try catalog.loadCatalog(&w, cat)).next_row);
    try testing.expectEqual(@as(u64, 100_000), try liveCount(&w, cat));

    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByPk(&w, cat, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 99_999, &out)) != null);
    try testing.expectEqual(@as(u64, 99_999), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 100_001, &out)) != null);
    try testing.expectEqual(@as(u64, 100_001), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 2, &out)) == null);
}
