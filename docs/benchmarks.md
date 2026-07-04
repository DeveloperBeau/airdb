# Benchmarks

The suite lives in `bench/` and runs outside `zig build test` so the test
cycle stays fast. It builds `ReleaseFast`, creates scratch databases under a
temp directory, and reports wall time, throughput, latency percentiles, file
and logical sizes, peak RSS, and page-fault deltas per scenario.

```sh
zig build bench                    # 1M-entity tier
zig build bench -- --scale=10m     # 10M tier
zig build bench -- --json=PATH     # append one JSON object per scenario
zig build bench -- --only=NAME     # single scenario
```

`bench/baseline-1m.json` is the committed baseline; compare a fresh
`--json` run against it to spot regressions.

## Scenarios

| Scenario | What it measures |
|---|---|
| `insert_recovery` | 1M sequential inserts across batched commits; reopen time and first-read latency after a cold open |
| `lookup_query` | point reads by pk (p50/p99), indexed equality query vs full scan |
| `churn_compaction` | steady-state insert+delete churn with the incremental compaction loop holding the dead-row bound |
| `blobs_pitr` | multi-chunk 24 MiB blobs: put/get bandwidth, latest reads vs point-in-time historical reads |
| `types_crud` | full-type CRUD over int/bool/blob/link/dict/set properties |
| `embedded_crud` | owner + embedded child lifecycle |
| `nested_embedded` | two levels of embedded ownership |
| `bulk_import` | bottom-up whole-table build into an empty type |
| `bulk_append` | right-edge batch appends against a populated type |

## Current numbers (1M tier)

Apple Silicon (M-series), macOS, ReleaseFast. One representative run; the
exact committed figures live in `bench/baseline-1m.json`.

| Scenario | Ops | Throughput | p50 | p99 | File |
|---|---|---|---|---|---|
| insert_recovery | 1,000,000 | 358k ops/s | — | — | 112 MiB |
| lookup_query | 100,000 | 1.24M ops/s | 0.8 µs | 2.8 µs | 208 MiB |
| churn_compaction | 40,000 | 21.6k ops/s | 15.4 ms/iter | 16.7 ms | 80 MiB |
| blobs_pitr | 8 × 24 MiB | put 1180 MiB/s, get 13.1 GiB/s | — | — | 272 MiB |
| types_crud | 350,000 | 54.0k ops/s | 3.5 µs | 37 µs | 1056 MiB |
| embedded_crud | 350,000 | 88.9k ops/s | 4.2 µs | 27 µs | 352 MiB |
| nested_embedded | 150,000 | 73.2k ops/s | 2.8 µs | 16 µs | 352 MiB |
| bulk_import | 1,000,000 | 16.8M rows/s (47× row-wise) | — | — | 64 MiB |
| bulk_append | 500,000 | 20.0M rows/s (51× row-wise) | — | — | 64 MiB |

Highlights from the notes lines:

- indexed equality query over 1M rows: 1.3 ms for 10k hits vs 43 ms full scan
- cold reopen of a 1M-row database: 51 ms; first read after reopen: 46 µs
- free-list cost per commit: ~20 µs encode across 101 batched commits
- typed CRUD per-phase p50: create 3.4 µs, read 1.8 µs, update 9.0 µs,
  delete 12.0 µs — deletes now reclaim every collection tree and blob
- the churn scenario's `bound=held` asserts incremental compaction kept dead
  rows under its bound for the whole run

## Known performance follow-ups

- Point reads pay ~8% versus the pre-subtree-count node format (inner nodes
  grew from 1027 to 1539 bytes to make `count()` a single-node read).
- Sequential insert throughput sits ~25% under the old baseline for the same
  reason plus catalog-node recycling; files are ~46% smaller in exchange.
- The graph-delete path (cascade + backlink pruning) dominates delete
  latency in `types_crud`/`embedded_crud` and has not been profiled yet.

## Reading the numbers

- `insert_recovery` throughput includes the durable commit barrier every
  batch; this is fsync-bound by design, not CPU-bound.
- `lookup_query`'s `idx_eq` vs `full` note line is the value-index payoff:
  an indexed equality query touches the candidate set only.
- `churn_compaction`'s `bound=held` note asserts the incremental compactor
  kept dead rows under its bound during the run — the scenario fails loudly
  if it doesn't.
- Free-list and setLength counters (`fl_*`, `setlength_*`) come from
  measurement-only counters on the Db and never affect behavior.
