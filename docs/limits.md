# Limits and contracts

The honest list. Some of these are Phase-1 scoping decisions, some are
inherent to the design; each says which.

## Threading: one Db instance, one thread

A `Db` instance has **no internal synchronization**. All transactions on one
instance must come from a single thread. Two threads sharing an instance is a
data race, full stop.

What is safe: one `Db` instance per thread (or per process), all attached to
the same file. The write lock, reader pins, and reclaim horizon coordinate
across instances exactly as they do across processes. Scoping decision — a
thread-safe handle layer is future work.

## Single writer

One write transaction at a time across all processes, serialized by the coord
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
  `bindex`).
- Up to 256 types, 256 properties per type. Properties are positional; names
  live in whatever binding layer sits on top.
- `updateTyped` does not yet rewrite collection properties (lists/sets/dicts
  are mutated through their own APIs instead).

## Point-in-time reads

- Bounded by the 128-entry version ring and the retention window. With
  `retain_versions = 0` (the default) only the latest version is readable.
- The retention window is shared and persisted. Raising it is always safe;
  lowering it while another process may hold point-in-time readers is not —
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

- Liveness of reader pins is pid + process-start-time. If the start-time
  query fails (exotic sandboxing), a recycled pid degrades to pid-only
  liveness: safe, but a dead reader's pin may persist until the slot is
  reused.
- The coord file must live next to the data file on the same filesystem.
- Advisory locks: a process that bypasses airdb and writes the file directly
  defeats every guarantee.

## Blobs and allocation

- A single arena allocation caps at one section (16 MiB); larger blobs chunk
  transparently, but list/set/dict *elements* are u64s (blob elements are refs
  and follow blob rules).
- `Db.create`/`open` require absolute paths.

## Durability environment

- `F_FULLFSYNC` falls back to `fsync` on filesystems that reject it (e.g.
  some network mounts); plain `fsync` on non-Apple platforms trusts the drive
  to honor flush. The usual database caveats about lying hardware apply.
