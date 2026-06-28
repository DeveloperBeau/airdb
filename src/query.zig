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
    // Per-property: whether the property has a value index, and the ref of that
    // index. Captured so the planner can drive a query off the index without a
    // second catalog deref.
    indexed: [MAX_PROPS]bool,
    value_index_refs: [MAX_PROPS]Ref,
    prop_count: usize,
    live_ref: Ref,
    keyrow_index_ref: Ref,
    next_row: u64,
};

fn openScan(txn: anytype, cat: Ref) !Scan {
    const v = try catalog.loadCatalog(txn, cat);
    var s: Scan = undefined;
    s.prop_count = v.prop_count;
    s.live_ref = v.live_col_ref;
    s.keyrow_index_ref = v.keyrow_index_ref;
    s.next_row = v.next_row;
    var j: usize = 0;
    while (j < v.prop_count) : (j += 1) {
        s.prop_refs[j] = v.propColRef(j);
        s.indexed[j] = v.indexed(j);
        s.value_index_refs[j] = v.valueIndexRef(j);
    }
    return s;
}

// A keyrow entry is live unless its row is tombstoned. `delete` removes the
// object key from the key->row index, so the current snapshot's index never
// holds a stale key that could alias a relocated row; the live check is the
// only filter needed.
fn rowLive(txn: anytype, s: *const Scan, pr: Pair) !bool {
    return (try Column.get(txn, s.live_ref, pr.row)) != 0;
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

// Gather every (okey, row) pair from the key->row index into `pairs`, in
// ascending okey order.
fn collectAllPairs(txn: anytype, s: *const Scan, pairs: *std.ArrayList(Pair), allocator: std.mem.Allocator) !void {
    try index.forEachEntry(txn, s.keyrow_index_ref, PairCollector{ .pairs = pairs, .allocator = allocator }, PairCollector.onEntry);
}

// ---------------------------------------------------------------------------
// Query planner.
//
// The planner chooses an optional DRIVING predicate: a predicate whose property
// is indexed and whose operator is index-friendly (eq, lt, le, gt, ge). When one
// exists, the candidate okeys are gathered from that property's value index
// rather than from a full keyrow scan; the remaining predicates are then applied
// to each candidate by the same rowLive/rowMatches logic the scan uses.
//
// Correctness: the value index is an exact mirror of the indexed property (kept
// in sync on every mutation), so its inner sets contain exactly the okeys whose
// value satisfies the driving predicate. Resolving each candidate okey through
// the keyrow index and re-applying ALL predicates (including the driving one,
// which always passes) plus the live check reproduces, on the same committed
// snapshot, the exact okey set the full scan would emit. Candidate pairs are
// sorted by okey so the emitted order matches the ascending-okey scan order too.
// ---------------------------------------------------------------------------

// Pick the index of the driving predicate, or null to fall back to a full scan.
// Prefers an indexed eq predicate (most selective); otherwise the first indexed
// range predicate. `ne` is never index-driven (negation is not index-friendly).
fn pickDriving(s: *const Scan, preds: []const Predicate) ?usize {
    var range_choice: ?usize = null;
    for (preds, 0..) |p, i| {
        if (p.prop >= s.prop_count or !s.indexed[p.prop]) continue;
        switch (p.op) {
            .eq => return i, // most selective: drive off it immediately
            .lt, .le, .gt, .ge => if (range_choice == null) {
                range_choice = i;
            },
            .ne => {},
        }
    }
    return range_choice;
}

// Translate a range operator + value into an inclusive [lo, hi] over u64.
// Returns null when the range is provably empty (gt maxInt, lt 0), so the
// caller emits zero candidates.
//   ge v -> [v, max]      gt v -> [v+1, max]  (empty if v == max)
//   le v -> [0, v]        lt v -> [0, v-1]    (empty if v == 0)
const Bounds = struct { lo: u64, hi: u64 };
fn rangeBounds(op: Op, value: u64) ?Bounds {
    const max = std.math.maxInt(u64);
    return switch (op) {
        .ge => Bounds{ .lo = value, .hi = max },
        .gt => if (value == max) null else Bounds{ .lo = value + 1, .hi = max },
        .le => Bounds{ .lo = 0, .hi = value },
        .lt => if (value == 0) null else Bounds{ .lo = 0, .hi = value - 1 },
        else => unreachable,
    };
}

// Appends okeys to a list; used to drain a value-index inner set (okey -> 1).
const OkeyCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onKey(self: @This(), key: u64) !void {
        try self.list.append(self.allocator, key);
    }
};

// Appends each outer entry's value (an inner-set root ref) to a list; used to
// gather the inner sets a range scan of the value index touches.
const InnerRootCollector = struct {
    list: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
    fn onEntry(self: @This(), _: u64, val: u64) !void {
        try self.list.append(self.allocator, val);
    }
};

// Gather candidate (okey, row) pairs for a driving predicate from its value
// index, resolving each okey to its current physical row via the keyrow index
// (skipping any okey with no mapping). Pairs are returned sorted by okey.
fn collectCandidatePairs(
    txn: anytype,
    s: *const Scan,
    driver: Predicate,
    pairs: *std.ArrayList(Pair),
    allocator: std.mem.Allocator,
) !void {
    const vi = s.value_index_refs[driver.prop];
    var okeys = std.ArrayList(u64).empty;
    defer okeys.deinit(allocator);

    if (driver.op == .eq) {
        if (try index.get(txn, vi, driver.value)) |inner_root| {
            if (inner_root != 0) {
                try index.forEachKey(txn, inner_root, OkeyCollector{ .list = &okeys, .allocator = allocator }, OkeyCollector.onKey);
            }
        }
    } else {
        const bounds = rangeBounds(driver.op, driver.value) orelse return; // empty range
        var inner_roots = std.ArrayList(u64).empty;
        defer inner_roots.deinit(allocator);
        try index.forEachEntryInRange(txn, vi, bounds.lo, bounds.hi, InnerRootCollector{ .list = &inner_roots, .allocator = allocator }, InnerRootCollector.onEntry);
        for (inner_roots.items) |inner_root| {
            if (inner_root == 0) continue;
            try index.forEachKey(txn, inner_root, OkeyCollector{ .list = &okeys, .allocator = allocator }, OkeyCollector.onKey);
        }
    }

    for (okeys.items) |okey| {
        const row = (try index.get(txn, s.keyrow_index_ref, okey)) orelse continue;
        try pairs.append(allocator, .{ .okey = okey, .row = row });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.okey < b.okey;
        }
    }.lt);
}

// Gather the (okey, row) pairs a query must evaluate: the index-driven candidate
// set when a driving predicate exists, otherwise every pair via a full scan.
// Either way the caller applies the live check and ALL predicates afterward, so
// behavior is identical to the full scan.
fn collectPairs(txn: anytype, s: *const Scan, preds: []const Predicate, pairs: *std.ArrayList(Pair), allocator: std.mem.Allocator) !void {
    if (pickDriving(s, preds)) |di| {
        try collectCandidatePairs(txn, s, preds[di], pairs, allocator);
    } else {
        try collectAllPairs(txn, s, pairs, allocator);
    }
}

// Test-only: expose the driving-predicate choice so equivalence tests can assert
// which path the planner takes.
fn drivingPredicateIndex(txn: anytype, cat: Ref, preds: []const Predicate) !?usize {
    const s = try openScan(txn, cat);
    return pickDriving(&s, preds);
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
    try collectPairs(txn, &s, preds, &pairs, allocator);
    for (pairs.items) |pr| {
        if (!(try rowLive(txn, &s, pr))) continue;
        if (try rowMatches(txn, &s, pr.row, preds)) try out.append(allocator, pr.okey);
    }
}

// Number of live rows satisfying all predicates.
pub fn countWhere(txn: anytype, cat: Ref, preds: []const Predicate, allocator: std.mem.Allocator) !u64 {
    const s = try openScan(txn, cat);
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    try collectPairs(txn, &s, preds, &pairs, allocator);
    var n: u64 = 0;
    for (pairs.items) |pr| {
        if (!(try rowLive(txn, &s, pr))) continue;
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
    try collectPairs(txn, &s, preds, &pairs, allocator);
    var agg = Aggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    for (pairs.items) |pr| {
        if (!(try rowLive(txn, &s, pr))) continue;
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

// ---------------------------------------------------------------------------
// Planner equivalence tests.
//
// Every test builds two catalogs over identical data inserted in identical
// order: one with prop 1 indexed (the planner drives off its value index) and
// one with prop 1 NOT indexed (forced full scan). Because both catalogs assign
// object keys from 0 in the same insertion order, a row's okey is the same in
// both, so the sorted okey slices must be byte-for-byte equal. Any divergence
// between the index path and the full scan is a defect.
// ---------------------------------------------------------------------------

// Build a 3-prop type: prop0 = pk, prop1 = value (indexed iff `idx`), prop2 =
// secondary. Inserts n rows with pk=i, prop1=i%100, prop2=i.
fn seedPlannerCat(w: *@import("db.zig").WriteTxn, idx: bool, n: u64) !Ref {
    const defs = [_]catalog.PropDef{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = idx },
        .{ .kind = .int },
    };
    var cat = try catalog.createDefs(w, &defs);
    var i: u64 = 0;
    while (i < n) : (i += 1) cat = (try objects.insert(w, cat, &.{ i, i % 100, i })).cat;
    return cat;
}

fn whereSorted(txn: anytype, cat: Ref, preds: []const Predicate, out: *std.ArrayList(u64)) !void {
    try where(txn, cat, preds, out, testing.allocator);
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
}

// Assert the index path (on cat_idx) yields the exact same sorted okey set as
// the full scan (on cat_scan) for the given predicates.
fn expectSameWhere(txn: anytype, cat_idx: Ref, cat_scan: Ref, preds: []const Predicate) !void {
    var a = std.ArrayList(u64).empty;
    defer a.deinit(testing.allocator);
    var b = std.ArrayList(u64).empty;
    defer b.deinit(testing.allocator);
    try whereSorted(txn, cat_idx, preds, &a);
    try whereSorted(txn, cat_scan, preds, &b);
    try testing.expectEqualSlices(u64, b.items, a.items);
}

test "planner picks an indexed eq predicate as the driver, prefers eq over range, ignores ne and non-indexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_pick.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try seedPlannerCat(&w, true, 10);

    // prop 1 is indexed; prop 0 and prop 2 are not.
    // eq on the indexed prop drives.
    try testing.expectEqual(@as(?usize, 0), try drivingPredicateIndex(&w, cat, &.{
        .{ .prop = 1, .op = .eq, .value = 5 },
    }));
    // Prefer the eq over a range, even when the range appears first.
    try testing.expectEqual(@as(?usize, 1), try drivingPredicateIndex(&w, cat, &.{
        .{ .prop = 1, .op = .ge, .value = 5 },
        .{ .prop = 1, .op = .eq, .value = 5 },
    }));
    // A range on the indexed prop drives when there is no eq.
    try testing.expectEqual(@as(?usize, 0), try drivingPredicateIndex(&w, cat, &.{
        .{ .prop = 1, .op = .lt, .value = 5 },
    }));
    // ne is not index-friendly: stays on the scan.
    try testing.expectEqual(@as(?usize, null), try drivingPredicateIndex(&w, cat, &.{
        .{ .prop = 1, .op = .ne, .value = 5 },
    }));
    // eq on a non-indexed prop: no driver.
    try testing.expectEqual(@as(?usize, null), try drivingPredicateIndex(&w, cat, &.{
        .{ .prop = 0, .op = .eq, .value = 5 },
        .{ .prop = 2, .op = .ge, .value = 5 },
    }));
    w.deinit();
}

test "indexed eq equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_eq.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 42 }});
    w.deinit();
}

test "indexed range equals full scan for each of lt le gt ge with boundary correctness" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_range.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    // Combined range [40,45].
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .ge, .value = 40 },
        .{ .prop = 1, .op = .le, .value = 45 },
    });
    // Each operator individually, at and around the bound (off-by-one guards).
    for ([_]u64{ 0, 1, 42, 99 }) |b| {
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .lt, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .le, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = b }});
        try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = b }});
    }
    w.deinit();
}

test "indexed predicate plus non-indexed predicate equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_mixed.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);
    // prop1 (indexed) drives; prop2 (not indexed) is a remaining predicate.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .eq, .value = 42 },
        .{ .prop = 2, .op = .ge, .value = 2500 },
    });
    // Range driver plus a remaining predicate.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{
        .{ .prop = 1, .op = .ge, .value = 30 },
        .{ .prop = 2, .op = .lt, .value = 1000 },
    });
    w.deinit();
}

test "ne falls back to the scan and still equals full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_ne.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 2000);
    const cat_scan = try seedPlannerCat(&w, false, 2000);
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ne, .value = 42 }});
    w.deinit();
}

test "non-indexed query is unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_noidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 2000);
    const cat_scan = try seedPlannerCat(&w, false, 2000);
    // Query a non-indexed prop on both: both run the full scan.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 2, .op = .eq, .value = 1234 }});
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 0, .op = .ge, .value = 1000 }});
    w.deinit();
}

test "countWhere rangeInclusive aggregateInt match between index path and full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_aggs.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 5000);
    const cat_scan = try seedPlannerCat(&w, false, 5000);

    // countWhere on an indexed eq predicate.
    try testing.expectEqual(
        try countWhere(&w, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator),
        try countWhere(&w, cat_idx, &.{.{ .prop = 1, .op = .eq, .value = 7 }}, testing.allocator),
    );
    // countWhere on an indexed range predicate.
    try testing.expectEqual(
        try countWhere(&w, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = 90 }}, testing.allocator),
        try countWhere(&w, cat_idx, &.{.{ .prop = 1, .op = .ge, .value = 90 }}, testing.allocator),
    );

    // rangeInclusive over the indexed prop.
    var ri_idx = std.ArrayList(u64).empty;
    defer ri_idx.deinit(testing.allocator);
    var ri_scan = std.ArrayList(u64).empty;
    defer ri_scan.deinit(testing.allocator);
    try rangeInclusive(&w, cat_idx, 1, 10, 20, &ri_idx, testing.allocator);
    try rangeInclusive(&w, cat_scan, 1, 10, 20, &ri_scan, testing.allocator);
    std.mem.sort(u64, ri_idx.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, ri_scan.items, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, ri_scan.items, ri_idx.items);

    // aggregateInt over the indexed prop with an indexed driver.
    const a = try aggregateInt(&w, cat_idx, 1, &.{.{ .prop = 1, .op = .eq, .value = 50 }}, testing.allocator);
    const b = try aggregateInt(&w, cat_scan, 1, &.{.{ .prop = 1, .op = .eq, .value = 50 }}, testing.allocator);
    try testing.expectEqual(b.count, a.count);
    try testing.expectEqual(b.sum, a.sum);
    try testing.expectEqual(b.min, a.min);
    try testing.expectEqual(b.max, a.max);
    w.deinit();
}

test "empty result and all-match edge cases match full scan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_edges.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat_idx = try seedPlannerCat(&w, true, 1000);
    const cat_scan = try seedPlannerCat(&w, false, 1000);

    // Empty: eq on a value no row holds (values are i%100, so 100 never appears).
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 100 }});
    // Empty: range entirely above the populated values.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = 99 }});
    // Empty: lt 0 underflow guard.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .lt, .value = 0 }});
    // Empty: gt maxInt overflow guard.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .gt, .value = std.math.maxInt(u64) }});
    // All-match: ge 0 selects every row.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .ge, .value = 0 }});
    // All-match: le maxInt selects every row.
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .le, .value = std.math.maxInt(u64) }});
    w.deinit();
}

test "index path equals full scan after deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try qTmpPath(testing.allocator, &tmp, "plan_del.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat_idx = try seedPlannerCat(&w, true, 2000);
    var cat_scan = try seedPlannerCat(&w, false, 2000);
    // Delete every 7th pk from both catalogs.
    var out: [3]u64 = undefined;
    var pk: u64 = 0;
    while (pk < 2000) : (pk += 7) {
        const vi = (try objects.getByPk(&w, cat_idx, pk, &out)).?;
        cat_idx = (try objects.delete(&w, cat_idx, pk, vi)).ok;
        const vs = (try objects.getByPk(&w, cat_scan, pk, &out)).?;
        cat_scan = (try objects.delete(&w, cat_scan, pk, vs)).ok;
    }
    try expectSameWhere(&w, cat_idx, cat_scan, &.{.{ .prop = 1, .op = .eq, .value = 42 }});
    try expectSameWhere(&w, cat_idx, cat_scan, &.{ .{ .prop = 1, .op = .ge, .value = 40 }, .{ .prop = 1, .op = .le, .value = 45 } });
    w.deinit();
}
