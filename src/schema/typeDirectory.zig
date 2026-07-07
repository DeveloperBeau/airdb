// typeDirectory.zig -- type directory node mapping type ids to catalog refs.
//
// Node layout: [type_count u16 LE @0][type_count * (catalog_ref u64 LE) @2]
//              [type_count * (is_embedded u8) @ 2 + tc*8]
// dirSize(tc) = 2 + tc * 8 + tc

const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const rows = @import("../records/rows.zig");
const catalog = @import("catalog.zig");

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
fn writeDir(transaction: *WriteTransaction, cat_refs: []const Reference, embedded: []const bool) !Reference {
    std.debug.assert(embedded.len == cat_refs.len);
    const tc: u16 = @intCast(cat_refs.len);
    const a = try transaction.alloc(dirSize(tc));
    std.mem.writeInt(u16, a.bytes[0..2], tc, .little);
    for (cat_refs, 0..) |cref, i| {
        std.mem.writeInt(u64, a.bytes[2 + i * 8 ..][0..8], cref, .little);
    }
    for (embedded, 0..) |e, i| a.bytes[2 + cat_refs.len * 8 + i] = if (e) 1 else 0;
    return a.ref;
}

// Create a directory from a full PropDef schema (supports links/collections),
// with the given per-type embedded flags.
pub fn createTypes(transaction: *WriteTransaction, schema: DefSchema, embedded: []const bool) !Reference {
    std.debug.assert(schema.len <= 256);
    std.debug.assert(embedded.len == schema.len);
    var cat_refs: [256]Reference = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) cat_refs[t] = try catalog.createDefs(transaction, schema[t]);
    return writeDir(transaction, cat_refs[0..schema.len], embedded);
}

// Create a directory from a full PropDef schema (supports links/collections).
pub fn createWithDefs(transaction: *WriteTransaction, schema: DefSchema) !Reference {
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return createTypes(transaction, schema, flags[0..schema.len]);
}

// Scalar-kinds convenience: each property gets elem = int.
pub fn create(transaction: *WriteTransaction, schema: Schema) !Reference {
    std.debug.assert(schema.len <= 256);
    var cat_refs: [256]Reference = undefined;
    var t: usize = 0;
    while (t < schema.len) : (t += 1) {
        cat_refs[t] = try catalog.createTyped(transaction, schema[t]);
    }
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return writeDir(transaction, cat_refs[0..schema.len], flags[0..schema.len]);
}

fn loadDir(transaction: anytype, dir: Reference) !struct { type_count: u16, bytes: []const u8 } {
    const tc_bytes = try transaction.deref(dir, 2);
    const type_count = std.mem.readInt(u16, tc_bytes[0..2], .little);
    const bytes = try transaction.deref(dir, dirSize(type_count));
    return .{ .type_count = type_count, .bytes = bytes };
}

pub fn typeCount(transaction: anytype, dir: Reference) !u16 {
    const d = try loadDir(transaction, dir);
    return d.type_count;
}

pub fn catalogRef(transaction: anytype, dir: Reference, type_id: u16) !Reference {
    const d = try loadDir(transaction, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    return std.mem.readInt(u64, d.bytes[2 + @as(usize, type_id) * 8 ..][0..8], .little);
}

pub fn setCatalogRef(transaction: *WriteTransaction, dir: Reference, type_id: u16, new_cat: Reference) !Reference {
    const d = try loadDir(transaction, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    const a = try transaction.writableCopy(dir, dirSize(d.type_count));
    std.mem.writeInt(u64, a.bytes[2 + @as(usize, type_id) * 8 ..][0..8], new_cat, .little);
    return a.ref;
}

// Append an already-created catalog to the directory; returns grown dir + id.
// Carries the existing per-type embedded flags and appends the new type's flag.
fn appendCatalog(transaction: *WriteTransaction, old_refs: []const Reference, old_embedded: []const bool, new_cat: Reference, new_embedded: bool) !Reference {
    std.debug.assert(old_refs.len == old_embedded.len);
    const old_tc = old_refs.len;
    var refs: [256]Reference = undefined;
    var flags: [256]bool = undefined;
    var t: usize = 0;
    while (t < old_tc) : (t += 1) {
        refs[t] = old_refs[t];
        flags[t] = old_embedded[t];
    }
    refs[old_tc] = new_cat;
    flags[old_tc] = new_embedded;
    return writeDir(transaction, refs[0 .. old_tc + 1], flags[0 .. old_tc + 1]);
}

// Snapshot existing catalog refs (before any file-growing create call).
fn snapshotRefs(transaction: anytype, dir: Reference, out: *[256]Reference) !u16 {
    const d = try loadDir(transaction, dir);
    var t: usize = 0;
    while (t < d.type_count) : (t += 1) {
        out[t] = std.mem.readInt(u64, d.bytes[2 + t * 8 ..][0..8], .little);
    }
    return d.type_count;
}

// Snapshot existing per-type embedded flags (before any file-growing call).
fn snapshotFlags(transaction: anytype, dir: Reference, out: *[256]bool) !u16 {
    const d = try loadDir(transaction, dir);
    var t: usize = 0;
    while (t < d.type_count) : (t += 1) {
        out[t] = d.bytes[2 + @as(usize, d.type_count) * 8 + t] != 0;
    }
    return d.type_count;
}

pub const AddTypeResult = struct { dir: Reference, type_id: u16 };

// Append a new type from a full PropDef schema (supports links/collections).
pub fn addTypeDefs(transaction: *WriteTransaction, dir: Reference, defs: []const PropDef) !AddTypeResult {
    return addTypeDefsEmbedded(transaction, dir, defs, false);
}

// Like addTypeDefs but marks the new type embedded when `is_embedded` is set.
pub fn addTypeDefsEmbedded(transaction: *WriteTransaction, dir: Reference, defs: []const PropDef, is_embedded: bool) !AddTypeResult {
    var old_refs: [256]Reference = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(transaction, dir, &old_refs);
    _ = try snapshotFlags(transaction, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createDefs(transaction, defs);
    const new_dir = try appendCatalog(transaction, old_refs[0..old_tc], old_flags[0..old_tc], new_cat, is_embedded);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Append a new object type to the directory and return the grown directory ref
// plus the new type id. The new type's catalog is created from `type_schema`.
pub fn addType(transaction: *WriteTransaction, dir: Reference, type_schema: []const PropKind) !AddTypeResult {
    // Capture existing catalog refs and embedded flags before createTyped, which
    // can grow the file and invalidate the directory deref slice.
    var old_refs: [256]Reference = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(transaction, dir, &old_refs);
    _ = try snapshotFlags(transaction, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const new_cat = try catalog.createTyped(transaction, type_schema);
    const new_dir = try appendCatalog(transaction, old_refs[0..old_tc], old_flags[0..old_tc], new_cat, false);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Report whether `type_id` was created as an embedded (single-owner) type.
pub fn isEmbedded(transaction: anytype, dir: Reference, type_id: u16) !bool {
    const d = try loadDir(transaction, dir);
    if (type_id >= d.type_count) return error.NoSuchType;
    return d.bytes[2 + @as(usize, d.type_count) * 8 + type_id] != 0;
}

pub fn validate(transaction: anytype, dir: Reference, expected: Schema) !void {
    const tc = try typeCount(transaction, dir);
    if (tc != expected.len) return error.SchemaMismatch;
    var t: u16 = 0;
    while (t < tc) : (t += 1) {
        const v = try catalog.loadCatalog(transaction, try catalogRef(transaction, dir, t));
        if (v.prop_count != expected[t].len) return error.SchemaMismatch;
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            if (v.kind(j) != expected[t][j]) return error.SchemaMismatch;
        }
    }
}

// Object/link/delete routing through the directory (the type_id -> catalog
// lookup + forward pattern) lives in typeRouting.zig.
const typeRouting = @import("typeRouting.zig");

// ---------------------------------------------------------------------------
// Embedded-object lifecycle: single-owner objects created and cleared through
// their owner via a cascade-rule to-one link.
// ---------------------------------------------------------------------------

// Create an embedded child for `owner`'s to-one link `prop` and link it in.
// If the owner already has a child via `prop`, the old child is deleted first
// (replace semantics). Returns the new directory ref.
pub fn insertEmbedded(transaction: *WriteTransaction, dir: Reference, owner_type: u16, owner_pk: u64, prop: usize, child_values: []const Value) !Reference {
    var cur = dir;
    const child_type = (try catalog.loadCatalog(transaction, try catalogRef(transaction, cur, owner_type))).linkTarget(prop);

    // Replace: delete any existing owned child first. A refused delete must
    // SURFACE, not be swallowed: silently linking the new child while the old
    // one survives breaks the single-owner invariant and leaks an ownerless
    // object. (.blocked is reachable when another type block-links the child;
    // conflict/not_found are impossible for a version read in this transaction.)
    if (try typeRouting.getLink(transaction, cur, owner_type, owner_pk, prop)) |old_okey| {
        const child_cat = try catalogRef(transaction, cur, child_type);
        const pc = (try catalog.loadCatalog(transaction, child_cat)).prop_count;
        var buf: [256]u64 = undefined;
        if (try rows.getByObjectKey(transaction, child_cat, old_okey, buf[0..pc])) |old_ver| {
            const old_pk = buf[0];
            const dres = try typeRouting.deleteNullifyX(transaction, cur, child_type, old_pk, old_ver);
            switch (dres) {
                .ok => |d| cur = d,
                else => return error.Blocked,
            }
        }
    }

    const ins = try typeRouting.insert(transaction, cur, child_type, child_values);
    cur = ins.dir;
    return try typeRouting.setLink(transaction, cur, owner_type, owner_pk, prop, ins.row);
}

// Delete the embedded child owned by `owner` via to-one link `prop`. Deleting
// the child cross-type-nullifies the owner's inbound link automatically.
// Returns the new directory ref (unchanged if there is no child).
pub fn clearEmbedded(transaction: *WriteTransaction, dir: Reference, owner_type: u16, owner_pk: u64, prop: usize) !Reference {
    const child_okey = (try typeRouting.getLink(transaction, dir, owner_type, owner_pk, prop)) orelse return dir;
    const child_type = (try catalog.loadCatalog(transaction, try catalogRef(transaction, dir, owner_type))).linkTarget(prop);
    const child_cat = try catalogRef(transaction, dir, child_type);
    const pc = (try catalog.loadCatalog(transaction, child_cat)).prop_count;
    var buf: [256]u64 = undefined;
    const child_ver = (try rows.getByObjectKey(transaction, child_cat, child_okey, buf[0..pc])) orelse return dir;
    const child_pk = buf[0];
    const dres = try typeRouting.deleteNullifyX(transaction, dir, child_type, child_pk, child_ver);
    return switch (dres) {
        .ok => |d| d,
        // A refused clear must surface: returning the unchanged dir read as
        // success while the child and its link silently survived.
        else => error.Blocked,
    };
}

test {
    _ = @import("typeDirectoryTests.zig");
}
