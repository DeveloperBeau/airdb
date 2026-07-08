// typeRouting.zig -- routing object, link, and delete operations through the
// type directory.
//
// Every function here follows the same pattern: resolve typeId to its catalog
// ref via the directory (typeDirectory.zig owns the directory node format), forward
// to the object/link layer, and COW the directory when the catalog changed.
// The cross-type delete machinery (deleteNullifyX and its worker) also lives
// here because it routes across every type in the directory.

const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Objects = @import("../records/objects.zig");
const rows = @import("../records/rows.zig");
const catalog = @import("catalog.zig");
const links = @import("../records/links.zig");
const typedir = @import("typeDirectory.zig");

const Value = catalog.Value;
const typeCount = typedir.typeCount;
const setCatalogRef = typedir.setCatalogRef;

/// A successful directory-routed update: the new directory ref and the row's
/// new version.
pub const UpdateOk = struct { dir: Reference, version: u64 };
/// Outcome of a directory-routed update.
pub const UpdateResult = union(enum) { ok: UpdateOk, conflict: Objects.Conflict, notFound };
/// Outcome of a directory-routed delete.
pub const DeleteResult = union(enum) { ok: Reference, conflict: Objects.Conflict, notFound, blocked };

/// Insert a typed object into `typeId`, returning the new directory ref and
/// the object's row.
pub fn insert(transaction: *WriteTransaction, dir: Reference, typeId: u16, values: []const Value) !struct { dir: Reference, row: u64 } {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const result = try Objects.insertTyped(transaction, catalogRef, values);
    const newDir = try setCatalogRef(transaction, dir, typeId, result.catalogRef);
    return .{ .dir = newDir, .row = result.row };
}

/// Read the object with primary key `primaryKey` from `typeId` into `out`, returning
/// its version or null when absent.
pub fn get(transaction: anytype, dir: Reference, typeId: u16, primaryKey: u64, out: []Value) !?u64 {
    return Objects.getTyped(transaction, try typedir.catalogRef(transaction, dir, typeId), primaryKey, out);
}

/// Update the object with primary key `primaryKey` when `expectedVersion` matches.
pub fn update(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, values: []const Value, expectedVersion: u64) !UpdateResult {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const result = try Objects.updateTyped(transaction, catalogRef, primaryKey, values, expectedVersion);
    return switch (result) {
        .ok => |okPayload| .{ .ok = .{ .dir = try setCatalogRef(transaction, dir, typeId, okPayload.catalogRef), .version = okPayload.version } },
        .conflict => |conflictVersion| .{ .conflict = conflictVersion },
        .notFound => .notFound,
    };
}

/// Delete the object with primary key `primaryKey` when `expectedVersion` matches.
pub fn delete(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, expectedVersion: u64) !DeleteResult {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const result = try Objects.deleteTyped(transaction, catalogRef, primaryKey, expectedVersion);
    return switch (result) {
        .ok => |newCatalog| .{ .ok = try setCatalogRef(transaction, dir, typeId, newCatalog) },
        .conflict => |conflictVersion| .{ .conflict = conflictVersion },
        .notFound => .notFound,
    };
}

/// Number of live objects in `typeId`.
pub fn liveCount(transaction: anytype, dir: Reference, typeId: u16) !u64 {
    return catalog.liveCount(transaction, try typedir.catalogRef(transaction, dir, typeId));
}

// --- link / to-many routing (mutators COW the directory) ---

/// The to-one link target (object key) of `primaryKey`'s property `property`, or null.
pub fn getLink(transaction: anytype, dir: Reference, typeId: u16, primaryKey: u64, property: usize) !?u64 {
    return links.getLink(transaction, try typedir.catalogRef(transaction, dir, typeId), primaryKey, property);
}

/// Set (or clear, with null) the to-one link of `primaryKey`'s property `property`.
pub fn setLink(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, property: usize, target: ?u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const newCatalog = try links.setLink(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, typeId, newCatalog);
}

/// Number of `typeId` objects whose property `property` links to `target`.
pub fn backlinkCount(transaction: anytype, dir: Reference, typeId: u16, property: usize, target: u64) !u64 {
    return links.backlinkCount(transaction, try typedir.catalogRef(transaction, dir, typeId), property, target);
}

/// Add `target` to `primaryKey`'s link-set property `property`.
pub fn linkSetAdd(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, property: usize, target: u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const newCatalog = try links.linkSetAdd(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, typeId, newCatalog);
}

/// Remove `target` from `primaryKey`'s link-set property `property`.
pub fn linkSetRemove(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, property: usize, target: u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, typeId);
    const newCatalog = try links.linkSetRemove(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, typeId, newCatalog);
}

/// Whether `primaryKey`'s link-set property `property` contains `target`.
pub fn linkSetContains(transaction: anytype, dir: Reference, typeId: u16, primaryKey: u64, property: usize, target: u64) !bool {
    return links.linkSetContains(transaction, try typedir.catalogRef(transaction, dir, typeId), primaryKey, property, target);
}

// ---------------------------------------------------------------------------
// Cross-type link resolution and delete-nullify
// ---------------------------------------------------------------------------

/// Resolve `primaryKey`'s to-one link `property` to its target type and object key, or
/// null when the link is unset.
pub fn resolveLink(transaction: anytype, dir: Reference, srcType: u16, primaryKey: u64, property: usize) !?struct { targetType: u16, objectKey: u64 } {
    const sourceCatalog = try typedir.catalogRef(transaction, dir, srcType);
    const objectKey = (try links.getLink(transaction, sourceCatalog, primaryKey, property)) orelse return null;
    const targetType = (try catalog.loadCatalog(transaction, sourceCatalog)).linkTarget(property);
    return .{ .targetType = targetType, .objectKey = objectKey };
}

/// Materialize the linked object into `out` (sized to the TARGET type's propertyCount).
/// Returns the target row version, or null if the link is unset or the target is gone.
pub fn getLinked(transaction: anytype, dir: Reference, srcType: u16, primaryKey: u64, property: usize, out: []Value) !?u64 {
    const result = (try resolveLink(transaction, dir, srcType, primaryKey, property)) orelse return null;
    const targetCatalog = try typedir.catalogRef(transaction, dir, result.targetType);
    return Objects.getTypedByObjectKey(transaction, targetCatalog, result.objectKey, out);
}

/// Delete an object, enforcing per-property deletion rules across the directory:
/// block (refuse while a block-rule link points at it), cascade (delete owned
/// children first), nullify (clear dangling inbound links). Cascade is recursive
/// and cycle-safe.
pub fn deleteNullifyX(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, expectedVersion: u64) !DeleteResult {
    const catalog0 = try typedir.catalogRef(transaction, dir, typeId);
    const propertyCount = (try catalog.loadCatalog(transaction, catalog0)).propertyCount;
    var buffer: [256]u64 = undefined;
    const version = (try rows.getByPrimaryKey(transaction, catalog0, primaryKey, buffer[0..propertyCount])) orelse return .notFound;
    if (version != expectedVersion) return .{ .conflict = .{ .currentVersion = version } };
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalog0, primaryKey)) orelse return .notFound;

    if (try isBlocked(transaction, dir, typeId, objectKey)) return .blocked;

    var visited = std.AutoHashMap(u64, void).init(transaction.database.store.allocator);
    defer visited.deinit();
    const newDir = try deleteWorker(transaction, dir, typeId, objectKey, &visited);
    return .{ .ok = newDir };
}

// BLOCK check (top-level only): whether any block-rule link in the directory
// points at `objectKey` of `typeId`. The object's own self-link does not block:
// the delete clears that link anyway, and counting it made self-linked rows
// permanently undeletable.
fn isBlocked(transaction: *WriteTransaction, dir: Reference, typeId: u16, objectKey: u64) !bool {
    const typeCountTotal = try typeCount(transaction, dir);
    var sourceType: u16 = 0;
    while (sourceType < typeCountTotal) : (sourceType += 1) {
        const sourceCatalog = try typedir.catalogRef(transaction, dir, sourceType);
        const sourceView = try catalog.loadCatalog(transaction, sourceCatalog);
        var propertyIndex: usize = 0;
        while (propertyIndex < sourceView.propertyCount) : (propertyIndex += 1) {
            const kind = sourceView.kind(propertyIndex);
            if ((kind == .link or kind == .linkSet) and sourceView.linkTarget(propertyIndex) == typeId and sourceView.delRule(propertyIndex) == .block) {
                const backlinkTotal = try links.backlinkCount(transaction, sourceCatalog, propertyIndex, objectKey);
                if (backlinkTotal > 1) return true;
                if (backlinkTotal == 1) {
                    const selfOnly = sourceType == typeId and (try links.backlinkContains(transaction, sourceCatalog, propertyIndex, objectKey, objectKey));
                    if (!selfOnly) return true;
                }
            }
        }
    }
    return false;
}

// The cascade-relevant schema of one type, captured BEFORE any mutation.
// Catalog nodes are freed the moment they are rewritten, so a CatalogView must
// not be read after a recursive delete has rewritten the type's catalog -- the
// node's bytes may already belong to a new allocation.
const SchemaSnapshot = struct {
    propertyCount: usize,
    kinds: [256]catalog.PropertyKind,
    elements: [256]catalog.ElementKind,
    rules: [256]catalog.DeletionRule,
    targets: [256]u16,
};

fn snapshotSchema(transaction: *WriteTransaction, catalogRef: Reference, propertyCount: usize) !SchemaSnapshot {
    var sourceType: SchemaSnapshot = undefined;
    sourceType.propertyCount = propertyCount;
    const sourceView = try catalog.loadCatalog(transaction, catalogRef);
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        sourceType.kinds[propertyIndex] = sourceView.kind(propertyIndex);
        sourceType.elements[propertyIndex] = sourceView.elementKind(propertyIndex);
        sourceType.rules[propertyIndex] = sourceView.delRule(propertyIndex);
        sourceType.targets[propertyIndex] = sourceView.linkTarget(propertyIndex);
    }
    return sourceType;
}

/// Recursively delete object `objectKey` of `typeId`: cascade to owned children
/// first, then nullify inbound links to it, clean its outbound backlinks, and
/// tombstone. Cycle/repeat-safe via `visited`. Inner deletes do not re-enforce
/// block (a cascade never half-applies). Returns the new directory ref.
fn deleteWorker(transaction: *WriteTransaction, dir: Reference, typeId: u16, objectKey: u64, visited: *std.AutoHashMap(u64, void)) !Reference {
    const key = (@as(u64, typeId) << 48) | objectKey;
    if (visited.contains(key)) return dir;
    try visited.put(key, {});

    var rowBuffer: [256]u64 = undefined;
    const catalogBefore = try typedir.catalogRef(transaction, dir, typeId);
    const propertyCount = (try catalog.loadCatalog(transaction, catalogBefore)).propertyCount;
    if ((try rows.getByObjectKey(transaction, catalogBefore, objectKey, rowBuffer[0..propertyCount])) == null) return dir; // already gone
    const primaryKey = rowBuffer[0];
    const schema = try snapshotSchema(transaction, catalogBefore, propertyCount);

    // Phase 1) Cascade: delete children reached by this object's cascade-rule
    // properties. Inlined (not a helper) because it recurses into deleteWorker, and
    // a helper would form a mutual recursion whose error sets Zig cannot infer.
    var currentDir = dir;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const kind = schema.kinds[propertyIndex];
            if ((kind != .link and kind != .linkSet) or schema.rules[propertyIndex] != .cascade) continue;
            const childType = schema.targets[propertyIndex];
            if (kind == .link) {
                if (try links.getLink(transaction, try typedir.catalogRef(transaction, currentDir, typeId), primaryKey, propertyIndex)) |child| {
                    currentDir = try deleteWorker(transaction, currentDir, childType, child, visited);
                }
            } else {
                var members = std.ArrayList(u64).empty;
                defer members.deinit(transaction.database.store.allocator);
                try links.linkSetCollect(transaction, try typedir.catalogRef(transaction, currentDir, typeId), primaryKey, propertyIndex, &members, transaction.database.store.allocator);
                for (members.items) |child| currentDir = try deleteWorker(transaction, currentDir, childType, child, visited);
            }
        }
    }

    currentDir = try nullifyInbound(transaction, currentDir, typeId, objectKey);
    currentDir = try cleanOutbound(transaction, currentDir, typeId, objectKey);
    return tombstoneAndReclaim(transaction, currentDir, typeId, primaryKey, objectKey, &schema);
}

// Phase 2) Nullify inbound links to this object across all types.
fn nullifyInbound(transaction: *WriteTransaction, dir: Reference, typeId: u16, objectKey: u64) !Reference {
    var currentDir = dir;
    const typeCountTotal = try typeCount(transaction, currentDir);
    var sourceType: u16 = 0;
    while (sourceType < typeCountTotal) : (sourceType += 1) {
        const sourceCatalog = try typedir.catalogRef(transaction, currentDir, sourceType);
        const newSourceCatalog = try links.nullifyInboundInCatalog(transaction, sourceCatalog, objectKey, typeId, sourceType == typeId);
        currentDir = try setCatalogRef(transaction, currentDir, sourceType, newSourceCatalog);
    }
    return currentDir;
}

// Phase 3) Clean this object's own outbound backlink entries.
fn cleanOutbound(transaction: *WriteTransaction, dir: Reference, typeId: u16, objectKey: u64) !Reference {
    const typeCatalog = try typedir.catalogRef(transaction, dir, typeId);
    const cleaned = try links.cleanOutboundInCatalog(transaction, typeCatalog, objectKey);
    return setCatalogRef(transaction, dir, typeId, cleaned);
}

// Phase 4) Tombstone (re-read current version, which matches in this transaction), then
// reclaim the row's blob/collection storage from the raws just re-read.
// The re-read (not the pre-cascade row buffer) matters: phase 2 may have
// nullified this row's own to-one link columns. Reclaiming only on .ok mirrors
// deleteTyped; without it every directory-path delete -- including every
// cascade-deleted child -- leaked its blobs and collection trees.
fn tombstoneAndReclaim(transaction: *WriteTransaction, dir: Reference, typeId: u16, primaryKey: u64, objectKey: u64, schema: *const SchemaSnapshot) !Reference {
    const propertyCount = schema.propertyCount;
    var rowBuffer: [256]u64 = undefined;
    const typeCatalog = try typedir.catalogRef(transaction, dir, typeId);
    const currentVersion = (try rows.getByObjectKey(transaction, typeCatalog, objectKey, rowBuffer[0..propertyCount])) orelse return dir;
    const dres = try rows.delete(transaction, typeCatalog, primaryKey, currentVersion);
    switch (dres) {
        .ok => |newCatalog| {
            const currentDir = try setCatalogRef(transaction, dir, typeId, newCatalog);
            try rows.freeRowStorage(transaction, schema.kinds[0..propertyCount], schema.elements[0..propertyCount], rowBuffer[0..propertyCount]);
            return currentDir;
        },
        else => return dir,
    }
}
