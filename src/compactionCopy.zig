// compactionCopy.zig -- deep-copying live rows and values between databases.
//
// This is the per-value/per-row copy machinery behind full-file compaction
// (compaction.compactToNewFile): copying a single property value across
// databases (including blobs, lists, sets, dicts, and link sets), copying all
// live rows of one type into a fresh destination catalog, and rebuilding the
// destination's backlink indexes from its copied forward links.

const std = @import("std");
const WriteTxn = @import("database.zig").WriteTxn;
const Ref = @import("reference.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");
const blob = @import("blob.zig");
const links = @import("links.zig");
const bindex = @import("byteKeyIndex.zig");

/// One key->row index entry: a stable object key and its physical row.
pub const Pair = struct { okey: u64, row: u64 };

/// Collect every (okey, row) entry of the key->row index rooted at
/// `keyrow_ref` into a list the caller owns. O(live rows).
pub fn collectKeyRowPairs(
    allocator: std.mem.Allocator,
    txn: anytype,
    keyrow_ref: Ref,
) !std.ArrayList(Pair) {
    var pairs = std.ArrayList(Pair).empty;
    errdefer pairs.deinit(allocator);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), key: u64, val: u64) !void {
            try self.list.append(self.a, .{ .okey = key, .row = val });
        }
    };
    try Index.forEachEntry(txn, keyrow_ref, Collector{ .list = &pairs, .a = allocator }, Collector.onEntry);
    return pairs;
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
            else => try copyKeySet(src, dst, src_raw), // int-keyed set: a u64-keyed Index
        },
        .link_set => try copyKeySet(src, dst, src_raw),
        .dict => try copyBindex(src, dst, src_raw), // byte-keyed dict -> bindex deep-copy
    };
}

// Deep-copy a u64-keyed set (Index mapping key -> 1) from `src` into `dst` by
// iterating the source keys and re-inserting each into a fresh destination set.
fn copyKeySet(src: anytype, dst: *WriteTxn, src_root: u64) !u64 {
    var newi = try Index.create(dst);
    const Sink = struct {
        idx: *Ref,
        dstp: *WriteTxn,
        fn onKey(self: @This(), key: u64) !void {
            self.idx.* = try Index.insert(self.dstp, self.idx.*, key, 1);
        }
    };
    try Index.forEachKey(src, src_root, Sink{ .idx = &newi, .dstp = dst }, Sink.onKey);
    return newi;
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

// Add okey under `value` in a value index (value -> {okey -> 1}), mirroring the
// shape the object layer's maintenance keeps. Local to the copy path, which
// must rebuild value indexes in the destination database.
fn viAddInto(dst: *WriteTxn, vi_ref: Ref, value: u64, okey: u64) !Ref {
    const existing = try Index.get(dst, vi_ref, value);
    var set_root = existing orelse try Index.create(dst);
    set_root = try Index.insert(dst, set_root, okey, 1);
    return try Index.insert(dst, vi_ref, value, set_root);
}

// Re-point every ref field of the snapshot at fresh structures created in the
// DESTINATION db. Backlink and value indexes are created empty in the
// destination (the source refs live in the source db's address space) and
// repopulated separately; the indexed flag carries through.
fn createDestinationStructures(dst: *WriteTxn, s: *catalog.CatalogSnapshot) !void {
    var j: usize = 0;
    while (j < s.prop_count) : (j += 1) {
        s.props[j].col = try Column.create(dst);
        s.props[j].backlink = if (s.props[j].kind == .link or s.props[j].kind == .link_set) try Index.create(dst) else 0;
        s.props[j].value_index = if (s.props[j].indexed) try Index.create(dst) else 0;
    }
    s.version_col_ref = try Column.create(dst);
    s.live_col_ref = try Column.create(dst);
    s.keyrow_index_ref = try Index.create(dst);
    s.pk_index_ref = try Index.create(dst);
}

/// Copy all live rows of `src_cat` (in the source db) into a fresh catalog in the
/// destination db, preserving object keys, primary keys, and next_key. Backlink
/// indexes are created empty (rebuild with rebuildBacklinks afterward); value
/// indexes are repopulated inline. Returns the new destination catalog ref.
/// O(live rows x properties), plus the deep copies' own costs.
pub fn copyTypeRows(src: anytype, src_cat: Ref, dst: *WriteTxn) !Ref {
    // Load the source snapshot, then re-point every ref field at structures
    // created in the DESTINATION db before writing. Kinds, elem kinds, targets,
    // rules, and indexed flags carry over as plain values.
    var s = try catalog.CatalogSnapshot.load(src, src_cat);
    const pc = s.prop_count;
    // Keep the source refs to read from.
    var s_prop: [catalog.max_prop_count]Ref = undefined;
    {
        var j: usize = 0;
        while (j < pc) : (j += 1) s_prop[j] = s.props[j].col;
    }
    const s_ver = s.version_col_ref;
    const s_live = s.live_col_ref;
    const s_keyrow = s.keyrow_index_ref;

    // Collect live (okey, src_row) pairs, then re-point at fresh dst structures.
    const alloc = dst.db.store.allocator;
    var pairs = try collectKeyRowPairs(alloc, src, s_keyrow);
    defer pairs.deinit(alloc);
    try createDestinationStructures(dst, &s);

    var d_row: u64 = 0;
    for (pairs.items) |pr| {
        if ((try Column.get(src, s_live, pr.row)) == 0) continue; // defensive
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const sraw = try Column.get(src, s_prop[j], pr.row);
            const draw = try copyValue(src, dst, s.props[j].kind, s.props[j].elem, sraw);
            s.props[j].col = try Column.append(dst, s.props[j].col, draw);
            // Repopulate the destination value index in the same pass. Leaving
            // it empty while the catalog still says indexed=true silently
            // empties every indexed query after a full-file compaction (the
            // planner trusts the flag) and fails the value-index audit.
            if (s.props[j].indexed) {
                s.props[j].value_index = try viAddInto(dst, s.props[j].value_index, draw, pr.okey);
            }
        }
        const ver = try Column.get(src, s_ver, pr.row);
        s.version_col_ref = try Column.append(dst, s.version_col_ref, ver);
        s.live_col_ref = try Column.append(dst, s.live_col_ref, 1);
        s.keyrow_index_ref = try Index.insert(dst, s.keyrow_index_ref, pr.okey, d_row);
        const pk = try Column.get(src, s_prop[0], pr.row);
        s.pk_index_ref = try Index.insert(dst, s.pk_index_ref, pk, pr.okey);
        d_row += 1;
    }

    s.next_row = d_row;
    return s.write(dst);
}

/// Rebuild backlink indexes for `cat` (in dst) from its copied forward links.
/// O(live rows x link properties x link fan-out).
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
        var pairs = blk: {
            const vv = try catalog.loadCatalog(dst, cur);
            break :blk try collectKeyRowPairs(alloc, dst, vv.keyrow_index_ref);
        };
        defer pairs.deinit(alloc);
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
