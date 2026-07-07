// compactionCopy.zig -- deep-copying live rows and values between databases.
//
// This is the per-value/per-row copy machinery behind full-file compaction
// (compaction.compactToNewFile): copying a single property value across
// databases (including blobs, lists, sets, dicts, and link sets), copying all
// live rows of one type into a fresh destination catalog, and rebuilding the
// destination's backlink indexes from its copied forward links.

const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");
const blob = @import("../records/blob.zig");
const links = @import("../records/links.zig");
const bindex = @import("../trees/byteKeyIndex.zig");

/// One key->row index entry: a stable object key and its physical row.
pub const Pair = struct { objectKey: u64, row: u64 };

/// Collect every (objectKey, row) entry of the key->row index rooted at
/// `keyrow_ref` into a list the caller owns. O(live rows).
pub fn collectKeyRowPairs(
    allocator: std.mem.Allocator,
    transaction: anytype,
    keyrow_ref: Reference,
) !std.ArrayList(Pair) {
    var pairs = std.ArrayList(Pair).empty;
    errdefer pairs.deinit(allocator);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        a: std.mem.Allocator,
        fn onEntry(self: @This(), key: u64, val: u64) !void {
            try self.list.append(self.a, .{ .objectKey = key, .row = val });
        }
    };
    try Index.forEachEntry(transaction, keyrow_ref, Collector{ .list = &pairs, .a = allocator }, Collector.onEntry);
    return pairs;
}

// Deep-copy a single property value from the source database into the destination database.
// kind/elem describe the property. Returns the destination-local raw u64.
fn copyValue(src: anytype, dst: *WriteTransaction, kind: catalog.PropertyKind, elem: catalog.ElemKind, src_raw: u64) !u64 {
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
fn copyKeySet(src: anytype, dst: *WriteTransaction, src_root: u64) !u64 {
    var newi = try Index.create(dst);
    const Sink = struct {
        idx: *Reference,
        dstp: *WriteTransaction,
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
fn copyBindex(src: anytype, dst: *WriteTransaction, src_root: u64) !u64 {
    var newr = try bindex.create(dst);
    const Sink = struct {
        dstp: *WriteTransaction,
        root: *u64,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            self.root.* = try bindex.insert(self.dstp, self.root.*, key, val);
        }
    };
    try bindex.forEachEntry(src, src_root, Sink{ .dstp = dst, .root = &newr }, Sink.onEntry);
    return newr;
}

// Add objectKey under `value` in a value index (value -> {objectKey -> 1}), mirroring the
// shape the object layer's maintenance keeps. Local to the copy path, which
// must rebuild value indexes in the destination database.
fn viAddInto(dst: *WriteTransaction, valueIndexRef: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(dst, valueIndexRef, value);
    var set_root = existing orelse try Index.create(dst);
    set_root = try Index.insert(dst, set_root, objectKey, 1);
    return try Index.insert(dst, valueIndexRef, value, set_root);
}

// Re-point every ref field of the snapshot at fresh structures created in the
// DESTINATION database. Backlink and value indexes are created empty in the
// destination (the source refs live in the source database's address space) and
// repopulated separately; the indexed flag carries through.
fn createDestinationStructures(dst: *WriteTransaction, s: *catalog.CatalogSnapshot) !void {
    var j: usize = 0;
    while (j < s.propertyCount) : (j += 1) {
        s.properties[j].col = try Column.create(dst);
        s.properties[j].backlink = if (s.properties[j].kind == .link or s.properties[j].kind == .link_set) try Index.create(dst) else 0;
        s.properties[j].value_index = if (s.properties[j].indexed) try Index.create(dst) else 0;
    }
    s.version_col_ref = try Column.create(dst);
    s.live_col_ref = try Column.create(dst);
    s.keyrow_index_ref = try Index.create(dst);
    s.primaryKeyIndexRef = try Index.create(dst);
}

/// Copy all live rows of `sourceCatalog` (in the source database) into a fresh catalog in the
/// destination database, preserving object keys, primary keys, and next_key. Backlink
/// indexes are created empty (rebuild with rebuildBacklinks afterward); value
/// indexes are repopulated inline. Returns the new destination catalog ref.
/// O(live rows x properties), plus the deep copies' own costs.
pub fn copyTypeRows(src: anytype, sourceCatalog: Reference, dst: *WriteTransaction) !Reference {
    // Load the source snapshot, then re-point every ref field at structures
    // created in the DESTINATION database before writing. Kinds, elem kinds, targets,
    // rules, and indexed flags carry over as plain values.
    var s = try catalog.CatalogSnapshot.load(src, sourceCatalog);
    const propertyCount = s.propertyCount;
    // Keep the source refs to read from.
    var sourcePropertyColumns: [catalog.maxPropertyCount]Reference = undefined;
    {
        var j: usize = 0;
        while (j < propertyCount) : (j += 1) sourcePropertyColumns[j] = s.properties[j].col;
    }
    const s_ver = s.version_col_ref;
    const s_live = s.live_col_ref;
    const s_keyrow = s.keyrow_index_ref;

    // Collect live (objectKey, src_row) pairs, then re-point at fresh dst structures.
    const alloc = dst.database.store.allocator;
    var pairs = try collectKeyRowPairs(alloc, src, s_keyrow);
    defer pairs.deinit(alloc);
    try createDestinationStructures(dst, &s);

    var d_row: u64 = 0;
    for (pairs.items) |pr| {
        if ((try Column.get(src, s_live, pr.row)) == 0) continue; // defensive
        var j: usize = 0;
        while (j < propertyCount) : (j += 1) {
            const sraw = try Column.get(src, sourcePropertyColumns[j], pr.row);
            const draw = try copyValue(src, dst, s.properties[j].kind, s.properties[j].elem, sraw);
            s.properties[j].col = try Column.append(dst, s.properties[j].col, draw);
            // Repopulate the destination value index in the same pass. Leaving
            // it empty while the catalog still says indexed=true silently
            // empties every indexed query after a full-file compaction (the
            // planner trusts the flag) and fails the value-index audit.
            if (s.properties[j].indexed) {
                s.properties[j].value_index = try viAddInto(dst, s.properties[j].value_index, draw, pr.objectKey);
            }
        }
        const ver = try Column.get(src, s_ver, pr.row);
        s.version_col_ref = try Column.append(dst, s.version_col_ref, ver);
        s.live_col_ref = try Column.append(dst, s.live_col_ref, 1);
        s.keyrow_index_ref = try Index.insert(dst, s.keyrow_index_ref, pr.objectKey, d_row);
        const primaryKey = try Column.get(src, sourcePropertyColumns[0], pr.row);
        s.primaryKeyIndexRef = try Index.insert(dst, s.primaryKeyIndexRef, primaryKey, pr.objectKey);
        d_row += 1;
    }

    s.next_row = d_row;
    return s.write(dst);
}

/// Rebuild backlink indexes for `catalogRef` (in dst) from its copied forward links.
/// O(live rows x link properties x link fan-out).
pub fn rebuildBacklinks(dst: *WriteTransaction, catalogRef: Reference) !Reference {
    var cur = catalogRef;
    const v0 = try catalog.loadCatalog(dst, catalogRef);
    const propertyCount = v0.propertyCount;
    const alloc = dst.database.store.allocator;
    var p: usize = 0;
    while (p < propertyCount) : (p += 1) {
        const k = (try catalog.loadCatalog(dst, cur)).kind(p);
        if (k != .link and k != .link_set) continue;
        // collect (objectKey,row) of cur
        var pairs = blk: {
            const vv = try catalog.loadCatalog(dst, cur);
            break :blk try collectKeyRowPairs(alloc, dst, vv.keyrow_index_ref);
        };
        defer pairs.deinit(alloc);
        for (pairs.items) |pr| {
            const vv = try catalog.loadCatalog(dst, cur);
            const col = vv.propertyColumnRef(p);
            const raw = try Column.get(dst, col, pr.row);
            if (k == .link) {
                if (raw != 0) cur = try links.addBacklink(dst, cur, p, raw - 1, pr.objectKey);
            } else {
                // link_set: the column holds a set-root of target objectKeys
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
                for (members.items) |t| cur = try links.addBacklink(dst, cur, p, t, pr.objectKey);
            }
        }
    }
    return cur;
}
