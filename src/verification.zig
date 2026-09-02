//! Offline integrity audit of a database instance.
//!
//! Checks the header, commit slots, root reference, and free list for structural
//! sanity, then audits every value index and backlink index against the live
//! base rows in both directions. Read-only; nothing inner imports this file.

const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");
const Slot = @import("storage/slots.zig").Slot;
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const ReadTransaction = @import("transactions/readTransaction.zig").ReadTransaction;
const slotAOff = @import("database.zig").slotAOff;
const slotBOff = @import("database.zig").slotBOff;
const typeDirectory = @import("schema/typeDirectory.zig");
const catalog = @import("schema/catalog.zig");
const Column = @import("trees/column.zig");
const Index = @import("trees/index.zig");
const byteKeyIndex = @import("trees/byteKeyIndex.zig");
const blobIndexKey = @import("records/blobIndexKey.zig");

/// Everything verifyIntegrity can report about a damaged database.
pub const VerifyError = error{
    HeaderCorrupt,
    SlotCorrupt,
    FreeListCorrupt,
    FreeExtentOutOfBounds,
    RootReferenceOutOfBounds,
    // A live row's indexed property value is not reflected in that property's
    // value index (forward direction of the value-index invariant).
    ValueIndexMissingEntry,
    // A value-index entry points at a dead/absent row, or at a live row whose
    // property value differs from the indexed value (backward direction).
    ValueIndexStaleEntry,
    // A live row's outbound link/linkSet target is missing from the target's
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
    if (!database.store.headerChecksumOk) return error.HeaderCorrupt;

    const aOk = Slot.decode(database.store.map[slotAOff .. slotAOff + Slot.size]) catch null;
    const bOk = Slot.decode(database.store.map[slotBOff .. slotBOff + Slot.size]) catch null;
    if (aOk == null and bOk == null) return error.SlotCorrupt;

    const limit = database.store.sectionsView().len * platform.sectionSize;

    if (database.activeRoot != 0) {
        const rootReference: usize = @intCast(database.activeRoot);
        if (rootReference % 8 != 0 or rootReference >= limit) return error.RootReferenceOutOfBounds;
    }

    if (database.freeListNodeReference != 0) {
        const nodeReference: usize = @intCast(database.freeListNodeReference);
        if (nodeReference % 8 != 0 or nodeReference + database.freeListNodeLen > limit) return error.FreeListCorrupt;
    }

    for (database.freeList.extents.items) |extent| {
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
    if (database.activeRoot == 0) return;
    var readTransaction = ReadTransaction{ .database = database, .rootReference = database.activeRoot, .version = database.activeVersion };
    const typeCount = typeDirectory.typeCount(&readTransaction, database.activeRoot) catch return;
    if (typeCount > 256) return;
    var typeId: u16 = 0;
    while (typeId < typeCount) : (typeId += 1) {
        const catalogReference = typeDirectory.catalogReference(&readTransaction, database.activeRoot, typeId) catch return;
        const catalogView = catalog.loadCatalog(&readTransaction, catalogReference) catch return;
        var propertyIndex: usize = 0;
        while (propertyIndex < catalogView.propertyCount) : (propertyIndex += 1) {
            const kind = catalogView.kind(propertyIndex);
            if (kind == .link or kind == .linkSet) {
                try auditBacklinksForward(&readTransaction, catalogView, propertyIndex, kind);
                try auditBacklinksBackward(&readTransaction, catalogView, propertyIndex, kind);
            }
            if (!catalogView.indexed(propertyIndex)) continue;
            const valueIndexReference = catalogView.valueIndexReference(propertyIndex);
            const propertyColumn = catalogView.propertyColumnReference(propertyIndex);
            if (kind == .blob) {
                try auditBlobValueIndexForward(&readTransaction, catalogView.keyToRowIndexReference, valueIndexReference, propertyColumn, catalogView.liveColumnReference);
                try auditBlobValueIndexBackward(&readTransaction, valueIndexReference, catalogView.keyToRowIndexReference, propertyColumn, catalogView.liveColumnReference);
            } else {
                try auditValueIndexForward(&readTransaction, catalogView.keyToRowIndexReference, valueIndexReference, propertyColumn, catalogView.liveColumnReference);
                try auditValueIndexBackward(&readTransaction, valueIndexReference, catalogView.keyToRowIndexReference, propertyColumn, catalogView.liveColumnReference);
            }
        }
    }
}

// Forward direction of the value-index invariant: walk the live rows (the
// key-to-row index maps objectKey->row for live rows only) and assert each row's indexed
// value carries that objectKey in the value index's inner set. A live row that the
// index does not cover is error.ValueIndexMissingEntry. Any structural failure
// reading the index/columns of an established typed catalog is itself a
// divergence and reported the same way.
fn auditValueIndexForward(readTransaction: *ReadTransaction, keyToRowIndexReference: Reference, valueIndexReference: Reference, propertyColumn: Reference, liveColumn: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        valueIndexReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if ((try Column.get(self.readTransaction, self.liveColumn, row)) == 0) return; // defensive: skip dead
            const value = try Column.get(self.readTransaction, self.propertyColumn, row);
            const inner = (try Index.get(self.readTransaction, self.valueIndexReference, value)) orelse return error.ValueIndexMissingEntry;
            if ((try Index.get(self.readTransaction, inner, objectKey)) == null) return error.ValueIndexMissingEntry;
        }
    };
    Index.forEachEntry(readTransaction, keyToRowIndexReference, Ctx{ .readTransaction = readTransaction, .valueIndexReference = valueIndexReference, .propertyColumn = propertyColumn, .liveColumn = liveColumn }, Ctx.onEntry) catch return error.ValueIndexMissingEntry;
}

// Backward direction of the value-index invariant: walk every (value, inner-set)
// entry of the value index and, for each objectKey in a non-empty inner set, assert it
// resolves through the key-to-row index to a live row whose property value equals
// that value. A stale/dangling objectKey or a value mismatch is
// error.ValueIndexStaleEntry. Empty inner sets are skipped defensively: current
// maintenance removes an entry the moment its set empties, but tolerating one
// keeps the audit usable on files written before that pruning existed.
fn auditValueIndexBackward(readTransaction: *ReadTransaction, valueIndexReference: Reference, keyToRowIndexReference: Reference, propertyColumn: Reference, liveColumn: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        keyToRowIndexReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        fn onEntry(self: @This(), value: u64, innerRoot: u64) anyerror!void {
            if ((try Index.count(self.readTransaction, innerRoot)) == 0) return; // empty set left by delete
            const Inner = struct {
                readTransaction: *ReadTransaction,
                keyToRowIndexReference: Reference,
                propertyColumn: Reference,
                liveColumn: Reference,
                value: u64,
                fn onKey(inner: @This(), objectKey: u64) anyerror!void {
                    const row = (try Index.get(inner.readTransaction, inner.keyToRowIndexReference, objectKey)) orelse return error.ValueIndexStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.liveColumn, row)) == 0) return error.ValueIndexStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.propertyColumn, row)) != inner.value) return error.ValueIndexStaleEntry;
                }
            };
            try Index.forEachKey(self.readTransaction, innerRoot, Inner{ .readTransaction = self.readTransaction, .keyToRowIndexReference = self.keyToRowIndexReference, .propertyColumn = self.propertyColumn, .liveColumn = self.liveColumn, .value = value }, Inner.onKey);
        }
    };
    Index.forEachEntry(readTransaction, valueIndexReference, Ctx{ .readTransaction = readTransaction, .keyToRowIndexReference = keyToRowIndexReference, .propertyColumn = propertyColumn, .liveColumn = liveColumn }, Ctx.onEntry) catch return error.ValueIndexStaleEntry;
}

// Forward direction of the value-index invariant for a `.blob` property: walk
// the live rows and assert each row's TRUNCATED key (blobIndexKey.read of its
// stored bytes) carries that objectKey in the byte-keyed value index's inner
// set. Asserting the row's truncated key, not its full bytes, is deliberate:
// the write path only ever promises the truncated key (blobIndexKey.zig), so
// asserting full bytes would be a stricter invariant than the index makes and
// would fail on every value over 256 bytes. Missing at either level is
// error.ValueIndexMissingEntry, matching the int-keyed direction.
fn auditBlobValueIndexForward(readTransaction: *ReadTransaction, keyToRowIndexReference: Reference, valueIndexReference: Reference, propertyColumn: Reference, liveColumn: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        valueIndexReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if ((try Column.get(self.readTransaction, self.liveColumn, row)) == 0) return; // defensive: skip dead
            const raw = try Column.get(self.readTransaction, self.propertyColumn, row);
            var keyBuffer: [blobIndexKey.maxLength]u8 = undefined;
            const key = try blobIndexKey.read(self.readTransaction, raw, &keyBuffer);
            const inner = (try byteKeyIndex.get(self.readTransaction, self.valueIndexReference, key)) orelse return error.ValueIndexMissingEntry;
            if ((try Index.get(self.readTransaction, inner, objectKey)) == null) return error.ValueIndexMissingEntry;
        }
    };
    Index.forEachEntry(readTransaction, keyToRowIndexReference, Ctx{ .readTransaction = readTransaction, .valueIndexReference = valueIndexReference, .propertyColumn = propertyColumn, .liveColumn = liveColumn }, Ctx.onEntry) catch return error.ValueIndexMissingEntry;
}

// Backward direction of the value-index invariant for a `.blob` property: walk
// every (key, inner-set) entry of the byte-keyed value index and, for each
// objectKey in a non-empty inner set, assert it resolves through the
// key-to-row index to a live row whose property value's own truncated key
// equals the outer key. A stale/dangling objectKey or a key mismatch is
// error.ValueIndexStaleEntry, matching the int-keyed direction. Empty inner
// sets are skipped defensively, as in the int-keyed direction.
//
// The outer key slice points into mapped storage and the inner walk
// dereferences other nodes (each objectKey's row and property column), so it
// is copied into a stack buffer before the inner walk: that removes any
// question about the slice's lifetime for the cost of one 256-byte buffer.
fn auditBlobValueIndexBackward(readTransaction: *ReadTransaction, valueIndexReference: Reference, keyToRowIndexReference: Reference, propertyColumn: Reference, liveColumn: Reference) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        keyToRowIndexReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        fn onEntry(self: @This(), key: []const u8, innerRoot: u64) anyerror!void {
            if ((try Index.count(self.readTransaction, innerRoot)) == 0) return; // empty set left by delete
            // Copy the outer key before the inner walk: it points into mapped
            // storage and the inner walk dereferences other nodes (each
            // objectKey's row and property column), so copying removes any
            // question about the slice's lifetime for the cost of one
            // 256-byte stack buffer.
            var keyBuffer: [blobIndexKey.maxLength]u8 = undefined;
            @memcpy(keyBuffer[0..key.len], key);
            const copiedKey = keyBuffer[0..key.len];
            const Inner = struct {
                readTransaction: *ReadTransaction,
                keyToRowIndexReference: Reference,
                propertyColumn: Reference,
                liveColumn: Reference,
                key: []const u8,
                fn onKey(inner: @This(), objectKey: u64) anyerror!void {
                    const row = (try Index.get(inner.readTransaction, inner.keyToRowIndexReference, objectKey)) orelse return error.ValueIndexStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.liveColumn, row)) == 0) return error.ValueIndexStaleEntry;
                    const raw = try Column.get(inner.readTransaction, inner.propertyColumn, row);
                    // The invariant asserted is the row's TRUNCATED key, exactly
                    // what the write path maintains: asserting full bytes would be
                    // a stricter invariant than the index promises and would fail
                    // on every value over 256 bytes.
                    var rowKeyBuffer: [blobIndexKey.maxLength]u8 = undefined;
                    const rowKey = try blobIndexKey.read(inner.readTransaction, raw, &rowKeyBuffer);
                    if (!std.mem.eql(u8, rowKey, inner.key)) return error.ValueIndexStaleEntry;
                }
            };
            try Index.forEachKey(self.readTransaction, innerRoot, Inner{ .readTransaction = self.readTransaction, .keyToRowIndexReference = self.keyToRowIndexReference, .propertyColumn = self.propertyColumn, .liveColumn = self.liveColumn, .key = copiedKey }, Inner.onKey);
        }
    };
    byteKeyIndex.forEachEntry(readTransaction, valueIndexReference, Ctx{ .readTransaction = readTransaction, .keyToRowIndexReference = keyToRowIndexReference, .propertyColumn = propertyColumn, .liveColumn = liveColumn }, Ctx.onEntry) catch return error.ValueIndexStaleEntry;
}

// Forward direction of the backlink invariant: every live row's outbound
// link/linkSet target must carry that row's objectKey in the target's backlink set.
// Any structural failure while walking is itself a divergence.
fn auditBacklinksForward(readTransaction: *ReadTransaction, catalogView: catalog.CatalogView, propertyIndex: usize, kind: catalog.PropertyKind) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        backlinkReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        kind: catalog.PropertyKind,
        fn checkOne(self: @This(), target: u64, sourceObjectKey: u64) anyerror!void {
            const inner = (try Index.get(self.readTransaction, self.backlinkReference, target)) orelse return error.BacklinkMissingEntry;
            if ((try Index.get(self.readTransaction, inner, sourceObjectKey)) == null) return error.BacklinkMissingEntry;
        }
        fn onEntry(self: @This(), objectKey: u64, row: u64) anyerror!void {
            if ((try Column.get(self.readTransaction, self.liveColumn, row)) == 0) return; // defensive: skip dead
            const raw = try Column.get(self.readTransaction, self.propertyColumn, row);
            if (self.kind == .link) {
                if (raw == 0) return; // null link
                try self.checkOne(raw - 1, objectKey);
                return;
            }
            // linkSet: every member of the row's set must backlink to this row.
            const Walk = struct {
                readTransaction: *ReadTransaction,
                backlinkReference: Reference,
                objectKey: u64,
                fn onKey(walk: @This(), target: u64) anyerror!void {
                    const inner = (try Index.get(walk.readTransaction, walk.backlinkReference, target)) orelse return error.BacklinkMissingEntry;
                    if ((try Index.get(walk.readTransaction, inner, walk.objectKey)) == null) return error.BacklinkMissingEntry;
                }
            };
            try Index.forEachKey(self.readTransaction, raw, Walk{ .readTransaction = self.readTransaction, .backlinkReference = self.backlinkReference, .objectKey = objectKey }, Walk.onKey);
        }
    };
    Index.forEachEntry(readTransaction, catalogView.keyToRowIndexReference, Ctx{
        .readTransaction = readTransaction,
        .backlinkReference = catalogView.backlinkReference(propertyIndex),
        .propertyColumn = catalogView.propertyColumnReference(propertyIndex),
        .liveColumn = catalogView.liveColumnReference,
        .kind = kind,
    }, Ctx.onEntry) catch return error.BacklinkMissingEntry;
}

// Backward direction of the backlink invariant: every backlink entry's source
// must be a live row whose link column actually points at the entry's target.
// Empty inner sets are tolerated defensively (maintenance prunes them now).
fn auditBacklinksBackward(readTransaction: *ReadTransaction, catalogView: catalog.CatalogView, propertyIndex: usize, kind: catalog.PropertyKind) VerifyError!void {
    const Ctx = struct {
        readTransaction: *ReadTransaction,
        keyToRowIndexReference: Reference,
        propertyColumn: Reference,
        liveColumn: Reference,
        kind: catalog.PropertyKind,
        fn onEntry(self: @This(), target: u64, innerRoot: u64) anyerror!void {
            if ((try Index.count(self.readTransaction, innerRoot)) == 0) return;
            const Inner = struct {
                readTransaction: *ReadTransaction,
                keyToRowIndexReference: Reference,
                propertyColumn: Reference,
                liveColumn: Reference,
                kind: catalog.PropertyKind,
                target: u64,
                fn onKey(inner: @This(), sourceObjectKey: u64) anyerror!void {
                    const row = (try Index.get(inner.readTransaction, inner.keyToRowIndexReference, sourceObjectKey)) orelse return error.BacklinkStaleEntry;
                    if ((try Column.get(inner.readTransaction, inner.liveColumn, row)) == 0) return error.BacklinkStaleEntry;
                    const raw = try Column.get(inner.readTransaction, inner.propertyColumn, row);
                    if (inner.kind == .link) {
                        if (raw == 0 or raw - 1 != inner.target) return error.BacklinkStaleEntry;
                    } else {
                        if ((try Index.get(inner.readTransaction, raw, inner.target)) == null) return error.BacklinkStaleEntry;
                    }
                }
            };
            try Index.forEachKey(self.readTransaction, innerRoot, Inner{
                .readTransaction = self.readTransaction,
                .keyToRowIndexReference = self.keyToRowIndexReference,
                .propertyColumn = self.propertyColumn,
                .liveColumn = self.liveColumn,
                .kind = self.kind,
                .target = target,
            }, Inner.onKey);
        }
    };
    Index.forEachEntry(readTransaction, catalogView.backlinkReference(propertyIndex), Ctx{
        .readTransaction = readTransaction,
        .keyToRowIndexReference = catalogView.keyToRowIndexReference,
        .propertyColumn = catalogView.propertyColumnReference(propertyIndex),
        .liveColumn = catalogView.liveColumnReference,
        .kind = kind,
    }, Ctx.onEntry) catch return error.BacklinkStaleEntry;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
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
    writeTransaction.setRoot(allocation.reference);
    _ = try writeTransaction.commit();
    // Corrupt the checksum bytes of BOTH slot regions so neither decodes. Header stays valid.
    database.store.map[slotAOff + 4] ^= 0xFF;
    database.store.map[slotBOff + 4] ^= 0xFF;
    try testing.expectError(error.SlotCorrupt, verifyIntegrity(&database));
}
