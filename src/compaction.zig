const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");
const blob = @import("blob.zig");
const links = @import("links.zig");

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

// Deep-copy a single property value from the source db into the destination db.
// kind/elem describe the property. Returns the destination-local raw u64.
fn copyValue(src: anytype, dst: *WriteTxn, kind: catalog.PropKind, elem: catalog.ElemKind, src_raw: u64) !u64 {
    return switch (kind) {
        .int, .link => src_raw, // verbatim (a link stores an object key, preserved)
        .blob => if (src_raw == 0) 0 else try blob.put(dst, try blob.get(src, src_raw)),
        .list => blk: {
            var newc = try Column.create(dst);
            const n = try Column.len(src, src_raw);
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const el = try Column.get(src, src_raw, i);
                const dv = if (elem == .blob) (if (el == 0) @as(u64, 0) else try blob.put(dst, try blob.get(src, el))) else el;
                newc = try Column.append(dst, newc, dv);
            }
            break :blk newc;
        },
        .set, .link_set => blk: {
            var newi = try Index.create(dst);
            const Sink = struct {
                idx: *Ref,
                dstp: *WriteTxn,
                fn onKey(self: @This(), key: u64) !void {
                    self.idx.* = try Index.insert(self.dstp, self.idx.*, key, 1);
                }
            };
            try Index.forEachKey(src, src_raw, Sink{ .idx = &newi, .dstp = dst }, Sink.onKey);
            break :blk newi;
        },
    };
}

// Copy all live rows of `src_cat` (in the source db) into a fresh catalog in the
// destination db, preserving object keys, primary keys, and next_key. Backlink
// indexes are created empty (rebuild with rebuildBacklinks afterward). Returns
// the new destination catalog ref.
pub fn copyTypeRows(src: anytype, src_cat: Ref, dst: *WriteTxn) !Ref {
    const sv = try catalog.loadCatalog(src, src_cat);
    const pc = sv.prop_count;
    const next_key = sv.next_key;
    var s_prop: [catalog.max_prop_count]Ref = undefined;
    var kinds: [catalog.max_prop_count]catalog.PropKind = undefined;
    var elems: [catalog.max_prop_count]catalog.ElemKind = undefined;
    var targets: [catalog.max_prop_count]u16 = undefined;
    var rules: [catalog.max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            s_prop[j] = sv.propColRef(j);
            kinds[j] = sv.kind(j);
            elems[j] = sv.elemKind(j);
            targets[j] = sv.linkTarget(j);
            rules[j] = sv.delRule(j);
        }
    }
    const s_ver = sv.version_col_ref;
    const s_live = sv.live_col_ref;
    const s_keyrow = sv.keyrow_index_ref;

    // Collect live (okey, src_row) pairs.
    const alloc = dst.db.store.allocator;
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(alloc);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), k: u64, val: u64) !void {
            try self.list.append(self.a, .{ .okey = k, .row = val });
        }
    };
    try Index.forEachEntry(src, s_keyrow, Collector{ .list = &pairs, .a = alloc }, Collector.onEntry);

    // Fresh destination structures.
    var d_prop: [catalog.max_prop_count]Ref = undefined;
    var d_bl: [catalog.max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            d_prop[j] = try Column.create(dst);
            d_bl[j] = if (kinds[j] == .link or kinds[j] == .link_set) try Index.create(dst) else 0;
        }
    }
    var d_ver = try Column.create(dst);
    var d_live = try Column.create(dst);
    var d_keyrow = try Index.create(dst);
    var d_pk = try Index.create(dst);

    var d_row: u64 = 0;
    for (pairs.items) |pr| {
        if ((try Column.get(src, s_live, pr.row)) == 0) continue; // defensive
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const sraw = try Column.get(src, s_prop[j], pr.row);
            const draw = try copyValue(src, dst, kinds[j], elems[j], sraw);
            d_prop[j] = try Column.append(dst, d_prop[j], draw);
        }
        const ver = try Column.get(src, s_ver, pr.row);
        d_ver = try Column.append(dst, d_ver, ver);
        d_live = try Column.append(dst, d_live, 1);
        d_keyrow = try Index.insert(dst, d_keyrow, pr.okey, d_row);
        const pk = try Column.get(src, s_prop[0], pr.row);
        d_pk = try Index.insert(dst, d_pk, pk, pr.okey);
        d_row += 1;
    }

    return catalog.writeCatalog(dst, pc, d_row, d_keyrow, next_key, d_pk, d_ver, d_live, d_prop[0..pc], kinds[0..pc], elems[0..pc], d_bl[0..pc], targets[0..pc], rules[0..pc]);
}

// Rebuild backlink indexes for `cat` (in dst) from its copied forward links.
pub fn rebuildBacklinks(dst: *WriteTxn, cat: Ref) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(dst, cat);
    const pc = v0.prop_count;
    const alloc = dst.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const k = (try catalog.loadCatalog(dst, cur)).kind(p);
        if (k != .link and k != .link_set) continue;
        // collect (okey,row) of cur
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(alloc);
        const C = struct {
            list: *std.ArrayList(Pair),
            a: std.mem.Allocator,
            fn onEntry(self: @This(), kk: u64, vv: u64) !void {
                try self.list.append(self.a, .{ .okey = kk, .row = vv });
            }
        };
        {
            const vv = try catalog.loadCatalog(dst, cur);
            try Index.forEachEntry(dst, vv.keyrow_index_ref, C{ .list = &pairs, .a = alloc }, C.onEntry);
        }
        for (pairs.items) |pr| {
            const vv = try catalog.loadCatalog(dst, cur);
            const col = vv.propColRef(p);
            const raw = try Column.get(dst, col, pr.row);
            if (k == .link) {
                if (raw != 0) cur = try links.addBacklink(dst, cur, p, raw - 1, pr.okey);
            } else {
                // link_set: the column holds a set-root of target okeys
                var members = std.ArrayList(u64).empty;
                defer members.deinit(alloc);
                const M = struct {
                    list: *std.ArrayList(u64),
                    a: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.a, key);
                    }
                };
                try Index.forEachKey(dst, raw, M{ .list = &members, .a = alloc }, M.onKey);
                for (members.items) |t| cur = try links.addBacklink(dst, cur, p, t, pr.okey);
            }
        }
    }
    return cur;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const objects = @import("objects.zig");
const collections = @import("collections.zig");

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

test "all value kinds deep-copy across databases preserving keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "src.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "dst.airdb");
    defer testing.allocator.free(dst_path);

    var src_db = try Db.create(testing.allocator, src_path);
    defer src_db.deinit();
    var dst_db = try Db.create(testing.allocator, dst_path);
    defer dst_db.deinit();

    var pk1_okey: u64 = undefined;
    var src_next_key: u64 = undefined;

    // Build the source database: 3 rows across every value kind, then delete one.
    {
        var w = try src_db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .blob },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .link, .link_target = 0 },
        });
        const r1 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 1 }, .{ .bytes = "a" }, .{ .list_int = &.{ 10, 20 } }, .{ .set_int = &.{ 5, 6 } }, .{ .link = null },
        });
        cat = r1.cat;
        pk1_okey = r1.row;
        const r2 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 2 }, .{ .bytes = "bb" }, .{ .list_int = &.{} }, .{ .set_int = &.{7} }, .{ .link = pk1_okey },
        });
        cat = r2.cat;
        const r3 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 3 }, .{ .bytes = "ccc" }, .{ .list_int = &.{ 1, 2, 3 } }, .{ .set_int = &.{} }, .{ .link = null },
        });
        cat = r3.cat;

        // Delete pk 3 -- leaves a gap in the source.
        var dout: [5]catalog.Value = undefined;
        const v3 = (try objects.getTyped(&w, cat, 3, &dout)).?;
        cat = (try objects.deleteTyped(&w, cat, 3, v3)).ok;

        src_next_key = (try catalog.loadCatalog(&w, cat)).next_key;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // Deep-copy the live rows into the destination database.
    {
        var src_read = try src_db.beginRead();
        const src_cat = src_read.root();
        var dst_w = try dst_db.beginWrite();
        var dst_cat = try copyTypeRows(&src_read, src_cat, &dst_w);
        dst_cat = try rebuildBacklinks(&dst_w, dst_cat);
        dst_w.setRoot(dst_cat);
        _ = try dst_w.commit();
        src_read.end();
    }

    // Reopen the destination and verify every value kind round-tripped.
    {
        var ddb = try Db.open(testing.allocator, dst_path);
        defer ddb.deinit();
        var r = try ddb.beginRead();
        defer r.end();
        const cat = r.root();

        // pk 1 and pk 2 readable with identical int + blob.
        var o1: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 1, &o1)) != null);
        try testing.expectEqual(@as(u64, 1), o1[0].int);
        try testing.expectEqualStrings("a", o1[1].bytes);
        var o2: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 2, &o2)) != null);
        try testing.expectEqual(@as(u64, 2), o2[0].int);
        try testing.expectEqualStrings("bb", o2[1].bytes);

        // list/set contents match.
        try testing.expectEqual(@as(?u64, 2), try collections.listLen(&r, cat, 1, 2));
        try testing.expectEqual(@as(u64, 10), try collections.listGetInt(&r, cat, 1, 2, 0));
        try testing.expectEqual(@as(u64, 20), try collections.listGetInt(&r, cat, 1, 2, 1));
        try testing.expectEqual(@as(?u64, 2), try collections.setCountInt(&r, cat, 1, 3));
        try testing.expect(try collections.setContainsInt(&r, cat, 1, 3, 5));
        try testing.expect(try collections.setContainsInt(&r, cat, 1, 3, 6));
        try testing.expectEqual(@as(?u64, 0), try collections.listLen(&r, cat, 2, 2));
        try testing.expectEqual(@as(?u64, 1), try collections.setCountInt(&r, cat, 2, 3));
        try testing.expect(try collections.setContainsInt(&r, cat, 2, 3, 7));

        // The link on pk 2 still equals pk 1's original object key and resolves to pk 1.
        try testing.expectEqual(@as(?u64, pk1_okey), try links.getLink(&r, cat, 2, 4));
        var ob: [5]u64 = undefined;
        try testing.expect((try objects.getByObjectKey(&r, cat, pk1_okey, &ob)) != null);
        try testing.expectEqual(@as(u64, 1), ob[0]);

        // Backlink rebuilt from the copied forward link.
        try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&r, cat, 4, pk1_okey));

        // pk 3 was dead in the source and must be absent.
        var o3: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 3, &o3)) == null);

        // next_key preserved across the copy.
        try testing.expectEqual(src_next_key, (try catalog.loadCatalog(&r, cat)).next_key);
    }
}
