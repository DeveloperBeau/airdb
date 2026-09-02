//! The include-fetch driver: resolve one page of a type's objects and its
//! requested link relations in batch, breadth-first, level by level, through
//! `batch.collectRowsForSortedKeys` (never through a per-key index descent).
//! Deliberately does NOT import `trees/index.zig`: every row resolution goes
//! through the batch primitive, so the missing import makes that structural
//! rather than a promise. Modeled on `typeRouting.zig`'s directory-scoped
//! call shape (2.9 of the spec): `(transaction, directoryReference, typeId,
//! ...)`, positionally, which is why this terminal takes a directory
//! reference rather than the catalog reference every other terminal in
//! `query.zig` takes.

const std = @import("std");
const Reference = @import("../storage/reference.zig").Reference;
const Column = @import("../trees/column.zig");
const catalog = @import("../schema/catalog.zig");
const typeDirectory = @import("../schema/typeDirectory.zig");
const Scan = @import("scan.zig").Scan;
const paging = @import("paging.zig");
const orderingLanguage = @import("ordering.zig");
const batch = @import("batch.zig");
const materialized = @import("materialized.zig");

const Request = orderingLanguage.Request;
const Relations = materialized.Relations;
const MaterializedObject = materialized.MaterializedObject;
const PropertyValue = materialized.PropertyValue;
const IncludedRelation = materialized.IncludedRelation;
const RelationTarget = materialized.RelationTarget;

// The per-fetch state every level needs, minus the transaction (which is
// `anytype` and so cannot be a field).
const Fetch = struct {
    directoryReference: Reference,
    arena: std.mem.Allocator,
    visited: *std.AutoHashMap(u64, *MaterializedObject),
    depth: usize,
};

// One relation waiting to be resolved: which parent asked, from which
// property, for which key of which type.
const PendingRelation = struct {
    parent: *MaterializedObject,
    includedSlot: usize,
    targetType: u16,
    targetKey: u64,
};

/// Pack a (typeId, objectKey) pair into the visited-set key, exactly as
/// `typeDirectory.zig`'s `deleteWorker` packs it. `objectKey` must fit in 48
/// bits (2^48 objects of one type); unreachable in practice and free in
/// release.
fn packVisitedKey(typeId: u16, objectKey: u64) u64 {
    std.debug.assert(objectKey >> 48 == 0);
    return (@as(u64, typeId) << 48) | objectKey;
}

/// Fetch one page of `typeId` objects and materialize them, resolving
/// `relations` in batch. `request` chooses the page exactly as `query.where`
/// does (same predicate, ordering, paging and cursor semantics); the relation
/// batch runs only after the page is chosen, so nothing about paging changes.
///
/// Every allocation, including the result and the engine's working sets, comes
/// from `arena`; free the whole result with one `arena.deinit()` and never
/// free an interior pointer. The result holds no pointer into mapped storage,
/// so ending the transaction cannot dangle a slice inside it, but
/// `.blobReference` and `.collectionRoot` values are storage references into
/// the transaction's snapshot and mean nothing once it ends. `typeId`,
/// `objectKey`, `version`, `.int` and `.link` stay valid after it ends.
///
/// `directoryReference` is a TYPE DIRECTORY reference, not a catalog
/// reference: this terminal resolves link targets across types, which only the
/// directory can do. Both are `Reference`, so passing the wrong one compiles.
///
/// Targets are resolved one level at a time, each level in one ascending walk
/// per target type; see `batch.collectRowsForSortedKeys` for that walk's cost,
/// which is the cost of the span between the smallest and largest target key,
/// not of the target count. On top of that, each materialized object costs one
/// column read per property plus its live and version cells. Levels below the
/// first follow EVERY `.link` property of each type reached, bounded only by
/// `relations.depth`. I/O throughout.
///
/// Errors: everything `Request.validate` and `Relations.validate` raise;
/// `error.NoSuchType` for a `typeId` outside the directory; `error.NotFound`
/// if a page key does not resolve to a row, which a consistent snapshot cannot
/// produce and a corrupt index can; `error.UnsortedObjectKeys` from
/// `collectRowsForSortedKeys` if `paging.collectPage` ever returns a
/// duplicate key, same class as `error.NotFound`: unreachable on a
/// consistent snapshot.
pub fn materializePage(
    transaction: anytype,
    directoryReference: Reference,
    typeId: u16,
    request: Request,
    relations: Relations,
    arena: std.mem.Allocator,
) ![]const MaterializedObject {
    const rootCatalogReference = try typeDirectory.catalogReference(transaction, directoryReference, typeId);
    const scan = try Scan.open(transaction, rootCatalogReference);
    try request.validate(&scan);
    try relations.validate(scan.propertyKinds[0..scan.propertyCount]);

    var pageKeys = std.ArrayList(u64).empty;
    try paging.collectPage(transaction, &scan, request, &pageKeys, arena);
    if (pageKeys.items.len == 0) return &.{};

    var visited = std.AutoHashMap(u64, *MaterializedObject).init(arena);
    const fetch = Fetch{
        .directoryReference = directoryReference,
        .arena = arena,
        .visited = &visited,
        .depth = relations.depth,
    };

    const roots = try materializeRoots(transaction, &fetch, typeId, pageKeys.items, relations.linkProperties);

    var currentLevelObjects = try pointersToElements(arena, roots);
    var level: usize = 0;
    while (level < relations.depth) : (level += 1) {
        const nextLevelObjects = try expandLevel(transaction, &fetch, level, currentLevelObjects);
        currentLevelObjects = try pointersToElements(arena, nextLevelObjects);
    }

    return roots;
}

// A slice of pointers, one per element of `values`, in the same order. `values`
// must never move after this call: every parent link recorded elsewhere
// (`visited`, `PendingRelation.parent`) is a pointer into it. O(values.len).
fn pointersToElements(arena: std.mem.Allocator, values: []MaterializedObject) ![]const *MaterializedObject {
    const pointers = try arena.alloc(*MaterializedObject, values.len);
    for (values, 0..) |*value, index| pointers[index] = value;
    return pointers;
}

// Resolve the page's own object keys through the same batch resolver every
// deeper level uses (2.8): sort a copy of the page keys, resolve in one walk,
// then scatter back to page order by the sort's own inverse permutation (no
// binary search, and no risk of a duplicate key resolving to the wrong slot).
// One ascending index walk plus one column read per property per root, O(span
// + pageKeys.len x propertyCount) with I/O.
fn materializeRoots(
    transaction: anytype,
    fetch: *const Fetch,
    typeId: u16,
    pageKeys: []const u64,
    rootLinkProperties: []const usize,
) ![]MaterializedObject {
    const KeyAtPosition = struct { objectKey: u64, pageIndex: usize };
    const pairs = try fetch.arena.alloc(KeyAtPosition, pageKeys.len);
    for (pageKeys, 0..) |objectKey, pageIndex| pairs[pageIndex] = .{ .objectKey = objectKey, .pageIndex = pageIndex };
    std.mem.sort(KeyAtPosition, pairs, {}, struct {
        fn lessThan(_: void, left: KeyAtPosition, right: KeyAtPosition) bool {
            return left.objectKey < right.objectKey;
        }
    }.lessThan);
    const sortedKeys = try fetch.arena.alloc(u64, pairs.len);
    for (pairs, 0..) |pair, index| sortedKeys[index] = pair.objectKey;

    const rootCatalogReference = try typeDirectory.catalogReference(transaction, fetch.directoryReference, typeId);
    const snapshot = try catalog.CatalogSnapshot.load(transaction, rootCatalogReference);

    const resolvedRows = try fetch.arena.alloc(?u64, sortedKeys.len);
    try batch.collectRowsForSortedKeys(transaction, snapshot.keyToRowIndexReference, sortedKeys, resolvedRows);

    const rowsInPageOrder = try fetch.arena.alloc(u64, pageKeys.len);
    for (pairs, 0..) |pair, sortedPosition| {
        rowsInPageOrder[pair.pageIndex] = resolvedRows[sortedPosition] orelse return error.NotFound;
    }

    const isAtBound = fetch.depth == 0;
    const roots = try fetch.arena.alloc(MaterializedObject, pageKeys.len);
    for (pageKeys, 0..) |objectKey, pageIndex| {
        const row = rowsInPageOrder[pageIndex];
        const live = try Column.get(transaction, snapshot.liveColumnReference, row);
        if (live == 0) return error.NotFound;
        try fillObject(transaction, fetch, &snapshot, typeId, objectKey, row, rootLinkProperties, isAtBound, &roots[pageIndex]);
        try fetch.visited.put(packVisitedKey(typeId, objectKey), &roots[pageIndex]);
    }
    return roots;
}

// Read one object's version cell and every property cell, decode them per
// materialized.PropertyValue's table, and fill `included` from
// `includedProperties`: one entry per requested link property, pre-filled
// from the decoded `.link` value (`.absent` for null, `.key` otherwise; the
// caller resolves `.key` entries to `.object` afterward). `included` stays
// empty at the depth bound, and empty when no property was requested. The
// caller has already read the live cell and confirmed the row is live before
// calling; fillObject does not re-read it. One column read per property plus
// the version cell, O(propertyCount) with I/O.
fn fillObject(
    transaction: anytype,
    fetch: *const Fetch,
    snapshot: *const catalog.CatalogSnapshot,
    typeId: u16,
    objectKey: u64,
    row: u64,
    includedProperties: []const usize,
    isAtBound: bool,
    out: *MaterializedObject,
) !void {
    const version = try Column.get(transaction, snapshot.versionColumnReference, row);

    const values = try fetch.arena.alloc(PropertyValue, snapshot.propertyCount);
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        const word = try Column.get(transaction, snapshot.properties[propertyIndex].column, row);
        values[propertyIndex] = switch (snapshot.properties[propertyIndex].kind) {
            .int => .{ .int = word },
            .link => .{ .link = if (word == 0) null else word - 1 },
            .blob => .{ .blobReference = word },
            .list, .set, .dict, .linkSet => .{ .collectionRoot = word },
        };
    }

    var included: []IncludedRelation = &.{};
    if (!isAtBound and includedProperties.len > 0) {
        included = try fetch.arena.alloc(IncludedRelation, includedProperties.len);
        for (includedProperties, 0..) |property, slot| {
            included[slot] = .{
                .property = property,
                .target = switch (values[property]) {
                    .link => |target| if (target) |key| RelationTarget{ .key = key } else RelationTarget.absent,
                    else => unreachable, // Relations.validate / includedPropertiesFor admit only .link
                },
            };
        }
    }

    out.* = .{
        .typeId = typeId,
        .objectKey = objectKey,
        .version = version,
        .values = values,
        .included = included,
    };
}

// Which properties are followed at one level (2.6): the root level follows
// exactly `relations.linkProperties` (handled by the caller, materializeRoots);
// every deeper level follows every `.link` property of the type it reached,
// in property order, written into `buffer` and returned as the used prefix.
// O(propertyCount).
fn includedPropertiesFor(snapshot: *const catalog.CatalogSnapshot, buffer: []usize) []const usize {
    var count: usize = 0;
    var propertyIndex: usize = 0;
    while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
        if (snapshot.properties[propertyIndex].kind == .link) {
            buffer[count] = propertyIndex;
            count += 1;
        }
    }
    return buffer[0..count];
}

// For each object at this level, push a PendingRelation for every included
// entry that is a not-yet-visited `.key` (a target reached for the first
// time). An entry already in `visited` is a back edge (2.7 rule 2) and is
// left as `.key` untouched. `objects` arrives grouped by typeId (level 0 is
// one page of one type; every deeper level is built run by run in
// expandLevel, one run per target type), so the source view is reloaded only
// when `object.typeId` changes from the previous object's: one directory
// lookup and one catalog load per distinct source type encountered, plus one
// visited-set probe per included entry, O(objects x includedPerObject) with
// I/O.
fn gatherPending(
    transaction: anytype,
    fetch: *const Fetch,
    objects: []const *MaterializedObject,
    out: *std.ArrayList(PendingRelation),
) !void {
    var currentSourceType: ?u16 = null;
    var currentSourceView: catalog.CatalogView = undefined;
    for (objects) |object| {
        if (object.included.len == 0) continue;
        if (currentSourceType == null or currentSourceType.? != object.typeId) {
            const sourceCatalogReference = try typeDirectory.catalogReference(transaction, fetch.directoryReference, object.typeId);
            currentSourceView = try catalog.loadCatalog(transaction, sourceCatalogReference);
            currentSourceType = object.typeId;
        }
        for (object.included, 0..) |relation, slot| {
            const targetKey = switch (relation.target) {
                .key => |key| key,
                .absent, .object => continue,
            };
            const targetType = currentSourceView.linkTarget(relation.property);
            if (fetch.visited.contains(packVisitedKey(targetType, targetKey))) continue;
            try out.append(fetch.arena, .{ .parent = object, .includedSlot = slot, .targetType = targetType, .targetKey = targetKey });
        }
    }
}

fn pendingLessThan(_: void, left: PendingRelation, right: PendingRelation) bool {
    if (left.targetType != right.targetType) return left.targetType < right.targetType;
    return left.targetKey < right.targetKey;
}

// Gather this level's pending relations, resolve each contiguous
// same-target-type run through one batch walk, and return the newly
// materialized objects (arena-fixed, so every pointer into it, including the
// ones just stored in `visited`, stays valid for the rest of the fetch).
// Cost: batch.collectRowsForSortedKeys's cost per run, plus fillObject's cost
// per newly materialized object.
fn expandLevel(transaction: anytype, fetch: *const Fetch, level: usize, parents: []const *MaterializedObject) ![]MaterializedObject {
    var pending = std.ArrayList(PendingRelation).empty;
    try gatherPending(transaction, fetch, parents, &pending);
    if (pending.items.len == 0) return &.{};
    std.mem.sort(PendingRelation, pending.items, {}, pendingLessThan);

    // Upper bound: at most one new object per pending relation (fewer once a
    // run's duplicate targets share one object). A single fixed allocation
    // keeps every pointer this level hands out stable for the rest of the
    // fetch: nothing here ever grows or moves.
    const results = try fetch.arena.alloc(MaterializedObject, pending.items.len);
    var filledCount: usize = 0;
    var runStart: usize = 0;
    while (runStart < pending.items.len) {
        var runEnd = runStart + 1;
        while (runEnd < pending.items.len and pending.items[runEnd].targetType == pending.items[runStart].targetType) runEnd += 1;
        filledCount += try expandRun(transaction, fetch, level, pending.items[runStart..runEnd], results[filledCount..]);
        runStart = runEnd;
    }
    return results[0..filledCount];
}

// One contiguous same-target-type run of pendings: resolve its deduplicated
// target keys in one batch walk, materialize the live ones into `out`
// (skipping a tombstoned or missing target, which stays `.key`), then upgrade
// every pending in the run that resolved to `.object`. Returns how many
// entries of `out` were filled.
fn expandRun(transaction: anytype, fetch: *const Fetch, level: usize, runPendings: []const PendingRelation, out: []MaterializedObject) !usize {
    const targetType = runPendings[0].targetType;
    const keyBuffer = try fetch.arena.alloc(u64, runPendings.len);
    for (runPendings, 0..) |pending, index| keyBuffer[index] = pending.targetKey;
    std.mem.sort(u64, keyBuffer, {}, std.sort.asc(u64));
    var uniqueCount: usize = 0;
    for (keyBuffer) |key| {
        if (uniqueCount == 0 or keyBuffer[uniqueCount - 1] != key) {
            keyBuffer[uniqueCount] = key;
            uniqueCount += 1;
        }
    }
    const sortedUniqueKeys = keyBuffer[0..uniqueCount];

    const targetCatalogReference = try typeDirectory.catalogReference(transaction, fetch.directoryReference, targetType);
    const snapshot = try catalog.CatalogSnapshot.load(transaction, targetCatalogReference);

    const resolvedRows = try fetch.arena.alloc(?u64, sortedUniqueKeys.len);
    try batch.collectRowsForSortedKeys(transaction, snapshot.keyToRowIndexReference, sortedUniqueKeys, resolvedRows);

    var includedPropertyBuffer: [catalog.maxPropertyCount]usize = undefined;
    const includedProperties = includedPropertiesFor(&snapshot, &includedPropertyBuffer);
    const isAtBound = level + 1 == fetch.depth;

    var filledCount: usize = 0;
    for (sortedUniqueKeys, 0..) |targetKey, index| {
        // stays .key: no index entry. Ordinarily reachable: links.setLink never
        // checks that its target key exists, so a link to a key nobody ever
        // inserted lands here (see "R30" in queryIncludeTests.zig).
        const row = resolvedRows[index] orelse continue;
        const live = try Column.get(transaction, snapshot.liveColumnReference, row);
        // stays .key: tombstoned. rows.delete always removes the key-to-row
        // index entry in the same step it tombstones the row, so this arm is
        // unreachable through any exposed write path today; it only guards
        // against an index entry left stale by something outside that
        // contract (see "R31" in queryIncludeTests.zig, which corrupts the
        // catalog directly to exercise it).
        if (live == 0) continue;
        const object = &out[filledCount];
        try fillObject(transaction, fetch, &snapshot, targetType, targetKey, row, includedProperties, isAtBound, object);
        try fetch.visited.put(packVisitedKey(targetType, targetKey), object);
        filledCount += 1;
    }

    for (runPendings) |pending| {
        if (fetch.visited.get(packVisitedKey(targetType, pending.targetKey))) |object| {
            @constCast(pending.parent.included)[pending.includedSlot].target = .{ .object = object };
        }
    }
    return filledCount;
}
