//! The airdb library root: re-exports every module, grouped by layer
//! (storage primitives -> trees -> records -> schema -> transactions ->
//! database facade -> edges), plus the handful of types callers use most.

// Database facade and transactions.
/// The Database type and the two-slot atomic durable commit machinery.
pub const database = @import("database.zig");
/// One process's handle to a database file (see database.zig).
pub const Database = database.Database;
/// A pinned read snapshot over a Database.
pub const ReadTransaction = database.ReadTransaction;
/// The single in-flight mutation over a Database.
pub const WriteTransaction = database.WriteTransaction;
/// ReadTransaction's home module.
pub const readTransaction = @import("transactions/readTransaction.zig");
/// WriteTransaction's home module (commit protocol included).
pub const writeTransaction = @import("transactions/writeTransaction.zig");
/// Commit-slot selection, version adoption, reader pins, and the retention window.
pub const versioning = @import("transactions/versioning.zig");
/// The cross-process coordination file: attach counts, latest version, reader pins.
pub const coordination = @import("transactions/coordination.zig");

// Records: typed objects, raw rows, and value representations.
/// Typed encode/decode orchestration over the raw row layer.
pub const objects = @import("records/objects.zig");
/// Raw row CRUD over the catalog's columns and indexes.
pub const rows = @import("records/rows.zig");
/// The blob heap with its tagged inline/chunked representation.
pub const blob = @import("records/blob.zig");
/// List/set/dict collection properties.
pub const collections = @import("records/collections.zig");
/// To-one and to-many links with backlink maintenance.
pub const links = @import("records/links.zig");
/// Bulk import and right-edge bulk append.
pub const bulk = @import("records/bulk.zig");

// Schema: catalogs, the type directory, and routing.
/// The per-type catalog: property definitions, columns, and indexes.
pub const catalog = @import("schema/catalog.zig");
/// The type directory mapping type ids to catalog references.
pub const typeDirectory = @import("schema/typeDirectory.zig");
/// Object/link/delete routing through the type directory.
pub const typeRouting = @import("schema/typeRouting.zig");
/// Structural schema evolution: add and remove properties.
pub const migrations = @import("schema/migrations.zig");

// Trees: the copy-on-write storage structures.
/// Column tree: dense row index -> u64 value.
pub const column = @import("trees/column.zig");
/// The column tree's on-disk node formats.
pub const columnNode = @import("trees/columnNode.zig");
/// u64-keyed B+tree (inline numeric keys).
pub const index = @import("trees/index.zig");
/// The key->value B+tree's on-disk node formats.
pub const indexNode = @import("trees/indexNode.zig");
/// Byte-keyed B+tree (blob-reference keys).
pub const byteKeyIndex = @import("trees/byteKeyIndex.zig");

// Storage primitives.
/// A node's stable identity: an absolute byte offset into the mapped file.
pub const Reference = @import("storage/reference.zig").Reference;
/// Bump allocation, pooled reuse, and the bounds-checked dereference chokepoint.
pub const arena = @import("storage/arena.zig");
/// The reclaimable-extent pool and its persisted chunk-chain format.
pub const freeList = @import("storage/freeList.zig");
/// Recovery of the persisted free-list chain on open/refresh.
pub const freeListRecovery = @import("storage/freeListRecovery.zig");
/// Header, mmap sections, and the file-backed store.
pub const fileStore = @import("storage/fileStore.zig");
/// The checksummed commit-slot encoding.
pub const slots = @import("storage/slots.zig");
/// Generic storage-node header encode/parse.
pub const node = @import("storage/node.zig");
/// The injectable durability barrier and its implementations.
pub const syncer = @import("storage/syncer.zig");
/// Injectable flush capability (see storage/syncer.zig).
pub const Syncing = @import("storage/syncer.zig").Syncing;
/// Test syncer that fails a chosen flush to simulate a crash.
pub const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;

// Maintenance: compaction and relocation.
/// Type packing, incremental compaction, and whole-file compaction.
pub const compaction = @import("storage/compaction.zig");
/// Cross-database deep copying behind whole-file compaction.
pub const compactionCopy = @import("storage/compactionCopy.zig");
/// Moving a live row into a dead physical slot.
pub const relocation = @import("storage/relocation.zig");
/// Caller-driven upkeep entry points (budgeted compaction steps).
pub const maintenance = @import("maintenance.zig");
/// Offline integrity audit.
pub const verification = @import("verification.zig");

// Edges and platform.
/// Predicate queries, aggregation, and sorting over a catalog.
pub const query = @import("query.zig");
/// The C ABI surface for language bindings.
pub const cApi = @import("cApi.zig");
/// OS-specific operations: mmap, file locking, process checks.
pub const platform = @import("platform.zig");
/// Peak resident set size of the current process, in bytes (a syscall).
pub const peakResidentBytes = @import("platform.zig").peakResidentBytes;
/// Cumulative minor/major page-fault counts (a syscall).
pub const pageFaults = @import("platform.zig").pageFaults;

test {
    @import("std").testing.refAllDecls(@This());
}
