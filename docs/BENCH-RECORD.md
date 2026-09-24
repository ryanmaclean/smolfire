# ryanlab.bench.v1 emission — smolFire

> Tracking issue: smolFire #79. Cross-links: #63, #64, #72, #78, #86, #90.

smolFire is the first producer of the shared `ryanlab.bench.v1` benchmark
record defined in `ryanmaclean/skills`:

- `schemas/bench.v1.schema.json`
- `docs/BENCHMARKING.md`

Principle from that contract: **measure once, project many times**. A
benchmark/run fact is emitted once as `ryanlab.bench.v1`; Datadog
metrics/events/notebooks, GitHub Actions summaries, experiment keep/discard
decisions, and OpenLineage facets all read that one record instead of
recomputing metrics themselves.

## Producer

`bin/bench-record.nu` parses the `SMOLFIRE_METRIC key=value` /
`SMOLFIRE_SECTION name=bytes` lines already emitted by the microVM build and
boot-gate paths (the same lines `bin/smolfire-metrics.nu` consumes) and a
`TIME_TO_READY=<ms>ms` gate line, and emits one JSON record:

```sh
nu bin/bench-record.nu \
  --workload one-elf-boot \
  --filesystem ffs \
  --out bench-record.json \
  build.log gate.log
```

Required fields: `schema` (constant `ryanlab.bench.v1`), `project`,
`timestamp`, `workload`, `metrics`. `runtime`, `filesystem`, `commit`
(defaults to `git rev-parse --short HEAD`), and free-form `tags` are also
populated.

Derived named metrics (`artifact_bytes`, `rss_bytes`, `boot_ms`) are computed
from the raw log values where a clean mapping exists, but **every raw
`SMOLFIRE_METRIC`/`SMOLFIRE_SECTION` key is preserved verbatim in `metrics`
too** — `docs/BENCHMARKING.md` is explicit that raw measurements are never
discarded just because a derived/rollup value also exists.

## CI wiring

`.github/workflows/ci.yml` runs `tests/bench-record-test.nu` (unit tests
against the existing `tests/fixtures/smolfire-metrics-*.log` fixtures), then
emits a real record from those fixtures, appends it to the job's
`$GITHUB_STEP_SUMMARY`, and uploads it as the `bench-record` artifact.

This is intentionally scoped to fixture data for #79: the schema-valid
record path, CI summary, and artifact upload are proven end to end. Wiring
`bin/bench-record.nu` into the real `smolfire.yml` / `build-image.yml` build
logs (once those workflows write their `SMOLFIRE_METRIC` lines to a file CI
can hand to this script) and any Datadog metric projection are follow-on
work — see #79 for the acceptance checklist.

## Future producers

Per the shared contract, #86 (ARM-only durable-commit baseline) and #90
(BSD/SoC primitive benchmarks) should emit the same `ryanlab.bench.v1` shape
via this script (or a sibling using the same field names) once their
hardware-dependent measurements exist, so FPGA-vs-CPU comparisons are direct.
