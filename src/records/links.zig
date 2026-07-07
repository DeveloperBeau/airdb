const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const PropertyDefinition = catalog.PropertyDefinition;
const Value = catalog.Value;
const PropertyCount = catalog.PropertyCount;
const CatalogView = catalog.CatalogView;
const maxPropertyCount = catalog.maxPropertyCount;

// ---------------------------------------------------------------------------
// Links and backlinks
//
// A `link` property stores `targetObjectKey + 1` in its column (0 = null). For each
// link property the catalog holds a backlink index: targetObjectKey -> set_root,
// where set_root is an index of sourceObjectKey -> 1. The backlink index is updated
// transactionally on every insert, set, clear, and delete.
// ---------------------------------------------------------------------------

// Add `source` to the backlink set for `target`, returning the new backlink ref.
fn blAdd(transaction: *WriteTransaction, bl_ref: Reference, target: u64, source: u64) !Reference {
    const existing = try Index.get(transaction, bl_ref, target);
    var set_root = existing orelse try Index.create(transaction);
    set_root = try Index.insert(transaction, set_root, source, 1);
    return try Index.insert(transaction, bl_ref, target, set_root);
}

// Remove `source` from the backlink set for `target`. No-op if absent.
// When the set empties, its outer entry is removed and the set's nodes freed,
// mirroring valueIndexRemove: link churn must not accumulate empty sets forever.
fn blRemove(transaction: *WriteTransaction, bl_ref: Reference, target: u64, source: u64) !Reference {
    const existing = try Index.get(transaction, bl_ref, target);
    const set_root = existing orelse return bl_ref;
    const new_set = try Index.remove(transaction, set_root, source);
    if ((try Index.count(transaction, new_set)) == 0) {
        const new_bl = try Index.remove(transaction, bl_ref, target);
        try Index.freeTree(transaction, new_set);
        return new_bl;
    }
    return try Index.insert(transaction, bl_ref, target, new_set);
}

// Add source->target to link property p's backlink index. Returns new catalog.
pub fn addBacklink(transaction: *WriteTransaction, catalogRef: Reference, p: usize, target: u64, source: u64) !Reference {
    const v = try catalog.loadCatalog(transaction, catalogRef);
    const new_bl = try blAdd(transaction, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(transaction, catalogRef, p, new_bl);
}

// Remove source from link property p's backlink set for target.
pub fn removeBacklink(transaction: *WriteTransaction, catalogRef: Reference, p: usize, target: u64, source: u64) !Reference {
    const v = try catalog.loadCatalog(transaction, catalogRef);
    const new_bl = try blRemove(transaction, v.backlinkRef(p), target, source);
    return try catalog.setBacklinkRef(transaction, catalogRef, p, new_bl);
}

// Read the target objectKey of link property `property` for the object with primary key
// `primaryKey`. Returns null if the link is unset (or the object is absent).
pub fn getLink(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const raw = try Column.get(transaction, r.propertyColumn, r.row);
    return if (raw == 0) null else raw - 1;
}

// Number of objects whose link property `property` points at `target` objectKey.
pub fn backlinkCount(transaction: anytype, catalogRef: Reference, property: usize, target: u64) !u64 {
    const v = try catalog.loadCatalog(transaction, catalogRef);
    const set_root = (try Index.get(transaction, v.backlinkRef(property), target)) orelse return 0;
    return try Index.count(transaction, set_root);
}

// True when `source` is recorded in link property `property`'s backlink set for
// `target`.
pub fn backlinkContains(transaction: anytype, catalogRef: Reference, property: usize, target: u64, source: u64) !bool {
    const v = try catalog.loadCatalog(transaction, catalogRef);
    const set_root = (try Index.get(transaction, v.backlinkRef(property), target)) orelse return false;
    return (try Index.get(transaction, set_root, source)) != null;
}

// Collect the source objectKeys whose link property `property` points at `target`.
pub fn backlinkCollect(
    transaction: anytype,
    catalogRef: Reference,
    property: usize,
    target: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const v = try catalog.loadCatalog(transaction, catalogRef);
    const set_root = (try Index.get(transaction, v.backlinkRef(property), target)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Set or clear link property `property` of the object with primary key `primaryKey`.
// Maintains the backlink index and bumps the row version. No-op if unchanged.
//
// Backlink SOURCES are object keys, never physical rows: rows move under
// relocation/compaction while objectKeys are stable, and every backlink consumer
// (nullifyInboundInCatalog, cleanOutboundInCatalog, rebuildBacklinks) resolves
// sources through the key->row index. Recording the row here would corrupt the
// graph the moment a source row is relocated.
pub fn setLink(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, target: ?u64) !Reference {
    const r0 = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return catalogRef;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogRef, primaryKey)) orelse return catalogRef;
    const row = r0.row;
    const old_raw = try Column.get(transaction, r0.propertyColumn, row);
    const old_target: ?u64 = if (old_raw == 0) null else old_raw - 1;
    if (old_target == target) return catalogRef; // unchanged

    const new_raw: u64 = if (target) |t| t + 1 else 0;
    var newCatalog = try catalog.replaceCollRoot(transaction, catalogRef, row, property, new_raw);
    if (old_target) |ot| newCatalog = try removeBacklink(transaction, newCatalog, property, ot, objectKey);
    if (target) |nt| newCatalog = try addBacklink(transaction, newCatalog, property, nt, objectKey);
    return newCatalog;
}

// ---------------------------------------------------------------------------
// To-many links (link_set): a set of target objectKeys with backlink maintenance.
// ---------------------------------------------------------------------------

pub fn linkSetCount(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?u64 {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return null;
    const set_root = try Column.get(transaction, r.propertyColumn, r.row);
    return try Index.count(transaction, set_root);
}

pub fn linkSetContains(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize, target: u64) !bool {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.propertyColumn, r.row);
    return (try Index.get(transaction, set_root, target)) != null;
}

pub fn linkSetCollect(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    property: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.propertyColumn, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// Add `target` to the to-many link set of object `primaryKey`; records the backlink.
// No-op if already a member. The backlink source is the objectKey (see setLink).
pub fn linkSetAdd(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, target: u64) !Reference {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogRef, primaryKey)) orelse return error.NotFound;
    const row = r.row;
    const old_root = try Column.get(transaction, r.propertyColumn, row);
    if ((try Index.get(transaction, old_root, target)) != null) return catalogRef; // already a member
    const new_root = try Index.insert(transaction, old_root, target, 1);
    var newCatalog = try catalog.replaceCollRoot(transaction, catalogRef, row, property, new_root);
    newCatalog = try addBacklink(transaction, newCatalog, property, target, objectKey);
    return newCatalog;
}

// Remove `target` from the to-many link set of object `primaryKey`; drops the backlink.
// No-op if not a member. The backlink source is the objectKey (see setLink).
pub fn linkSetRemove(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, property: usize, target: u64) !Reference {
    const r = (try catalog.resolveProperty(transaction, catalogRef, primaryKey, property)) orelse return error.NotFound;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogRef, primaryKey)) orelse return error.NotFound;
    const row = r.row;
    const old_root = try Column.get(transaction, r.propertyColumn, row);
    if ((try Index.get(transaction, old_root, target)) == null) return catalogRef; // not a member
    const new_root = try Index.remove(transaction, old_root, target);
    var newCatalog = try catalog.replaceCollRoot(transaction, catalogRef, row, property, new_root);
    newCatalog = try removeBacklink(transaction, newCatalog, property, target, objectKey);
    return newCatalog;
}

// Nullify every inbound link pointing at `objectKey` (and drop those backlink
// entries) for each link/link_set property, restricted to properties where
// `match_all` is true OR the property's link target type equals `target_type`.
// Returns the new catalog ref.
pub fn nullifyInboundInCatalog(transaction: *WriteTransaction, catalogRef: Reference, objectKey: u64, target_type: u16, match_all: bool) !Reference {
    var cur = catalogRef;
    const v0 = try catalog.loadCatalog(transaction, catalogRef);
    const propertyCount = v0.propertyCount;
    const alloc = transaction.database.store.allocator;
    var p: usize = 0;
    while (p < propertyCount) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(transaction, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;
        if (!match_all) {
            const vt = try catalog.loadCatalog(transaction, cur);
            if (vt.linkTarget(p) != target_type) continue;
        }

        // Nullify inbound: snapshot the sources, then clear each one's link to
        // objectKey. For to-one, set the column to null; for to-many, remove objectKey
        // from the source's set.
        var sources = std.ArrayList(u64).empty;
        defer sources.deinit(alloc);
        try backlinkCollect(transaction, cur, p, objectKey, &sources, alloc);
        for (sources.items) |src| {
            // src is a source object key; resolve to its physical row for column
            // access. A backlink entry whose source no longer resolves is stale
            // (corrupt or already deleted); skip it -- the whole set for objectKey is
            // dropped below regardless.
            const src_row = (try catalog.objectKeyToRow(transaction, cur, src)) orelse continue;
            // match_all means this catalog is the target's own type, so
            // src == objectKey is the row being deleted referencing itself.
            const self_source = match_all and src == objectKey;
            // A self-sourced to-many entry is left untouched: the dying row's
            // set tree is freed wholesale from its column raw by the delete's
            // storage reclamation, and Index.remove COWs -- freeing the old
            // root -- so mutating it here made that reclamation a double free.
            // The backlink set for objectKey is dropped below regardless.
            if (self_source and kind == .link_set) continue;
            cur = if (kind == .link)
                try nullifySourceLink(transaction, cur, p, src_row, !self_source)
            else
                try nullifySourceLinkSet(transaction, cur, p, src_row, objectKey, !self_source);
        }
        cur = try dropBacklinkSet(transaction, cur, p, objectKey);
    }
    return cur;
}

// Nullify one source row's to-one link (the link path of inbound nullify):
// set its link column to null. With `bump_version`, also bump the source
// row's version: its link column changed, and a client holding the
// pre-nullify version must get a conflict on update rather than silently
// resurrecting a dangling link. The SELF-link case passes false: bumping the
// row being deleted would make the follow-up tombstone's version check fail
// forever, leaving self-linked objects undeletable.
fn nullifySourceLink(transaction: *WriteTransaction, catalogRef: Reference, property: usize, src_row: u64, bump_version: bool) !Reference {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    s.properties[property].col = try Column.set(transaction, s.properties[property].col, src_row, 0);
    if (bump_version) {
        s.version_col_ref = try Column.set(transaction, s.version_col_ref, src_row, transaction.new_version);
    }
    return s.replace(transaction);
}

// Nullify one source row's to-many link (the link_set path of inbound
// nullify): remove `objectKey` from the source's set. `bump_version` follows the
// same conflict-surfacing rule as nullifySourceLink.
fn nullifySourceLinkSet(transaction: *WriteTransaction, catalogRef: Reference, property: usize, src_row: u64, objectKey: u64, bump_version: bool) !Reference {
    var s = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const src_set = try Column.get(transaction, s.properties[property].col, src_row);
    const new_set = try Index.remove(transaction, src_set, objectKey);
    s.properties[property].col = try Column.set(transaction, s.properties[property].col, src_row, new_set);
    if (bump_version) {
        s.version_col_ref = try Column.set(transaction, s.version_col_ref, src_row, transaction.new_version);
    }
    return s.replace(transaction);
}

// Drop the whole backlink set for objectKey under property `property` (its inbound
// links are now clear): remove the outer entry and free the set's nodes,
// rather than inserting a fresh empty set and orphaning the old tree.
fn dropBacklinkSet(transaction: *WriteTransaction, catalogRef: Reference, property: usize, objectKey: u64) !Reference {
    const vv = try catalog.loadCatalog(transaction, catalogRef);
    if (try Index.get(transaction, vv.backlinkRef(property), objectKey)) |set_root| {
        const new_bl = try Index.remove(transaction, vv.backlinkRef(property), objectKey);
        try Index.freeTree(transaction, set_root);
        return catalog.setBacklinkRef(transaction, catalogRef, property, new_bl);
    }
    return catalogRef;
}

// Remove `objectKey`'s own outbound link entries from its targets' backlink sets for
// each link/link_set property. Returns the new catalog ref.
pub fn cleanOutboundInCatalog(transaction: *WriteTransaction, catalogRef: Reference, objectKey: u64) !Reference {
    var cur = catalogRef;
    const v0 = try catalog.loadCatalog(transaction, catalogRef);
    const propertyCount = v0.propertyCount;
    const alloc = transaction.database.store.allocator;
    var p: usize = 0;
    while (p < propertyCount) : (p += 1) {
        const kind = blk: {
            const vk = try catalog.loadCatalog(transaction, cur);
            break :blk vk.kind(p);
        };
        if (kind != .link and kind != .link_set) continue;

        // Outbound: remove objectKey's own entries from its targets' backlink sets.
        // objectKey is an object key; resolve to the physical row to read its columns.
        // An unresolvable objectKey has no readable outbound links to clean.
        const row = (try catalog.objectKeyToRow(transaction, cur, objectKey)) orelse return cur;
        if (kind == .link) {
            const vv2 = try catalog.loadCatalog(transaction, cur);
            const out_raw = try Column.get(transaction, vv2.propertyColumnRef(p), row);
            if (out_raw != 0) cur = try removeBacklink(transaction, cur, p, out_raw - 1, objectKey);
        } else {
            // to-many: iterate the deleted row's set members.
            var members = std.ArrayList(u64).empty;
            defer members.deinit(alloc);
            {
                const vv2 = try catalog.loadCatalog(transaction, cur);
                const set_root = try Column.get(transaction, vv2.propertyColumnRef(p), row);
                const Sink = struct {
                    list: *std.ArrayList(u64),
                    alloc: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.alloc, key);
                    }
                };
                try Index.forEachKey(transaction, set_root, Sink{ .list = &members, .alloc = alloc }, Sink.onKey);
            }
            for (members.items) |m| cur = try removeBacklink(transaction, cur, p, m, objectKey);
        }
    }
    return cur;
}

// For each link property: (1) nullify every inbound link pointing at `objectKey`
// (and drop those backlink entries); (2) remove the deleted row's own outbound
// link entry from its target's backlink set. Returns the new catalog ref.
pub fn fixBacklinksForDelete(transaction: *WriteTransaction, catalogRef: Reference, objectKey: u64) !Reference {
    const c1 = try nullifyInboundInCatalog(transaction, catalogRef, objectKey, 0, true);
    return try cleanOutboundInCatalog(transaction, c1, objectKey);
}

test {
    _ = @import("linksTests.zig");
}
