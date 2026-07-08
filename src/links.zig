const std = @import("std");
const WriteTxn = @import("write_txn.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

// ---------------------------------------------------------------------------
// Links and backlinks
//
// A `link` property stores `target_okey + 1` in its column (0 = null). For each
// link property the catalog holds a backlink index: target_okey -> set_root,
// where set_root is an index of source_okey -> 1. The backlink index is updated
// transactionally on every insert, set, clear, and delete.
// ---------------------------------------------------------------------------

// Add `source` to the backlink set for `target`, returning the new backlink ref.
fn blAdd(txn: *WriteTxn, bl_ref: Ref, target: u64, source: u64) !Ref {
    const existing = try Index.get(txn, bl_ref, target);
    var set_root = existing orelse try Index.create(txn);
    set_root = try Index.insert(txn, set_root, source, 1);
    return try Index.insert(txn, bl_ref, target, set_root);
}

// Remove `source` from the backlink set for `target`. No-op if absent.
// When the set empties, its outer entry is removed and the set's nodes freed,
// mirroring viRemove: link churn must not accumulate empty sets forever.
fn blRemove(txn: *WriteTxn, bl_ref: Ref, target: u64, source: u64) !Ref {
    const existing = try Index.get(txn, bl_ref, target);
    const set_root = existing orelse return bl_ref;
    const new_set = try Index.remove(txn, set_root, source);
    if ((try Index.count(txn, new_set)) == 0) {
        const new_bl = try Index.remove(txn, bl_ref, target);
        try Index.freeTree(txn, new_set);
        return new_bl;
    }
    return try Index.insert(txn, bl_ref, target, new_set);
}

// Add source->target to link property p's backlink index. Returns new catalog.
pub fn addBacklink(txn: *WriteTxn, cat: Ref, p: usize, target: u64, source: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const new_bl = try blAdd(txn, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(txn, cat, p, new_bl);
}

// Remove source from link property p's backlink set for target.
pub fn removeBacklink(txn: *WriteTxn, cat: Ref, p: usize, target: u64, source: u64) !Ref {
    const v = try catalog.loadCatalog(txn, cat);
    const new_bl = try blRemove(txn, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(txn, cat, p, new_bl);
}

// Read the target okey of link property `prop` for the object with primary key
// `pk`. Returns null if the link is unset (or the object is absent).
pub fn getLink(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const raw = try Column.get(txn, r.prop_col, r.row);
    return if (raw == 0) null else raw - 1;
}

// Number of objects whose link property `prop` points at `target` okey.
pub fn backlinkCount(txn: anytype, cat: Ref, prop: usize, target: u64) !u64 {
    const v = try catalog.loadCatalog(txn, cat);
    const set_root = (try Index.get(txn, v.backlinkRef(prop), target)) orelse return 0;
    return try Index.count(txn, set_root);
}

// True when `source` is recorded in link property `prop`'s backlink set for
// `target`.
pub fn backlinkContains(txn: anytype, cat: Ref, prop: usize, target: u64, source: u64) !bool {
    const v = try catalog.loadCatalog(txn, cat);
    const set_root = (try Index.get(txn, v.backlinkRef(prop), target)) orelse return false;
    return (try Index.get(txn, set_root, source)) != null;
}

// Collect the source okeys whose link property `prop` points at `target`.
pub fn backlinkCollect(
    txn: anytype,
    cat: Ref,
    prop: usize,
    target: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const v = try catalog.loadCatalog(txn, cat);
    const set_root = (try Index.get(txn, v.backlinkRef(prop), target)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Set or clear link property `prop` of the object with primary key `pk`.
// Maintains the backlink index and bumps the row version. No-op if unchanged.
//
// Backlink SOURCES are object keys, never physical rows: rows move under
// relocation/compaction while okeys are stable, and every backlink consumer
// (nullifyInboundInCatalog, cleanOutboundInCatalog, rebuildBacklinks) resolves
// sources through the key->row index. Recording the row here would corrupt the
// graph the moment a source row is relocated.
pub fn setLink(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: ?u64) !Ref {
    const r0 = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return cat;
    const okey = (try catalog.pkToOkey(txn, cat, pk)) orelse return cat;
    const row = r0.row;
    const old_raw = try Column.get(txn, r0.prop_col, row);
    const old_target: ?u64 = if (old_raw == 0) null else old_raw - 1;
    if (old_target == target) return cat; // unchanged

    const new_raw: u64 = if (target) |t| t + 1 else 0;
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_raw);
    if (old_target) |ot| new_cat = try removeBacklink(txn, new_cat, prop, ot, okey);
    if (target) |nt| new_cat = try addBacklink(txn, new_cat, prop, nt, okey);
    return new_cat;
}

// ---------------------------------------------------------------------------
// To-many links (link_set): a set of target okeys with backlink maintenance.
// ---------------------------------------------------------------------------

pub fn linkSetCount(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try Index.count(txn, set_root);
}

pub fn linkSetContains(txn: anytype, cat: Ref, pk: u64, prop: usize, target: u64) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try Index.get(txn, set_root, target)) != null;
}

pub fn linkSetCollect(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Add `target` to the to-many link set of object `pk`; records the backlink.
// No-op if already a member. The backlink source is the okey (see setLink).
pub fn linkSetAdd(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const okey = (try catalog.pkToOkey(txn, cat, pk)) orelse return error.NotFound;
    const row = r.row;
    const old_root = try Column.get(txn, r.prop_col, row);
    if ((try Index.get(txn, old_root, target)) != null) return cat; // already a member
    const new_root = try Index.insert(txn, old_root, target, 1);
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_root);
    new_cat = try addBacklink(txn, new_cat, prop, target, okey);
    return new_cat;
}

// Remove `target` from the to-many link set of object `pk`; drops the backlink.
// No-op if not a member. The backlink source is the okey (see setLink).
pub fn linkSetRemove(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, target: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const okey = (try catalog.pkToOkey(txn, cat, pk)) orelse return error.NotFound;
    const row = r.row;
    const old_root = try Column.get(txn, r.prop_col, row);
    if ((try Index.get(txn, old_root, target)) == null) return cat; // not a member
    const new_root = try Index.remove(txn, old_root, target);
    var new_cat = try catalog.replaceCollRoot(txn, cat, row, prop, new_root);
    new_cat = try removeBacklink(txn, new_cat, prop, target, okey);
    return new_cat;
}

// Nullify every inbound link pointing at `okey` (and drop those backlink
// entries) for each link/link_set property, restricted to properties where
// `match_all` is true OR the property's link target type equals `target_type`.
// Returns the new catalog ref.
pub fn nullifyInboundInCatalog(txn: *WriteTxn, cat: Ref, okey: u64, target_type: u16, match_all: bool) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(txn, cat);
    const pc = v0.prop_count;
    const alloc = txn.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(txn, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;
        if (!match_all) {
            const vt = try catalog.loadCatalog(txn, cur);
            if (vt.linkTarget(p) != target_type) continue;
        }

        // Nullify inbound: snapshot the sources, then clear each one's link to
        // okey. For to-one, set the column to null; for to-many, remove okey
        // from the source's set.
        var sources = std.ArrayList(u64).empty;
        defer sources.deinit(alloc);
        try backlinkCollect(txn, cur, p, okey, &sources, alloc);
        for (sources.items) |src| {
            // src is a source object key; resolve to its physical row for column
            // access. A backlink entry whose source no longer resolves is stale
            // (corrupt or already deleted); skip it -- the whole set for okey is
            // dropped below regardless.
            const src_row = (try catalog.okeyToRow(txn, cur, src)) orelse continue;
            // match_all means this catalog is the target's own type, so
            // src == okey is the row being deleted referencing itself.
            const self_source = match_all and src == okey;
            // A self-sourced to-many entry is left untouched: the dying row's
            // set tree is freed wholesale from its column raw by the delete's
            // storage reclamation, and Index.remove COWs -- freeing the old
            // root -- so mutating it here made that reclamation a double free.
            // The backlink set for okey is dropped below regardless.
            if (self_source and kind == .link_set) continue;
            var s = try catalog.CatalogSnapshot.load(txn, cur);
            if (kind == .link) {
                s.props[p].col = try Column.set(txn, s.props[p].col, src_row, 0);
            } else {
                const src_set = try Column.get(txn, s.props[p].col, src_row);
                const new_set = try Index.remove(txn, src_set, okey);
                s.props[p].col = try Column.set(txn, s.props[p].col, src_row, new_set);
            }
            // Bump the source row's version: its link column changed, and a
            // client holding the pre-nullify version must get a conflict on
            // update rather than silently resurrecting a dangling link. The
            // SELF-link case is exempt: bumping the row being deleted would
            // make the follow-up tombstone's version check fail forever,
            // leaving self-linked objects undeletable.
            if (!self_source) {
                s.version_col_ref = try Column.set(txn, s.version_col_ref, src_row, txn.new_version);
            }
            cur = try s.replace(txn);
        }
        // Drop the whole backlink set for okey (its inbound links are now
        // clear): remove the outer entry and free the set's nodes, rather than
        // inserting a fresh empty set and orphaning the old tree.
        {
            const vv = try catalog.loadCatalog(txn, cur);
            if (try Index.get(txn, vv.backlinkRef(p), okey)) |set_root| {
                const new_bl = try Index.remove(txn, vv.backlinkRef(p), okey);
                try Index.freeTree(txn, set_root);
                cur = try catalog.setBacklinkRef(txn, cur, p, new_bl);
            }
        }
    }
    return cur;
}

// Remove `okey`'s own outbound link entries from its targets' backlink sets for
// each link/link_set property. Returns the new catalog ref.
pub fn cleanOutboundInCatalog(txn: *WriteTxn, cat: Ref, okey: u64) !Ref {
    var cur = cat;
    const v0 = try catalog.loadCatalog(txn, cat);
    const pc = v0.prop_count;
    const alloc = txn.db.store.allocator;
    var p: usize = 0;
    while (p < pc) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(txn, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;

        // Outbound: remove okey's own entries from its targets' backlink sets.
        // okey is an object key; resolve to the physical row to read its columns.
        // An unresolvable okey has no readable outbound links to clean.
        const row = (try catalog.okeyToRow(txn, cur, okey)) orelse return cur;
        if (kind == .link) {
            const vv2 = try catalog.loadCatalog(txn, cur);
            const out_raw = try Column.get(txn, vv2.propColRef(p), row);
            if (out_raw != 0) cur = try removeBacklink(txn, cur, p, out_raw - 1, okey);
        } else {
            // to-many: iterate the deleted row's set members.
            var members = std.ArrayList(u64).empty;
            defer members.deinit(alloc);
            {
                const vv2 = try catalog.loadCatalog(txn, cur);
                const set_root = try Column.get(txn, vv2.propColRef(p), row);
                const Sink = struct {
                    list: *std.ArrayList(u64),
                    alloc: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.alloc, key);
                    }
                };
                try Index.forEachKey(txn, set_root, Sink{ .list = &members, .alloc = alloc }, Sink.onKey);
            }
            for (members.items) |m| cur = try removeBacklink(txn, cur, p, m, okey);
        }
    }
    return cur;
}

// For each link property: (1) nullify every inbound link pointing at `okey`
// (and drop those backlink entries); (2) remove the deleted row's own outbound
// link entry from its target's backlink set. Returns the new catalog ref.
pub fn fixBacklinksForDelete(txn: *WriteTxn, cat: Ref, okey: u64) !Ref {
    const c1 = try nullifyInboundInCatalog(txn, cat, okey, 0, true);
    return try cleanOutboundInCatalog(txn, c1, okey);
}

test {
    _ = @import("linksTests.zig");
}
