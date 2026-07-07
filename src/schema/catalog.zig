const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");

pub const PropertyCount = u16;
pub const PropertyKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3, link = 4, link_set = 5, dict = 6 };
pub const ElemKind = enum(u8) { int = 0, blob = 1 };
pub const DeletionRule = enum(u8) { nullify = 0, cascade = 1, block = 2 };
pub const PropertyDefinition = struct { kind: PropertyKind, elem: ElemKind = .int, link_target: u16 = 0, del_rule: DeletionRule = .nullify, indexed: bool = false };
// A single byte-keyed dictionary entry: a byte-string key mapped to a u64 value
// (an int, or an object key for a "dict of links" -- u64 covers both).
pub const DictEntry = struct { key: []const u8, val: u64 };
pub const Value = union(enum) {
    int: u64,
    // A blob property decodes to one of two read-side shapes:
    //   .bytes    -- a small blob (<= inline cap): a zero-copy slice into the
    //                mapped storage. Valid until the next MUTATING call on the
    //                same transaction: an update/delete that frees the blob
    //                routes a transaction-private node to the immediate-reuse pool, so
    //                the next allocation may scribble it. Copy the bytes out
    //                before mutating if they must survive.
    //   .blob_ref -- a blob larger than the inline cap, stored chunked and thus
    //                without a single contiguous slice. The caller materializes
    //                it with `blob.getAlloc(transaction, ref, allocator)` and frees the
    //                returned buffer.
    bytes: []const u8,
    blob_ref: Reference,
    list_int: []const u64,
    list_blob: []const []const u8,
    set_int: []const u64,
    set_blob: []const []const u8,
    dict_int: []const DictEntry,
    coll_root: Reference, // read side: getTyped returns this for list/set/dict/link_set properties
    link: ?u64,
    link_set: []const u64, // to-many: initial set of target objectKeys
};

// Catalog node layout:
// [propertyCount u16][next_row u64][primaryKeyIndexRef u64][version_col_ref u64][live_col_ref u64]
// [propertyCount * (propertyColumnRef u64)][propertyCount * (kind u8)][propertyCount * (elem u8)]
// [propertyCount * (backlink_ref u64)][propertyCount * (link_target u16)][propertyCount * (del_rule u8)]
// [propertyCount * (value_index_ref u64)][propertyCount * (indexed u8)]
//
// The value-index ref and indexed flag arrays are appended last so the earlier
// per-property arrays keep their existing offsets unchanged.
const propertyCountOffset: usize = 0;
const off_next_row: usize = 2;
const primaryKeyIndexRefOffset: usize = 10;
const off_version_col_ref: usize = 18;
const off_live_col_ref: usize = 26;
const off_keyrow_index_ref: usize = 34;
const off_next_key: usize = 42;
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
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    primaryKeyIndexRef: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    propertyColumnRefs: []const Reference,
    kinds: []const PropertyKind,
    elems: []const ElemKind,
    backlinks: []const Reference,
    targets: []const u16,
    rules: []const DeletionRule,
    value_index_refs: []const Reference,
    indexed_flags: []const bool,
) !Reference {
    const a = try transaction.alloc(catalogSize(propertyCount));
    std.mem.writeInt(u16, a.bytes[propertyCountOffset..][0..2], propertyCount, .little);
    std.mem.writeInt(u64, a.bytes[off_next_row..][0..8], next_row, .little);
    std.mem.writeInt(u64, a.bytes[off_keyrow_index_ref..][0..8], keyrow_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_next_key..][0..8], next_key, .little);
    std.mem.writeInt(u64, a.bytes[primaryKeyIndexRefOffset..][0..8], primaryKeyIndexRef, .little);
    std.mem.writeInt(u64, a.bytes[off_version_col_ref..][0..8], version_col_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_live_col_ref..][0..8], live_col_ref, .little);
    for (propertyColumnRefs, 0..) |ref, i| {
        std.mem.writeInt(u64, a.bytes[propertyColumnsOffset + i * 8 ..][0..8], ref, .little);
    }
    const ko = kindsOffset(propertyCount);
    for (kinds, 0..) |k, i| a.bytes[ko + i] = @intFromEnum(k);
    const eo = elemsOffset(propertyCount);
    for (elems, 0..) |e, i| a.bytes[eo + i] = @intFromEnum(e);
    const blo = backlinksOffset(propertyCount);
    for (backlinks, 0..) |bref, i| {
        std.mem.writeInt(u64, a.bytes[blo + i * 8 ..][0..8], bref, .little);
    }
    const to = targetsOffset(propertyCount);
    for (targets, 0..) |t, i| std.mem.writeInt(u16, a.bytes[to + i * 2 ..][0..2], t, .little);
    const ro = rulesOffset(propertyCount);
    for (rules, 0..) |r, i| a.bytes[ro + i] = @intFromEnum(r);
    const valueIndexOffset = valueIndexRefsOffset(propertyCount);
    for (value_index_refs, 0..) |vref, i| {
        std.mem.writeInt(u64, a.bytes[valueIndexOffset + i * 8 ..][0..8], vref, .little);
    }
    const ifo = indexedFlagsOffset(propertyCount);
    for (indexed_flags, 0..) |flag, i| a.bytes[ifo + i] = @intFromBool(flag);
    return a.ref;
}

// createDefs allocates columns, a primaryKey index, version/live columns, and a catalog
// node from explicit per-property definitions. defs[0].kind must be .int (the primaryKey).
pub fn createDefs(transaction: *WriteTransaction, defs: []const PropertyDefinition) !Reference {
    std.debug.assert(defs.len >= 1 and defs[0].kind == .int);
    const propertyCount: PropertyCount = @intCast(defs.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var propertyColumnRefs: [maxPropertyCount]Reference = undefined;
    var kinds: [maxPropertyCount]PropertyKind = undefined;
    var elems: [maxPropertyCount]ElemKind = undefined;
    var backlinks: [maxPropertyCount]Reference = undefined;
    var targets: [maxPropertyCount]u16 = undefined;
    var rules: [maxPropertyCount]DeletionRule = undefined;
    var value_index_refs: [maxPropertyCount]Reference = undefined;
    var indexed_flags: [maxPropertyCount]bool = undefined;
    var i: usize = 0;
    while (i < propertyCount) : (i += 1) {
        propertyColumnRefs[i] = try Column.create(transaction);
        kinds[i] = defs[i].kind;
        elems[i] = defs[i].elem;
        backlinks[i] = if (defs[i].kind == .link or defs[i].kind == .link_set) try Index.create(transaction) else 0;
        targets[i] = defs[i].link_target;
        rules[i] = defs[i].del_rule;
        indexed_flags[i] = defs[i].indexed;
        value_index_refs[i] = if (defs[i].indexed) try Index.create(transaction) else 0;
    }
    const version_col_ref = try Column.create(transaction);
    const live_col_ref = try Column.create(transaction);
    const primaryKeyIndexRef = try Index.create(transaction);
    const keyrow = try Index.create(transaction);
    return writeCatalog(
        transaction,
        propertyCount,
        0,
        keyrow,
        0,
        primaryKeyIndexRef,
        version_col_ref,
        live_col_ref,
        propertyColumnRefs[0..propertyCount],
        kinds[0..propertyCount],
        elems[0..propertyCount],
        backlinks[0..propertyCount],
        targets[0..propertyCount],
        rules[0..propertyCount],
        value_index_refs[0..propertyCount],
        indexed_flags[0..propertyCount],
    );
}

// createTyped keeps its scalar-only signature; every property gets elem = int.
pub fn createTyped(transaction: *WriteTransaction, kinds: []const PropertyKind) !Reference {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const propertyCount: PropertyCount = @intCast(kinds.len);
    std.debug.assert(propertyCount <= maxPropertyCount);
    var defs: [maxPropertyCount]PropertyDefinition = undefined;
    var i: usize = 0;
    while (i < propertyCount) : (i += 1) defs[i] = .{ .kind = kinds[i], .elem = .int };
    return createDefs(transaction, defs[0..propertyCount]);
}

// Create propertyCount property columns, a version column, a live column, and an
// empty primaryKey index. All property kinds default to .int.
pub fn create(transaction: *WriteTransaction, propertyCount: PropertyCount) !Reference {
    std.debug.assert(propertyCount <= maxPropertyCount);
    var all_int: [maxPropertyCount]PropertyKind = undefined;
    var i: usize = 0;
    while (i < propertyCount) : (i += 1) all_int[i] = .int;
    return createTyped(transaction, all_int[0..propertyCount]);
}

pub const CatalogView = struct {
    propertyCount: PropertyCount,
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    primaryKeyIndexRef: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    bytes: []const u8,

    pub fn propertyColumnRef(self: CatalogView, i: usize) Reference {
        return std.mem.readInt(u64, self.bytes[propertyColumnsOffset + i * 8 ..][0..8], .little);
    }

    pub fn kind(self: CatalogView, i: usize) PropertyKind {
        const kinds_offset = propertyColumnsOffset + @as(usize, self.propertyCount) * 8;
        return @enumFromInt(self.bytes[kinds_offset + i]);
    }

    pub fn elemKind(self: CatalogView, i: usize) ElemKind {
        const eo = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + self.propertyCount;
        return @enumFromInt(self.bytes[eo + i]);
    }

    pub fn backlinkRef(self: CatalogView, i: usize) Reference {
        const blo = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return std.mem.readInt(u64, self.bytes[blo + i * 8 ..][0..8], .little);
    }

    pub fn linkTarget(self: CatalogView, i: usize) u16 {
        const to = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8;
        return std.mem.readInt(u16, self.bytes[to + i * 2 ..][0..2], .little);
    }

    pub fn delRule(self: CatalogView, i: usize) DeletionRule {
        const ro = propertyColumnsOffset + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2 + @as(usize, self.propertyCount) * 8 + @as(usize, self.propertyCount) * 2;
        return @enumFromInt(self.bytes[ro + i]);
    }

    pub fn valueIndexRef(self: CatalogView, i: usize) Reference {
        const valueIndexOffset = valueIndexRefsOffset(self.propertyCount);
        return std.mem.readInt(u64, self.bytes[valueIndexOffset + i * 8 ..][0..8], .little);
    }

    pub fn indexed(self: CatalogView, i: usize) bool {
        const ifo = indexedFlagsOffset(self.propertyCount);
        return self.bytes[ifo + i] != 0;
    }
};

// Deref the catalog at catalogRef, read propertyCount, then deref the full node and parse
// all fixed fields. Returns a CatalogView whose bytes slice is valid for the
// lifetime of the transaction.
//
// All per-property enum bytes (kind, elem kind, deletion rule) are validated
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
        const ko = kindsOffset(propertyCount);
        const eo = elemsOffset(propertyCount);
        const ro = rulesOffset(propertyCount);
        var p: usize = 0;
        while (p < propertyCount) : (p += 1) {
            if (std.enums.fromInt(PropertyKind, bytes[ko + p]) == null) return error.Corrupt;
            if (std.enums.fromInt(ElemKind, bytes[eo + p]) == null) return error.Corrupt;
            if (std.enums.fromInt(DeletionRule, bytes[ro + p]) == null) return error.Corrupt;
        }
    }
    return CatalogView{
        .propertyCount = propertyCount,
        .next_row = std.mem.readInt(u64, bytes[off_next_row..][0..8], .little),
        .keyrow_index_ref = std.mem.readInt(u64, bytes[off_keyrow_index_ref..][0..8], .little),
        .next_key = std.mem.readInt(u64, bytes[off_next_key..][0..8], .little),
        .primaryKeyIndexRef = std.mem.readInt(u64, bytes[primaryKeyIndexRefOffset..][0..8], .little),
        .version_col_ref = std.mem.readInt(u64, bytes[off_version_col_ref..][0..8], .little),
        .live_col_ref = std.mem.readInt(u64, bytes[off_live_col_ref..][0..8], .little),
        .bytes = bytes,
    };
}

/// One property's full catalog record, as carried by CatalogSnapshot.
pub const PropertySnapshot = struct {
    col: Reference,
    kind: PropertyKind,
    elem: ElemKind,
    backlink: Reference,
    target: u16,
    rule: DeletionRule,
    value_index: Reference,
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
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    primaryKeyIndexRef: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    properties: [maxPropertyCount]PropertySnapshot,
    /// The node this snapshot was loaded from and its on-disk size, so
    /// replace() can free it. propertyCount may change after load (migrations),
    /// so the size is captured here, not recomputed.
    source: Reference,
    source_len: usize,

    pub fn load(transaction: anytype, catalogRef: Reference) !CatalogSnapshot {
        const v = try loadCatalog(transaction, catalogRef);
        var s: CatalogSnapshot = undefined;
        s.source = catalogRef;
        s.source_len = catalogSize(v.propertyCount);
        s.propertyCount = v.propertyCount;
        s.next_row = v.next_row;
        s.keyrow_index_ref = v.keyrow_index_ref;
        s.next_key = v.next_key;
        s.primaryKeyIndexRef = v.primaryKeyIndexRef;
        s.version_col_ref = v.version_col_ref;
        s.live_col_ref = v.live_col_ref;
        var j: usize = 0;
        while (j < v.propertyCount) : (j += 1) {
            s.properties[j] = .{
                .col = v.propertyColumnRef(j),
                .kind = v.kind(j),
                .elem = v.elemKind(j),
                .backlink = v.backlinkRef(j),
                .target = v.linkTarget(j),
                .rule = v.delRule(j),
                .value_index = v.valueIndexRef(j),
                .indexed = v.indexed(j),
            };
        }
        return s;
    }

    /// Allocate and encode a fresh catalog node from this snapshot.
    pub fn write(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        var cols: [maxPropertyCount]Reference = undefined;
        var kinds: [maxPropertyCount]PropertyKind = undefined;
        var elems: [maxPropertyCount]ElemKind = undefined;
        var backlinks: [maxPropertyCount]Reference = undefined;
        var targets: [maxPropertyCount]u16 = undefined;
        var rules: [maxPropertyCount]DeletionRule = undefined;
        var valueIndexRefs: [maxPropertyCount]Reference = undefined;
        var idxf: [maxPropertyCount]bool = undefined;
        const propertyCount = self.propertyCount;
        var j: usize = 0;
        while (j < propertyCount) : (j += 1) {
            const p = self.properties[j];
            cols[j] = p.col;
            kinds[j] = p.kind;
            elems[j] = p.elem;
            backlinks[j] = p.backlink;
            targets[j] = p.target;
            rules[j] = p.rule;
            valueIndexRefs[j] = p.value_index;
            idxf[j] = p.indexed;
        }
        return writeCatalog(
            transaction,
            propertyCount,
            self.next_row,
            self.keyrow_index_ref,
            self.next_key,
            self.primaryKeyIndexRef,
            self.version_col_ref,
            self.live_col_ref,
            cols[0..propertyCount],
            kinds[0..propertyCount],
            elems[0..propertyCount],
            backlinks[0..propertyCount],
            targets[0..propertyCount],
            rules[0..propertyCount],
            valueIndexRefs[0..propertyCount],
            idxf[0..propertyCount],
        );
    }

    /// Write the snapshot as a fresh node and free the node it was loaded
    /// from. This is the normal way to rewrite a catalog within one database:
    /// the old node is garbage the moment the caller adopts the new ref, and a
    /// transaction-private old node is reused by the very next same-size catalog write,
    /// so catalog churn stops growing the file. Do NOT use when the source
    /// lives in a different database (copyTypeRows) or must stay readable.
    pub fn replace(self: *const CatalogSnapshot, transaction: *WriteTransaction) !Reference {
        const new_ref = try self.write(transaction);
        try transaction.free(self.source, self.source_len);
        return new_ref;
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
    const v = try loadCatalog(transaction, catalogRef);
    return Index.get(transaction, v.keyrow_index_ref, objectKey);
}

// Resolve a primary key to its stable object key via the primaryKey index.
// Returns null if the primaryKey has no mapping.
pub fn primaryKeyToObjectKey(transaction: anytype, catalogRef: Reference, primaryKey: u64) !?u64 {
    const v = try loadCatalog(transaction, catalogRef);
    return Index.get(transaction, v.primaryKeyIndexRef, primaryKey);
}

// Resolve (catalogRef, primaryKey, property) to the property column ref and the row;
// null if primaryKey absent or row tombstoned. The primaryKey index maps primaryKey -> objectKey, and the
// keyrow index maps objectKey -> physical row.
pub fn resolveProperty(transaction: anytype, catalogRef: Reference, primaryKey: u64, property: usize) !?struct { row: u64, propertyColumn: Reference } {
    const v = try loadCatalog(transaction, catalogRef);
    const objectKey = (try Index.get(transaction, v.primaryKeyIndexRef, primaryKey)) orelse return null;
    const row = (try Index.get(transaction, v.keyrow_index_ref, objectKey)) orelse return null;
    if ((try Column.get(transaction, v.live_col_ref, row)) == 0) return null;
    return .{ .row = row, .propertyColumn = v.propertyColumnRef(property) };
}

// Write new_root into property `property` at `row`, bump that row's version stamp,
// return the new catalog ref.
pub fn replaceCollRoot(transaction: *WriteTransaction, catalogRef: Reference, row: u64, property: usize, new_root: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, catalogRef);
    s.properties[property].col = try Column.set(transaction, s.properties[property].col, row, new_root);
    s.version_col_ref = try Column.set(transaction, s.version_col_ref, row, transaction.new_version);
    return s.replace(transaction);
}

// Write a new backlink ref into property `p`, preserving everything else.
pub fn setBacklinkRef(transaction: *WriteTransaction, catalogRef: Reference, p: usize, new_bl: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, catalogRef);
    s.properties[p].backlink = new_bl;
    return s.replace(transaction);
}

// Write a new value-index ref into property `p`, preserving everything else.
pub fn setValueIndexRef(transaction: *WriteTransaction, catalogRef: Reference, p: usize, new_vi: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, catalogRef);
    s.properties[p].value_index = new_vi;
    return s.replace(transaction);
}

// Write a new column ref into property `p`, preserving everything else.
pub fn setPropertyColumnRef(transaction: *WriteTransaction, catalogRef: Reference, p: usize, new_col: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, catalogRef);
    s.properties[p].col = new_col;
    return s.replace(transaction);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Database = @import("../database.zig").Database;

fn objTmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..dlen], name });
}

test "create allocates an empty type and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "obj1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try create(&w, 3);
    try testing.expectEqual(@as(PropertyCount, 3), try loadPropertyCount(&w, catalogRef));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, catalogRef));
    w.deinit();
}

test "CatalogSnapshot round-trips every field through load and write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "snap_rt.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .link, .link_target = 3, .del_rule = .cascade },
        .{ .kind = .list, .elem = .blob },
    });
    const s = try CatalogSnapshot.load(&w, catalogRef);
    const copy_ref = try s.write(&w);
    const v0 = try loadCatalog(&w, catalogRef);
    const v1 = try loadCatalog(&w, copy_ref);
    try testing.expectEqual(v0.propertyCount, v1.propertyCount);
    try testing.expectEqual(v0.next_row, v1.next_row);
    try testing.expectEqual(v0.next_key, v1.next_key);
    try testing.expectEqual(v0.primaryKeyIndexRef, v1.primaryKeyIndexRef);
    try testing.expectEqual(v0.keyrow_index_ref, v1.keyrow_index_ref);
    try testing.expectEqual(v0.version_col_ref, v1.version_col_ref);
    try testing.expectEqual(v0.live_col_ref, v1.live_col_ref);
    var j: usize = 0;
    while (j < v0.propertyCount) : (j += 1) {
        try testing.expectEqual(v0.propertyColumnRef(j), v1.propertyColumnRef(j));
        try testing.expectEqual(v0.kind(j), v1.kind(j));
        try testing.expectEqual(v0.elemKind(j), v1.elemKind(j));
        try testing.expectEqual(v0.backlinkRef(j), v1.backlinkRef(j));
        try testing.expectEqual(v0.linkTarget(j), v1.linkTarget(j));
        try testing.expectEqual(v0.delRule(j), v1.delRule(j));
        try testing.expectEqual(v0.valueIndexRef(j), v1.valueIndexRef(j));
        try testing.expectEqual(v0.indexed(j), v1.indexed(j));
    }
}

test "loadCatalog rejects corrupt disk values instead of panicking" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "corruptcat.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    defer w.deinit();
    const catalogRef = try create(&w, 2);
    _ = try loadCatalog(&w, catalogRef); // clean before corruption

    // Corrupt a kind byte (out-of-range enum value) directly in the mapping.
    const catalogOffset: usize = @intCast(catalogRef);
    const kind_byte_off = catalogOffset + propertyColumnsOffset + 2 * 8; // kindsOffset(2), property 0
    const saved_kind = database.store.map[kind_byte_off];
    database.store.map[kind_byte_off] = 200;
    try testing.expectError(error.Corrupt, loadCatalog(&w, catalogRef));
    database.store.map[kind_byte_off] = saved_kind;
    _ = try loadCatalog(&w, catalogRef); // restored

    // Corrupt the property count to an implausible value.
    std.mem.writeInt(u16, database.store.map[catalogOffset..][0..2], 6000, .little);
    try testing.expectError(error.Corrupt, loadCatalog(&w, catalogRef));
}

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createTyped(&w, &.{ .int, .blob, .int });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expectEqual(PropertyKind.int, v.kind(0));
    try testing.expectEqual(PropertyKind.blob, v.kind(1));
    try testing.expectEqual(PropertyKind.int, v.kind(2));
    const catalog2 = try create(&w, 2);
    const v2 = try loadCatalog(&w, catalog2);
    try testing.expectEqual(PropertyKind.int, v2.kind(0));
    try testing.expectEqual(PropertyKind.int, v2.kind(1));
    w.deinit();
}

test "createDefs records kind and element kind per property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "defs.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
        .{ .kind = .list, .elem = .blob },
    });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expectEqual(@as(PropertyCount, 4), v.propertyCount);
    try testing.expectEqual(PropertyKind.int, v.kind(0));
    try testing.expectEqual(PropertyKind.list, v.kind(1));
    try testing.expectEqual(ElemKind.int, v.elemKind(1));
    try testing.expectEqual(PropertyKind.set, v.kind(2));
    try testing.expectEqual(ElemKind.int, v.elemKind(2));
    try testing.expectEqual(PropertyKind.list, v.kind(3));
    try testing.expectEqual(ElemKind.blob, v.elemKind(3));
    const catalog2 = try createTyped(&w, &.{ .int, .blob });
    const v2 = try loadCatalog(&w, catalog2);
    try testing.expectEqual(PropertyKind.blob, v2.kind(1));
    try testing.expectEqual(ElemKind.int, v2.elemKind(1));
    w.deinit();
}

test "createDefs builds a backlink index for each link property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcat.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .link },
    });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expectEqual(PropertyKind.link, v.kind(2));
    try testing.expect(v.backlinkRef(2) != 0);
    try testing.expectEqual(@as(Reference, 0), v.backlinkRef(0));
    try testing.expectEqual(@as(Reference, 0), v.backlinkRef(1));
    w.deinit();
}

test "createDefs records a link target type id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "ltarget.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 3 },
        .{ .kind = .link_set, .link_target = 7 },
    });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expectEqual(@as(u16, 0), v.linkTarget(0));
    try testing.expectEqual(@as(u16, 3), v.linkTarget(1));
    try testing.expectEqual(@as(u16, 7), v.linkTarget(2));
    w.deinit();
}

test "createDefs creates an empty key-to-row index and zero next_key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "keyrow.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expect(v.keyrow_index_ref != 0);
    try testing.expectEqual(@as(u64, 0), v.next_key);
    w.deinit();
}

test "catalog persists indexed flag and value index ref" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expect(v.indexed(1));
    try testing.expect(!v.indexed(0));
    try testing.expect(!v.indexed(2));
    try testing.expect(v.valueIndexRef(1) != 0);
    try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(0));
    try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(2));
    const vidx1 = v.valueIndexRef(1);
    // Round-trip through a full catalog rebuild (setPropertyColumnRef rewrites every
    // field) and assert both the flag and the value-index ref survive.
    const catalog2 = try setPropertyColumnRef(&w, catalogRef, 2, v.propertyColumnRef(2));
    const v2 = try loadCatalog(&w, catalog2);
    try testing.expect(v2.indexed(1));
    try testing.expect(!v2.indexed(0));
    try testing.expect(!v2.indexed(2));
    try testing.expectEqual(vidx1, v2.valueIndexRef(1));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexRef(0));
    try testing.expectEqual(@as(Reference, 0), v2.valueIndexRef(2));
    w.deinit();
}

test "non-indexed catalog: value index refs zero and existing fields intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "noindex.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .blob },
        .{ .kind = .link, .link_target = 4, .del_rule = .cascade },
    });
    const v = try loadCatalog(&w, catalogRef);
    var i: usize = 0;
    while (i < v.propertyCount) : (i += 1) {
        try testing.expect(!v.indexed(i));
        try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(i));
    }
    // Every pre-existing accessor must still read the right field: this guards
    // that appending the new arrays did not disturb the earlier offset math.
    try testing.expectEqual(PropertyKind.int, v.kind(0));
    try testing.expectEqual(PropertyKind.list, v.kind(1));
    try testing.expectEqual(ElemKind.blob, v.elemKind(1));
    try testing.expectEqual(PropertyKind.link, v.kind(2));
    try testing.expect(v.propertyColumnRef(0) != 0);
    try testing.expect(v.propertyColumnRef(1) != 0);
    try testing.expect(v.backlinkRef(2) != 0); // link property got a backlink index
    try testing.expectEqual(@as(Reference, 0), v.backlinkRef(0));
    try testing.expectEqual(@as(Reference, 0), v.backlinkRef(1));
    try testing.expectEqual(@as(u16, 4), v.linkTarget(2));
    try testing.expectEqual(@as(u16, 0), v.linkTarget(0));
    try testing.expectEqual(DeletionRule.cascade, v.delRule(2));
    try testing.expectEqual(DeletionRule.nullify, v.delRule(0));
    w.deinit();
}

test "createDefs records a per-property deletion rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "delrule.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var w = try database.beginWrite();
    const catalogRef = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 2, .del_rule = .cascade },
        .{ .kind = .link, .link_target = 3, .del_rule = .block },
    });
    const v = try loadCatalog(&w, catalogRef);
    try testing.expectEqual(DeletionRule.nullify, v.delRule(0));
    try testing.expectEqual(DeletionRule.cascade, v.delRule(1));
    try testing.expectEqual(DeletionRule.block, v.delRule(2));
    // existing per-property data still intact
    try testing.expectEqual(@as(u16, 2), v.linkTarget(1));
    w.deinit();
}
