const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const inode = @import("index_node.zig");
const catalog = @import("catalog.zig");
const rawRows = @import("rows.zig");

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
// remains (packLeaves/stackInner/collapseToRoot live with each tree's own
// operations in column.zig and index.zig).
// ---------------------------------------------------------------------------

pub const ValueOkeys = struct { value: u64, okeys: []const u64 };

/// Build a column tree holding `values` at row indices 0..values.len. Returns
/// the root Ref. Equivalent to Column.create followed by an append per value.
pub fn bulkColumn(txn: *WriteTxn, values: []const u64) !Ref {
    if (values.len == 0) return Column.create(txn);
    const al = txn.db.store.allocator;

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Column.packLeaves(txn, values, al);
    defer level.deinit(al);
    try Column.collapseToRoot(txn, &level, al);
    return level.items[0].ref;
}

// Deref an index node, sizing the read by its kind byte (leaf vs inner).
fn derefIdxNode(txn: *WriteTxn, ref: Ref) ![]const u8 {
    const kb = try txn.deref(ref, 1);
    return switch (kb[0]) {
        inode.kind_leaf => txn.deref(ref, inode.leaf_node_size),
        inode.kind_inner => txn.deref(ref, inode.inner_node_size),
        else => error.Corrupt,
    };
}

// When the BLIND rightmost leaf of the index is empty (removals emptied it),
// return its parent-recorded low key; null otherwise (non-empty leaf, or an
// empty ROOT leaf, which has no recorded low). The recorded low propagates
// identically up every level of the rightmost path, so it is the single value
// an appended run's first key must clear (see the qualification in bulkAppend).
fn emptyRightmostLow(txn: *WriteTxn, root: Ref) !?u64 {
    var cur: Ref = root;
    var recorded_low: ?u64 = null;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= Index.max_depth) return error.Corrupt;
        const nb = try derefIdxNode(txn, cur);
        if (nb[0] == inode.kind_leaf) {
            if ((try inode.parseLeaf(nb)).count != 0) return null;
            return recorded_low; // null when the empty leaf IS the root
        }
        const iv = try inode.parseInner(nb);
        recorded_low = iv.lowKey(iv.child_count - 1);
        cur = iv.childRef(iv.child_count - 1);
    }
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

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Index.packLeaves(txn, keys, vals, al);
    defer level.deinit(al);
    try Index.collapseToRoot(txn, &level, al);
    return level.items[0].ref;
}

/// Build a value index (value -> inner okey-set) from `entries`, sorted by
/// value, each with ascending okeys. Each inner set maps okey -> 1, matching
/// the shape rows.viAdd maintains (value -> Index{okey -> 1}).
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
// Object-key convention (matched to rows.insert): a fresh insert takes the
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
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    if (s.next_row != 0) return error.TypeNotEmpty;
    const prop_count = s.prop_count;
    const old_next_key = s.next_key;

    // Reject a link-bearing type here, before a single node is written.
    {
        var j: usize = 0;
        while (j < prop_count) : (j += 1) {
            const k = s.props[j].kind;
            if (k == .link or k == .link_set) return error.UnsupportedForBulk;
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

    // The type is empty, but its creation pre-allocated empty columns and
    // indexes that the bulk-built roots replace; free them so the import
    // leaves no orphan nodes behind.
    {
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            try Column.freeTree(txn, s.props[p].col);
            if (s.props[p].indexed) try Index.freeTree(txn, s.props[p].value_index);
        }
    }
    try Column.freeTree(txn, s.version_col_ref);
    try Column.freeTree(txn, s.live_col_ref);
    try Index.freeTree(txn, s.pk_index_ref);
    try Index.freeTree(txn, s.keyrow_index_ref);

    // Property columns: gather each property's values in sorted-row order.
    {
        const col_vals = try al.alloc(u64, n);
        defer al.free(col_vals);
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            for (perm, 0..) |src, r| col_vals[r] = rows[src][p];
            s.props[p].col = try bulkColumn(txn, col_vals[0..n]);
        }
    }

    // Version and live columns: one stamp per row. The version stamp matches
    // rows.insert (txn.new_version), so a bulk row carries the same version a
    // single-insert twin committed in the same transaction would; live = 1.
    const stamps = try al.alloc(u64, n);
    defer al.free(stamps);
    @memset(stamps, txn.new_version);
    s.version_col_ref = try bulkColumn(txn, stamps[0..n]);
    @memset(stamps, 1);
    s.live_col_ref = try bulkColumn(txn, stamps[0..n]);

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
    s.pk_index_ref = try bulkIndex(txn, pks[0..n], okeys[0..n]);
    s.keyrow_index_ref = try bulkIndex(txn, okeys[0..n], phys_rows[0..n]);

    // Value indexes: for each indexed property, group its okeys by value.
    {
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            if (s.props[p].indexed) {
                s.props[p].value_index = try buildPropValueIndex(txn, rows, perm, p, old_next_key, al);
            }
        }
    }

    s.next_row = @intCast(n);
    s.next_key = old_next_key + @as(u64, @intCast(n));
    return s.replace(txn);
}

// Build the value index for indexed property `p`: emit (value -> {okey -> 1})
// with values ascending and each inner okey set ascending, matching the shape
// rows.viAdd maintains. okeys are assigned in sorted-pk order (okey_r =
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
// Bulk append orchestrator.
//
// bulkAppend fast-paths a batch of rows whose primary keys all land strictly to
// the RIGHT of the type's current key space onto the right edge of every tree,
// without touching any left subtree. The result is byte-identical to inserting
// the same rows one at a time in ascending-pk order: each new row gets the next
// physical row and object key in batch order, the version stamp matches
// rows.insert (txn.new_version), live = 1, and the pk and key->row indexes
// grow only along their rightmost path.
//
// A batch only qualifies when nothing about it would force a non-right-edge
// write: no property is indexed and none is a link/link_set (those maintain
// secondary structures keyed by value/target, not by row), the batch pks are
// strictly ascending and unique, and the smallest batch pk is strictly greater
// than the type's current max pk. Any other shape returns error.NotAppendable
// with NOTHING written, so the caller's fallback can replay row-by-row.
//
// Crucially, every qualification check is read-only and runs BEFORE the first
// node is allocated, so a NotAppendable return leaves the catalog and all trees
// untouched. The CALLER commits.
pub fn bulkAppend(txn: *WriteTxn, cat: Ref, rows: []const []const u64) !Ref {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const prop_count = s.prop_count;

    // Validate row widths first: a single malformed row aborts before any work.
    for (rows) |row| {
        if (row.len != prop_count) return error.BadRow;
    }
    if (rows.len == 0) return cat;

    // Qualify the schema: reject an indexed or link-bearing property -- both
    // keep secondary structures that a pure right-edge append cannot maintain.
    const old_next_row = s.next_row;
    const old_next_key = s.next_key;
    {
        var j: usize = 0;
        while (j < prop_count) : (j += 1) {
            const k = s.props[j].kind;
            if (k == .link or k == .link_set) return error.NotAppendable;
            if (s.props[j].indexed) return error.NotAppendable;
        }
    }

    const n = rows.len;

    // Batch pks must be strictly ascending and unique; any non-ascending or
    // duplicate-in-batch shape is NotAppendable so the fallback handles it
    // (including per-row duplicate detection against the existing rows).
    {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (rows[i][0] <= rows[i - 1][0]) return error.NotAppendable;
        }
    }

    // The smallest batch pk (rows[0][0], since ascending) must clear the current
    // max pk in the type. An empty type (no max) admits any ascending batch.
    if (try Index.maxKey(txn, s.pk_index_ref)) |max_pk| {
        if (rows[0][0] <= max_pk) return error.NotAppendable;
    }

    // If the BLIND rightmost pk-index leaf is empty (removals never merge
    // leaves), its RECORDED LOW may exceed every surviving key -- a pk-history
    // gap. Index.appendRun rebuilds exactly that leaf and derives the new
    // parent low from the batch's first key; a batch below the recorded low
    // would break the ascending-lows invariant and make the appended rows
    // unreachable. Such a batch must take the row-by-row fallback. (The
    // keyrow index is immune: new okeys are allocated above every okey -- and
    // therefore every stale low -- the tree has ever held.)
    if (try emptyRightmostLow(txn, s.pk_index_ref)) |stale_low| {
        if (rows[0][0] < stale_low) return error.NotAppendable;
    }

    // --- Qualified. Nothing has been written yet; build the right-edge runs. ---
    const al = txn.db.store.allocator;

    // Object keys and physical rows are assigned in batch order from the type's
    // current counters, exactly as sequential ascending-pk inserts would: the
    // j-th row gets okey = next_key + j and physical row = next_row + j.
    const pks = try al.alloc(u64, n);
    defer al.free(pks);
    const okeys = try al.alloc(u64, n);
    defer al.free(okeys);
    const phys_rows = try al.alloc(u64, n);
    defer al.free(phys_rows);
    for (rows, 0..) |row, j| {
        pks[j] = row[0];
        okeys[j] = old_next_key + @as(u64, @intCast(j));
        phys_rows[j] = old_next_row + @as(u64, @intCast(j));
    }

    // Property columns: append each property's values in batch order.
    {
        const col_vals = try al.alloc(u64, n);
        defer al.free(col_vals);
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            for (rows, 0..) |row, j| col_vals[j] = row[p];
            s.props[p].col = try Column.appendRun(txn, s.props[p].col, col_vals[0..n], al);
        }
    }

    // Version and live columns: one stamp per row, matching rows.insert.
    const stamps = try al.alloc(u64, n);
    defer al.free(stamps);
    @memset(stamps, txn.new_version);
    s.version_col_ref = try Column.appendRun(txn, s.version_col_ref, stamps[0..n], al);
    @memset(stamps, 1);
    s.live_col_ref = try Column.appendRun(txn, s.live_col_ref, stamps[0..n], al);

    // pk index (pk -> okey) and key->row index (okey -> physical row). Both runs
    // land on the right edge: batch pks are ascending and above the current max,
    // and okeys are consecutive from next_key (thus above every existing okey).
    s.pk_index_ref = try Index.appendRun(txn, s.pk_index_ref, pks[0..n], okeys[0..n], al);
    s.keyrow_index_ref = try Index.appendRun(txn, s.keyrow_index_ref, okeys[0..n], phys_rows[0..n], al);

    s.next_row = old_next_row + @as(u64, @intCast(n));
    s.next_key = old_next_key + @as(u64, @intCast(n));
    return s.replace(txn);
}

// Try the right-edge fast path; on NotAppendable, fall back to row-by-row
// rows.insert, which handles any schema and detects duplicate keys per row.
pub fn bulkAppendOrInsert(txn: *WriteTxn, cat: Ref, rows: []const []const u64) !Ref {
    return bulkAppend(txn, cat, rows) catch |e| switch (e) {
        error.NotAppendable => fallbackInsert(txn, cat, rows),
        else => e,
    };
}

// Insert every row one at a time, threading the catalog ref. A DuplicateKey from
// rows.insert propagates to the caller. Empty rows return cat unchanged.
//
// Link-bearing schemas are rejected outright: rows.insert writes raw column
// values without backlink maintenance (that is insertTyped's job), so silently
// accepting them here would corrupt the link graph -- the same reason
// bulkImport refuses them.
fn fallbackInsert(txn: *WriteTxn, cat: Ref, rows: []const []const u64) !Ref {
    if (rows.len == 0) return cat;
    {
        const v = try catalog.loadCatalog(txn, cat);
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            const k = v.kind(j);
            if (k == .link or k == .link_set) return error.UnsupportedForBulk;
        }
    }
    var c = cat;
    for (rows) |row| {
        c = (try rawRows.insert(txn, c, row)).cat;
    }
    return c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("bulkTests.zig");
}
