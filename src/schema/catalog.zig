const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");

pub const PropertyCount = u16;
pub const PropertyKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3, link = 4, linkSet = 5, dict = 6 };
pub const ElementKind = enum(u8) { int = 0, blob = 1 };
pub const DeletionRule = enum(u8) { nullify = 0, cascade = 1, block = 2 };
pub const PropertyDefinition = struct { kind: PropertyKind, element: ElementKind = .int, linkTarget: u16 = 0, delRule: DeletionRule = .nullify, indexed: bool = false };
// A single byte-keyed dictionary entry: a byte-string key mapped to a u64 value
// (an int, or an object key for a "dict of links" -- u64 covers both).
pub const DictEntry = struct { key: []const u8, value: u64 };
pub const Value = union(enum) {
    int: u64,
    // A blob property decodes to one of two read-side shapes:
    //   .bytes    -- a small blob (<= inline cap): a zero-copy slice into the
    //                mapped storage. Valid until the next MUTATING call on the
    //                same transaction: an update/delete that frees the blob
    //                routes a transaction-private node to the immediate-reuse pool, so
    //                the next allocation may scribble it. Copy the bytes out
    //                before mutating if they must survive.
    //   .blobRef -- a blob larger than the inline cap, stored chunked and thus
    //                without a single contiguous slice. The caller materializes
    //                it with `blob.getAlloc(transaction, ref, allocator)` and frees the
    //                returned buffer.
    bytes: []const u8,
    blobRef: Reference,
    listInt: []const u64,
    listBlob: []const []const u8,
    setInt: []const u64,
    setBlob: []const []const u8,
    dictInt: []const DictEntry,
    collRoot: Reference, // read side: getTyped returns this for list/set/dict/linkSet properties
    link: ?u64,
    linkSet: []const u64, // to-many: initial set of target objectKeys
};

// Catalog node layout:
// [propertyCount u16][nextRow u64][primaryKeyIndexRef u64][versionColRef u64][liveColRef u64]
// [propertyCount * (propertyColumnRef u64)][propertyCount * (kind u8)][propertyCount * (element u8)]
// [propertyCount * (backlinkRef u64)][propertyCount * (linkTarget u16)][propertyCount * (delRule u8)]
// [propertyCount * (valueIndexRef u64)][propertyCount * (indexed u8)]
//
// The value-index ref and indexed flag arrays are appended last so the earlier
// per-property arrays keep their existing offsets unchanged.
const propertyCountOffset: usize = 0;
const offNextRow: usize = 2;
const primaryKeyIndexRefOffset: usize = 10;
const offVersionColRef: usize = 18;
const offLiveColRef: usize = 26;
const offKeyrowIndexRef: usize = 34;
const offNextKey: usize = 42;
const propertyColumnsOffset: usize = 50;

pub const maxPropertyCount: usize = 256;

fn catalogSize(propertyCount: PropertyCount) usize {
    return propertyColumnsOffset + @as(usize, propertyCount) * 8 + @as(usize, propertyCount) * 2 + @as(usize, propertyCount) * 8 + @as(usize, propertyCount) * 2 + @as(usize, propertyCount) + @as(usize, propertyCount) * 8 + @as(usize, propertyCount);
}

fn kindsOffset(propertyCount: PropertyCount) usize {
    return propertyColumnsOffset + @as(usize, propertyCount) * 8;
}

fn elemsOffset(propertyCount: PropertyCount) usize {
    return kindsOffset(propertyCount) + propertyCount;
}

fn backlinksOffset(propertyCount: PropertyCount) usize {
    return elemsOffset(propertyCount) + propertyCount;
}

fn targetsOffset(propertyCount: PropertyCount) usize {
    return backlinksOffset(propertyCount) + @as(usize, propertyCount) * 8;
}

fn rulesOffset(propertyCount: PropertyCount) usize {
    return targetsOffset(propertyCount) + @as(usize, propertyCount) * 2;
}

fn valueIndexRefsOffset(propertyCount: PropertyCount) usize {
    return rulesOffset(propertyCount) + @as(usize, propertyCount);
}

fn indexedFlagsOffset(propertyCount: PropertyCount) usize {
    return valueIndexRefsOffset(propertyCount) + @as(usize, propertyCount) * 8;
}

// Allocate and encode a fresh catalog node; return its ref.
pub fn writeCatalog(
    transaction: *WriteTransaction,
    propertyCount: PropertyCount,
    nextRow: u64,
    keyrowIndexRef: Reference,
    nextKey: u64,
    primaryKeyIndexRef: Reference,
    versionColRef: Reference,
    liveColRef: Reference,
    propertyColumnRefs: []const Reference,
    kinds: []const PropertyKind,
    elements: []const ElementKind,
    backlinks: []const Reference,
    targets: []const u16,
    rules: []const DeletionRule,
    valueIndexRefs: []const Reference,
    indexedFlags: []const bool,
) !Reference {
    const allocation = try transaction.alloc(catalogSize(propertyCount));
    std.mem.writeInt(u16, allocation.bytes[propertyCountOffset..][0..2], propertyCount, .little);
    std.mem.writeInt(u64, allocation.bytes[offNextRow..][0..8], nextRow, .little);
    std.mem.writeInt(u64, allocation.bytes[offKeyrowIndexRef..][0..8], keyrowIndexRef, .little);
    std.mem.writeInt(u64, allocation.bytes[offNextKey..][0..8], nextKey, .little);
    std.mem.writeInt(u64, allocation.bytes[primaryKeyIndexRefOffset..][0..8], primaryKeyIndexRef, .little);
    std.mem.writeInt(u64, allocation.bytes[offVersionColRef..][0..8], versionColRef, .little);
    std.mem.writeInt(u64, allocation.bytes[offLiveColRef..][0..8], liveColRef, .little);
    for (propertyColumnRefs, 0..) |ref, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[propertyColumnsOffset + propertyIndex * 8 ..][0..8], ref, .little);
    }
    const kindsBase = kindsOffset(propertyCount);
    for (kinds, 0..) |kind, propertyIndex| allocation.bytes[kindsBase + propertyIndex] = @intFromEnum(kind);
    const elementsBase = elemsOffset(propertyCount);
    for (elements, 0..) |element, propertyIndex| allocation.bytes[elementsBase + propertyIndex] = @intFromEnum(element);
    const blo = backlinksOffset(propertyCount);
    for (backlinks, 0..) |bref, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[blo + propertyIndex * 8 ..][0..8], bref, .little);
    }
    const targetsBase = targetsOffset(propertyCount);
    for (targets, 0..) |target, propertyIndex| std.mem.writeInt(u16, allocation.bytes[targetsBase + propertyIndex * 2 ..][0..2], target, .little);
    const rulesBase = rulesOffset(propertyCount);
    for (rules, 0..) |rule, propertyIndex| allocation.bytes[rulesBase + propertyIndex] = @intFromEnum(rule);
    const valueIndexOffset = valueIndexRefsOffset(propertyCount);
    for (valueIndexRefs, 0..) |vref, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[valueIndexOffset + propertyIndex * 8 ..][0..8], vref, .little);
    }
    const ifo = indexedFlagsOffset(propertyCount);
    for (indexedFlags, 0..) |flag, propertyIndex| allocation.bytes[ifo + propertyIndex] = @intFromBool(flag);
    return allocation.ref;
}

// createFromDefinitions allocates columns, a primaryKey index, version/live columns, and a catalog
// node from explicit per-property definitions. definitions[0].kind must be .int (the primaryKey).
pub fn createFromDefinitions(transaction: *WriteTransaction, definitions: []const PropertyDefinition) !Reference {
    std.debug.assert(definitions.len >= 1 and definitions[0].kind == .int);
    const propertyCount: PropertyCount = @intCast(definitions.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var propertyColumnRefs: [maxPropertyCount]Reference = undefined;
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    var elements: [maxPropertyCount]ElementKind = undefined;
    var backlinks: [maxPropertyCount]Reference = undefined;
    var targets: [maxPropertyCount]u16 = undefined;
    var rules: [maxPropertyCount]DeletionRule = undefined;
    var valueIndexRefs: [maxPropertyCount]Reference = undefined;
    var indexedFlags: [maxPropertyCount]bool = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        propertyColumnRefs[propertyIndex] = try Column.create(transaction);
        kinds[propertyIndex] = definitions[propertyIndex].kind;
        elements[propertyIndex] = definitions[propertyIndex].element;
        backlinks[propertyIndex] = if (definitions[propertyIndex].kind == .link or definitions[propertyIndex].kind == .linkSet) try Index.create(transaction) else 0;
        targets[propertyIndex] = definitions[propertyIndex].linkTarget;
        rules[propertyIndex] = definitions[propertyIndex].delRule;
        indexedFlags[propertyIndex] = definitions[propertyIndex].indexed;
        valueIndexRefs[propertyIndex] = if (definitions[propertyIndex].indexed) try Index.create(transaction) else 0;
    }
    const versionColRef = try Column.create(transaction);
    const liveColRef = try Column.create(transaction);
    const primaryKeyIndexRef = try Index.create(transaction);
    const keyrow = try Index.create(transaction);
    return writeCatalog(
        transaction,
        propertyCount,
        0,
        keyrow,
        0,
        primaryKeyIndexRef,
        versionColRef,
        liveColRef,
        propertyColumnRefs[0..propertyCount],
        kinds[0..propertyCount],
        elements[0..propertyCount],
        backlinks[0..propertyCount],
        targets[0..propertyCount],
        rules[0..propertyCount],
        valueIndexRefs[0..propertyCount],
        indexedFlags[0..propertyCount],
    );
}

// createTyped keeps its scalar-only signature; every property gets element = int.
pub fn createTyped(transaction: *WriteTransaction, kinds: []const PropertyKind) !Reference {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const propertyCount: PropertyCount = @intCast(kinds.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var definitions: [maxPropertyCount]PropertyDefinition = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) definitions[propertyIndex] = .{ .kind = kinds[propertyIndex], .element = .int };
    return createFromDefinitions(transaction, definitions[0..propertyCount]);
}

// Create propertyCount property columns, a version column, a live column, and an
// empty primaryKey index. All property kinds default to .int.
pub fn create(transaction: *WriteTransaction, propertyCount: PropertyCount) !Reference {
    std.debug.assert(propertyCount <= maxPropertyCount);
    var allInt: [maxPropertyCount]PropertyKind = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) allInt[propertyIndex] = .int;
    return createTyped(transaction, allInt[0..propertyCount]);
}

pub const CatalogView = struct {
    propertyCount: PropertyCount,
    nextRow: u64,
    keyrowIndexRef: Reference,
    nextKey: u64,
    primaryKeyIndexRef: Reference,
    versionColRef: Reference,
    liveColRef: Reference,
    bytes: []const u8,

    pub fn propertyColumnRef(self: CatalogView, propertyIndex: usize) Reference {
        return std.mem.readInt(u64, self.bytes[propertyColumnsOffset + propertyIndex * 8 ..][0..8], .little);
    }

    pub fn kind(self: CatalogView, propertyIndex: usize) PropertyKind {
        return @enumFromInt(self.bytes[kindsOffset(self.propertyCount) + propertyIndex]);
    }

    pub fn elementKind(self: CatalogView, propertyIndex: usize) ElementKind {
        const elementsBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + self.propertyCount;
        return @enumFromInt(self.bytes[elementsBase + propertyIndex]);
    }

    pub fn backlinkRef(self: CatalogView, propertyIndex: usize) Reference {
        const blo = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return std.mem.readInt(u64, self.bytes[blo + propertyIndex * 8 ..][0..8], .little);
    }

    pub fn linkTarget(self: CatalogView, propertyIndex: usize) u16 {
        const targetsBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8;
        return std.mem.readInt(u16, self.bytes[targetsBase + propertyIndex * 2 ..][0..2], .little);
    }

    pub fn delRule(self: CatalogView, propertyIndex: usize) DeletionRule {
        const rulesBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return @enumFromInt(self.bytes[rulesBase + propertyIndex]);
    }

    pub fn valueIndexRef(self: CatalogView, propertyIndex: usize) Reference {
        const valueIndexOffset = valueIndexRefsOffset(self.propertyCount);
        return std.mem.readInt(u64, self.bytes[valueIndexOffset + propertyIndex * 8 ..][0..8], .little);
    }

    pub fn indexed(self: CatalogView, propertyIndex: usize) bool {
        const ifo = indexedFlagsOffset(self.propertyCount);
        return self.bytes[ifo + propertyIndex] != 0;
    }
};

// Deref the catalog at catalogRef, read propertyCount, then deref the full node and parse
// all fixed fields. Returns a CatalogView whose bytes slice is valid for the
// lifetime of the transaction.
//
// All per-property enum bytes (kind, element kind, deletion rule) are validated
// here, ONCE, so the CatalogView accessors can stay infallible. These bytes
// come straight from the mapped file: a corrupted value must surface as
// error.Corrupt, never as a panic (ReleaseSafe) or undefined behavior
// (ReleaseFast) from an unchecked @enumFromInt.
pub fn loadCatalog(transaction: anytype, catalogRef: Reference) !CatalogView {
    const propertyCountBytes = try transaction.deref(catalogRef, 2);
    const propertyCount = std.mem.readInt(u16, propertyCountBytes[0..2], .little);
    if (propertyCount > maxPropertyCount) return error.Corrupt;
    const bytes = try transaction.deref(catalogRef, catalogSize(propertyCount));
    {
        const kindsBase = kindsOffset(propertyCount);
        const elementsBase = elemsOffset(propertyCount);
        const rulesBase = rulesOffset(propertyCount);
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            if (std.enums.fromInt(PropertyKind, bytes[kindsBase + propertyIndex]) == null) return error.Corrupt;
            if (std.enums.fromInt(ElementKind, bytes[elementsBase + propertyIndex]) == null) return error.Corrupt;
            if (std.enums.fromInt(DeletionRule, bytes[rulesBase + propertyIndex]) == null) return error.Corrupt;
        }
    }
    return CatalogView{
        .propertyCount = propertyCount,
        .nextRow = std.mem.readInt(u64, bytes[offNextRow..][0..8], .little),
        .keyrowIndexRef = std.mem.readInt(u64, bytes[offKeyrowIndexRef..][0..8], .little),
        .nextKey = std.mem.readInt(u64, bytes[offNextKey..][0..8], .little),
        .primaryKeyIndexRef = std.mem.readInt(u64, bytes[primaryKeyIndexRefOffset..][0..8], .little),
        .versionColRef = std.mem.readInt(u64, bytes[offVersionColRef..][0..8], .little),
        .liveColRef = std.mem.readInt(u64, bytes[offLiveColRef..][0..8], .little),
        .bytes = bytes,
    };
}

/// One property's full catalog record, as carried by CatalogSnapshot.
pub const PropertySnapshot = struct {
    col: Reference,
    kind: PropertyKind,
    element: ElementKind,
    backlink: Reference,
    target: u16,
    rule: DeletionRule,
    valueIndex: Reference,
    indexed: bool,
};

/// A mutable, owned copy of every catalog field. This is THE way to rewrite a
/// catalog: load, mutate the fields that change, write. It replaces the
/// hand-rolled eight-parallel-arrays snapshot ritual (and the 15-positional-
/// argument writeCatalog call) that was previously duplicated at every mutation
/// site -- a pattern where transposing two Reference arguments compiles fine and
/// corrupts data. Because the snapshot owns plain values, it is also immune to
/// the CatalogView invalidation hazard: file growth cannot invalidate it.
pub const CatalogSnapshot = struct {
    propertyCount: PropertyCount,
    nextRow: u64,
    keyrowIndexRef: Reference,
    nextKey: u64,
    primaryKeyIndexRef: Reference,
    versionColRef: Reference,
    liveColRef: Reference,
    properties: [maxPropertyCount]PropertySnapshot,
    /// The node this snapshot was loaded from and its on-disk size, so
    /// replace() can free it. propertyCount may change after load (migrations),
    /// so the size is captured here, not recomputed.
    source: Reference,
    sourceLen: usize,

    pub fn load(transaction: anytype, catalogRef: Reference) !CatalogSnapshot {
        const view = try loadCatalog(transaction, catalogRef);
        var snapshot: CatalogSnapshot = undefined;
        snapshot.source = catalogRef;
        snapshot.sourceLen = catalogSize(view.propertyCount);
        snapshot.propertyCount = view.propertyCount;
        snapshot.nextRow = view.nextRow;
        snapshot.keyrowIndexRef = view.keyrowIndexRef;
        snapshot.nextKey = view.nextKey;
        snapshot.primaryKeyIndexRef = view.primaryKeyIndexRef;
        snapshot.versionColRef = view.versionColRef;
        snapshot.liveColRef = view.liveColRef;
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            snapshot.properties[propertyIndex] = .{
                .col = view.propertyColumnRef(propertyIndex),
                .kind = view.kind(propertyIndex),
                .element = view.elementKind(propertyIndex),
                .backlink = view.backlinkRef(propertyIndex),
                .target = view.linkTarget(propertyIndex),
                .rule = view.delRule(propertyIndex),
                .valueIndex = view.valueIndexRef(propertyIndex),
                .indexed = view.indexed(propertyIndex),
            };
        }
        return snapshot;
    }

    /// Allocate and encode a fresh catalog node from this snapshot.
    pub fn write(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        var cols: [maxPropertyCount]Reference = undefined;
        var kinds: [maxPropertyCount]PropertyKind = undefined;
        var elements: [maxPropertyCount]ElementKind = undefined;
        var backlinks: [maxPropertyCount]Reference = undefined;
        var targets: [maxPropertyCount]u16 = undefined;
        var rules: [maxPropertyCount]DeletionRule = undefined;
        var valueIndexRefs: [maxPropertyCount]Reference = undefined;
        var indexedFlags: [maxPropertyCount]bool = undefined;
        const propertyCount = self.propertyCount;
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const property = self.properties[propertyIndex];
            cols[propertyIndex] = property.col;
            kinds[propertyIndex] = property.kind;
            elements[propertyIndex] = property.element;
            backlinks[propertyIndex] = property.backlink;
            targets[propertyIndex] = property.target;
            rules[propertyIndex] = property.rule;
            valueIndexRefs[propertyIndex] = property.valueIndex;
            indexedFlags[propertyIndex] = property.indexed;
        }
        return writeCatalog(
            transaction,
            propertyCount,
            self.nextRow,
            self.keyrowIndexRef,
            self.nextKey,
            self.primaryKeyIndexRef,
            self.versionColRef,
            self.liveColRef,
            cols[0..propertyCount],
            kinds[0..propertyCount],
            elements[0..propertyCount],
            backlinks[0..propertyCount],
            targets[0..propertyCount],
            rules[0..propertyCount],
            valueIndexRefs[0..propertyCount],
            indexedFlags[0..propertyCount],
        );
    }

    /// Write the snapshot as a fresh node and free the node it was loaded
    /// from. This is the normal way to rewrite a catalog within one database:
    /// the old node is garbage the moment the caller adopts the new ref, and a
    /// transaction-private old node is reused by the very next same-size catalog write,
    /// so catalog churn stops growing the file. Do NOT use when the source
    /// lives in a different database (copyTypeRows) or must stay readable.
    pub fn replace(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        const newRef = try self.write(transaction);
        try transaction.free(self.source, self.sourceLen);
        return newRef;
    }
};

pub fn loadPropertyCount(transaction: anytype, catalogRef: Reference) !PropertyCount {
    const view = try loadCatalog(transaction, catalogRef);
    return view.propertyCount;
}

// liveCount returns the number of live rows tracked by the primaryKey index.
pub fn liveCount(transaction: anytype, catalogRef: Reference) !u64 {
    const view = try loadCatalog(transaction, catalogRef);
    return Index.count(transaction, view.primaryKeyIndexRef);
}

// Resolve an object key to its physical row via the key-to-row index.
// Returns null if the objectKey has no mapping.
pub fn objectKeyToRow(transaction: anytype, catalogRef: Reference, objectKey: u64) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
    return Index.get(transaction, view.keyrowIndexRef, objectKey);
}

// Resolve a primary key to its stable object key via the primaryKey index.
// Returns null if the primaryKey has no mapping.
pub fn primaryKeyToObjectKey(transaction: anytype, catalogRef: Reference, primaryKey: u64) !?u64 {
    const view = try loadCatalog(transaction, catalogRef);
    return Index.get(transaction, view.primaryKeyIndexRef, primaryKey);
}

// Resolve (catalogRef, primaryKey, property) to the property column ref and the row;
// null if primaryKey absent or row tombstoned. The primaryKey index maps primaryKey -> objectKey, and the
// keyrow index maps objectKey -> physical row.
pub fn resolveProperty(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?struct { row: u64, propertyColumn: Reference } {
    const view = try loadCatalog(transaction, catalogRef);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexRef, primaryKey)) orelse return null;
    const row = (try Index.get(transaction, view.keyrowIndexRef, objectKey)) orelse return null;
    if ((try Column.get(transaction, view.liveColRef, row)) == 0) return null;
    return .{ .row = row, .propertyColumn = view.propertyColumnRef(property) };
}

// Write newRoot into property `property` at `row`, bump that row's version stamp,
// return the new catalog ref.
pub fn replaceCollRoot(transaction: *WriteTransaction, catalogRef: Reference, row: u64, property: usize, newRoot: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogRef);
    snapshot.properties[property].col = try Column.set(transaction, snapshot.properties[property].col, row, newRoot);
    snapshot.versionColRef = try Column.set(transaction, snapshot.versionColRef, row, transaction.newVersion);
    return snapshot.replace(transaction);
}

// Write a new backlink ref into property `p`, preserving everything else.
pub fn setBacklinkRef(transaction: *WriteTransaction, catalogRef: Reference, propertyIndex: usize, newBacklink: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogRef);
    snapshot.properties[propertyIndex].backlink = newBacklink;
    return snapshot.replace(transaction);
}

// Write a new value-index ref into property `p`, preserving everything else.
pub fn setValueIndexRef(transaction: *WriteTransaction, catalogRef: Reference, propertyIndex: usize, newValueIndex: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogRef);
    snapshot.properties[propertyIndex].valueIndex = newValueIndex;
    return snapshot.replace(transaction);
}

// Write a new column ref into property `p`, preserving everything else.
pub fn setPropertyColumnRef(transaction: *WriteTransaction, catalogRef: Reference, propertyIndex: usize, newColumn: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogRef);
    snapshot.properties[propertyIndex].col = newColumn;
    return snapshot.replace(transaction);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Database = @import("../database.zig").Database;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..dlen], name });
}

test "create allocates an empty type and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try create(&writeTransaction, 3);
    try testing.expectEqual(@as(PropertyCount, 3), try loadPropertyCount(&writeTransaction, catalogRef));
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, catalogRef));
    writeTransaction.deinit();
}

test "CatalogSnapshot round-trips every field through load and write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "snap_rt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .link, .linkTarget = 3, .delRule = .cascade },
        .{ .kind = .list, .element = .blob },
    });
    const snapshot = try CatalogSnapshot.load(&writeTransaction, catalogRef);
    const copyRef = try snapshot.write(&writeTransaction);
    const view0 = try loadCatalog(&writeTransaction, catalogRef);
    const view1 = try loadCatalog(&writeTransaction, copyRef);
    try testing.expectEqual(view0.propertyCount, view1.propertyCount);
    try testing.expectEqual(view0.nextRow, view1.nextRow);
    try testing.expectEqual(view0.nextKey, view1.nextKey);
    try testing.expectEqual(view0.primaryKeyIndexRef, view1.primaryKeyIndexRef);
    try testing.expectEqual(view0.keyrowIndexRef, view1.keyrowIndexRef);
    try testing.expectEqual(view0.versionColRef, view1.versionColRef);
    try testing.expectEqual(view0.liveColRef, view1.liveColRef);
    var propertyIndex: usize = 0;
    while (propertyIndex < view0.propertyCount) : (propertyIndex += 1) {
        try testing.expectEqual(view0.propertyColumnRef(propertyIndex), view1.propertyColumnRef(propertyIndex));
        try testing.expectEqual(view0.kind(propertyIndex), view1.kind(propertyIndex));
        try testing.expectEqual(view0.elementKind(propertyIndex), view1.elementKind(propertyIndex));
        try testing.expectEqual(view0.backlinkRef(propertyIndex), view1.backlinkRef(propertyIndex));
        try testing.expectEqual(view0.linkTarget(propertyIndex), view1.linkTarget(propertyIndex));
        try testing.expectEqual(view0.delRule(propertyIndex), view1.delRule(propertyIndex));
        try testing.expectEqual(view0.valueIndexRef(propertyIndex), view1.valueIndexRef(propertyIndex));
        try testing.expectEqual(view0.indexed(propertyIndex), view1.indexed(propertyIndex));
    }
}

test "loadCatalog rejects corrupt disk values instead of panicking" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "corruptcat.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    defer writeTransaction.deinit();
    const catalogRef = try create(&writeTransaction, 2);
    _ = try loadCatalog(&writeTransaction, catalogRef); // clean before corruption

    // Corrupt a kind byte (out-of-range enum value) directly in the mapping.
    const catalogOffset: usize = @intCast(catalogRef);
    const kindByteOff = catalogOffset + propertyColumnsOffset + 2 * 8; // kindsOffset(2), property 0
    const savedKind = database.store.map[kindByteOff];
    database.store.map[kindByteOff] = 200;
    try testing.expectError(error.Corrupt, loadCatalog(&writeTransaction, catalogRef));
    database.store.map[kindByteOff] = savedKind;
    _ = try loadCatalog(&writeTransaction, catalogRef); // restored

    // Corrupt the property count to an implausible value.
    std.mem.writeInt(u16, database.store.map[catalogOffset..][0..2], 6000, .little);
    try testing.expectError(error.Corrupt, loadCatalog(&writeTransaction, catalogRef));
}

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createTyped(&writeTransaction, &.{ .int, .blob, .int });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(PropertyKind.int, view.kind(0));
    try testing.expectEqual(PropertyKind.blob, view.kind(1));
    try testing.expectEqual(PropertyKind.int, view.kind(2));
    const catalog2 = try create(&writeTransaction, 2);
    const v2 = try loadCatalog(&writeTransaction, catalog2);
    try testing.expectEqual(PropertyKind.int, v2.kind(0));
    try testing.expectEqual(PropertyKind.int, v2.kind(1));
    writeTransaction.deinit();
}

test "createDefs records kind and element kind per property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "defs.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .int },
        .{ .kind = .set, .element = .int },
        .{ .kind = .list, .element = .blob },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(PropertyCount, 4), view.propertyCount);
    try testing.expectEqual(PropertyKind.int, view.kind(0));
    try testing.expectEqual(PropertyKind.list, view.kind(1));
    try testing.expectEqual(ElementKind.int, view.elementKind(1));
    try testing.expectEqual(PropertyKind.set, view.kind(2));
    try testing.expectEqual(ElementKind.int, view.elementKind(2));
    try testing.expectEqual(PropertyKind.list, view.kind(3));
    try testing.expectEqual(ElementKind.blob, view.elementKind(3));
    const catalog2 = try createTyped(&writeTransaction, &.{ .int, .blob });
    const v2 = try loadCatalog(&writeTransaction, catalog2);
    try testing.expectEqual(PropertyKind.blob, v2.kind(1));
    try testing.expectEqual(ElementKind.int, v2.elementKind(1));
    writeTransaction.deinit();
}

test "createDefs builds a backlink index for each link property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcat.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .link },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(PropertyKind.link, view.kind(2));
    try testing.expect(view.backlinkRef(2) != 0);
    try testing.expectEqual(@as(Reference, 0), view.backlinkRef(0));
    try testing.expectEqual(@as(Reference, 0), view.backlinkRef(1));
    writeTransaction.deinit();
}

test "createDefs records a link target type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "ltarget.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 3 },
        .{ .kind = .linkSet, .linkTarget = 7 },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(@as(u16, 0), view.linkTarget(0));
    try testing.expectEqual(@as(u16, 3), view.linkTarget(1));
    try testing.expectEqual(@as(u16, 7), view.linkTarget(2));
    writeTransaction.deinit();
}

test "createDefs creates an empty key-to-row index and zero next_key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "keyrow.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expect(view.keyrowIndexRef != 0);
    try testing.expectEqual(@as(u64, 0), view.nextKey);
    writeTransaction.deinit();
}

test "catalog persists indexed flag and value index ref" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expect(view.indexed(1));
    try testing.expect(!view.indexed(0));
    try testing.expect(!view.indexed(2));
    try testing.expect(view.valueIndexRef(1) != 0);
    try testing.expectEqual(@as(Reference, 0), view.valueIndexRef(0));
    try testing.expectEqual(@as(Reference, 0), view.valueIndexRef(2));
    const vidx1 = view.valueIndexRef(1);
    // Round-trip through a full catalog rebuild (setPropertyColumnRef rewrites every
    // field) and assert both the flag and the value-index ref survive.
    const catalog2 = try setPropertyColumnRef(&writeTransaction, catalogRef, 2, view.propertyColumnRef(2));
    const v2 = try loadCatalog(&writeTransaction, catalog2);
    try testing.expect(v2.indexed(1));
    try testing.expect(!v2.indexed(0));
    try testing.expect(!v2.indexed(2));
    try testing.expectEqual(vidx1, v2.valueIndexRef(1));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexRef(0));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexRef(2));
    writeTransaction.deinit();
}

test "non-indexed catalog: value index refs zero and existing fields intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "noindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .blob },
        .{ .kind = .link, .linkTarget = 4, .delRule = .cascade },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    var propertyIndex: usize = 0;
    while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
        try testing.expect(!view.indexed(propertyIndex));
        try testing.expectEqual(@as(Reference, 0), view.valueIndexRef(propertyIndex));
    }
    // Every pre-existing accessor must still read the right field: this guards
    // that appending the new arrays did not disturb the earlier offset math.
    try testing.expectEqual(PropertyKind.int, view.kind(0));
    try testing.expectEqual(PropertyKind.list, view.kind(1));
    try testing.expectEqual(ElementKind.blob, view.elementKind(1));
    try testing.expectEqual(PropertyKind.link, view.kind(2));
    try testing.expect(view.propertyColumnRef(0) != 0);
    try testing.expect(view.propertyColumnRef(1) != 0);
    try testing.expect(view.backlinkRef(2) != 0); // link property got a backlink index
    try testing.expectEqual(@as(Reference, 0), view.backlinkRef(0));
    try testing.expectEqual(@as(Reference, 0), view.backlinkRef(1));
    try testing.expectEqual(@as(u16, 4), view.linkTarget(2));
    try testing.expectEqual(@as(u16, 0), view.linkTarget(0));
    try testing.expectEqual(DeletionRule.cascade, view.delRule(2));
    try testing.expectEqual(DeletionRule.nullify, view.delRule(0));
    writeTransaction.deinit();
}

test "createDefs records a per-property deletion rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "delrule.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogRef = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 2, .delRule = .cascade },
        .{ .kind = .link, .linkTarget = 3, .delRule = .block },
    });
    const view = try loadCatalog(&writeTransaction, catalogRef);
    try testing.expectEqual(DeletionRule.nullify, view.delRule(0));
    try testing.expectEqual(DeletionRule.cascade, view.delRule(1));
    try testing.expectEqual(DeletionRule.block, view.delRule(2));
    // existing per-property data still intact
    try testing.expectEqual(@as(u16, 2), view.linkTarget(1));
    writeTransaction.deinit();
}
