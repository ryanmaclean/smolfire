# BOP filesystem-native state matrix

Issue: #63

## Decision

Carry forward **NetBSD FFS + WAPBL + persistent `fss(4)` snapshots** for the
first smolfire/sibling NetBSD experiments.

Keep **HAMMER1** as the semantic reference model for what an ideal
filesystem-native state store looks like, and keep **HAMMER2** as the best
cross-BSD follow-on once snapshot cadence and port maturity are validated.
Do **not** start with **NetBSD LFS**: its log structure helps write order and
recovery, but it does not preserve old states as a durable history surface
without adding a new retention mechanism.

## Smallest primitive set

The workload in #63 only needs six primitives:

1. `rename(2)` for `pending -> running -> done|failed`
2. `fsync(2)` on the file and parent directory so state transitions survive power loss
3. append-safe file writes for logs and artifacts
4. an immutable or historical view handle for reconstruction
5. mount-time crash recovery
6. stable object identity so run/input/output versions can be derived without a second DB

That yields the following filesystem-native mapping:

| Candidate | History surface | Crash recovery | Identity surface | Verdict |
|---|---|---|---|---|
| DragonFly HAMMER1 | Native transaction history + snapshots | Native crash recovery on mount | transaction IDs + PFS UUIDs | Best semantics, but DragonFly-only |
| HAMMER2 | Explicit snapshots/PFSs | COW + recovery tooling | PFS cluster/fs IDs + snapshot labels | Best cross-BSD follow-on |
| NetBSD LFS | Checkpoints only unless retention is extended | Checkpoint + roll-forward | IFILE entries + segment timestamps | Not enough history by itself |
| NetBSD FFS + WAPBL + persistent `fss` | Snapshot at chosen workflow boundaries | WAPBL journal replay on mount | snapshot time + inode/generation | **Best first NetBSD experiment** |

## Why this recommendation wins

### 1. HAMMER1 is the semantic ideal, but not the deployment fit

DragonFly's `hammer(5)` exposes the strongest history model of the four.
It has monotonic transaction IDs, historical path lookup, snapshots, PFSs,
and fine-grained retained history. If the only question were semantic fit,
HAMMER1 would win.

But smolfire's immediate follow-on work is explicitly about **SMOLFIRE/sibling
NetBSD experiments**. HAMMER1 therefore serves better as the reference model:
"what history-native looks like" rather than the first implementation target.

### 2. HAMMER2 is promising, but still needs scheduled boundaries

`hammer2(8)` gives snapshots, PFSs, checksums, compression, and a concrete
recovery story. It is the strongest candidate for a future cross-BSD state
substrate.

However, its history surface is snapshot-based rather than native per-event
history. For this workload, that means the application still has to decide
*when* to snapshot (`bundle-created`, `running`, `done|failed`). That is good
and tractable, but it is a larger workflow contract than the FFS baseline.

### 3. NetBSD LFS is chronological, not historical

NetBSD LFS already writes in log order and has checkpoint/roll-forward
recovery, so it is appealing at first glance. But the cleaner treats older
segments as garbage-collection input, not as a first-class user-visible
history API.

So LFS does not yet meet the issue goal of deriving prior state and lineage
without a second database or event log. To make it do so, the project would
have to invent a new retention/checkpoint policy or add a snapshot layer,
which defeats the "smallest primitive set" goal.

### 4. FFS + WAPBL + persistent `fss` is the smallest available NetBSD set

NetBSD already has all three pieces:

- FFS for normal file layout and POSIX rename behavior
- WAPBL for fast crash recovery via journal replay on mount
- persistent `fss(4)` snapshots for point-in-time historical views

For the BOP workload, that is enough:

- create the bundle in FFS
- `fsync` bundle contents + parent directory
- rename `pending -> running`
- take a persistent `fss` snapshot at the boundary you want to retain
- append logs / artifacts
- rename `running -> done|failed`
- take the terminal snapshot
- on crash, let WAPBL replay at mount and inspect the latest live tree plus
  retained snapshots

That gives durable state, crash recovery, and reconstructable prior states
without needing a second database. The history is coarser than HAMMER1, but it
is explicit, easy to reason about, and already available in NetBSD.

## Recommendation for the next experiment

1. Use `docs/BOP-FILESYSTEM-STATE-MATRIX.toml` as the machine-readable source of truth.
2. Prototype the BOP workload on **NetBSD FFS + WAPBL + persistent `fss`**.
3. Snapshot at three explicit boundaries only:
   - bundle created
   - first `running` transition
   - terminal `done|failed` transition
4. Record lineage from:
   - snapshot timestamp
   - inode number + generation of bundle/artifact roots
   - stable relative paths inside the bundle
5. Keep HAMMER2 as the next follow-on matrix leg after the FFS baseline is running.

## Source basis

The recommendation is based on upstream source/manual review rather than local
benchmark numbers:

- `DragonFlyBSD/DragonFlyBSD share/man/man5/hammer.5`
- `DragonFlyBSD/DragonFlyBSD sbin/hammer2/hammer2.8`
- `NetBSD/src sys/ufs/lfs/README`
- `NetBSD/src share/man/man4/wapbl.4`
- `NetBSD/src share/man/man4/fss.4`

The companion TOML intentionally leaves latency/RAM/amplification numbers out,
because this issue asks us not to assume an answer before testing. Those
measurements should be filled in by the future workload runner, not invented in
documentation.
