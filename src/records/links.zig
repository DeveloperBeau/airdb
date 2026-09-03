const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");
const rows = @import("rows.zig");

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
// link property the catalog holds a backlink index: targetObjectKey -> setRoot,
// where setRoot is an index of sourceObjectKey -> 1. The backlink index is updated
// transactionally on every insert, set, clear, and delete.
// ---------------------------------------------------------------------------

// Add `source` to the backlink set for `target`, returning the new backlink reference.
fn blAdd(transaction: *WriteTransaction, backlinkReference: Reference, target: u64, source: u64) !Reference {
    const existing = try Index.get(transaction, backlinkReference, target);
    var setRoot = existing orelse try Index.create(transaction);
    setRoot = try Index.insert(transaction, setRoot, source, 1);
    return try Index.insert(transaction, backlinkReference, target, setRoot);
}

// Remove `source` from the backlink set for `target`. No-op if absent.
// When the set empties, its outer entry is removed and the set's nodes freed,
// mirroring intValueIndexRemove: link churn must not accumulate empty sets forever.
fn blRemove(transaction: *WriteTransaction, backlinkReference: Reference, target: u64, source: u64) !Reference {
    const existing = try Index.get(transaction, backlinkReference, target);
    const setRoot = existing orelse return backlinkReference;
    const newSet = try Index.remove(transaction, setRoot, source);
    if ((try Index.count(transaction, newSet)) == 0) {
        const newBl = try Index.remove(transaction, backlinkReference, target);
        try Index.freeTree(transaction, newSet);
        return newBl;
    }
    return try Index.insert(transaction, backlinkReference, target, newSet);
}

/// Record source->target in link property `propertyIndex`'s backlink index and
/// return the new catalog reference (copy-on-write). Tree walks, O(log n).
pub fn addBacklink(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, target: u64, source: u64) !Reference {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    const newBl = try blAdd(transaction, view.backlinkReference(propertyIndex), target, source);
    return try catalog.setBacklinkReference(transaction, catalogReference, propertyIndex, newBl);
}

/// Remove `source` from link property `propertyIndex`'s backlink set for
/// `target` and return the new catalog reference. No-op if absent; an emptied set
/// has its outer entry removed and its nodes freed. Tree walks, O(log n).
pub fn removeBacklink(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, target: u64, source: u64) !Reference {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    const newBl = try blRemove(transaction, view.backlinkReference(propertyIndex), target, source);
    return try catalog.setBacklinkReference(transaction, catalogReference, propertyIndex, newBl);
}

/// The target objectKey of link property `property` for the object with
/// primary key `primaryKey`, or null when the link is unset or the object is
/// absent. Tree walks, O(log n).
pub fn getLink(transaction: anytype, catalogReference: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return null;
    const raw = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return if (raw == 0) null else raw - 1;
}

/// Number of objects whose link property `property` points at `target`
/// objectKey. One index descent plus a single-node count read (O(log n)).
pub fn backlinkCount(transaction: anytype, catalogReference: Reference, property: usize, target: u64) !u64 {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    const setRoot = (try Index.get(transaction, view.backlinkReference(property), target)) orelse return 0;
    return try Index.count(transaction, setRoot);
}

/// True when `source` is recorded in link property `property`'s backlink set
/// for `target`. Tree walks, O(log n).
pub fn backlinkContains(transaction: anytype, catalogReference: Reference, property: usize, target: u64, source: u64) !bool {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    const setRoot = (try Index.get(transaction, view.backlinkReference(property), target)) orelse return false;
    return (try Index.get(transaction, setRoot, source)) != null;
}

/// Append the source objectKeys whose link property `property` points at
/// `target` to `out` in ascending order. `out` grows with `allocator` and the
/// caller owns it. Walks the whole backlink set, O(k) over the source count.
pub fn backlinkCollect(
    transaction: anytype,
    catalogReference: Reference,
    property: usize,
    target: u64,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const view = try catalog.loadCatalog(transaction, catalogReference);
    const setRoot = (try Index.get(transaction, view.backlinkReference(property), target)) orelse return;
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, setRoot, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

/// Set (target non-null) or clear (target null) link property `property` of
/// the object with primary key `primaryKey`, returning the new catalog reference.
/// Maintains the backlink index and bumps the row version. Maintains the
/// property's value index when it is indexed. Setting the value it already
/// has is a no-op that returns `catalogReference` unchanged. Tree walks,
/// O(log n).
///
/// Backlink SOURCES are object keys, never physical rows: rows move under
/// relocation/compaction while objectKeys are stable, and every backlink consumer
/// (nullifyInboundInCatalog, cleanOutboundInCatalog, rebuildBacklinks) resolves
/// sources through the key->row index. Recording the row here would corrupt the
/// graph the moment a source row is relocated.
pub fn setLink(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, property: usize, target: ?u64) !Reference {
    const resolvedBefore = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return catalogReference;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogReference, primaryKey)) orelse return catalogReference;
    const row = resolvedBefore.row;
    const oldRaw = try Column.get(transaction, resolvedBefore.propertyColumn, row);
    const oldTarget: ?u64 = if (oldRaw == 0) null else oldRaw - 1;
    if (oldTarget == target) return catalogReference; // unchanged

    const newRaw: u64 = if (target) |unwrapped| unwrapped + 1 else 0;
    const indexed = blk: {
        const view = try catalog.loadCatalog(transaction, catalogReference);
        break :blk view.indexed(property);
    };
    var newCatalog = try catalog.replaceCollectionRoot(transaction, catalogReference, row, property, newRaw);
    if (indexed) {
        newCatalog = try rows.removeFromValueIndex(transaction, newCatalog, property, oldRaw, objectKey);
        newCatalog = try rows.addToValueIndex(transaction, newCatalog, property, newRaw, objectKey);
    }
    if (oldTarget) |previousTarget| newCatalog = try removeBacklink(transaction, newCatalog, property, previousTarget, objectKey);
    if (target) |newTarget| newCatalog = try addBacklink(transaction, newCatalog, property, newTarget, objectKey);
    return newCatalog;
}

// ---------------------------------------------------------------------------
// To-many links (linkSet): a set of target objectKeys with backlink maintenance.
// ---------------------------------------------------------------------------

/// Number of targets in to-many link property `property`, or null when the
/// object is absent or tombstoned. Two index descents to resolve the row,
/// then a single-node count read (O(log n)).
pub fn linkSetCount(transaction: anytype, catalogReference: Reference, primaryKey: u64, property: usize) !?u64 {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return null;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return try Index.count(transaction, setRoot);
}

/// True when `target` is in to-many link property `property` of the object
/// with primary key `primaryKey`. Fails with error.NotFound when the object
/// is absent. Tree walks, O(log n).
pub fn linkSetContains(transaction: anytype, catalogReference: Reference, primaryKey: u64, property: usize, target: u64) !bool {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    return (try Index.get(transaction, setRoot, target)) != null;
}

/// Append every target objectKey in to-many link property `property` to `out`
/// in ascending order. `out` grows with `allocator` and the caller owns it.
/// Walks the whole link set, O(k) over the target count.
pub fn linkSetCollect(
    transaction: anytype,
    catalogReference: Reference,
    primaryKey: u64,
    property: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return error.NotFound;
    const setRoot = try Column.get(transaction, resolved.propertyColumn, resolved.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, setRoot, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

/// Add `target` to the to-many link set of object `primaryKey`, record the
/// backlink, and return the new catalog reference. Adding an existing member is a
/// no-op that returns `catalogReference` unchanged. The backlink source is the
/// objectKey (see setLink). Tree walks, O(log n).
pub fn linkSetAdd(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, property: usize, target: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return error.NotFound;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogReference, primaryKey)) orelse return error.NotFound;
    const row = resolved.row;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, row);
    if ((try Index.get(transaction, oldRoot, target)) != null) return catalogReference; // already a member
    const newRoot = try Index.insert(transaction, oldRoot, target, 1);
    var newCatalog = try catalog.replaceCollectionRoot(transaction, catalogReference, row, property, newRoot);
    newCatalog = try addBacklink(transaction, newCatalog, property, target, objectKey);
    return newCatalog;
}

/// Remove `target` from the to-many link set of object `primaryKey`, drop the
/// backlink, and return the new catalog reference. Removing a non-member is a no-op
/// that returns `catalogReference` unchanged. The backlink source is the objectKey
/// (see setLink). Tree walks, O(log n).
pub fn linkSetRemove(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, property: usize, target: u64) !Reference {
    const resolved = (try catalog.resolveProperty(transaction, catalogReference, primaryKey, property)) orelse return error.NotFound;
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalogReference, primaryKey)) orelse return error.NotFound;
    const row = resolved.row;
    const oldRoot = try Column.get(transaction, resolved.propertyColumn, row);
    if ((try Index.get(transaction, oldRoot, target)) == null) return catalogReference; // not a member
    const newRoot = try Index.remove(transaction, oldRoot, target);
    var newCatalog = try catalog.replaceCollectionRoot(transaction, catalogReference, row, property, newRoot);
    newCatalog = try removeBacklink(transaction, newCatalog, property, target, objectKey);
    return newCatalog;
}

/// Nullify every inbound link pointing at `objectKey` (and drop those
/// backlink entries) for each link/linkSet property, restricted to properties
/// where `matchAll` is true OR the property's link target type equals
/// `targetType`. Returns the new catalog reference. Cost scales with the number of
/// link properties times the number of inbound sources per property (a tree
/// walk per source).
pub fn nullifyInboundInCatalog(transaction: *WriteTransaction, catalogReference: Reference, objectKey: u64, targetType: u16, matchAll: bool) !Reference {
    var currentCatalog = catalogReference;
    const baseView = try catalog.loadCatalog(transaction, catalogReference);
    const propertyCount = baseView.propertyCount;
    const alloc = transaction.database.store.allocator;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        const kind = blk: {
            const currentView = try catalog.loadCatalog(transaction, currentCatalog);
            break :blk currentView.kind(propertyIndex);
        };
        if (kind != .link and kind != .linkSet) continue;
        if (!matchAll) {
            const targetView = try catalog.loadCatalog(transaction, currentCatalog);
            if (targetView.linkTarget(propertyIndex) != targetType) continue;
        }

        // Nullify inbound: snapshot the sources, then clear each one's link to
        // objectKey. For to-one, set the column to null; for to-many, remove objectKey
        // from the source's set.
        var sources = std.ArrayList(u64).empty;
        defer sources.deinit(alloc);
        try backlinkCollect(transaction, currentCatalog, propertyIndex, objectKey, &sources, alloc);
        for (sources.items) |sourceObjectKey| {
            // sourceObjectKey is a source object key; resolve to its physical row for
            // column access. A backlink entry whose source no longer resolves is stale
            // (corrupt or already deleted); skip it -- the whole set for objectKey is
            // dropped below regardless.
            const sourceRow = (try catalog.objectKeyToRow(transaction, currentCatalog, sourceObjectKey)) orelse continue;
            // matchAll means this catalog is the target's own type, so
            // sourceObjectKey == objectKey is the row being deleted referencing itself.
            const selfSource = matchAll and sourceObjectKey == objectKey;
            // A self-sourced to-many entry is left untouched: the dying row's
            // set tree is freed wholesale from its column raw by the delete's
            // storage reclamation, and Index.remove COWs -- freeing the old
            // root -- so mutating it here made that reclamation a double free.
            // The backlink set for objectKey is dropped below regardless.
            if (selfSource and kind == .linkSet) continue;
            currentCatalog = if (kind == .link)
                try nullifySourceLink(transaction, currentCatalog, propertyIndex, sourceObjectKey, sourceRow, !selfSource)
            else
                try nullifySourceLinkSet(transaction, currentCatalog, propertyIndex, sourceRow, objectKey, !selfSource);
        }
        currentCatalog = try dropBacklinkSet(transaction, currentCatalog, propertyIndex, objectKey);
    }
    return currentCatalog;
}

// Nullify one source row's to-one link (the link path of inbound nullify):
// set its link column to null. With `bumpVersion`, also bump the source
// row's version: its link column changed, and a client holding the
// pre-nullify version must get a conflict on update rather than silently
// resurrecting a dangling link. The SELF-link case passes false: bumping the
// row being deleted would make the follow-up tombstone's version check fail
// forever, leaving self-linked objects undeletable.
//
// When the property is indexed, the source's objectKey is MOVED in the value
// index from its old target's raw to 0, in the same transaction: the index is
// the authority for indexed reads (query.minimum/maximum read its key set with
// no residual filter, and query.where(property eq 0) drives off it), so a
// bypassed index is a query that silently omits this row.
fn nullifySourceLink(transaction: *WriteTransaction, catalogReference: Reference, property: usize, sourceObjectKey: u64, sourceRow: u64, bumpVersion: bool) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    const previousRaw = try Column.get(transaction, snapshot.properties[property].column, sourceRow);
    const indexed = snapshot.properties[property].indexed;
    snapshot.properties[property].column = try Column.set(transaction, snapshot.properties[property].column, sourceRow, 0);
    if (bumpVersion) {
        snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, sourceRow, transaction.newVersion);
    }
    var updatedCatalog = try snapshot.replace(transaction);
    if (indexed and previousRaw != 0) {
        updatedCatalog = try rows.removeFromValueIndex(transaction, updatedCatalog, property, previousRaw, sourceObjectKey);
        updatedCatalog = try rows.addToValueIndex(transaction, updatedCatalog, property, 0, sourceObjectKey);
    }
    return updatedCatalog;
}

// Nullify one source row's to-many link (the linkSet path of inbound
// nullify): remove `objectKey` from the source's set. `bumpVersion` follows the
// same conflict-surfacing rule as nullifySourceLink.
fn nullifySourceLinkSet(transaction: *WriteTransaction, catalogReference: Reference, property: usize, sourceRow: u64, objectKey: u64, bumpVersion: bool) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    const sourceSet = try Column.get(transaction, snapshot.properties[property].column, sourceRow);
    const newSet = try Index.remove(transaction, sourceSet, objectKey);
    snapshot.properties[property].column = try Column.set(transaction, snapshot.properties[property].column, sourceRow, newSet);
    if (bumpVersion) {
        snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, sourceRow, transaction.newVersion);
    }
    return snapshot.replace(transaction);
}

// Drop the whole backlink set for objectKey under property `property` (its inbound
// links are now clear): remove the outer entry and free the set's nodes,
// rather than inserting a fresh empty set and orphaning the old tree.
fn dropBacklinkSet(transaction: *WriteTransaction, catalogReference: Reference, property: usize, objectKey: u64) !Reference {
    const catalogView = try catalog.loadCatalog(transaction, catalogReference);
    if (try Index.get(transaction, catalogView.backlinkReference(property), objectKey)) |setRoot| {
        const newBl = try Index.remove(transaction, catalogView.backlinkReference(property), objectKey);
        try Index.freeTree(transaction, setRoot);
        return catalog.setBacklinkReference(transaction, catalogReference, property, newBl);
    }
    return catalogReference;
}

/// Remove `objectKey`'s own outbound link entries from its targets' backlink
/// sets for each link/linkSet property. Returns the new catalog reference. Cost
/// scales with the number of link properties times the deleted row's outbound
/// target count (a tree walk per target).
pub fn cleanOutboundInCatalog(transaction: *WriteTransaction, catalogReference: Reference, objectKey: u64) !Reference {
    var currentCatalog = catalogReference;
    const baseView = try catalog.loadCatalog(transaction, catalogReference);
    const propertyCount = baseView.propertyCount;
    const alloc = transaction.database.store.allocator;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        const kind = blk: {
            const currentView = try catalog.loadCatalog(transaction, currentCatalog);
            break :blk currentView.kind(propertyIndex);
        };
        if (kind != .link and kind != .linkSet) continue;

        // Outbound: remove objectKey's own entries from its targets' backlink sets.
        // objectKey is an object key; resolve to the physical row to read its columns.
        // An unresolvable objectKey has no readable outbound links to clean.
        const row = (try catalog.objectKeyToRow(transaction, currentCatalog, objectKey)) orelse return currentCatalog;
        if (kind == .link) {
            const vv2 = try catalog.loadCatalog(transaction, currentCatalog);
            const outRaw = try Column.get(transaction, vv2.propertyColumnReference(propertyIndex), row);
            if (outRaw != 0) currentCatalog = try removeBacklink(transaction, currentCatalog, propertyIndex, outRaw - 1, objectKey);
        } else {
            // to-many: iterate the deleted row's set members.
            var members = std.ArrayList(u64).empty;
            defer members.deinit(alloc);
            {
                const vv2 = try catalog.loadCatalog(transaction, currentCatalog);
                const setRoot = try Column.get(transaction, vv2.propertyColumnReference(propertyIndex), row);
                const Sink = struct {
                    list: *std.ArrayList(u64),
                    alloc: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.alloc, key);
                    }
                };
                try Index.forEachKey(transaction, setRoot, Sink{ .list = &members, .alloc = alloc }, Sink.onKey);
            }
            for (members.items) |member| currentCatalog = try removeBacklink(transaction, currentCatalog, propertyIndex, member, objectKey);
        }
    }
    return currentCatalog;
}

/// For each link property: (1) nullify every inbound link pointing at
/// `objectKey` (and drop those backlink entries); (2) remove the deleted
/// row's own outbound link entry from its target's backlink set. Returns the
/// new catalog reference. Cost scales with the row's inbound and outbound link
/// counts across all link properties.
pub fn fixBacklinksForDelete(transaction: *WriteTransaction, catalogReference: Reference, objectKey: u64) !Reference {
    const nullified = try nullifyInboundInCatalog(transaction, catalogReference, objectKey, 0, true);
    return try cleanOutboundInCatalog(transaction, nullified, objectKey);
}

test {
    _ = @import("linksTests.zig");
}
