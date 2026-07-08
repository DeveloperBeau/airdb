// objects.zig -- typed encode/decode orchestration over the raw row layer.
//
// Encodes []Value rows into raw u64 storage (allocating blob and collection
// structures), decodes them back, and keeps the link graph consistent
// (backlinks, nullify-on-delete). The raw column/index CRUD it drives lives
// below this in rows.zig.

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

/// Result types shared with the raw layer: the typed update/delete return the
/// same shapes rows.update/rows.delete produce.
pub const Conflict = rows.Conflict;
pub const UpdateResult = rows.UpdateResult;
pub const DeleteResult = rows.DeleteResult;

// insertTyped encodes a []Value row into raw u64 storage, allocating a blob
// node for each .blob property, then delegates to rows.insert.
pub fn insertTyped(transaction: *WriteTransaction, catalogRef: Reference, values: []const Value) !struct { catalogRef: Reference, row: u64 } {
    const view = try loadCatalog(transaction, catalogRef);
    const propertyCount = view.propertyCount;
    std.debug.assert(values.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds and elements into local buffers before any mutation that could
    // invalidate the deref slice backing CatalogView.
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
                .int => try collections.buildListInt(transaction, values[propertyIndex].list_int),
                .blob => try collections.buildListBlob(transaction, values[propertyIndex].list_blob),
            },
            .set => switch (elements[propertyIndex]) {
                .int => try collections.buildSetInt(transaction, values[propertyIndex].set_int),
                .blob => try collections.buildSetBlob(transaction, values[propertyIndex].set_blob),
            },
            .dict => try collections.buildDict(transaction, values[propertyIndex].dict_int),
            .link => if (values[propertyIndex].link) |target| target + 1 else 0,
            .link_set => try collections.buildSetInt(transaction, values[propertyIndex].link_set),
        };
    }
    const result = try rows.insert(transaction, catalogRef, raw[0..propertyCount]);
    // Maintain backlinks for any links the new row carries.
    var updatedCatalog = result.catalogRef;
    {
        var linkIndex: usize = 0;
        while (linkIndex < propertyCount) : (linkIndex += 1) {
            switch (kinds[linkIndex]) {
                .link => {
                    if (values[linkIndex].link) |target| {
                        updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, target, result.row);
                    }
                },
                .link_set => {
                    for (values[linkIndex].link_set) |target| {
                        updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, target, result.row);
                    }
                },
                else => {},
            }
        }
    }
    return .{ .catalogRef = updatedCatalog, .row = result.row };
}

// getTyped reads a row by primary key and decodes each property into a Value.
// A small .blob property decodes to a zero-copy .bytes slice into the mapped
// storage; a blob larger than the inline cap (stored chunked) decodes to a
// .blob_ref the caller materializes with blob.getAlloc.
// Returns the row version, or null when the key is not found.
pub fn getTyped(transaction: anytype, catalogRef: Reference, primaryKey: u64, out: []Value) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
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
    const version = (try rows.getByPrimaryKey(transaction, catalogRef, primaryKey, raw[0..propertyCount])) orelse return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        out[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => .{ .int = raw[propertyIndex] },
            .blob => if (blob.get(transaction, raw[propertyIndex])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blob_ref = raw[propertyIndex] },
                else => return err,
            },
            .list, .set, .dict, .link_set => .{ .coll_root = raw[propertyIndex] },
            .link => .{ .link = if (raw[propertyIndex] == 0) null else raw[propertyIndex] - 1 },
        };
    }
    return version;
}

// getTypedByObjectKey decodes a row addressed by stable object key into Values.
pub fn getTypedByObjectKey(transaction: anytype, catalogRef: Reference, objectKey: u64, out: []Value) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
    const propertyCount = view.propertyCount;
    std.debug.assert(out.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) kinds[propertyIndex] = view.kind(propertyIndex);
    }
    var raw: [maxPropertyCount]u64 = undefined;
    const version = (try rows.getByObjectKey(transaction, catalogRef, objectKey, raw[0..propertyCount])) orelse return null;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        out[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => .{ .int = raw[propertyIndex] },
            .blob => if (blob.get(transaction, raw[propertyIndex])) |slice| .{ .bytes = slice } else |err| switch (err) {
                error.BlobChunked => .{ .blob_ref = raw[propertyIndex] },
                else => return err,
            },
            .list, .set, .dict, .link_set => .{ .coll_root = raw[propertyIndex] },
            .link => .{ .link = if (raw[propertyIndex] == 0) null else raw[propertyIndex] - 1 },
        };
    }
    return version;
}

// Delete an object and keep the graph consistent: nullify inbound links and
// clean the deleted object's outbound backlink entries.
pub fn deleteAndNullify(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, expected_version: u64) !DeleteResult {
    const view = try loadCatalog(transaction, catalogRef);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexRef, primaryKey)) orelse return .not_found;
    const row = (try catalog.objectKeyToRow(transaction, catalogRef, objectKey)) orelse return .not_found;
    const currentVersion = try Column.get(transaction, view.version_col_ref, row);
    if (currentVersion != expected_version) return .{ .conflict = .{ .current_version = currentVersion } };
    const fixed = try links.fixBacklinksForDelete(transaction, catalogRef, objectKey);
    return try rows.delete(transaction, fixed, primaryKey, expected_version);
}

// updateTyped is MVCC-safe: it does NOT free any blob unless the version check
// passes. Steps: read current row, check version, then on the apply path free
// old blobs and allocate new ones before delegating to rows.update.
// Deliberately one long function: the read/check/free/allocate/update sequence
// is one irreducible MVCC step -- splitting it would scatter the frees from
// the version check that alone makes them safe.
pub fn updateTyped(
    transaction: *WriteTransaction,
    catalogRef: Reference,
    primaryKey: u64,
    values: []const Value,
    expected_version: u64,
) !UpdateResult {
    const view = try loadCatalog(transaction, catalogRef);
    const propertyCount = view.propertyCount;
    std.debug.assert(values.len == propertyCount);
    std.debug.assert(propertyCount <= maxPropertyCount);
    // Capture kinds before any mutation.
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) kinds[propertyIndex] = view.kind(propertyIndex);
    }
    // Step 1: read the current row into cur_raw.
    var cur_raw: [maxPropertyCount]u64 = undefined;
    const current_version = (try rows.getByPrimaryKey(transaction, catalogRef, primaryKey, cur_raw[0..propertyCount])) orelse return .not_found;
    // Step 2: version check BEFORE freeing or allocating any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: apply path -- free old blobs and allocate new ones. Collection
    // properties are CARRIED THROUGH unchanged (mutate them via their own
    // APIs): updating any row of a collection-bearing type must not require
    // the caller to re-supply roots, and must never crash.
    var new_raw: [maxPropertyCount]u64 = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        new_raw[propertyIndex] = switch (kinds[propertyIndex]) {
            .int => values[propertyIndex].int,
            .blob => blk: {
                try blob.free(transaction, cur_raw[propertyIndex]);
                break :blk try blob.put(transaction, values[propertyIndex].bytes);
            },
            .list, .set, .dict, .link_set => cur_raw[propertyIndex],
            .link => if (values[propertyIndex].link) |target| target + 1 else 0,
        };
    }
    // Step 4: delegate to the core update; it will re-check the version (match).
    const result = try rows.update(transaction, catalogRef, primaryKey, new_raw[0..propertyCount], expected_version);
    // Step 5: maintain backlinks for any changed to-one link, mirroring
    // setLink. Skipping this left the old target's backlink set naming this
    // source forever and the new target's set missing it -- corrupting
    // nullify/cascade/block enforcement. The backlink source is the objectKey.
    switch (result) {
        .ok => |ok| {
            var updatedCatalog = ok.catalogRef;
            var changed = false;
            var linkIndex: usize = 0;
            while (linkIndex < propertyCount) : (linkIndex += 1) {
                if (kinds[linkIndex] != .link or cur_raw[linkIndex] == new_raw[linkIndex]) continue;
                // The row was just updated successfully, so its primaryKey must
                // resolve; anything else is index divergence, and bailing
                // mid-loop would leave the backlinks half-moved.
                const objectKey = (try catalog.primaryKeyToObjectKey(transaction, updatedCatalog, primaryKey)) orelse return error.Corrupt;
                if (cur_raw[linkIndex] != 0) updatedCatalog = try links.removeBacklink(transaction, updatedCatalog, linkIndex, cur_raw[linkIndex] - 1, objectKey);
                if (new_raw[linkIndex] != 0) updatedCatalog = try links.addBacklink(transaction, updatedCatalog, linkIndex, new_raw[linkIndex] - 1, objectKey);
                changed = true;
            }
            if (changed) return .{ .ok = .{ .catalogRef = updatedCatalog, .version = ok.version } };
            return result;
        },
        else => return result,
    }
}

// deleteTyped is MVCC-safe: blobs are freed only on the apply path, never on
// conflict or not_found.
pub fn deleteTyped(
    transaction: *WriteTransaction,
    catalogRef: Reference,
    primaryKey: u64,
    expected_version: u64,
) !DeleteResult {
    const view = try loadCatalog(transaction, catalogRef);
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
    var cur_raw: [maxPropertyCount]u64 = undefined;
    const current_version = (try rows.getByPrimaryKey(transaction, catalogRef, primaryKey, cur_raw[0..propertyCount])) orelse return .not_found;
    // Step 2: version check BEFORE freeing any blob.
    if (current_version != expected_version)
        return .{ .conflict = .{ .current_version = current_version } };
    // Step 3: delegate to the graph-safe delete (nullifies inbound links).
    const result = try deleteAndNullify(transaction, catalogRef, primaryKey, expected_version);
    // Step 4: on the apply path, free the row's blob and collection storage.
    // This runs AFTER deleteAndNullify because the outbound backlink cleanup
    // reads the link_set roots; the tombstoned row's columns still hold the
    // roots, so cur_raw stays accurate. Without this every deleted row leaked
    // its blobs and list/set/dict trees (and their element/key blobs)
    // permanently. MVCC-safe: a conflict or not_found result frees nothing.
    switch (result) {
        .ok => try rows.freeRowStorage(transaction, kinds[0..propertyCount], elements[0..propertyCount], cur_raw[0..propertyCount]),
        else => {},
    }
    return result;
}

test {
    _ = @import("objectsTests.zig");
}
