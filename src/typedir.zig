// typedir.zig -- type directory node mapping type ids to catalog refs.
//
// Node layout: [type_count u16 LE @0][type_count * (catalog_ref u64 LE) @2]
//              [type_count * (is_embedded u8) @ 2 + tc*8]
// dirSize(tc) = 2 + tc * 8 + tc

const std = @import("std");
const testing = std.testing;
const WriteTxn = @import("db.zig").WriteTxn;
const Db = @import("db.zig").Db;
const Ref = @import("ref.zig").Ref;
const Objects = @import("objects.zig");
const rows = @import("rows.zig");
const catalog = @import("catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");

pub const Schema = []const []const catalog.PropKind;
// Full schema: each type is a slice of PropDefs, so a multi-type directory can
// hold link and collection properties (not just scalar kinds).
pub const DefSchema = []const []const catalog.PropDef;
pub const Value = catalog.Value;
const PropKind = catalog.PropKind;
const PropDef = catalog.PropDef;

fn dirSize(tc: u16) usize {
    return 2 + @as(usize, tc) * 8 + tc;
}

// Pack `tc` catalog refs + per-type embedded flags into a fresh directory node.
fn writeDir(txn: *WriteTxn, cat_refs: []const Ref, embedded: []const bool) !Ref {
    std.debug.assert(embedded.len == cat_refs.len);
    const tc: u16 = @intCast(cat_refs.len);
    const a = try txn.alloc(dirSize(tc));
    std.mem.writeInt(u16, a.bytes[0..2], tc, .little);
    for (cat_refs, 0..) |cref, i| {
        std.mem.writeInt(u64, a.bytes[2 + i * 8 ..][0..8], cref, .little);
    }
    for (embedded, 0..) |e, i| a.bytes[2 + cat_refs.len * 8 + i] = if (e) 1 else 0;
    return a.ref;
}

// Create a directory from a full PropDef schema (supports links/collections),
// with the given per-type embedded flags.
pub fn createTypes(txn: *WriteTxn, schema: DefSchema, embedded: []const bool) !Ref {
    std.debug.assert(schema.len <= 256);
    std.debug.assert(embedded.len == schema.len);
    var cat_refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) cat_refs[t] = try catalog.createDefs(txn, schema[t]);
    return writeDir(txn, cat_refs[0..schema.len], embedded);
}

// Create a directory from a full PropDef schema (supports links/collections).
pub fn createWithDefs(txn: *WriteTxn, schema: DefSchema) !Ref {
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return createTypes(txn, schema, flags[0..schema.len]);
}

// Scalar-kinds convenience: each property gets elem = int.
pub fn create(txn: *WriteTxn, schema: Schema) !Ref {
    std.debug.assert(schema.len <= 256);
    var cat_refs: [256]Ref = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) {
        cat_refs[t] = try catalog.createTyped(txn, schema[t]);
    }
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return writeDir(txn, cat_refs[0..schema.len], flags[0..schema.len]);
}

fn loadDir(txn: anytype, dir: Ref) !struct { type_count: u16, bytes: []const u8 } {
    const tc_bytes = try txn.deref(dir, 2);
    const type_count = std.mem.readInt(u16, tc_bytes[0..2], .little);
    const bytes = try txn.deref(dir, dirSize(type_count));
    return .{ .type_count = type_count, .bytes = bytes };
}

pub fn typeCount(txn: anytype, dir: Ref) !u16 {
    const d = try loadDir(txn, dir);
    return d.type_count;
}

pub fn catalogRef(txn: anytype, dir: Ref, type_id: u16) !Ref {
    const d = try loadDir(txn, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    return std.mem.readInt(u64, d.bytes[2 + @as(usize, type_id) * 8 ..][0..8], .little);
}

pub fn setCatalogRef(txn: *WriteTxn, dir: Ref, type_id: u16, new_cat: Ref) !Ref {
    const d = try loadDir(txn, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    const a = try txn.writableCopy(dir, dirSize(d.type_count));
    std.mem.writeInt(u64, a.bytes[2 + @as(usize, type_id) * 8 ..][0..8], new_cat, .little);
    return a.ref;
}

// Append an already-created catalog to the directory; returns grown dir + id.
// Carries the existing per-type embedded flags and appends the new type's flag.
fn appendCatalog(txn: *WriteTxn, old_refs: []const Ref, old_embedded: []const bool, new_cat: Ref, new_embedded: bool) !Ref {
    std.debug.assert(old_refs.len == old_embedded.len);
    const old_tc = old_refs.len;
    var refs: [256]Ref = undefined;
    var flags: [256]bool = undefined;
    var t: usize = 0;
    while (t < old_tc) : (t += 1) {
        refs[t] = old_refs[t];
        flags[t] = old_embedded[t];
    }
    refs[old_tc] = new_cat;
    flags[old_tc] = new_embedded;
    return writeDir(txn, refs[0 .. old_tc + 1], flags[0 .. old_tc + 1]);
}

// Snapshot existing catalog refs (before any file-growing create call).
fn snapshotRefs(txn: anytype, dir: Ref, out: *[256]Ref) !u16 {
    const d = try loadDir(txn, dir);
    var t: usize = 0;
    while (t < d.type_count) : (t += 1) {
        out[t] = std.mem.readInt(u64, d.bytes[2 + t * 8 ..][0..8], .little);
    }
    return d.type_count;
}

// Snapshot existing per-type embedded flags (before any file-growing call).
fn snapshotFlags(txn: anytype, dir: Ref, out: *[256]bool) !u16 {
    const d = try loadDir(txn, dir);
    var t: usize = 0;
    while (t < d.type_count) : (t += 1) {
        out[t] = d.bytes[2 + @as(usize, d.type_count) * 8 + t] != 0;
    }
    return d.type_count;
}

pub const AddTypeResult = struct { dir: Ref, type_id: u16 };

// Append a new type from a full PropDef schema (supports links/collections).
pub fn addTypeDefs(txn: *WriteTxn, dir: Ref, defs: []const PropDef) !AddTypeResult {
    return addTypeDefsEmbedded(txn, dir, defs, false);
}

// Like addTypeDefs but marks the new type embedded when `is_embedded` is set.
pub fn addTypeDefsEmbedded(txn: *WriteTxn, dir: Ref, defs: []const PropDef, is_embedded: bool) !AddTypeResult {
    var old_refs: [256]Ref = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(txn, dir, &old_refs);
    _ = try snapshotFlags(txn, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createDefs(txn, defs);
    const new_dir = try appendCatalog(txn, old_refs[0..old_tc], old_flags[0..old_tc], new_cat, is_embedded);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Append a new object type to the directory and return the grown directory ref
// plus the new type id. The new type's catalog is created from `type_schema`.
pub fn addType(txn: *WriteTxn, dir: Ref, type_schema: []const PropKind) !AddTypeResult {
    // Capture existing catalog refs and embedded flags before createTyped, which
    // can grow the file and invalidate the directory deref slice.
    var old_refs: [256]Ref = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(txn, dir, &old_refs);
    _ = try snapshotFlags(txn, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createTyped(txn, type_schema);
    const new_dir = try appendCatalog(txn, old_refs[0..old_tc], old_flags[0..old_tc], new_cat, false);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Report whether `type_id` was created as an embedded (single-owner) type.
pub fn isEmbedded(txn: anytype, dir: Ref, type_id: u16) !bool {
    const d = try loadDir(txn, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    return d.bytes[2 + @as(usize, d.type_count) * 8 + type_id] != 0;
}

pub fn validate(txn: anytype, dir: Ref, expected: Schema) !void {
    const tc = try typeCount(txn, dir);
    if (tc != expected.len) return error.SchemaMismatch;
    var t: u16 = 0;
    while (t < tc) : (t += 1) {
        const v = try catalog.loadCatalog(txn, try catalogRef(txn, dir, t));
        if (v.prop_count != expected[t].len) return error.SchemaMismatch;
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            if (v.kind(j) != expected[t][j]) return error.SchemaMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// Routing wrappers: read catalog ref for the type, do the op, COW the directory
// ---------------------------------------------------------------------------

pub const UpdateOk = struct { dir: Ref, version: u64 };
pub const UpdateResult = union(enum) { ok: UpdateOk, conflict: Objects.Conflict, not_found };
pub const DeleteResult = union(enum) { ok: Ref, conflict: Objects.Conflict, not_found, blocked };

pub fn insert(txn: *WriteTxn, dir: Ref, type_id: u16, values: []const Value) !struct { dir: Ref, row: u64 } {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.insertTyped(txn, cat, values);
    const new_dir = try setCatalogRef(txn, dir, type_id, r.cat);
    return .{ .dir = new_dir, .row = r.row };
}

pub fn get(txn: anytype, dir: Ref, type_id: u16, pk: u64, out: []Value) !?u64 {
    return Objects.getTyped(txn, try catalogRef(txn, dir, type_id), pk, out);
}

pub fn update(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, values: []const Value, expected_version: u64) !UpdateResult {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.updateTyped(txn, cat, pk, values, expected_version);
    return switch (r) {
        .ok => |o| .{ .ok = .{ .dir = try setCatalogRef(txn, dir, type_id, o.cat), .version = o.version } },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

pub fn delete(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, expected_version: u64) !DeleteResult {
    const cat = try catalogRef(txn, dir, type_id);
    const r = try Objects.deleteTyped(txn, cat, pk, expected_version);
    return switch (r) {
        .ok => |c| .{ .ok = try setCatalogRef(txn, dir, type_id, c) },
        .conflict => |c| .{ .conflict = c },
        .not_found => .not_found,
    };
}

pub fn liveCount(txn: anytype, dir: Ref, type_id: u16) !u64 {
    return catalog.liveCount(txn, try catalogRef(txn, dir, type_id));
}

// --- link / to-many routing (mutators COW the directory) ---

pub fn getLink(txn: anytype, dir: Ref, type_id: u16, pk: u64, prop: usize) !?u64 {
    return links.getLink(txn, try catalogRef(txn, dir, type_id), pk, prop);
}

pub fn setLink(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: ?u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.setLink(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn backlinkCount(txn: anytype, dir: Ref, type_id: u16, prop: usize, target: u64) !u64 {
    return links.backlinkCount(txn, try catalogRef(txn, dir, type_id), prop, target);
}

pub fn linkSetAdd(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.linkSetAdd(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn linkSetRemove(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !Ref {
    const cat = try catalogRef(txn, dir, type_id);
    const new_cat = try links.linkSetRemove(txn, cat, pk, prop, target);
    return try setCatalogRef(txn, dir, type_id, new_cat);
}

pub fn linkSetContains(txn: anytype, dir: Ref, type_id: u16, pk: u64, prop: usize, target: u64) !bool {
    return links.linkSetContains(txn, try catalogRef(txn, dir, type_id), pk, prop, target);
}

// ---------------------------------------------------------------------------
// Cross-type link resolution and delete-nullify
// ---------------------------------------------------------------------------

pub fn resolveLink(txn: anytype, dir: Ref, src_type: u16, pk: u64, prop: usize) !?struct { target_type: u16, okey: u64 } {
    const src_cat = try catalogRef(txn, dir, src_type);
    const okey = (try links.getLink(txn, src_cat, pk, prop)) orelse return null;
    const target_type = (try catalog.loadCatalog(txn, src_cat)).linkTarget(prop);
    return .{ .target_type = target_type, .okey = okey };
}

// Materialize the linked object into `out` (sized to the TARGET type's prop_count).
// Returns the target row version, or null if the link is unset or the target is gone.
pub fn getLinked(txn: anytype, dir: Ref, src_type: u16, pk: u64, prop: usize, out: []Value) !?u64 {
    const r = (try resolveLink(txn, dir, src_type, pk, prop)) orelse return null;
    const target_cat = try catalogRef(txn, dir, r.target_type);
    return Objects.getTypedByOkey(txn, target_cat, r.okey, out);
}

// Delete an object, enforcing per-property deletion rules across the directory:
// block (refuse while a block-rule link points at it), cascade (delete owned
// children first), nullify (clear dangling inbound links). Cascade is recursive
// and cycle-safe.
pub fn deleteNullifyX(txn: *WriteTxn, dir: Ref, type_id: u16, pk: u64, expected_version: u64) !DeleteResult {
    const cat0 = try catalogRef(txn, dir, type_id);
    const pc = (try catalog.loadCatalog(txn, cat0)).prop_count;
    var buf: [256]u64 = undefined;
    const ver = (try rows.getByPk(txn, cat0, pk, buf[0..pc])) orelse return .not_found;
    if (ver != expected_version) return .{ .conflict = .{ .current_version = ver } };
    const okey = (try catalog.pkToOkey(txn, cat0, pk)) orelse return .not_found;

    // BLOCK check (top-level only): refuse if any block-rule link points at it.
    // The object's own self-link does not block: this delete clears that link
    // anyway, and counting it made self-linked rows permanently undeletable.
    const tc = try typeCount(txn, dir);
    var s: u16 = 0;
    while (s < tc) : (s += 1) {
        const s_cat = try catalogRef(txn, dir, s);
        const sv = try catalog.loadCatalog(txn, s_cat);
        var p: usize = 0;
        while (p < sv.prop_count) : (p += 1) {
            const k = sv.kind(p);
            if ((k == .link or k == .link_set) and sv.linkTarget(p) == type_id and sv.delRule(p) == .block) {
                const cnt = try links.backlinkCount(txn, s_cat, p, okey);
                if (cnt > 1) return .blocked;
                if (cnt == 1) {
                    const self_only = s == type_id and (try links.backlinkContains(txn, s_cat, p, okey, okey));
                    if (!self_only) return .blocked;
                }
            }
        }
    }

    var visited = std.AutoHashMap(u64, void).init(txn.db.store.allocator);
    defer visited.deinit();
    const new_dir = try deleteWorker(txn, dir, type_id, okey, &visited);
    return .{ .ok = new_dir };
}

// Recursively delete object `okey` of `type_id`: cascade to owned children
// first, then nullify inbound links to it, clean its outbound backlinks, and
// tombstone. Cycle/repeat-safe via `visited`. Inner deletes do not re-enforce
// block (a cascade never half-applies). Returns the new directory ref.
fn deleteWorker(txn: *WriteTxn, dir: Ref, type_id: u16, okey: u64, visited: *std.AutoHashMap(u64, void)) !Ref {
    const key = (@as(u64, type_id) << 48) | okey;
    if (visited.contains(key)) return dir;
    try visited.put(key, {});

    var cur = dir;
    var rbuf: [256]u64 = undefined;
    const cat_t0 = try catalogRef(txn, cur, type_id);
    const pc = (try catalog.loadCatalog(txn, cat_t0)).prop_count;
    if ((try rows.getByObjectKey(txn, cat_t0, okey, rbuf[0..pc])) == null) return cur; // already gone
    const pk = rbuf[0];

    // Snapshot the cascade-relevant schema BEFORE any mutation. Catalog nodes
    // are freed the moment they are rewritten, so a CatalogView into cat_t0
    // must not be read after a recursive delete has rewritten this type's
    // catalog -- the node's bytes may already belong to a new allocation.
    var kinds: [256]catalog.PropKind = undefined;
    var elems: [256]catalog.ElemKind = undefined;
    var rules: [256]catalog.DeletionRule = undefined;
    var targets: [256]u16 = undefined;
    {
        const sv = try catalog.loadCatalog(txn, cat_t0);
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            kinds[p] = sv.kind(p);
            elems[p] = sv.elemKind(p);
            rules[p] = sv.delRule(p);
            targets[p] = sv.linkTarget(p);
        }
    }

    // 1) Cascade: delete children reached by this object's cascade-rule props.
    {
        var p: usize = 0;
        while (p < pc) : (p += 1) {
            const k = kinds[p];
            if ((k != .link and k != .link_set) or rules[p] != .cascade) continue;
            const child_type = targets[p];
            if (k == .link) {
                if (try links.getLink(txn, try catalogRef(txn, cur, type_id), pk, p)) |child| {
                    cur = try deleteWorker(txn, cur, child_type, child, visited);
                }
            } else {
                var members = std.ArrayList(u64).empty;
                defer members.deinit(txn.db.store.allocator);
                try links.linkSetCollect(txn, try catalogRef(txn, cur, type_id), pk, p, &members, txn.db.store.allocator);
                for (members.items) |child| cur = try deleteWorker(txn, cur, child_type, child, visited);
            }
        }
    }

    // 2) Nullify inbound links to this object across all types.
    {
        const n = try typeCount(txn, cur);
        var s: u16 = 0;
        while (s < n) : (s += 1) {
            const s_cat = try catalogRef(txn, cur, s);
            const new_s = try links.nullifyInboundInCatalog(txn, s_cat, okey, type_id, s == type_id);
            cur = try setCatalogRef(txn, cur, s, new_s);
        }
    }
    // 3) Clean this object's own outbound backlink entries.
    {
        const t_cat = try catalogRef(txn, cur, type_id);
        const cleaned = try links.cleanOutboundInCatalog(txn, t_cat, okey);
        cur = try setCatalogRef(txn, cur, type_id, cleaned);
    }
    // 4) Tombstone (re-read current version, which matches in this txn), then
    //    reclaim the row's blob/collection storage from the raws just re-read.
    //    The re-read (not the step-0 rbuf) matters: step 2 may have nullified
    //    this row's own to-one link columns. Reclaiming only on .ok mirrors
    //    deleteTyped; without it every directory-path delete -- including
    //    every cascade-deleted child -- leaked its blobs and collection trees.
    {
        const t_cat = try catalogRef(txn, cur, type_id);
        const cur_ver = (try rows.getByObjectKey(txn, t_cat, okey, rbuf[0..pc])) orelse return cur;
        const dres = try rows.delete(txn, t_cat, pk, cur_ver);
        switch (dres) {
            .ok => |new_cat| {
                cur = try setCatalogRef(txn, cur, type_id, new_cat);
                try rows.freeRowStorage(txn, kinds[0..pc], elems[0..pc], rbuf[0..pc]);
            },
            else => {},
        }
    }
    return cur;
}

// ---------------------------------------------------------------------------
// Embedded-object lifecycle: single-owner objects created and cleared through
// their owner via a cascade-rule to-one link.
// ---------------------------------------------------------------------------

// Create an embedded child for `owner`'s to-one link `prop` and link it in.
// If the owner already has a child via `prop`, the old child is deleted first
// (replace semantics). Returns the new directory ref.
pub fn insertEmbedded(txn: *WriteTxn, dir: Ref, owner_type: u16, owner_pk: u64, prop: usize, child_values: []const Value) !Ref {
    var cur = dir;
    const child_type = (try catalog.loadCatalog(txn, try catalogRef(txn, cur, owner_type))).linkTarget(prop);

    // Replace: delete any existing owned child first. A refused delete must
    // SURFACE, not be swallowed: silently linking the new child while the old
    // one survives breaks the single-owner invariant and leaks an ownerless
    // object. (.blocked is reachable when another type block-links the child;
    // conflict/not_found are impossible for a version read in this txn.)
    if (try getLink(txn, cur, owner_type, owner_pk, prop)) |old_okey| {
        const child_cat = try catalogRef(txn, cur, child_type);
        const pc = (try catalog.loadCatalog(txn, child_cat)).prop_count;
        var buf: [256]u64 = undefined;
        if (try rows.getByObjectKey(txn, child_cat, old_okey, buf[0..pc])) |old_ver| {
            const old_pk = buf[0];
            const dres = try deleteNullifyX(txn, cur, child_type, old_pk, old_ver);
            switch (dres) {
                .ok => |d| cur = d,
                else => return error.Blocked,
            }
        }
    }

    const ins = try insert(txn, cur, child_type, child_values);
    cur = ins.dir;
    return try setLink(txn, cur, owner_type, owner_pk, prop, ins.row);
}

// Delete the embedded child owned by `owner` via to-one link `prop`. Deleting
// the child cross-type-nullifies the owner's inbound link automatically.
// Returns the new directory ref (unchanged if there is no child).
pub fn clearEmbedded(txn: *WriteTxn, dir: Ref, owner_type: u16, owner_pk: u64, prop: usize) !Ref {
    const child_okey = (try getLink(txn, dir, owner_type, owner_pk, prop)) orelse return dir;
    const child_type = (try catalog.loadCatalog(txn, try catalogRef(txn, dir, owner_type))).linkTarget(prop);
    const child_cat = try catalogRef(txn, dir, child_type);
    const pc = (try catalog.loadCatalog(txn, child_cat)).prop_count;
    var buf: [256]u64 = undefined;
    const child_ver = (try rows.getByObjectKey(txn, child_cat, child_okey, buf[0..pc])) orelse return dir;
    const child_pk = buf[0];
    const dres = try deleteNullifyX(txn, dir, child_type, child_pk, child_ver);
    return switch (dres) {
        .ok => |d| d,
        // A refused clear must surface: returning the unchanged dir read as
        // success while the child and its link silently survived.
        else => error.Blocked,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("typedirTests.zig");
}
