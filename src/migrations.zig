const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("bindex.zig");
const catalog = @import("catalog.zig");
const blob = @import("blob.zig");
const objects = @import("objects.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

// ---------------------------------------------------------------------------
// Migrations (structural schema evolution)
//
// The catalog stores properties by position, not name, so renaming is a no-op
// at this layer (names live in the binding/schema layer). Add and remove
// rewrite the catalog transactionally (COW); existing snapshots are unaffected.
// ---------------------------------------------------------------------------

// Append a new property to the type. The new column is filled with
// `default_value` for every existing row (live or tombstoned). For a link or
// link_set property a fresh backlink index is created. Returns the new catalog.
pub fn addProperty(txn: *WriteTxn, cat: Ref, def: PropDef, default_value: u64) !Ref {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const pc = s.prop_count;
    std.debug.assert(pc + 1 <= max_prop_count);

    const is_collection = switch (def.kind) {
        .list, .set, .dict, .link_set => true,
        .int, .blob, .link => false,
    };
    // Indexing a collection property would index its per-row root refs --
    // meaningless as values and impossible to backfill coherently.
    if (def.indexed and is_collection) return error.Unsupported;

    // Build the new column. Storage-bearing kinds are backfilled PER LIVE
    // ROW, never shared. Collections: a raw zero root breaks every collection
    // accessor and made pre-migration rows undeletable through the graph-safe
    // delete (its outbound cleanup walks link_set roots), while a SHARED root
    // would be freed by the first row's delete underneath every other row.
    // Blobs have the same aliasing hazard: writing the caller's single
    // default ref into every row meant the first row's delete freed the node
    // under all the others, planting a duplicate extent in the free list --
    // so each live row gets its own copy of the default bytes (the caller
    // keeps ownership of the passed-in ref). Dead rows get 0 for both;
    // nothing ever dereferences a tombstoned row's columns.
    var new_col = try Column.create(txn);
    var i: u64 = 0;
    while (i < s.next_row) : (i += 1) {
        const live = (try Column.get(txn, s.live_col_ref, i)) != 0;
        const fill: u64 = if (def.kind == .blob)
            (if (live and default_value != 0) try blobDup(txn, default_value) else if (live) default_value else 0)
        else if (!is_collection)
            default_value
        else if (!live)
            0
        else switch (def.kind) {
            .list => try Column.create(txn),
            .set => switch (def.elem) {
                .int => try Index.create(txn),
                .blob => try bindex.create(txn),
            },
            .link_set => try Index.create(txn),
            .dict => try bindex.create(txn),
            else => unreachable,
        };
        new_col = try Column.append(txn, new_col, fill);
    }

    // Backfill the value index for existing LIVE rows: the query planner
    // trusts the indexed flag, so an empty index would silently drop every
    // pre-migration row from indexed queries (and fail the integrity audit).
    // Each row is indexed under its OWN raw column value (mirroring the
    // insert path) -- blob backfills give every row a distinct ref, so a
    // single shared key would diverge from what reads and audits expect.
    var vi: Ref = 0;
    if (def.indexed) {
        vi = try Index.create(txn);
        const Sink = struct {
            txn: *WriteTxn,
            vi: *Ref,
            col: Ref,
            fn onEntry(self: @This(), okey: u64, row: u64) anyerror!void {
                const raw = try Column.get(self.txn, self.col, row);
                self.vi.* = try objects.viAdd(self.txn, self.vi.*, raw, okey);
            }
        };
        try Index.forEachEntry(txn, s.keyrow_index_ref, Sink{ .txn = txn, .vi = &vi, .col = new_col }, Sink.onEntry);
    }

    s.props[pc] = .{
        .col = new_col,
        .kind = def.kind,
        .elem = def.elem,
        .backlink = if (def.kind == .link or def.kind == .link_set) try Index.create(txn) else 0,
        .target = def.link_target,
        .rule = def.del_rule,
        .value_index = vi,
        .indexed = def.indexed,
    };
    s.prop_count = pc + 1;
    return s.replace(txn);
}

// Copy a blob's bytes into a fresh node, returning the new ref. Used by the
// blob-default backfill so no two rows share one node.
fn blobDup(txn: *WriteTxn, ref: u64) !u64 {
    if (blob.get(txn, ref)) |bytes| {
        return blob.put(txn, bytes);
    } else |err| switch (err) {
        error.BlobChunked => {
            const alloc = txn.db.store.allocator;
            const bytes = try blob.getAlloc(txn, ref, alloc);
            defer alloc.free(bytes);
            return blob.put(txn, bytes);
        },
        else => |e| return e,
    }
}

// Remove property `prop` (must be >= 1; the primary key at 0 cannot be removed).
// The dropped column is left for compaction to reclaim. Returns the new catalog.
pub fn removeProperty(txn: *WriteTxn, cat: Ref, prop: usize) !Ref {
    std.debug.assert(prop >= 1);
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    std.debug.assert(prop < s.prop_count);
    var j: usize = prop;
    while (j + 1 < s.prop_count) : (j += 1) s.props[j] = s.props[j + 1];
    s.prop_count -= 1;
    return s.replace(txn);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const create = catalog.create;
const propCount = catalog.propCount;
const insert = @import("objects.zig").insert;
const getByPk = @import("objects.zig").getByPk;
const getLink = @import("links.zig").getLink;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "addProperty backfills the default for existing rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_backfill.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    // start with pk + one value
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
    // add a third int property defaulting to 7
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, cat));
    var out: [3]u64 = undefined;
    _ = (try getByPk(&w, cat, 1, &out)).?;
    try testing.expectEqual(@as(u64, 10), out[1]);
    try testing.expectEqual(@as(u64, 7), out[2]); // backfilled
    w.deinit();
}

test "addProperty: new inserts supply the added property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_newinsert.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    // new inserts provide all three
    cat = (try insert(&w, cat, &.{ 3, 30, 99 })).cat;
    var out: [3]u64 = undefined;
    _ = (try getByPk(&w, cat, 3, &out)).?;
    try testing.expectEqual(@as(u64, 99), out[2]);
    w.deinit();
}

test "removeProperty drops a property and shifts the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig1_remove.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 2);
    cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
    cat = try addProperty(&w, cat, .{ .kind = .int }, 7);
    cat = (try insert(&w, cat, &.{ 3, 30, 99 })).cat;
    // remove the middle property (index 1); now pk + the added prop
    cat = try removeProperty(&w, cat, 1);
    try testing.expectEqual(@as(PropCount, 2), try propCount(&w, cat));
    var out2: [2]u64 = undefined;
    _ = (try getByPk(&w, cat, 3, &out2)).?;
    try testing.expectEqual(@as(u64, 3), out2[0]); // pk preserved
    try testing.expectEqual(@as(u64, 99), out2[1]); // the formerly-third prop shifted to index 1
    w.deinit();
}

test "addProperty(indexed) backfills the value index for existing rows" {
    // Regression: the fresh value index was left empty, so indexed queries
    // silently missed every pre-migration row and the audit flagged the file.
    const query = @import("query.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_vidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        var cat = try create(&w, 2);
        cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
        cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
        cat = try addProperty(&w, cat, .{ .kind = .int, .indexed = true }, 7);
        // A post-migration insert supplies its own value.
        cat = (try insert(&w, cat, &.{ 3, 30, 9 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }
    try db.verifyIntegrity();
    var r = try db.beginRead();
    defer r.end();
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try query.where(&r, r.root(), &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 2), hits.items.len); // both pre-migration rows
    hits.clearRetainingCapacity();
    try query.where(&r, r.root(), &.{.{ .prop = 2, .op = .eq, .value = 9 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "addProperty(link_set) leaves pre-migration rows deletable" {
    // Regression: collection kinds were backfilled with a raw 0 root, which
    // broke every collection accessor on migrated rows and made them
    // undeletable through the graph-safe delete (its outbound cleanup walks
    // link_set roots and hit error.BadRef).
    const typedir = @import("typedir.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_collroot.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    {
        var w = try db.beginWrite();
        var dir = try typedir.createTypes(&w, &.{&.{.{ .kind = .int }}}, &.{false});
        dir = (try typedir.insert(&w, dir, 0, &.{.{ .int = 1 }})).dir;
        // Migrate: add a link_set property targeting the same type.
        const cat = try typedir.catalogRef(&w, dir, 0);
        const new_cat = try addProperty(&w, cat, .{ .kind = .link_set, .link_target = 0 }, 0);
        dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(dir);
        _ = try w.commit();
    }
    try db.verifyIntegrity(); // the audit must not trip over the backfilled roots
    {
        var w = try db.beginWrite();
        var out: [2]catalog.Value = undefined;
        const ver = (try typedir.get(&w, w.new_root, 0, 1, &out)).?;
        const res = try typedir.deleteNullifyX(&w, w.new_root, 0, 1, ver);
        try testing.expect(res == .ok); // previously error.BadRef
        w.setRoot(res.ok);
        _ = try w.commit();
    }
}

test "addProperty rejects an indexed collection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig_idxcoll.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    const cat = try create(&w, 1);
    try testing.expectError(error.Unsupported, addProperty(&w, cat, .{ .kind = .list, .indexed = true }, 0));
}

test "addProperty link type gets a backlink index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "mig2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try create(&w, 1); // just a pk
    cat = (try insert(&w, cat, &.{1})).cat;
    cat = try addProperty(&w, cat, .{ .kind = .link }, 0); // 0 == null link
    const v = try catalog.loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.link, v.kind(1));
    try testing.expect(v.backlinkRef(1) != 0);
    // a row created before the migration reads as a null link
    try testing.expectEqual(@as(?u64, null), try getLink(&w, cat, 1, 1));
    w.deinit();
}

test "addProperty copies a blob default per row instead of sharing one node" {
    // Regression: the backfill wrote the caller's single blob ref into every
    // existing row. The first row's delete freed the node underneath all the
    // others, and a second delete freed it again -- a duplicate extent in the
    // free list, handing the same bytes to two future allocations.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "blobdefault.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();

    {
        var w = try db.beginWrite();
        var cat = try catalog.createTyped(&w, &.{ .int, .int });
        cat = (try insert(&w, cat, &.{ 1, 10 })).cat;
        cat = (try insert(&w, cat, &.{ 2, 20 })).cat;
        const dflt = try blob.put(&w, "default-bytes");
        cat = try addProperty(&w, cat, .{ .kind = .blob }, dflt);
        w.setRoot(cat);
        _ = try w.commit();
    }
    var w = try db.beginWrite();
    defer w.deinit();
    // Every row reads the default bytes, but from its OWN node.
    var raw1: [3]u64 = undefined;
    var raw2: [3]u64 = undefined;
    const v1 = (try getByPk(&w, w.new_root, 1, &raw1)).?;
    const v2 = (try getByPk(&w, w.new_root, 2, &raw2)).?;
    try testing.expectEqualStrings("default-bytes", try blob.get(&w, raw1[2]));
    try testing.expectEqualStrings("default-bytes", try blob.get(&w, raw2[2]));
    try testing.expect(raw1[2] != raw2[2]);
    // Deleting both rows must not free any extent twice.
    var cat = w.new_root;
    switch (try objects.deleteTyped(&w, cat, 1, v1)) {
        .ok => |c| cat = c,
        else => return error.TestUnexpectedResult,
    }
    switch (try objects.deleteTyped(&w, cat, 2, v2)) {
        .ok => |c| cat = c,
        else => return error.TestUnexpectedResult,
    }
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    for (w.txn_reuse.extents.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing); // duplicate free
    }
    for (w.in_flight_frees.items) |e| {
        const gop = try seen.getOrPut(e.offset);
        try testing.expect(!gop.found_existing);
    }
}
