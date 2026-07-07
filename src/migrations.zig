const std = @import("std");
const WriteTxn = @import("db.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("bindex.zig");
const catalog = @import("catalog.zig");
const blob = @import("blob.zig");
const rows = @import("rows.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

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
pub fn addProperty(txn: *WriteTxn, cat: Ref, def: PropDef, default_value: u64) !Ref {
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    const pc = s.prop_count;
    std.debug.assert(pc + 1 <= max_prop_count);

    const is_collection = switch (def.kind) {
        .list, .set, .dict, .link_set => true,
        .int, .blob, .link => false,
    };
    // Indexing a collection property would index its per-row root refs --
    // meaningless as values and impossible to backfill coherently.
    if (def.indexed and is_collection) return error.Unsupported;

    // Build the new column. Storage-bearing kinds are backfilled PER LIVE
    // ROW, never shared. Collections: a raw zero root breaks every collection
    // accessor and made pre-migration rows undeletable through the graph-safe
    // delete (its outbound cleanup walks link_set roots), while a SHARED root
    // would be freed by the first row's delete underneath every other row.
    // Blobs have the same aliasing hazard: writing the caller's single
    // default ref into every row meant the first row's delete freed the node
    // under all the others, planting a duplicate extent in the free list --
    // so each live row gets its own copy of the default bytes (the caller
    // keeps ownership of the passed-in ref). Dead rows get 0 for both;
    // nothing ever dereferences a tombstoned row's columns.
    var new_col = try Column.create(txn);
    var i: u64 = 0;
    while (i < s.next_row) : (i += 1) {
        const live = (try Column.get(txn, s.live_col_ref, i)) != 0;
        const fill: u64 = if (def.kind == .blob)
            (if (live and default_value != 0) try blobDup(txn, default_value) else if (live) default_value else 0)
        else if (!is_collection)
            default_value
        else if (!live)
            0
        else switch (def.kind) {
            .list => try Column.create(txn),
            .set => switch (def.elem) {
                .int => try Index.create(txn),
                .blob => try bindex.create(txn),
            },
            .link_set => try Index.create(txn),
            .dict => try bindex.create(txn),
            else => unreachable,
        };
        new_col = try Column.append(txn, new_col, fill);
    }

    // Backfill the value index for existing LIVE rows: the query planner
    // trusts the indexed flag, so an empty index would silently drop every
    // pre-migration row from indexed queries (and fail the integrity audit).
    // Each row is indexed under its OWN raw column value (mirroring the
    // insert path) -- blob backfills give every row a distinct ref, so a
    // single shared key would diverge from what reads and audits expect.
    var vi: Ref = 0;
    if (def.indexed) {
        vi = try Index.create(txn);
        const Sink = struct {
            txn: *WriteTxn,
            vi: *Ref,
            col: Ref,
            fn onEntry(self: @This(), okey: u64, row: u64) anyerror!void {
                const raw = try Column.get(self.txn, self.col, row);
                self.vi.* = try rows.viAdd(self.txn, self.vi.*, raw, okey);
            }
        };
        try Index.forEachEntry(txn, s.keyrow_index_ref, Sink{ .txn = txn, .vi = &vi, .col = new_col }, Sink.onEntry);
    }

    s.props[pc] = .{
        .col = new_col,
        .kind = def.kind,
        .elem = def.elem,
        .backlink = if (def.kind == .link or def.kind == .link_set) try Index.create(txn) else 0,
        .target = def.link_target,
        .rule = def.del_rule,
        .value_index = vi,
        .indexed = def.indexed,
    };
    s.prop_count = pc + 1;
    return s.replace(txn);
}

// Copy a blob's bytes into a fresh node, returning the new ref. Used by the
// blob-default backfill so no two rows share one node.
fn blobDup(txn: *WriteTxn, ref: u64) !u64 {
    if (blob.get(txn, ref)) |bytes| {
        return blob.put(txn, bytes);
    } else |err| switch (err) {
        error.BlobChunked => {
            const alloc = txn.db.store.allocator;
            const bytes = try blob.getAlloc(txn, ref, alloc);
            defer alloc.free(bytes);
            return blob.put(txn, bytes);
        },
        else => |e| return e,
    }
}

// Remove property `prop` (must be >= 1; the primary key at 0 cannot be removed).
// The dropped column is left for compaction to reclaim. Returns the new catalog.
pub fn removeProperty(txn: *WriteTxn, cat: Ref, prop: usize) !Ref {
    std.debug.assert(prop >= 1);
    var s = try catalog.CatalogSnapshot.load(txn, cat);
    std.debug.assert(prop < s.prop_count);
    var j: usize = prop;
    while (j + 1 < s.prop_count) : (j += 1) s.props[j] = s.props[j + 1];
    s.prop_count -= 1;
    return s.replace(txn);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("migrationsTests.zig");
}
