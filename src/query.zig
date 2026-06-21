const std = @import("std");
const objects = @import("objects.zig");
const catalog = @import("catalog.zig");
const index = @import("index.zig");
const Column = @import("column.zig");
const Ref = @import("ref.zig").Ref;

// Query engine over an object catalog. Operates on the stable object key (okey)
// space: a scan walks the per-type key->row index, so each entry maps an okey to
// the physical row that currently holds its data (rows can move via relocation).
// Predicates compare the raw u64 stored in a property column, so they apply to
// int properties and to link properties (which store target okey + 1). Blob and
// collection predicates are a later addition.
//
// Results are object keys (okeys); materialize them with
// objects.getTypedByOkey. The fetch model is stale-snapshot: a query reads one
// committed snapshot and returns detached keys, never live cursors.

const MAX_PROPS: usize = 256;

pub const Op = enum { eq, ne, lt, le, gt, ge };

pub const Predicate = struct {
    prop: usize,
    op: Op,
    value: u64,
};

fn cmp(op: Op, lhs: u64, rhs: u64) bool {
    return switch (op) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .le => lhs <= rhs,
        .gt => lhs > rhs,
        .ge => lhs >= rhs,
    };
}

// Snapshot of the column refs a scan needs: all property columns, the live
// column, and the key->row index. Captured into locals so no catalog deref slice
// is held across reads.
const Scan = struct {
    prop_refs: [MAX_PROPS]Ref,
    prop_count: usize,
    live_ref: Ref,
    keyrow_index_ref: Ref,
    pk_index_ref: Ref,
    next_row: u64,
};

fn openScan(txn: anytype, cat: Ref) !Scan {
    const v = try catalog.loadCatalog(txn, cat);
    var s: Scan = undefined;
    s.prop_count = v.prop_count;
    s.live_ref = v.live_col_ref;
    s.keyrow_index_ref = v.keyrow_index_ref;
    s.pk_index_ref = v.pk_index_ref;
    s.next_row = v.next_row;
    var j: usize = 0;
    while (j < v.prop_count) : (j += 1) s.prop_refs[j] = v.propColRef(j);
    return s;
}

// A keyrow entry counts only if its row is live AND this okey is the canonical
// one for that row. A deleted object leaves its okey->row mapping in the keyrow
// index; if that dead slot is later reused by a relocation, the stale okey would
// otherwise alias a live row that belongs to a different okey. The pk index maps
// the row's pk back to the single owning okey, so we use it to reject aliases.
fn entryIsCanonical(txn: anytype, s: *const Scan, pr: Pair) !bool {
    if ((try Column.get(txn, s.live_ref, pr.row)) == 0) return false;
    const pk = try Column.get(txn, s.prop_refs[0], pr.row);
    return (try index.get(txn, s.pk_index_ref, pk)) == pr.okey;
}

fn rowMatches(txn: anytype, s: *const Scan, row: u64, preds: []const Predicate) !bool {
    for (preds) |p| {
        const raw = try Column.get(txn, s.prop_refs[p.prop], row);
        if (!cmp(p.op, raw, p.value)) return false;
    }
    return true;
}

// (okey, physical row) pair, as surfaced by the key->row index.
const Pair = struct { okey: u64, row: u64 };

// forEachEntry's callback cannot receive the txn, so it only appends the raw
// (okey, row) pairs; the live check and predicate evaluation happen afterward
// with the txn in scope.
const PairCollector = struct {
    pairs: *std.ArrayList(Pair),
    allocator: std.mem.Allocator,
    fn onEntry(self: @This(), key: u64, val: u64) !void {
        try self.pairs.append(self.allocator, .{ .okey = key, .row = val });
    }
};

// Gather every (okey, row) pair from the key->row index into `pairs`.
fn collectPairs(txn: anytype, s: *const Scan, pairs: *std.ArrayList(Pair), allocator: std.mem.Allocator) !void {
    try index.forEachEntry(txn, s.keyrow_index_ref, PairCollector{ .pairs = pairs, .allocator = allocator }, PairCollector.onEntry);
}

// Collect the okeys of every live row that satisfies ALL predicates (logical
// AND). An empty predicate list matches every live row.
pub fn where(
    txn: anytype,
    cat: Ref,
    preds: []const Predicate,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const s = try openScan(txn, cat);
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    try collectPairs(txn, &s, &pairs, allocator);
    for (pairs.items) |pr| {
        if (!(try entryIsCanonical(txn, &s, pr))) continue;
        if (try rowMatches(txn, &s, pr.row, preds)) try out.append(allocator, pr.okey);
    }
}

// Number of live rows satisfying all predicates.
pub fn countWhere(txn: anytype, cat: Ref, preds: []const Predicate, allocator: std.mem.Allocator) !u64 {
    const s = try openScan(txn, cat);
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    try collectPairs(txn, &s, &pairs, allocator);
    var n: u64 = 0;
    for (pairs.items) |pr| {
        if (!(try entryIsCanonical(txn, &s, pr))) continue;
        if (try rowMatches(txn, &s, pr.row, preds)) n += 1;
    }
    return n;
}

pub const Aggregate = struct { count: u64, sum: u64, min: ?u64, max: ?u64 };

// Aggregate an int property over the live rows satisfying all predicates.
// `sum` wraps on overflow (wrapping add); min/max are null when no row matches.
pub fn aggregateInt(txn: anytype, cat: Ref, prop: usize, preds: []const Predicate, allocator: std.mem.Allocator) !Aggregate {
    const s = try openScan(txn, cat);
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    try collectPairs(txn, &s, &pairs, allocator);
    var agg = Aggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    for (pairs.items) |pr| {
        if (!(try entryIsCanonical(txn, &s, pr))) continue;
        if (!(try rowMatches(txn, &s, pr.row, preds))) continue;
        const val = try Column.get(txn, s.prop_refs[prop], pr.row);
        agg.count += 1;
        agg.sum +%= val;
        if (agg.min == null or val < agg.min.?) agg.min = val;
        if (agg.max == null or val > agg.max.?) agg.max = val;
    }
    return agg;
}

// Convenience: collect okeys whose property `prop` is in the inclusive range
// [lo, hi]. Implemented as a scan with two predicates; an index-seek fast path
// is a later optimization.
pub fn rangeInclusive(
    txn: anytype,
    cat: Ref,
    prop: usize,
    lo: u64,
    hi: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const preds = [_]Predicate{
        .{ .prop = prop, .op = .ge, .value = lo },
        .{ .prop = prop, .op = .le, .value = hi },
    };
    try where(txn, cat, &preds, out, allocator);
}

// Sort a slice of okeys in place by an int property, ascending. Reads each
// row's value once into a temporary pair array, then sorts.
pub fn sortByPropAsc(
    txn: anytype,
    cat: Ref,
    okeys: []u64,
    prop: usize,
    allocator: std.mem.Allocator,
) !void {
    const v = try catalog.loadCatalog(txn, cat);
    const col = v.propColRef(prop);
    const SortPair = struct { val: u64, key: u64 };
    const pairs = try allocator.alloc(SortPair, okeys.len);
    defer allocator.free(pairs);
    for (okeys, 0..) |k, i| {
        const row = (try catalog.okeyToRow(txn, cat, k)).?;
        pairs[i] = .{ .val = try Column.get(txn, col, row), .key = k };
    }
    std.mem.sort(SortPair, pairs, {}, struct {
        fn lt(_: void, a: SortPair, b: SortPair) bool {
            return a.val < b.val;
        }
    }.lt);
    for (pairs, 0..) |pr, i| okeys[i] = pr.key;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;

fn qTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

// Build a type with pk(int) + age(int) and insert (pk, age) rows.
fn seed(w: anytype, pairs: []const [2]u64) !Ref {
    var cat = try catalog.create(w, 2);
    for (pairs) |p| cat = (try objects.insert(w, cat, &.{ p[0], p[1] })).cat;
    return cat;
}

test "where filters live rows by ANDed predicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try seed(&w, &.{ .{ 1, 20 }, .{ 2, 30 }, .{ 3, 40 }, .{ 4, 30 } });
    // age == 30
    var r1 = std.ArrayList(u64).empty;
    defer r1.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &r1, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r1.items.len);
    // age > 25 AND pk < 4  -> pk 2 (age30), pk3 (age40) ; pk4 excluded by pk<4
    var r2 = std.ArrayList(u64).empty;
    defer r2.deinit(testing.allocator);
    try where(&w, cat, &.{
        .{ .prop = 1, .op = .gt, .value = 25 },
        .{ .prop = 0, .op = .lt, .value = 4 },
    }, &r2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), r2.items.len);
    // delete pk 2, re-query age==30 -> only pk4
    var out: [2]u64 = undefined;
    const vv = (try objects.getByPk(&w, cat, 2, &out)).?;
    cat = (try objects.delete(&w, cat, 2, vv)).ok;
    var r3 = std.ArrayList(u64).empty;
    defer r3.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &r3, testing.allocator);
    try testing.expectEqual(@as(usize, 1), r3.items.len);
    w.deinit();
}

test "countWhere and aggregateInt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try seed(&w, &.{ .{ 1, 10 }, .{ 2, 20 }, .{ 3, 30 }, .{ 4, 40 } });
    try testing.expectEqual(@as(u64, 4), try countWhere(&w, cat, &.{}, testing.allocator));
    try testing.expectEqual(@as(u64, 2), try countWhere(&w, cat, &.{.{ .prop = 1, .op = .ge, .value = 30 }}, testing.allocator));
    const agg = try aggregateInt(&w, cat, 1, &.{}, testing.allocator);
    try testing.expectEqual(@as(u64, 4), agg.count);
    try testing.expectEqual(@as(u64, 100), agg.sum);
    try testing.expectEqual(@as(?u64, 10), agg.min);
    try testing.expectEqual(@as(?u64, 40), agg.max);
    const empty = try aggregateInt(&w, cat, 1, &.{.{ .prop = 1, .op = .gt, .value = 1000 }}, testing.allocator);
    try testing.expectEqual(@as(u64, 0), empty.count);
    try testing.expectEqual(@as(?u64, null), empty.min);
    w.deinit();
}

test "rangeInclusive and sortByPropAsc" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try seed(&w, &.{ .{ 5, 1 }, .{ 1, 1 }, .{ 9, 1 }, .{ 3, 1 }, .{ 7, 1 } });
    var rng = std.ArrayList(u64).empty;
    defer rng.deinit(testing.allocator);
    // pk in [3,7]
    try rangeInclusive(&w, cat, 0, 3, 7, &rng, testing.allocator);
    try testing.expectEqual(@as(usize, 3), rng.items.len); // pks 5,3,7
    // sort the matching okeys by pk ascending, then verify the pk order is 3,5,7
    try sortByPropAsc(&w, cat, rng.items, 0, testing.allocator);
    var out: [2]u64 = undefined;
    _ = try objects.getByObjectKey(&w, cat, rng.items[0], &out);
    try testing.expectEqual(@as(u64, 3), out[0]);
    _ = try objects.getByObjectKey(&w, cat, rng.items[1], &out);
    try testing.expectEqual(@as(u64, 5), out[0]);
    _ = try objects.getByObjectKey(&w, cat, rng.items[2], &out);
    try testing.expectEqual(@as(u64, 7), out[0]);
    w.deinit();
}

test "scan over 100k rows finds the matching slice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q4.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < 100_000) : (i += 1) cat = (try objects.insert(&w, cat, &.{ i, i % 100 })).cat;
    // 1000 rows have (i % 100 == 7)
    try testing.expectEqual(@as(u64, 1000), try countWhere(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator));
    w.deinit();
}

test "query returns stable object keys after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "q5.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    // pk + age. Insert a throwaway first to open up a dead slot, then the target.
    var cat = try catalog.create(&w, 2);
    const throwaway = try objects.insert(&w, cat, &.{ 1, 99 });
    cat = throwaway.cat;
    const target = try objects.insert(&w, cat, &.{ 2, 30 });
    cat = target.cat;
    const target_okey = target.row;

    // Free the throwaway's physical slot.
    const dead_row = (try catalog.okeyToRow(&w, cat, throwaway.row)).?;
    var vbuf: [2]u64 = undefined;
    const tv = (try objects.getByPk(&w, cat, 1, &vbuf)).?;
    cat = (try objects.delete(&w, cat, 1, tv)).ok;

    // Relocate the target into the freed slot; its okey is unchanged.
    cat = try relocation.relocateRow(&w, cat, target_okey, dead_row);

    // A query that matches the relocated row must return its stable okey, and
    // that okey must resolve to the right values.
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(testing.allocator);
    try where(&w, cat, &.{.{ .prop = 1, .op = .eq, .value = 30 }}, &hits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(target_okey, hits.items[0]);

    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, hits.items[0], &out)) != null);
    try testing.expectEqual(@as(u64, 2), out[0]); // pk
    try testing.expectEqual(@as(u64, 30), out[1]); // age
    w.deinit();
}

const relocation = @import("relocation.zig");
