// verification.zig -- offline integrity audit of a database instance.
//
// Checks the header, commit slots, root ref, and free list for structural
// sanity, then audits every value index and backlink index against the live
// base rows in both directions. Read-only; nothing inner imports this file.

const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");
const Slot = @import("storage/slots.zig").Slot;
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const ReadTransaction = @import("transactions/readTransaction.zig").ReadTransaction;
const slot_a_off = @import("database.zig").slot_a_off;
const slot_b_off = @import("database.zig").slot_b_off;
const typedir = @import("schema/typeDirectory.zig");
const catalog = @import("schema/catalog.zig");
const Column = @import("trees/column.zig");
const Index = @import("trees/index.zig");

/// Everything verifyIntegrity can report about a damaged database.
pub const VerifyError = error{
    HeaderCorrupt,
    SlotCorrupt,
    FreeListCorrupt,
    FreeExtentOutOfBounds,
    RootRefOutOfBounds,
    // A live row's indexed property value is not reflected in that property's
    // value index (forward direction of the value-index invariant).
    ValueIndexMissingEntry,
    // A value-index entry points at a dead/absent row, or at a live row whose
    // property value differs from the indexed value (backward direction).
    ValueIndexStaleEntry,
    // A live row's outbound link/link_set target is missing from the target's
    // backlink set (forward direction of the backlink invariant).
    BacklinkMissingEntry,
    // A backlink entry names a source that is dead/absent or whose link column
    // does not actually point at the target (backward direction).
    BacklinkStaleEntry,
};

/// Audit the database's structural invariants and every value/backlink index.
/// O(total entries) across all indexed and link-bearing types; reads the whole
/// live data set.
pub fn verifyIntegrity(database: *Database) VerifyError!void {
    if (!database.store.header_checksum_ok) return error.HeaderCorrupt;

    const a_ok = Slot.decode(database.store.map[slot_a_off .. slot_a_off + Slot.size]) catch null;
    const b_ok = Slot.decode(database.store.map[slot_b_off .. slot_b_off + Slot.size]) catch null;
    if (a_ok == null and b_ok == null) return error.SlotCorrupt;

    const limit = database.store.sectionsView().len * platform.section_size;

    if (database.active_root != 0) {
        const rootRef: usize = @intCast(database.active_root);
        if (rootRef % 8 != 0 or rootRef >= limit) return error.RootRefOutOfBounds;
    }

    if (database.free_list_node_ref != 0) {
        const nodeRef: usize = @intCast(database.free_list_node_ref);
        if (nodeRef % 8 != 0 or nodeRef + database.free_list_node_len > limit) return error.FreeListCorrupt;
    }

    for (database.free_list.extents.items) |extent| {
        const extentOffset: usize = @intCast(extent.offset);
        if (extent.len == 0) return error.FreeExtentOutOfBounds;
        if (extentOffset % 8 != 0) return error.FreeExtentOutOfBounds;
        const elen: usize = @intCast(extent.len);
        if (extentOffset > limit or elen > limit - extentOffset) return error.FreeExtentOutOfBounds;
    }

    try auditValueIndexes(database);
}

// Audit every value index against the live base rows. For each indexed
// property of each type, both directions of the invariant are checked:
//   * forward  -- every live row's value is present in the value index;
//   * backward -- every value-index entry resolves to a live row whose
//                 property value equals the indexed value.
// Any divergence is surfaced as a VerifyError rather than later showing up
// as a wrong query result.
//
// The root may legitimately not be a type directory (low-level callers
// commit raw blobs). A valid directory holds at most 256 types, so an
// implausible type count -- or any catalog that fails to load -- means the
// root is not a typed directory and there is nothing to audit.
fn auditValueIndexes(database: *Database) VerifyError!void {
    if (database.active_root == 0) return;
    var readTransaction = ReadTransaction{ .database = database, .root_ref = database.active_root, .version = database.active_version };
    const typeCount = typedir.typeCount(&readTransaction, database.active_root) catch return;
    if (typeCount > 256) return;
    var typeId: u16 = 0;
    while (typeId < typeCount) : (typeId += 1) {
        const catalogRef = typedir.catalogRef(&readTransaction, database.active_root, typeId) catch return;
        const catalogView = catalog.loadCatalog(&readTransaction, catalogRef) catch return;
        var propertyIndex: usize = 0;
        while (propertyIndex < catalogView.propertyCount) : (propertyIndex += 1) {
            const kind = catalogView.kind(propertyIndex);
            if (kind == .link or kind == .link_set) {
                try auditBacklinksForward(&readTransaction, catalogView, propertyIndex, kind);
                try auditBacklinksBackward(&readTransaction, catalogView, propertyIndex, kind);
            }
            if (!catalogView.indexed(propertyIndex)) continue;
            const valueIndexRef = catalogView.valueIndexRef(propertyIndex);
            const propertyColumn = catalogView.propertyColumnRef(propertyIndex);
            try auditValueIndexForward(&readTransaction, catalogView.keyrow_index_ref, valueIndexRef, propertyColumn, catalogView.live_col_ref);
            try auditValueIndexBackward(&readTransaction, valueIndexRef, catalogView.keyrow_index_ref, propertyColumn, catalogView.live_col_ref);
        }
    }
}

// Forward direction of the value-index invariant: walk the live rows (the
// keyrow index maps objectKey->row for live rows only) and assert each row's indexed
// value carries that objectKey in the value index's inner set. A live row that the
// index does not cover is error.ValueIndexMissingEntry. Any structural failure
// reading the index/columns of an established typed catalog is itself a
// divergence and reported the same way.
fn auditValueIndexForward(readTransaction: *ReadTransaction, keyrow_ref: Reference, valueIndexRef: Reference, propertyColumn: Reference, live_col: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        valueIndexRef: Reference,
        propertyColumn: Reference,
        live_col: Reference,
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if ((try Column.get(self.readTransaction, self.live_col, row)) == 0) return; // defensive: skip dead
            const value = try Column.get(self.readTransaction, self.propertyColumn, row);
            const inner = (try Index.get(self.readTransaction, self.valueIndexRef, value)) orelse return error.ValueIndexMissingEntry;
            if ((try Index.get(self.readTransaction, inner, objectKey)) == null) return error.ValueIndexMissingEntry;
        }
    };
    Index.forEachEntry(readTransaction, keyrow_ref, Ctx{ .readTransaction = readTransaction, .valueIndexRef = valueIndexRef, .propertyColumn = propertyColumn, .live_col = live_col }, Ctx.onEntry) catch return error.ValueIndexMissingEntry;
}

// Backward direction of the value-index invariant: walk every (value, inner-set)
// entry of the value index and, for each objectKey in a non-empty inner set, assert it
// resolves through the keyrow index to a live row whose property value equals
// that value. A stale/dangling objectKey or a value mismatch is
// error.ValueIndexStaleEntry. Empty inner sets are skipped defensively: current
// maintenance removes an entry the moment its set empties, but tolerating one
// keeps the audit usable on files written before that pruning existed.
fn auditValueIndexBackward(readTransaction: *ReadTransaction, valueIndexRef: Reference, keyrow_ref: Reference, propertyColumn: Reference, live_col: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        keyrow_ref: Reference,
        propertyColumn: Reference,
        live_col: Reference,
        fn onEntry(self: @This(), value: u64, inner_root: u64) anyerror!void {
            if ((try Index.count(self.readTransaction, inner_root)) == 0) return; // empty set left by delete
            const Inner = struct {
                readTransaction: *ReadTransaction,
                keyrow_ref: Reference,
                propertyColumn: Reference,
                live_col: Reference,
                value: u64,
                fn onKey(inner: @This(), objectKey: u64) anyerror!void {
                    const row = (try Index.get(inner.readTransaction, inner.keyrow_ref, objectKey)) orelse return error.ValueIndexStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.live_col, row)) == 0) return error.ValueIndexStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.propertyColumn, row)) != inner.value) return error.ValueIndexStaleEntry;
                }
            };
            try Index.forEachKey(self.readTransaction, inner_root, Inner{ .readTransaction = self.readTransaction, .keyrow_ref = self.keyrow_ref, .propertyColumn = self.propertyColumn, .live_col = self.live_col, .value = value }, Inner.onKey);
        }
    };
    Index.forEachEntry(readTransaction, valueIndexRef, Ctx{ .readTransaction = readTransaction, .keyrow_ref = keyrow_ref, .propertyColumn = propertyColumn, .live_col = live_col }, Ctx.onEntry) catch return error.ValueIndexStaleEntry;
}

// Forward direction of the backlink invariant: every live row's outbound
// link/link_set target must carry that row's objectKey in the target's backlink set.
// Any structural failure while walking is itself a divergence.
fn auditBacklinksForward(readTransaction: *ReadTransaction, catalogView: catalog.CatalogView, propertyIndex: usize, kind: catalog.PropertyKind) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        backlinkRef: Reference,
        propertyColumn: Reference,
        live_col: Reference,
        kind: catalog.PropertyKind,
        fn checkOne(self: @This(), target: u64, sourceObjectKey: u64) anyerror!void {
            const inner = (try Index.get(self.readTransaction, self.backlinkRef, target)) orelse return error.BacklinkMissingEntry;
            if ((try Index.get(self.readTransaction, inner, sourceObjectKey)) == null) return error.BacklinkMissingEntry;
        }
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if ((try Column.get(self.readTransaction, self.live_col, row)) == 0) return; // defensive: skip dead
            const raw = try Column.get(self.readTransaction, self.propertyColumn, row);
            if (self.kind == .link) {
                if (raw == 0) return; // null link
                try self.checkOne(raw - 1, objectKey);
                return;
            }
            // link_set: every member of the row's set must backlink to this row.
            const Walk = struct {
                readTransaction: *ReadTransaction,
                backlinkRef: Reference,
                objectKey: u64,
                fn onKey(walk: @This(), target: u64) anyerror!void {
                    const inner = (try Index.get(walk.readTransaction, walk.backlinkRef, target)) orelse return error.BacklinkMissingEntry;
                    if ((try Index.get(walk.readTransaction, inner, walk.objectKey)) == null) return error.BacklinkMissingEntry;
                }
            };
            try Index.forEachKey(self.readTransaction, raw, Walk{ .readTransaction = self.readTransaction, .backlinkRef = self.backlinkRef, .objectKey = objectKey }, Walk.onKey);
        }
    };
    Index.forEachEntry(readTransaction, catalogView.keyrow_index_ref, Ctx{
        .readTransaction = readTransaction,
        .backlinkRef = catalogView.backlinkRef(propertyIndex),
        .propertyColumn = catalogView.propertyColumnRef(propertyIndex),
        .live_col = catalogView.live_col_ref,
        .kind = kind,
    }, Ctx.onEntry) catch return error.BacklinkMissingEntry;
}

// Backward direction of the backlink invariant: every backlink entry's source
// must be a live row whose link column actually points at the entry's target.
// Empty inner sets are tolerated defensively (maintenance prunes them now).
fn auditBacklinksBackward(readTransaction: *ReadTransaction, catalogView: catalog.CatalogView, propertyIndex: usize, kind: catalog.PropertyKind) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        keyrow: Reference,
        propertyColumn: Reference,
        live_col: Reference,
        kind: catalog.PropertyKind,
        fn onEntry(self: @This(), target: u64, inner_root: u64) anyerror!void {
            if ((try Index.count(self.readTransaction, inner_root)) == 0) return;
            const Inner = struct {
                readTransaction: *ReadTransaction,
                keyrow: Reference,
                propertyColumn: Reference,
                live_col: Reference,
                kind: catalog.PropertyKind,
                target: u64,
                fn onKey(inner: @This(), sourceObjectKey: u64) anyerror!void {
                    const row = (try Index.get(inner.readTransaction, inner.keyrow, sourceObjectKey)) orelse return error.BacklinkStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.live_col, row)) == 0) return error.BacklinkStaleEntry;
                    const raw = try Column.get(inner.readTransaction, inner.propertyColumn, row);
                    if (inner.kind == .link) {
                        if (raw == 0 or raw - 1 != inner.target) return error.BacklinkStaleEntry;
                    } else {
                        if ((try Index.get(inner.readTransaction, raw, inner.target)) == null) return error.BacklinkStaleEntry;
                    }
                }
            };
            try Index.forEachKey(self.readTransaction, inner_root, Inner{
                .readTransaction = self.readTransaction,
                .keyrow = self.keyrow,
                .propertyColumn = self.propertyColumn,
                .live_col = self.live_col,
                .kind = self.kind,
                .target = target,
            }, Inner.onKey);
        }
    };
    Index.forEachEntry(readTransaction, catalogView.backlinkRef(propertyIndex), Ctx{
        .readTransaction = readTransaction,
        .keyrow = catalogView.keyrow_index_ref,
        .propertyColumn = catalogView.propertyColumnRef(propertyIndex),
        .live_col = catalogView.live_col_ref,
        .kind = kind,
    }, Ctx.onEntry) catch return error.BacklinkStaleEntry;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..path_len], name });
}

test "verifyIntegrity detects both slots corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "vi_slot.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_");
    writeTransaction.setRoot(allocation.ref);
    _ = try writeTransaction.commit();
    // Corrupt the checksum bytes of BOTH slot regions so neither decodes. Header stays valid.
    database.store.map[slot_a_off + 4] ^= 0xFF;
    database.store.map[slot_b_off + 4] ^= 0xFF;
    try testing.expectError(error.SlotCorrupt, verifyIntegrity(&database));
}
