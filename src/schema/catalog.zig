const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");

/// The integer type counting a catalog's properties (bounded by maxPropertyCount).
pub const PropertyCount = u16;
/// Storage kind of one property: scalar int, blob, a collection
/// (list/set/dict), or a link (to-one .link, to-many .linkSet).
pub const PropertyKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3, link = 4, linkSet = 5, dict = 6 };
/// Element type of a list or set property: inline u64 ints or blob byte strings.
pub const ElementKind = enum(u8) { int = 0, blob = 1 };
/// Delete-time behavior of a link property when its target object is deleted:
/// nullify clears the dangling inbound link, cascade deletes the linked child
/// along with its owner, block refuses to delete a target while the link
/// points at it.
pub const DeletionRule = enum(u8) { nullify = 0, cascade = 1, block = 2 };
/// Everything the schema records about one property: its kind, element type,
/// link target type, deletion rule, and whether it carries a value index.
pub const PropertyDefinition = struct { kind: PropertyKind, element: ElementKind = .int, linkTarget: u16 = 0, deletionRule: DeletionRule = .nullify, indexed: bool = false };
/// A single byte-keyed dictionary entry: a byte-string key mapped to a u64 value
/// (an int, or an object key for a "dict of links" -- u64 covers both).
pub const DictEntry = struct { key: []const u8, value: u64 };
/// One property's typed value, as written by insertTyped/updateTyped and
/// decoded by getTyped. The active tag must match the property's declared
/// kind (and element kind).
pub const Value = union(enum) {
    int: u64,
    /// A blob property decodes to one of two read-side shapes:
    ///   .bytes    -- a small blob (<= inline cap): a zero-copy slice into the
    ///                mapped storage. Valid until the next MUTATING call on the
    ///                same transaction: an update/delete that frees the blob
    ///                routes a transaction-private node to the immediate-reuse pool, so
    ///                the next allocation may scribble it. Copy the bytes out
    ///                before mutating if they must survive.
    ///   .blobReference -- a blob larger than the inline cap, stored chunked and thus
    ///                without a single contiguous slice. The caller materializes
    ///                it with `blob.getAlloc(transaction, reference, allocator)` and frees the
    ///                returned buffer.
    bytes: []const u8,
    blobReference: Reference,
    listInt: []const u64,
    listBlob: []const []const u8,
    setInt: []const u64,
    setBlob: []const []const u8,
    dictInt: []const DictEntry,
    collectionRoot: Reference, // read side: getTyped returns this for list/set/dict/linkSet properties
    link: ?u64,
    linkSet: []const u64, // to-many: initial set of target objectKeys
};

// Catalog node layout:
// [propertyCount u16][nextRow u64][primaryKeyIndexReference u64][versionColumnReference u64][liveColumnReference u64]
// [propertyCount * (propertyColumnReference u64)][propertyCount * (kind u8)][propertyCount * (element u8)]
// [propertyCount * (backlinkReference u64)][propertyCount * (linkTarget u16)][propertyCount * (deletionRule u8)]
// [propertyCount * (valueIndexReference u64)][propertyCount * (indexed u8)]
//
// The value-index reference and indexed flag arrays are appended last so the earlier
// per-property arrays keep their existing offsets unchanged.
const propertyCountOffset: usize = 0;
const offNextRow: usize = 2;
const primaryKeyIndexReferenceOffset: usize = 10;
const versionColumnReferenceOffset: usize = 18;
const liveColumnReferenceOffset: usize = 26;
const keyToRowIndexReferenceOffset: usize = 34;
const offNextKey: usize = 42;
const propertyColumnsOffset: usize = 50;

/// Upper bound on properties per type; sizes the fixed buffers threaded
/// through the row and object layers.
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

/// Allocate and encode a fresh catalog node from the given field arrays and
/// return its reference. Prefer CatalogSnapshot.write: fifteen positional arguments
/// invite transposition bugs. O(propertyCount) encoding.
pub fn writeCatalog(
    transaction: *WriteTransaction,
    propertyCount: PropertyCount,
    nextRow: u64,
    keyToRowIndexReference: Reference,
    nextKey: u64,
    primaryKeyIndexReference: Reference,
    versionColumnReference: Reference,
    liveColumnReference: Reference,
    propertyColumnReferences: []const Reference,
    kinds: []const PropertyKind,
    elements: []const ElementKind,
    backlinks: []const Reference,
    targets: []const u16,
    rules: []const DeletionRule,
    valueIndexReferences: []const Reference,
    indexedFlags: []const bool,
) !Reference {
    const allocation = try transaction.alloc(catalogSize(propertyCount));
    std.mem.writeInt(u16, allocation.bytes[propertyCountOffset..][0..2], propertyCount, .little);
    std.mem.writeInt(u64, allocation.bytes[offNextRow..][0..8], nextRow, .little);
    std.mem.writeInt(u64, allocation.bytes[keyToRowIndexReferenceOffset..][0..8], keyToRowIndexReference, .little);
    std.mem.writeInt(u64, allocation.bytes[offNextKey..][0..8], nextKey, .little);
    std.mem.writeInt(u64, allocation.bytes[primaryKeyIndexReferenceOffset..][0..8], primaryKeyIndexReference, .little);
    std.mem.writeInt(u64, allocation.bytes[versionColumnReferenceOffset..][0..8], versionColumnReference, .little);
    std.mem.writeInt(u64, allocation.bytes[liveColumnReferenceOffset..][0..8], liveColumnReference, .little);
    for (propertyColumnReferences, 0..) |reference, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[propertyColumnsOffset + propertyIndex * 8 ..][0..8], reference, .little);
    }
    const kindsBase = kindsOffset(propertyCount);
    for (kinds, 0..) |kind, propertyIndex| allocation.bytes[kindsBase + propertyIndex] = @intFromEnum(kind);
    const elementsBase = elemsOffset(propertyCount);
    for (elements, 0..) |element, propertyIndex| allocation.bytes[elementsBase + propertyIndex] = @intFromEnum(element);
    const blo = backlinksOffset(propertyCount);
    for (backlinks, 0..) |backlinkReference, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[blo + propertyIndex * 8 ..][0..8], backlinkReference, .little);
    }
    const targetsBase = targetsOffset(propertyCount);
    for (targets, 0..) |target, propertyIndex| std.mem.writeInt(u16, allocation.bytes[targetsBase + propertyIndex * 2 ..][0..2], target, .little);
    const rulesBase = rulesOffset(propertyCount);
    for (rules, 0..) |rule, propertyIndex| allocation.bytes[rulesBase + propertyIndex] = @intFromEnum(rule);
    const valueIndexOffset = valueIndexRefsOffset(propertyCount);
    for (valueIndexReferences, 0..) |valueIndexReference, propertyIndex| {
        std.mem.writeInt(u64, allocation.bytes[valueIndexOffset + propertyIndex * 8 ..][0..8], valueIndexReference, .little);
    }
    const ifo = indexedFlagsOffset(propertyCount);
    for (indexedFlags, 0..) |flag, propertyIndex| allocation.bytes[ifo + propertyIndex] = @intFromBool(flag);
    return allocation.reference;
}

/// Create an empty type from explicit per-property definitions: allocates a
/// column per property, backlink indexes for link properties, value indexes
/// for indexed properties, version/live columns, the primaryKey and key->row
/// indexes, and the catalog node itself. definitions[0].kind must be .int
/// (the primary key). O(propertyCount) node allocations.
pub fn createFromDefinitions(transaction: *WriteTransaction, definitions: []const PropertyDefinition) !Reference {
    std.debug.assert(definitions.len >= 1 and definitions[0].kind == .int);
    const propertyCount: PropertyCount = @intCast(definitions.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var propertyColumnReferences: [maxPropertyCount]Reference = undefined;
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    var elements: [maxPropertyCount]ElementKind = undefined;
    var backlinks: [maxPropertyCount]Reference = undefined;
    var targets: [maxPropertyCount]u16 = undefined;
    var rules: [maxPropertyCount]DeletionRule = undefined;
    var valueIndexReferences: [maxPropertyCount]Reference = undefined;
    var indexedFlags: [maxPropertyCount]bool = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        propertyColumnReferences[propertyIndex] = try Column.create(transaction);
        kinds[propertyIndex] = definitions[propertyIndex].kind;
        elements[propertyIndex] = definitions[propertyIndex].element;
        backlinks[propertyIndex] = if (definitions[propertyIndex].kind == .link or definitions[propertyIndex].kind == .linkSet) try Index.create(transaction) else 0;
        targets[propertyIndex] = definitions[propertyIndex].linkTarget;
        rules[propertyIndex] = definitions[propertyIndex].deletionRule;
        indexedFlags[propertyIndex] = definitions[propertyIndex].indexed;
        valueIndexReferences[propertyIndex] = if (definitions[propertyIndex].indexed) try Index.create(transaction) else 0;
    }
    const versionColumnReference = try Column.create(transaction);
    const liveColumnReference = try Column.create(transaction);
    const primaryKeyIndexReference = try Index.create(transaction);
    const keyToRowIndexReference = try Index.create(transaction);
    return writeCatalog(
        transaction,
        propertyCount,
        0,
        keyToRowIndexReference,
        0,
        primaryKeyIndexReference,
        versionColumnReference,
        liveColumnReference,
        propertyColumnReferences[0..propertyCount],
        kinds[0..propertyCount],
        elements[0..propertyCount],
        backlinks[0..propertyCount],
        targets[0..propertyCount],
        rules[0..propertyCount],
        valueIndexReferences[0..propertyCount],
        indexedFlags[0..propertyCount],
    );
}

/// Create an empty type from bare property kinds; every property gets
/// element = int and the other definition defaults.
pub fn createTyped(transaction: *WriteTransaction, kinds: []const PropertyKind) !Reference {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const propertyCount: PropertyCount = @intCast(kinds.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var definitions: [maxPropertyCount]PropertyDefinition = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) definitions[propertyIndex] = .{ .kind = kinds[propertyIndex], .element = .int };
    return createFromDefinitions(transaction, definitions[0..propertyCount]);
}

/// Create an empty type of `propertyCount` all-int properties: property
/// columns, a version column, a live column, and an empty primaryKey index.
pub fn create(transaction: *WriteTransaction, propertyCount: PropertyCount) !Reference {
    std.debug.assert(propertyCount <= maxPropertyCount);
    var allInt: [maxPropertyCount]PropertyKind = undefined;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) allInt[propertyIndex] = .int;
    return createTyped(transaction, allInt[0..propertyCount]);
}

/// A read-only, zero-copy view of a catalog node: the fixed header fields
/// parsed out plus a `bytes` slice into mapped storage for the per-property
/// arrays. The slice is invalidated when the catalog node is rewritten or
/// freed, so capture what you need before any catalog mutation; use
/// CatalogSnapshot when mutating.
pub const CatalogView = struct {
    propertyCount: PropertyCount,
    nextRow: u64,
    keyToRowIndexReference: Reference,
    nextKey: u64,
    primaryKeyIndexReference: Reference,
    versionColumnReference: Reference,
    liveColumnReference: Reference,
    bytes: []const u8,

    /// The reference of property `propertyIndex`'s column tree.
    pub fn propertyColumnReference(self: CatalogView, propertyIndex: usize) Reference {
        return std.mem.readInt(u64, self.bytes[propertyColumnsOffset + propertyIndex * 8 ..][0..8], .little);
    }

    /// The storage kind of property `propertyIndex` (validated at load time).
    pub fn kind(self: CatalogView, propertyIndex: usize) PropertyKind {
        return @enumFromInt(self.bytes[kindsOffset(self.propertyCount) + propertyIndex]);
    }

    /// The element type of list/set property `propertyIndex`.
    pub fn elementKind(self: CatalogView, propertyIndex: usize) ElementKind {
        const elementsBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + self.propertyCount;
        return @enumFromInt(self.bytes[elementsBase + propertyIndex]);
    }

    /// The reference of link property `propertyIndex`'s backlink index
    /// (target objectKey -> set of source objectKeys); 0 for non-link properties.
    pub fn backlinkReference(self: CatalogView, propertyIndex: usize) Reference {
        const blo = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return std.mem.readInt(u64, self.bytes[blo + propertyIndex * 8 ..][0..8], .little);
    }

    /// The type id link property `propertyIndex` points at.
    pub fn linkTarget(self: CatalogView, propertyIndex: usize) u16 {
        const targetsBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8;
        return std.mem.readInt(u16, self.bytes[targetsBase + propertyIndex * 2 ..][0..2], .little);
    }

    /// The deletion rule of link property `propertyIndex`.
    pub fn deletionRule(self: CatalogView, propertyIndex: usize) DeletionRule {
        const rulesBase = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return @enumFromInt(self.bytes[rulesBase + propertyIndex]);
    }

    /// The reference of property `propertyIndex`'s value index
    /// (value -> set of objectKeys); 0 when the property is not indexed.
    pub fn valueIndexReference(self: CatalogView, propertyIndex: usize) Reference {
        const valueIndexOffset = valueIndexRefsOffset(self.propertyCount);
        return std.mem.readInt(u64, self.bytes[valueIndexOffset + propertyIndex * 8 ..][0..8], .little);
    }

    /// True when property `propertyIndex` maintains a value index.
    pub fn indexed(self: CatalogView, propertyIndex: usize) bool {
        const ifo = indexedFlagsOffset(self.propertyCount);
        return self.bytes[ifo + propertyIndex] != 0;
    }
};

/// Parse the catalog node at `catalogReference` into a CatalogView. The view's
/// bytes slice points into mapped storage and is invalidated when the catalog
/// node is rewritten or freed (any catalog mutation). O(propertyCount)
/// validation.
///
/// All per-property enum bytes (kind, element kind, deletion rule) are validated
/// here, ONCE, so the CatalogView accessors can stay infallible. These bytes
/// come straight from the mapped file: a corrupted value must surface as
/// error.Corrupt, never as a panic (ReleaseSafe) or undefined behavior
/// (ReleaseFast) from an unchecked @enumFromInt.
pub fn loadCatalog(transaction: anytype, catalogReference: Reference) !CatalogView {
    const propertyCountBytes = try transaction.dereference(catalogReference, 2);
    const propertyCount = std.mem.readInt(u16, propertyCountBytes[0..2], .little);
    if (propertyCount > maxPropertyCount) return error.Corrupt;
    const bytes = try transaction.dereference(catalogReference, catalogSize(propertyCount));
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
        .keyToRowIndexReference = std.mem.readInt(u64, bytes[keyToRowIndexReferenceOffset..][0..8], .little),
        .nextKey = std.mem.readInt(u64, bytes[offNextKey..][0..8], .little),
        .primaryKeyIndexReference = std.mem.readInt(u64, bytes[primaryKeyIndexReferenceOffset..][0..8], .little),
        .versionColumnReference = std.mem.readInt(u64, bytes[versionColumnReferenceOffset..][0..8], .little),
        .liveColumnReference = std.mem.readInt(u64, bytes[liveColumnReferenceOffset..][0..8], .little),
        .bytes = bytes,
    };
}

/// One property's full catalog record, as carried by CatalogSnapshot.
pub const PropertySnapshot = struct {
    column: Reference,
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
    keyToRowIndexReference: Reference,
    nextKey: u64,
    primaryKeyIndexReference: Reference,
    versionColumnReference: Reference,
    liveColumnReference: Reference,
    properties: [maxPropertyCount]PropertySnapshot,
    /// The node this snapshot was loaded from and its on-disk size, so
    /// replace() can free it. propertyCount may change after load (migrations),
    /// so the size is captured here, not recomputed.
    source: Reference,
    sourceLen: usize,

    /// Copy every field of the catalog at `catalogReference` into an owned
    /// snapshot. O(propertyCount).
    pub fn load(transaction: anytype, catalogReference: Reference) !CatalogSnapshot {
        const view = try loadCatalog(transaction, catalogReference);
        var snapshot: CatalogSnapshot = undefined;
        snapshot.source = catalogReference;
        snapshot.sourceLen = catalogSize(view.propertyCount);
        snapshot.propertyCount = view.propertyCount;
        snapshot.nextRow = view.nextRow;
        snapshot.keyToRowIndexReference = view.keyToRowIndexReference;
        snapshot.nextKey = view.nextKey;
        snapshot.primaryKeyIndexReference = view.primaryKeyIndexReference;
        snapshot.versionColumnReference = view.versionColumnReference;
        snapshot.liveColumnReference = view.liveColumnReference;
        var propertyIndex: usize = 0;
        while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
            snapshot.properties[propertyIndex] = .{
                .column = view.propertyColumnReference(propertyIndex),
                .kind = view.kind(propertyIndex),
                .element = view.elementKind(propertyIndex),
                .backlink = view.backlinkReference(propertyIndex),
                .target = view.linkTarget(propertyIndex),
                .rule = view.deletionRule(propertyIndex),
                .valueIndex = view.valueIndexReference(propertyIndex),
                .indexed = view.indexed(propertyIndex),
            };
        }
        return snapshot;
    }

    /// Allocate and encode a fresh catalog node from this snapshot.
    pub fn write(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        var columns: [maxPropertyCount]Reference = undefined;
        var kinds: [maxPropertyCount]PropertyKind = undefined;
        var elements: [maxPropertyCount]ElementKind = undefined;
        var backlinks: [maxPropertyCount]Reference = undefined;
        var targets: [maxPropertyCount]u16 = undefined;
        var rules: [maxPropertyCount]DeletionRule = undefined;
        var valueIndexReferences: [maxPropertyCount]Reference = undefined;
        var indexedFlags: [maxPropertyCount]bool = undefined;
        const propertyCount = self.propertyCount;
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const property = self.properties[propertyIndex];
            columns[propertyIndex] = property.column;
            kinds[propertyIndex] = property.kind;
            elements[propertyIndex] = property.element;
            backlinks[propertyIndex] = property.backlink;
            targets[propertyIndex] = property.target;
            rules[propertyIndex] = property.rule;
            valueIndexReferences[propertyIndex] = property.valueIndex;
            indexedFlags[propertyIndex] = property.indexed;
        }
        return writeCatalog(
            transaction,
            propertyCount,
            self.nextRow,
            self.keyToRowIndexReference,
            self.nextKey,
            self.primaryKeyIndexReference,
            self.versionColumnReference,
            self.liveColumnReference,
            columns[0..propertyCount],
            kinds[0..propertyCount],
            elements[0..propertyCount],
            backlinks[0..propertyCount],
            targets[0..propertyCount],
            rules[0..propertyCount],
            valueIndexReferences[0..propertyCount],
            indexedFlags[0..propertyCount],
        );
    }

    /// Write the snapshot as a fresh node and free the node it was loaded
    /// from. This is the normal way to rewrite a catalog within one database:
    /// the old node is garbage the moment the caller adopts the new reference, and a
    /// transaction-private old node is reused by the very next same-size catalog write,
    /// so catalog churn stops growing the file. Do NOT use when the source
    /// lives in a different database (copyTypeRows) or must stay readable.
    pub fn replace(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        const newReference = try self.write(transaction);
        try transaction.free(self.source, self.sourceLen);
        return newReference;
    }
};

/// The number of properties recorded in the catalog at `catalogReference`.
pub fn loadPropertyCount(transaction: anytype, catalogReference: Reference) !PropertyCount {
    const view = try loadCatalog(transaction, catalogReference);
    return view.propertyCount;
}

/// Number of live rows, as tracked by the primaryKey index (a single-node
/// count read; tombstoned rows are already removed from the index).
pub fn liveCount(transaction: anytype, catalogReference: Reference) !u64 {
    const view = try loadCatalog(transaction, catalogReference);
    return Index.count(transaction, view.primaryKeyIndexReference);
}

/// Resolve an object key to its physical row via the key-to-row index, or
/// null if the objectKey has no mapping. One index descent, O(log n).
pub fn objectKeyToRow(transaction: anytype, catalogReference: Reference, objectKey: u64) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    return Index.get(transaction, view.keyToRowIndexReference, objectKey);
}

/// Resolve a primary key to its stable object key via the primaryKey index,
/// or null if the primaryKey has no mapping. One index descent, O(log n).
pub fn primaryKeyToObjectKey(transaction: anytype, catalogReference: Reference, primaryKey: u64) !?u64 {
    const view = try loadCatalog(transaction, catalogReference);
    return Index.get(transaction, view.primaryKeyIndexReference, primaryKey);
}

/// Resolve (catalogReference, primaryKey, property) to the property column reference and
/// the physical row; null if the primaryKey is absent or the row is
/// tombstoned. Two index descents (primaryKey -> objectKey, objectKey -> row)
/// plus a liveness read, O(log n).
pub fn resolveProperty(transaction: anytype, catalogReference: Reference, primaryKey: u64, property: usize) !?struct { row: u64, propertyColumn: Reference } {
    const view = try loadCatalog(transaction, catalogReference);
    const objectKey = (try Index.get(transaction, view.primaryKeyIndexReference, primaryKey)) orelse return null;
    const row = (try Index.get(transaction, view.keyToRowIndexReference, objectKey)) orelse return null;
    if ((try Column.get(transaction, view.liveColumnReference, row)) == 0) return null;
    return .{ .row = row, .propertyColumn = view.propertyColumnReference(property) };
}

/// Write `newRoot` into property `property`'s column at `row`, bump that
/// row's version stamp, and return the new catalog reference (copy-on-write). Two
/// column walks plus a catalog rewrite, O(log n + propertyCount).
pub fn replaceCollectionRoot(transaction: *WriteTransaction, catalogReference: Reference, row: u64, property: usize, newRoot: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogReference);
    snapshot.properties[property].column = try Column.set(transaction, snapshot.properties[property].column, row, newRoot);
    snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, row, transaction.newVersion);
    return snapshot.replace(transaction);
}

/// Write a new backlink reference into property `propertyIndex` and return the new
/// catalog reference, preserving everything else. O(propertyCount) catalog rewrite.
pub fn setBacklinkReference(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, newBacklink: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogReference);
    snapshot.properties[propertyIndex].backlink = newBacklink;
    return snapshot.replace(transaction);
}

/// Write a new value-index reference into property `propertyIndex` and return the
/// new catalog reference, preserving everything else. O(propertyCount) catalog
/// rewrite.
pub fn setValueIndexReference(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, newValueIndex: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogReference);
    snapshot.properties[propertyIndex].valueIndex = newValueIndex;
    return snapshot.replace(transaction);
}

/// Write a new column reference into property `propertyIndex` and return the new
/// catalog reference, preserving everything else. O(propertyCount) catalog rewrite.
pub fn setPropertyColumnReference(transaction: *WriteTransaction, catalogReference: Reference, propertyIndex: usize, newColumn: Reference) !Reference {
    var snapshot = try CatalogSnapshot.load(transaction, catalogReference);
    snapshot.properties[propertyIndex].column = newColumn;
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
    const catalogReference = try create(&writeTransaction, 3);
    try testing.expectEqual(@as(PropertyCount, 3), try loadPropertyCount(&writeTransaction, catalogReference));
    try testing.expectEqual(@as(u64, 0), try liveCount(&writeTransaction, catalogReference));
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .link, .linkTarget = 3, .deletionRule = .cascade },
        .{ .kind = .list, .element = .blob },
    });
    const snapshot = try CatalogSnapshot.load(&writeTransaction, catalogReference);
    const copyReference = try snapshot.write(&writeTransaction);
    const view0 = try loadCatalog(&writeTransaction, catalogReference);
    const view1 = try loadCatalog(&writeTransaction, copyReference);
    try testing.expectEqual(view0.propertyCount, view1.propertyCount);
    try testing.expectEqual(view0.nextRow, view1.nextRow);
    try testing.expectEqual(view0.nextKey, view1.nextKey);
    try testing.expectEqual(view0.primaryKeyIndexReference, view1.primaryKeyIndexReference);
    try testing.expectEqual(view0.keyToRowIndexReference, view1.keyToRowIndexReference);
    try testing.expectEqual(view0.versionColumnReference, view1.versionColumnReference);
    try testing.expectEqual(view0.liveColumnReference, view1.liveColumnReference);
    var propertyIndex: usize = 0;
    while (propertyIndex < view0.propertyCount) : (propertyIndex += 1) {
        try testing.expectEqual(view0.propertyColumnReference(propertyIndex), view1.propertyColumnReference(propertyIndex));
        try testing.expectEqual(view0.kind(propertyIndex), view1.kind(propertyIndex));
        try testing.expectEqual(view0.elementKind(propertyIndex), view1.elementKind(propertyIndex));
        try testing.expectEqual(view0.backlinkReference(propertyIndex), view1.backlinkReference(propertyIndex));
        try testing.expectEqual(view0.linkTarget(propertyIndex), view1.linkTarget(propertyIndex));
        try testing.expectEqual(view0.deletionRule(propertyIndex), view1.deletionRule(propertyIndex));
        try testing.expectEqual(view0.valueIndexReference(propertyIndex), view1.valueIndexReference(propertyIndex));
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
    const catalogReference = try create(&writeTransaction, 2);
    _ = try loadCatalog(&writeTransaction, catalogReference); // clean before corruption

    // Corrupt a kind byte (out-of-range enum value) directly in the mapping.
    const catalogOffset: usize = @intCast(catalogReference);
    const kindByteOff = catalogOffset + propertyColumnsOffset + 2 * 8; // kindsOffset(2), property 0
    const savedKind = database.store.map[kindByteOff];
    database.store.map[kindByteOff] = 200;
    try testing.expectError(error.Corrupt, loadCatalog(&writeTransaction, catalogReference));
    database.store.map[kindByteOff] = savedKind;
    _ = try loadCatalog(&writeTransaction, catalogReference); // restored

    // Corrupt the property count to an implausible value.
    std.mem.writeInt(u16, database.store.map[catalogOffset..][0..2], 6000, .little);
    try testing.expectError(error.Corrupt, loadCatalog(&writeTransaction, catalogReference));
}

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogReference = try createTyped(&writeTransaction, &.{ .int, .blob, .int });
    const view = try loadCatalog(&writeTransaction, catalogReference);
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .int },
        .{ .kind = .set, .element = .int },
        .{ .kind = .list, .element = .blob },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .link },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(PropertyKind.link, view.kind(2));
    try testing.expect(view.backlinkReference(2) != 0);
    try testing.expectEqual(@as(Reference, 0), view.backlinkReference(0));
    try testing.expectEqual(@as(Reference, 0), view.backlinkReference(1));
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 3 },
        .{ .kind = .linkSet, .linkTarget = 7 },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const view = try loadCatalog(&writeTransaction, catalogReference);
    try testing.expect(view.keyToRowIndexReference != 0);
    try testing.expectEqual(@as(u64, 0), view.nextKey);
    writeTransaction.deinit();
}

test "catalog persists indexed flag and value index reference" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
    try testing.expect(view.indexed(1));
    try testing.expect(!view.indexed(0));
    try testing.expect(!view.indexed(2));
    try testing.expect(view.valueIndexReference(1) != 0);
    try testing.expectEqual(@as(Reference, 0), view.valueIndexReference(0));
    try testing.expectEqual(@as(Reference, 0), view.valueIndexReference(2));
    const vidx1 = view.valueIndexReference(1);
    // Round-trip through a full catalog rebuild (setPropertyColumnReference rewrites every
    // field) and assert both the flag and the value-index reference survive.
    const catalog2 = try setPropertyColumnReference(&writeTransaction, catalogReference, 2, view.propertyColumnReference(2));
    const v2 = try loadCatalog(&writeTransaction, catalog2);
    try testing.expect(v2.indexed(1));
    try testing.expect(!v2.indexed(0));
    try testing.expect(!v2.indexed(2));
    try testing.expectEqual(vidx1, v2.valueIndexReference(1));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexReference(0));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexReference(2));
    writeTransaction.deinit();
}

test "non-indexed catalog: value index references zero and existing fields intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "noindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .list, .element = .blob },
        .{ .kind = .link, .linkTarget = 4, .deletionRule = .cascade },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
    var propertyIndex: usize = 0;
    while (propertyIndex < view.propertyCount) : (propertyIndex += 1) {
        try testing.expect(!view.indexed(propertyIndex));
        try testing.expectEqual(@as(Reference, 0), view.valueIndexReference(propertyIndex));
    }
    // Every pre-existing accessor must still read the right field: this guards
    // that appending the new arrays did not disturb the earlier offset math.
    try testing.expectEqual(PropertyKind.int, view.kind(0));
    try testing.expectEqual(PropertyKind.list, view.kind(1));
    try testing.expectEqual(ElementKind.blob, view.elementKind(1));
    try testing.expectEqual(PropertyKind.link, view.kind(2));
    try testing.expect(view.propertyColumnReference(0) != 0);
    try testing.expect(view.propertyColumnReference(1) != 0);
    try testing.expect(view.backlinkReference(2) != 0); // link property got a backlink index
    try testing.expectEqual(@as(Reference, 0), view.backlinkReference(0));
    try testing.expectEqual(@as(Reference, 0), view.backlinkReference(1));
    try testing.expectEqual(@as(u16, 4), view.linkTarget(2));
    try testing.expectEqual(@as(u16, 0), view.linkTarget(0));
    try testing.expectEqual(DeletionRule.cascade, view.deletionRule(2));
    try testing.expectEqual(DeletionRule.nullify, view.deletionRule(0));
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
    const catalogReference = try createFromDefinitions(&writeTransaction, &.{
        .{ .kind = .int },
        .{ .kind = .link, .linkTarget = 2, .deletionRule = .cascade },
        .{ .kind = .link, .linkTarget = 3, .deletionRule = .block },
    });
    const view = try loadCatalog(&writeTransaction, catalogReference);
    try testing.expectEqual(DeletionRule.nullify, view.deletionRule(0));
    try testing.expectEqual(DeletionRule.cascade, view.deletionRule(1));
    try testing.expectEqual(DeletionRule.block, view.deletionRule(2));
    // existing per-property data still intact
    try testing.expectEqual(@as(u16, 2), view.linkTarget(1));
    writeTransaction.deinit();
}
