# airdb
Modern Mobile DB

## Benchmarks

`zig build bench` runs the performance suite (insert/recovery, lookup/query,
churn/compaction, large blobs and historical reads, full-type CRUD, embedded and
nested-embedded objects). It prints a metrics table and is kept out of `zig build
test` so the test run stays fast.

- `zig build bench` runs the default 1M-entity tier.
- `zig build bench -- --scale=10m` runs the large 10M tier.
- `zig build bench -- --json=PATH` appends one JSON object per scenario to PATH.
- `zig build bench -- --only=NAME` runs a single scenario.

`bench/baseline-1m.json` holds a committed 1M baseline for comparison.
