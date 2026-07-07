const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const inode = @import("../trees/indexNode.zig");
const catalog = @import("../schema/catalog.zig");
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

pub const ValueObjectKeys = struct { value: u64, objectKeys: []const u64 };

/// Build a column tree holding `values` at row indices 0..values.len. Returns
/// the root Reference. Equivalent to Column.create followed by an append per value.
pub fn bulkColumn(transaction: *WriteTransaction, values: []const u64) !Reference {
    if (values.len == 0) return Column.create(transaction);
    const al = transaction.database.store.allocator;

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Column.packLeaves(transaction, values, al);
    defer level.deinit(al);
    try Column.collapseToRoot(transaction, &level, al);
    return level.items[0].ref;
}

// Deref an index node, sizing the read by its kind byte (leaf vs inner).
fn derefIdxNode(transaction: *WriteTransaction, ref: Reference) ![]const u8 {
    const kb = try transaction.deref(ref, 1);
    return switch (kb[0]) {
        inode.kind_leaf => transaction.deref(ref, inode.leaf_node_size),
        inode.kind_inner => transaction.deref(ref, inode.inner_node_size),
        else => error.Corrupt,
    };
}

// When the BLIND rightmost leaf of the index is empty (removals emptied it),
// return its parent-recorded low key; null otherwise (non-empty leaf, or an
// empty ROOT leaf, which has no recorded low). The recorded low propagates
// identically up every level of the rightmost path, so it is the single value
// an appended run's first key must clear (see the qualification in bulkAppend).
fn emptyRightmostLow(transaction: *WriteTransaction, root: Reference) !?u64 {
    var cur: Reference = root;
    var recorded_low: ?u64 = null;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= Index.max_depth) return error.Corrupt;
        const nb = try derefIdxNode(transaction, cur);
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
/// Returns the root Reference. Equivalent to Index.create plus an insert per pair.
pub fn bulkIndex(transaction: *WriteTransaction, keys: []const u64, vals: []const u64) !Reference {
    std.debug.assert(keys.len == vals.len);
    if (std.debug.runtime_safety) {
        var p: usize = 1;
        while (p < keys.len) : (p += 1) std.debug.assert(keys[p] > keys[p - 1]);
    }
    if (keys.len == 0) return Index.create(transaction);
    const al = transaction.database.store.allocator;

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Index.packLeaves(transaction, keys, vals, al);
    defer level.deinit(al);
    try Index.collapseToRoot(transaction, &level, al);
    return level.items[0].ref;
}

/// Build a value index (value -> inner objectKey-set) from `entries`, sorted by
/// value, each with ascending objectKeys. Each inner set maps objectKey -> 1, matching
/// the shape rows.viAdd maintains (value -> Index{objectKey -> 1}).
pub fn bulkValueIndex(transaction: *WriteTransaction, entries: []const ValueObjectKeys) !Reference {
    if (entries.len == 0) return Index.create(transaction);
    const al = transaction.database.store.allocator;

    const values = try al.alloc(u64, entries.len);
    defer al.free(values);
    const inner_roots = try al.alloc(u64, entries.len);
    defer al.free(inner_roots);

    // A reusable buffer of 1s big enough for the largest objectKey set.
    var maxObjectKeys: usize = 0;
    for (entries) |e| maxObjectKeys = @max(maxObjectKeys, e.objectKeys.len);
    const ones = try al.alloc(u64, maxObjectKeys);
    defer al.free(ones);
    @memset(ones, 1);

    for (entries, 0..) |e, k| {
        values[k] = e.value;
        inner_roots[k] = try bulkIndex(transaction, e.objectKeys, ones[0..e.objectKeys.len]);
    }

    return bulkIndex(transaction, values, inner_roots);
}

// ---------------------------------------------------------------------------
// Bulk import orchestrator.
//
// bulkImport ingests a whole table of rows into an EMPTY type in one shot,
// building every column and index bottom-up so the result is indistinguishable
// from inserting the same rows one at a time in primary-key order. The columns,
// version/live columns, primaryKey index, key->row index, and per-indexed-property value
// indexes are all built directly from the sorted input.
//
// Object-key convention (matched to rows.insert): a fresh insert takes the
// catalog's current next_key as the new row's objectKey and assigns physical row =
// next_row, then bumps both by one. Inserting the rows in ascending-primaryKey order
// therefore gives the r-th-smallest primaryKey an objectKey of (start_next_key + r) and a
// physical row of r. bulkImport reproduces exactly that mapping: it sorts by primaryKey,
// then assigns objectKeyR = old_next_key + r and physical row r = r. So a bulk row
// and its single-insert twin resolve primaryKey -> objectKey -> row identically, and every
// lookup, scan, and value-index query matches.
//
// All rejections happen BEFORE any node is written, so a bad input can never
// half-commit. Phase 1 excludes link/link_set properties. The CALLER commits.
pub fn bulkImport(
    transaction: *WriteTransaction,
    catalogRef: Reference,
    rows: []const []const u64,
    opts: struct { presorted: bool = false },
) !Reference {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    if (s.next_row != 0) return error.TypeNotEmpty;
    const old_next_key = s.next_key;
    try validateImportInput(&s, rows);

    const al = transaction.database.store.allocator;
    const perm = try primaryKeySortOrder(rows, opts.presorted, al);
    defer al.free(perm);

    // --- All validation passed; build the tree roots bottom-up. ---
    try freePreallocatedTrees(transaction, &s);
    try buildImportTrees(transaction, &s, rows, perm, old_next_key);
    try buildValueIndexes(transaction, &s, rows, perm, old_next_key);

    s.next_row = @intCast(rows.len);
    s.next_key = old_next_key + @as(u64, @intCast(rows.len));
    return s.replace(transaction);
}

// Reject a link-bearing type and any malformed row width here, before a single
// node is written.
fn validateImportInput(s: *const catalog.CatalogSnapshot, rows: []const []const u64) !void {
    var j: usize = 0;
    while (j < s.prop_count) : (j += 1) {
        const k = s.props[j].kind;
        if (k == .link or k == .link_set) return error.UnsupportedForBulk;
    }
    for (rows) |row| {
        if (row.len != s.prop_count) return error.BadRow;
    }
}

// The primary-key sort order of `rows`: perm[r] is the input index of the r-th
// row in ascending-primaryKey order. The caller owns the returned slice. A duplicate
// primary key (adjacent equal after sort) is rejected before anything is
// written. With `presorted`, the input order is trusted (asserted ascending
// under runtime safety) and the sort is skipped.
fn primaryKeySortOrder(
    rows: []const []const u64,
    presorted: bool,
    al: std.mem.Allocator,
) ![]usize {
    const n = rows.len;
    const perm = try al.alloc(usize, n);
    errdefer al.free(perm);
    for (perm, 0..) |*x, i| x.* = i;
    if (presorted) {
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
    var r: usize = 1;
    while (r < n) : (r += 1) {
        if (rows[perm[r]][0] == rows[perm[r - 1]][0]) return error.DuplicateKey;
    }
    return perm;
}

// The type is empty, but its creation pre-allocated empty columns and indexes
// that the bulk-built roots replace; free them so the import leaves no orphan
// nodes behind.
fn freePreallocatedTrees(transaction: *WriteTransaction, s: *const catalog.CatalogSnapshot) !void {
    var p: usize = 0;
    while (p < s.prop_count) : (p += 1) {
        try Column.freeTree(transaction, s.props[p].col);
        if (s.props[p].indexed) try Index.freeTree(transaction, s.props[p].value_index);
    }
    try Column.freeTree(transaction, s.version_col_ref);
    try Column.freeTree(transaction, s.live_col_ref);
    try Index.freeTree(transaction, s.primaryKeyIndexRef);
    try Index.freeTree(transaction, s.keyrow_index_ref);
}

// Build the property columns, version/live columns, and primaryKey/key->row indexes
// bottom-up from the sorted input, storing the new roots into the snapshot.
fn buildImportTrees(
    transaction: *WriteTransaction,
    s: *catalog.CatalogSnapshot,
    rows: []const []const u64,
    perm: []const usize,
    old_next_key: u64,
) !void {
    const n = rows.len;
    const al = transaction.database.store.allocator;

    // Property columns: gather each property's values in sorted-row order.
    {
        const col_vals = try al.alloc(u64, n);
        defer al.free(col_vals);
        var p: usize = 0;
        while (p < s.prop_count) : (p += 1) {
            for (perm, 0..) |src, r| col_vals[r] = rows[src][p];
            s.props[p].col = try bulkColumn(transaction, col_vals[0..n]);
        }
    }

    // Version and live columns: one stamp per row. The version stamp matches
    // rows.insert (transaction.new_version), so a bulk row carries the same version a
    // single-insert twin committed in the same transaction would; live = 1.
    const stamps = try al.alloc(u64, n);
    defer al.free(stamps);
    @memset(stamps, transaction.new_version);
    s.version_col_ref = try bulkColumn(transaction, stamps[0..n]);
    @memset(stamps, 1);
    s.live_col_ref = try bulkColumn(transaction, stamps[0..n]);

    // primaryKey index (primaryKey -> objectKey) and key->row index (objectKey -> physical row). objectKeys are
    // assigned in sorted-primaryKey order from the type's current next_key, so
    // objectKeyR == old_next_key + r and physical row r == r.
    const primaryKeys = try al.alloc(u64, n);
    defer al.free(primaryKeys);
    const objectKeys = try al.alloc(u64, n);
    defer al.free(objectKeys);
    const phys_rows = try al.alloc(u64, n);
    defer al.free(phys_rows);
    for (perm, 0..) |src, r| {
        primaryKeys[r] = rows[src][0];
        objectKeys[r] = old_next_key + @as(u64, @intCast(r));
        phys_rows[r] = @intCast(r);
    }
    s.primaryKeyIndexRef = try bulkIndex(transaction, primaryKeys[0..n], objectKeys[0..n]);
    s.keyrow_index_ref = try bulkIndex(transaction, objectKeys[0..n], phys_rows[0..n]);
}

// Value indexes: for each indexed property, group its objectKeys by value and store
// the built index root into the snapshot.
fn buildValueIndexes(
    transaction: *WriteTransaction,
    s: *catalog.CatalogSnapshot,
    rows: []const []const u64,
    perm: []const usize,
    old_next_key: u64,
) !void {
    const al = transaction.database.store.allocator;
    var p: usize = 0;
    while (p < s.prop_count) : (p += 1) {
        if (s.props[p].indexed) {
            s.props[p].value_index = try buildPropValueIndex(transaction, rows, perm, p, old_next_key, al);
        }
    }
}

// Build the value index for indexed property `p`: emit (value -> {objectKey -> 1})
// with values ascending and each inner objectKey set ascending, matching the shape
// rows.viAdd maintains. objectKeys are assigned in sorted-primaryKey order (objectKeyR =
// old_next_key + r), so sorting (value, objectKey) pairs yields ascending objectKeys
// within each value group.
fn buildPropValueIndex(
    transaction: *WriteTransaction,
    rows: []const []const u64,
    perm: []const usize,
    p: usize,
    old_next_key: u64,
    al: std.mem.Allocator,
) !Reference {
    const n = perm.len;
    const Pair = struct { value: u64, objectKey: u64 };
    const pairs = try al.alloc(Pair, n);
    defer al.free(pairs);
    for (perm, 0..) |src, r| pairs[r] = .{ .value = rows[src][p], .objectKey = old_next_key + @as(u64, @intCast(r)) };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            if (a.value != b.value) return a.value < b.value;
            return a.objectKey < b.objectKey;
        }
    }.lt);

    // A contiguous objectKey buffer in (value, objectKey) order; each entry's objectKeys slice
    // points into it.
    const sortedObjectKeys = try al.alloc(u64, n);
    defer al.free(sortedObjectKeys);
    for (pairs, 0..) |pr, i| sortedObjectKeys[i] = pr.objectKey;

    var entries = std.ArrayList(ValueObjectKeys).empty;
    defer entries.deinit(al);
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and pairs[j].value == pairs[i].value) j += 1;
        try entries.append(al, .{ .value = pairs[i].value, .objectKeys = sortedObjectKeys[i..j] });
        i = j;
    }
    return bulkValueIndex(transaction, entries.items);
}

// ---------------------------------------------------------------------------
// Bulk append orchestrator.
//
// bulkAppend fast-paths a batch of rows whose primary keys all land strictly to
// the RIGHT of the type's current key space onto the right edge of every tree,
// without touching any left subtree. The result is byte-identical to inserting
// the same rows one at a time in ascending-primaryKey order: each new row gets the next
// physical row and object key in batch order, the version stamp matches
// rows.insert (transaction.new_version), live = 1, and the primaryKey and key->row indexes
// grow only along their rightmost path.
//
// A batch only qualifies when nothing about it would force a non-right-edge
// write: no property is indexed and none is a link/link_set (those maintain
// secondary structures keyed by value/target, not by row), the batch primaryKeys are
// strictly ascending and unique, and the smallest batch primaryKey is strictly greater
// than the type's current max primaryKey. Any other shape returns error.NotAppendable
// with NOTHING written, so the caller's fallback can replay row-by-row.
//
// Crucially, every qualification check is read-only and runs BEFORE the first
// node is allocated, so a NotAppendable return leaves the catalog and all trees
// untouched. The CALLER commits.
pub fn bulkAppend(transaction: *WriteTransaction, catalogRef: Reference, rows: []const []const u64) !Reference {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);

    // Validate row widths first: a single malformed row aborts before any work.
    for (rows) |row| {
        if (row.len != s.prop_count) return error.BadRow;
    }
    if (rows.len == 0) return catalogRef;

    try qualifyRightEdgeAppend(transaction, &s, rows);

    // --- Qualified. Nothing has been written yet; build the right-edge runs. ---
    const old_next_row = s.next_row;
    const old_next_key = s.next_key;
    const n = rows.len;
    const al = transaction.database.store.allocator;

    // Object keys and physical rows are assigned in batch order from the type's
    // current counters, exactly as sequential ascending-primaryKey inserts would: the
    // j-th row gets objectKey = next_key + j and physical row = next_row + j.
    const primaryKeys = try al.alloc(u64, n);
    defer al.free(primaryKeys);
    const objectKeys = try al.alloc(u64, n);
    defer al.free(objectKeys);
    const phys_rows = try al.alloc(u64, n);
    defer al.free(phys_rows);
    for (rows, 0..) |row, j| {
        primaryKeys[j] = row[0];
        objectKeys[j] = old_next_key + @as(u64, @intCast(j));
        phys_rows[j] = old_next_row + @as(u64, @intCast(j));
    }

    try appendColumnRuns(transaction, &s, rows);

    // primaryKey index (primaryKey -> objectKey) and key->row index (objectKey -> physical row). Both runs
    // land on the right edge: batch primaryKeys are ascending and above the current max,
    // and objectKeys are consecutive from next_key (thus above every existing objectKey).
    s.primaryKeyIndexRef = try Index.appendRun(transaction, s.primaryKeyIndexRef, primaryKeys[0..n], objectKeys[0..n], al);
    s.keyrow_index_ref = try Index.appendRun(transaction, s.keyrow_index_ref, objectKeys[0..n], phys_rows[0..n], al);

    s.next_row = old_next_row + @as(u64, @intCast(n));
    s.next_key = old_next_key + @as(u64, @intCast(n));
    return s.replace(transaction);
}

// Append each property's values in batch order to the right edge of its
// column, then one version stamp and one live stamp per row (the version
// matches rows.insert, transaction.new_version; live = 1), storing the new column
// roots into the snapshot.
fn appendColumnRuns(
    transaction: *WriteTransaction,
    s: *catalog.CatalogSnapshot,
    rows: []const []const u64,
) !void {
    const n = rows.len;
    const al = transaction.database.store.allocator;

    // Property columns: append each property's values in batch order.
    {
        const col_vals = try al.alloc(u64, n);
        defer al.free(col_vals);
        var p: usize = 0;
        while (p < s.prop_count) : (p += 1) {
            for (rows, 0..) |row, j| col_vals[j] = row[p];
            s.props[p].col = try Column.appendRun(transaction, s.props[p].col, col_vals[0..n], al);
        }
    }

    // Version and live columns: one stamp per row, matching rows.insert.
    const stamps = try al.alloc(u64, n);
    defer al.free(stamps);
    @memset(stamps, transaction.new_version);
    s.version_col_ref = try Column.appendRun(transaction, s.version_col_ref, stamps[0..n], al);
    @memset(stamps, 1);
    s.live_col_ref = try Column.appendRun(transaction, s.live_col_ref, stamps[0..n], al);
}

// Qualify a batch for the right-edge fast path, returning error.NotAppendable
// for any shape it cannot handle. Every check is read-only and runs before the
// first node is allocated, so a NotAppendable return leaves the catalog and
// all trees untouched and the caller's fallback can replay row-by-row.
fn qualifyRightEdgeAppend(
    transaction: *WriteTransaction,
    s: *const catalog.CatalogSnapshot,
    rows: []const []const u64,
) !void {
    // Qualify the schema: reject an indexed or link-bearing property -- both
    // keep secondary structures that a pure right-edge append cannot maintain.
    {
        var j: usize = 0;
        while (j < s.prop_count) : (j += 1) {
            const k = s.props[j].kind;
            if (k == .link or k == .link_set) return error.NotAppendable;
            if (s.props[j].indexed) return error.NotAppendable;
        }
    }

    // Batch primaryKeys must be strictly ascending and unique; any non-ascending or
    // duplicate-in-batch shape is NotAppendable so the fallback handles it
    // (including per-row duplicate detection against the existing rows).
    {
        var i: usize = 1;
        while (i < rows.len) : (i += 1) {
            if (rows[i][0] <= rows[i - 1][0]) return error.NotAppendable;
        }
    }

    // The smallest batch primaryKey (rows[0][0], since ascending) must clear the current
    // max primaryKey in the type. An empty type (no max) admits any ascending batch.
    if (try Index.maxKey(transaction, s.primaryKeyIndexRef)) |maxPrimaryKey| {
        if (rows[0][0] <= maxPrimaryKey) return error.NotAppendable;
    }

    // If the BLIND rightmost primaryKey-index leaf is empty (removals never merge
    // leaves), its RECORDED LOW may exceed every surviving key -- a primaryKey-history
    // gap. Index.appendRun rebuilds exactly that leaf and derives the new
    // parent low from the batch's first key; a batch below the recorded low
    // would break the ascending-lows invariant and make the appended rows
    // unreachable. Such a batch must take the row-by-row fallback. (The
    // keyrow index is immune: new objectKeys are allocated above every objectKey -- and
    // therefore every stale low -- the tree has ever held.)
    if (try emptyRightmostLow(transaction, s.primaryKeyIndexRef)) |stale_low| {
        if (rows[0][0] < stale_low) return error.NotAppendable;
    }
}

// Try the right-edge fast path; on NotAppendable, fall back to row-by-row
// rows.insert, which handles any schema and detects duplicate keys per row.
pub fn bulkAppendOrInsert(transaction: *WriteTransaction, catalogRef: Reference, rows: []const []const u64) !Reference {
    return bulkAppend(transaction, catalogRef, rows) catch |e| switch (e) {
        error.NotAppendable => fallbackInsert(transaction, catalogRef, rows),
        else => e,
    };
}

// Insert every row one at a time, threading the catalog ref. A DuplicateKey from
// rows.insert propagates to the caller. Empty rows return catalogRef unchanged.
//
// Link-bearing schemas are rejected outright: rows.insert writes raw column
// values without backlink maintenance (that is insertTyped's job), so silently
// accepting them here would corrupt the link graph -- the same reason
// bulkImport refuses them.
fn fallbackInsert(transaction: *WriteTransaction, catalogRef: Reference, rows: []const []const u64) !Reference {
    if (rows.len == 0) return catalogRef;
    {
        const v = try catalog.loadCatalog(transaction, catalogRef);
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            const k = v.kind(j);
            if (k == .link or k == .link_set) return error.UnsupportedForBulk;
        }
    }
    var c = catalogRef;
    for (rows) |row| {
        c = (try rawRows.insert(transaction, c, row)).catalogRef;
    }
    return c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("bulkTests.zig");
}
