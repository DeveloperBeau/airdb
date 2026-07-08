const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");
const typedir = @import("typedir.zig");
const objects = @import("objects.zig");
const relocateRow = @import("relocation.zig").relocateRow;
const file_store = @import("file_store.zig");
const compactionCopy = @import("compactionCopy.zig");

const max_prop_count = catalog.max_prop_count;

const Pair = compactionCopy.Pair;
const collectKeyRowPairs = compactionCopy.collectKeyRowPairs;

// Cross-database row/value deep-copying lives in compactionCopy.zig;
// re-exported here for the whole-file compaction callers below.
pub const copyTypeRows = compactionCopy.copyTypeRows;
pub const rebuildBacklinks = compactionCopy.rebuildBacklinks;

pub fn liveCount(txn: anytype, cat: Ref) !u64 {
    const v = try catalog.loadCatalog(txn, cat);
    return Index.count(txn, v.keyrow_index_ref);
}

pub fn shouldCompact(txn: anytype, cat: Ref) !bool {
    const v = try catalog.loadCatalog(txn, cat);
    const n = v.next_row;
    if (n == 0) return false;
    const live = try Index.count(txn, v.keyrow_index_ref);
    return (n - live) * 2 > n; // more than half the rows are dead
}

// Rebuild the type's columns to contain only live rows, packed densely, and
// remap the key->row index. Object keys, pk index, and backlink indexes are
// preserved (keyed by object key). Returns the new catalog ref.
pub fn compactType(txn: *WriteTxn, cat: Ref) !Ref {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const pc = s.prop_count;
    // Keep the old column/index roots to read from while the snapshot's fields
    // are re-pointed at the fresh dense structures.
    var old_prop: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) old_prop[j] = s.props[j].col;
    }
    const old_ver = s.version_col_ref;
    const old_live = s.live_col_ref;
    const old_keyrow = s.keyrow_index_ref;

    const alloc = txn.db.store.allocator;
    var pairs = try collectKeyRowPairs(alloc, txn, old_keyrow);
    defer pairs.deinit(alloc);

    // Build fresh dense columns.
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) s.props[j].col = try Column.create(txn);
    }
    s.version_col_ref = try Column.create(txn);
    s.live_col_ref = try Column.create(txn);
    s.keyrow_index_ref = try Index.create(txn);

    var new_row: u64 = 0;
    for (pairs.items) |pr| {
        // defensive live check (delete already drops dead keys from keyrow)
        if ((try Column.get(txn, old_live, pr.row)) == 0) continue;
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const cell = try Column.get(txn, old_prop[j], pr.row);
            s.props[j].col = try Column.append(txn, s.props[j].col, cell);
        }
        const ver = try Column.get(txn, old_ver, pr.row);
        s.version_col_ref = try Column.append(txn, s.version_col_ref, ver);
        s.live_col_ref = try Column.append(txn, s.live_col_ref, 1);
        s.keyrow_index_ref = try Index.insert(txn, s.keyrow_index_ref, pr.okey, new_row);
        new_row += 1;
    }

    // Free the replaced structures: the old property/version/live columns and
    // the old key->row index are fully copied out above and unreferenced by the
    // new catalog. Without this a full compact of a large type left its entire
    // old column set as permanently unreclaimable garbage. (The pk index,
    // backlinks, and value indexes are carried over, not rebuilt.)
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) try Column.freeTree(txn, old_prop[j]);
    }
    try Column.freeTree(txn, old_ver);
    try Column.freeTree(txn, old_live);
    try Index.freeTree(txn, old_keyrow);

    s.next_row = new_row;
    return s.replace(txn);
}

// Truncate a fully-packed type's columns down to `new_len` rows and publish a
// catalog with next_row == new_len. All live rows must already lie in
// [0, new_len); the dead tail is dropped. Object key/pk/backlink indexes are
// preserved unchanged. Returns the new catalog ref.
fn truncatePacked(txn: *WriteTxn, cat: Ref, new_len: u64) !Ref {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    {
        var j: usize = 0;
        while (j < s.prop_count) : (j += 1) s.props[j].col = try Column.truncate(txn, s.props[j].col, new_len);
    }
    s.version_col_ref = try Column.truncate(txn, s.version_col_ref, new_len);
    s.live_col_ref = try Column.truncate(txn, s.live_col_ref, new_len);
    s.next_row = new_len;
    return s.replace(txn);
}

// Two-pointer packing cursor for one in-flight compaction run. live_count and
// next_row pin the run to a specific catalog shape: if either changes between
// steps (churn inserted/deleted/relocated rows), the stored cursor is stale and
// must be discarded. hole_lo scans upward through [0, live_count) seeking dead
// relocation targets; high_hi scans downward from next_row toward live_count
// seeking live rows that must move down. Both advance monotonically across
// steps so no slot is ever revisited (relocateRow is not idempotent).
//
// The struct itself lives on the Db (the cursor persists across the write
// transactions of one packing run), so its definition is in db.zig.
pub const CompactCursor = @import("db.zig").CompactCursor;

// Map a physical row to its stable object key. There is no reverse key->row
// index, so we go through the primary key: property 0 holds the pk, and the pk
// index maps pk -> okey (the same association objects.insert builds and
// resolveProp reads). Valid for any live row; the row's pk cell is preserved by
// relocateRow, so this holds even after earlier relocations in the same run.
fn rowToOkey(txn: anytype, v: catalog.CatalogView, row: u64) !u64 {
    const pk = try Column.get(txn, v.propColRef(0), row);
    // A live row whose pk does not resolve means the pk index diverged from the
    // columns: surface corruption instead of crashing mid-compaction.
    return (try Index.get(txn, v.pk_index_ref, pk)) orelse error.Corrupt;
}

// Hard safety check before truncating a packed type's dead tail: no live row
// may survive in [live_count, next_row). Bounded, debug-only, and runs once
// per pack at the final step.
fn assertTailDead(txn: *WriteTxn, cat: Ref, live_count: u64, next_row: u64) !void {
    if (!std.debug.runtime_safety) return;
    const v = try catalog.loadCatalog(txn, cat);
    var r: u64 = live_count;
    while (r < next_row) : (r += 1) {
        std.debug.assert((try Column.get(txn, v.live_col_ref, r)) == 0);
    }
}

// Advance cursor.hole_lo upward to the next dead slot (relocation target) in
// [0, live_count).
fn advanceHoleCursor(txn: *WriteTxn, cat: Ref, live_count: u64, cursor: *CompactCursor) !void {
    const v = try catalog.loadCatalog(txn, cat);
    while (cursor.hole_lo < live_count and (try Column.get(txn, v.live_col_ref, cursor.hole_lo)) == 1) : (cursor.hole_lo += 1) {}
}

// Advance cursor.high_hi down past dead rows to the next live row at
// >= live_count.
fn advanceHighCursor(txn: *WriteTxn, cat: Ref, live_count: u64, cursor: *CompactCursor) !void {
    const v = try catalog.loadCatalog(txn, cat);
    while (cursor.high_hi > live_count and (try Column.get(txn, v.live_col_ref, cursor.high_hi - 1)) == 0) : (cursor.high_hi -= 1) {}
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
// persisted on the Db so the next call resumes where this one stopped.
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
pub fn compactStep(txn: *WriteTxn, cat: Ref, type_id: u16, budget: usize) !struct { cat: Ref, moved: usize, done: bool } {
    var cur = cat;
    const lc = try liveCount(txn, cur);
    const next_row = (try catalog.loadCatalog(txn, cur)).next_row;

    // Already packed (no live row above live_count). The dead tail is already
    // gone (next_row == live_count), so there is nothing to truncate.
    if (next_row == lc) {
        txn.db.compact_cursor = null;
        return .{ .cat = cur, .moved = 0, .done = true };
    }

    // Resume the stored cursor only if it pins this exact CATALOG (the ref
    // uniquely identifies the type and its committed state) with this exact
    // shape; otherwise (another type, churn, or a fresh run) restart the scan.
    var cursor: CompactCursor = blk: {
        if (txn.db.compact_cursor) |c| {
            if (c.type_id == type_id and c.cat == cat and c.live_count == lc and c.next_row == next_row) break :blk c;
        }
        break :blk .{ .type_id = type_id, .cat = cat, .live_count = lc, .next_row = next_row, .hole_lo = 0, .high_hi = next_row };
    };

    var moved: usize = 0;
    while (moved < budget) {
        try advanceHoleCursor(txn, cur, lc, &cursor);
        try advanceHighCursor(txn, cur, lc, &cursor);
        // No high live rows left to move, or (defensively) no holes to fill.
        if (cursor.high_hi <= lc or cursor.hole_lo >= lc) break;

        const high_row = cursor.high_hi - 1;
        const okey = try rowToOkey(txn, try catalog.loadCatalog(txn, cur), high_row);
        cur = try relocateRow(txn, cur, okey, cursor.hole_lo);
        // The hole is now live and the high row now dead; step past both.
        cursor.hole_lo += 1;
        cursor.high_hi -= 1;
        moved += 1;
    }

    // Skip any trailing dead rows the budget loop left unexamined so the guard
    // sees the true frontier (lets `done` fire as early as it is provably safe).
    try advanceHighCursor(txn, cur, lc, &cursor);

    if (cursor.high_hi <= lc) {
        try assertTailDead(txn, cur, lc, next_row);
        cur = try truncatePacked(txn, cur, lc);
        txn.db.compact_cursor = null;
        return .{ .cat = cur, .moved = moved, .done = true };
    }

    // Persist against the catalog ref the NEXT call will see: relocations COW
    // the catalog, so `cur` is what the caller publishes and later re-derives.
    cursor.cat = cur;
    txn.db.compact_cursor = cursor;
    return .{ .cat = cur, .moved = moved, .done = false };
}

// ---------------------------------------------------------------------------
// Full-file compaction with a verify-before-swap equivalence gate.
// ---------------------------------------------------------------------------

pub const CompactionError = error{CompactionMismatch};

// Order-independent 64-bit mix of a primary key, folded with XOR so the running
// accumulator does not depend on traversal order.
inline fn mixPk(pk: u64) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&pk));
}

// Walk a catalog's key->row index, reading each live row's primary key (prop 0),
// and fold the pk set into `fold` (XOR of mixed pks) while counting rows. The
// fold is identity-preserving and order-independent.
fn foldPks(allocator: std.mem.Allocator, txn: anytype, cat: Ref, fold: *u64, count: *u64) !void {
    const v = try catalog.loadCatalog(txn, cat);
    const prop0 = v.propColRef(0);
    var pairs = try collectKeyRowPairs(allocator, txn, v.keyrow_index_ref);
    defer pairs.deinit(allocator);
    for (pairs.items) |pr| {
        const pk = try Column.get(txn, prop0, pr.row);
        fold.* ^= mixPk(pk);
        count.* += 1;
    }
}

// Fold SRC's pk set (like foldPks) AND, for every live source object, prove that
// the destination preserves it: (a) the object is readable in dst by its
// original object key, and (b) every to-one link property holds the same raw
// target in dst as in src. Returns error.CompactionMismatch on any failure.
fn foldPksAndCheck(allocator: std.mem.Allocator, src: anytype, sc: Ref, dst: anytype, dc: Ref, fold: *u64, count: *u64) !void {
    const sv = try catalog.loadCatalog(src, sc);
    const dv = try catalog.loadCatalog(dst, dc);
    const pc = sv.prop_count;
    if (dv.prop_count != pc) return error.CompactionMismatch;

    // Snapshot column refs and per-prop kinds for both sides up front.
    var s_prop: [max_prop_count]Ref = undefined;
    var d_prop: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]catalog.PropKind = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            s_prop[j] = sv.propColRef(j);
            d_prop[j] = dv.propColRef(j);
            kinds[j] = sv.kind(j);
            if (dv.kind(j) != kinds[j]) return error.CompactionMismatch;
        }
    }
    const s_prop0 = s_prop[0];

    // Collect SRC's live (okey, row) pairs.
    var pairs = try collectKeyRowPairs(allocator, src, sv.keyrow_index_ref);
    defer pairs.deinit(allocator);

    var out: [max_prop_count]catalog.Value = undefined;
    for (pairs.items) |pr| {
        // pk fold over the source.
        const pk = try Column.get(src, s_prop0, pr.row);
        fold.* ^= mixPk(pk);
        count.* += 1;

        // (a) readability: the same object key must decode in dst.
        if ((try objects.getTypedByOkey(dst, dc, pr.okey, out[0..pc])) == null) return error.CompactionMismatch;

        const drow = (try catalog.okeyToRow(dst, dc, pr.okey)) orelse return error.CompactionMismatch;
        try checkRowProperties(src, dst, dv, kinds[0..pc], s_prop[0..pc], d_prop[0..pc], pr, drow);
    }
}

// Per-property preservation checks for one copied row: (b) to-one forward
// links must carry the identical raw target in dst, and (c) every indexed
// property value must be covered by the destination's value index -- an empty
// or stale index passes the row-readability checks but silently empties
// queries. Returns error.CompactionMismatch on any divergence.
fn checkRowProperties(
    src: anytype,
    dst: anytype,
    dv: catalog.CatalogView,
    kinds: []const catalog.PropKind,
    s_prop: []const Ref,
    d_prop: []const Ref,
    pr: Pair,
    drow: u64,
) !void {
    var p: usize = 0;
    while (p < kinds.len) : (p += 1) {
        if (kinds[p] == .link) {
            const s_raw = try Column.get(src, s_prop[p], pr.row);
            const d_raw = try Column.get(dst, d_prop[p], drow);
            if (s_raw != d_raw) return error.CompactionMismatch;
        }
        if (dv.indexed(p)) {
            const d_raw = try Column.get(dst, d_prop[p], drow);
            const inner = (try Index.get(dst, dv.valueIndexRef(p), d_raw)) orelse return error.CompactionMismatch;
            if ((try Index.get(dst, inner, pr.okey)) == null) return error.CompactionMismatch;
        }
    }
}

// Verify the destination is equivalent to the source before it is published.
// Proves, per type: identical type count, identical live count, identical pk set
// (order-independent fold), every source object readable in dst by its original
// key, and identical to-one forward links. Any divergence aborts the compaction.
fn verifyEquivalent(allocator: std.mem.Allocator, src: anytype, src_dir: Ref, dst: anytype, dst_dir: Ref) !void {
    const tc = try typedir.typeCount(src, src_dir);
    if ((try typedir.typeCount(dst, dst_dir)) != tc) return error.CompactionMismatch;
    var t: u16 = 0;
    while (t < tc) : (t += 1) {
        const sc = try typedir.catalogRef(src, src_dir, t);
        const dc = try typedir.catalogRef(dst, dst_dir, t);

        // 1. live count.
        if ((try liveCount(src, sc)) != (try liveCount(dst, dc))) return error.CompactionMismatch;

        // 2. pk-set fold + readability + forward-link match.
        var src_fold: u64 = 0;
        var src_n: u64 = 0;
        try foldPksAndCheck(allocator, src, sc, dst, dc, &src_fold, &src_n);
        var dst_fold: u64 = 0;
        var dst_n: u64 = 0;
        try foldPks(allocator, dst, dc, &dst_fold, &dst_n);
        if (src_fold != dst_fold or src_n != dst_n) return error.CompactionMismatch;
    }
}

// Copy a database's live data into a brand-new file (an on-disk shrink),
// preserving object keys, primary keys, links, and backlinks. Before the new
// file is published (committed) it is verified equivalent to the source; on any
// mismatch the destination is discarded uncommitted and the error propagates.
pub fn compactToNewFile(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var src_db = try @import("db.zig").Db.open(allocator, src_path);
    defer src_db.deinit();
    var src_r = try src_db.beginRead();
    defer src_r.end();
    const src_dir = src_r.root();
    const tc = try typedir.typeCount(&src_r, src_dir);

    var dst_db = try @import("db.zig").Db.create(allocator, dst_path);
    var dst_db_alive = true;
    defer if (dst_db_alive) dst_db.deinit();
    var dst_w = try dst_db.beginWrite();
    var dst_committed = false;
    defer if (!dst_committed) dst_w.deinit();

    // Reconstruct the schema (PropDefs per type) + embedded flags from the source.
    var schema = std.ArrayList([]catalog.PropDef).empty;
    defer {
        for (schema.items) |s| allocator.free(s);
        schema.deinit(allocator);
    }
    var embedded = std.ArrayList(bool).empty;
    defer embedded.deinit(allocator);
    {
        var t: u16 = 0;
        while (t < tc) : (t += 1) {
            const sc = try typedir.catalogRef(&src_r, src_dir, t);
            const v = try catalog.loadCatalog(&src_r, sc);
            const defs = try allocator.alloc(catalog.PropDef, v.prop_count);
            var j: usize = 0;
            while (j < v.prop_count) : (j += 1) {
                defs[j] = .{ .kind = v.kind(j), .elem = v.elemKind(j), .link_target = v.linkTarget(j), .del_rule = v.delRule(j), .indexed = v.indexed(j) };
            }
            try schema.append(allocator, defs);
            try embedded.append(allocator, try typedir.isEmbedded(&src_r, src_dir, t));
        }
    }
    var dst_dir = try typedir.createTypes(&dst_w, schema.items, embedded.items);

    // Copy each type's live rows, then rebuild its backlinks.
    {
        var t: u16 = 0;
        while (t < tc) : (t += 1) {
            const sc = try typedir.catalogRef(&src_r, src_dir, t);
            var dc = try copyTypeRows(&src_r, sc, &dst_w);
            dc = try rebuildBacklinks(&dst_w, dc);
            dst_dir = try typedir.setCatalogRef(&dst_w, dst_dir, t, dc);
        }
    }

    // VERIFY before publishing. On any mismatch, abort (no commit) -> dst discarded.
    try verifyEquivalent(allocator, &src_r, src_dir, &dst_w, dst_dir);

    dst_w.setRoot(dst_dir);
    _ = try dst_w.commit();
    dst_committed = true;
    dst_db.deinit();
    dst_db_alive = false;
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
// the coord is recreated on the next Db.open.
//
// After the rename the stale coordination files are removed so the next open
// recreates "<path>.coord" fresh: the old coord describes the pre-compaction
// data file, and the temp's coord is orphaned once its data file is renamed away.
//
// `path` must be ABSOLUTE. The caller must close ALL handles to the database
// (and end any read/write transactions) before calling this -- there must be no
// other open Db on `path` while it is replaced.
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
