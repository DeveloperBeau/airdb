# Limits and contracts

The honest list. Some of these are Phase-1 scoping decisions, some are
inherent to the design; each says which.

## Threading: one Database instance, one thread

A `Database` instance has **no internal synchronization**. All transactions on one
instance must come from a single thread. Two threads sharing an instance is a
data race, full stop.

What is safe: one `Database` instance per thread (or per process), all attached to
the same file. The write lock, reader pins, and reclaim horizon coordinate
across instances exactly as they do across processes. Scoping decision — a
thread-safe handle layer is future work.

## Single writer

One write transaction at a time across all processes, serialized by the coordination
file lock. `beginWrite` blocks; `beginWriteTry` returns `error.WouldBlock`.
Writer throughput is therefore one commit pipeline; batch with explicit
transactions or bulk operations rather than many small commits.

## Format stability

Pre-1.0, the on-disk format changes without migration support. A file
written by an older build may fail to open or fail integrity checks against a
newer one. Ship a matched engine with your app.

## Primary keys and schema

- One u64 primary key per type (property 0). Composite or string keys are
  future work at a layer above (secondary byte-keyed indexes exist as
  `byteKeyIndex`).
- Up to 256 types, 256 properties per type. Properties are positional; names
  live in whatever binding layer sits on top.
- `updateTyped` carries collection properties through unchanged; lists, sets,
  and dicts are mutated through their own APIs.

## Point-in-time reads

- Bounded by the 128-entry version ring and the retention window. With
  `retain_versions = 0` (the default) only the latest version is readable.
- The retention window is shared and persisted. Raising it protects versions
  committed AFTER the raise (space already reused cannot be un-reused);
  lowering it while another process may hold point-in-time readers is unsafe —
  raise-only while readers can exist.
- Retention withholds freed space from reuse, so a wide window trades file
  growth for history.

## Space and compaction

- Deletes tombstone; space returns through the free list and compaction, not
  immediately. Compaction is caller-driven (`maybeCompactStep`), never
  automatic.
- The file never shrinks in place; `compactInPlace` rewrites it (and requires
  every handle to the database to be closed first).

## Multi-process caveats

- Zero-copy `bytes` slices returned by reads point into the mapped file and
  are invalidated by any later mutation in the same write transaction that
  frees the underlying blob (e.g. replacing an embedded child, deleting or
  updating the row). Copy the bytes out before mutating if they must survive.
- Liveness of reader pins is pid + process-start-time (truncated to 32 bits;
  a false match needs a recycled pid AND a start-time collision). If the
  start-time query fails (exotic sandboxing), a recycled pid degrades to
  pid-only liveness: safe, but a dead reader's pin then persists until the
  squatting pid itself exits.
- At most 64 simultaneously attached Database instances per database; the 65th
  open fails with TooManyAttachments rather than degrade to reads whose pins
  no writer can see.
- The coordination file must live next to the data file on the same filesystem.
- Advisory locks: a process that bypasses airdb and writes the file directly
  defeats every guarantee.

## Blobs and allocation

- A single arena allocation caps at one section (16 MiB); larger blobs chunk
  transparently, but list/set/dict *elements* are u64s (blob elements are references
  and follow blob rules).
- An indexed `.blob` property's value-index key is its stored bytes truncated
  to 256 bytes; two values sharing a 256-byte prefix share one index key
  (the query engine still returns the exact answer, re-checking every
  candidate against its full bytes).
- `bulkImport` refuses a type with an indexed `.blob` property
  (`error.UnsupportedForBulk`); an unindexed `.blob` property is unaffected.
- `Database.create`/`open` require absolute paths.

## Failed commits

- A data-barrier flush failure leaves the previous version fully live; the
  transaction is concluded and the commit can simply be retried.
- A commit-point (header) flush failure is different: the flipped commit
  pointer was already in the mapped page, so its on-disk fate is
  indeterminate. The instance refuses further writes (CommitIndeterminate)
  until the database is reopened; reopen re-reads the header and resolves
  which version won. Reads remain available throughout.

## Durability environment

- `F_FULLFSYNC` falls back to `fsync` on filesystems that reject it (e.g.
  some network mounts); plain `fsync` on non-Apple platforms trusts the drive
  to honor flush. The usual database caveats about lying hardware apply.
