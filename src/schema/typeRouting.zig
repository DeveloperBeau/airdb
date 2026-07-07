// typeRouting.zig -- routing object, link, and delete operations through the
// type directory.
//
// Every function here follows the same pattern: resolve type_id to its catalog
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
pub const UpdateResult = union(enum) { ok: UpdateOk, conflict: Objects.Conflict, not_found };
/// Outcome of a directory-routed delete.
pub const DeleteResult = union(enum) { ok: Reference, conflict: Objects.Conflict, not_found, blocked };

/// Insert a typed object into `type_id`, returning the new directory ref and
/// the object's row.
pub fn insert(transaction: *WriteTransaction, dir: Reference, type_id: u16, values: []const Value) !struct { dir: Reference, row: u64 } {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const r = try Objects.insertTyped(transaction, catalogRef, values);
    const new_dir = try setCatalogRef(transaction, dir, type_id, r.catalogRef);
    return .{ .dir = new_dir, .row = r.row };
}

/// Read the object with primary key `primaryKey` from `type_id` into `out`, returning
/// its version or null when absent.
pub fn get(transaction: anytype, dir: Reference, type_id: u16, primaryKey: u64, out: []Value) !?u64 {
    return Objects.getTyped(transaction, try typedir.catalogRef(transaction, dir, type_id), primaryKey, out);
}

/// Update the object with primary key `primaryKey` when `expected_version` matches.
pub fn update(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, values: []const Value, expected_version: u64) !UpdateResult {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const r = try Objects.updateTyped(transaction, catalogRef, primaryKey, values, expected_version);
    return switch (r) {
        .ok => |o| .{ .ok = .{ .dir = try setCatalogRef(transaction, dir, type_id, o.catalogRef), .version = o.version } },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

/// Delete the object with primary key `primaryKey` when `expected_version` matches.
pub fn delete(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, expected_version: u64) !DeleteResult {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const r = try Objects.deleteTyped(transaction, catalogRef, primaryKey, expected_version);
    return switch (r) {
        .ok => |c| .{ .ok = try setCatalogRef(transaction, dir, type_id, c) },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

/// Number of live objects in `type_id`.
pub fn liveCount(transaction: anytype, dir: Reference, type_id: u16) !u64 {
    return catalog.liveCount(transaction, try typedir.catalogRef(transaction, dir, type_id));
}

// --- link / to-many routing (mutators COW the directory) ---

/// The to-one link target (object key) of `primaryKey`'s property `property`, or null.
pub fn getLink(transaction: anytype, dir: Reference, type_id: u16, primaryKey: u64, property: usize) !?u64 {
    return links.getLink(transaction, try typedir.catalogRef(transaction, dir, type_id), primaryKey, property);
}

/// Set (or clear, with null) the to-one link of `primaryKey`'s property `property`.
pub fn setLink(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, property: usize, target: ?u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const newCatalog = try links.setLink(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, type_id, newCatalog);
}

/// Number of `type_id` objects whose property `property` links to `target`.
pub fn backlinkCount(transaction: anytype, dir: Reference, type_id: u16, property: usize, target: u64) !u64 {
    return links.backlinkCount(transaction, try typedir.catalogRef(transaction, dir, type_id), property, target);
}

/// Add `target` to `primaryKey`'s link-set property `property`.
pub fn linkSetAdd(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, property: usize, target: u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const newCatalog = try links.linkSetAdd(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, type_id, newCatalog);
}

/// Remove `target` from `primaryKey`'s link-set property `property`.
pub fn linkSetRemove(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, property: usize, target: u64) !Reference {
    const catalogRef = try typedir.catalogRef(transaction, dir, type_id);
    const newCatalog = try links.linkSetRemove(transaction, catalogRef, primaryKey, property, target);
    return try setCatalogRef(transaction, dir, type_id, newCatalog);
}

/// Whether `primaryKey`'s link-set property `property` contains `target`.
pub fn linkSetContains(transaction: anytype, dir: Reference, type_id: u16, primaryKey: u64, property: usize, target: u64) !bool {
    return links.linkSetContains(transaction, try typedir.catalogRef(transaction, dir, type_id), primaryKey, property, target);
}

// ---------------------------------------------------------------------------
// Cross-type link resolution and delete-nullify
// ---------------------------------------------------------------------------

/// Resolve `primaryKey`'s to-one link `property` to its target type and object key, or
/// null when the link is unset.
pub fn resolveLink(transaction: anytype, dir: Reference, src_type: u16, primaryKey: u64, property: usize) !?struct { target_type: u16, objectKey: u64 } {
    const sourceCatalog = try typedir.catalogRef(transaction, dir, src_type);
    const objectKey = (try links.getLink(transaction, sourceCatalog, primaryKey, property)) orelse return null;
    const target_type = (try catalog.loadCatalog(transaction, sourceCatalog)).linkTarget(property);
    return .{ .target_type = target_type, .objectKey = objectKey };
}

/// Materialize the linked object into `out` (sized to the TARGET type's propertyCount).
/// Returns the target row version, or null if the link is unset or the target is gone.
pub fn getLinked(transaction: anytype, dir: Reference, src_type: u16, primaryKey: u64, property: usize, out: []Value) !?u64 {
    const r = (try resolveLink(transaction, dir, src_type, primaryKey, property)) orelse return null;
    const targetCatalog = try typedir.catalogRef(transaction, dir, r.target_type);
    return Objects.getTypedByObjectKey(transaction, targetCatalog, r.objectKey, out);
}

/// Delete an object, enforcing per-property deletion rules across the directory:
/// block (refuse while a block-rule link points at it), cascade (delete owned
/// children first), nullify (clear dangling inbound links). Cascade is recursive
/// and cycle-safe.
pub fn deleteNullifyX(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, expected_version: u64) !DeleteResult {
    const catalog0 = try typedir.catalogRef(transaction, dir, type_id);
    const propertyCount = (try catalog.loadCatalog(transaction, catalog0)).propertyCount;
    var buffer: [256]u64 = undefined;
    const version = (try rows.getByPrimaryKey(transaction, catalog0, primaryKey, buffer[0..propertyCount])) orelse return .not_found;
    if (version != expected_version) return .{ .conflict = .{ .current_version = version } };
    const objectKey = (try catalog.primaryKeyToObjectKey(transaction, catalog0, primaryKey)) orelse return .not_found;

    if (try isBlocked(transaction, dir, type_id, objectKey)) return .blocked;

    var visited = std.AutoHashMap(u64, void).init(transaction.database.store.allocator);
    defer visited.deinit();
    const new_dir = try deleteWorker(transaction, dir, type_id, objectKey, &visited);
    return .{ .ok = new_dir };
}

// BLOCK check (top-level only): whether any block-rule link in the directory
// points at `objectKey` of `type_id`. The object's own self-link does not block:
// the delete clears that link anyway, and counting it made self-linked rows
// permanently undeletable.
fn isBlocked(transaction: *WriteTransaction, dir: Reference, type_id: u16, objectKey: u64) !bool {
    const tc = try typeCount(transaction, dir);
    var s: u16 = 0;
    while (s < tc) : (s += 1) {
        const sourceCatalog = try typedir.catalogRef(transaction, dir, s);
        const sv = try catalog.loadCatalog(transaction, sourceCatalog);
        var p: usize = 0;
        while (p < sv.propertyCount) : (p += 1) {
            const k = sv.kind(p);
            if ((k == .link or k == .link_set) and sv.linkTarget(p) == type_id and sv.delRule(p) == .block) {
                const cnt = try links.backlinkCount(transaction, sourceCatalog, p, objectKey);
                if (cnt > 1) return true;
                if (cnt == 1) {
                    const self_only = s == type_id and (try links.backlinkContains(transaction, sourceCatalog, p, objectKey, objectKey));
                    if (!self_only) return true;
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
    var s: SchemaSnapshot = undefined;
    s.propertyCount = propertyCount;
    const sv = try catalog.loadCatalog(transaction, catalogRef);
    var p: usize = 0;
    while (p < propertyCount) : (p += 1) {
        s.kinds[p] = sv.kind(p);
        s.elements[p] = sv.elementKind(p);
        s.rules[p] = sv.delRule(p);
        s.targets[p] = sv.linkTarget(p);
    }
    return s;
}

/// Recursively delete object `objectKey` of `type_id`: cascade to owned children
/// first, then nullify inbound links to it, clean its outbound backlinks, and
/// tombstone. Cycle/repeat-safe via `visited`. Inner deletes do not re-enforce
/// block (a cascade never half-applies). Returns the new directory ref.
fn deleteWorker(transaction: *WriteTransaction, dir: Reference, type_id: u16, objectKey: u64, visited: *std.AutoHashMap(u64, void)) !Reference {
    const key = (@as(u64, type_id) << 48) | objectKey;
    if (visited.contains(key)) return dir;
    try visited.put(key, {});

    var rowBuffer: [256]u64 = undefined;
    const catalogBefore = try typedir.catalogRef(transaction, dir, type_id);
    const propertyCount = (try catalog.loadCatalog(transaction, catalogBefore)).propertyCount;
    if ((try rows.getByObjectKey(transaction, catalogBefore, objectKey, rowBuffer[0..propertyCount])) == null) return dir; // already gone
    const primaryKey = rowBuffer[0];
    const schema = try snapshotSchema(transaction, catalogBefore, propertyCount);

    // Phase 1) Cascade: delete children reached by this object's cascade-rule
    // properties. Inlined (not a helper) because it recurses into deleteWorker, and
    // a helper would form a mutual recursion whose error sets Zig cannot infer.
    var cur = dir;
    {
        var p: usize = 0;
        while (p < propertyCount) : (p += 1) {
            const k = schema.kinds[p];
            if ((k != .link and k != .link_set) or schema.rules[p] != .cascade) continue;
            const child_type = schema.targets[p];
            if (k == .link) {
                if (try links.getLink(transaction, try typedir.catalogRef(transaction, cur, type_id), primaryKey, p)) |child| {
                    cur = try deleteWorker(transaction, cur, child_type, child, visited);
                }
            } else {
                var members = std.ArrayList(u64).empty;
                defer members.deinit(transaction.database.store.allocator);
                try links.linkSetCollect(transaction, try typedir.catalogRef(transaction, cur, type_id), primaryKey, p, &members, transaction.database.store.allocator);
                for (members.items) |child| cur = try deleteWorker(transaction, cur, child_type, child, visited);
            }
        }
    }

    cur = try nullifyInbound(transaction, cur, type_id, objectKey);
    cur = try cleanOutbound(transaction, cur, type_id, objectKey);
    return tombstoneAndReclaim(transaction, cur, type_id, primaryKey, objectKey, &schema);
}

// Phase 2) Nullify inbound links to this object across all types.
fn nullifyInbound(transaction: *WriteTransaction, dir: Reference, type_id: u16, objectKey: u64) !Reference {
    var cur = dir;
    const n = try typeCount(transaction, cur);
    var s: u16 = 0;
    while (s < n) : (s += 1) {
        const sourceCatalog = try typedir.catalogRef(transaction, cur, s);
        const new_s = try links.nullifyInboundInCatalog(transaction, sourceCatalog, objectKey, type_id, s == type_id);
        cur = try setCatalogRef(transaction, cur, s, new_s);
    }
    return cur;
}

// Phase 3) Clean this object's own outbound backlink entries.
fn cleanOutbound(transaction: *WriteTransaction, dir: Reference, type_id: u16, objectKey: u64) !Reference {
    const typeCatalog = try typedir.catalogRef(transaction, dir, type_id);
    const cleaned = try links.cleanOutboundInCatalog(transaction, typeCatalog, objectKey);
    return setCatalogRef(transaction, dir, type_id, cleaned);
}

// Phase 4) Tombstone (re-read current version, which matches in this transaction), then
// reclaim the row's blob/collection storage from the raws just re-read.
// The re-read (not the pre-cascade row buffer) matters: phase 2 may have
// nullified this row's own to-one link columns. Reclaiming only on .ok mirrors
// deleteTyped; without it every directory-path delete -- including every
// cascade-deleted child -- leaked its blobs and collection trees.
fn tombstoneAndReclaim(transaction: *WriteTransaction, dir: Reference, type_id: u16, primaryKey: u64, objectKey: u64, schema: *const SchemaSnapshot) !Reference {
    const propertyCount = schema.propertyCount;
    var rowBuffer: [256]u64 = undefined;
    const typeCatalog = try typedir.catalogRef(transaction, dir, type_id);
    const currentVersion = (try rows.getByObjectKey(transaction, typeCatalog, objectKey, rowBuffer[0..propertyCount])) orelse return dir;
    const dres = try rows.delete(transaction, typeCatalog, primaryKey, currentVersion);
    switch (dres) {
        .ok => |newCatalog| {
            const cur = try setCatalogRef(transaction, dir, type_id, newCatalog);
            try rows.freeRowStorage(transaction, schema.kinds[0..propertyCount], schema.elements[0..propertyCount], rowBuffer[0..propertyCount]);
            return cur;
        },
        else => return dir,
    }
}
