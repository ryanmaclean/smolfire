# OpenLineage projection for BOP + filesystem facts

`bin/openlineage-export.nu` defines a compact internal record format and a deterministic OpenLineage projection. The exporter is **not** a state store: it only transforms facts that were already derived from BOP run identity, filesystem-native version/history identity, and observed input/output mutations.

## Mapping

| Internal fact | OpenLineage projection |
| --- | --- |
| BOP card/template | `job.namespace` + `job.name`, with `job.facets.smolfireBop` preserving `card` and `template` |
| One execution / lease | `run.runId`, with `run.facets.smolfireBopRun.leaseId` preserving the lease identifier |
| Parent/subagent | `run.facets.parent` (`ParentRunFacet`) |
| Dependencies | `run.facets.jobDependencies.upstream` (`JobDependenciesRunFacet`) |
| `pending -> running` | `eventType = "START"` |
| `running -> done` | `eventType = "COMPLETE"` |
| `running -> failed` | `eventType = "FAIL"` |
| Filesystem object / path | `inputs[]` / `outputs[]` dataset `namespace` + `name` |
| Filesystem-native version identity | `facets.version.datasetVersion`, plus `facets.smolfireFilesystemVersion` for filesystem-specific details |

## Compact internal record format (`schema_version = "v1"`)

The exporter accepts one JSON record or a JSON list of records. Each record contains only the facts needed to derive the OpenLineage event:

```json
{
  "schema_version": "v1",
  "event_time": "2026-09-23T09:15:00Z",
  "job": {
    "namespace": "smolfire.bop",
    "name": "build-image",
    "card": "build-image",
    "template": "release-image"
  },
  "run": {
    "run_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "state_from": "pending",
    "state_to": "running",
    "attempt": 2,
    "lease_id": "lease-42"
  },
  "parent": {
    "run_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "job": {"namespace": "smolfire.bop", "name": "coord-root"}
  },
  "dependencies": [
    {
      "job": {"namespace": "smolfire.bop", "name": "prepare-rootfs"},
      "run_id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    }
  ],
  "inputs": [
    {
      "namespace": "hammer2://tank/ci",
      "name": "/workspace/input.txt",
      "version": {
        "identity": "snapshot@ci.2026-09-23T09:10:00Z",
        "filesystem": "HAMMER2",
        "kind": "snapshot"
      }
    }
  ],
  "outputs": [
    {
      "namespace": "ffs://release",
      "path": "/artifacts/smolfire.ufs.qcow2"
    }
  ]
}
```

Only stable identities belong in this record. If a filesystem cannot supply a stable version identifier for a specific mutation, omit `version.identity`; the exporter will still emit the dataset path, but it will not invent a synthetic lineage version.

## Filesystem guidance

The exporter treats `version.identity` as the canonical dataset version string and preserves filesystem-native detail in `facets.smolfireFilesystemVersion`. This keeps one exporter working across the filesystem matrix without adding another canonical database.

- **HAMMER1**: use a TID only when it is already available as the volume-local mutation identity you trust for the dataset being exported. Pair it with the dataset namespace/path so it is not treated as a global identifier by itself.
- **LFS**: use a checkpoint or segment/checkpoint identity only when it is stable for replay and attribution. If the checkpoint cannot be tied back to the observed mutation set, omit it instead of fabricating a version.
- **HAMMER2**: prefer existing snapshot or PFS-version identities. The exporter does not require a forced snapshot-per-operation policy; it simply projects the snapshot/PFS identity you already observed.
- **FFS + WAPBL**: snapshots are the useful stable baseline. WAPBL detail may be carried in `details`, but WAPBL alone is not enough to fabricate `datasetVersion` when no snapshot identity exists.

## Minimal process / jail / run binding

`run.binding` is the smallest supported attribution hook. It is intentionally just a bag of already-observed facts (for example executor, jail name, PID, or other process-tree identifiers) that explain **which** BOP run observed the input/output mutation set. The binding travels in `run.facets.smolfireBopRun.binding`; it is not a second source of truth.

## Determinism

The exporter sorts multiple records by `event_time`, job namespace/name, run ID, and event type before writing JSON. Given the same input records, it will produce byte-stable pretty JSON and structurally identical compact JSON.
