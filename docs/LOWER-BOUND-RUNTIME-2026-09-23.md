# smolFire lower-bound runtime and lineage architecture — 2026-09-23

> Canonical Datadog notebook payload: `docs/datadog/smolfire-lower-bound-runtime-notebook.json`
>
> Publish/update with: `python3 bin/publish-datadog-notebook.py`
>
> Tracking issue: [smolfire#76](https://github.com/ryanmaclean/smolfire/issues/76)
>
> Datadog notebook URL: _pending publish_
>
> Datadog notebook ID: _pending publish_

## Goal

Find the **smallest and fastest permissively licensed execution substrate** that can run agent work while making state transition, history, provenance, and lineage native enough that the same logic is not reimplemented in a queue, database, trace store, VCS, and filesystem.

Hard constraints:

- Prefer BSD/MIT/Apache project code; no GPL/LGPL/AGPL dependencies in the project.
- Go lower before adding abstraction.
- Storage and RAM are first-class constraints.
- BOP/filesystem state is canonical; OpenLineage is an export/projection, not another state store.
- A useful design may go below a conventional OS, including rump/unikernel, FPGA, SmartNIC/DPU, or storage-controller logic.

## Existing systems

### smolFire / FreeBSD

Current one-ELF microVM baseline:

- direct PVH boot
- no bootloader
- no disk for root
- no pkgbase
- embedded MFS/UFS root
- static FreeBSD `/rescue` userland
- VirtIO MMIO networking
- Firecracker + QEMU microvm gates
- ~37 MiB ELF
- ~476 ms median release boot in the measured hosted-runner baseline
- TSLOG already attributes the boot path

Measured dominant costs:

1. TSC/LAPIC calibration (~259 ms)
2. kernel console output (~126 ms)
3. phantom COM2-4 UART probes (~31 ms)
4. init + rc (~33 ms)

This remains the FreeBSD control/reference implementation.

### NetBSD 11 MICROVM

Sibling complete-OS candidate.

Reasons to test:

- dedicated MICROVM/PVH configuration
- tiny complete BSD
- native FFS/WAPBL/fss snapshots
- native LFS
- rump versions of NetBSD filesystem components

### NetBSD rump / rumprun

Potential software lower bound before hardware.

Target shape:

```
PVH / Solo5 / VMM
  ↓
NetBSD rump
  ├── VirtIO block
  ├── VirtIO net (optional)
  ├── LFS or FFS
  └── tiny BOP worker
```

No general-purpose shell/init/package layer unless required.

## Storage candidates

### HAMMER1

Semantic reference for native historical storage.

Interesting primitives:

- create/delete transaction IDs
- historical views
- fine-grained retained history
- mirroring/change stream

Question: can a filesystem transaction ID directly become the lineage/version identity for BOP artifacts?

### HAMMER2

Modern portability reference.

Interesting because:

- native DragonFly filesystem
- FreeBSD/NetBSD/OpenBSD ports exist
- writable snapshots/PFSs
- checksums/compression
- modern Rust userspace ecosystem exists

Caveat: snapshots/PFS history is not identical to HAMMER1's automatic fine-grained history.

### NetBSD LFS

Chronological/log-structured candidate.

Research hypothesis:

> Old log/checkpoint state may be treated as retained history rather than immediately becoming cleaner garbage.

Questions:

- Can checkpoints become stable dataset/version IDs?
- Can cleaner retention rules preserve only the history required by active lineage?
- What is the minimum metadata required to reconstruct BOP state/history?

### NetBSD FFS

Correctness/control baseline.

Use:

- WAPBL for crash recovery
- fss(4) persistent snapshots
- mature rename/fsync semantics

Less natural for automatic history, but important as a baseline.

## Common filesystem workload

All candidates should run the same semantic test, not only fio:

```
CREATE card
pending -> running
append logs
write artifact
running -> done/failed
fsync
crash at random point
recover
query/reconstruct prior state
export lineage
```

Measure:

- image/kernel bytes
- RSS
- boot-to-ready
- metadata bytes per card/run
- write amplification
- rename latency
- fsync latency
- crash recovery time
- retained history per GiB
- pruning/cleaning cost
- lineage reconstruction cost

## BOP -> filesystem -> OpenLineage

BOP's filesystem state remains authoritative.

Proposed projection:

| Native primitive | OpenLineage |
|---|---|
| BOP card/template | Job |
| execution/lease UUID | Run |
| parent run | ParentRunFacet |
| dependency | JobDependenciesRunFacet |
| pending -> running | START |
| running -> done | COMPLETE |
| running -> failed | FAIL |
| filesystem object/path | Dataset |
| HAMMER1 TID | DatasetVersion |
| LFS checkpoint | DatasetVersion |
| HAMMER2 snapshot/PFS identity | DatasetVersion |
| FFS snapshot identity | DatasetVersion |

OpenLineage JSON should be generated only as an export/view.

The desired canonical binding is:

```
BOP run UUID
  ↕
process / jail / VM execution identity
  ↕
filesystem transaction/checkpoint/version
```

## Jev / System One

Jev is not a coding-agent replacement. It is a candidate **fast decision plane**.

Candidate BOP sites:

- provider selection / rotation
- retry / fail / escalate
- card routing / priority
- capability match
- human-review gate
- destructive-action/tool gate
- context/tool relevance
- choose deterministic path vs expensive LLM

Requirements:

- deterministic safety/filesystem invariants remain authoritative
- Jev/System One state is advisory or confidence-gated
- decisions can be logged with confidence but are not canonical state
- compare against deterministic rules, a local classifier/heuristic, and any existing LLM-based decision
- fail closed or fall back deterministically when unavailable

## Hardware lower bound

Do not begin by putting a soft CPU and BSD on an FPGA.

Instead investigate moving the duplicated ordering/provenance primitive into hardware:

```
CPU emits mutation descriptor
    ↓
FPGA / SmartNIC / DPU / storage controller
    ├── allocate sequence/TID
    ├── timestamp
    ├── hash/checksum
    ├── route
    └── DMA / append to NVMe
    ↓
completion with transaction ID
```

Minimal descriptor concept:

```c
struct mutation {
    uint64_t object;
    uint64_t parent;
    uint64_t run;
    uint64_t op;
    uint64_t address;
    uint32_t length;
};
```

Research questions:

- Can one hardware-issued TID order both filesystem state and lineage?
- How does this interact with HAMMER/LFS commit ordering?
- Can checksum/hash/timestamp happen without extra copies?
- What persistence guarantees require NVMe FUA/flush?
- What remains in software for crash recovery?
- Where is the measured break-even versus a CPU-only lock-free ring?

## Root of trust

smolFire already contains measured/attestation work.

Long-term provenance chain:

```
measured boot
  ↓
kernel/ELF measurement
  ↓
filesystem UUID/root
  ↓
BOP run UUID
  ↓
filesystem TID/checkpoint
  ↓
artifact hash
```

Avoid independently signing/storing equivalent representations at each layer.

## Open work

smolFire:

- [smolfire#60](https://github.com/ryanmaclean/smolfire/issues/60) Make one-ELF SMOLFIRE microVM the primary path
- [smolfire#61](https://github.com/ryanmaclean/smolfire/issues/61) Shrink userland below /rescue
- [smolfire#62](https://github.com/ryanmaclean/smolfire/issues/62) FreeBSD 16-CURRENT compatibility lane
- [smolfire#63](https://github.com/ryanmaclean/smolfire/issues/63) HAMMER1/HAMMER2/NetBSD LFS/FFS state matrix
- [smolfire#64](https://github.com/ryanmaclean/smolfire/issues/64) NetBSD 11 MICROVM sibling
- [smolfire#65](https://github.com/ryanmaclean/smolfire/issues/65) BOP/filesystem -> OpenLineage projection
- [smolfire#72](https://github.com/ryanmaclean/smolfire/issues/72) rump/rumprun lower-bound prototype
- [smolfire#73](https://github.com/ryanmaclean/smolfire/issues/73) FPGA/SmartNIC/NVMe transaction-sequencer research
- [smolfire#76](https://github.com/ryanmaclean/smolfire/issues/76) Publish and keep the Datadog Notebook in sync with this research

BOP:

- [bop#5](https://github.com/ryanmaclean/bop/issues/5) Evaluate Jev/System One as BOP's fast decision plane

## Near-term execution order

1. Preserve measured FreeBSD one-ELF baseline.
2. Add a separate writable VirtIO state disk to the microVM.
3. Run FFS baseline workload.
4. Run HAMMER2 on FreeBSD where viable.
5. Bring up NetBSD 11 MICROVM sibling with FFS and LFS.
6. Run the same workload under rump LFS/FFS.
7. Compare HAMMER1 semantics against the measured matrix.
8. Implement deterministic OpenLineage export from BOP + filesystem identities.
9. Evaluate Jev/System One only at high-frequency bounded decision sites.
10. Prototype the transaction sequencer in software rings before FPGA hardware.

## Decision rule

Prefer the lowest layer that can own a primitive once.

If ordering/history belongs in storage, do not recreate it in BOP.
If run identity belongs in BOP, do not recreate it in the filesystem.
If OpenLineage can be derived, do not persist another canonical lineage database.
If hardware can provide ordering/hash/timestamp more cheaply, measure it before adding another software service.
