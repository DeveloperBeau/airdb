const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const bindex = @import("../trees/byteKeyIndex.zig");
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

// Append a new property to the type. The new column is filled with
// `default_value` for every existing row (live or tombstoned). For a link or
// link_set property a fresh backlink index is created. Returns the new catalog.
pub fn addProperty(transaction: *WriteTransaction, catalogRef: Reference, def: PropertyDefinition, default_value: u64) !Reference {
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    const propertyCount = snapshot.propertyCount;
    std.debug.assert(propertyCount + 1 <= maxPropertyCount);

    const is_collection = switch (def.kind) {
        .list, .set, .dict, .link_set => true,
        .int, .blob, .link => false,
    };
    // Indexing a collection property would index its per-row root refs --
    // meaningless as values and impossible to backfill coherently.
    if (def.indexed and is_collection) return error.Unsupported;

    const new_col = try buildBackfilledColumn(transaction, &snapshot, def, default_value, is_collection);
    const valueIndexRef: Reference = if (def.indexed) try backfillValueIndex(transaction, snapshot.keyrow_index_ref, new_col) else 0;

    snapshot.properties[propertyCount] = .{
        .col = new_col,
        .kind = def.kind,
        .element = def.element,
        .backlink = if (def.kind == .link or def.kind == .link_set) try Index.create(transaction) else 0,
        .target = def.link_target,
        .rule = def.del_rule,
        .value_index = valueIndexRef,
        .indexed = def.indexed,
    };
    snapshot.propertyCount = propertyCount + 1;
    return snapshot.replace(transaction);
}

// Build the new property's column, filled with the default for every existing
// row. Storage-bearing kinds are backfilled PER LIVE ROW, never shared.
// Collections: a raw zero root breaks every collection accessor and made
// pre-migration rows undeletable through the graph-safe delete (its outbound
// cleanup walks link_set roots), while a SHARED root would be freed by the
// first row's delete underneath every other row. Blobs have the same aliasing
// hazard: writing the caller's single default ref into every row meant the
// first row's delete freed the node under all the others, planting a
// duplicate extent in the free list -- so each live row gets its own copy of
// the default bytes (the caller keeps ownership of the passed-in ref). Dead
// rows get 0 for both; nothing ever dereferences a tombstoned row's columns.
fn buildBackfilledColumn(
    transaction: *WriteTransaction,
    snapshot: *const catalog.CatalogSnapshot,
    def: PropertyDefinition,
    default_value: u64,
    is_collection: bool,
) !Reference {
    var new_col = try Column.create(transaction);
    var row: u64 = 0;
    while (row < snapshot.next_row) : (row += 1) {
        const live = (try Column.get(transaction, snapshot.live_col_ref, row)) != 0;
        const fill: u64 = if (def.kind == .blob)
            (if (live and default_value != 0) try blobDup(transaction, default_value) else if (live) default_value else 0)
        else if (!is_collection)
            default_value
        else if (!live)
            0
        else switch (def.kind) {
            .list => try Column.create(transaction),
            .set => switch (def.element) {
                .int => try Index.create(transaction),
                .blob => try bindex.create(transaction),
            },
            .link_set => try Index.create(transaction),
            .dict => try bindex.create(transaction),
            else => unreachable,
        };
        new_col = try Column.append(transaction, new_col, fill);
    }
    return new_col;
}

// Backfill the new property's value index for existing LIVE rows: the query
// planner trusts the indexed flag, so an empty index would silently drop
// every pre-migration row from indexed queries (and fail the integrity
// audit). Each row is indexed under its OWN raw column value (mirroring the
// insert path) -- blob backfills give every row a distinct ref, so a single
// shared key would diverge from what reads and audits expect.
fn backfillValueIndex(transaction: *WriteTransaction, keyrow_ref: Reference, new_col: Reference) !Reference {
    var valueIndexRef = try Index.create(transaction);
    const Sink = struct {
        transaction: *WriteTransaction,
        valueIndexRef: *Reference,
        col: Reference,
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            const raw = try Column.get(self.transaction, self.col, row);
            self.valueIndexRef.* = try rows.valueIndexAdd(self.transaction, self.valueIndexRef.*, raw, objectKey);
        }
    };
    try Index.forEachEntry(transaction, keyrow_ref, Sink{ .transaction = transaction, .valueIndexRef = &valueIndexRef, .col = new_col }, Sink.onEntry);
    return valueIndexRef;
}

// Copy a blob's bytes into a fresh node, returning the new ref. Used by the
// blob-default backfill so no two rows share one node.
fn blobDup(transaction: *WriteTransaction, ref: u64) !u64 {
    if (blob.get(transaction, ref)) |bytes| {
        return blob.put(transaction, bytes);
    } else |err| switch (err) {
        error.BlobChunked => {
            const scratchAllocator = transaction.database.store.allocator;
            const bytes = try blob.getAlloc(transaction, ref, scratchAllocator);
            defer scratchAllocator.free(bytes);
            return blob.put(transaction, bytes);
        },
        else => return err,
    }
}

// Remove property `property` (must be >= 1; the primary key at 0 cannot be removed).
// The dropped column is left for compaction to reclaim. Returns the new catalog.
pub fn removeProperty(transaction: *WriteTransaction, catalogRef: Reference, property: usize) !Reference {
    std.debug.assert(property >= 1);
    var snapshot = try catalog.CatalogSnapshot.load(transaction, catalogRef);
    std.debug.assert(property < snapshot.propertyCount);
    var propertyIndex: usize = property;
    while (propertyIndex + 1 < snapshot.propertyCount) : (propertyIndex += 1) snapshot.properties[propertyIndex] = snapshot.properties[propertyIndex + 1];
    snapshot.propertyCount -= 1;
    return snapshot.replace(transaction);
}

test {
    _ = @import("migrationsTests.zig");
}
