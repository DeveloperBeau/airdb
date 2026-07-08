const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const byteKeyIndex = @import("../trees/byteKeyIndex.zig");
const catalog = @import("catalog.zig");
const blob = @import("../records/blob.zig");
const rows = @import("../records/rows.zig");

const PropertyKind = catalog.PropertyKind;
const ElementKind = catalog.ElementKind;
const PropertyDefinition = catalog.PropertyDefinition;
const Value = catalog.Value;
const PropertyCount = catalog.PropertyCount;
const CatalogView = catalog.CatalogView;
const maxPropertyCount = catalog.maxPropertyCount;

// ---------------------------------------------------------------------------
// Migrations (structural schema evolution)
//
// The catalog stores properties by position, not name, so renaming is a no-op
// at this layer (names live in the binding/schema layer). Add and remove
// rewrite the catalog transactionally (COW); existing snapshots are unaffected.
// ---------------------------------------------------------------------------

/// Append a new property to the type and return the new catalog reference. The new
/// column is backfilled for every existing row: live rows get `defaultValue`
/// (blob defaults are copied per row; collection kinds get a fresh empty
/// tree each) and dead rows get 0. A link or linkSet property gets a fresh
/// backlink index; an indexed property gets its value index backfilled from
/// the live rows. Indexing a collection kind is error.Unsupported. O(n) over
/// every existing row, live or tombstoned.
pub fn addProperty(transaction: *WriteTransaction, catalogReference: Reference, def: PropertyDefinition, defaultValue: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    const propertyCount = snapshot.propertyCount;
    std.debug.assert(propertyCount + 1 <= maxPropertyCount);

    const isCollection = switch (def.kind) {
        .list, .set, .dict, .linkSet => true,
        .int, .blob, .link => false,
    };
    // Indexing a collection property would index its per-row root references --
    // meaningless as values and impossible to backfill coherently.
    if (def.indexed and isCollection) return error.Unsupported;

    const newColumn = try buildBackfilledColumn(transaction, &snapshot, def, defaultValue, isCollection);
    const valueIndexReference: Reference = if (def.indexed) try backfillValueIndex(transaction, snapshot.keyToRowIndexReference, newColumn) else 0;

    snapshot.properties[propertyCount] = .{
        .column = newColumn,
        .kind = def.kind,
        .element = def.element,
        .backlink = if (def.kind == .link or def.kind == .linkSet) try Index.create(transaction) else 0,
        .target = def.linkTarget,
        .rule = def.deletionRule,
        .valueIndex = valueIndexReference,
        .indexed = def.indexed,
    };
    snapshot.propertyCount = propertyCount + 1;
    return snapshot.replace(transaction);
}

// Build the new property's column, filled with the default for every existing
// row. Storage-bearing kinds are backfilled PER LIVE ROW, never shared.
// Collections: a raw zero root breaks every collection accessor and made
// pre-migration rows undeletable through the graph-safe delete (its outbound
// cleanup walks linkSet roots), while a SHARED root would be freed by the
// first row's delete underneath every other row. Blobs have the same aliasing
// hazard: writing the caller's single default reference into every row meant the
// first row's delete freed the node under all the others, planting a
// duplicate extent in the free list -- so each live row gets its own copy of
// the default bytes (the caller keeps ownership of the passed-in reference). Dead
// rows get 0 for both; nothing ever dereferences a tombstoned row's columns.
fn buildBackfilledColumn(
    transaction: *WriteTransaction,
    snapshot: *const catalog.CatalogSnapshot,
    def: PropertyDefinition,
    defaultValue: u64,
    isCollection: bool,
) !Reference {
    var newColumn = try Column.create(transaction);
    var row: u64 = 0;
    while (row < snapshot.nextRow) : (row += 1) {
        const live = (try Column.get(transaction, snapshot.liveColumnReference, row)) != 0;
        const fill: u64 = if (def.kind == .blob)
            (if (live and defaultValue != 0) try blobDup(transaction, defaultValue) else if (live) defaultValue else 0)
        else if (!isCollection)
            defaultValue
        else if (!live)
            0
        else switch (def.kind) {
            .list => try Column.create(transaction),
            .set => switch (def.element) {
                .int => try Index.create(transaction),
                .blob => try byteKeyIndex.create(transaction),
            },
            .linkSet => try Index.create(transaction),
            .dict => try byteKeyIndex.create(transaction),
            else => unreachable,
        };
        newColumn = try Column.append(transaction, newColumn, fill);
    }
    return newColumn;
}

// Backfill the new property's value index for existing LIVE rows: the query
// planner trusts the indexed flag, so an empty index would silently drop
// every pre-migration row from indexed queries (and fail the integrity
// audit). Each row is indexed under its OWN raw column value (mirroring the
// insert path) -- blob backfills give every row a distinct reference, so a single
// shared key would diverge from what reads and audits expect.
fn backfillValueIndex(transaction: *WriteTransaction, keyToRowIndexReference: Reference, newColumn: Reference) !Reference {
    var valueIndexReference = try Index.create(transaction);
    const Sink = struct {
        transaction: *WriteTransaction,
        valueIndexReference: *Reference,
        column: Reference,
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            const raw = try Column.get(self.transaction, self.column, row);
            self.valueIndexReference.* = try rows.valueIndexAdd(self.transaction, self.valueIndexReference.*, raw, objectKey);
        }
    };
    try Index.forEachEntry(transaction, keyToRowIndexReference, Sink{ .transaction = transaction, .valueIndexReference = &valueIndexReference, .column = newColumn }, Sink.onEntry);
    return valueIndexReference;
}

// Copy a blob's bytes into a fresh node, returning the new reference. Used by the
// blob-default backfill so no two rows share one node.
fn blobDup(transaction: *WriteTransaction, reference: u64) !u64 {
    if (blob.get(transaction, reference)) |bytes| {
        return blob.put(transaction, bytes);
    } else |err| switch (err) {
        error.BlobChunked => {
            const scratchAllocator = transaction.database.store.allocator;
            const bytes = try blob.getAlloc(transaction, reference, scratchAllocator);
            defer scratchAllocator.free(bytes);
            return blob.put(transaction, bytes);
        },
        else => return err,
    }
}

/// Remove property `property` (must be >= 1; the primary key at 0 cannot be
/// removed) and return the new catalog reference. The dropped column's storage is
/// left for compaction to reclaim. O(propertyCount) catalog rewrite.
pub fn removeProperty(transaction: *WriteTransaction, catalogReference: Reference, property: usize) !Reference {
    std.debug.assert(property >= 1);
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogReference);
    std.debug.assert(property < snapshot.propertyCount);
    var propertyIndex: usize = property;
    while (propertyIndex + 1 < snapshot.propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex] = snapshot.properties[propertyIndex + 1];
    snapshot.propertyCount -= 1;
    return snapshot.replace(transaction);
}

test {
    _ = @import("migrationsTests.zig");
}
