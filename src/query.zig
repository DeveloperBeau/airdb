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
fn rowMatches(txn: anytype, s: *const Scan, row: u64, preds: []const Predicate) !bool {
    for (preds) |p| {
        const raw = try Column.get(txn, s.prop_refs[p.prop], row);
        if (!cmp(p.op, raw, p.value)) return false;
    }
    return true;
}

// Full row evaluation: live check plus every predicate (logical AND).
fn evalRow(txn: anytype, s: *const Scan, row: u64, preds: []const Predicate) !bool {
    if ((try Column.get(txn, s.live_ref, row)) == 0) return false;
    return rowMatches(txn, s, row, preds);
}

// Reject out-of-range property indices up front: the evaluators index
// fixed-size ref arrays, so an unchecked prop is an undefined ref below 256
// and an out-of-bounds read past it. Query inputs will eventually cross the
// C ABI, which must not trust its arguments.
fn validateProps(s: *const Scan, preds: []const Predicate) !void {
    for (preds) |p| {
        if (p.prop >= s.prop_count) return error.BadProp;
    }
}

// (okey, physical row) pair, as surfaced by the key->row index.
const Pair = struct { okey: u64, row: u64 };

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

// Run a query: stream every live matching (okey, row) into `onMatch(ctx, okey, row)`.
// With a driving predicate the candidate set comes from that property's value
// index (bounded by its selectivity, so a temporary pair buffer is fine); the
// full-scan path streams the key->row index directly and evaluates each row
// inside the traversal, so no O(live) buffer is ever materialized.
fn runQuery(
    txn: anytype,
    s: *const Scan,
    preds: []const Predicate,
    allocator: std.mem.Allocator,
    ctx: anytype,
    comptime onMatch: fn (@TypeOf(ctx), u64, u64) anyerror!void,
) !void {
    if (pickDriving(s, preds)) |di| {
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(allocator);
        try collectCandidatePairs(txn, s, preds[di], &pairs, allocator);
        for (pairs.items) |pr| {
            if (try evalRow(txn, s, pr.row, preds)) try onMatch(ctx, pr.okey, pr.row);
        }
        return;
    }
    const Stream = struct {
        txn: @TypeOf(txn),
        s: *const Scan,
        preds: []const Predicate,
        inner: @TypeOf(ctx),
        fn onEntry(self: @This(), okey: u64, row: u64) anyerror!void {
            if (try evalRow(self.txn, self.s, row, self.preds)) try onMatch(self.inner, okey, row);
        }
    };
    try index.forEachEntry(txn, s.keyrow_index_ref, Stream{ .txn = txn, .s = s, .preds = preds, .inner = ctx }, Stream.onEntry);
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
    try validateProps(&s, preds);
    const Sink = struct {
        out: *std.ArrayList(u64),
        allocator: std.mem.Allocator,
        fn onMatch(self: @This(), okey: u64, _: u64) anyerror!void {
            try self.out.append(self.allocator, okey);
        }
    };
    try runQuery(txn, &s, preds, allocator, Sink{ .out = out, .allocator = allocator }, Sink.onMatch);
}

// Number of live rows satisfying all predicates. The full-scan path streams,
// so this allocates nothing proportional to the table.
pub fn countWhere(txn: anytype, cat: Ref, preds: []const Predicate, allocator: std.mem.Allocator) !u64 {
    const s = try openScan(txn, cat);
    try validateProps(&s, preds);
    var n: u64 = 0;
    const Sink = struct {
        n: *u64,
        fn onMatch(self: @This(), _: u64, _: u64) anyerror!void {
            self.n.* += 1;
        }
    };
    try runQuery(txn, &s, preds, allocator, Sink{ .n = &n }, Sink.onMatch);
    return n;
}

pub const Aggregate = struct { count: u64, sum: u64, min: ?u64, max: ?u64 };

// Aggregate an int property over the live rows satisfying all predicates.
// `sum` wraps on overflow (wrapping add); min/max are null when no row matches.
pub fn aggregateInt(txn: anytype, cat: Ref, prop: usize, preds: []const Predicate, allocator: std.mem.Allocator) !Aggregate {
    const s = try openScan(txn, cat);
    try validateProps(&s, preds);
    if (prop >= s.prop_count) return error.BadProp;
    var agg = Aggregate{ .count = 0, .sum = 0, .min = null, .max = null };
    const Sink = struct {
        txn: @TypeOf(txn),
        s: *const Scan,
        prop: usize,
        agg: *Aggregate,
        fn onMatch(self: @This(), _: u64, row: u64) anyerror!void {
            const val = try Column.get(self.txn, self.s.prop_refs[self.prop], row);
            self.agg.count += 1;
            self.agg.sum +%= val;
            if (self.agg.min == null or val < self.agg.min.?) self.agg.min = val;
            if (self.agg.max == null or val > self.agg.max.?) self.agg.max = val;
        }
    };
    try runQuery(txn, &s, preds, allocator, Sink{ .txn = txn, .s = &s, .prop = prop, .agg = &agg }, Sink.onMatch);
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
    if (prop >= v.prop_count) return error.BadProp;
    const col = v.propColRef(prop);
    const SortPair = struct { val: u64, key: u64 };
    const pairs = try allocator.alloc(SortPair, okeys.len);
    defer allocator.free(pairs);
    for (okeys, 0..) |k, i| {
        // A caller-supplied okey that no longer resolves (stale or deleted) is
        // an input error, not a crash.
        const row = (try catalog.okeyToRow(txn, cat, k)) orelse return error.NotFound;
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

test {
    _ = @import("queryTests.zig");
}
