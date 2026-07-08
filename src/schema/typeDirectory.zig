//! Type directory node mapping type ids to catalog references.
//!
//! Node layout: [typeCount u16 LE @0][typeCount * (catalogReference u64 LE) @2]
//!              [typeCount * (isEmbedded u8) @ 2 + tc*8]
//! directorySize(tc) = 2 + tc * 8 + tc

const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const rows = @import("../records/rows.zig");
const catalog = @import("catalog.zig");

/// Scalar-kinds schema: each type is a slice of bare PropertyKinds (every
/// property defaults to element = int, no links).
pub const Schema = []const []const catalog.PropertyKind;
/// Full schema: each type is a slice of PropertyDefinitions, so a multi-type directory can
/// hold link and collection properties (not just scalar kinds).
pub const DefinitionSchema = []const []const catalog.PropertyDefinition;
/// One property's typed value (re-exported from the catalog).
pub const Value = catalog.Value;
const PropertyKind = catalog.PropertyKind;
const PropertyDefinition = catalog.PropertyDefinition;

fn directorySize(typeCountTotal: u16) usize {
    return 2 + @as(usize, typeCountTotal) * 8 + typeCountTotal;
}

// Pack `tc` catalog references + per-type embedded flags into a fresh directory node.
fn writeDirectory(transaction: *WriteTransaction, catalogReferences: []const Reference, embedded: []const bool) !Reference {
    std.debug.assert(embedded.len == catalogReferences.len);
    const typeCountTotal: u16 = @intCast(catalogReferences.len);
    const allocation = try transaction.alloc(directorySize(typeCountTotal));
    std.mem.writeInt(u16, allocation.bytes[0..2], typeCountTotal, .little);
    for (catalogReferences, 0..) |typeCatalogReference, typeIndex| {
        std.mem.writeInt(u64, allocation.bytes[2 + typeIndex * 8 ..][0..8], typeCatalogReference, .little);
    }
    for (embedded, 0..) |flag, typeIndex| allocation.bytes[2 + catalogReferences.len * 8 + typeIndex] = if (flag) 1 else 0;
    return allocation.reference;
}

/// Create a directory from a full PropertyDefinition schema (supports
/// links/collections) with the given per-type embedded flags, creating one
/// catalog per type. Returns the directory reference. One catalog build per type.
pub fn createTypes(transaction: *WriteTransaction, schema: DefinitionSchema, embedded: []const bool) !Reference {
    std.debug.assert(schema.len <= 256);
    std.debug.assert(embedded.len == schema.len);
    var catalogReferences: [256]Reference = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < schema.len) : (typeIndex += 1) catalogReferences[typeIndex] = try catalog.createFromDefinitions(transaction, schema[typeIndex]);
    return writeDirectory(transaction, catalogReferences[0..schema.len], embedded);
}

/// Create a directory from a full PropertyDefinition schema (supports
/// links/collections); no type is marked embedded.
pub fn createWithDefinitions(transaction: *WriteTransaction, schema: DefinitionSchema) !Reference {
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return createTypes(transaction, schema, flags[0..schema.len]);
}

/// Create a directory from a scalar-kinds Schema; each property gets
/// element = int and no type is marked embedded.
pub fn create(transaction: *WriteTransaction, schema: Schema) !Reference {
    std.debug.assert(schema.len <= 256);
    var catalogReferences: [256]Reference = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < schema.len) : (typeIndex += 1) {
        catalogReferences[typeIndex] = try catalog.createTyped(transaction, schema[typeIndex]);
    }
    var flags: [256]bool = undefined;
    @memset(flags[0..schema.len], false);
    return writeDirectory(transaction, catalogReferences[0..schema.len], flags[0..schema.len]);
}

fn loadDirectory(transaction: anytype, directoryReference: Reference) !struct { typeCount: u16, bytes: []const u8 } {
    const tcBytes = try transaction.dereference(directoryReference, 2);
    const storedTypeCount = std.mem.readInt(u16, tcBytes[0..2], .little);
    const bytes = try transaction.dereference(directoryReference, directorySize(storedTypeCount));
    return .{ .typeCount = storedTypeCount, .bytes = bytes };
}

/// Number of types recorded in the directory at `directoryReference`.
pub fn typeCount(transaction: anytype, directoryReference: Reference) !u16 {
    const directory = try loadDirectory(transaction, directoryReference);
    return directory.typeCount;
}

/// The catalog reference of `typeId`, or error.NoSuchType past the directory's end.
pub fn catalogReference(transaction: anytype, directoryReference: Reference, typeId: u16) !Reference {
    const directory = try loadDirectory(transaction, directoryReference);
    if (typeId >= directory.typeCount) return error.NoSuchType;
    return std.mem.readInt(u64, directory.bytes[2 + @as(usize, typeId) * 8 ..][0..8], .little);
}

/// Point `typeId` at `newCatalog` and return the new directory reference
/// (copy-on-write; the caller must adopt it).
pub fn setCatalogReference(transaction: *WriteTransaction, directoryReference: Reference, typeId: u16, newCatalog: Reference) !Reference {
    const directory = try loadDirectory(transaction, directoryReference);
    if (typeId >= directory.typeCount) return error.NoSuchType;
    const allocation = try transaction.writableCopy(directoryReference, directorySize(directory.typeCount));
    std.mem.writeInt(u64, allocation.bytes[2 + @as(usize, typeId) * 8 ..][0..8], newCatalog, .little);
    return allocation.reference;
}

// Append an already-created catalog to the directory; returns grown directory + id.
// Carries the existing per-type embedded flags and appends the new type's flag.
fn appendCatalog(transaction: *WriteTransaction, oldReferences: []const Reference, oldEmbedded: []const bool, newCatalog: Reference, newEmbedded: bool) !Reference {
    std.debug.assert(oldReferences.len == oldEmbedded.len);
    const oldTc = oldReferences.len;
    var references: [256]Reference = undefined;
    var flags: [256]bool = undefined;
    var typeIndex: usize = 0;
    while (typeIndex < oldTc) : (typeIndex += 1) {
        references[typeIndex] = oldReferences[typeIndex];
        flags[typeIndex] = oldEmbedded[typeIndex];
    }
    references[oldTc] = newCatalog;
    flags[oldTc] = newEmbedded;
    return writeDirectory(transaction, references[0 .. oldTc + 1], flags[0 .. oldTc + 1]);
}

// Snapshot existing catalog references (before any file-growing create call).
fn snapshotReferences(transaction: anytype, directoryReference: Reference, out: *[256]Reference) !u16 {
    const directory = try loadDirectory(transaction, directoryReference);
    var typeIndex: usize = 0;
    while (typeIndex < directory.typeCount) : (typeIndex += 1) {
        out[typeIndex] = std.mem.readInt(u64, directory.bytes[2 + typeIndex * 8 ..][0..8], .little);
    }
    return directory.typeCount;
}

// Snapshot existing per-type embedded flags (before any file-growing call).
fn snapshotFlags(transaction: anytype, directoryReference: Reference, out: *[256]bool) !u16 {
    const directory = try loadDirectory(transaction, directoryReference);
    var typeIndex: usize = 0;
    while (typeIndex < directory.typeCount) : (typeIndex += 1) {
        out[typeIndex] = directory.bytes[2 + @as(usize, directory.typeCount) * 8 + typeIndex] != 0;
    }
    return directory.typeCount;
}

/// Outcome of adding a type: the grown directory reference and the new type's id.
pub const AddTypeResult = struct { directoryReference: Reference, typeId: u16 };

/// Append a new type from a full PropertyDefinition schema (supports
/// links/collections) and return the grown directory reference plus the new type id.
pub fn addTypeDefinitions(transaction: *WriteTransaction, directoryReference: Reference, definitions: []const PropertyDefinition) !AddTypeResult {
    return addTypeDefinitionsEmbedded(transaction, directoryReference, definitions, false);
}

/// Like addTypeDefinitions but marks the new type embedded (single-owner)
/// when `embedded` is set.
pub fn addTypeDefinitionsEmbedded(transaction: *WriteTransaction, directoryReference: Reference, definitions: []const PropertyDefinition, embedded: bool) !AddTypeResult {
    var oldReferences: [256]Reference = undefined;
    var oldFlags: [256]bool = undefined;
    const oldTc = try snapshotReferences(transaction, directoryReference, &oldReferences);
    _ = try snapshotFlags(transaction, directoryReference, &oldFlags);
    std.debug.assert(oldTc < 256);
    const newCatalog = try catalog.createFromDefinitions(transaction, definitions);
    const newDirectoryReference = try appendCatalog(transaction, oldReferences[0..oldTc], oldFlags[0..oldTc], newCatalog, embedded);
    return .{ .directoryReference = newDirectoryReference, .typeId = oldTc };
}

/// Append a new object type to the directory and return the grown directory
/// reference plus the new type id. The new type's catalog is created from the
/// scalar `typeSchema` (element = int, no links).
pub fn addType(transaction: *WriteTransaction, directoryReference: Reference, typeSchema: []const PropertyKind) !AddTypeResult {
    // Capture existing catalog references and embedded flags before createTyped, which
    // can grow the file and invalidate the directory dereference slice.
    var oldReferences: [256]Reference = undefined;
    var oldFlags: [256]bool = undefined;
    const oldTc = try snapshotReferences(transaction, directoryReference, &oldReferences);
    _ = try snapshotFlags(transaction, directoryReference, &oldFlags);
    std.debug.assert(oldTc < 256);
    const newCatalog = try catalog.createTyped(transaction, typeSchema);
    const newDirectoryReference = try appendCatalog(transaction, oldReferences[0..oldTc], oldFlags[0..oldTc], newCatalog, false);
    return .{ .directoryReference = newDirectoryReference, .typeId = oldTc };
}

/// True when `typeId` was created as an embedded (single-owner) type.
pub fn isEmbedded(transaction: anytype, directoryReference: Reference, typeId: u16) !bool {
    const directory = try loadDirectory(transaction, directoryReference);
    if (typeId >= directory.typeCount) return error.NoSuchType;
    return directory.bytes[2 + @as(usize, directory.typeCount) * 8 + typeId] != 0;
}

/// Check the directory's stored types against `expected`, failing with
/// error.SchemaMismatch on any type-count, property-count, or kind
/// difference. Walks every type's catalog, O(types x properties).
pub fn validate(transaction: anytype, directoryReference: Reference, expected: Schema) !void {
    const typeCountTotal = try typeCount(transaction, directoryReference);
    if (typeCountTotal != expected.len) return error.SchemaMismatch;
    var typeIndex: u16 = 0;
    while (typeIndex < typeCountTotal) : (typeIndex += 1) {
        const view = try catalog.loadCatalog(transaction, try catalogReference(transaction, directoryReference, typeIndex));
        if (view.propertyCount != expected[typeIndex].len) return error.SchemaMismatch;
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            if (view.kind(propertyIndex) != expected[typeIndex][propertyIndex]) return error.SchemaMismatch;
        }
    }
}

// Object/link/delete routing through the directory (the typeId -> catalog
// lookup + forward pattern) lives in typeRouting.zig.
const typeRouting = @import("typeRouting.zig");

// ---------------------------------------------------------------------------
// Embedded-object lifecycle: single-owner objects created and cleared through
// their owner via a cascade-rule to-one link.
// ---------------------------------------------------------------------------

/// Create an embedded child for the owner's to-one link `property` and link
/// it in, returning the new directory reference. If the owner already has a child
/// via `property`, the old child is deleted first (replace semantics); a
/// delete refused by a block-rule link surfaces as error.Blocked rather than
/// leaking an ownerless object.
pub fn insertEmbedded(transaction: *WriteTransaction, directoryReference: Reference, ownerType: u16, ownerPrimaryKey: u64, property: usize, childValues: []const Value) !Reference {
    var currentDirectoryReference = directoryReference;
    const childType = (try catalog.loadCatalog(transaction, try catalogReference(transaction, currentDirectoryReference, ownerType))).linkTarget(property);

    // Replace: delete any existing owned child first. A refused delete must
    // SURFACE, not be swallowed: silently linking the new child while the old
    // one survives breaks the single-owner invariant and leaks an ownerless
    // object. (.blocked is reachable when another type block-links the child;
    // conflict/notFound are impossible for a version read in this transaction.)
    if (try typeRouting.getLink(transaction, currentDirectoryReference, ownerType, ownerPrimaryKey, property)) |oldObjectKey| {
        const childCatalog = try catalogReference(transaction, currentDirectoryReference, childType);
        const propertyCount = (try catalog.loadCatalog(transaction, childCatalog)).propertyCount;
        var buffer: [256]u64 = undefined;
        if (try rows.getByObjectKey(transaction, childCatalog, oldObjectKey, buffer[0..propertyCount])) |oldVersion| {
            const oldPrimaryKey = buffer[0];
            const deleteResult = try typeRouting.deleteNullifyCrossType(transaction, currentDirectoryReference, childType, oldPrimaryKey, oldVersion);
            switch (deleteResult) {
                .ok => |directory| currentDirectoryReference = directory,
                else => return error.Blocked,
            }
        }
    }

    const ins = try typeRouting.insert(transaction, currentDirectoryReference, childType, childValues);
    currentDirectoryReference = ins.directoryReference;
    return try typeRouting.setLink(transaction, currentDirectoryReference, ownerType, ownerPrimaryKey, property, ins.objectKey);
}

/// Delete the embedded child owned via to-one link `property`, returning the
/// new directory reference (unchanged if there is no child). Deleting the child
/// cross-type-nullifies the owner's inbound link automatically; a delete
/// refused by a block-rule link surfaces as error.Blocked.
pub fn clearEmbedded(transaction: *WriteTransaction, directoryReference: Reference, ownerType: u16, ownerPrimaryKey: u64, property: usize) !Reference {
    const childObjectKey = (try typeRouting.getLink(transaction, directoryReference, ownerType, ownerPrimaryKey, property)) orelse return directoryReference;
    const childType = (try catalog.loadCatalog(transaction, try catalogReference(transaction, directoryReference, ownerType))).linkTarget(property);
    const childCatalog = try catalogReference(transaction, directoryReference, childType);
    const propertyCount = (try catalog.loadCatalog(transaction, childCatalog)).propertyCount;
    var buffer: [256]u64 = undefined;
    const childVersion = (try rows.getByObjectKey(transaction, childCatalog, childObjectKey, buffer[0..propertyCount])) orelse return directoryReference;
    const childPrimaryKey = buffer[0];
    const deleteResult = try typeRouting.deleteNullifyCrossType(transaction, directoryReference, childType, childPrimaryKey, childVersion);
    return switch (deleteResult) {
        .ok => |directory| directory,
        // A refused clear must surface: returning the unchanged directory read as
        // success while the child and its link silently survived.
        else => error.Blocked,
    };
}

test {
    _ = @import("typeDirectoryTests.zig");
}
