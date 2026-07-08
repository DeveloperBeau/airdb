const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");
const typeDirectory = @import("../schema/typeDirectory.zig");
const objects = @import("../records/objects.zig");
const relocateRow = @import("relocation.zig").relocateRow;
const fileStore = @import("fileStore.zig");
const compactionCopy = @import("compactionCopy.zig");

const maxPropertyCount = catalog.maxPropertyCount;

const Pair = compactionCopy.Pair;
const collectKeyRowPairs = compactionCopy.collectKeyRowPairs;

/// Deep-copy one type's live rows into a fresh catalog in another database
/// (re-exported from compactionCopy.zig for the whole-file compaction
/// callers below).
pub const copyTypeRows = compactionCopy.copyTypeRows;
/// Rebuild a copied type's backlink indexes from its copied forward links
/// (re-exported from compactionCopy.zig).
pub const rebuildBacklinks = compactionCopy.rebuildBacklinks;

/// Number of live rows in the type, counted from the key->row index (a
/// single-node count read).
pub fn liveCount(transaction: anytype, catalogRef: Reference) !u64 {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    return Index.count(transaction, view.keyrowIndexRef);
}

/// True when more than half the type's physical rows are dead -- the packing
/// trigger. Single-node reads, O(1).
pub fn shouldCompact(transaction: anytype, catalogRef: Reference) !bool {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    const nextRow = view.nextRow;
    if (nextRow == 0) return false;
    const live = try Index.count(transaction, view.keyrowIndexRef);
    return (nextRow - live) * 2 > nextRow; // more than half the rows are dead
}

/// Rebuild the type's columns to contain only live rows, packed densely, and
/// remap the key->row index. Object keys, primaryKey index, and backlink
/// indexes are preserved (keyed by object key). Returns the new catalog ref.
/// O(live rows x properties) column writes in one transaction.
pub fn compactType(transaction: *WriteTransaction, catalogRef: Reference) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const propertyCount = snapshot.propertyCount;
    // Keep the old column/index roots to read from while the snapshot's fields
    // are re-pointed at the fresh dense structures.
    var oldPropertyColumns: [maxPropertyCount]Reference = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) oldPropertyColumns[propertyIndex] = snapshot.properties[propertyIndex].column;
    }
    const oldVersion = snapshot.versionColumnRef;
    const oldLive = snapshot.liveColumnRef;
    const oldKeyrow = snapshot.keyrowIndexRef;

    const alloc = transaction.database.store.allocator;
    var pairs = try collectKeyRowPairs(alloc, transaction, oldKeyrow);
    defer pairs.deinit(alloc);

    // Build fresh dense columns.
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex].column = try Column.create(transaction);
    }
    snapshot.versionColumnRef = try Column.create(transaction);
    snapshot.liveColumnRef = try Column.create(transaction);
    snapshot.keyrowIndexRef = try Index.create(transaction);

    var newRow: u64 = 0;
    for (pairs.items) |pair| {
        // defensive live check (delete already drops dead keys from keyrow)
        if ((try Column.get(transaction, oldLive, pair.row)) == 0) continue;
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const cell = try Column.get(transaction, oldPropertyColumns[propertyIndex], pair.row);
            snapshot.properties[propertyIndex].column = try Column.append(transaction, snapshot.properties[propertyIndex].column, cell);
        }
        const version = try Column.get(transaction, oldVersion, pair.row);
        snapshot.versionColumnRef = try Column.append(transaction, snapshot.versionColumnRef, version);
        snapshot.liveColumnRef = try Column.append(transaction, snapshot.liveColumnRef, 1);
        snapshot.keyrowIndexRef = try Index.insert(transaction, snapshot.keyrowIndexRef, pair.objectKey, newRow);
        newRow += 1;
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
    try Column.freeTree(transaction, oldLive);
    try Index.freeTree(transaction, oldKeyrow);

    snapshot.nextRow = newRow;
    return snapshot.replace(transaction);
}

// Truncate a fully-packed type's columns down to `newLen` rows and publish a
// catalog with nextRow == newLen. All live rows must already lie in
// [0, newLen); the dead tail is dropped. Object key/primaryKey/backlink indexes are
// preserved unchanged. Returns the new catalog ref.
fn truncatePacked(transaction: *WriteTransaction, catalogRef: Reference, newLen: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex].column = try Column.truncate(transaction, snapshot.properties[propertyIndex].column, newLen);
    }
    snapshot.versionColumnRef = try Column.truncate(transaction, snapshot.versionColumnRef, newLen);
    snapshot.liveColumnRef = try Column.truncate(transaction, snapshot.liveColumnRef, newLen);
    snapshot.nextRow = newLen;
    return snapshot.replace(transaction);
}

/// Two-pointer packing cursor for one in-flight compaction run. liveCount and
/// nextRow pin the run to a specific catalog shape: if either changes between
/// steps (churn inserted/deleted/relocated rows), the stored cursor is stale and
/// must be discarded. holeLo scans upward through [0, liveCount) seeking dead
/// relocation targets; highHi scans downward from nextRow toward liveCount
/// seeking live rows that must move down. Both advance monotonically across
/// steps so no slot is ever revisited (relocateRow is not idempotent).
///
/// The struct itself lives on the Database (the cursor persists across the write
/// transactions of one packing run), so its definition is in database.zig.
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
// may survive in [liveRowCount, nextRow). Bounded, debug-only, and runs once
// per pack at the final step.
fn assertTailDead(transaction: *WriteTransaction, catalogRef: Reference, liveRowCount: u64, nextRow: u64) !void {
    if (!std.debug.runtime_safety) return;
    const view = try catalog.loadCatalog(transaction, catalogRef);
    var row: u64 = liveRowCount;
    while (row < nextRow) : (row += 1) {
        std.debug.assert((try Column.get(transaction, view.liveColumnRef, row)) == 0);
    }
}

// Advance cursor.holeLo upward to the next dead slot (relocation target) in
// [0, liveRowCount).
fn advanceHoleCursor(transaction: *WriteTransaction, catalogRef: Reference, liveRowCount: u64, cursor: *CompactCursor) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    while (cursor.holeLo < liveRowCount and (try Column.get(transaction, view.liveColumnRef, cursor.holeLo)) == 1) : (cursor.holeLo += 1) {}
}

// Advance cursor.highHi down past dead rows to the next live row at
// >= liveRowCount.
fn advanceHighCursor(transaction: *WriteTransaction, catalogRef: Reference, liveRowCount: u64, cursor: *CompactCursor) !void {
    const view = try catalog.loadCatalog(transaction, catalogRef);
    while (cursor.highHi > liveRowCount and (try Column.get(transaction, view.liveColumnRef, cursor.highHi - 1)) == 0) : (cursor.highHi -= 1) {}
}

/// Incrementally pack a type toward dense storage, doing at most `budget`
/// relocations per call, using a budget-proportional two-pointer tail scan
/// instead of a full index walk.
///
/// `holeLo` advances upward through [0, liveCount) to find dead slots
/// (relocation targets); `highHi` advances downward from nextRow toward
/// liveCount to find live rows at physical index >= liveCount (rows that must
/// move down). Each paired (hole, high row) is relocated via relocateRow, up to
/// `budget` times; both cursors then step past the consumed slots. The cursor is
/// persisted on the Database so the next call resumes where this one stopped.
///
/// Reset rule (data-loss-critical): the cursor is only resumed when the freshly
/// loaded liveCount AND nextRow match the stored ones. Any mismatch -- or no
/// stored cursor -- restarts the scan from holeLo=0, highHi=nextRow. This
/// guarantees a stale cursor (from churn between steps) can never be trusted.
///
/// Truncation guard (the no-data-loss line): the dead tail [liveCount, nextRow)
/// is truncated, and `done` reported, ONLY when `highHi <= liveCount` -- i.e.
/// the downward cursor has examined the ENTIRE range above liveCount and every
/// live row it found was relocated (relocating a high row flips it dead, then the
/// cursor steps past it). This is equivalent in safety to the old
/// "all collected high rows moved" guard: both certify that no live row remains
/// in [liveCount, nextRow) before the truncate. A debug-only bounded scan
/// asserts exactly that immediately before truncating. Returns the updated
/// catalog ref, the rows moved this call, and whether packing finished.
pub fn compactStep(transaction: *WriteTransaction, catalogRef: Reference, typeId: u16, budget: usize) !struct { catalogRef: Reference, moved: usize, done: bool } {
    var currentCatalog = catalogRef;
    const liveRows = try liveCount(transaction, currentCatalog);
    const nextRow = (try catalog.loadCatalog(transaction, currentCatalog)).nextRow;

    // Already packed (no live row above liveCount). The dead tail is already
    // gone (nextRow == liveCount), so there is nothing to truncate.
    if (nextRow == liveRows) {
        transaction.database.compactCursor = null;
        return .{ .catalogRef = currentCatalog, .moved = 0, .done = true };
    }

    // Resume the stored cursor only if it pins this exact CATALOG (the ref
    // uniquely identifies the type and its committed state) with this exact
    // shape; otherwise (another type, churn, or a fresh run) restart the scan.
    var cursor: CompactCursor = blk: {
        if (transaction.database.compactCursor) |cursor| {
            if (cursor.typeId == typeId and cursor.catalogRef == catalogRef and cursor.liveCount == liveRows and cursor.nextRow == nextRow) break :blk cursor;
        }
        break :blk .{ .typeId = typeId, .catalogRef = catalogRef, .liveCount = liveRows, .nextRow = nextRow, .holeLo = 0, .highHi = nextRow };
    };

    var moved: usize = 0;
    while (moved < budget) {
        try advanceHoleCursor(transaction, currentCatalog, liveRows, &cursor);
        try advanceHighCursor(transaction, currentCatalog, liveRows, &cursor);
        // No high live rows left to move, or (defensively) no holes to fill.
        if (cursor.highHi <= liveRows or cursor.holeLo >= liveRows) break;

        const highRow = cursor.highHi - 1;
        const objectKey = try rowToObjectKey(transaction, try catalog.loadCatalog(transaction, currentCatalog), highRow);
        currentCatalog = try relocateRow(transaction, currentCatalog, objectKey, cursor.holeLo);
        // The hole is now live and the high row now dead; step past both.
        cursor.holeLo += 1;
        cursor.highHi -= 1;
        moved += 1;
    }

    // Skip any trailing dead rows the budget loop left unexamined so the guard
    // sees the true frontier (lets `done` fire as early as it is provably safe).
    try advanceHighCursor(transaction, currentCatalog, liveRows, &cursor);

    if (cursor.highHi <= liveRows) {
        try assertTailDead(transaction, currentCatalog, liveRows, nextRow);
        currentCatalog = try truncatePacked(transaction, currentCatalog, liveRows);
        transaction.database.compactCursor = null;
        return .{ .catalogRef = currentCatalog, .moved = moved, .done = true };
    }

    // Persist against the catalog ref the NEXT call will see: relocations COW
    // the catalog, so `cur` is what the caller publishes and later re-derives.
    cursor.catalogRef = currentCatalog;
    transaction.database.compactCursor = cursor;
    return .{ .catalogRef = currentCatalog, .moved = moved, .done = false };
}

// ---------------------------------------------------------------------------
// Full-file compaction with a verify-before-swap equivalence gate.
// ---------------------------------------------------------------------------

/// Verification failure: the compacted copy did not match the source, so the
/// swap was refused.
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
    var pairs = try collectKeyRowPairs(allocator, transaction, view.keyrowIndexRef);
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
    var pairs = try collectKeyRowPairs(allocator, source, sourceView.keyrowIndexRef);
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
            const sRaw = try Column.get(source, sourcePropertyColumns[propertyIndex], pair.row);
            const dRaw = try Column.get(destination, destinationPropertyColumns[propertyIndex], drow);
            if (sRaw != dRaw) return error.CompactionMismatch;
        }
        if (destinationView.indexed(propertyIndex)) {
            const dRaw = try Column.get(destination, destinationPropertyColumns[propertyIndex], drow);
            const inner = (try Index.get(destination, destinationView.valueIndexRef(propertyIndex), dRaw)) orelse return error.CompactionMismatch;
            if ((try Index.get(destination, inner, pair.objectKey)) == null) return error.CompactionMismatch;
        }
    }
}

// Verify the destination is equivalent to the source before it is published.
// Proves, per type: identical type count, identical live count, identical primaryKey set
// (order-independent fold), every source object readable in dst by its original
// key, and identical to-one forward links. Any divergence aborts the compaction.
fn verifyEquivalent(allocator: std.mem.Allocator, source: anytype, sourceDirectoryReference: Reference, destination: anytype, destinationDirectoryReference: Reference) !void {
    const typeCount = try typeDirectory.typeCount(source, sourceDirectoryReference);
    if ((try typeDirectory.typeCount(destination, destinationDirectoryReference)) != typeCount) return error.CompactionMismatch;
    var typeId: u16 = 0;
    while (typeId < typeCount) : (typeId += 1) {
        const sourceCatalog = try typeDirectory.catalogRef(source, sourceDirectoryReference, typeId);
        const destinationCatalog = try typeDirectory.catalogRef(destination, destinationDirectoryReference, typeId);

        // 1. live count.
        if ((try liveCount(source, sourceCatalog)) != (try liveCount(destination, destinationCatalog))) return error.CompactionMismatch;

        // 2. primaryKey-set fold + readability + forward-link match.
        var srcFold: u64 = 0;
        var srcN: u64 = 0;
        try foldPrimaryKeysAndCheck(allocator, source, sourceCatalog, destination, destinationCatalog, &srcFold, &srcN);
        var dstFold: u64 = 0;
        var dstN: u64 = 0;
        try foldPrimaryKeys(allocator, destination, destinationCatalog, &dstFold, &dstN);
        if (srcFold != dstFold or srcN != dstN) return error.CompactionMismatch;
    }
}

/// Copy a database's live data into a brand-new file (an on-disk shrink),
/// preserving object keys, primary keys, links, and backlinks. Before the new
/// file is published (committed) it is verified equivalent to the source; on
/// any mismatch the destination is discarded uncommitted and the error
/// propagates. Heavy I/O: opens both databases and reads every live row twice
/// (copy, then verify).
pub fn compactToNewFile(allocator: std.mem.Allocator, srcPath: []const u8, dstPath: []const u8) !void {
    var sourceDatabase = try @import("../database.zig").Database.open(allocator, srcPath);
    defer sourceDatabase.deinit();
    var srcR = try sourceDatabase.beginRead();
    defer srcR.end();
    const sourceDirectoryReference = srcR.root();
    const typeCount = try typeDirectory.typeCount(&srcR, sourceDirectoryReference);

    var destinationDatabase = try @import("../database.zig").Database.create(allocator, dstPath);
    var destinationDatabaseAlive = true;
    defer if (destinationDatabaseAlive) destinationDatabase.deinit();
    var dstW = try destinationDatabase.beginWrite();
    var dstCommitted = false;
    defer if (!dstCommitted) dstW.deinit();

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
            const sourceCatalog = try typeDirectory.catalogRef(&srcR, sourceDirectoryReference, typeId);
            const view = try catalog.loadCatalog(&srcR, sourceCatalog);
            const definitions = try allocator.alloc(catalog.PropertyDefinition, view.propertyCount);
            var propertyIndex: usize = 0;
            while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
                definitions[propertyIndex] = .{ .kind = view.kind(propertyIndex), .element = view.elementKind(propertyIndex), .linkTarget = view.linkTarget(propertyIndex), .deletionRule = view.deletionRule(propertyIndex), .indexed = view.indexed(propertyIndex) };
            }
            try schema.append(allocator, definitions);
            try embedded.append(allocator, try typeDirectory.isEmbedded(&srcR, sourceDirectoryReference, typeId));
        }
    }
    var destinationDirectoryReference = try typeDirectory.createTypes(&dstW, schema.items, embedded.items);

    // Copy each type's live rows, then rebuild its backlinks.
    {
        var typeId: u16 = 0;
        while (typeId < typeCount) : (typeId += 1) {
            const sourceCatalog = try typeDirectory.catalogRef(&srcR, sourceDirectoryReference, typeId);
            var destinationCatalog = try copyTypeRows(&srcR, sourceCatalog, &dstW);
            destinationCatalog = try rebuildBacklinks(&dstW, destinationCatalog);
            destinationDirectoryReference = try typeDirectory.setCatalogRef(&dstW, destinationDirectoryReference, typeId, destinationCatalog);
        }
    }

    // VERIFY before publishing. On any mismatch, abort (no commit) -> dst discarded.
    try verifyEquivalent(allocator, &srcR, sourceDirectoryReference, &dstW, destinationDirectoryReference);

    dstW.setRoot(destinationDirectoryReference);
    _ = try dstW.commit();
    dstCommitted = true;
    destinationDatabase.deinit();
    destinationDatabaseAlive = false;
}

const Io = std.Io;

/// Compact a database file in place, crash-safely. Heavy I/O: a full copy,
/// verify, fsync, and rename.
///
/// The live data is first compacted into a sibling temp file "<path>.compacting"
/// (written, verified equivalent, committed, and fsync'd by compactToNewFile),
/// then the temp data file is atomically renamed over the original. The rename is
/// the single publish point: a crash BEFORE it leaves the original `path`
/// completely untouched (the orphan `.compacting` temp is simply overwritten on
/// the next run); a crash AFTER it leaves the new compacted file in place, and
/// the coordination is recreated on the next Database.open.
///
/// After the rename the stale coordination files are removed so the next open
/// recreates "<path>.coord" fresh: the old coordination file describes the pre-compaction
/// data file, and the temp's coordination is orphaned once its data file is renamed away.
///
/// `path` must be ABSOLUTE. The caller must close ALL handles to the database
/// (and end any read/write transactions) before calling this -- there must be no
/// other open Database on `path` while it is replaced.
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

    // 3) Remove stale coordination files; next open recreates path.coord fresh.
    const tmpCoord = try std.fmt.allocPrint(allocator, "{s}.coord", .{tmp});
    defer allocator.free(tmpCoord);
    const pathCoord = try std.fmt.allocPrint(allocator, "{s}.coord", .{path});
    defer allocator.free(pathCoord);
    fileStore.deleteAbsoluteIgnoreMissing(io, pathCoord); // old coordination (now describes replaced data)
    fileStore.deleteAbsoluteIgnoreMissing(io, tmpCoord); // compaction's coordination (orphaned by the rename)

    // 4) Make the rename durable across power loss by fsync'ing the parent
    //    directory. The data file is F_FULLFSYNC'd by compactToNewFile and the
    //    rename is atomic; this directory fsync hardens the directory ENTRY itself.
    //    Restored portably via libc fsync on the directory fd (the std.Io File
    //    sync wrapper panics with BADF on a directory handle on Linux).
    //    Best-effort: a failure here cannot un-publish the already-renamed file.
    fileStore.syncParentDirectory(path);
}

// NOTE: link/backlink survival across a relocation is covered directly by
// relocation.zig's tests ("a same-type link to a relocated object still
// resolves"); compactStep only sequences relocateRow calls, so wiring links
// into these tests would duplicate that coverage without exercising new paths.

test {
    _ = @import("compactionTests.zig");
}
