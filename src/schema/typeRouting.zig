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
const catalogRef = typedir.catalogRef;
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
    const cat = try catalogRef(transaction, dir, type_id);
    const r = try Objects.insertTyped(transaction, cat, values);
    const new_dir = try setCatalogRef(transaction, dir, type_id, r.cat);
    return .{ .dir = new_dir, .row = r.row };
}

/// Read the object with primary key `pk` from `type_id` into `out`, returning
/// its version or null when absent.
pub fn get(transaction: anytype, dir: Reference, type_id: u16, pk: u64, out: []Value) !?u64 {
    return Objects.getTyped(transaction, try catalogRef(transaction, dir, type_id), pk, out);
}

/// Update the object with primary key `pk` when `expected_version` matches.
pub fn update(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, values: []const Value, expected_version: u64) !UpdateResult {
    const cat = try catalogRef(transaction, dir, type_id);
    const r = try Objects.updateTyped(transaction, cat, pk, values, expected_version);
    return switch (r) {
        .ok => |o| .{ .ok = .{ .dir = try setCatalogRef(transaction, dir, type_id, o.cat), .version = o.version } },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

/// Delete the object with primary key `pk` when `expected_version` matches.
pub fn delete(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, expected_version: u64) !DeleteResult {
    const cat = try catalogRef(transaction, dir, type_id);
    const r = try Objects.deleteTyped(transaction, cat, pk, expected_version);
    return switch (r) {
        .ok => |c| .{ .ok = try setCatalogRef(transaction, dir, type_id, c) },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

/// Number of live objects in `type_id`.
pub fn liveCount(transaction: anytype, dir: Reference, type_id: u16) !u64 {
    return catalog.liveCount(transaction, try catalogRef(transaction, dir, type_id));
}

// --- link / to-many routing (mutators COW the directory) ---

/// The to-one link target (object key) of `pk`'s property `prop`, or null.
pub fn getLink(transaction: anytype, dir: Reference, type_id: u16, pk: u64, prop: usize) !?u64 {
    return links.getLink(transaction, try catalogRef(transaction, dir, type_id), pk, prop);
}

/// Set (or clear, with null) the to-one link of `pk`'s property `prop`.
pub fn setLink(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, prop: usize, target: ?u64) !Reference {
    const cat = try catalogRef(transaction, dir, type_id);
    const new_cat = try links.setLink(transaction, cat, pk, prop, target);
    return try setCatalogRef(transaction, dir, type_id, new_cat);
}

/// Number of `type_id` objects whose property `prop` links to `target`.
pub fn backlinkCount(transaction: anytype, dir: Reference, type_id: u16, prop: usize, target: u64) !u64 {
    return links.backlinkCount(transaction, try catalogRef(transaction, dir, type_id), prop, target);
}

/// Add `target` to `pk`'s link-set property `prop`.
pub fn linkSetAdd(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, prop: usize, target: u64) !Reference {
    const cat = try catalogRef(transaction, dir, type_id);
    const new_cat = try links.linkSetAdd(transaction, cat, pk, prop, target);
    return try setCatalogRef(transaction, dir, type_id, new_cat);
}

/// Remove `target` from `pk`'s link-set property `prop`.
pub fn linkSetRemove(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, prop: usize, target: u64) !Reference {
    const cat = try catalogRef(transaction, dir, type_id);
    const new_cat = try links.linkSetRemove(transaction, cat, pk, prop, target);
    return try setCatalogRef(transaction, dir, type_id, new_cat);
}

/// Whether `pk`'s link-set property `prop` contains `target`.
pub fn linkSetContains(transaction: anytype, dir: Reference, type_id: u16, pk: u64, prop: usize, target: u64) !bool {
    return links.linkSetContains(transaction, try catalogRef(transaction, dir, type_id), pk, prop, target);
}

// ---------------------------------------------------------------------------
// Cross-type link resolution and delete-nullify
// ---------------------------------------------------------------------------

/// Resolve `pk`'s to-one link `prop` to its target type and object key, or
/// null when the link is unset.
pub fn resolveLink(transaction: anytype, dir: Reference, src_type: u16, pk: u64, prop: usize) !?struct { target_type: u16, okey: u64 } {
    const src_cat = try catalogRef(transaction, dir, src_type);
    const okey = (try links.getLink(transaction, src_cat, pk, prop)) orelse return null;
    const target_type = (try catalog.loadCatalog(transaction, src_cat)).linkTarget(prop);
    return .{ .target_type = target_type, .okey = okey };
}

/// Materialize the linked object into `out` (sized to the TARGET type's prop_count).
/// Returns the target row version, or null if the link is unset or the target is gone.
pub fn getLinked(transaction: anytype, dir: Reference, src_type: u16, pk: u64, prop: usize, out: []Value) !?u64 {
    const r = (try resolveLink(transaction, dir, src_type, pk, prop)) orelse return null;
    const target_cat = try catalogRef(transaction, dir, r.target_type);
    return Objects.getTypedByOkey(transaction, target_cat, r.okey, out);
}

/// Delete an object, enforcing per-property deletion rules across the directory:
/// block (refuse while a block-rule link points at it), cascade (delete owned
/// children first), nullify (clear dangling inbound links). Cascade is recursive
/// and cycle-safe.
pub fn deleteNullifyX(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, expected_version: u64) !DeleteResult {
    const cat0 = try catalogRef(transaction, dir, type_id);
    const pc = (try catalog.loadCatalog(transaction, cat0)).prop_count;
    var buf: [256]u64 = undefined;
    const ver = (try rows.getByPk(transaction, cat0, pk, buf[0..pc])) orelse return .not_found;
    if (ver != expected_version) return .{ .conflict = .{ .current_version = ver } };
    const okey = (try catalog.pkToOkey(transaction, cat0, pk)) orelse return .not_found;

    if (try isBlocked(transaction, dir, type_id, okey)) return .blocked;

    var visited = std.AutoHashMap(u64, void).init(transaction.database.store.allocator);
    defer visited.deinit();
    const new_dir = try deleteWorker(transaction, dir, type_id, okey, &visited);
    return .{ .ok = new_dir };
}

// BLOCK check (top-level only): whether any block-rule link in the directory
// points at `okey` of `type_id`. The object's own self-link does not block:
// the delete clears that link anyway, and counting it made self-linked rows
// permanently undeletable.
fn isBlocked(transaction: *WriteTransaction, dir: Reference, type_id: u16, okey: u64) !bool {
    const tc = try typeCount(transaction, dir);
    var s: u16 = 0;
    while (s < tc) : (s += 1) {
        const s_cat = try catalogRef(transaction, dir, s);
        const sv = try catalog.loadCatalog(transaction, s_cat);
        var p: usize = 0;
        while (p < sv.prop_count) : (p += 1) {
            const k = sv.kind(p);
            if ((k == .link or k == .link_set) and sv.linkTarget(p) == type_id and sv.delRule(p) == .block) {
                const cnt = try links.backlinkCount(transaction, s_cat, p, okey);
                if (cnt > 1) return true;
                if (cnt == 1) {
                    const self_only = s == type_id and (try links.backlinkContains(transaction, s_cat, p, okey, okey));
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
    prop_count: usize,
    kinds: [256]catalog.PropKind,
    elems: [256]catalog.ElemKind,
    rules: [256]catalog.DeletionRule,
    targets: [256]u16,
};

fn snapshotSchema(transaction: *WriteTransaction, cat: Reference, prop_count: usize) !SchemaSnapshot {
    var s: SchemaSnapshot = undefined;
    s.prop_count = prop_count;
    const sv = try catalog.loadCatalog(transaction, cat);
    var p: usize = 0;
    while (p < prop_count) : (p += 1) {
        s.kinds[p] = sv.kind(p);
        s.elems[p] = sv.elemKind(p);
        s.rules[p] = sv.delRule(p);
        s.targets[p] = sv.linkTarget(p);
    }
    return s;
}

/// Recursively delete object `okey` of `type_id`: cascade to owned children
/// first, then nullify inbound links to it, clean its outbound backlinks, and
/// tombstone. Cycle/repeat-safe via `visited`. Inner deletes do not re-enforce
/// block (a cascade never half-applies). Returns the new directory ref.
fn deleteWorker(transaction: *WriteTransaction, dir: Reference, type_id: u16, okey: u64, visited: *std.AutoHashMap(u64, void)) !Reference {
    const key = (@as(u64, type_id) << 48) | okey;
    if (visited.contains(key)) return dir;
    try visited.put(key, {});

    var rbuf: [256]u64 = undefined;
    const cat_t0 = try catalogRef(transaction, dir, type_id);
    const pc = (try catalog.loadCatalog(transaction, cat_t0)).prop_count;
    if ((try rows.getByObjectKey(transaction, cat_t0, okey, rbuf[0..pc])) == null) return dir; // already gone
    const pk = rbuf[0];
    const schema = try snapshotSchema(transaction, cat_t0, pc);

    // Phase 1) Cascade: delete children reached by this object's cascade-rule
    // props. Inlined (not a helper) because it recurses into deleteWorker, and
    // a helper would form a mutual recursion whose error sets Zig cannot infer.
    var cur = dir;
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            const k = schema.kinds[p];
            if ((k != .link and k != .link_set) or schema.rules[p] != .cascade) continue;
            const child_type = schema.targets[p];
            if (k == .link) {
                if (try links.getLink(transaction, try catalogRef(transaction, cur, type_id), pk, p)) |child| {
                    cur = try deleteWorker(transaction, cur, child_type, child, visited);
                }
            } else {
                var members = std.ArrayList(u64).empty;
                defer members.deinit(transaction.database.store.allocator);
                try links.linkSetCollect(transaction, try catalogRef(transaction, cur, type_id), pk, p, &members, transaction.database.store.allocator);
                for (members.items) |child| cur = try deleteWorker(transaction, cur, child_type, child, visited);
            }
        }
    }

    cur = try nullifyInbound(transaction, cur, type_id, okey);
    cur = try cleanOutbound(transaction, cur, type_id, okey);
    return tombstoneAndReclaim(transaction, cur, type_id, pk, okey, &schema);
}

// Phase 2) Nullify inbound links to this object across all types.
fn nullifyInbound(transaction: *WriteTransaction, dir: Reference, type_id: u16, okey: u64) !Reference {
    var cur = dir;
    const n = try typeCount(transaction, cur);
    var s: u16 = 0;
    while (s < n) : (s += 1) {
        const s_cat = try catalogRef(transaction, cur, s);
        const new_s = try links.nullifyInboundInCatalog(transaction, s_cat, okey, type_id, s == type_id);
        cur = try setCatalogRef(transaction, cur, s, new_s);
    }
    return cur;
}

// Phase 3) Clean this object's own outbound backlink entries.
fn cleanOutbound(transaction: *WriteTransaction, dir: Reference, type_id: u16, okey: u64) !Reference {
    const t_cat = try catalogRef(transaction, dir, type_id);
    const cleaned = try links.cleanOutboundInCatalog(transaction, t_cat, okey);
    return setCatalogRef(transaction, dir, type_id, cleaned);
}

// Phase 4) Tombstone (re-read current version, which matches in this transaction), then
// reclaim the row's blob/collection storage from the raws just re-read.
// The re-read (not the pre-cascade row buffer) matters: phase 2 may have
// nullified this row's own to-one link columns. Reclaiming only on .ok mirrors
// deleteTyped; without it every directory-path delete -- including every
// cascade-deleted child -- leaked its blobs and collection trees.
fn tombstoneAndReclaim(transaction: *WriteTransaction, dir: Reference, type_id: u16, pk: u64, okey: u64, schema: *const SchemaSnapshot) !Reference {
    const pc = schema.prop_count;
    var rbuf: [256]u64 = undefined;
    const t_cat = try catalogRef(transaction, dir, type_id);
    const cur_ver = (try rows.getByObjectKey(transaction, t_cat, okey, rbuf[0..pc])) orelse return dir;
    const dres = try rows.delete(transaction, t_cat, pk, cur_ver);
    switch (dres) {
        .ok => |new_cat| {
            const cur = try setCatalogRef(transaction, dir, type_id, new_cat);
            try rows.freeRowStorage(transaction, schema.kinds[0..pc], schema.elems[0..pc], rbuf[0..pc]);
            return cur;
        },
        else => return dir,
    }
}
