//! Typed encode/decode orchestration over the raw row layer.
//!
//! Encodes []Value rows into raw u64 storage (allocating blob and collection
//! structures), decodes them back, and keeps the link graph consistent
//! (backlinks, nullify-on-delete). The raw column/index CRUD it drives lives
//! below this in rows.zig.

const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const blob = @import("blob.zig");
const catalog = @import("../schema/catalog.zig");
const collections = @import("collections.zig");
const links = @import("links.zig");
const rows = @import("rows.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const Value = catalog.Value;
const maxPropertyCount = catalog.maxPropertyCount;

const loadCatalog = catalog.loadCatalog;

/// The row's current version, reported when an optimistic write loses the
/// race (shared with the raw row layer).
pub const Conflict = rows.Conflict;
/// Outcome of a typed update -- the same shape rows.update produces.
pub const UpdateResult = rows.UpdateResult;
/// Outcome of a typed delete -- the same shape rows.delete produces.
pub const DeleteResult = rows.DeleteResult;

/// Encode a []Value row into raw u64 storage -- allocating a blob node for
/// each .blob property and building each collection's tree -- then insert it
/// via rows.insert, maintaining backlinks for any links the row carries.
/// Returns the new catalog reference and the row's stable object key. One tree walk
/// per property plus collection builds proportional to their element counts.
pub fn insertTyped(transaction: *WriteTransaction, catalogReference: Reference, values: []const Value) !struct { catalogReference: Reference, objectKey: u64 } {
    const view = try loadCatalog(transaction, catalogReference);
    const propertyCount = view.propertyCount;
    std.debug.assert(values.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds and elements into local buffers before any mutation that could
    // invalidate the dereference slice backing CatalogView.
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    var elements: [maxPropertyCount]ElementKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            kinds[propertyIndex] = view.kind(propertyIndex);
            elements[propertyIndex] = view.elementKind(propertyIndex);
        }
    }
    var raw: [maxPropertyCount]u64 = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        raw[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => values[propertyIndex].int,
            .blob => try blob.put(transaction, values[propertyIndex].bytes),
            .list => switch (elements[propertyIndex]) {
                .int => try collections.buildListInt(transaction, values[propertyIndex].listInt),
                .blob => try collections.buildListBlob(transaction, values[propertyIndex].listBlob),
            },
            .set => switch (elements[propertyIndex]) {
                .int => try collections.buildSetInt(transaction, values[propertyIndex].setInt),
                .blob => try collections.buildSetBlob(transaction, values[propertyIndex].setBlob),
            },
            .dict => try collections.buildDict(transaction, values[propertyIndex].dictInt),
            .link => if (values[propertyIndex].link) |target| target + 1 else 0,
            .linkSet => try collections.buildSetInt(transaction, values[propertyIndex].linkSet),
        };
    }
    const result = try rows.insert(transaction, catalogReference, raw[0..propertyCount]);
    // Maintain backlinks for any links the new row carries.
    var updatedCatalog = result.catalogReference;
    {
        var linkIndex: usize = 0;
        while (linkIndex < propertyCount) : (linkIndex += 1) {
            switch (kinds[linkIndex]) {
                .link => {
                    if (values[linkIndex].link) |target| {
                        updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, target, result.objectKey);
                    }
                },
                .linkSet => {
                    for (values[linkIndex].linkSet) |target| {
                        updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, target, result.objectKey);
                    }
                },
                else => {},
            }
        }
    }
    return .{ .catalogReference = updatedCatalog, .objectKey = result.objectKey };
}

/// Read a row by primary key and decode each property into `out` as a Value.
/// A small .blob property decodes to a zero-copy .bytes slice into the mapped
/// storage (valid until the next mutating call on the transaction); a blob
/// larger than the inline cap (stored chunked) decodes to a .blobReference the
/// caller materializes with blob.getAlloc. Returns the row version, or null
/// when the key is not found. One tree walk per property (O(log n) each).
pub fn getTyped(transaction: anytype, catalogReference: Reference, primaryKey: u64, out: []Value) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    const propertyCount = view.propertyCount;
    std.debug.assert(out.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds before the getByPrimaryKey call may touch other catalog nodes.
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) kinds[propertyIndex] = view.kind(propertyIndex);
    }
    var raw: [maxPropertyCount]u64 = undefined;
    const version = (try rows.getByPrimaryKey(transaction, catalogReference, primaryKey, raw[0..propertyCount])) orelse return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        out[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => .{ .int = raw[propertyIndex] },
            .blob => if (blob.get(transaction, raw[propertyIndex])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blobReference = raw[propertyIndex] },
                else => return err,
            },
            .list, .set, .dict, .linkSet => .{ .collectionRoot = raw[propertyIndex] },
            .link => .{ .link = if (raw[propertyIndex] == 0) null else raw[propertyIndex] - 1 },
        };
    }
    return version;
}

/// Read a row addressed by its stable object key and decode each property
/// into `out` as a Value; blob decoding follows the getTyped rules. Returns
/// the row version, or null when the objectKey is unknown or the row is
/// tombstoned. One tree walk per property (O(log n) each).
pub fn getTypedByObjectKey(transaction: anytype, catalogReference: Reference, objectKey: u64, out: []Value) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    const propertyCount = view.propertyCount;
    std.debug.assert(out.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) kinds[propertyIndex] = view.kind(propertyIndex);
    }
    var raw: [maxPropertyCount]u64 = undefined;
    const version = (try rows.getByObjectKey(transaction, catalogReference, objectKey, raw[0..propertyCount])) orelse return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        out[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => .{ .int = raw[propertyIndex] },
            .blob => if (blob.get(transaction, raw[propertyIndex])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blobReference = raw[propertyIndex] },
                else => return err,
            },
            .list, .set, .dict, .linkSet => .{ .collectionRoot = raw[propertyIndex] },
            .link => .{ .link = if (raw[propertyIndex] == 0) null else raw[propertyIndex] - 1 },
        };
    }
    return version;
}

/// Delete an object and keep the link graph consistent: nullify inbound links
/// and clean the deleted object's outbound backlink entries before the
/// tombstone. Version-guarded like rows.delete. Cost scales with the row's
/// inbound and outbound link counts.
pub fn deleteAndNullify(transaction: *WriteTransaction, catalogReference: Reference, primaryKey: u64, expectedVersion: u64) !DeleteResult {
    const view = try loadCatalog(transaction, catalogReference);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexReference, primaryKey)) orelse return .notFound;
    const row = (try catalog.objectKeyToRow(transaction, catalogReference, objectKey)) orelse return .notFound;
    const currentVersion = try Column.get(transaction, view.versionColumnReference, row);
    if (currentVersion != expectedVersion) return .{ .conflict = .{ .currentVersion = currentVersion } };
    const fixed = try links.fixBacklinksForDelete(transaction, catalogReference, objectKey);
    return try rows.delete(transaction, fixed, primaryKey, expectedVersion);
}

/// Overwrite an object's properties from `values`, guarded by the row's
/// expected version, and return the update outcome. Collection properties are
/// carried through unchanged (mutate them via their own APIs); changed to-one
/// links re-point their backlink entries. One tree walk per property.
///
/// MVCC-safe: it does NOT free any blob unless the version check passes.
/// Steps: read current row, check version, then on the apply path free old
/// blobs and allocate new ones before delegating to rows.update.
/// Deliberately one long function: the read/check/free/allocate/update
/// sequence is one irreducible MVCC step -- splitting it would scatter the
/// frees from the version check that alone makes them safe.
pub fn updateTyped(
    transaction: *WriteTransaction,
    catalogReference: Reference,
    primaryKey: u64,
    values: []const Value,
    expectedVersion: u64,
) !UpdateResult {
    const view = try loadCatalog(transaction, catalogReference);
    const propertyCount = view.propertyCount;
    std.debug.assert(values.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds before any mutation.
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) kinds[propertyIndex] = view.kind(propertyIndex);
    }
    // Step 1: read the current row into curRaw.
    var curRaw: [maxPropertyCount]u64 = undefined;
    const currentVersion = (try rows.getByPrimaryKey(transaction, catalogReference, primaryKey, curRaw[0..propertyCount])) orelse return .notFound;
    // Step 2: version check BEFORE freeing or allocating any blob.
    if (currentVersion != expectedVersion)
        return .{ .conflict = .{ .currentVersion = currentVersion } };
    // Step 3: apply path -- free old blobs and allocate new ones. Collection
    // properties are CARRIED THROUGH unchanged (mutate them via their own
    // APIs): updating any row of a collection-bearing type must not require
    // the caller to re-supply roots, and must never crash.
    var newRaw: [maxPropertyCount]u64 = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        newRaw[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => values[propertyIndex].int,
            .blob => blk: {
                try blob.free(transaction, curRaw[propertyIndex]);
                break :blk try blob.put(transaction, values[propertyIndex].bytes);
            },
            .list, .set, .dict, .linkSet => curRaw[propertyIndex],
            .link => if (values[propertyIndex].link) |target| target + 1 else 0,
        };
    }
    // Step 4: delegate to the core update; it will re-check the version (match).
    const result = try rows.update(transaction, catalogReference, primaryKey, newRaw[0..propertyCount], expectedVersion);
    // Step 5: maintain backlinks for any changed to-one link, mirroring
    // setLink. Skipping this left the old target's backlink set naming this
    // source forever and the new target's set missing it -- corrupting
    // nullify/cascade/block enforcement. The backlink source is the objectKey.
    switch (result) {
        .ok => |ok| {
            var updatedCatalog = ok.catalogReference;
            var changed = false;
            var linkIndex: usize = 0;
            while (linkIndex < propertyCount) : (linkIndex += 1) {
                if (kinds[linkIndex] != .link or curRaw[linkIndex] == newRaw[linkIndex]) continue;
                // The row was just updated successfully, so its primaryKey must
                // resolve; anything else is index divergence, and bailing
                // mid-loop would leave the backlinks half-moved.
                const objectKey = (try catalog.primaryKeyToObjectKey(transaction, updatedCatalog, primaryKey)) orelse return error.Corrupt;
                if (curRaw[linkIndex] != 0) updatedCatalog = try links.removeBacklink(transaction, updatedCatalog, linkIndex, curRaw[linkIndex] - 1, objectKey);
                if (newRaw[linkIndex] != 0) updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, newRaw[linkIndex] - 1, objectKey);
                changed = true;
            }
            if (changed) return .{ .ok = .{ .catalogReference = updatedCatalog, .version = ok.version } };
            return result;
        },
        else => return result,
    }
}

/// Delete an object, fix its link graph (via deleteAndNullify), and reclaim
/// its blob and collection storage, all guarded by the row's expected
/// version. MVCC-safe: blobs are freed only on the apply path, never on
/// conflict or notFound. Cost scales with the row's property, link, and
/// collection sizes.
pub fn deleteTyped(
    transaction: *WriteTransaction,
    catalogReference: Reference,
    primaryKey: u64,
    expectedVersion: u64,
) !DeleteResult {
    const view = try loadCatalog(transaction, catalogReference);
    const propertyCount = view.propertyCount;
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds/elements before any mutation.
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    var elements: [maxPropertyCount]ElementKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            kinds[propertyIndex] = view.kind(propertyIndex);
            elements[propertyIndex] = view.elementKind(propertyIndex);
        }
    }
    // Step 1: read the current row.
    var curRaw: [maxPropertyCount]u64 = undefined;
    const currentVersion = (try rows.getByPrimaryKey(transaction, catalogReference, primaryKey, curRaw[0..propertyCount])) orelse return .notFound;
    // Step 2: version check BEFORE freeing any blob.
    if (currentVersion != expectedVersion)
        return .{ .conflict = .{ .currentVersion = currentVersion } };
    // Step 3: delegate to the graph-safe delete (nullifies inbound links).
    const result = try deleteAndNullify(transaction, catalogReference, primaryKey, expectedVersion);
    // Step 4: on the apply path, free the row's blob and collection storage.
    // This runs AFTER deleteAndNullify because the outbound backlink cleanup
    // reads the linkSet roots; the tombstoned row's columns still hold the
    // roots, so curRaw stays accurate. Without this every deleted row leaked
    // its blobs and list/set/dict trees (and their element/key blobs)
    // permanently. MVCC-safe: a conflict or notFound result frees nothing.
    switch (result) {
        .ok => try rows.freeRowStorage(transaction, kinds[0..propertyCount], elements[0..propertyCount], curRaw[0..propertyCount]),
        else => {},
    }
    return result;
}

test {
    _ = @import("objectsTests.zig");
}
