const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const cnode = @import("column_node.zig");
const inode = @import("index_node.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const DeletionRule = catalog.DeletionRule;
const max_prop_count = catalog.max_prop_count;

// ---------------------------------------------------------------------------
// Bottom-up bulk tree builders.
//
// These build a complete, balanced tree directly from sorted input rather than
// inserting one element at a time. Leaves are packed to capacity in key order,
// then inner levels are stacked on top in runs of FANOUT until a single root
// remains. The produced nodes are byte-for-byte the same on-disk format the
// sequential readers expect, so a bulk-built tree is indistinguishable from one
// grown via the normal append/insert path.
// ---------------------------------------------------------------------------

pub const ValueOkeys = struct { value: u64, okeys: []const u64 };

/// Build a column tree holding `values` at row indices 0..values.len. Returns
/// the root Ref. Equivalent to Column.create followed by an append per value.
pub fn bulkColumn(txn: *WriteTxn, values: []const u64) !Ref {
    if (values.len == 0) return Column.create(txn);
    const al = txn.db.store.allocator;
    const cap: usize = cnode.LEAF_CAP;
    const fan: usize = cnode.FANOUT;

    // Current level: a list of child refs and the value count under each child.
    var refs = std.ArrayList(u64).empty;
    defer refs.deinit(al);
    var counts = std.ArrayList(u64).empty;
    defer counts.deinit(al);

    // Pack leaves to capacity in row order.
    var i: usize = 0;
    while (i < values.len) {
        const end = @min(i + cap, values.len);
        const a = try txn.alloc(cnode.leaf_node_size);
        _ = cnode.encodeLeaf(a.bytes, values[i..end]);
        try refs.append(al, a.ref);
        try counts.append(al, @intCast(end - i));
        i = end;
    }

    // Stack inner levels until a single root remains. A column inner node stores
    // (child_ref, subtree_count); the parent's own count is the sum of its
    // children's counts.
    while (refs.items.len > 1) {
        var next_refs = std.ArrayList(u64).empty;
        var next_counts = std.ArrayList(u64).empty;
        var j: usize = 0;
        while (j < refs.items.len) {
            const end = @min(j + fan, refs.items.len);
            const a = try txn.alloc(cnode.inner_node_size);
            _ = cnode.encodeInner(a.bytes, refs.items[j..end], counts.items[j..end]);
            var total: u64 = 0;
            for (counts.items[j..end]) |c| total += c;
            try next_refs.append(al, a.ref);
            try next_counts.append(al, total);
            j = end;
        }
        refs.deinit(al);
        counts.deinit(al);
        refs = next_refs;
        counts = next_counts;
    }
    return refs.items[0];
}

/// Build a u64 index over strictly-ascending `keys` with parallel `vals`.
/// Returns the root Ref. Equivalent to Index.create plus an insert per pair.
pub fn bulkIndex(txn: *WriteTxn, keys: []const u64, vals: []const u64) !Ref {
    std.debug.assert(keys.len == vals.len);
    if (std.debug.runtime_safety) {
        var p: usize = 1;
        while (p < keys.len) : (p += 1) std.debug.assert(keys[p] > keys[p - 1]);
    }
    if (keys.len == 0) return Index.create(txn);
    const al = txn.db.store.allocator;
    const cap: usize = inode.LEAF_CAP;
    const fan: usize = inode.FANOUT;

    // Current level: child refs and the low key (first key) of each child.
    var refs = std.ArrayList(u64).empty;
    defer refs.deinit(al);
    var lows = std.ArrayList(u64).empty;
    defer lows.deinit(al);

    // Pack leaves to capacity in key order.
    var i: usize = 0;
    while (i < keys.len) {
        const end = @min(i + cap, keys.len);
        const a = try txn.alloc(inode.leaf_node_size);
        _ = inode.encodeLeaf(a.bytes, keys[i..end], vals[i..end]);
        try refs.append(al, a.ref);
        try lows.append(al, keys[i]);
        i = end;
    }

    // Stack inner levels. An index inner node stores (child_ref, low_key); the
    // parent's own low key is the low key of its first child.
    while (refs.items.len > 1) {
        var next_refs = std.ArrayList(u64).empty;
        var next_lows = std.ArrayList(u64).empty;
        var j: usize = 0;
        while (j < refs.items.len) {
            const end = @min(j + fan, refs.items.len);
            const a = try txn.alloc(inode.inner_node_size);
            _ = inode.encodeInner(a.bytes, refs.items[j..end], lows.items[j..end]);
            try next_refs.append(al, a.ref);
            try next_lows.append(al, lows.items[j]);
            j = end;
        }
        refs.deinit(al);
        lows.deinit(al);
        refs = next_refs;
        lows = next_lows;
    }
    return refs.items[0];
}

/// Build a value index (value -> inner okey-set) from `entries`, sorted by
/// value, each with ascending okeys. Each inner set maps okey -> 1, matching
/// the shape objects.viAdd maintains (value -> Index{okey -> 1}).
pub fn bulkValueIndex(txn: *WriteTxn, entries: []const ValueOkeys) !Ref {
    if (entries.len == 0) return Index.create(txn);
    const al = txn.db.store.allocator;

    const values = try al.alloc(u64, entries.len);
    defer al.free(values);
    const inner_roots = try al.alloc(u64, entries.len);
    defer al.free(inner_roots);

    // A reusable buffer of 1s big enough for the largest okey set.
    var max_okeys: usize = 0;
    for (entries) |e| max_okeys = @max(max_okeys, e.okeys.len);
    const ones = try al.alloc(u64, max_okeys);
    defer al.free(ones);
    @memset(ones, 1);

    for (entries, 0..) |e, k| {
        values[k] = e.value;
        inner_roots[k] = try bulkIndex(txn, e.okeys, ones[0..e.okeys.len]);
    }

    return bulkIndex(txn, values, inner_roots);
}

// ---------------------------------------------------------------------------
// Bulk import orchestrator.
//
// bulkImport ingests a whole table of rows into an EMPTY type in one shot,
// building every column and index bottom-up so the result is indistinguishable
// from inserting the same rows one at a time in primary-key order. The columns,
// version/live columns, pk index, key->row index, and per-indexed-property value
// indexes are all built directly from the sorted input.
//
// Object-key convention (matched to objects.insert): a fresh insert takes the
// catalog's current next_key as the new row's okey and assigns physical row =
// next_row, then bumps both by one. Inserting the rows in ascending-pk order
// therefore gives the r-th-smallest pk an okey of (start_next_key + r) and a
// physical row of r. bulkImport reproduces exactly that mapping: it sorts by pk,
// then assigns okey_r = old_next_key + r and physical row r = r. So a bulk row
// and its single-insert twin resolve pk -> okey -> row identically, and every
// lookup, scan, and value-index query matches.
//
// All rejections happen BEFORE any node is written, so a bad input can never
// half-commit. Phase 1 excludes link/link_set properties. The CALLER commits.
pub fn bulkImport(
    txn: *WriteTxn,
    cat: Ref,
    rows: []const []const u64,
    opts: struct { presorted: bool = false },
) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    if (v.next_row != 0) return error.TypeNotEmpty;
    const prop_count = v.prop_count;
    const old_next_key = v.next_key;

    // Capture every per-property field into locals before any allocation can
    // grow/remap the file and invalidate the CatalogView bytes slice. Reject a
    // link-bearing type here, before a single node is written.
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var backlinks: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]DeletionRule = undefined;
    var idxf: [max_prop_count]bool = undefined;
    {
        var j: usize = 0;
        while (j < prop_count) : (j += 1) {
            const k = v.kind(j);
            if (k == .link or k == .link_set) return error.UnsupportedForBulk;
            kinds[j] = k;
            elems[j] = v.elemKind(j);
            backlinks[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
            idxf[j] = v.indexed(j);
        }
    }

    // Validate row widths up front: a single malformed row aborts before any write.
    for (rows) |row| {
        if (row.len != prop_count) return error.BadRow;
    }

    const n = rows.len;
    const al = txn.db.store.allocator;

    // Determine the primary-key sort order. perm[r] is the input index of the
    // r-th row in ascending-pk order.
    const perm = try al.alloc(usize, n);
    defer al.free(perm);
    for (perm, 0..) |*x, i| x.* = i;
    if (opts.presorted) {
        if (std.debug.runtime_safety) {
            var i: usize = 1;
            while (i < n) : (i += 1) std.debug.assert(rows[i][0] > rows[i - 1][0]);
        }
    } else {
        std.mem.sort(usize, perm, rows, struct {
            fn lt(rs: []const []const u64, a: usize, b: usize) bool {
                return rs[a][0] < rs[b][0];
            }
        }.lt);
    }
    // Reject a duplicate primary key (adjacent equal after sort) before writing.
    {
        var r: usize = 1;
        while (r < n) : (r += 1) {
            if (rows[perm[r]][0] == rows[perm[r - 1]][0]) return error.DuplicateKey;
        }
    }

    // --- All validation passed; build the tree roots bottom-up. ---

    // Property columns: gather each property's values in sorted-row order.
    var prop_col_refs: [max_prop_count]Ref = undefined;
    {
        const col_vals = try al.alloc(u64, n);
        defer al.free(col_vals);
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            for (perm, 0..) |src, r| col_vals[r] = rows[src][p];
            prop_col_refs[p] = try bulkColumn(txn, col_vals[0..n]);
        }
    }

    // Version and live columns: one stamp per row. The version stamp matches
    // objects.insert (txn.new_version), so a bulk row carries the same version a
    // single-insert twin committed in the same transaction would; live = 1.
    const stamps = try al.alloc(u64, n);
    defer al.free(stamps);
    @memset(stamps, txn.new_version);
    const version_col_ref = try bulkColumn(txn, stamps[0..n]);
    @memset(stamps, 1);
    const live_col_ref = try bulkColumn(txn, stamps[0..n]);

    // pk index (pk -> okey) and key->row index (okey -> physical row). okeys are
    // assigned in sorted-pk order from the type's current next_key, so
    // okey_r == old_next_key + r and physical row r == r.
    const pks = try al.alloc(u64, n);
    defer al.free(pks);
    const okeys = try al.alloc(u64, n);
    defer al.free(okeys);
    const phys_rows = try al.alloc(u64, n);
    defer al.free(phys_rows);
    for (perm, 0..) |src, r| {
        pks[r] = rows[src][0];
        okeys[r] = old_next_key + @as(u64, @intCast(r));
        phys_rows[r] = @intCast(r);
    }
    const pk_index_ref = try bulkIndex(txn, pks[0..n], okeys[0..n]);
    const keyrow_index_ref = try bulkIndex(txn, okeys[0..n], phys_rows[0..n]);

    // Value indexes: for each indexed property, group its okeys by value.
    var value_index_refs: [max_prop_count]Ref = undefined;
    {
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            value_index_refs[p] = if (idxf[p])
                try buildPropValueIndex(txn, rows, perm, p, old_next_key, al)
            else
                0;
        }
    }

    return catalog.writeCatalog(
        txn,
        prop_count,
        @intCast(n), // next_row
        keyrow_index_ref,
        old_next_key + @as(u64, @intCast(n)), // next_key
        pk_index_ref,
        version_col_ref,
        live_col_ref,
        prop_col_refs[0..prop_count],
        kinds[0..prop_count],
        elems[0..prop_count],
        backlinks[0..prop_count],
        targets[0..prop_count],
        rules[0..prop_count],
        value_index_refs[0..prop_count],
        idxf[0..prop_count],
    );
}

// Build the value index for indexed property `p`: emit (value -> {okey -> 1})
// with values ascending and each inner okey set ascending, matching the shape
// objects.viAdd maintains. okeys are assigned in sorted-pk order (okey_r =
// old_next_key + r), so sorting (value, okey) pairs yields ascending okeys
// within each value group.
fn buildPropValueIndex(
    txn: *WriteTxn,
    rows: []const []const u64,
    perm: []const usize,
    p: usize,
    old_next_key: u64,
    al: std.mem.Allocator,
) !Ref {
    const n = perm.len;
    const Pair = struct { value: u64, okey: u64 };
    const pairs = try al.alloc(Pair, n);
    defer al.free(pairs);
    for (perm, 0..) |src, r| pairs[r] = .{ .value = rows[src][p], .okey = old_next_key + @as(u64, @intCast(r)) };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            if (a.value != b.value) return a.value < b.value;
            return a.okey < b.okey;
        }
    }.lt);

    // A contiguous okey buffer in (value, okey) order; each entry's okeys slice
    // points into it.
    const sorted_okeys = try al.alloc(u64, n);
    defer al.free(sorted_okeys);
    for (pairs, 0..) |pr, i| sorted_okeys[i] = pr.okey;

    var entries = std.ArrayList(ValueOkeys).empty;
    defer entries.deinit(al);
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and pairs[j].value == pairs[i].value) j += 1;
        try entries.append(al, .{ .value = pairs[i].value, .okeys = sorted_okeys[i..j] });
        i = j;
    }
    return bulkValueIndex(txn, entries.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const objects = @import("objects.zig");
const query = @import("query.zig");
const typedir = @import("typedir.zig");

fn bulkTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

fn checkColumnSize(w: *WriteTxn, n: usize) !void {
    const values = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(values);
    for (values, 0..) |*v, i| v.* = @as(u64, i) * 7;

    const built = try bulkColumn(w, values);

    var seq = try Column.create(w);
    for (values) |v| seq = try Column.append(w, seq, v);

    try testing.expectEqual(try Column.len(w, seq), try Column.len(w, built));
    try testing.expectEqual(@as(u64, n), try Column.len(w, built));
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(try Column.get(w, seq, i), try Column.get(w, built, i));
    }
}

test "bulkColumn equals sequential appends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcol.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColumnSize(&w, 1000);
    w.deinit();
}

test "bulkColumn boundary sizes: 0, 1, LEAF_CAP, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkcolsizes.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkColumnSize(&w, 0);
    try checkColumnSize(&w, 1);
    try checkColumnSize(&w, cnode.LEAF_CAP); // single full leaf
    try checkColumnSize(&w, @as(usize, cnode.LEAF_CAP) * cnode.FANOUT + 1); // 3 levels
    w.deinit();
}

const IdxCollector = struct {
    keys: *std.ArrayList(u64),
    vals: *std.ArrayList(u64),
    fn onEntry(self: @This(), key: u64, val: u64) !void {
        try self.keys.append(testing.allocator, key);
        try self.vals.append(testing.allocator, val);
    }
};

fn checkIndexSize(w: *WriteTxn, n: usize) !void {
    const keys = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(keys);
    const vals = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(vals);
    for (keys, vals, 0..) |*k, *v, i| {
        k.* = @intCast(i);
        v.* = @as(u64, i) * 10;
    }

    const built = try bulkIndex(w, keys, vals);

    var seq = try Index.create(w);
    for (keys, vals) |k, v| seq = try Index.insert(w, seq, k, v);

    try testing.expectEqual(@as(u64, n), try Index.count(w, built));
    try testing.expectEqual(try Index.count(w, seq), try Index.count(w, built));

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try testing.expectEqual(try Index.get(w, seq, i), try Index.get(w, built, i));
    }

    var bk = std.ArrayList(u64).empty;
    defer bk.deinit(testing.allocator);
    var bv = std.ArrayList(u64).empty;
    defer bv.deinit(testing.allocator);
    try Index.forEachEntry(w, built, IdxCollector{ .keys = &bk, .vals = &bv }, IdxCollector.onEntry);
    try testing.expectEqual(n, bk.items.len);
    for (bk.items, bv.items, 0..) |k, v, j| {
        try testing.expectEqual(@as(u64, j), k);
        try testing.expectEqual(@as(u64, j) * 10, v);
    }
}

test "bulkIndex equals sequential inserts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidx.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkIndexSize(&w, 1000);
    w.deinit();
}

test "bulkIndex boundary sizes: 0, 1, LEAF_CAP, multi-inner-level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkidxsizes.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    try checkIndexSize(&w, 0);
    try checkIndexSize(&w, 1);
    try checkIndexSize(&w, inode.LEAF_CAP);
    try checkIndexSize(&w, @as(usize, inode.LEAF_CAP) * inode.FANOUT + 1);
    w.deinit();
}

const SetCollector = struct {
    keys: *std.ArrayList(u64),
    fn onKey(self: @This(), key: u64) !void {
        try self.keys.append(testing.allocator, key);
    }
};

fn collectSet(w: *WriteTxn, set_root: Ref, out: *std.ArrayList(u64)) !void {
    out.clearRetainingCapacity();
    try Index.forEachKey(w, set_root, SetCollector{ .keys = out }, SetCollector.onKey);
}

test "bulkValueIndex equals sequential maintenance" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "bulkvi.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();

    const N: u64 = 1000;
    const num_values: u64 = 100;

    // Build the grouped entries: value v=i%100 maps to okeys {i : i%100==v}, ascending.
    var entries = std.ArrayList(ValueOkeys).empty;
    defer {
        for (entries.items) |e| testing.allocator.free(e.okeys);
        entries.deinit(testing.allocator);
    }
    var v: u64 = 0;
    while (v < num_values) : (v += 1) {
        var okeys = std.ArrayList(u64).empty;
        var i: u64 = v; // first okey with i%100==v
        while (i < N) : (i += num_values) try okeys.append(testing.allocator, i);
        try entries.append(testing.allocator, .{ .value = v, .okeys = try okeys.toOwnedSlice(testing.allocator) });
    }

    const built = try bulkValueIndex(&w, entries.items);

    // Sequential maintenance mirror: for each (value, okey) add okey to the inner
    // set for value, exactly as objects.viAdd does.
    var seq = try Index.create(&w);
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const value = i % num_values;
        const existing = try Index.get(&w, seq, value);
        var set_root = existing orelse try Index.create(&w);
        set_root = try Index.insert(&w, set_root, i, 1);
        seq = try Index.insert(&w, seq, value, set_root);
    }

    // Compare the inner okey set for every value.
    var built_set = std.ArrayList(u64).empty;
    defer built_set.deinit(testing.allocator);
    var seq_set = std.ArrayList(u64).empty;
    defer seq_set.deinit(testing.allocator);

    v = 0;
    while (v < num_values) : (v += 1) {
        const b_inner = (try Index.get(&w, built, v)) orelse return error.MissingValue;
        const s_inner = (try Index.get(&w, seq, v)) orelse return error.MissingValue;
        try collectSet(&w, b_inner, &built_set);
        try collectSet(&w, s_inner, &seq_set);
        try testing.expectEqualSlices(u64, seq_set.items, built_set.items);
    }
    w.deinit();
}

// Schema shared by the orchestrator tests: int pk, int value, int category (indexed).
const import_defs = [_]catalog.PropDef{
    .{ .kind = .int },
    .{ .kind = .int },
    .{ .kind = .int, .indexed = true },
};

test "bulkImport equals row-by-row for a scalar indexed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_a = try bulkTmpPath(testing.allocator, &tmp, "import_a.airdb");
    defer testing.allocator.free(path_a);
    const path_b = try bulkTmpPath(testing.allocator, &tmp, "import_b.airdb");
    defer testing.allocator.free(path_b);

    const N: u64 = 5000;

    // Shuffled input order for the bulk import: pks arrive out of order, so the
    // import must sort them and reproduce the same okey-per-pk mapping the
    // in-order row-by-row twin produces.
    const order = try testing.allocator.alloc(u64, N);
    defer testing.allocator.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE12345678);
    prng.random().shuffle(u64, order);

    const storage = try testing.allocator.alloc([3]u64, N);
    defer testing.allocator.free(storage);
    const row_slices = try testing.allocator.alloc([]const u64, N);
    defer testing.allocator.free(row_slices);
    for (order, 0..) |pk, k| {
        storage[k] = .{ pk, pk * 3, pk % 50 };
        row_slices[k] = &storage[k];
    }

    // db A: bulk import inside a one-type directory so verifyIntegrity audits it.
    {
        var db = try Db.create(testing.allocator, path_a);
        defer db.deinit();
        var w = try db.beginWrite();
        const dir = try typedir.createTypes(&w, &.{&import_defs}, &.{false});
        const cat0 = try typedir.catalogRef(&w, dir, 0);
        const new_cat = try bulkImport(&w, cat0, row_slices, .{});
        const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
        w.setRoot(new_dir);
        _ = try w.commit();
        try db.verifyIntegrity(); // both value-index directions, in memory
    }

    // db B: the same rows inserted one at a time, in ascending-pk order.
    {
        var db = try Db.create(testing.allocator, path_b);
        defer db.deinit();
        var w = try db.beginWrite();
        var cat = try catalog.createDefs(&w, &import_defs);
        var pk: u64 = 0;
        while (pk < N) : (pk += 1) cat = (try objects.insert(&w, cat, &.{ pk, pk * 3, pk % 50 })).cat;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // Reopen A from disk (durability) and compare against B.
    var da = try Db.open(testing.allocator, path_a);
    defer da.deinit();
    try da.verifyIntegrity(); // audit again after reopen
    var dbb = try Db.open(testing.allocator, path_b);
    defer dbb.deinit();

    var ra = try da.beginRead();
    defer ra.end();
    var rb = try dbb.beginRead();
    defer rb.end();

    const cat_a = try typedir.catalogRef(&ra, ra.root(), 0);
    const cat_b = rb.root();

    // Counts equal.
    try testing.expectEqual(N, try catalog.liveCount(&ra, cat_a));
    try testing.expectEqual(try catalog.liveCount(&rb, cat_b), try catalog.liveCount(&ra, cat_a));

    // Every pk lookup equal: property values AND row version.
    var pk: u64 = 0;
    while (pk < N) : (pk += 1) {
        var oa: [3]u64 = undefined;
        var ob: [3]u64 = undefined;
        const va = try objects.getByPk(&ra, cat_a, pk, &oa);
        const vb = try objects.getByPk(&rb, cat_b, pk, &ob);
        try testing.expectEqual(vb, va);
        try testing.expectEqualSlices(u64, &ob, &oa);
    }

    // Full-scan order equal (ascending okey for both).
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{}, &sb, testing.allocator);
        try testing.expectEqualSlices(u64, sb.items, sa.items);
    }

    // Indexed query: category == 7, equal sorted okey sets.
    {
        var sa = std.ArrayList(u64).empty;
        defer sa.deinit(testing.allocator);
        var sb = std.ArrayList(u64).empty;
        defer sb.deinit(testing.allocator);
        try query.where(&ra, cat_a, &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &sa, testing.allocator);
        try query.where(&rb, cat_b, &.{.{ .prop = 2, .op = .eq, .value = 7 }}, &sb, testing.allocator);
        std.mem.sort(u64, sa.items, {}, std.sort.asc(u64));
        std.mem.sort(u64, sb.items, {}, std.sort.asc(u64));
        try testing.expectEqualSlices(u64, sb.items, sa.items);
        try testing.expectEqual(@as(usize, 100), sa.items.len); // pk%50==7 over 0..5000
    }
}

test "bulkImport rejects a non-empty type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_nonempty.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    var cat = try catalog.createDefs(&w, &import_defs);
    cat = (try objects.insert(&w, cat, &.{ 1, 3, 1 })).cat;

    const more = [_][]const u64{ &.{ 10, 30, 5 }, &.{ 11, 33, 6 } };
    try testing.expectError(error.TypeNotEmpty, bulkImport(&w, cat, &more, .{}));

    // The type is unchanged: still one live row, intact.
    try testing.expectEqual(@as(u64, 1), try catalog.liveCount(&w, cat));
    var out: [3]u64 = undefined;
    try testing.expect((try objects.getByPk(&w, cat, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[0]);
    try testing.expectEqual(@as(u64, 3), out[1]);
    try testing.expectEqual(@as(u64, 1), out[2]);
    w.deinit();
}

test "bulkImport rejects duplicate pk before committing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_dup.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try catalog.createDefs(&w, &import_defs);

    const dup = [_][]const u64{ &.{ 5, 1, 0 }, &.{ 6, 2, 0 }, &.{ 5, 3, 0 } };
    try testing.expectError(error.DuplicateKey, bulkImport(&w, cat, &dup, .{}));

    // Nothing was written: the type is still empty.
    try testing.expectEqual(@as(u64, 0), try catalog.liveCount(&w, cat));
    const cv = try catalog.loadCatalog(&w, cat);
    try testing.expectEqual(@as(u64, 0), cv.next_row);
    try testing.expectEqual(@as(u64, 0), cv.next_key);
    w.deinit();
}

test "bulkImport rejects a link-bearing type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try bulkTmpPath(testing.allocator, &tmp, "import_link.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const link_defs = [_]catalog.PropDef{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } };
    const cat = try catalog.createDefs(&w, &link_defs);

    const rws = [_][]const u64{&.{ 1, 0 }};
    try testing.expectError(error.UnsupportedForBulk, bulkImport(&w, cat, &rws, .{}));
    w.deinit();
}

test "bulkImport edge sizes: empty, single, LEAF_CAP" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sizes = [_]u64{ 0, 1, @as(u64, cnode.LEAF_CAP) };
    for (sizes, 0..) |n, si| {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "edge_{d}.airdb", .{si});
        const path = try bulkTmpPath(testing.allocator, &tmp, name);
        defer testing.allocator.free(path);

        const storage = try testing.allocator.alloc([3]u64, n);
        defer testing.allocator.free(storage);
        const row_slices = try testing.allocator.alloc([]const u64, n);
        defer testing.allocator.free(row_slices);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            storage[i] = .{ i, i * 3, i % 7 };
            row_slices[i] = &storage[i];
        }

        var db = try Db.create(testing.allocator, path);
        defer db.deinit();
        {
            var w = try db.beginWrite();
            const dir = try typedir.createTypes(&w, &.{&import_defs}, &.{false});
            const cat0 = try typedir.catalogRef(&w, dir, 0);
            const new_cat = try bulkImport(&w, cat0, row_slices, .{ .presorted = true });
            const new_dir = try typedir.setCatalogRef(&w, dir, 0, new_cat);
            w.setRoot(new_dir);
            _ = try w.commit();
        }
        try db.verifyIntegrity();

        var r = try db.beginRead();
        defer r.end();
        const cat = try typedir.catalogRef(&r, r.root(), 0);
        try testing.expectEqual(n, try catalog.liveCount(&r, cat));
        const cv = try catalog.loadCatalog(&r, cat);
        try testing.expectEqual(n, cv.next_row);
        try testing.expectEqual(n, cv.next_key);
        if (n > 0) {
            var out: [3]u64 = undefined;
            const last = n - 1;
            try testing.expect((try objects.getByPk(&r, cat, last, &out)) != null);
            try testing.expectEqual(last, out[0]);
            try testing.expectEqual(last * 3, out[1]);
            try testing.expectEqual(last % 7, out[2]);
        }
    }
}
