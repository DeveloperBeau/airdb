# Architecture

airdb is a copy-on-write, memory-mapped storage engine with a typed object
layer on top. Everything lives in one data file plus a small coordination
sidecar (`<path>.coord`). There is no WAL, no page cache of its own, and no
background threads: durability comes from an atomic two-slot commit, and all
maintenance (compaction) is driven explicitly by the caller.

## Layer map

| Layer | Files | Responsibility |
|---|---|---|
| Platform | `platform.zig`, `syncer.zig` | mmap sections, file locks, pid/incarnation checks, durability barrier (`F_FULLFSYNC` on Darwin, `fsync` elsewhere), injectable `Syncer` for crash tests |
| Store | `file_store.zig`, `slots.zig`, `arena.zig`, `freelist.zig` | CRC-checked header, two CRC-checked commit slots, bump-allocating arena over the mapping, persisted free list with size-class buckets |
| Transactions | `db.zig`, `write_txn.zig`, `read_txn.zig`, `coord.zig` | MVCC snapshots and pins, the commit protocol, version→root ring for point-in-time reads, cross-process coordination |
| Trees | `index.zig`/`index_node.zig`, `column.zig`/`column_node.zig`, `bindex.zig`, `blob.zig` | copy-on-write B+trees (u64-keyed index with subtree counts, row-indexed column, byte-keyed bindex), chunked blob heap |
| Objects | `catalog.zig`, `objects.zig`, `typedir.zig`, `links.zig`, `collections.zig` | typed columnar storage, stable object keys, optimistic versioning, value indexes, link graph with delete rules |
| Operations | `compaction.zig`, `relocation.zig`, `bulk.zig`, `migrations.zig`, `query.zig` | incremental and full compaction, bulk import/append, schema evolution, predicate queries |
| Edge | `ffi.zig`, `include/airdb.h` | C ABI: auto-commit CRUD, bulk, explicit transactions |

## Memory mapping: sections that never move

The file is mapped in fixed 16 MiB sections. Growth only appends new
sections; an existing section is never remapped or moved, so every live
pointer into the mapping stays valid for the life of the process. A `Ref` is
an absolute byte offset; `arena.deref` is the single bounds-checked chokepoint
every read goes through (null, alignment, section bounds, no cross-section
spans). No allocation may cross a section boundary, which caps a single
allocation at the section size.

## The commit protocol

The header page holds two commit slots (A and B), each a CRC32-checksummed
`(version, root_ref, free_list_ref, logical_size)` record, plus a header whose
`active_slot` byte is the commit pointer.

1. Build the new persistent free list and write it into the arena.
2. Encode the new slot into the **inactive** slot region; record
   `(version, root)` in the version ring.
3. **Flush** — the data barrier. New nodes, free list, and slot are durable.
   Failure here: nothing observable changed; the old slot is untouched.
4. Flip `header.active_slot` to the new slot; rewrite the header CRC.
5. **Flush** — the commit point. Failure here: all in-memory header state is
   reverted; recovery still sees the old slot.
6. Only now: publish the new version in memory and in the coord file.

Recovery follows `header.active_slot`, never "highest version": a slot made
durable by step 3 whose commit never reached step 5 must not be resurrected.
If the primary slot's CRC is bad, recovery falls back to the other slot (the
previous version) and reports it via `metrics().recovered_fallback`. The test
suite drives every one of these paths with a `FailingSyncer` that fails the
Nth flush.

## MVCC and space reclamation

Every mutation is copy-on-write: a write transaction builds a new tree
version; committed nodes are never modified in place. Readers pin the version
they opened and publish that pin to their coord participant slot.

Freed space is reclaimed through a horizon:

- Nodes allocated **and** freed inside one uncommitted transaction are private
  and reused immediately (bulk operations stay space-bounded).
- Nodes belonging to a committed version enter the persistent free list tagged
  with the version that freed them. They become reusable only when every live
  reader in every attached process has moved past that version
  (`coord.globalHorizon`), further clamped by the **retention window**.
- The retention window (`setRetainVersions`) is stored in the header page and
  shared by all processes: space freed within the most recent N versions is
  withheld, which is what makes point-in-time reads (`beginReadAt`) safe under
  concurrent writers. Both `beginRead` and `beginReadAt` pin first and
  re-validate against the published latest version after the pin is visible,
  retrying (latest reads) or refusing (point-in-time reads) when the world
  moved past the pin while it was in flight.

The free list itself is bucketed by 8-byte size class with back-pointer
repair, making exact-class reuse O(1). It deliberately does not carve or
coalesce: the copy-on-write cycle frees and reallocates a small fixed set of
node sizes, and exact matching keeps that pool fragment-free (both carving and
merging were tried and shredded it).

## Point-in-time reads

The header page carries a 128-entry ring of `(version, root)` pairs, written
as part of the same barrier as the commit slot. `beginReadAt(v)` resolves a
past version through the ring (newest entry wins, so an aborted commit's
leftover entry can never shadow the real one) and pins it like any reader.
Availability is bounded by the ring capacity and the retention window.

## Multi-process coordination

`<path>.coord` is a 4 KiB mmap'd sidecar:

- an attach count and the published latest version (atomics),
- the cross-process write lock (an advisory file lock — one writer at a time),
- 64 participant slots, each `(pid, incarnation token, min pinned version)`.

A writer computes the global reclaim horizon as the minimum pinned version
across live participants. Liveness is pid **plus incarnation** (process start
time): a recycled pid cannot keep a dead reader's pin alive. Dead slots are
reclaimed in passing.

## The object layer

A **type directory** maps type ids to **catalogs**. A catalog is one node
describing a type: per-property column roots, kinds, a pk index
(pk → object key), a key→row index (object key → physical row), version and
liveness columns, and per-property backlink/value indexes. Rows live in
columns addressed by physical row; the **object key** (okey) is the stable
identity — links and indexes reference okeys, so compaction can relocate rows
without breaking anything.

Catalog rewrites go through `CatalogSnapshot`: load every field into an owned
value, mutate, write. Mutations are whole-catalog copy-on-write, so a
transaction threads catalog refs exactly like tree roots.

Secondary structures are maintained transactionally with the row:

- **Value indexes** (per indexed property): value → set of okeys. The query
  planner drives equality/range predicates off them.
- **Backlinks** (per link property): target okey → set of source okeys. They
  power `nullify`/`cascade`/`block` delete rules.

`verifyIntegrity` audits both structures in both directions (every live row
covered; every entry resolves to a live, agreeing row), on top of header,
slot, root, and free-list validation.

## Compaction

Deletes tombstone rows; space is reclaimed on two tracks:

- **Incremental** (`compactStep`): a budget-proportional two-pointer pass that
  relocates live rows from the tail into dead slots, at most `budget` moves
  per call, with a cursor that survives across calls and resets on any churn.
  The dead tail is truncated only when the scan proves no live row remains
  above the live count. Index subtree counts make the per-step bookkeeping a
  single-node read.
- **Full file** (`compactInPlace`): copy all live data into a fresh file,
  **verify** the copy is equivalent to the source (type counts, live counts,
  order-independent pk folds, per-object readability, link identity), then
  publish with a single atomic rename hardened by a parent-directory fsync. A
  crash before the rename leaves the original untouched; after it, the new
  file is complete.
