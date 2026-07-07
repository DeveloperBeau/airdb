# Features

Code pointers use `module.function` names under `src/`.

## Durability and recovery

- Two-slot atomic commit with CRC-checked slots and header
  (`writeTransaction.commit`, `slots.Slot`). A commit either fully happens or leaves
  the previous version live — verified by flush-failure injection tests.
- Full durability barrier per commit: `F_FULLFSYNC` on Apple platforms (drive
  write cache included), `fsync` elsewhere (`syncer.FileSyncer`).
- Crash recovery follows the committed slot pointer, with CRC fallback to the
  previous version surfaced via `Database.metrics().recovered_fallback`.
- `Database.verifyIntegrity`: header/slot/root/free-list validation plus
  bidirectional audits of every value index and backlink index.
- Corrupt input is an error, never a crash: parsers validate counts and enum
  bytes, tree walks are depth-capped against ref cycles, and every read passes
  a bounds-checked deref.

## Transactions

- Single writer (cross-process lock), many readers, no blocking between them.
- `Database.beginRead` — snapshot at the latest version; `ReadTransaction.end` unpins.
- `Database.beginWrite` / `beginWriteTry` — exclusive write transaction; `commit`
  is the durable point, `deinit` aborts and rolls back the bump allocator so
  aborted work costs no file space.
- Optimistic per-row versioning: `update`/`delete` take an expected version
  and return `conflict` with the current one on mismatch.

## Point-in-time reads

- `Database.beginReadAt(version)` opens a committed past version (bounded by the
  128-version ring and the retention window).
- `Database.setRetainVersions(n)` — shared, persisted retention floor honored by
  writers in every attached process.
- `oldestReadableVersion` / `oldestRetainedVersion` report the readable range.

## Typed object store

- Up to 256 types per database (`typeDirectory`), up to 256 properties per type
  (`catalog`). Property kinds: `int`, `blob`, `list` (int/blob elements),
  `set` (int/blob), `dict` (byte key → u64), `link`, `link_set`.
- Primary key: u64 (property 0). Stable object keys decouple identity from
  physical rows.
- Blobs: zero-copy reads up to ~16 MiB inline, transparent chunking beyond
  (tested to 40 MiB); `blob.readInto`/`getAlloc` for materialization.
- Schema evolution: `migrations.addProperty` (with backfill default) and
  `removeProperty`, both transactional.

## Links and graph rules

- To-one (`link`) and to-many (`link_set`) with target-type metadata and
  automatic backlink maintenance.
- Delete rules per property: `nullify` (clear inbound links), `cascade`
  (delete owned children, cycle-safe), `block` (refuse while referenced) —
  enforced by `typeRouting.deleteNullifyCrossType`.
- Embedded (single-owner) objects: `insertEmbedded` / `clearEmbedded` with
  replace semantics.

## Secondary indexes and queries

- Per-property value indexes (`indexed = true`), maintained in the same
  transaction as every insert/update/delete; emptied entries are pruned.
- `query.where` / `countWhere` / `aggregateInt` with `eq/ne/lt/le/gt/ge`
  predicates (logical AND). The planner drives off an indexed equality or
  range predicate when one exists; otherwise the scan streams the key→row
  index without materializing the table.
- `query.rangeInclusive`, `query.sortByPropertyAscending`.

## Bulk operations

- `bulk.bulkImport` — build a whole table bottom-up into an empty type
  (columns, primaryKey/key→row indexes, value indexes), byte-identical to sequential
  inserts, all-or-nothing validation before a single node is written.
- `bulk.bulkAppend` — right-edge fast path for ascending-primaryKey batches on
  populated types; falls back to row-by-row when the batch doesn't qualify
  (`bulkAppendOrInsert`). Replaced edge nodes are freed, not leaked.

## Compaction

- `Database.maybeCompactStep(type_id, budget)` — incremental, budget-proportional
  packing with a resumable cursor and a proof-gated tail truncation.
- `compaction.compactInPlace(path)` — full-file shrink with a
  verify-before-swap equivalence gate and atomic rename publish.

## Multi-process

- Up to 64 simultaneously attached instances; one writer at a time via the coordination lock.
- Reader pins published per process; the space-reclaim horizon respects every
  live reader, with pid+incarnation liveness so recycled pids can't pin the
  horizon.
- `Database.attachedProcesses`, `Database.metrics()` for observability.

## C ABI (`include/airdb.h`)

- Auto-commit: `airdb_open/close/insert/get/update/delete/count/propertyCount`.
- Bulk: `airdb_bulk_insert` (empty type), `airdb_bulk_append`.
- Explicit transactions: `airdb_begin` → `airdb_txn_insert/update/delete` →
  `airdb_commit` / `airdb_abort` — one durable barrier per batch.
- Errors are negative codes (`AIRDB_E_*`); a corrupt database opens as `NULL`
  and is never truncated.
