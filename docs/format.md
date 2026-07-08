# On-disk format

Pre-1.0: this layout changes without migration support. All integers are
little-endian; the store refuses to open big-endian-tagged files.

## File layout

The data file is a sequence of 16 MiB sections (`platform.section_size`),
mapped individually and never moved. A `Reference` is an absolute byte offset,
8-aligned, `0` meaning null. Offset 0 starts the reserved header page
(4096 bytes); the allocation arena begins at 4096.

### Header page (page 0)

| Range | Contents |
|---|---|
| `[0, 32)` | file header: magic u64, page_size u32, endianness u8, active_slot u8, reserved, logical_size u64, CRC32 of `[0,28)` |
| `[64, 100)` | commit slot A |
| `[128, 164)` | commit slot B |
| `[192, 200)` | retention window u64 (shared reclaim floor; 0 = none, maxInt = retain everything) |
| `[1016, 1024)` | version-ring head counter u64 (monotonic; live index = head % 128) |
| `[1024, 3072)` | version ring: 128 × (version u64, root_reference u64) |

A commit slot is `version u64, root_reference u64, free_list_reference u64,
logical_size u64, CRC32 of the preceding 32 bytes` (36 bytes).

### Free-list node

`[count u32]` then `count ×` `(offset u64, len u64, freed_version u64)`.
Lengths are stored rounded up to 8 (the arena 8-aligns allocation starts, so
the folded bytes are dead padding). One node is written per commit; the
previous node's space is recycled through the next list.

## Tree nodes

Three node families share the `[kind u8][count u16]` header. Fanout and leaf
capacity are both 64.

**Index (u64 → u64)** — `trees/indexNode.zig`, used for primaryKey indexes, key→row
indexes, sets of objectKeys, and value-index outer/inner trees:

- leaf (1027 B): count × (key u64, value u64), sorted by key
- inner (1539 B): count × (child_reference u64, low_key u64, subtree_count u64) —
  the subtree counts make `count()` a single-node read

**Column (row → u64)** — `trees/columnNode.zig`, one per property plus version and
liveness columns:

- leaf (515 B): count × value u64, addressed by position
- inner (1027 B): count × (child_reference u64, subtree_count u64)

**Bindex (bytes → u64)** — `trees/byteKeyIndex.zig`, byte-keyed dictionary/set: identical
layout to the index, except each key slot holds a blob reference to the key bytes
and ordering compares the dereferenced bytes.

## Blobs

Tagged by the first byte:

- inline (`0`): `[tag][len u32][bytes]`, up to just under one section
- chunked (`1`): `[tag][total_len u64][chunk_count u32][chunk_reference u64 × n]`
  with raw chunk nodes of up to ~16 MiB each

The empty blob is the null reference; no node is written.

## Catalog node

Per type: `propertyCount u16, next_row u64, primaryKeyIndexReference u64,
version_column_reference u64, live_column_reference u64, key_to_row_index_reference u64, next_key u64`,
then per-property parallel arrays in this order: column references (u64), kinds
(u8), element kinds (u8), backlink references (u64), link targets (u16), delete
rules (u8), value-index references (u64), indexed flags (u8). New arrays append at
the end so earlier offsets never move.

The type directory node is `type_count u16`, `type_count × catalog_reference u64`,
`type_count × embedded_flag u8`.

## Coordination sidecar (`<path>.coord`)

One 4096-byte page:

| Range | Contents |
|---|---|
| `[0, 8)` | magic |
| `[8, 12)` | attach count (atomic) |
| `[16, 24)` | published latest version (atomic) |
| `[64, 1088)` | 64 participant slots × 16 B: pid u32, incarnation token u32 (truncated process start time), min pinned version u64 |

The write lock is an advisory lock on this file. The sidecar carries no user
data; a stale one is deleted and recreated safely.
