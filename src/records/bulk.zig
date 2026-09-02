const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const indexNode = @import("../trees/indexNode.zig");
const catalog = @import("../schema/catalog.zig");
const rawRows = @import("rows.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const DeletionRule = catalog.DeletionRule;
const maxPropertyCount = catalog.maxPropertyCount;

// ---------------------------------------------------------------------------
// Bottom-up bulk tree builders.
//
// These build a complete, balanced tree directly from sorted input rather than
// inserting one element at a time. Leaves are packed to capacity in key order,
// then inner levels are stacked on top in runs of fanout until a single root
// remains (packLeaves/stackInner/collapseToRoot live with each tree's own
// operations in column.zig and index.zig).
// ---------------------------------------------------------------------------

/// One value-index entry for bulk building: a property value paired with the
/// ascending objectKeys of the rows holding it.
pub const ValueObjectKeys = struct { value: u64, objectKeys: []const u64 };

/// Build a column tree holding `values` at row indices 0..values.len. Returns
/// the root Reference. Equivalent to Column.create followed by an append per value.
pub fn bulkColumn(transaction: *WriteTransaction, values: []const u64) !Reference {
    if (values.len == 0) return Column.create(transaction);
    const allocator = transaction.database.store.allocator;

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Column.packLeaves(transaction, values, allocator);
    defer level.deinit(allocator);
    try Column.collapseToRoot(transaction, &level, allocator);
    return level.items[0].reference;
}

// Dereference an index node, sizing the read by its kind byte (leaf vs inner).
fn dereferenceIndexNode(transaction: *WriteTransaction, reference: Reference) ![]const u8 {
    const kb = try transaction.dereference(reference, 1);
    return switch (kb[0]) {
        indexNode.kindLeaf => transaction.dereference(reference, indexNode.leafNodeSize),
        indexNode.kindInner => transaction.dereference(reference, indexNode.innerNodeSize),
        else => error.Corrupt,
    };
}

// When the BLIND rightmost leaf of the index is empty (removals emptied it),
// return its parent-recorded low key; null otherwise (non-empty leaf, or an
// empty ROOT leaf, which has no recorded low). The recorded low propagates
// identically up every level of the rightmost path, so it is the single value
// an appended run's first key must clear (see the qualification in bulkAppend).
fn emptyRightmostLow(transaction: *WriteTransaction, root: Reference) !?u64 {
    var currentReference: Reference = root;
    var recordedLow: ?u64 = null;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops >= Index.maxDepth) return error.Corrupt;
        const nodeBytes = try dereferenceIndexNode(transaction, currentReference);
        if (nodeBytes[0] == indexNode.kindLeaf) {
            if ((try indexNode.parseLeaf(nodeBytes)).count != 0) return null;
            return recordedLow; // null when the empty leaf IS the root
        }
        const innerView = try indexNode.parseInner(nodeBytes);
        recordedLow = innerView.lowKey(innerView.childCount - 1);
        currentReference = innerView.childReference(innerView.childCount - 1);
    }
}

/// Build a u64 index over strictly-ascending `keys` with parallel `vals`.
/// Returns the root Reference. Equivalent to Index.create plus an insert per pair.
pub fn bulkIndex(transaction: *WriteTransaction, keys: []const u64, values: []const u64) !Reference {
    std.debug.assert(keys.len == values.len);
    if (std.debug.runtime_safety) {
        var propertyIndex: usize = 1;
        while (propertyIndex < keys.len) : (propertyIndex += 1) std.debug.assert(keys[propertyIndex] > keys[propertyIndex - 1]);
    }
    if (keys.len == 0) return Index.create(transaction);
    const allocator = transaction.database.store.allocator;

    // Pack leaves, then stack inner levels until a single root remains.
    var level = try Index.packLeaves(transaction, keys, values, allocator);
    defer level.deinit(allocator);
    try Index.collapseToRoot(transaction, &level, allocator);
    return level.items[0].reference;
}

/// Build a value index (value -> inner objectKey-set) from `entries`, sorted by
/// value, each with ascending objectKeys. Each inner set maps objectKey -> 1, matching
/// the shape rows.valueIndexAdd maintains (value -> Index{objectKey -> 1}).
pub fn bulkValueIndex(transaction: *WriteTransaction, entries: []const ValueObjectKeys) !Reference {
    if (entries.len == 0) return Index.create(transaction);
    const allocator = transaction.database.store.allocator;

    const values = try allocator.alloc(u64, entries.len);
    defer allocator.free(values);
    const innerRoots = try allocator.alloc(u64, entries.len);
    defer allocator.free(innerRoots);

    // A reusable buffer of 1s big enough for the largest objectKey set.
    var maxObjectKeys: usize = 0;
    for (entries) |entry| maxObjectKeys = @max(maxObjectKeys, entry.objectKeys.len);
    const ones = try allocator.alloc(u64, maxObjectKeys);
    defer allocator.free(ones);
    @memset(ones, 1);

    for (entries, 0..) |entry, entryIndex| {
        values[entryIndex] = entry.value;
        innerRoots[entryIndex] = try bulkIndex(transaction, entry.objectKeys, ones[0..entry.objectKeys.len]);
    }

    return bulkIndex(transaction, values, innerRoots);
}

/// Ingest a whole table of rows into an EMPTY type in one shot, returning the
/// new catalog reference. Builds every column and index bottom-up so the result is
/// indistinguishable from inserting the same rows one at a time in
/// primary-key order: the columns, version/live columns, primaryKey index,
/// key->row index, and per-indexed-property value indexes are all built
/// directly from the sorted input. O(m log m) to sort, then O(m) node writes
/// over the row count.
///
/// Object-key convention (matched to rows.insert): a fresh insert takes the
/// catalog's current nextKey as the new row's objectKey and assigns physical row =
/// nextRow, then bumps both by one. Inserting the rows in ascending-primaryKey order
/// therefore gives the r-th-smallest primaryKey an objectKey of (startNextKey + r) and a
/// physical row of r. bulkImport reproduces exactly that mapping: it sorts by primaryKey,
/// then assigns objectKeyR = oldNextKey + r and physical row r = r. So a bulk row
/// and its single-insert twin resolve primaryKey -> objectKey -> row identically, and every
/// lookup, scan, and value-index query matches.
///
/// All rejections happen BEFORE any node is written, so a bad input can never
/// half-commit. Phase 1 excludes link/linkSet properties. The CALLER commits.
pub fn bulkImport(
    transaction: *WriteTransaction,
    catalogReference: Reference,
    rows: []const []const u64,
    opts: struct { presorted: bool = false },
) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    if (snapshot.nextRow != 0) return error.TypeNotEmpty;
    const oldNextKey = snapshot.nextKey;
    try validateImportInput(&snapshot, rows);

    const allocator = transaction.database.store.allocator;
    const permutation = try primaryKeySortOrder(rows, opts.presorted, allocator);
    defer allocator.free(permutation);

    // --- All validation passed; build the tree roots bottom-up. ---
    try freePreallocatedTrees(transaction, &snapshot);
    try buildImportTrees(transaction, &snapshot, rows, permutation, oldNextKey);
    try buildValueIndexes(transaction, &snapshot, rows, permutation, oldNextKey);

    snapshot.nextRow = @intCast(rows.len);
    snapshot.nextKey = oldNextKey + @as(u64, @intCast(rows.len));
    return snapshot.replace(transaction);
}

// Reject a link-bearing type, an indexed blob property, and any malformed row
// width here, before a single node is written. An indexed blob property must
// be rejected here rather than anywhere later: bulkImport frees the type's
// pre-allocated columns and indexes right after this call
// (freePreallocatedTrees), so a rejection after that point would leave the
// catalog pointing at freed nodes. buildPropertyValueIndex/bulkValueIndex stay
// numeric and unreachable for a blob property as a result.
fn validateImportInput(snapshot: *const catalog.CatalogSnapshot, rows: []const []const u64) !void {
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        const kind = snapshot.properties[propertyIndex].kind;
        if (kind == .link or kind == .linkSet) return error.UnsupportedForBulk;
        if (kind == .blob and snapshot.properties[propertyIndex].indexed) return error.UnsupportedForBulk;
    }
    for (rows) |row| {
        if (row.len != snapshot.propertyCount) return error.BadRow;
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
    allocator: std.mem.Allocator,
) ![]usize {
    const rowCount = rows.len;
    const permutation = try allocator.alloc(usize, rowCount);
    errdefer allocator.free(permutation);
    for (permutation, 0..) |*slot, inputIndex| slot.* = inputIndex;
    if (presorted) {
        if (std.debug.runtime_safety) {
            var rowIndex: usize = 1;
            while (rowIndex < rowCount) : (rowIndex += 1) std.debug.assert(rows[rowIndex][0] > rows[rowIndex - 1][0]);
        }
    } else {
        std.mem.sort(usize, permutation, rows, struct {
            fn lessThan(table: []const []const u64, left: usize, right: usize) bool {
                return table[left][0] < table[right][0];
            }
        }.lessThan);
    }
    var rank: usize = 1;
    while (rank < rowCount) : (rank += 1) {
        if (rows[permutation[rank]][0] == rows[permutation[rank - 1]][0]) return error.DuplicateKey;
    }
    return permutation;
}

// The type is empty, but its creation pre-allocated empty columns and indexes
// that the bulk-built roots replace; free them so the import leaves no orphan
// nodes behind.
fn freePreallocatedTrees(transaction: *WriteTransaction, snapshot: *const catalog.CatalogSnapshot) !void {
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        try Column.freeTree(transaction, snapshot.properties[propertyIndex].column);
        // Index.freeTree, not a kind switch: validateImportInput already rejected
        // an indexed .blob property, so every indexed property reaching here is
        // int or link, correctly freed as the numeric tree it is.
        if (snapshot.properties[propertyIndex].indexed) try Index.freeTree(transaction, snapshot.properties[propertyIndex].valueIndex);
    }
    try Column.freeTree(transaction, snapshot.versionColumnReference);
    try Column.freeTree(transaction, snapshot.liveColumnReference);
    try Index.freeTree(transaction, snapshot.primaryKeyIndexReference);
    try Index.freeTree(transaction, snapshot.keyToRowIndexReference);
}

// Build the property columns, version/live columns, and primaryKey/key->row indexes
// bottom-up from the sorted input, storing the new roots into the snapshot.
fn buildImportTrees(
    transaction: *WriteTransaction,
    snapshot: *catalog.CatalogSnapshot,
    rows: []const []const u64,
    permutation: []const usize,
    oldNextKey: u64,
) !void {
    const rowCount = rows.len;
    const allocator = transaction.database.store.allocator;

    // Property columns: gather each property's values in sorted-row order.
    {
        const columnValues = try allocator.alloc(u64, rowCount);
        defer allocator.free(columnValues);
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
            for (permutation, 0..) |sourceRow, rank| columnValues[rank] = rows[sourceRow][propertyIndex];
            snapshot.properties[propertyIndex].column = try bulkColumn(transaction, columnValues[0..rowCount]);
        }
    }

    // Version and live columns: one stamp per row. The version stamp matches
    // rows.insert (transaction.newVersion), so a bulk row carries the same version a
    // single-insert twin committed in the same transaction would; live = 1.
    const stamps = try allocator.alloc(u64, rowCount);
    defer allocator.free(stamps);
    @memset(stamps, transaction.newVersion);
    snapshot.versionColumnReference = try bulkColumn(transaction, stamps[0..rowCount]);
    @memset(stamps, 1);
    snapshot.liveColumnReference = try bulkColumn(transaction, stamps[0..rowCount]);

    // primaryKey index (primaryKey -> objectKey) and key->row index (objectKey -> physical row). objectKeys are
    // assigned in sorted-primaryKey order from the type's current nextKey, so
    // objectKeyR == oldNextKey + r and physical row r == r.
    const primaryKeys = try allocator.alloc(u64, rowCount);
    defer allocator.free(primaryKeys);
    const objectKeys = try allocator.alloc(u64, rowCount);
    defer allocator.free(objectKeys);
    const physicalRows = try allocator.alloc(u64, rowCount);
    defer allocator.free(physicalRows);
    for (permutation, 0..) |sourceRow, rank| {
        primaryKeys[rank] = rows[sourceRow][0];
        objectKeys[rank] = oldNextKey + @as(u64, @intCast(rank));
        physicalRows[rank] = @intCast(rank);
    }
    snapshot.primaryKeyIndexReference = try bulkIndex(transaction, primaryKeys[0..rowCount], objectKeys[0..rowCount]);
    snapshot.keyToRowIndexReference = try bulkIndex(transaction, objectKeys[0..rowCount], physicalRows[0..rowCount]);
}

// Value indexes: for each indexed property, group its objectKeys by value and store
// the built index root into the snapshot.
fn buildValueIndexes(
    transaction: *WriteTransaction,
    snapshot: *catalog.CatalogSnapshot,
    rows: []const []const u64,
    permutation: []const usize,
    oldNextKey: u64,
) !void {
    const allocator = transaction.database.store.allocator;
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        if (snapshot.properties[propertyIndex].indexed) {
            snapshot.properties[propertyIndex].valueIndex = try buildPropertyValueIndex(transaction, rows, permutation, propertyIndex, oldNextKey, allocator);
        }
    }
}

// Build the value index for indexed property `p`: emit (value -> {objectKey -> 1})
// with values ascending and each inner objectKey set ascending, matching the shape
// rows.valueIndexAdd maintains. objectKeys are assigned in sorted-primaryKey order (objectKeyR =
// oldNextKey + r), so sorting (value, objectKey) pairs yields ascending objectKeys
// within each value group.
fn buildPropertyValueIndex(
    transaction: *WriteTransaction,
    rows: []const []const u64,
    permutation: []const usize,
    propertyIndex: usize,
    oldNextKey: u64,
    allocator: std.mem.Allocator,
) !Reference {
    const rowCount = permutation.len;
    const Pair = struct { value: u64, objectKey: u64 };
    const pairs = try allocator.alloc(Pair, rowCount);
    defer allocator.free(pairs);
    for (permutation, 0..) |sourceRow, rank| pairs[rank] = .{ .value = rows[sourceRow][propertyIndex], .objectKey = oldNextKey + @as(u64, @intCast(rank)) };
    std.mem.sort(Pair, pairs, {}, struct {
        fn lessThan(_: void, left: Pair, right: Pair) bool {
            if (left.value != right.value) return left.value < right.value;
            return left.objectKey < right.objectKey;
        }
    }.lessThan);

    // A contiguous objectKey buffer in (value, objectKey) order; each entry's objectKeys slice
    // points into it.
    const sortedObjectKeys = try allocator.alloc(u64, rowCount);
    defer allocator.free(sortedObjectKeys);
    for (pairs, 0..) |pair, rank| sortedObjectKeys[rank] = pair.objectKey;

    var entries = std.ArrayList(ValueObjectKeys).empty;
    defer entries.deinit(allocator);
    var runStart: usize = 0;
    while (runStart < rowCount) {
        var runEnd = runStart + 1;
        while (runEnd < rowCount and pairs[runEnd].value == pairs[runStart].value) runEnd += 1;
        try entries.append(allocator, .{ .value = pairs[runStart].value, .objectKeys = sortedObjectKeys[runStart..runEnd] });
        runStart = runEnd;
    }
    return bulkValueIndex(transaction, entries.items);
}

/// Fast-path a batch of rows whose primary keys all land strictly to the
/// RIGHT of the type's current key space onto the right edge of every tree,
/// without touching any left subtree; returns the new catalog reference. The result
/// is byte-identical to inserting the same rows one at a time in
/// ascending-primaryKey order: each new row gets the next physical row and
/// object key in batch order, the version stamp matches rows.insert
/// (transaction.newVersion), live = 1, and the primaryKey and key->row
/// indexes grow only along their rightmost path. O(m) node writes over the
/// batch plus one right-edge rebuild per tree.
///
/// A batch only qualifies when nothing about it would force a non-right-edge
/// write: no property is indexed and none is a link/linkSet (those maintain
/// secondary structures keyed by value/target, not by row), the batch primaryKeys are
/// strictly ascending and unique, and the smallest batch primaryKey is strictly greater
/// than the type's current max primaryKey. Any other shape returns error.NotAppendable
/// with NOTHING written, so the caller's fallback can replay row-by-row.
///
/// Crucially, every qualification check is read-only and runs BEFORE the first
/// node is allocated, so a NotAppendable return leaves the catalog and all trees
/// untouched. The CALLER commits.
pub fn bulkAppend(transaction: *WriteTransaction, catalogReference: Reference, rows: []const []const u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);

    // Validate row widths first: a single malformed row aborts before any work.
    for (rows) |row| {
        if (row.len != snapshot.propertyCount) return error.BadRow;
    }
    if (rows.len == 0) return catalogReference;

    try qualifyRightEdgeAppend(transaction, &snapshot, rows);

    // --- Qualified. Nothing has been written yet; build the right-edge runs. ---
    const oldNextRow = snapshot.nextRow;
    const oldNextKey = snapshot.nextKey;
    const rowCount = rows.len;
    const allocator = transaction.database.store.allocator;

    // Object keys and physical rows are assigned in batch order from the type's
    // current counters, exactly as sequential ascending-primaryKey inserts would: the
    // j-th row gets objectKey = nextKey + j and physical row = nextRow + j.
    const primaryKeys = try allocator.alloc(u64, rowCount);
    defer allocator.free(primaryKeys);
    const objectKeys = try allocator.alloc(u64, rowCount);
    defer allocator.free(objectKeys);
    const physicalRows = try allocator.alloc(u64, rowCount);
    defer allocator.free(physicalRows);
    for (rows, 0..) |row, rowIndex| {
        primaryKeys[rowIndex] = row[0];
        objectKeys[rowIndex] = oldNextKey + @as(u64, @intCast(rowIndex));
        physicalRows[rowIndex] = oldNextRow + @as(u64, @intCast(rowIndex));
    }

    try appendColumnRuns(transaction, &snapshot, rows);

    // primaryKey index (primaryKey -> objectKey) and key->row index (objectKey -> physical row). Both runs
    // land on the right edge: batch primaryKeys are ascending and above the current max,
    // and objectKeys are consecutive from nextKey (thus above every existing objectKey).
    snapshot.primaryKeyIndexReference = try Index.appendRun(transaction, snapshot.primaryKeyIndexReference, primaryKeys[0..rowCount], objectKeys[0..rowCount], allocator);
    snapshot.keyToRowIndexReference = try Index.appendRun(transaction, snapshot.keyToRowIndexReference, objectKeys[0..rowCount], physicalRows[0..rowCount], allocator);

    snapshot.nextRow = oldNextRow + @as(u64, @intCast(rowCount));
    snapshot.nextKey = oldNextKey + @as(u64, @intCast(rowCount));
    return snapshot.replace(transaction);
}

// Append each property's values in batch order to the right edge of its
// column, then one version stamp and one live stamp per row (the version
// matches rows.insert, transaction.newVersion; live = 1), storing the new column
// roots into the snapshot.
fn appendColumnRuns(
    transaction: *WriteTransaction,
    snapshot: *catalog.CatalogSnapshot,
    rows: []const []const u64,
) !void {
    const rowCount = rows.len;
    const allocator = transaction.database.store.allocator;

    // Property columns: append each property's values in batch order.
    {
        const columnValues = try allocator.alloc(u64, rowCount);
        defer allocator.free(columnValues);
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
            for (rows, 0..) |row, rowIndex| columnValues[rowIndex] = row[propertyIndex];
            snapshot.properties[propertyIndex].column = try Column.appendRun(transaction, snapshot.properties[propertyIndex].column, columnValues[0..rowCount], allocator);
        }
    }

    // Version and live columns: one stamp per row, matching rows.insert.
    const stamps = try allocator.alloc(u64, rowCount);
    defer allocator.free(stamps);
    @memset(stamps, transaction.newVersion);
    snapshot.versionColumnReference = try Column.appendRun(transaction, snapshot.versionColumnReference, stamps[0..rowCount], allocator);
    @memset(stamps, 1);
    snapshot.liveColumnReference = try Column.appendRun(transaction, snapshot.liveColumnReference, stamps[0..rowCount], allocator);
}

// Qualify a batch for the right-edge fast path, returning error.NotAppendable
// for any shape it cannot handle. Every check is read-only and runs before the
// first node is allocated, so a NotAppendable return leaves the catalog and
// all trees untouched and the caller's fallback can replay row-by-row.
fn qualifyRightEdgeAppend(
    transaction: *WriteTransaction,
    snapshot: *const catalog.CatalogSnapshot,
    rows: []const []const u64,
) !void {
    // Qualify the schema: reject an indexed or link-bearing property -- both
    // keep secondary structures that a pure right-edge append cannot maintain.
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
            const kind = snapshot.properties[propertyIndex].kind;
            if (kind == .link or kind == .linkSet) return error.NotAppendable;
            if (snapshot.properties[propertyIndex].indexed) return error.NotAppendable;
        }
    }

    // Batch primaryKeys must be strictly ascending and unique; any non-ascending or
    // duplicate-in-batch shape is NotAppendable so the fallback handles it
    // (including per-row duplicate detection against the existing rows).
    {
        var rowIndex: usize = 1;
        while (rowIndex < rows.len) : (rowIndex += 1) {
            if (rows[rowIndex][0] <= rows[rowIndex - 1][0]) return error.NotAppendable;
        }
    }

    // The smallest batch primaryKey (rows[0][0], since ascending) must clear the current
    // max primaryKey in the type. An empty type (no max) admits any ascending batch.
    if (try Index.maxKey(transaction, snapshot.primaryKeyIndexReference)) |maxPrimaryKey| {
        if (rows[0][0] <= maxPrimaryKey) return error.NotAppendable;
    }

    // If the BLIND rightmost primaryKey-index leaf is empty (removals never merge
    // leaves), its RECORDED LOW may exceed every surviving key -- a primaryKey-history
    // gap. Index.appendRun rebuilds exactly that leaf and derives the new
    // parent low from the batch's first key; a batch below the recorded low
    // would break the ascending-lows invariant and make the appended rows
    // unreachable. Such a batch must take the row-by-row fallback. (The
    // key-to-row index is immune: new objectKeys are allocated above every objectKey -- and
    // therefore every stale low -- the tree has ever held.)
    if (try emptyRightmostLow(transaction, snapshot.primaryKeyIndexReference)) |staleLow| {
        if (rows[0][0] < staleLow) return error.NotAppendable;
    }
}

/// Try the right-edge fast path; on NotAppendable, fall back to row-by-row
/// rows.insert, which handles any non-link schema and detects duplicate keys
/// per row. Returns the new catalog reference. O(m) on the fast path, O(m log n)
/// on the fallback.
pub fn bulkAppendOrInsert(transaction: *WriteTransaction, catalogReference: Reference, rows: []const []const u64) !Reference {
    return bulkAppend(transaction, catalogReference, rows) catch |err| switch (err) {
        error.NotAppendable => fallbackInsert(transaction, catalogReference, rows),
        else => err,
    };
}

// Insert every row one at a time, threading the catalog reference. A DuplicateKey from
// rows.insert propagates to the caller. Empty rows return catalogReference unchanged.
//
// Link-bearing schemas are rejected outright: rows.insert writes raw column
// values without backlink maintenance (that is insertTyped's job), so silently
// accepting them here would corrupt the link graph -- the same reason
// bulkImport refuses them.
fn fallbackInsert(transaction: *WriteTransaction, catalogReference: Reference, rows: []const []const u64) !Reference {
    if (rows.len == 0) return catalogReference;
    {
        const view = try catalog.loadCatalog(transaction, catalogReference);
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            const kind = view.kind(propertyIndex);
            if (kind == .link or kind == .linkSet) return error.UnsupportedForBulk;
        }
    }
    var currentCatalog = catalogReference;
    for (rows) |row| {
        currentCatalog = (try rawRows.insert(transaction, currentCatalog, row)).catalogReference;
    }
    return currentCatalog;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("bulkTests.zig");
}
