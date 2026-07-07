const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");

pub const PropCount = u16;
pub const PropKind = enum(u8) { int = 0, blob = 1, list = 2, set = 3, link = 4, link_set = 5, dict = 6 };
pub const ElemKind = enum(u8) { int = 0, blob = 1 };
pub const DeletionRule = enum(u8) { nullify = 0, cascade = 1, block = 2 };
pub const PropDef = struct { kind: PropKind, elem: ElemKind = .int, link_target: u16 = 0, del_rule: DeletionRule = .nullify, indexed: bool = false };
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
    link_set: []const u64, // to-many: initial set of target okeys
};

// Catalog node layout:
// [prop_count u16][next_row u64][pk_index_ref u64][version_col_ref u64][live_col_ref u64]
// [prop_count * (prop_col_ref u64)][prop_count * (kind u8)][prop_count * (elem u8)]
// [prop_count * (backlink_ref u64)][prop_count * (link_target u16)][prop_count * (del_rule u8)]
// [prop_count * (value_index_ref u64)][prop_count * (indexed u8)]
//
// The value-index ref and indexed flag arrays are appended last so the earlier
// per-property arrays keep their existing offsets unchanged.
const off_prop_count: usize = 0;
const off_next_row: usize = 2;
const off_pk_index_ref: usize = 10;
const off_version_col_ref: usize = 18;
const off_live_col_ref: usize = 26;
const off_keyrow_index_ref: usize = 34;
const off_next_key: usize = 42;
const off_prop_cols: usize = 50;

pub const max_prop_count: usize = 256;

fn catalogSize(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8 + @as(usize, pc) * 2 + @as(usize, pc) * 8 + @as(usize, pc) * 2 + @as(usize, pc) + @as(usize, pc) * 8 + @as(usize, pc);
}

fn kindsOffset(pc: PropCount) usize {
    return off_prop_cols + @as(usize, pc) * 8;
}

fn elemsOffset(pc: PropCount) usize {
    return kindsOffset(pc) + pc;
}

fn backlinksOffset(pc: PropCount) usize {
    return elemsOffset(pc) + pc;
}

fn targetsOffset(pc: PropCount) usize {
    return backlinksOffset(pc) + @as(usize, pc) * 8;
}

fn rulesOffset(pc: PropCount) usize {
    return targetsOffset(pc) + @as(usize, pc) * 2;
}

fn valueIndexRefsOffset(pc: PropCount) usize {
    return rulesOffset(pc) + @as(usize, pc);
}

fn indexedFlagsOffset(pc: PropCount) usize {
    return valueIndexRefsOffset(pc) + @as(usize, pc) * 8;
}

// Allocate and encode a fresh catalog node; return its ref.
pub fn writeCatalog(
    transaction: *WriteTransaction,
    prop_count: PropCount,
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    pk_index_ref: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    prop_col_refs: []const Reference,
    kinds: []const PropKind,
    elems: []const ElemKind,
    backlinks: []const Reference,
    targets: []const u16,
    rules: []const DeletionRule,
    value_index_refs: []const Reference,
    indexed_flags: []const bool,
) !Reference {
    const a = try transaction.alloc(catalogSize(prop_count));
    std.mem.writeInt(u16, a.bytes[off_prop_count..][0..2], prop_count, .little);
    std.mem.writeInt(u64, a.bytes[off_next_row..][0..8], next_row, .little);
    std.mem.writeInt(u64, a.bytes[off_keyrow_index_ref..][0..8], keyrow_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_next_key..][0..8], next_key, .little);
    std.mem.writeInt(u64, a.bytes[off_pk_index_ref..][0..8], pk_index_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_version_col_ref..][0..8], version_col_ref, .little);
    std.mem.writeInt(u64, a.bytes[off_live_col_ref..][0..8], live_col_ref, .little);
    for (prop_col_refs, 0..) |ref, i| {
        std.mem.writeInt(u64, a.bytes[off_prop_cols + i * 8 ..][0..8], ref, .little);
    }
    const ko = kindsOffset(prop_count);
    for (kinds, 0..) |k, i| a.bytes[ko + i] = @intFromEnum(k);
    const eo = elemsOffset(prop_count);
    for (elems, 0..) |e, i| a.bytes[eo + i] = @intFromEnum(e);
    const blo = backlinksOffset(prop_count);
    for (backlinks, 0..) |bref, i| {
        std.mem.writeInt(u64, a.bytes[blo + i * 8 ..][0..8], bref, .little);
    }
    const to = targetsOffset(prop_count);
    for (targets, 0..) |t, i| std.mem.writeInt(u16, a.bytes[to + i * 2 ..][0..2], t, .little);
    const ro = rulesOffset(prop_count);
    for (rules, 0..) |r, i| a.bytes[ro + i] = @intFromEnum(r);
    const vio = valueIndexRefsOffset(prop_count);
    for (value_index_refs, 0..) |vref, i| {
        std.mem.writeInt(u64, a.bytes[vio + i * 8 ..][0..8], vref, .little);
    }
    const ifo = indexedFlagsOffset(prop_count);
    for (indexed_flags, 0..) |flag, i| a.bytes[ifo + i] = @intFromBool(flag);
    return a.ref;
}

// createDefs allocates columns, a pk index, version/live columns, and a catalog
// node from explicit per-property definitions. defs[0].kind must be .int (the pk).
pub fn createDefs(transaction: *WriteTransaction, defs: []const PropDef) !Reference {
    std.debug.assert(defs.len >= 1 and defs[0].kind == .int);
    const prop_count: PropCount = @intCast(defs.len);
    std.debug.assert(prop_count <= max_prop_count);
    var prop_col_refs: [max_prop_count]Reference = undefined;
    var kinds: [max_prop_count]PropKind = undefined;
    var elems: [max_prop_count]ElemKind = undefined;
    var backlinks: [max_prop_count]Reference = undefined;
    var targets: [max_prop_count]u16 = undefined;
    var rules: [max_prop_count]DeletionRule = undefined;
    var value_index_refs: [max_prop_count]Reference = undefined;
    var indexed_flags: [max_prop_count]bool = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) {
        prop_col_refs[i] = try Column.create(transaction);
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
    const pk_index_ref = try Index.create(transaction);
    const keyrow = try Index.create(transaction);
    return writeCatalog(
        transaction,
        prop_count,
        0,
        keyrow,
        0,
        pk_index_ref,
        version_col_ref,
        live_col_ref,
        prop_col_refs[0..prop_count],
        kinds[0..prop_count],
        elems[0..prop_count],
        backlinks[0..prop_count],
        targets[0..prop_count],
        rules[0..prop_count],
        value_index_refs[0..prop_count],
        indexed_flags[0..prop_count],
    );
}

// createTyped keeps its scalar-only signature; every property gets elem = int.
pub fn createTyped(transaction: *WriteTransaction, kinds: []const PropKind) !Reference {
    std.debug.assert(kinds.len >= 1 and kinds[0] == .int);
    const pc: PropCount = @intCast(kinds.len);
    std.debug.assert(pc <= max_prop_count);
    var defs: [max_prop_count]PropDef = undefined;
    var i: usize = 0;
    while (i < pc) : (i += 1) defs[i] = .{ .kind = kinds[i], .elem = .int };
    return createDefs(transaction, defs[0..pc]);
}

// Create prop_count property columns, a version column, a live column, and an
// empty pk index. All property kinds default to .int.
pub fn create(transaction: *WriteTransaction, prop_count: PropCount) !Reference {
    std.debug.assert(prop_count <= max_prop_count);
    var all_int: [max_prop_count]PropKind = undefined;
    var i: usize = 0;
    while (i < prop_count) : (i += 1) all_int[i] = .int;
    return createTyped(transaction, all_int[0..prop_count]);
}

pub const CatalogView = struct {
    prop_count: PropCount,
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    pk_index_ref: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    bytes: []const u8,

    pub fn propColRef(self: CatalogView, i: usize) Reference {
        return std.mem.readInt(u64, self.bytes[off_prop_cols + i * 8 ..][0..8], .little);
    }

    pub fn kind(self: CatalogView, i: usize) PropKind {
        const kinds_offset = off_prop_cols + @as(usize, self.prop_count) * 8;
        return @enumFromInt(self.bytes[kinds_offset + i]);
    }

    pub fn elemKind(self: CatalogView, i: usize) ElemKind {
        const eo = off_prop_cols + @as(usize, self.prop_count) * 8 + self.prop_count;
        return @enumFromInt(self.bytes[eo + i]);
    }

    pub fn backlinkRef(self: CatalogView, i: usize) Reference {
        const blo = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2;
        return std.mem.readInt(u64, self.bytes[blo + i * 8 ..][0..8], .little);
    }

    pub fn linkTarget(self: CatalogView, i: usize) u16 {
        const to = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2 + @as(usize, self.prop_count) * 8;
        return std.mem.readInt(u16, self.bytes[to + i * 2 ..][0..2], .little);
    }

    pub fn delRule(self: CatalogView, i: usize) DeletionRule {
        const ro = off_prop_cols + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2 + @as(usize, self.prop_count) * 8 + @as(usize, self.prop_count) * 2;
        return @enumFromInt(self.bytes[ro + i]);
    }

    pub fn valueIndexRef(self: CatalogView, i: usize) Reference {
        const vio = valueIndexRefsOffset(self.prop_count);
        return std.mem.readInt(u64, self.bytes[vio + i * 8 ..][0..8], .little);
    }

    pub fn indexed(self: CatalogView, i: usize) bool {
        const ifo = indexedFlagsOffset(self.prop_count);
        return self.bytes[ifo + i] != 0;
    }
};

// Deref the catalog at cat, read prop_count, then deref the full node and parse
// all fixed fields. Returns a CatalogView whose bytes slice is valid for the
// lifetime of the transaction.
//
// All per-property enum bytes (kind, elem kind, deletion rule) are validated
// here, ONCE, so the CatalogView accessors can stay infallible. These bytes
// come straight from the mapped file: a corrupted value must surface as
// error.Corrupt, never as a panic (ReleaseSafe) or undefined behavior
// (ReleaseFast) from an unchecked @enumFromInt.
pub fn loadCatalog(transaction: anytype, cat: Reference) !CatalogView {
    const pc_bytes = try transaction.deref(cat, 2);
    const prop_count = std.mem.readInt(u16, pc_bytes[0..2], .little);
    if (prop_count > max_prop_count) return error.Corrupt;
    const bytes = try transaction.deref(cat, catalogSize(prop_count));
    {
        const ko = kindsOffset(prop_count);
        const eo = elemsOffset(prop_count);
        const ro = rulesOffset(prop_count);
        var p: usize = 0;
        while (p < prop_count) : (p += 1) {
            if (std.enums.fromInt(PropKind, bytes[ko + p]) == null) return error.Corrupt;
            if (std.enums.fromInt(ElemKind, bytes[eo + p]) == null) return error.Corrupt;
            if (std.enums.fromInt(DeletionRule, bytes[ro + p]) == null) return error.Corrupt;
        }
    }
    return CatalogView{
        .prop_count = prop_count,
        .next_row = std.mem.readInt(u64, bytes[off_next_row..][0..8], .little),
        .keyrow_index_ref = std.mem.readInt(u64, bytes[off_keyrow_index_ref..][0..8], .little),
        .next_key = std.mem.readInt(u64, bytes[off_next_key..][0..8], .little),
        .pk_index_ref = std.mem.readInt(u64, bytes[off_pk_index_ref..][0..8], .little),
        .version_col_ref = std.mem.readInt(u64, bytes[off_version_col_ref..][0..8], .little),
        .live_col_ref = std.mem.readInt(u64, bytes[off_live_col_ref..][0..8], .little),
        .bytes = bytes,
    };
}

/// One property's full catalog record, as carried by CatalogSnapshot.
pub const PropSnap = struct {
    col: Reference,
    kind: PropKind,
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
    prop_count: PropCount,
    next_row: u64,
    keyrow_index_ref: Reference,
    next_key: u64,
    pk_index_ref: Reference,
    version_col_ref: Reference,
    live_col_ref: Reference,
    props: [max_prop_count]PropSnap,
    /// The node this snapshot was loaded from and its on-disk size, so
    /// replace() can free it. prop_count may change after load (migrations),
    /// so the size is captured here, not recomputed.
    source: Reference,
    source_len: usize,

    pub fn load(transaction: anytype, cat: Reference) !CatalogSnapshot {
        const v = try loadCatalog(transaction, cat);
        var s: CatalogSnapshot = undefined;
        s.source = cat;
        s.source_len = catalogSize(v.prop_count);
        s.prop_count = v.prop_count;
        s.next_row = v.next_row;
        s.keyrow_index_ref = v.keyrow_index_ref;
        s.next_key = v.next_key;
        s.pk_index_ref = v.pk_index_ref;
        s.version_col_ref = v.version_col_ref;
        s.live_col_ref = v.live_col_ref;
        var j: usize = 0;
        while (j < v.prop_count) : (j += 1) {
            s.props[j] = .{
                .col = v.propColRef(j),
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
        var cols: [max_prop_count]Reference = undefined;
        var kinds: [max_prop_count]PropKind = undefined;
        var elems: [max_prop_count]ElemKind = undefined;
        var backlinks: [max_prop_count]Reference = undefined;
        var targets: [max_prop_count]u16 = undefined;
        var rules: [max_prop_count]DeletionRule = undefined;
        var vidx: [max_prop_count]Reference = undefined;
        var idxf: [max_prop_count]bool = undefined;
        const pc = self.prop_count;
        var j: usize = 0;
        while (j < pc) : (j += 1) {
            const p = self.props[j];
            cols[j] = p.col;
            kinds[j] = p.kind;
            elems[j] = p.elem;
            backlinks[j] = p.backlink;
            targets[j] = p.target;
            rules[j] = p.rule;
            vidx[j] = p.value_index;
            idxf[j] = p.indexed;
        }
        return writeCatalog(
            transaction,
            pc,
            self.next_row,
            self.keyrow_index_ref,
            self.next_key,
            self.pk_index_ref,
            self.version_col_ref,
            self.live_col_ref,
            cols[0..pc],
            kinds[0..pc],
            elems[0..pc],
            backlinks[0..pc],
            targets[0..pc],
            rules[0..pc],
            vidx[0..pc],
            idxf[0..pc],
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

pub fn propCount(transaction: anytype, cat: Reference) !PropCount {
    const view = try loadCatalog(transaction, cat);
    return view.prop_count;
}

// liveCount returns the number of live rows tracked by the pk index.
pub fn liveCount(transaction: anytype, cat: Reference) !u64 {
    const view = try loadCatalog(transaction, cat);
    return Index.count(transaction, view.pk_index_ref);
}

// Resolve an object key to its physical row via the key-to-row index.
// Returns null if the okey has no mapping.
pub fn okeyToRow(transaction: anytype, cat: Reference, okey: u64) !?u64 {
    const v = try loadCatalog(transaction, cat);
    return Index.get(transaction, v.keyrow_index_ref, okey);
}

// Resolve a primary key to its stable object key via the pk index.
// Returns null if the pk has no mapping.
pub fn pkToOkey(transaction: anytype, cat: Reference, pk: u64) !?u64 {
    const v = try loadCatalog(transaction, cat);
    return Index.get(transaction, v.pk_index_ref, pk);
}

// Resolve (cat, pk, prop) to the property column ref and the row;
// null if pk absent or row tombstoned. The pk index maps pk -> okey, and the
// keyrow index maps okey -> physical row.
pub fn resolveProp(transaction: anytype, cat: Reference, pk: u64, prop: usize) !?struct { row: u64, prop_col: Reference } {
    const v = try loadCatalog(transaction, cat);
    const okey = (try Index.get(transaction, v.pk_index_ref, pk)) orelse return null;
    const row = (try Index.get(transaction, v.keyrow_index_ref, okey)) orelse return null;
    if ((try Column.get(transaction, v.live_col_ref, row)) == 0) return null;
    return .{ .row = row, .prop_col = v.propColRef(prop) };
}

// Write new_root into property `prop` at `row`, bump that row's version stamp,
// return the new catalog ref.
pub fn replaceCollRoot(transaction: *WriteTransaction, cat: Reference, row: u64, prop: usize, new_root: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, cat);
    s.props[prop].col = try Column.set(transaction, s.props[prop].col, row, new_root);
    s.version_col_ref = try Column.set(transaction, s.version_col_ref, row, transaction.new_version);
    return s.replace(transaction);
}

// Write a new backlink ref into property `p`, preserving everything else.
pub fn setBacklinkRef(transaction: *WriteTransaction, cat: Reference, p: usize, new_bl: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, cat);
    s.props[p].backlink = new_bl;
    return s.replace(transaction);
}

// Write a new value-index ref into property `p`, preserving everything else.
pub fn setValueIndexRef(transaction: *WriteTransaction, cat: Reference, p: usize, new_vi: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, cat);
    s.props[p].value_index = new_vi;
    return s.replace(transaction);
}

// Write a new column ref into property `p`, preserving everything else.
pub fn setPropColRef(transaction: *WriteTransaction, cat: Reference, p: usize, new_col: Reference) !Reference {
    var s = try CatalogSnapshot.load(transaction, cat);
    s.props[p].col = new_col;
    return s.replace(transaction);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Db = @import("../database.zig").Db;

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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try create(&w, 3);
    try testing.expectEqual(@as(PropCount, 3), try propCount(&w, cat));
    try testing.expectEqual(@as(u64, 0), try liveCount(&w, cat));
    w.deinit();
}

test "CatalogSnapshot round-trips every field through load and write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "snap_rt.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .link, .link_target = 3, .del_rule = .cascade },
        .{ .kind = .list, .elem = .blob },
    });
    const s = try CatalogSnapshot.load(&w, cat);
    const copy_ref = try s.write(&w);
    const v0 = try loadCatalog(&w, cat);
    const v1 = try loadCatalog(&w, copy_ref);
    try testing.expectEqual(v0.prop_count, v1.prop_count);
    try testing.expectEqual(v0.next_row, v1.next_row);
    try testing.expectEqual(v0.next_key, v1.next_key);
    try testing.expectEqual(v0.pk_index_ref, v1.pk_index_ref);
    try testing.expectEqual(v0.keyrow_index_ref, v1.keyrow_index_ref);
    try testing.expectEqual(v0.version_col_ref, v1.version_col_ref);
    try testing.expectEqual(v0.live_col_ref, v1.live_col_ref);
    var j: usize = 0;
    while (j < v0.prop_count) : (j += 1) {
        try testing.expectEqual(v0.propColRef(j), v1.propColRef(j));
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    defer w.deinit();
    const cat = try create(&w, 2);
    _ = try loadCatalog(&w, cat); // clean before corruption

    // Corrupt a kind byte (out-of-range enum value) directly in the mapping.
    const cat_off: usize = @intCast(cat);
    const kind_byte_off = cat_off + off_prop_cols + 2 * 8; // kindsOffset(2), prop 0
    const saved_kind = db.store.map[kind_byte_off];
    db.store.map[kind_byte_off] = 200;
    try testing.expectError(error.Corrupt, loadCatalog(&w, cat));
    db.store.map[kind_byte_off] = saved_kind;
    _ = try loadCatalog(&w, cat); // restored

    // Corrupt the prop count to an implausible value.
    std.mem.writeInt(u16, db.store.map[cat_off..][0..2], 6000, .little);
    try testing.expectError(error.Corrupt, loadCatalog(&w, cat));
}

test "createTyped records property kinds; create defaults to all int" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "kinds.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createTyped(&w, &.{ .int, .blob, .int });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.blob, v.kind(1));
    try testing.expectEqual(PropKind.int, v.kind(2));
    const cat2 = try create(&w, 2);
    const v2 = try loadCatalog(&w, cat2);
    try testing.expectEqual(PropKind.int, v2.kind(0));
    try testing.expectEqual(PropKind.int, v2.kind(1));
    w.deinit();
}

test "createDefs records kind and element kind per property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "defs.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .int },
        .{ .kind = .set, .elem = .int },
        .{ .kind = .list, .elem = .blob },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(@as(PropCount, 4), v.prop_count);
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.list, v.kind(1));
    try testing.expectEqual(ElemKind.int, v.elemKind(1));
    try testing.expectEqual(PropKind.set, v.kind(2));
    try testing.expectEqual(ElemKind.int, v.elemKind(2));
    try testing.expectEqual(PropKind.list, v.kind(3));
    try testing.expectEqual(ElemKind.blob, v.elemKind(3));
    const cat2 = try createTyped(&w, &.{ .int, .blob });
    const v2 = try loadCatalog(&w, cat2);
    try testing.expectEqual(PropKind.blob, v2.kind(1));
    try testing.expectEqual(ElemKind.int, v2.elemKind(1));
    w.deinit();
}

test "createDefs builds a backlink index for each link property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "linkcat.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int },
        .{ .kind = .link },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(PropKind.link, v.kind(2));
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 3 },
        .{ .kind = .link_set, .link_target = 7 },
    });
    const v = try loadCatalog(&w, cat);
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{ .{ .kind = .int }, .{ .kind = .int } });
    const v = try loadCatalog(&w, cat);
    try testing.expect(v.keyrow_index_ref != 0);
    try testing.expectEqual(@as(u64, 0), v.next_key);
    w.deinit();
}

test "catalog persists indexed flag and value index ref" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try objTmpPath(testing.allocator, &tmp, "vindex.airdb");
    defer testing.allocator.free(path);
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .int, .indexed = true },
        .{ .kind = .int },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expect(v.indexed(1));
    try testing.expect(!v.indexed(0));
    try testing.expect(!v.indexed(2));
    try testing.expect(v.valueIndexRef(1) != 0);
    try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(0));
    try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(2));
    const vidx1 = v.valueIndexRef(1);
    // Round-trip through a full catalog rebuild (setPropColRef rewrites every
    // field) and assert both the flag and the value-index ref survive.
    const cat2 = try setPropColRef(&w, cat, 2, v.propColRef(2));
    const v2 = try loadCatalog(&w, cat2);
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .list, .elem = .blob },
        .{ .kind = .link, .link_target = 4, .del_rule = .cascade },
    });
    const v = try loadCatalog(&w, cat);
    var i: usize = 0;
    while (i < v.prop_count) : (i += 1) {
        try testing.expect(!v.indexed(i));
        try testing.expectEqual(@as(Reference, 0), v.valueIndexRef(i));
    }
    // Every pre-existing accessor must still read the right field: this guards
    // that appending the new arrays did not disturb the earlier offset math.
    try testing.expectEqual(PropKind.int, v.kind(0));
    try testing.expectEqual(PropKind.list, v.kind(1));
    try testing.expectEqual(ElemKind.blob, v.elemKind(1));
    try testing.expectEqual(PropKind.link, v.kind(2));
    try testing.expect(v.propColRef(0) != 0);
    try testing.expect(v.propColRef(1) != 0);
    try testing.expect(v.backlinkRef(2) != 0); // link prop got a backlink index
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
    var db = try Db.create(testing.allocator, path);
    defer db.deinit();
    var w = try db.beginWrite();
    const cat = try createDefs(&w, &.{
        .{ .kind = .int },
        .{ .kind = .link, .link_target = 2, .del_rule = .cascade },
        .{ .kind = .link, .link_target = 3, .del_rule = .block },
    });
    const v = try loadCatalog(&w, cat);
    try testing.expectEqual(DeletionRule.nullify, v.delRule(0));
    try testing.expectEqual(DeletionRule.cascade, v.delRule(1));
    try testing.expectEqual(DeletionRule.block, v.delRule(2));
    // existing per-prop data still intact
    try testing.expectEqual(@as(u16, 2), v.linkTarget(1));
    w.deinit();
}
