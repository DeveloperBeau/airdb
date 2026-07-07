const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");
const typedir = @import("../schema/typeDirectory.zig");
const objects = @import("../records/objects.zig");
const relocateRow = @import("relocation.zig").relocateRow;
const file_store = @import("fileStore.zig");
const compactionCopy = @import("compactionCopy.zig");

const maxPropertyCount = catalog.maxPropertyCount;

const Pair = compactionCopy.Pair;
const collectKeyRowPairs = compactionCopy.collectKeyRowPairs;

// Cross-database row/value deep-copying lives in compactionCopy.zig;
// re-exported here for the whole-file compaction callers below.
pub const copyTypeRows = compactionCopy.copyTypeRows;
pub const rebuildBacklinks = compactionCopy.rebuildBacklinks;

pub fn liveCount(transaction: anytype, catalogRef: Reference) !u64 {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    return Index.count(transaction, view.keyrow_index_ref);
}

pub fn shouldCompact(transaction: anytype, catalogRef: Reference) !bool {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    const nextRow = view.next_row;
    if (nextRow == 0) return false;
    const live = try Index.count(transaction, view.keyrow_index_ref);
    return (nextRow - live) * 2 > nextRow; // more than half the rows are dead
}

// Rebuild the type's columns to contain only live rows, packed densely, and
// remap the key->row index. Object keys, primaryKey index, and backlink indexes are
// preserved (keyed by object key). Returns the new catalog ref.
pub fn compactType(transaction: *WriteTransaction, catalogRef: Reference) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const propertyCount = snapshot.propertyCount;
    // Keep the old column/index roots to read from while the snapshot's fields
    // are re-pointed at the fresh dense structures.
    var oldPropertyColumns: [maxPropertyCount]Reference = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) oldPropertyColumns[propertyIndex] = snapshot.properties[propertyIndex].col;
    }
    const oldVersion = snapshot.version_col_ref;
    const old_live = snapshot.live_col_ref;
    const old_keyrow = snapshot.keyrow_index_ref;

    const alloc = transaction.database.store.allocator;
    var pairs = try collectKeyRowPairs(alloc, transaction, old_keyrow);
    defer pairs.deinit(alloc);

    // Build fresh dense columns.
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex].col = try Column.create(transaction);
    }
    snapshot.version_col_ref = try Column.create(transaction);
    snapshot.live_col_ref = try Column.create(transaction);
    snapshot.keyrow_index_ref = try Index.create(transaction);

    var new_row: u64 = 0;
    for (pairs.items) |pair| {
        // defensive live check (delete already drops dead keys from keyrow)
        if ((try Column.get(transaction, old_live, pair.row)) == 0) continue;
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const cell = try Column.get(transaction, oldPropertyColumns[propertyIndex], pair.row);
            snapshot.properties[propertyIndex].col = try Column.append(transaction, snapshot.properties[propertyIndex].col, cell);
        }
        const version = try Column.get(transaction, oldVersion, pair.row);
        snapshot.version_col_ref = try Column.append(transaction, snapshot.version_col_ref, version);
        snapshot.live_col_ref = try Column.append(transaction, snapshot.live_col_ref, 1);
        snapshot.keyrow_index_ref = try Index.insert(transaction, snapshot.keyrow_index_ref, pair.objectKey, new_row);
        new_row += 1;
    }

    // Free the replaced structures: the old property/version/live columns and
    // the old key->row index are fully copied out above and unreferenced by the
    // new catalog. Without this a full compact of a large type left its entire
    // old column set as permanently unreclaimable garbage. (The primaryKey index,
    // backlinks, and value indexes are carried over, not rebuilt.)
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) try Column.freeTree(transaction, oldPropertyColumns[propertyIndex]);
    }
    try Column.freeTree(transaction, oldVersion);
    try Column.freeTree(transaction, old_live);
    try Index.freeTree(transaction, old_keyrow);

    snapshot.next_row = new_row;
    return snapshot.replace(transaction);
}

// Truncate a fully-packed type's columns down to `new_len` rows and publish a
// catalog with next_row == new_len. All live rows must already lie in
// [0, new_len); the dead tail is dropped. Object key/primaryKey/backlink indexes are
// preserved unchanged. Returns the new catalog ref.
fn truncatePacked(transaction: *WriteTransaction, catalogRef: Reference, new_len: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex].col = try Column.truncate(transaction, snapshot.properties[propertyIndex].col, new_len);
    }
    snapshot.version_col_ref = try Column.truncate(transaction, snapshot.version_col_ref, new_len);
    snapshot.live_col_ref = try Column.truncate(transaction, snapshot.live_col_ref, new_len);
    snapshot.next_row = new_len;
    return snapshot.replace(transaction);
}

// Two-pointer packing cursor for one in-flight compaction run. live_count and
// next_row pin the run to a specific catalog shape: if either changes between
// steps (churn inserted/deleted/relocated rows), the stored cursor is stale and
// must be discarded. hole_lo scans upward through [0, live_count) seeking dead
// relocation targets; high_hi scans downward from next_row toward live_count
// seeking live rows that must move down. Both advance monotonically across
// steps so no slot is ever revisited (relocateRow is not idempotent).
//
// The struct itself lives on the Database (the cursor persists across the write
// transactions of one packing run), so its definition is in database.zig.
pub const CompactCursor = @import("../database.zig").CompactCursor;

// Map a physical row to its stable object key. There is no reverse key->row
// index, so we go through the primary key: property 0 holds the primaryKey, and the primaryKey
// index maps primaryKey -> objectKey (the same association objects.insert builds and
// resolveProperty reads). Valid for any live row; the row's primaryKey cell is preserved by
// relocateRow, so this holds even after earlier relocations in the same run.
fn rowToObjectKey(transaction: anytype, view: catalog.CatalogView, row: u64) !u64 {
    const primaryKey = try Column.get(transaction, view.propertyColumnRef(0), row);
    // A live row whose primaryKey does not resolve means the primaryKey index diverged from the
    // columns: surface corruption instead of crashing mid-compaction.
    return (try Index.get(transaction, view.primaryKeyIndexRef, primaryKey)) orelse error.Corrupt;
}

// Hard safety check before truncating a packed type's dead tail: no live row
// may survive in [live_count, next_row). Bounded, debug-only, and runs once
// per pack at the final step.
fn assertTailDead(transaction: *WriteTransaction, catalogRef: Reference, live_count: u64, next_row: u64) !void {
    if (!std.debug.runtime_safety) return;
    const view = try catalog.loadCatalog(transaction, catalogRef);
    var row: u64 = live_count;
    while (row < next_row) : (row += 1) {
        std.debug.assert((try Column.get(transaction, view.live_col_ref, row)) == 0);
    }
}

// Advance cursor.hole_lo upward to the next dead slot (relocation target) in
// [0, live_count).
fn advanceHoleCursor(transaction: *WriteTransaction, catalogRef: Reference, live_count: u64, cursor: *CompactCursor) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    while (cursor.hole_lo < live_count and (try Column.get(transaction, view.live_col_ref, cursor.hole_lo)) == 1) : (cursor.hole_lo += 1) {}
}

// Advance cursor.high_hi down past dead rows to the next live row at
// >= live_count.
fn advanceHighCursor(transaction: *WriteTransaction, catalogRef: Reference, live_count: u64, cursor: *CompactCursor) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    while (cursor.high_hi > live_count and (try Column.get(transaction, view.live_col_ref, cursor.high_hi - 1)) == 0) : (cursor.high_hi -= 1) {}
}

// Incrementally pack a type toward dense storage, doing at most `budget`
// relocations per call, using a budget-proportional two-pointer tail scan
// instead of a full index walk.
//
// `hole_lo` advances upward through [0, live_count) to find dead slots
// (relocation targets); `high_hi` advances downward from next_row toward
// live_count to find live rows at physical index >= live_count (rows that must
// move down). Each paired (hole, high row) is relocated via relocateRow, up to
// `budget` times; both cursors then step past the consumed slots. The cursor is
// persisted on the Database so the next call resumes where this one stopped.
//
// Reset rule (data-loss-critical): the cursor is only resumed when the freshly
// loaded live_count AND next_row match the stored ones. Any mismatch -- or no
// stored cursor -- restarts the scan from hole_lo=0, high_hi=next_row. This
// guarantees a stale cursor (from churn between steps) can never be trusted.
//
// Truncation guard (the no-data-loss line): the dead tail [live_count, next_row)
// is truncated, and `done` reported, ONLY when `high_hi <= live_count` -- i.e.
// the downward cursor has examined the ENTIRE range above live_count and every
// live row it found was relocated (relocating a high row flips it dead, then the
// cursor steps past it). This is equivalent in safety to the old
// "all collected high rows moved" guard: both certify that no live row remains
// in [live_count, next_row) before the truncate. A debug-only bounded scan
// asserts exactly that immediately before truncating. Returns the updated
// catalog ref, the rows moved this call, and whether packing finished.
pub fn compactStep(transaction: *WriteTransaction, catalogRef: Reference, type_id: u16, budget: usize) !struct { catalogRef: Reference, moved: usize, done: bool } {
    var currentCatalog = catalogRef;
    const liveRows = try liveCount(transaction, currentCatalog);
    const next_row = (try catalog.loadCatalog(transaction, currentCatalog)).next_row;

    // Already packed (no live row above live_count). The dead tail is already
    // gone (next_row == live_count), so there is nothing to truncate.
    if (next_row == liveRows) {
        transaction.database.compact_cursor = null;
        return .{ .catalogRef = currentCatalog, .moved = 0, .done = true };
    }

    // Resume the stored cursor only if it pins this exact CATALOG (the ref
    // uniquely identifies the type and its committed state) with this exact
    // shape; otherwise (another type, churn, or a fresh run) restart the scan.
    var cursor: CompactCursor = blk: {
        if (transaction.database.compact_cursor) |cursor| {
            if (cursor.type_id == type_id and cursor.catalogRef == catalogRef and cursor.live_count == liveRows and cursor.next_row == next_row) break :blk cursor;
        }
        break :blk .{ .type_id = type_id, .catalogRef = catalogRef, .live_count = liveRows, .next_row = next_row, .hole_lo = 0, .high_hi = next_row };
    };

    var moved: usize = 0;
    while (moved < budget) {
        try advanceHoleCursor(transaction, currentCatalog, liveRows, &cursor);
        try advanceHighCursor(transaction, currentCatalog, liveRows, &cursor);
        // No high live rows left to move, or (defensively) no holes to fill.
        if (cursor.high_hi <= liveRows or cursor.hole_lo >= liveRows) break;

        const high_row = cursor.high_hi - 1;
        const objectKey = try rowToObjectKey(transaction, try catalog.loadCatalog(transaction, currentCatalog), high_row);
        currentCatalog = try relocateRow(transaction, currentCatalog, objectKey, cursor.hole_lo);
        // The hole is now live and the high row now dead; step past both.
        cursor.hole_lo += 1;
        cursor.high_hi -= 1;
        moved += 1;
    }

    // Skip any trailing dead rows the budget loop left unexamined so the guard
    // sees the true frontier (lets `done` fire as early as it is provably safe).
    try advanceHighCursor(transaction, currentCatalog, liveRows, &cursor);

    if (cursor.high_hi <= liveRows) {
        try assertTailDead(transaction, currentCatalog, liveRows, next_row);
        currentCatalog = try truncatePacked(transaction, currentCatalog, liveRows);
        transaction.database.compact_cursor = null;
        return .{ .catalogRef = currentCatalog, .moved = moved, .done = true };
    }

    // Persist against the catalog ref the NEXT call will see: relocations COW
    // the catalog, so `cur` is what the caller publishes and later re-derives.
    cursor.catalogRef = currentCatalog;
    transaction.database.compact_cursor = cursor;
    return .{ .catalogRef = currentCatalog, .moved = moved, .done = false };
}

// ---------------------------------------------------------------------------
// Full-file compaction with a verify-before-swap equivalence gate.
// ---------------------------------------------------------------------------

pub const CompactionError = error{CompactionMismatch};

// Order-independent 64-bit mix of a primary key, folded with XOR so the running
// accumulator does not depend on traversal order.
inline fn mixPrimaryKey(primaryKey: u64) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&primaryKey));
}

// Walk a catalog's key->row index, reading each live row's primary key (property 0),
// and fold the primaryKey set into `fold` (XOR of mixed primaryKeys) while counting rows. The
// fold is identity-preserving and order-independent.
fn foldPrimaryKeys(allocator: std.mem.Allocator, transaction: anytype, catalogRef: Reference, fold: *u64, count: *u64) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    const property0 = view.propertyColumnRef(0);
    var pairs = try collectKeyRowPairs(allocator, transaction, view.keyrow_index_ref);
    defer pairs.deinit(allocator);
    for (pairs.items) |pair| {
        const primaryKey = try Column.get(transaction, property0, pair.row);
        fold.* ^= mixPrimaryKey(primaryKey);
        count.* += 1;
    }
}

// Fold SRC's primaryKey set (like foldPrimaryKeys) AND, for every live source object, prove that
// the destination preserves it: (a) the object is readable in dst by its
// original object key, and (b) every to-one link property holds the same raw
// target in dst as in src. Returns error.CompactionMismatch on any failure.
fn foldPrimaryKeysAndCheck(allocator: std.mem.Allocator, source: anytype, sourceCatalog: Reference, destination: anytype, destinationCatalog: Reference, fold: *u64, count: *u64) !void {
    const sourceView = try catalog.loadCatalog(source, sourceCatalog);
    const destinationView = try catalog.loadCatalog(destination, destinationCatalog);
    const propertyCount = sourceView.propertyCount;
    if (destinationView.propertyCount != propertyCount) return error.CompactionMismatch;

    // Snapshot column refs and per-property kinds for both sides up front.
    var sourcePropertyColumns: [maxPropertyCount]Reference = undefined;
    var destinationPropertyColumns: [maxPropertyCount]Reference = undefined;
    var kinds: [maxPropertyCount]catalog.PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            sourcePropertyColumns[propertyIndex] = sourceView.propertyColumnRef(propertyIndex);
            destinationPropertyColumns[propertyIndex] = destinationView.propertyColumnRef(propertyIndex);
            kinds[propertyIndex] = sourceView.kind(propertyIndex);
            if (destinationView.kind(propertyIndex) != kinds[propertyIndex]) return error.CompactionMismatch;
        }
    }
    const sourcePropertyColumn0 = sourcePropertyColumns[0];

    // Collect SRC's live (objectKey, row) pairs.
    var pairs = try collectKeyRowPairs(allocator, source, sourceView.keyrow_index_ref);
    defer pairs.deinit(allocator);

    var out: [maxPropertyCount]catalog.Value = undefined;
    for (pairs.items) |pair| {
        // primaryKey fold over the source.
        const primaryKey = try Column.get(source, sourcePropertyColumn0, pair.row);
        fold.* ^= mixPrimaryKey(primaryKey);
        count.* += 1;

        // (a) readability: the same object key must decode in dst.
        if ((try objects.getTypedByObjectKey(destination, destinationCatalog, pair.objectKey, out[0..propertyCount])) == null) return error.CompactionMismatch;

        const drow = (try catalog.objectKeyToRow(destination, destinationCatalog, pair.objectKey)) orelse return error.CompactionMismatch;
        try checkRowProperties(source, destination, destinationView, kinds[0..propertyCount], sourcePropertyColumns[0..propertyCount], destinationPropertyColumns[0..propertyCount], pair, drow);
    }
}

// Per-property preservation checks for one copied row: (b) to-one forward
// links must carry the identical raw target in dst, and (c) every indexed
// property value must be covered by the destination's value index -- an empty
// or stale index passes the row-readability checks but silently empties
// queries. Returns error.CompactionMismatch on any divergence.
fn checkRowProperties(
    source: anytype,
    destination: anytype,
    destinationView: catalog.CatalogView,
    kinds: []const catalog.PropertyKind,
    sourcePropertyColumns: []const Reference,
    destinationPropertyColumns: []const Reference,
    pair: Pair,
    drow: u64,
) !void {
    var propertyIndex: usize = 0;
    while (propertyIndex < kinds.len) : (propertyIndex += 1) {
        if (kinds[propertyIndex] == .link) {
            const s_raw = try Column.get(source, sourcePropertyColumns[propertyIndex], pair.row);
            const d_raw = try Column.get(destination, destinationPropertyColumns[propertyIndex], drow);
            if (s_raw != d_raw) return error.CompactionMismatch;
        }
        if (destinationView.indexed(propertyIndex)) {
            const d_raw = try Column.get(destination, destinationPropertyColumns[propertyIndex], drow);
            const inner = (try Index.get(destination, destinationView.valueIndexRef(propertyIndex), d_raw)) orelse return error.CompactionMismatch;
            if ((try Index.get(destination, inner, pair.objectKey)) == null) return error.CompactionMismatch;
        }
    }
}

// Verify the destination is equivalent to the source before it is published.
// Proves, per type: identical type count, identical live count, identical primaryKey set
// (order-independent fold), every source object readable in dst by its original
// key, and identical to-one forward links. Any divergence aborts the compaction.
fn verifyEquivalent(allocator: std.mem.Allocator, source: anytype, src_dir: Reference, destination: anytype, dst_dir: Reference) !void {
    const typeCount = try typedir.typeCount(source, src_dir);
    if ((try typedir.typeCount(destination, dst_dir)) != typeCount) return error.CompactionMismatch;
    var typeId: u16 = 0;
    while (typeId < typeCount) : (typeId += 1) {
        const sourceCatalog = try typedir.catalogRef(source, src_dir, typeId);
        const destinationCatalog = try typedir.catalogRef(destination, dst_dir, typeId);

        // 1. live count.
        if ((try liveCount(source, sourceCatalog)) != (try liveCount(destination, destinationCatalog))) return error.CompactionMismatch;

        // 2. primaryKey-set fold + readability + forward-link match.
        var src_fold: u64 = 0;
        var src_n: u64 = 0;
        try foldPrimaryKeysAndCheck(allocator, source, sourceCatalog, destination, destinationCatalog, &src_fold, &src_n);
        var dst_fold: u64 = 0;
        var dst_n: u64 = 0;
        try foldPrimaryKeys(allocator, destination, destinationCatalog, &dst_fold, &dst_n);
        if (src_fold != dst_fold or src_n != dst_n) return error.CompactionMismatch;
    }
}

// Copy a database's live data into a brand-new file (an on-disk shrink),
// preserving object keys, primary keys, links, and backlinks. Before the new
// file is published (committed) it is verified equivalent to the source; on any
// mismatch the destination is discarded uncommitted and the error propagates.
pub fn compactToNewFile(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var sourceDatabase = try @import("../database.zig").Database.open(allocator, src_path);
    defer sourceDatabase.deinit();
    var src_r = try sourceDatabase.beginRead();
    defer src_r.end();
    const src_dir = src_r.root();
    const typeCount = try typedir.typeCount(&src_r, src_dir);

    var destinationDatabase = try @import("../database.zig").Database.create(allocator, dst_path);
    var destinationDatabaseAlive = true;
    defer if (destinationDatabaseAlive) destinationDatabase.deinit();
    var dst_w = try destinationDatabase.beginWrite();
    var dst_committed = false;
    defer if (!dst_committed) dst_w.deinit();

    // Reconstruct the schema (PropertyDefinitions per type) + embedded flags from the source.
    var schema = std.ArrayList([]catalog.PropertyDefinition).empty;
    defer {
        for (schema.items) |definitionList| allocator.free(definitionList);
        schema.deinit(allocator);
    }
    var embedded = std.ArrayList(bool).empty;
    defer embedded.deinit(allocator);
    {
        var typeId: u16 = 0;
        while (typeId < typeCount) : (typeId += 1) {
            const sourceCatalog = try typedir.catalogRef(&src_r, src_dir, typeId);
            const view = try catalog.loadCatalog(&src_r, sourceCatalog);
            const definitions = try allocator.alloc(catalog.PropertyDefinition, view.propertyCount);
            var propertyIndex: usize = 0;
            while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
                definitions[propertyIndex] = .{ .kind = view.kind(propertyIndex), .element = view.elementKind(propertyIndex), .link_target = view.linkTarget(propertyIndex), .del_rule = view.delRule(propertyIndex), .indexed = view.indexed(propertyIndex) };
            }
            try schema.append(allocator, definitions);
            try embedded.append(allocator, try typedir.isEmbedded(&src_r, src_dir, typeId));
        }
    }
    var dst_dir = try typedir.createTypes(&dst_w, schema.items, embedded.items);

    // Copy each type's live rows, then rebuild its backlinks.
    {
        var typeId: u16 = 0;
        while (typeId < typeCount) : (typeId += 1) {
            const sourceCatalog = try typedir.catalogRef(&src_r, src_dir, typeId);
            var destinationCatalog = try copyTypeRows(&src_r, sourceCatalog, &dst_w);
            destinationCatalog = try rebuildBacklinks(&dst_w, destinationCatalog);
            dst_dir = try typedir.setCatalogRef(&dst_w, dst_dir, typeId, destinationCatalog);
        }
    }

    // VERIFY before publishing. On any mismatch, abort (no commit) -> dst discarded.
    try verifyEquivalent(allocator, &src_r, src_dir, &dst_w, dst_dir);

    dst_w.setRoot(dst_dir);
    _ = try dst_w.commit();
    dst_committed = true;
    destinationDatabase.deinit();
    destinationDatabaseAlive = false;
}

const Io = std.Io;

// Compact a database file in place, crash-safely.
//
// The live data is first compacted into a sibling temp file "<path>.compacting"
// (written, verified equivalent, committed, and fsync'd by compactToNewFile),
// then the temp data file is atomically renamed over the original. The rename is
// the single publish point: a crash BEFORE it leaves the original `path`
// completely untouched (the orphan `.compacting` temp is simply overwritten on
// the next run); a crash AFTER it leaves the new compacted file in place, and
// the coord is recreated on the next Database.open.
//
// After the rename the stale coordination files are removed so the next open
// recreates "<path>.coord" fresh: the old coord describes the pre-compaction
// data file, and the temp's coord is orphaned once its data file is renamed away.
//
// `path` must be ABSOLUTE. The caller must close ALL handles to the database
// (and end any read/write transactions) before calling this -- there must be no
// other open Database on `path` while it is replaced.
pub fn compactInPlace(allocator: std.mem.Allocator, path: []const u8) !void {
    // Build "<path>.compacting" temp path.
    const tmp = try std.fmt.allocPrint(allocator, "{s}.compacting", .{path});
    defer allocator.free(tmp);

    // 1) Compact into the temp file (verified + committed inside compactToNewFile).
    try compactToNewFile(allocator, path, tmp);

    // 2) Publish atomically: rename temp data file over the original. Note the
    //    0.16 signature takes `io` LAST: renameAbsolute(old, new, io).
    const io = std.Io.Threaded.global_single_threaded.io();
    try Io.Dir.renameAbsolute(tmp, path, io);

    // 3) Remove stale coord files; next open recreates path.coord fresh.
    const tmp_coord = try std.fmt.allocPrint(allocator, "{s}.coord", .{tmp});
    defer allocator.free(tmp_coord);
    const path_coord = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
    defer allocator.free(path_coord);
    file_store.deleteAbsoluteIgnoreMissing(io, path_coord); // old coord (now describes replaced data)
    file_store.deleteAbsoluteIgnoreMissing(io, tmp_coord); // compaction's coord (orphaned by the rename)

    // 4) Make the rename durable across power loss by fsync'ing the parent
    //    directory. The data file is F_FULLFSYNC'd by compactToNewFile and the
    //    rename is atomic; this dir fsync hardens the directory ENTRY itself.
    //    Restored portably via libc fsync on the directory fd (the std.Io File
    //    sync wrapper panics with BADF on a directory handle on Linux).
    //    Best-effort: a failure here cannot un-publish the already-renamed file.
    file_store.syncParentDir(path);
}

// NOTE: link/backlink survival across a relocation is covered directly by
// relocation.zig's tests ("a same-type link to a relocated object still
// resolves"); compactStep only sequences relocateRow calls, so wiring links
// into these tests would duplicate that coverage without exercising new paths.

test {
    _ = @import("compactionTests.zig");
}
