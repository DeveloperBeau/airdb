const std = @import("std");
const WriteTxn = @import("write_txn.zig").WriteTxn;
const Ref = @import("ref.zig").Ref;
const Column = @import("column.zig");
const Index = @import("index.zig");
const bindex = @import("bindex.zig");
const blob = @import("blob.zig");
const catalog = @import("catalog.zig");

const PropKind = catalog.PropKind;
const ElemKind = catalog.ElemKind;
const PropDef = catalog.PropDef;
const Value = catalog.Value;
const PropCount = catalog.PropCount;
const CatalogView = catalog.CatalogView;
const max_prop_count = catalog.max_prop_count;

pub fn buildListInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Column.create(txn);
    for (items) |x| root = try Column.append(txn, root, x);
    return root;
}

pub fn buildListBlob(txn: *WriteTxn, items: []const []const u8) !Ref {
    var root = try Column.create(txn);
    for (items) |s| {
        const bref = try blob.put(txn, s);
        root = try Column.append(txn, root, bref);
    }
    return root;
}

pub fn buildSetInt(txn: *WriteTxn, items: []const u64) !Ref {
    var root = try Index.create(txn);
    for (items) |k| root = try Index.insert(txn, root, k, 1);
    return root;
}

pub fn listLen(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.len(txn, list_root);
}

pub fn listGetInt(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) !u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    return try Column.get(txn, list_root, index);
}

pub fn listGetBlob(txn: anytype, cat: Ref, pk: u64, prop: usize, index: u64) ![]const u8 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const list_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try Column.get(txn, list_root, index);
    return try blob.get(txn, bref);
}

pub fn listAppendInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, value: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.append(txn, old_root, value);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listSetInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, index: u64, value: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try Column.set(txn, old_root, index, value);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn listAppendBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, bytes: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const bref = try blob.put(txn, bytes);
    const new_root = try Column.append(txn, old_root, bref);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCountInt(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try Index.count(txn, set_root);
}

pub fn setContainsInt(txn: anytype, cat: Ref, pk: u64, prop: usize, key: u64) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try Index.get(txn, set_root, key)) != null;
}

pub fn setAddInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) != null) return cat; // already a member, no version bump
    const new_root = try Index.insert(txn, old_root, key, 1);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setRemoveInt(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try Index.get(txn, old_root, key)) == null) return cat; // not a member, no version bump
    const new_root = try Index.remove(txn, old_root, key);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setCollectInt(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(u64),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(u64),
        alloc: std.mem.Allocator,
        fn onKey(self: @This(), key: u64) !void {
            try self.list.append(self.alloc, key);
        }
    };
    try Index.forEachKey(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onKey);
}

// ---------------------------------------------------------------------------
// set of blob: byte-string members backed by the byte-keyed B+tree (bindex).
// Members are the bindex keys; the value column is an unused sentinel (1).
// ---------------------------------------------------------------------------

pub fn buildSetBlob(txn: *WriteTxn, items: []const []const u8) !Ref {
    var root = try bindex.create(txn);
    // bindex.insert overwrites an existing key, so duplicate members dedup.
    for (items) |member| root = try bindex.insert(txn, root, member, 1);
    return root;
}

pub fn setCountBlob(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.count(txn, set_root);
}

pub fn setContainsBlob(txn: anytype, cat: Ref, pk: u64, prop: usize, member: []const u8) !bool {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    return (try bindex.get(txn, set_root, member)) != null;
}

pub fn setAddBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, member: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, member)) != null) return cat; // already a member, no version bump
    const new_root = try bindex.insert(txn, old_root, member, 1);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn setRemoveBlob(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, member: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, member)) == null) return cat; // not a member, no version bump
    const new_root = try bindex.remove(txn, old_root, member);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

// Collect members in ascending byte order. forEachEntry hands the callback a key
// slice that points into mapped storage and is only valid for the duration of
// the call, so each member is duped into `allocator`. The caller owns the result:
// it must free every appended slice and then deinit the list.
pub fn setCollectBlob(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const set_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList([]const u8),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            _ = val;
            try self.list.append(self.alloc, try self.alloc.dupe(u8, key));
        }
    };
    try bindex.forEachEntry(txn, set_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

// ---------------------------------------------------------------------------
// dict: byte-string key -> u64 value, backed by the byte-keyed B+tree (bindex).
// ---------------------------------------------------------------------------

pub fn buildDict(txn: *WriteTxn, entries: []const catalog.DictEntry) !Ref {
    var root = try bindex.create(txn);
    // bindex.insert overwrites an existing key, so a repeated key keeps the last value.
    for (entries) |e| root = try bindex.insert(txn, root, e.key, e.val);
    return root;
}

pub fn dictGet(txn: anytype, cat: Ref, pk: u64, prop: usize, key: []const u8) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.get(txn, dict_root, key);
}

pub fn dictCount(txn: anytype, cat: Ref, pk: u64, prop: usize) !?u64 {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return null;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    return try bindex.count(txn, dict_root);
}

pub fn dictPut(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: []const u8, val: u64) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    const new_root = try bindex.insert(txn, old_root, key, val); // overwrites existing key
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

pub fn dictRemove(txn: *WriteTxn, cat: Ref, pk: u64, prop: usize, key: []const u8) !Ref {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const old_root = try Column.get(txn, r.prop_col, r.row);
    if ((try bindex.get(txn, old_root, key)) == null) return cat; // absent, no version bump
    const new_root = try bindex.remove(txn, old_root, key);
    return catalog.replaceCollRoot(txn, cat, r.row, prop, new_root);
}

// Collect (key, val) pairs in ascending byte-key order. The key slice handed to
// the callback is only valid during the call, so each key is duped into
// `allocator`. The caller owns the result: it must free every entry's key and
// then deinit the list.
pub fn dictCollect(
    txn: anytype,
    cat: Ref,
    pk: u64,
    prop: usize,
    out: *std.ArrayList(catalog.DictEntry),
    allocator: std.mem.Allocator,
) !void {
    const r = (try catalog.resolveProp(txn, cat, pk, prop)) orelse return error.NotFound;
    const dict_root = try Column.get(txn, r.prop_col, r.row);
    const Sink = struct {
        list: *std.ArrayList(catalog.DictEntry),
        alloc: std.mem.Allocator,
        fn onEntry(self: @This(), key: []const u8, val: u64) !void {
            try self.list.append(self.alloc, .{ .key = try self.alloc.dupe(u8, key), .val = val });
        }
    };
    try bindex.forEachEntry(txn, dict_root, Sink{ .list = out, .alloc = allocator }, Sink.onEntry);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("collectionsTests.zig");
}
