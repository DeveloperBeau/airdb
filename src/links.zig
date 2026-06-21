const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

// ---------------------------------------------------------------------------
// Links and backlinks
//
// A `link` property stores `target_okey + 1` in its column (0 = null). For each
// link property the catalog holds a backlink index: target_okey -> set_root,
// where set_root is an index of source_okey -> 1. The backlink index is updated
// transactionally on every insert, set, clear, and delete.
// ---------------------------------------------------------------------------

// Add `source` to the backlink set for `target`, returning the new backlink ref.
fn blAdd(txn: *WriteTxn, bl_ref: Ref, target: u64, source: u64) !Ref {
    const existing = try Index.get(txn, bl_ref, target);
    var set_root = existing orelse try Index.create(txn);
    set_root = try Index.insert(txn, set_root, source, 1);
    return try Index.insert(txn, bl_ref, target, set_root);
}

// Remove `source` from the backlink set for `target`. No-op if absent.
fn blRemove(txn: *WriteTxn, bl_ref: Ref, target: u64, source: u64) !Ref {
    const existing = try Index.get(txn, bl_ref, target);
    const set_root = existing orelse return bl_ref;
    const new_set = try Index.remove(txn, set_root, source);
    return try Index.insert(txn, bl_ref, target, new_set);
}

// Add source->target to link property p's backlink index. Returns new catalog.
pub fn addBacklink(txn: *WriteTxn, cat: Ref, p: usize, target: u64, source: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const new_bl = try blAdd(txn, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(txn, cat, p, new_bl);
}

// Remove source from link property p's backlink set for target.
fn removeBacklink(txn: *WriteTxn, cat: Ref, p: usize, target: u64, source: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const new_bl = try blRemove(txn, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(txn, cat, p, new_bl);
}

// Read the target okey of link property `prop` for the object with primary key
// `pk`. Returns null if the link is unset (or the object is absent).
pub fn getLink(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const raw = try Column.get(txn, r.prop_col, r.row);
    return if (raw == 0) null else raw - 1;
}

// Number of objects whose link property `prop` points at `target` okey.
pub fn backlinkCount(txn: anytype, cat: Ref, prop: usize, target: u64) !u64 {
    const v = try catalog.loadCatalog(txn, cat);
    const set_root = (try Index.get(txn, v.backlinkRef(prop), target)) orelse return 0;
    return try Index.count(txn, set_root);
}

// Collect the source okeys whose link property `prop` points at `target`.
pub fn backlinkCollect(
    txn: anytype,
    cat: Ref,
    prop: usize,
    target: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const v = try catalog.loadCatalog(txn, cat);
    const set_root = (try Index.get(txn, v.backlinkRef(prop), target)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Set or clear link property `prop` of the object with primary key `pk`.
// Maintains the backlink index and bumps the row version. No-op if unchanged.
pub fn setLink(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: ?u64) !Ref {
    const r0 = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return cat;
    const row = r0.row;
    const old_raw = try Column.get(txn, r0.prop_col, row);
    const old_target: ?u64 = if (old_raw == 0) null else old_raw - 1;
    if (old_target == target) return cat; // unchanged

    const new_raw: u64 = if (target) |t| t + 1 else 0;
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_raw);
    if (old_target) |ot| new_cat = try removeBacklink(txn, new_cat, prop, ot, row);
    if (target) |nt| new_cat = try addBacklink(txn, new_cat, prop, nt, row);
    return new_cat;
}

// ---------------------------------------------------------------------------
// To-many links (link_set): a set of target okeys with backlink maintenance.
// ---------------------------------------------------------------------------

pub fn linkSetCount(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try Index.count(txn, set_root);
}

pub fn linkSetContains(txn: anytype, cat: Ref, pk: u64, prop: usize, target: u64) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try Index.get(txn, set_root, target)) != null;
}

pub fn linkSetCollect(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Add `target` to the to-many link set of object `pk`; records the backlink.
// No-op if already a member.
pub fn linkSetAdd(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const row = r.row;
    const old_root = try Column.get(txn, r.prop_col, row);
    if ((try Index.get(txn, old_root, target)) != null) return cat; // already a member
    const new_root = try Index.insert(txn, old_root, target, 1);
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_root);
    new_cat = try addBacklink(txn, new_cat, prop, target, row);
    return new_cat;
}

// Remove `target` from the to-many link set of object `pk`; drops the backlink.
// No-op if not a member.
pub fn linkSetRemove(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)).?;
    const row = r.row;
    const old_root = try Column.get(txn, r.prop_col, row);
    if ((try Index.get(txn, old_root, target)) == null) return cat; // not a member
    const new_root = try Index.remove(txn, old_root, target);
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_root);
    new_cat = try removeBacklink(txn, new_cat, prop, target, row);
    return new_cat;
}

// Nullify every inbound link pointing at `okey` (and drop those backlink
// entries) for each link/link_set property, restricted to properties where
// `match_all` is true OR the property's link target type equals `target_type`.
// Returns the new catalog ref.
pub fn nullifyInboundInCatalog(txn: *WriteTxn, cat: Ref, okey: u64, target_type: u16, match_all: bool) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(txn, cat);
    const pc = v0.prop_count;
    const alloc = txn.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(txn, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;
        if (!match_all) {
            const vt = try catalog.loadCatalog(txn, cur);
            if (vt.linkTarget(p) != target_type) continue;
        }

        // Nullify inbound: snapshot the sources, then clear each one's link to
        // okey. For to-one, set the column to null; for to-many, remove okey
        // from the source's set.
        var sources = std.ArrayList(u64).empty;
        defer sources.deinit(alloc);
        try backlinkCollect(txn, cur, p, okey, &sources, alloc);
        for (sources.items) |src| {
            const vv = try catalog.loadCatalog(txn, cur);
            const col = vv.propColRef(p);
            // src is a source object key; resolve to its physical row for column access.
            const src_row = (try catalog.okeyToRow(txn, cur, src)).?;
            const new_col = if (kind == .link)
                try Column.set(txn, col, src_row, 0)
            else blk: {
                const src_set = try Column.get(txn, col, src_row);
                const new_set = try Index.remove(txn, src_set, okey);
                break :blk try Column.set(txn, col, src_row, new_set);
            };
            cur = try catalog.setPropColRef(txn, cur, p, new_col);
        }
        // Drop the whole backlink set for okey (its inbound links are now clear).
        {
            const vv = try catalog.loadCatalog(txn, cur);
            const empty = try Index.create(txn);
            const new_bl = try Index.insert(txn, vv.backlinkRef(p), okey, empty);
            cur = try catalog.setBacklinkRef(txn, cur, p, new_bl);
        }
    }
    return cur;
}

// Remove `okey`'s own outbound link entries from its targets' backlink sets for
// each link/link_set property. Returns the new catalog ref.
pub fn cleanOutboundInCatalog(txn: *WriteTxn, cat: Ref, okey: u64) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(txn, cat);
    const pc = v0.prop_count;
    const alloc = txn.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(txn, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;

        // Outbound: remove okey's own entries from its targets' backlink sets.
        // okey is an object key; resolve to the physical row to read its columns.
        const row = (try catalog.okeyToRow(txn, cur, okey)).?;
        if (kind == .link) {
            const vv2 = try catalog.loadCatalog(txn, cur);
            const out_raw = try Column.get(txn, vv2.propColRef(p), row);
            if (out_raw != 0) cur = try removeBacklink(txn, cur, p, out_raw - 1, okey);
        } else {
            // to-many: iterate the deleted row's set members.
            var members = std.ArrayList(u64).empty;
            defer members.deinit(alloc);
            {
                const vv2 = try catalog.loadCatalog(txn, cur);
                const set_root = try Column.get(txn, vv2.propColRef(p), row);
                const Sink = struct {
                    list: *std.ArrayList(u64),
                    alloc: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.alloc, key);
                    }
                };
                try Index.forEachKey(txn, set_root, Sink{ .list = &members, .alloc = alloc }, Sink.onKey);
            }
            for (members.items) |m| cur = try removeBacklink(txn, cur, p, m, okey);
        }
    }
    return cur;
}

// For each link property: (1) nullify every inbound link pointing at `okey`
// (and drop those backlink entries); (2) remove the deleted row's own outbound
// link entry from its target's backlink set. Returns the new catalog ref.
pub fn fixBacklinksForDelete(txn: *WriteTxn, cat: Ref, okey: u64) !Ref {
    const c1 = try nullifyInboundInCatalog(txn, cat, okey, 0, true);
    return try cleanOutboundInCatalog(txn, c1, okey);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const insertTyped = @import("objects.zig").insertTyped;
const getTyped = @import("objects.zig").getTyped;
const deleteTyped = @import("objects.zig").deleteTyped;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "insert stores a link and records the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .link } });
    const boss = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .bytes = "Boss" }, .{ .link = null } });
    cat = boss.cat;
    const rep = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .bytes = "Report" }, .{ .link = boss.row } });
    cat = rep.cat;
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 1, 2));
    try testing.expectEqual(@as(?u64, boss.row), try getLink(&w, cat, 2, 2));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 2, boss.row));
    var srcs = std.ArrayList(u64).empty;
    defer srcs.deinit(testing.allocator);
    try backlinkCollect(&w, cat, 2, boss.row, &srcs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), srcs.items.len);
    try testing.expectEqual(rep.row, srcs.items[0]);
    w.deinit();
}

test "setLink moves a link and updates both backlink sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_move.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = null } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = a.row } });
    cat = c.cat;
    cat = try setLink(&w, cat, 3, 1, b.row);
    try testing.expectEqual(@as(?u64, b.row), try getLink(&w, cat, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, cat, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, b.row));
    w.deinit();
}

test "setLink clearing a link drops the backlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link2_clear.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = null } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = b.row } });
    cat = c.cat;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, b.row));
    cat = try setLink(&w, cat, 3, 1, null);
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 3, 1));
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, cat, 1, b.row));
    w.deinit();
}

test "nullifyInboundInCatalog clears only links whose target type matches the filter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "nullify_filter.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    // props: pk(int), prop1(link -> type 5), prop2(link -> type 9)
    var cat = try catalog.createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 5 },
        .{ .kind = .link, .link_target = 9 },
    });
    // Target row T, plus S1 (prop1 -> T) and S2 (prop2 -> T).
    const t = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null }, .{ .link = null } });
    cat = t.cat;
    const s1 = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = t.row }, .{ .link = null } });
    cat = s1.cat;
    const s2 = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = null }, .{ .link = t.row } });
    cat = s2.cat;
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, cat, 2, 1));
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, cat, 3, 2));
    // Filtered nullify on target type 5 clears only prop1's inbound link.
    cat = try nullifyInboundInCatalog(&w, cat, t.row, 5, false);
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 2, 1));
    try testing.expectEqual(@as(?u64, t.row), try getLink(&w, cat, 3, 2));
    w.deinit();
}

test "deleting a target nullifies inbound to-one links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_target.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = a.row } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = a.row } });
    cat = c.cat;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, cat, 1, a.row));
    var out: [2]Value = undefined;
    const va = (try getTyped(&w, cat, 1, &out)).?;
    const dres = try deleteTyped(&w, cat, 1, va);
    cat = dres.ok;
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 2, 1));
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 3, 1));
    w.deinit();
}

test "deleting a source removes its outbound backlink entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "link3_source.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = a.row } });
    cat = b.cat;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    var out: [2]Value = undefined;
    const vb = (try getTyped(&w, cat, 2, &out)).?;
    cat = (try deleteTyped(&w, cat, 2, vb)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, cat, 1, a.row));
    w.deinit();
}

test "links and backlinks persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkpersist.airdb");
    defer testing.allocator.free(path);
    var boss_row: u64 = undefined;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
        const boss = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
        cat = boss.cat;
        boss_row = boss.row;
        var i: u64 = 2;
        while (i <= 50) : (i += 1) cat = (try insertTyped(&w, cat, &.{ .{ .int = i }, .{ .link = boss.row } })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 49), try backlinkCount(&r, r.root(), 1, boss_row));
        try testing.expectEqual(@as(?u64, boss_row), try getLink(&r, r.root(), 25, 1));
        r.end();
    }
}

test "a self-link is allowed and recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_self.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    cat = try setLink(&w, cat, 1, 1, a.row);
    try testing.expectEqual(@as(?u64, a.row), try getLink(&w, cat, 1, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    w.deinit();
}

test "a two-node cycle is allowed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcycle_cycle.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = a.row } });
    cat = b.cat;
    cat = try setLink(&w, cat, 1, 1, b.row);
    try testing.expectEqual(@as(?u64, b.row), try getLink(&w, cat, 1, 1));
    // a links to b, and b still links to a, so each keeps one inbound.
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, b.row));
    w.deinit();
}

test "to-many link set: insert seeds members and backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_insert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    // props: pk(int), tags(link_set -> same type)
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    cat = b.cat;
    // c links to both a and b at insert.
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    cat = c.cat;
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, cat, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, b.row));
    // d also links to a, so a now has two inbound.
    const d = try insertTyped(&w, cat, &.{ .{ .int = 4 }, .{ .link_set = &.{a.row} } });
    cat = d.cat;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, cat, 1, a.row));
    w.deinit();
}

test "to-many link set: membership query reflects members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_member.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    cat = c.cat;
    try testing.expect(try linkSetContains(&w, cat, 3, 1, a.row));
    try testing.expect(!(try linkSetContains(&w, cat, 3, 1, b.row)));
    w.deinit();
}

test "to-many link set: add inserts a new member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addnew.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    cat = c.cat;
    cat = try linkSetAdd(&w, cat, 3, 1, b.row);
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, cat, 3, 1));
    try testing.expect(try linkSetContains(&w, cat, 3, 1, b.row));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, b.row));
    w.deinit();
}

test "to-many link set: adding an existing member is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_addexist.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    cat = c.cat;
    cat = try linkSetAdd(&w, cat, 3, 1, a.row); // already member, no change
    try testing.expectEqual(@as(?u64, 2), try linkSetCount(&w, cat, 3, 1));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    w.deinit();
}

test "to-many link set: remove drops a member" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset1_remove.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{} } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{ a.row, b.row } } });
    cat = c.cat;
    // d also links to a, so a has two inbound before the removal.
    const d = try insertTyped(&w, cat, &.{ .{ .int = 4 }, .{ .link_set = &.{a.row} } });
    cat = d.cat;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, cat, 1, a.row));
    cat = try linkSetRemove(&w, cat, 3, 1, a.row);
    try testing.expect(!(try linkSetContains(&w, cat, 3, 1, a.row)));
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row)); // only d now
    w.deinit();
}

test "deleting a to-many target removes it from all linkers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_target.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{a.row} } });
    cat = b.cat;
    const c = try insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link_set = &.{a.row} } });
    cat = c.cat;
    try testing.expectEqual(@as(u64, 2), try backlinkCount(&w, cat, 1, a.row));
    // Delete a: b and c must lose a from their sets.
    var out: [2]Value = undefined;
    const va = (try getTyped(&w, cat, 1, &out)).?;
    cat = (try deleteTyped(&w, cat, 1, va)).ok;
    try testing.expect(!(try linkSetContains(&w, cat, 2, 1, a.row)));
    try testing.expect(!(try linkSetContains(&w, cat, 3, 1, a.row)));
    try testing.expectEqual(@as(?u64, 0), try linkSetCount(&w, cat, 2, 1));
    w.deinit();
}

test "deleting a to-many linker cleans its backlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset2_linker.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
    const a = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
    cat = a.cat;
    const b = try insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link_set = &.{a.row} } });
    cat = b.cat;
    try testing.expectEqual(@as(u64, 1), try backlinkCount(&w, cat, 1, a.row));
    // Delete b (the linker): no lingering backlink on a's okey.
    var out: [2]Value = undefined;
    const vb = (try getTyped(&w, cat, 2, &out)).?;
    cat = (try deleteTyped(&w, cat, 2, vb)).ok;
    try testing.expectEqual(@as(u64, 0), try backlinkCount(&w, cat, 1, a.row));
    w.deinit();
}

test "to-many links persist across commit and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "lset3.airdb");
    defer testing.allocator.free(path);
    var hub_row: u64 = undefined;
    {
        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link_set } });
        const hub = try insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link_set = &.{} } });
        cat = hub.cat;
        hub_row = hub.row;
        var i: u64 = 2;
        while (i <= 30) : (i += 1) {
            const o = try insertTyped(&w, cat, &.{ .{ .int = i }, .{ .link_set = &.{hub.row} } });
            cat = o.cat;
        }
        w.setRoot(cat);
        _ = try w.commit();
    }
    {
        var db = try Db.open(testing.allocator, path);
        defer db.deinit();
        var r = try db.beginRead();
        try testing.expectEqual(@as(u64, 29), try backlinkCount(&r, r.root(), 1, hub_row));
        try testing.expect(try linkSetContains(&r, r.root(), 15, 1, hub_row));
        r.end();
    }
}
