const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");
const blob = @import("blob.zig");
const links = @import("links.zig");
const typedir = @import("typedir.zig");
const objects = @import("objects.zig");
const bindex = @import("bindex.zig");
const relocateRow = @import("relocation.zig").relocateRow;

const max_prop_count = catalog.max_prop_count;

const Pair = struct { okey: u64, row: u64 };

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
    const v = try catalog.loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_key = v.next_key;
    const pk_index_ref = v.pk_index_ref;
    const old_ver = v.version_col_ref;
    const old_live = v.live_col_ref;
    const old_keyrow = v.keyrow_index_ref;
    var old_prop: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]catalog.PropKind = undefined;
    var elems: [max_prop_count]catalog.ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            old_prop[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
        }
    }
    const alloc = txn.db.store.allocator;
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(alloc);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: u64, val: u64) !void {
            try self.list.append(self.alloc, .{ .okey = key, .row = val });
        }
    };
    try Index.forEachEntry(txn, old_keyrow, Collector{ .list = &pairs, .alloc = alloc }, Collector.onEntry);

    // Build fresh dense columns.
    var new_prop: [max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) new_prop[j] = try Column.create(txn);
    }
    var new_ver = try Column.create(txn);
    var new_live = try Column.create(txn);
    var new_keyrow = try Index.create(txn);

    var new_row: u64 = 0;
    for (pairs.items) |pr| {
        // defensive live check (delete already drops dead keys from keyrow)
        if ((try Column.get(txn, old_live, pr.row)) == 0) continue;
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const cell = try Column.get(txn, old_prop[j], pr.row);
            new_prop[j] = try Column.append(txn, new_prop[j], cell);
        }
        const ver = try Column.get(txn, old_ver, pr.row);
        new_ver = try Column.append(txn, new_ver, ver);
        new_live = try Column.append(txn, new_live, 1);
        new_keyrow = try Index.insert(txn, new_keyrow, pr.okey, new_row);
        new_row += 1;
    }

    return catalog.writeCatalog(txn, pc, new_row, new_keyrow, next_key, pk_index_ref, new_ver, new_live, new_prop[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets[0..pc], rules[0..pc]);
}

// Truncate a fully-packed type's columns down to `new_len` rows and publish a
// catalog with next_row == new_len. All live rows must already lie in
// [0, new_len); the dead tail is dropped. Object key/pk/backlink indexes are
// preserved unchanged. Returns the new catalog ref.
fn truncatePacked(txn: *WriteTxn, cat: Ref, new_len: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const pc = v.prop_count;
    const next_key = v.next_key;
    const keyrow = v.keyrow_index_ref;
    const pk_index_ref = v.pk_index_ref;
    // Snapshot all view-backed values before truncating: Column.truncate can grow
    // the file and invalidate the bytes backing the CatalogView.
    var prop: [max_prop_count]Ref = undefined;
    var kinds: [max_prop_count]catalog.PropKind = undefined;
    var elems: [max_prop_count]catalog.ElemKind = undefined;
    var bl: [max_prop_count]Ref = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            prop[j] = v.propColRef(j);
            kinds[j] = v.kind(j);
            elems[j] = v.elemKind(j);
            bl[j] = v.backlinkRef(j);
            targets[j] = v.linkTarget(j);
            rules[j] = v.delRule(j);
        }
    }
    var ver = v.version_col_ref;
    var live = v.live_col_ref;

    {
        var j: usize = 0;
        while (j < pc) : (j += 1) prop[j] = try Column.truncate(txn, prop[j], new_len);
    }
    ver = try Column.truncate(txn, ver, new_len);
    live = try Column.truncate(txn, live, new_len);

    return catalog.writeCatalog(txn, pc, new_len, keyrow, next_key, pk_index_ref, ver, live, prop[0..pc], kinds[0..pc], elems[0..pc], bl[0..pc], targets[0..pc], rules[0..pc]);
}

// Incrementally pack a type toward dense storage, doing at most `budget`
// relocations per call. Each call moves up to `budget` "high" live rows (those
// at physical index >= live_count) down into "holes" (dead slots below
// live_count), then -- once no high live rows remain -- truncates the dead tail
// so next_row == live_count. `done` is true when the type is fully packed and
// truncated; call again with the returned cat until `done`. Returns the updated
// catalog ref, the number of rows moved this call, and whether packing finished.
pub fn compactStep(txn: *WriteTxn, cat: Ref, budget: usize) !struct { cat: Ref, moved: usize, done: bool } {
    var cur = cat;
    const lc = try liveCount(txn, cur);
    const alloc = txn.db.store.allocator;

    // Already packed (no live row above live_count): just ensure the tail is
    // truncated so next_row == live_count, and report done.
    if ((try catalog.loadCatalog(txn, cur)).next_row == lc) {
        return .{ .cat = cur, .moved = 0, .done = true };
    }

    // One pass over the key->row index: collect the high live rows (row >= lc)
    // and mark which slots in [0, lc) are occupied. Unmarked slots are holes.
    var high = std.ArrayList(Pair).empty;
    defer high.deinit(alloc);
    const occ = try alloc.alloc(bool, @intCast(lc));
    defer alloc.free(occ);
    @memset(occ, false);

    const Collector = struct {
        high: *std.ArrayList(Pair),
        occ: []bool,
        a: std.mem.Allocator,
        lc: u64,
        fn onEntry(self: @This(), okey: u64, row: u64) !void {
            if (row >= self.lc) {
                try self.high.append(self.a, .{ .okey = okey, .row = row });
            } else {
                self.occ[@intCast(row)] = true;
            }
        }
    };
    {
        const v = try catalog.loadCatalog(txn, cur);
        try Index.forEachEntry(txn, v.keyrow_index_ref, Collector{ .high = &high, .occ = occ, .a = alloc, .lc = lc }, Collector.onEntry);
    }

    // Holes are the unmarked indices in [0, lc). By construction their count
    // equals high.len (total live rows == lc), but we min over both to be safe.
    var holes = std.ArrayList(u64).empty;
    defer holes.deinit(alloc);
    {
        var i: u64 = 0;
        while (i < lc) : (i += 1) if (!occ[@intCast(i)]) try holes.append(alloc, i);
    }

    // Relocate high rows into holes, up to the budget.
    const limit = @min(budget, @min(high.items.len, holes.items.len));
    var moved: usize = 0;
    while (moved < limit) : (moved += 1) {
        cur = try relocateRow(txn, cur, high.items[moved].okey, holes.items[moved]);
    }

    // Each relocation consumes one high row; if any remain, budget is exhausted
    // and we are not done. Otherwise every live row is now packed in [0, lc):
    // truncate the dead tail and finish.
    if (high.items.len - moved == 0) {
        cur = try truncatePacked(txn, cur, lc);
        return .{ .cat = cur, .moved = moved, .done = true };
    }
    return .{ .cat = cur, .moved = moved, .done = false };
}

// Deep-copy a single property value from the source db into the destination db.
// kind/elem describe the property. Returns the destination-local raw u64.
fn copyValue(src: anytype, dst: *WriteTxn, kind: catalog.PropKind, elem: catalog.ElemKind, src_raw: u64) !u64 {
    return switch (kind) {
        .int, .link => src_raw, // verbatim (a link stores an object key, preserved)
        .blob => try blob.copyInto(src, dst, src_raw),
        .list => blk: {
            var newc = try Column.create(dst);
            const n = try Column.len(src, src_raw);
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const el = try Column.get(src, src_raw, i);
                const dv = if (elem == .blob) try blob.copyInto(src, dst, el) else el;
                newc = try Column.append(dst, newc, dv);
            }
            break :blk newc;
        },
        .set => switch (elem) {
            .blob => try copyBindex(src, dst, src_raw), // byte-keyed set -> bindex deep-copy
            else => blk: {
                // int-keyed set: a u64-keyed Index.
                var newi = try Index.create(dst);
                const Sink = struct {
                    idx: *Ref,
                    dstp: *WriteTxn,
                    fn onKey(self: @This(), key: u64) !void {
                        self.idx.* = try Index.insert(self.dstp, self.idx.*, key, 1);
                    }
                };
                try Index.forEachKey(src, src_raw, Sink{ .idx = &newi, .dstp = dst }, Sink.onKey);
                break :blk newi;
            },
        },
        .link_set => blk: {
            var newi = try Index.create(dst);
            const Sink = struct {
                idx: *Ref,
                dstp: *WriteTxn,
                fn onKey(self: @This(), key: u64) !void {
                    self.idx.* = try Index.insert(self.dstp, self.idx.*, key, 1);
                }
            };
            try Index.forEachKey(src, src_raw, Sink{ .idx = &newi, .dstp = dst }, Sink.onKey);
            break :blk newi;
        },
        .dict => try copyBindex(src, dst, src_raw), // byte-keyed dict -> bindex deep-copy
    };
}

// Deep-copy a bindex root (dict or byte-keyed set) from `src` into `dst` by
// iterating the source tree and re-inserting each entry. bindex.insert re-puts
// the key into the destination's blob heap, so this is a correct cross-database
// deep-copy. forEachEntry hands the callback a key slice into the SOURCE mapping;
// bindex.insert grows only the DST arena (a different mapping), so the source key
// stays valid for the duration of the insert -- keep the insert inside onEntry.
fn copyBindex(src: anytype, dst: *WriteTxn, src_root: u64) !u64 {
    var newr = try bindex.create(dst);
    const Sink = struct {
        dstp: *WriteTxn,
        root: *u64,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            self.root.* = try bindex.insert(self.dstp, self.root.*, key, val);
        }
    };
    try bindex.forEachEntry(src, src_root, Sink{ .dstp = dst, .root = &newr }, Sink.onEntry);
    return newr;
}

// Copy all live rows of `src_cat` (in the source db) into a fresh catalog in the
// destination db, preserving object keys, primary keys, and next_key. Backlink
// indexes are created empty (rebuild with rebuildBacklinks afterward). Returns
// the new destination catalog ref.
pub fn copyTypeRows(src: anytype, src_cat: Ref, dst: *WriteTxn) !Ref {
    const sv = try catalog.loadCatalog(src, src_cat);
    const pc = sv.prop_count;
    const next_key = sv.next_key;
    var s_prop: [catalog.max_prop_count]Ref = undefined;
    var kinds: [catalog.max_prop_count]catalog.PropKind = undefined;
    var elems: [catalog.max_prop_count]catalog.ElemKind = undefined;
    var targets: [catalog.max_prop_count]u16 = undefined;
    var rules: [catalog.max_prop_count]catalog.DeletionRule = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            s_prop[j] = sv.propColRef(j);
            kinds[j] = sv.kind(j);
            elems[j] = sv.elemKind(j);
            targets[j] = sv.linkTarget(j);
            rules[j] = sv.delRule(j);
        }
    }
    const s_ver = sv.version_col_ref;
    const s_live = sv.live_col_ref;
    const s_keyrow = sv.keyrow_index_ref;

    // Collect live (okey, src_row) pairs.
    const alloc = dst.db.store.allocator;
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(alloc);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), k: u64, val: u64) !void {
            try self.list.append(self.a, .{ .okey = k, .row = val });
        }
    };
    try Index.forEachEntry(src, s_keyrow, Collector{ .list = &pairs, .a = alloc }, Collector.onEntry);

    // Fresh destination structures.
    var d_prop: [catalog.max_prop_count]Ref = undefined;
    var d_bl: [catalog.max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            d_prop[j] = try Column.create(dst);
            d_bl[j] = if (kinds[j] == .link or kinds[j] == .link_set) try Index.create(dst) else 0;
        }
    }
    var d_ver = try Column.create(dst);
    var d_live = try Column.create(dst);
    var d_keyrow = try Index.create(dst);
    var d_pk = try Index.create(dst);

    var d_row: u64 = 0;
    for (pairs.items) |pr| {
        if ((try Column.get(src, s_live, pr.row)) == 0) continue; // defensive
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const sraw = try Column.get(src, s_prop[j], pr.row);
            const draw = try copyValue(src, dst, kinds[j], elems[j], sraw);
            d_prop[j] = try Column.append(dst, d_prop[j], draw);
        }
        const ver = try Column.get(src, s_ver, pr.row);
        d_ver = try Column.append(dst, d_ver, ver);
        d_live = try Column.append(dst, d_live, 1);
        d_keyrow = try Index.insert(dst, d_keyrow, pr.okey, d_row);
        const pk = try Column.get(src, s_prop[0], pr.row);
        d_pk = try Index.insert(dst, d_pk, pk, pr.okey);
        d_row += 1;
    }

    return catalog.writeCatalog(dst, pc, d_row, d_keyrow, next_key, d_pk, d_ver, d_live, d_prop[0..pc], kinds[0..pc], elems[0..pc], d_bl[0..pc], targets[0..pc], rules[0..pc]);
}

// Rebuild backlink indexes for `cat` (in dst) from its copied forward links.
pub fn rebuildBacklinks(dst: *WriteTxn, cat: Ref) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(dst, cat);
    const pc = v0.prop_count;
    const alloc = dst.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const k = (try catalog.loadCatalog(dst, cur)).kind(p);
        if (k != .link and k != .link_set) continue;
        // collect (okey,row) of cur
        var pairs = std.ArrayList(Pair).empty;
        defer pairs.deinit(alloc);
        const C = struct {
            list: *std.ArrayList(Pair),
            a: std.mem.Allocator,
            fn onEntry(self: @This(), kk: u64, vv: u64) !void {
                try self.list.append(self.a, .{ .okey = kk, .row = vv });
            }
        };
        {
            const vv = try catalog.loadCatalog(dst, cur);
            try Index.forEachEntry(dst, vv.keyrow_index_ref, C{ .list = &pairs, .a = alloc }, C.onEntry);
        }
        for (pairs.items) |pr| {
            const vv = try catalog.loadCatalog(dst, cur);
            const col = vv.propColRef(p);
            const raw = try Column.get(dst, col, pr.row);
            if (k == .link) {
                if (raw != 0) cur = try links.addBacklink(dst, cur, p, raw - 1, pr.okey);
            } else {
                // link_set: the column holds a set-root of target okeys
                var members = std.ArrayList(u64).empty;
                defer members.deinit(alloc);
                const M = struct {
                    list: *std.ArrayList(u64),
                    a: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.a, key);
                    }
                };
                try Index.forEachKey(dst, raw, M{ .list = &members, .a = alloc }, M.onKey);
                for (members.items) |t| cur = try links.addBacklink(dst, cur, p, t, pr.okey);
            }
        }
    }
    return cur;
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
    const keyrow = v.keyrow_index_ref;
    const prop0 = v.propColRef(0);
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    const C = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), k: u64, val: u64) !void {
            try self.list.append(self.a, .{ .okey = k, .row = val });
        }
    };
    try Index.forEachEntry(txn, keyrow, C{ .list = &pairs, .a = allocator }, C.onEntry);
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
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    const C = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), k: u64, val: u64) !void {
            try self.list.append(self.a, .{ .okey = k, .row = val });
        }
    };
    try Index.forEachEntry(src, sv.keyrow_index_ref, C{ .list = &pairs, .a = allocator }, C.onEntry);

    var out: [max_prop_count]catalog.Value = undefined;
    for (pairs.items) |pr| {
        // pk fold over the source.
        const pk = try Column.get(src, s_prop0, pr.row);
        fold.* ^= mixPk(pk);
        count.* += 1;

        // (a) readability: the same object key must decode in dst.
        if ((try objects.getTypedByOkey(dst, dc, pr.okey, out[0..pc])) == null) return error.CompactionMismatch;

        // (b) to-one forward links must carry the identical raw target in dst.
        const drow = (try catalog.okeyToRow(dst, dc, pr.okey)) orelse return error.CompactionMismatch;
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            if (kinds[p] != .link) continue;
            const s_raw = try Column.get(src, s_prop[p], pr.row);
            const d_raw = try Column.get(dst, d_prop[p], drow);
            if (s_raw != d_raw) return error.CompactionMismatch;
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
                defs[j] = .{ .kind = v.kind(j), .elem = v.elemKind(j), .link_target = v.linkTarget(j), .del_rule = v.delRule(j) };
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

// Delete an absolute path, treating a missing file as success. Used to remove
// coordination files during the publish step of in-place compaction. Any other
// failure is swallowed best-effort: the data file is already published by the
// atomic rename, and a leftover/stale coord is recreated fresh by Db.open
// (openOrCreate), so it cannot corrupt the published data.
fn deleteAbsoluteIgnoreMissing(io: Io, abs_path: []const u8) void {
    Io.Dir.deleteFileAbsolute(io, abs_path) catch {};
}

// Make the directory ENTRY for `path` durable by fsync'ing its parent directory.
// Uses libc fsync directly on the directory fd, which is the portable POSIX way:
// the std.Io File sync wrapper panics with BADF on a directory handle on Linux.
// Best-effort -- errors are swallowed. No-op on Windows.
fn syncParentDir(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir_path = std.fs.path.dirname(path) orelse return;
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return;
    defer dir.close(io);
    _ = std.c.fsync(dir.handle);
}

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
    deleteAbsoluteIgnoreMissing(io, path_coord); // old coord (now describes replaced data)
    deleteAbsoluteIgnoreMissing(io, tmp_coord); // compaction's coord (orphaned by the rename)

    // 4) Make the rename durable across power loss by fsync'ing the parent
    //    directory. The data file is F_FULLFSYNC'd by compactToNewFile and the
    //    rename is atomic; this dir fsync hardens the directory ENTRY itself.
    //    Restored portably via libc fsync on the directory fd (the std.Io File
    //    sync wrapper panics with BADF on a directory handle on Linux).
    //    Best-effort: a failure here cannot un-publish the already-renamed file.
    syncParentDir(path);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("db.zig").Db;
const collections = @import("collections.zig");

fn cmpTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "compactType packs live rows and drops dead ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "pack.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var pk: u64 = 0;
    while (pk < 10) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{ pk, pk * 10 });
        cat = r.cat;
    }

    for ([_]u64{ 2, 5, 8 }) |dpk| {
        var out: [2]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, dpk, &out)).?;
        cat = switch (try objects.delete(&w, cat, dpk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    cat = try compactType(&w, cat);

    try testing.expectEqual(@as(u64, 7), (try catalog.loadCatalog(&w, cat)).next_row);
    try testing.expectEqual(@as(u64, 7), try liveCount(&w, cat));

    pk = 0;
    while (pk < 10) : (pk += 1) {
        var out: [2]u64 = undefined;
        const got = try objects.getByPk(&w, cat, pk, &out);
        if (pk == 2 or pk == 5 or pk == 8) {
            try testing.expect(got == null);
        } else {
            try testing.expect(got != null);
            try testing.expectEqual(pk * 10, out[1]);
        }
    }
}

test "object keys and links survive compaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "links.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .link } });

    const a = try objects.insertTyped(&w, cat, &.{ .{ .int = 1 }, .{ .link = null } });
    cat = a.cat;
    const a_okey = a.row;
    const b = try objects.insertTyped(&w, cat, &.{ .{ .int = 2 }, .{ .link = null } });
    cat = b.cat;
    const c = try objects.insertTyped(&w, cat, &.{ .{ .int = 3 }, .{ .link = a_okey } });
    cat = c.cat;

    // delete B (pk 2) -- creates a hole
    var out: [2]u64 = undefined;
    const ver = (try objects.getByPk(&w, cat, 2, &out)).?;
    cat = switch (try objects.delete(&w, cat, 2, ver)) {
        .ok => |x| x,
        else => unreachable,
    };

    cat = try compactType(&w, cat);

    // C still links to A by object key
    try testing.expectEqual(a_okey, (try links.getLink(&w, cat, 3, 1)).?);
    // A is still resolvable by its object key
    var ao: [2]u64 = undefined;
    try testing.expect((try objects.getByObjectKey(&w, cat, a_okey, &ao)) != null);
    try testing.expectEqual(@as(u64, 1), ao[0]);
    // backlink from C -> A survived
    try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&w, cat, 1, a_okey));
}

test "shouldCompact reflects dead ratio" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "ratio.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 1);
    var pk: u64 = 0;
    while (pk < 10) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{pk});
        cat = r.cat;
    }
    try testing.expect(!(try shouldCompact(&w, cat)));

    pk = 0;
    while (pk < 6) : (pk += 1) {
        var out: [1]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, pk, &out)).?;
        cat = switch (try objects.delete(&w, cat, pk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }
    try testing.expect(try shouldCompact(&w, cat));
}

test "compaction reclaims under churn (scale)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "scale.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    const n: u64 = 200_000;
    var cat = try catalog.create(&w, 2);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const r = try objects.insert(&w, cat, &.{ i, i });
        cat = r.cat;
    }

    // delete every even pk; all rows carry version == w.new_version this txn
    i = 0;
    while (i < n) : (i += 2) {
        cat = switch (try objects.delete(&w, cat, i, w.new_version)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    cat = try compactType(&w, cat);

    try testing.expectEqual(@as(u64, 100_000), (try catalog.loadCatalog(&w, cat)).next_row);
    try testing.expectEqual(@as(u64, 100_000), try liveCount(&w, cat));

    var out: [2]u64 = undefined;
    try testing.expect((try objects.getByPk(&w, cat, 1, &out)) != null);
    try testing.expectEqual(@as(u64, 1), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 99_999, &out)) != null);
    try testing.expectEqual(@as(u64, 99_999), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 100_001, &out)) != null);
    try testing.expectEqual(@as(u64, 100_001), out[1]);
    try testing.expect((try objects.getByPk(&w, cat, 2, &out)) == null);
}

test "all value kinds deep-copy across databases preserving keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "src.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "dst.airdb");
    defer testing.allocator.free(dst_path);

    var src_db = try Db.create(testing.allocator, src_path);
    defer src_db.deinit();
    var dst_db = try Db.create(testing.allocator, dst_path);
    defer dst_db.deinit();

    var pk1_okey: u64 = undefined;
    var src_next_key: u64 = undefined;

    // Build the source database: 3 rows across every value kind, then delete one.
    {
        var w = try src_db.beginWrite();
        var cat = try catalog.createDefs(&w, &.{
            .{ .kind = .int },
            .{ .kind = .blob },
            .{ .kind = .list, .elem = .int },
            .{ .kind = .set, .elem = .int },
            .{ .kind = .link, .link_target = 0 },
        });
        const r1 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 1 }, .{ .bytes = "a" }, .{ .list_int = &.{ 10, 20 } }, .{ .set_int = &.{ 5, 6 } }, .{ .link = null },
        });
        cat = r1.cat;
        pk1_okey = r1.row;
        const r2 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 2 }, .{ .bytes = "bb" }, .{ .list_int = &.{} }, .{ .set_int = &.{7} }, .{ .link = pk1_okey },
        });
        cat = r2.cat;
        const r3 = try objects.insertTyped(&w, cat, &.{
            .{ .int = 3 }, .{ .bytes = "ccc" }, .{ .list_int = &.{ 1, 2, 3 } }, .{ .set_int = &.{} }, .{ .link = null },
        });
        cat = r3.cat;

        // Delete pk 3 -- leaves a gap in the source.
        var dout: [5]catalog.Value = undefined;
        const v3 = (try objects.getTyped(&w, cat, 3, &dout)).?;
        cat = (try objects.deleteTyped(&w, cat, 3, v3)).ok;

        src_next_key = (try catalog.loadCatalog(&w, cat)).next_key;
        w.setRoot(cat);
        _ = try w.commit();
    }

    // Deep-copy the live rows into the destination database.
    {
        var src_read = try src_db.beginRead();
        const src_cat = src_read.root();
        var dst_w = try dst_db.beginWrite();
        var dst_cat = try copyTypeRows(&src_read, src_cat, &dst_w);
        dst_cat = try rebuildBacklinks(&dst_w, dst_cat);
        dst_w.setRoot(dst_cat);
        _ = try dst_w.commit();
        src_read.end();
    }

    // Reopen the destination and verify every value kind round-tripped.
    {
        var ddb = try Db.open(testing.allocator, dst_path);
        defer ddb.deinit();
        var r = try ddb.beginRead();
        defer r.end();
        const cat = r.root();

        // pk 1 and pk 2 readable with identical int + blob.
        var o1: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 1, &o1)) != null);
        try testing.expectEqual(@as(u64, 1), o1[0].int);
        try testing.expectEqualStrings("a", o1[1].bytes);
        var o2: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 2, &o2)) != null);
        try testing.expectEqual(@as(u64, 2), o2[0].int);
        try testing.expectEqualStrings("bb", o2[1].bytes);

        // list/set contents match.
        try testing.expectEqual(@as(?u64, 2), try collections.listLen(&r, cat, 1, 2));
        try testing.expectEqual(@as(u64, 10), try collections.listGetInt(&r, cat, 1, 2, 0));
        try testing.expectEqual(@as(u64, 20), try collections.listGetInt(&r, cat, 1, 2, 1));
        try testing.expectEqual(@as(?u64, 2), try collections.setCountInt(&r, cat, 1, 3));
        try testing.expect(try collections.setContainsInt(&r, cat, 1, 3, 5));
        try testing.expect(try collections.setContainsInt(&r, cat, 1, 3, 6));
        try testing.expectEqual(@as(?u64, 0), try collections.listLen(&r, cat, 2, 2));
        try testing.expectEqual(@as(?u64, 1), try collections.setCountInt(&r, cat, 2, 3));
        try testing.expect(try collections.setContainsInt(&r, cat, 2, 3, 7));

        // The link on pk 2 still equals pk 1's original object key and resolves to pk 1.
        try testing.expectEqual(@as(?u64, pk1_okey), try links.getLink(&r, cat, 2, 4));
        var ob: [5]u64 = undefined;
        try testing.expect((try objects.getByObjectKey(&r, cat, pk1_okey, &ob)) != null);
        try testing.expectEqual(@as(u64, 1), ob[0]);

        // Backlink rebuilt from the copied forward link.
        try testing.expectEqual(@as(u64, 1), try links.backlinkCount(&r, cat, 4, pk1_okey));

        // pk 3 was dead in the source and must be absent.
        var o3: [5]catalog.Value = undefined;
        try testing.expect((try objects.getTyped(&r, cat, 3, &o3)) == null);

        // next_key preserved across the copy.
        try testing.expectEqual(src_next_key, (try catalog.loadCatalog(&r, cat)).next_key);
    }
}

test "compactToNewFile produces a verified, smaller, equivalent file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "fullsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "fulldst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropDef;
    var author_okeys: [300]u64 = undefined;

    // Build the source: two types, ~300 authors + ~300 books, delete ~100 books.
    {
        var db = try Db.create(testing.allocator, src_path);
        defer db.deinit();
        var w = try db.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author{int pk, blob name}
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 }, .{ .kind = .set, .elem = .int } }, // 1: Book{int pk, link author, set tags}
        };
        var dir = try typedir.createTypes(&w, &schema, &.{ false, false });

        var i: u64 = 0;
        var nbuf: [32]u8 = undefined;
        while (i < 300) : (i += 1) {
            const s = try std.fmt.bufPrint(&nbuf, "author-{d}", .{i});
            const r = try typedir.insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } });
            dir = r.dir;
            author_okeys[@intCast(i)] = r.row;
        }
        i = 0;
        while (i < 300) : (i += 1) {
            const a_okey = author_okeys[@intCast(i % 300)];
            const r = try typedir.insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = a_okey }, .{ .set_int = &.{ i, i + 1000 } } });
            dir = r.dir;
        }
        // Delete every third book (~100): pks 0,3,...,297.
        i = 0;
        while (i < 300) : (i += 3) {
            var out: [3]catalog.Value = undefined;
            const ver = (try typedir.get(&w, dir, 1, i, &out)).?;
            const dres = try typedir.deleteNullifyX(&w, dir, 1, i, ver);
            dir = dres.ok;
        }
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction (opens src, writes + verifies + commits dst).
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // The fresh file holds no garbage, so its live data footprint must be smaller
    // than the churned source's. Compare logical size (high-water of live bytes),
    // since the physical file length floors at the 1MB initial mmap for both.
    var src_size: u64 = undefined;
    var dst_size: u64 = undefined;
    {
        var sdb = try Db.open(testing.allocator, src_path);
        src_size = sdb.arena.top;
        sdb.deinit();
        var ddb = try Db.open(testing.allocator, dst_path);
        dst_size = ddb.arena.top;
        ddb.deinit();
    }
    try testing.expect(dst_size < src_size);

    // The destination is published; verify equivalence on the live data.
    var ddb = try Db.open(testing.allocator, dst_path);
    defer ddb.deinit();
    var r = try ddb.beginRead();
    defer r.end();
    const dir = r.root();

    try testing.expectEqual(@as(u64, 300), try typedir.liveCount(&r, dir, 0));
    try testing.expectEqual(@as(u64, 200), try typedir.liveCount(&r, dir, 1));

    // A surviving author reads back with identical values.
    var ao: [2]catalog.Value = undefined;
    _ = (try typedir.get(&r, dir, 0, 42, &ao)).?;
    try testing.expectEqual(@as(u64, 42), ao[0].int);
    try testing.expectEqualStrings("author-42", ao[1].bytes);

    // A surviving book (pk 1, not divisible by 3) keeps its author link, and the
    // link resolves to the same author object.
    var bo: [3]catalog.Value = undefined;
    _ = (try typedir.get(&r, dir, 1, 1, &bo)).?;
    try testing.expectEqual(@as(?u64, author_okeys[1]), try typedir.getLink(&r, dir, 1, 1, 1));
    var la: [2]catalog.Value = undefined;
    _ = (try typedir.getLinked(&r, dir, 1, 1, 1, &la)).?;
    try testing.expectEqual(@as(u64, 1), la[0].int);

    // A deleted book (pk 3) is absent.
    var b3: [3]catalog.Value = undefined;
    try testing.expectEqual(@as(?u64, null), try typedir.get(&r, dir, 1, 3, &b3));
}

test "compaction preserves dict and set-of-blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "bindexsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "bindexdst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropDef;

    // Build the source: a type with {int pk, dict, set(elem=blob)}, two rows with
    // dict entries + blob-set members, then delete one row to leave a gap.
    {
        var db = try Db.create(testing.allocator, src_path);
        defer db.deinit();
        var w = try db.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .dict }, .{ .kind = .set, .elem = .blob } },
        };
        var dir = try typedir.createTypes(&w, &schema, &.{false});

        const r1 = try typedir.insert(&w, dir, 0, &.{
            .{ .int = 1 },
            .{ .dict_int = &.{ .{ .key = "a", .val = 1 }, .{ .key = "b", .val = 2 } } },
            .{ .set_blob = &.{ "x", "yy" } },
        });
        dir = r1.dir;
        const r2 = try typedir.insert(&w, dir, 0, &.{
            .{ .int = 2 },
            .{ .dict_int = &.{.{ .key = "c", .val = 3 }} },
            .{ .set_blob = &.{"zzz"} },
        });
        dir = r2.dir;

        // Delete pk 2 -- leaves a gap in the source.
        var out: [3]catalog.Value = undefined;
        const ver = (try typedir.get(&w, dir, 0, 2, &out)).?;
        const dres = try typedir.deleteNullifyX(&w, dir, 0, 2, ver);
        dir = dres.ok;

        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction: opens src, deep-copies live rows, verifies, commits dst.
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // Reopen the destination and verify the surviving row's dict + blob-set survived.
    {
        var ddb = try Db.open(testing.allocator, dst_path);
        defer ddb.deinit();
        var r = try ddb.beginRead();
        defer r.end();
        const dir = r.root();
        const cat = try typedir.catalogRef(&r, dir, 0);

        try testing.expectEqual(@as(u64, 1), try typedir.liveCount(&r, dir, 0));

        // Surviving row pk 1: dict entries preserved.
        try testing.expectEqual(@as(?u64, 2), try collections.dictCount(&r, cat, 1, 1));
        try testing.expectEqual(@as(?u64, 1), try collections.dictGet(&r, cat, 1, 1, "a"));
        try testing.expectEqual(@as(?u64, 2), try collections.dictGet(&r, cat, 1, 1, "b"));
        try testing.expectEqual(@as(?u64, null), try collections.dictGet(&r, cat, 1, 1, "c"));

        // Surviving row pk 1: blob-set members preserved.
        try testing.expectEqual(@as(?u64, 2), try collections.setCountBlob(&r, cat, 1, 2));
        try testing.expect(try collections.setContainsBlob(&r, cat, 1, 2, "x"));
        try testing.expect(try collections.setContainsBlob(&r, cat, 1, 2, "yy"));
        try testing.expect(!(try collections.setContainsBlob(&r, cat, 1, 2, "zzz")));

        // Deleted row pk 2 is absent.
        var o2: [3]catalog.Value = undefined;
        try testing.expectEqual(@as(?u64, null), try typedir.get(&r, dir, 0, 2, &o2));
    }
}

test "compaction preserves a large (chunked) blob" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src_path = try cmpTmpPath(testing.allocator, &tmp, "bigblobsrc.airdb");
    defer testing.allocator.free(src_path);
    const dst_path = try cmpTmpPath(testing.allocator, &tmp, "bigblobdst.airdb");
    defer testing.allocator.free(dst_path);

    const PD = catalog.PropDef;

    // A blob well past the inline cap (section_size is 16 MiB) is stored chunked.
    const n: usize = 20 * 1024 * 1024;
    const big = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 251);

    // Build the source: a type {int pk, blob}, one large blob and one small.
    {
        var db = try Db.create(testing.allocator, src_path);
        defer db.deinit();
        var w = try db.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } },
        };
        var dir = try typedir.createTypes(&w, &schema, &.{false});
        dir = (try typedir.insert(&w, dir, 0, &.{ .{ .int = 1 }, .{ .bytes = big } })).dir;
        dir = (try typedir.insert(&w, dir, 0, &.{ .{ .int = 2 }, .{ .bytes = "small" } })).dir;
        w.setRoot(dir);
        _ = try w.commit();
    }

    // Full-file compaction: deep-copies live rows (incl. the chunked blob), verifies, commits.
    try compactToNewFile(testing.allocator, src_path, dst_path);

    // Reopen the destination and verify both blobs survived.
    {
        var ddb = try Db.open(testing.allocator, dst_path);
        defer ddb.deinit();
        var r = try ddb.beginRead();
        defer r.end();
        const dir = r.root();

        // The large blob materializes byte-identical via its ref.
        var o1: [2]catalog.Value = undefined;
        try testing.expect((try typedir.get(&r, dir, 0, 1, &o1)) != null);
        try testing.expect(o1[1] == .blob_ref);
        const got = try blob.getAlloc(&r, o1[1].blob_ref, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, big, got);

        // The small blob still reads via a zero-copy slice.
        var o2: [2]catalog.Value = undefined;
        try testing.expect((try typedir.get(&r, dir, 0, 2, &o2)) != null);
        try testing.expect(o2[1] == .bytes);
        try testing.expectEqualStrings("small", o2[1].bytes);
    }
}

test "compactStep packs a delete-heavy type across several small steps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step1.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var okeys: [12]u64 = undefined;
    var pk: u64 = 0;
    while (pk < 12) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{ pk, pk * 100 });
        cat = r.cat;
        okeys[@intCast(pk)] = r.row;
    }

    const dels = [_]u64{ 0, 2, 3, 5, 7, 8, 11 };
    for (dels) |dpk| {
        var out: [2]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, dpk, &out)).?;
        cat = switch (try objects.delete(&w, cat, dpk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    // Pack in small budgeted steps until done.
    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&w, cat, 2);
        cat = res.cat;
        try testing.expect(res.moved <= 2);
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    // Fully packed: next_row == live count.
    try testing.expectEqual(try liveCount(&w, cat), (try catalog.loadCatalog(&w, cat)).next_row);

    // Every survivor reads back its exact values; deleted keys are gone.
    pk = 0;
    while (pk < 12) : (pk += 1) {
        const is_del = blk: {
            for (dels) |d| if (d == pk) break :blk true;
            break :blk false;
        };
        var out: [2]catalog.Value = undefined;
        const got = try objects.getTypedByOkey(&w, cat, okeys[@intCast(pk)], &out);
        if (is_del) {
            try testing.expect(got == null);
        } else {
            try testing.expect(got != null);
            try testing.expectEqual(pk, out[0].int);
            try testing.expectEqual(pk * 100, out[1].int);
        }
    }
}

test "compactStep on an all-dead type truncates to zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step2.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var pk: u64 = 0;
    while (pk < 6) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{ pk, pk });
        cat = r.cat;
    }
    pk = 0;
    while (pk < 6) : (pk += 1) {
        var out: [2]u64 = undefined;
        const ver = (try objects.getByPk(&w, cat, pk, &out)).?;
        cat = switch (try objects.delete(&w, cat, pk, ver)) {
            .ok => |c| c,
            else => unreachable,
        };
    }

    var guard: usize = 0;
    while (true) {
        const res = try compactStep(&w, cat, 2);
        cat = res.cat;
        if (res.done) break;
        guard += 1;
        try testing.expect(guard < 100);
    }

    try testing.expectEqual(@as(u64, 0), (try catalog.loadCatalog(&w, cat)).next_row);
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, cat));
}

test "compactStep is a no-op on an already-packed type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "step3.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();

    var cat = try catalog.create(&w, 2);
    var okeys: [5]u64 = undefined;
    var pk: u64 = 0;
    while (pk < 5) : (pk += 1) {
        const r = try objects.insert(&w, cat, &.{ pk, pk * 7 });
        cat = r.cat;
        okeys[@intCast(pk)] = r.row;
    }

    const res = try compactStep(&w, cat, 4);
    cat = res.cat;
    try testing.expect(res.done);
    try testing.expectEqual(@as(usize, 0), res.moved);

    pk = 0;
    while (pk < 5) : (pk += 1) {
        var out: [2]catalog.Value = undefined;
        const got = try objects.getTypedByOkey(&w, cat, okeys[@intCast(pk)], &out);
        try testing.expect(got != null);
        try testing.expectEqual(pk, out[0].int);
        try testing.expectEqual(pk * 7, out[1].int);
    }
}

// NOTE: link/backlink survival across a relocation is covered directly by
// relocation.zig's tests ("a same-type link to a relocated object still
// resolves"); compactStep only sequences relocateRow calls, so wiring links
// into these tests would duplicate that coverage without exercising new paths.

test "compactInPlace shrinks and preserves data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try cmpTmpPath(testing.allocator, &tmp, "inplace.airdb");
    defer testing.allocator.free(path);

    const PD = catalog.PropDef;

    // Build a churned database (two types) at `path`, then CLOSE it so no handle
    // remains while compactInPlace replaces the file. Capture the logical size
    // (arena high-water) before closing to compare against the compacted file.
    var pre_top: u64 = undefined;
    var author_okeys: [200]u64 = undefined;
    {
        var db = try Db.create(testing.allocator, path);
        var w = try db.beginWrite();
        const schema = [_][]const PD{
            &.{ .{ .kind = .int }, .{ .kind = .blob } }, // 0: Author{int pk, blob name}
            &.{ .{ .kind = .int }, .{ .kind = .link, .link_target = 0 } }, // 1: Book{int pk, link author}
        };
        var dir = try typedir.createTypes(&w, &schema, &.{ false, false });

        var i: u64 = 0;
        var nbuf: [32]u8 = undefined;
        while (i < 200) : (i += 1) {
            const s = try std.fmt.bufPrint(&nbuf, "author-{d}", .{i});
            const r = try typedir.insert(&w, dir, 0, &.{ .{ .int = i }, .{ .bytes = s } });
            dir = r.dir;
            author_okeys[@intCast(i)] = r.row;
        }
        i = 0;
        while (i < 200) : (i += 1) {
            const r = try typedir.insert(&w, dir, 1, &.{ .{ .int = i }, .{ .link = author_okeys[@intCast(i)] } });
            dir = r.dir;
        }
        // Churn: delete every even-pk book (~100 holes).
        i = 0;
        while (i < 200) : (i += 2) {
            var out: [2]catalog.Value = undefined;
            const ver = (try typedir.get(&w, dir, 1, i, &out)).?;
            const dres = try typedir.deleteNullifyX(&w, dir, 1, i, ver);
            dir = dres.ok;
        }
        w.setRoot(dir);
        _ = try w.commit();

        pre_top = db.arena.top;
        db.deinit();
    }

    // Compact in place over the SAME path.
    try compactInPlace(testing.allocator, path);

    // The ".compacting" temp data file must have been renamed away.
    {
        const temp_data = try std.fmt.allocPrint(testing.allocator, "{s}.compacting", .{path});
        defer testing.allocator.free(temp_data);
        const io = std.Io.Threaded.global_single_threaded.io();
        try testing.expectError(error.FileNotFound, Io.Dir.openFileAbsolute(io, temp_data, .{}));
    }

    // Reopen the SAME path and verify the live data survived intact.
    var db = try Db.open(testing.allocator, path);
    defer db.deinit();

    // The compacted file's logical footprint must not exceed the churned source's.
    try testing.expect(db.arena.top <= pre_top);

    var r = try db.beginRead();
    defer r.end();
    const dir = r.root();

    // All 200 authors survive; only the 100 odd-pk books remain.
    try testing.expectEqual(@as(u64, 200), try typedir.liveCount(&r, dir, 0));
    try testing.expectEqual(@as(u64, 100), try typedir.liveCount(&r, dir, 1));

    // A surviving author reads back identically.
    var ao: [2]catalog.Value = undefined;
    _ = (try typedir.get(&r, dir, 0, 137, &ao)).?;
    try testing.expectEqual(@as(u64, 137), ao[0].int);
    try testing.expectEqualStrings("author-137", ao[1].bytes);

    // A surviving (odd-pk) book keeps its author link, resolving to the same author.
    var bo: [2]catalog.Value = undefined;
    _ = (try typedir.get(&r, dir, 1, 137, &bo)).?;
    try testing.expectEqual(@as(?u64, author_okeys[137]), try typedir.getLink(&r, dir, 1, 137, 1));
    var la: [2]catalog.Value = undefined;
    _ = (try typedir.getLinked(&r, dir, 1, 137, 1, &la)).?;
    try testing.expectEqual(@as(u64, 137), la[0].int);

    // A deleted (even-pk) book is absent.
    var b2: [2]catalog.Value = undefined;
    try testing.expectEqual(@as(?u64, null), try typedir.get(&r, dir, 1, 42, &b2));
}
