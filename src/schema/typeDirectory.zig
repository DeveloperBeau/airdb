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

pub const Schema = []const []const catalog.PropertyKind;
// Full schema: each type is a slice of PropertyDefinitions, so a multi-type directory can
// hold link and collection properties (not just scalar kinds).
pub const DefinitionSchema = []const []const catalog.PropertyDefinition;
pub const Value = catalog.Value;
const PropertyKind = catalog.PropertyKind;
const PropertyDefinition = catalog.PropertyDefinition;

fn dirSize(typeCountTotal: u16) usize {
    return 2 + @as(usize, typeCountTotal) * 8 + typeCountTotal;
}

// Pack `tc` catalog refs + per-type embedded flags into a fresh directory node.
fn writeDir(transaction: *WriteTransaction, catalogRefs: []const Reference, embedded: []const bool) !Reference {
    std.debug.assert(embedded.len == catalogRefs.len);
    const typeCountTotal: u16 = @intCast(catalogRefs.len);
    const allocation = try transaction.alloc(dirSize(typeCountTotal));
    std.mem.writeInt(u16, allocation.bytes[0..2], typeCountTotal, .little);
    for (catalogRefs, 0..) |cref, typeIndex| {
        std.mem.writeInt(u64, allocation.bytes[2 + typeIndex * 8 ..][0..8], cref, .little);
    }
    for (embedded, 0..) |flag, typeIndex| allocation.bytes[2 + catalogRefs.len * 8 + typeIndex] = if (flag) 1 else 0;
    return allocation.ref;
}

// Create a directory from a full PropertyDefinition schema (supports links/collections),
// with the given per-type embedded flags.
pub fn createTypes(transaction: *WriteTransaction, schema: DefinitionSchema, embedded: []const bool) !Reference {
    std.debug.assert(schema.len <= 256);
    std.debug.assert(embedded.len == schema.len);
    var catalogRefs: [256]Reference = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < schema.len) : (typeIndex += 1) catalogRefs[typeIndex] = try catalog.createFromDefinitions(transaction, schema[typeIndex]);
    return writeDir(transaction, catalogRefs[0..schema.len], embedded);
}

// Create a directory from a full PropertyDefinition schema (supports links/collections).
pub fn createWithDefinitions(transaction: *WriteTransaction, schema: DefinitionSchema) !Reference {
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return createTypes(transaction, schema, flags[0..schema.len]);
}

// Scalar-kinds convenience: each property gets element = int.
pub fn create(transaction: *WriteTransaction, schema: Schema) !Reference {
    std.debug.assert(schema.len <= 256);
    var catalogRefs: [256]Reference = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < schema.len) : (typeIndex += 1) {
        catalogRefs[typeIndex] = try catalog.createTyped(transaction, schema[typeIndex]);
    }
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return writeDir(transaction, catalogRefs[0..schema.len], flags[0..schema.len]);
}

fn loadDir(transaction: anytype, dir: Reference) !struct { type_count: u16, bytes: []const u8 } {
    const tc_bytes = try transaction.deref(dir, 2);
    const type_count = std.mem.readInt(u16, tc_bytes[0..2], .little);
    const bytes = try transaction.deref(dir, dirSize(type_count));
    return .{ .type_count = type_count, .bytes = bytes };
}

pub fn typeCount(transaction: anytype, dir: Reference) !u16 {
    const directory = try loadDir(transaction, dir);
    return directory.type_count;
}

pub fn catalogRef(transaction: anytype, dir: Reference, type_id: u16) !Reference {
    const directory = try loadDir(transaction, dir);
    if (type_id >= directory.type_count) return error.NoSuchType;
    return std.mem.readInt(u64, directory.bytes[2 + @as(usize, type_id) * 8 ..][0..8], .little);
}

pub fn setCatalogRef(transaction: *WriteTransaction, dir: Reference, type_id: u16, newCatalog: Reference) !Reference {
    const directory = try loadDir(transaction, dir);
    if (type_id >= directory.type_count) return error.NoSuchType;
    const allocation = try transaction.writableCopy(dir, dirSize(directory.type_count));
    std.mem.writeInt(u64, allocation.bytes[2 + @as(usize, type_id) * 8 ..][0..8], newCatalog, .little);
    return allocation.ref;
}

// Append an already-created catalog to the directory; returns grown dir + id.
// Carries the existing per-type embedded flags and appends the new type's flag.
fn appendCatalog(transaction: *WriteTransaction, old_refs: []const Reference, old_embedded: []const bool, newCatalog: Reference, new_embedded: bool) !Reference {
    std.debug.assert(old_refs.len == old_embedded.len);
    const old_tc = old_refs.len;
    var refs: [256]Reference = undefined;
    var flags: [256]bool = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < old_tc) : (typeIndex += 1) {
        refs[typeIndex] = old_refs[typeIndex];
        flags[typeIndex] = old_embedded[typeIndex];
    }
    refs[old_tc] = newCatalog;
    flags[old_tc] = new_embedded;
    return writeDir(transaction, refs[0 .. old_tc + 1], flags[0 .. old_tc + 1]);
}

// Snapshot existing catalog refs (before any file-growing create call).
fn snapshotRefs(transaction: anytype, dir: Reference, out: *[256]Reference) !u16 {
    const directory = try loadDir(transaction, dir);
    var typeIndex: usize = 0;
    while (typeIndex < directory.type_count) : (typeIndex += 1) {
        out[typeIndex] = std.mem.readInt(u64, directory.bytes[2 + typeIndex * 8 ..][0..8], .little);
    }
    return directory.type_count;
}

// Snapshot existing per-type embedded flags (before any file-growing call).
fn snapshotFlags(transaction: anytype, dir: Reference, out: *[256]bool) !u16 {
    const directory = try loadDir(transaction, dir);
    var typeIndex: usize = 0;
    while (typeIndex < directory.type_count) : (typeIndex += 1) {
        out[typeIndex] = directory.bytes[2 + @as(usize, directory.type_count) * 8 + typeIndex] != 0;
    }
    return directory.type_count;
}

pub const AddTypeResult = struct { dir: Reference, type_id: u16 };

// Append a new type from a full PropertyDefinition schema (supports links/collections).
pub fn addTypeDefinitions(transaction: *WriteTransaction, dir: Reference, definitions: []const PropertyDefinition) !AddTypeResult {
    return addTypeDefinitionsEmbedded(transaction, dir, definitions, false);
}

// Like addTypeDefinitions but marks the new type embedded when `is_embedded` is set.
pub fn addTypeDefinitionsEmbedded(transaction: *WriteTransaction, dir: Reference, definitions: []const PropertyDefinition, is_embedded: bool) !AddTypeResult {
    var old_refs: [256]Reference = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(transaction, dir, &old_refs);
    _ = try snapshotFlags(transaction, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const newCatalog = try catalog.createFromDefinitions(transaction, definitions);
    const new_dir = try appendCatalog(transaction, old_refs[0..old_tc], old_flags[0..old_tc], newCatalog, is_embedded);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Append a new object type to the directory and return the grown directory ref
// plus the new type id. The new type's catalog is created from `type_schema`.
pub fn addType(transaction: *WriteTransaction, dir: Reference, type_schema: []const PropertyKind) !AddTypeResult {
    // Capture existing catalog refs and embedded flags before createTyped, which
    // can grow the file and invalidate the directory deref slice.
    var old_refs: [256]Reference = undefined;
    var old_flags: [256]bool = undefined;
    const old_tc = try snapshotRefs(transaction, dir, &old_refs);
    _ = try snapshotFlags(transaction, dir, &old_flags);
    std.debug.assert(old_tc < 256);
    const newCatalog = try catalog.createTyped(transaction, type_schema);
    const new_dir = try appendCatalog(transaction, old_refs[0..old_tc], old_flags[0..old_tc], newCatalog, false);
    return .{ .dir = new_dir, .type_id = old_tc };
}

// Report whether `type_id` was created as an embedded (single-owner) type.
pub fn isEmbedded(transaction: anytype, dir: Reference, type_id: u16) !bool {
    const directory = try loadDir(transaction, dir);
    if (type_id >= directory.type_count) return error.NoSuchType;
    return directory.bytes[2 + @as(usize, directory.type_count) * 8 + type_id] != 0;
}

pub fn validate(transaction: anytype, dir: Reference, expected: Schema) !void {
    const typeCountTotal = try typeCount(transaction, dir);
    if (typeCountTotal != expected.len) return error.SchemaMismatch;
    var typeIndex: u16 = 0;
    while (typeIndex < typeCountTotal) : (typeIndex += 1) {
        const view = try catalog.loadCatalog(transaction, try catalogRef(transaction, dir, typeIndex));
        if (view.propertyCount != expected[typeIndex].len) return error.SchemaMismatch;
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            if (view.kind(propertyIndex) != expected[typeIndex][propertyIndex]) return error.SchemaMismatch;
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

// Create an embedded child for `owner`'s to-one link `property` and link it in.
// If the owner already has a child via `property`, the old child is deleted first
// (replace semantics). Returns the new directory ref.
pub fn insertEmbedded(transaction: *WriteTransaction, dir: Reference, owner_type: u16, ownerPrimaryKey: u64, property: usize, child_values: []const Value) !Reference {
    var currentDir = dir;
    const child_type = (try catalog.loadCatalog(transaction, try catalogRef(transaction, currentDir, owner_type))).linkTarget(property);

    // Replace: delete any existing owned child first. A refused delete must
    // SURFACE, not be swallowed: silently linking the new child while the old
    // one survives breaks the single-owner invariant and leaks an ownerless
    // object. (.blocked is reachable when another type block-links the child;
    // conflict/not_found are impossible for a version read in this transaction.)
    if (try typeRouting.getLink(transaction, currentDir, owner_type, ownerPrimaryKey, property)) |oldObjectKey| {
        const childCatalog = try catalogRef(transaction, currentDir, child_type);
        const propertyCount = (try catalog.loadCatalog(transaction, childCatalog)).propertyCount;
        var buffer: [256]u64 = undefined;
        if (try rows.getByObjectKey(transaction, childCatalog, oldObjectKey, buffer[0..propertyCount])) |oldVersion| {
            const oldPrimaryKey = buffer[0];
            const deleteResult = try typeRouting.deleteNullifyX(transaction, currentDir, child_type, oldPrimaryKey, oldVersion);
            switch (deleteResult) {
                .ok => |directory| currentDir = directory,
                else => return error.Blocked,
            }
        }
    }

    const ins = try typeRouting.insert(transaction, currentDir, child_type, child_values);
    currentDir = ins.dir;
    return try typeRouting.setLink(transaction, currentDir, owner_type, ownerPrimaryKey, property, ins.row);
}

// Delete the embedded child owned by `owner` via to-one link `property`. Deleting
// the child cross-type-nullifies the owner's inbound link automatically.
// Returns the new directory ref (unchanged if there is no child).
pub fn clearEmbedded(transaction: *WriteTransaction, dir: Reference, owner_type: u16, ownerPrimaryKey: u64, property: usize) !Reference {
    const childObjectKey = (try typeRouting.getLink(transaction, dir, owner_type, ownerPrimaryKey, property)) orelse return dir;
    const child_type = (try catalog.loadCatalog(transaction, try catalogRef(transaction, dir, owner_type))).linkTarget(property);
    const childCatalog = try catalogRef(transaction, dir, child_type);
    const propertyCount = (try catalog.loadCatalog(transaction, childCatalog)).propertyCount;
    var buffer: [256]u64 = undefined;
    const childVersion = (try rows.getByObjectKey(transaction, childCatalog, childObjectKey, buffer[0..propertyCount])) orelse return dir;
    const childPrimaryKey = buffer[0];
    const deleteResult = try typeRouting.deleteNullifyX(transaction, dir, child_type, childPrimaryKey, childVersion);
    return switch (deleteResult) {
        .ok => |directory| directory,
        // A refused clear must surface: returning the unchanged dir read as
        // success while the child and its link silently survived.
        else => error.Blocked,
    };
}

test {
    _ = @import("typeDirectoryTests.zig");
}
