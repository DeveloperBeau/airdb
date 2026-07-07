const std = @import("std");
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const bindex = @import("../trees/byteKeyIndex.zig");
const blob = @import("blob.zig");
const catalog = @import("../schema/catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

pub fn buildListInt(transaction: *WriteTransaction, items: []const u64) !Reference {
    var root = try Column.create(transaction);
    for (items) |x| root = try Column.append(transaction, root, x);
    return root;
}

pub fn buildListBlob(transaction: *WriteTransaction, items: []const []const u8) !Reference {
    var root = try Column.create(transaction);
    for (items) |s| {
        const bref = try blob.put(transaction, s);
        root = try Column.append(transaction, root, bref);
    }
    return root;
}

pub fn buildSetInt(transaction: *WriteTransaction, items: []const u64) !Reference {
    var root = try Index.create(transaction);
    for (items) |k| root = try Index.insert(transaction, root, k, 1);
    return root;
}

pub fn listLen(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return null;
    const list_root = try Column.get(transaction, r.prop_col, r.row);
    return try Column.len(transaction, list_root);
}

pub fn listGetInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize, index: u64) !u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const list_root = try Column.get(transaction, r.prop_col, r.row);
    return try Column.get(transaction, list_root, index);
}

pub fn listGetBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize, index: u64) ![]const u8 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const list_root = try Column.get(transaction, r.prop_col, r.row);
    const bref = try Column.get(transaction, list_root, index);
    return try blob.get(transaction, bref);
}

pub fn listAppendInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, value: u64) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    const new_root = try Column.append(transaction, old_root, value);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn listSetInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, index: u64, value: u64) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    const new_root = try Column.set(transaction, old_root, index, value);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn listAppendBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, bytes: []const u8) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    const bref = try blob.put(transaction, bytes);
    const new_root = try Column.append(transaction, old_root, bref);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn setCountInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return null;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    return try Index.count(transaction, set_root);
}

pub fn setContainsInt(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize, key: u64) !bool {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    return (try Index.get(transaction, set_root, key)) != null;
}

pub fn setAddInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, key: u64) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    if ((try Index.get(transaction, old_root, key)) != null) return catalogRef; // already a member, no version bump
    const new_root = try Index.insert(transaction, old_root, key, 1);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn setRemoveInt(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, key: u64) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    if ((try Index.get(transaction, old_root, key)) == null) return catalogRef; // not a member, no version bump
    const new_root = try Index.remove(transaction, old_root, key);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn setCollectInt(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(transaction, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// ---------------------------------------------------------------------------
// set of blob: byte-string members backed by the byte-keyed B+tree (bindex).
// Members are the bindex keys; the value column is an unused sentinel (1).
// ---------------------------------------------------------------------------

pub fn buildSetBlob(transaction: *WriteTransaction, items: []const []const u8) !Reference {
    var root = try bindex.create(transaction);
    // bindex.insert overwrites an existing key, so duplicate members dedup.
    for (items) |member| root = try bindex.insert(transaction, root, member, 1);
    return root;
}

pub fn setCountBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return null;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    return try bindex.count(transaction, set_root);
}

pub fn setContainsBlob(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize, member: []const u8) !bool {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    return (try bindex.get(transaction, set_root, member)) != null;
}

pub fn setAddBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, member: []const u8) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    if ((try bindex.get(transaction, old_root, member)) != null) return catalogRef; // already a member, no version bump
    const new_root = try bindex.insert(transaction, old_root, member, 1);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn setRemoveBlob(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, member: []const u8) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    if ((try bindex.get(transaction, old_root, member)) == null) return catalogRef; // not a member, no version bump
    const new_root = try bindex.remove(transaction, old_root, member);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

// Collect members in ascending byte order. forEachEntry hands the callback a key
// slice that points into mapped storage and is only valid for the duration of
// the call, so each member is duped into `allocator`. The caller owns the result:
// it must free every appended slice and then deinit the list.
pub fn setCollectBlob(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    prop: usize,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const set_root = try Column.get(transaction, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            _ = val;
            try self.list.append(self.alloc, try self.alloc.dupe(u8, key));
        }
    };
    try bindex.forEachEntry(transaction, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

// ---------------------------------------------------------------------------
// dict: byte-string key -> u64 value, backed by the byte-keyed B+tree (bindex).
// ---------------------------------------------------------------------------

pub fn buildDict(transaction: *WriteTransaction, entries: []const catalog.DictEntry) !Reference {
    var root = try bindex.create(transaction);
    // bindex.insert overwrites an existing key, so a repeated key keeps the last value.
    for (entries) |e| root = try bindex.insert(transaction, root, e.key, e.val);
    return root;
}

pub fn dictGet(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize, key: []const u8) !?u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const dict_root = try Column.get(transaction, r.prop_col, r.row);
    return try bindex.get(transaction, dict_root, key);
}

pub fn dictCount(transaction: anytype, catalogRef: Reference, primaryKey: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return null;
    const dict_root = try Column.get(transaction, r.prop_col, r.row);
    return try bindex.count(transaction, dict_root);
}

pub fn dictPut(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, key: []const u8, val: u64) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    const new_root = try bindex.insert(transaction, old_root, key, val); // overwrites existing key
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

pub fn dictRemove(transaction: *WriteTransaction, catalogRef: Reference, primaryKey: u64, prop: usize, key: []const u8) !Reference {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const old_root = try Column.get(transaction, r.prop_col, r.row);
    if ((try bindex.get(transaction, old_root, key)) == null) return catalogRef; // absent, no version bump
    const new_root = try bindex.remove(transaction, old_root, key);
    return catalog.replaceCollRoot(transaction, catalogRef, r.row, prop, new_root);
}

// Collect (key, val) pairs in ascending byte-key order. The key slice handed to
// the callback is only valid during the call, so each key is duped into
// `allocator`. The caller owns the result: it must free every entry's key and
// then deinit the list.
pub fn dictCollect(
    transaction: anytype,
    catalogRef: Reference,
    primaryKey: u64,
    prop: usize,
    out: *std.ArrayList(catalog.DictEntry),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(transaction, catalogRef, primaryKey, prop)) orelse return error.NotFound;
    const dict_root = try Column.get(transaction, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(catalog.DictEntry),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.list.append(self.alloc, .{ .key = try self.alloc.dupe(u8, key), .val = val });
        }
    };
    try bindex.forEachEntry(transaction, dict_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

test {
    _ = @import("collectionsTests.zig");
}
