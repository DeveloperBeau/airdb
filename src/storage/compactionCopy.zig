//! Deep-copying of live rows and values between databases.
//!
//! This is the per-value/per-row copy machinery behind full-file compaction
//! (compaction.compactToNewFile): copying a single property value across
//! databases (including blobs, lists, sets, dicts, and link sets), copying all
//! live rows of one type into a fresh destination catalog, and rebuilding the
//! destination's backlink indexes from its copied forward links.

const std = @import("std");
const WriteTransaction = @import("../database.zig").WriteTransaction;
const Reference = @import("reference.zig").Reference;
const Column = @import("../trees/column.zig");
const Index = @import("../trees/index.zig");
const catalog = @import("../schema/catalog.zig");
const blob = @import("../records/blob.zig");
const links = @import("../records/links.zig");
const byteKeyIndex = @import("../trees/byteKeyIndex.zig");

/// One key->row index entry: a stable object key and its physical row.
pub const Pair = struct { objectKey: u64, row: u64 };

/// Collect every (objectKey, row) entry of the key->row index rooted at
/// `keyToRowIndexReference` into a list the caller owns. O(live rows).
pub fn collectKeyRowPairs(
    allocator: std.mem.Allocator,
    transaction: anytype,
    keyToRowIndexReference: Reference,
) !std.ArrayList(Pair) {
    var pairs = std.ArrayList(Pair).empty;
    errdefer pairs.deinit(allocator);
    const Collector = struct {
        list: *std.ArrayList(Pair),
        allocator: std.mem.Allocator,
        fn onEntry(self: @This(), key: u64, value: u64) !void {
            try self.list.append(self.allocator, .{ .objectKey = key, .row = value });
        }
    };
    try Index.forEachEntry(transaction, keyToRowIndexReference, Collector{ .list = &pairs, .allocator = allocator }, Collector.onEntry);
    return pairs;
}

// Deep-copy a single property value from the source database into the destination database.
// kind/element describe the property. Returns the destination-local raw u64.
fn copyValue(source: anytype, destination: *WriteTransaction, kind: catalog.PropertyKind, element: catalog.ElementKind, srcRaw: u64) !u64 {
    return switch (kind) {
        .int, .link => srcRaw, // verbatim (a link stores an object key, preserved)
        .blob => try blob.copyInto(source, destination, srcRaw),
        .list => blk: {
            var newc = try Column.create(destination);
            const elementCount = try Column.length(source, srcRaw);
            var elementIndex: u64 = 0;
            while (elementIndex < elementCount) : (elementIndex += 1) {
                const elementValue = try Column.get(source, srcRaw, elementIndex);
                const copiedValue = if (element == .blob) try blob.copyInto(source, destination, elementValue) else elementValue;
                newc = try Column.append(destination, newc, copiedValue);
            }
            break :blk newc;
        },
        .set => switch (element) {
            .blob => try copyBindex(source, destination, srcRaw), // byte-keyed set -> byteKeyIndex deep-copy
            else => try copyKeySet(source, destination, srcRaw), // int-keyed set: a u64-keyed Index
        },
        .linkSet => try copyKeySet(source, destination, srcRaw),
        .dict => try copyBindex(source, destination, srcRaw), // byte-keyed dict -> byteKeyIndex deep-copy
    };
}

// Deep-copy a u64-keyed set (Index mapping key -> 1) from `src` into `dst` by
// iterating the source keys and re-inserting each into a fresh destination set.
fn copyKeySet(source: anytype, destination: *WriteTransaction, srcRoot: u64) !u64 {
    var newi = try Index.create(destination);
    const Sink = struct {
        indexReference: *Reference,
        dstp: *WriteTransaction,
        fn onKey(self: @This(), key: u64) !void {
            self.indexReference.* = try Index.insert(self.dstp, self.indexReference.*, key, 1);
        }
    };
    try Index.forEachKey(source, srcRoot, Sink{ .indexReference = &newi, .dstp = destination }, Sink.onKey);
    return newi;
}

// Deep-copy a byteKeyIndex root (dict or byte-keyed set) from `src` into `dst` by
// iterating the source tree and re-inserting each entry. byteKeyIndex.insert re-puts
// the key into the destination's blob heap, so this is a correct cross-database
// deep-copy. forEachEntry hands the callback a key slice into the SOURCE mapping;
// byteKeyIndex.insert grows only the DST arena (a different mapping), so the source key
// stays valid for the duration of the insert -- keep the insert inside onEntry.
fn copyBindex(source: anytype, destination: *WriteTransaction, srcRoot: u64) !u64 {
    var newr = try byteKeyIndex.create(destination);
    const Sink = struct {
        dstp: *WriteTransaction,
        root: *u64,
        fn onEntry(self: @This(), key: []const u8, value: u64) !void {
            self.root.* = try byteKeyIndex.insert(self.dstp, self.root.*, key, value);
        }
    };
    try byteKeyIndex.forEachEntry(source, srcRoot, Sink{ .dstp = destination, .root = &newr }, Sink.onEntry);
    return newr;
}

// Add objectKey under `value` in a value index (value -> {objectKey -> 1}), mirroring the
// shape the object layer's maintenance keeps. Local to the copy path, which
// must rebuild value indexes in the destination database.
fn viAddInto(destination: *WriteTransaction, valueIndexReference: Reference, value: u64, objectKey: u64) !Reference {
    const existing = try Index.get(destination, valueIndexReference, value);
    var setRoot = existing orelse try Index.create(destination);
    setRoot = try Index.insert(destination, setRoot, objectKey, 1);
    return try Index.insert(destination, valueIndexReference, value, setRoot);
}

// Re-point every reference field of the snapshot at fresh structures created in the
// DESTINATION database. Backlink and value indexes are created empty in the
// destination (the source references live in the source database's address space) and
// repopulated separately; the indexed flag carries through.
fn createDestinationStructures(destination: *WriteTransaction, snapshot: *catalog.CatalogSnapshot) !void {
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        snapshot.properties[propertyIndex].column = try Column.create(destination);
        snapshot.properties[propertyIndex].backlink = if (snapshot.properties[propertyIndex].kind == .link or snapshot.properties[propertyIndex].kind == .linkSet) try Index.create(destination) else 0;
        snapshot.properties[propertyIndex].valueIndex = if (snapshot.properties[propertyIndex].indexed) try Index.create(destination) else 0;
    }
    snapshot.versionColumnReference = try Column.create(destination);
    snapshot.liveColumnReference = try Column.create(destination);
    snapshot.keyToRowIndexReference = try Index.create(destination);
    snapshot.primaryKeyIndexReference = try Index.create(destination);
}

/// Copy all live rows of `sourceCatalog` (in the source database) into a fresh catalog in the
/// destination database, preserving object keys, primary keys, and nextKey. Backlink
/// indexes are created empty (rebuild with rebuildBacklinks afterward); value
/// indexes are repopulated inline. Returns the new destination catalog reference.
/// O(live rows x properties), plus the deep copies' own costs.
pub fn copyTypeRows(source: anytype, sourceCatalog: Reference, destination: *WriteTransaction) !Reference {
    // Load the source snapshot, then re-point every reference field at structures
    // created in the DESTINATION database before writing. Kinds, element kinds, targets,
    // rules, and indexed flags carry over as plain values.
    var snapshot = try catalog.CatalogSnapshot.load(source, sourceCatalog);
    const propertyCount = snapshot.propertyCount;
    // Keep the source references to read from.
    var sourcePropertyColumns: [catalog.maxPropertyCount]Reference = undefined;
    {
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) sourcePropertyColumns[propertyIndex] = snapshot.properties[propertyIndex].column;
    }
    const sourceVersionColumn = snapshot.versionColumnReference;
    const sLive = snapshot.liveColumnReference;
    const sourceKeyToRowIndexReference = snapshot.keyToRowIndexReference;

    // Collect live (objectKey, srcRow) pairs, then re-point at fresh dst structures.
    const scratchAllocator = destination.database.store.allocator;
    var pairs = try collectKeyRowPairs(scratchAllocator, source, sourceKeyToRowIndexReference);
    defer pairs.deinit(scratchAllocator);
    try createDestinationStructures(destination, &snapshot);

    var dRow: u64 = 0;
    for (pairs.items) |pair| {
        if ((try Column.get(source, sLive, pair.row)) == 0) continue; // defensive
        var propertyIndex: usize = 0;
        while (propertyIndex < propertyCount) : (propertyIndex += 1) {
            const sraw = try Column.get(source, sourcePropertyColumns[propertyIndex], pair.row);
            const draw = try copyValue(source, destination, snapshot.properties[propertyIndex].kind, snapshot.properties[propertyIndex].element, sraw);
            snapshot.properties[propertyIndex].column = try Column.append(destination, snapshot.properties[propertyIndex].column, draw);
            // Repopulate the destination value index in the same pass. Leaving
            // it empty while the catalog still says indexed=true silently
            // empties every indexed query after a full-file compaction (the
            // planner trusts the flag) and fails the value-index audit.
            if (snapshot.properties[propertyIndex].indexed) {
                snapshot.properties[propertyIndex].valueIndex = try viAddInto(destination, snapshot.properties[propertyIndex].valueIndex, draw, pair.objectKey);
            }
        }
        const version = try Column.get(source, sourceVersionColumn, pair.row);
        snapshot.versionColumnReference = try Column.append(destination, snapshot.versionColumnReference, version);
        snapshot.liveColumnReference = try Column.append(destination, snapshot.liveColumnReference, 1);
        snapshot.keyToRowIndexReference = try Index.insert(destination, snapshot.keyToRowIndexReference, pair.objectKey, dRow);
        const primaryKey = try Column.get(source, sourcePropertyColumns[0], pair.row);
        snapshot.primaryKeyIndexReference = try Index.insert(destination, snapshot.primaryKeyIndexReference, primaryKey, pair.objectKey);
        dRow += 1;
    }

    snapshot.nextRow = dRow;
    return snapshot.write(destination);
}

/// Rebuild backlink indexes for `catalogReference` (in dst) from its copied forward links.
/// O(live rows x link properties x link fan-out).
pub fn rebuildBacklinks(destination: *WriteTransaction, catalogReference: Reference) !Reference {
    var currentCatalog = catalogReference;
    const baseView = try catalog.loadCatalog(destination, catalogReference);
    const propertyCount = baseView.propertyCount;
    const scratchAllocator = destination.database.store.allocator;
    var propertyIndex: usize = 0;
    while (propertyIndex < propertyCount) : (propertyIndex += 1) {
        const kind = (try catalog.loadCatalog(destination, currentCatalog)).kind(propertyIndex);
        if (kind != .link and kind != .linkSet) continue;
        // collect (objectKey,row) of cur
        var pairs = blk: {
            const currentView = try catalog.loadCatalog(destination, currentCatalog);
            break :blk try collectKeyRowPairs(scratchAllocator, destination, currentView.keyToRowIndexReference);
        };
        defer pairs.deinit(scratchAllocator);
        for (pairs.items) |pair| {
            const currentView = try catalog.loadCatalog(destination, currentCatalog);
            const column = currentView.propertyColumnReference(propertyIndex);
            const raw = try Column.get(destination, column, pair.row);
            if (kind == .link) {
                if (raw != 0) currentCatalog = try links.addBacklink(destination, currentCatalog, propertyIndex, raw - 1, pair.objectKey);
            } else {
                // linkSet: the column holds a set-root of target objectKeys
                var members = std.ArrayList(u64).empty;
                defer members.deinit(scratchAllocator);
                const MemberCollector = struct {
                    list: *std.ArrayList(u64),
                    allocator: std.mem.Allocator,
                    fn onKey(self: @This(), key: u64) !void {
                        try self.list.append(self.allocator, key);
                    }
                };
                try Index.forEachKey(destination, raw, MemberCollector{ .list = &members, .allocator = scratchAllocator }, MemberCollector.onKey);
                for (members.items) |member| currentCatalog = try links.addBacklink(destination, currentCatalog, propertyIndex, member, pair.objectKey);
            }
        }
    }
    return currentCatalog;
}
