<!-- SPDX-License-Identifier: Apache-2.0 -->
# SuperStation One software fault injection for durable-tid (#88) — 2026-09-25

Issue #88: fault and replay testing of the durable-commit path. This is the
**software half**: the #86 model B writer (`hps/durable_commit_bench.c`,
baseline in `docs/SUPERSTATION-BASELINE-2026-09-24.md`, PR #108) is driven by a
fault-injection controller on superstation1. There is no FPGA DUT yet (#87), so
every trace line carries `"fpga": null`. The trace format already has the
fields #88 asks for (exact input, fault point, oracle result, recovered state,
divergence), so the FPGA side can be added as a second column later.

**Result:** 1,500 injected crash iterations on exFAT/microSD (1,432 `SIGKILL`s
plus 68 errno faults) and 40 real ENOSPC faults: **0 violations**. Every
acknowledged record was recovered and CRC-valid. Torn tails (510) were always
detected, excluded and repaired. A deliberately broken writer is always
caught. **One finding:** with FAT on a loop device whose backing store fills,
this kernel acknowledged a record it had not stored. 25 of 30 runs lost the last
acked record (see "Finding").

## Device and conditions

| Item | Value |
|---|---|
| Board | superstation1 (SuperStation One, Cyclone V HPS, 2× Cortex-A9 @ 800 MHz, 492 MiB) |
| Kernel | **`6.18.38-MiSTer #2 SMP armv7l`**. Update All replaced MiSTer Linux at 06:10Z on 2026-09-25; the #86 baseline ran on 5.15.1. Timing is not compared across the two kernels |
| Storage | `/media/fat` exFAT on 64 GB microSD, `rw,sync,dirsync,noatime`, `queue/write_cache = write through`; rootfs ext4 loop, read-only |
| Work dir | `/media/fat/smolfire-bench/f88` only; transient mounts under `f88/mnt` and `f88/backing`, all removed afterwards (verified: no leftover mounts or loop devices) |
| Build | static armv7 on ubrpi502, `arm-linux-gnueabihf-gcc 13.3 -O2 -march=armv7-a -mtune=cortex-a9 -mfpu=neon -static`; binary hashes in `raw/env.txt` |
| Concurrency | no `update_all`/`downloader` running (checked at preflight); MiSTer menu and Datadog IoT agent left running and untouched |
| Window | 2026-09-25 07:31–07:39Z campaign, 07:39–07:41Z manual repro |

## Method

`hps/durable_fault_harness.c` (controller) + fault hooks in
`hps/durable_commit_bench.c` (all off by default; with no hook flags the
timed loop is the #86 loop). `bin/ss1-fault-campaign.nu` builds, preflights,
pushes, runs and fetches. It uses one SSH ControlMaster and never retries a
failed login.

Per iteration:
1. Spawn the writer on a log that persists across iterations (rotated every
   50–100 iterations, so each restart recovers hundreds of records). Acks go to
   a pipe that only the controller reads. An ack is written after
   append → `fdatasync` → publish; it is the "acknowledged as durable" signal.
   The writer stores `{phase, chunk, seq}` in a shared memfd at every boundary,
   using plain stores, which are async-signal-safe.
2. Inject one fault:
   - **stop** (≈60%): the writer `raise(SIGSTOP)`s at a chosen boundary of a
     chosen op: `construct`, `construct-mid` (before CRC), `append` (before
     `pwrite`), `append-mid` (between `pwrite` chunks of a record split into
     4 or 8 writes, so the record is torn), `durable` (after `pwrite`, before
     `fdatasync`), `publish`, `ack`, or `done`. The controller then sends
     `SIGKILL`: an exact `kill -9` at a phase boundary.
   - **external** (≈35%): the controller sends `SIGKILL` after a uniform random
     0–40 ms (64 B records) or 0–60 ms (4 KiB). This lands wherever the process
     is, mostly inside `pwrite`.
   - **errno** (≈5%): the writer is told its append (after writing half the
     record) or its `fdatasync` returned EIO/ENOSPC.
3. Scan the log in the controller with `O_DIRECT` (an independent CRC/seq
   oracle), run recovery as a new process (`--recover-only --repair`,
   timed), scan again, then check the invariants.

Invariants (any failure is a violation and is counted):
`acked_lost` (an acked seq is not recovered), `phantom` (more than one un-acked
seq recovered), `oracle_mismatch` (writer recovery ≠ independent scan),
`torn_exposed` (after repair the file is not exactly `recovered` valid
records), `resurrection` (a valid record after an invalid one),
`epoch_regress`, `ack_gap`, `not_killed`/`unexpected_exit`,
`recovery_failed`.

**Fill** (real resource errors): a fresh small filesystem each iteration. The
writer appends until the kernel refuses; then remount (loop cases), recover and
check.
- `tmpfs-enospc`: tmpfs `size=256k` (30 iterations).
- `vfat-enospc`: 1 MiB FAT12 image *file on the SD* (`f88/enospc.img`), loop,
  `sync,dirsync` (10 iterations).
- `vfat-eio`: sparse 1 MiB FAT12 image on a 192 KiB tmpfs, loop,
  `sync,dirsync`. When the tmpfs is full, the loop device fails the write
  (30 iterations).

FAT images come from the harness's own formatter (`mkfat`), so no GPL mkfs is
needed. `fill` refuses any mount or image path outside `--root`.

**Oracle self-test:** the same crash campaign against two deliberately
broken writers. `--mutant ack-early` acks before the append, so the harness
must report `acked_lost`. `--mutant no-repair` makes repair a no-op, so the
harness must report `torn_exposed`.

## Results

### Crash campaign (exFAT on microSD)

| | 64 B records, split 4 | 4 KiB records, split 8 |
|---|---|---|
| iterations (faults) | 1200 | 300 |
| `SIGKILL` at a phase boundary (stop) | 727 | 176 |
| `SIGKILL` at a random time (external) | 418 | 111 |
| errno faults (EIO/ENOSPC, simulated) | 55 | 13 |
| acked records across all runs | 6190 | 723 |
| **violations** | **0** | **0** |
| torn/partial tails detected and repaired | 407 | 103 |
| recovered = last_acked + 1 (in-flight op was durable, allowed) | 393 | 77 |
| scans read with `O_DIRECT` | 1199/1200 (first scan: no log yet) | 300/300 |
| recovery scan p50 / p99 / max | 2.0 / 6.1 / 11.7 ms | 16.6 / 39.4 / 43.6 ms |
| recovery restart (exec + scan + repair) p50 / p99 / max | 5.5 / 26.9 / 102.9 ms | 20.2 / 46.6 / 47.7 ms |

Where the stop kills landed, and what recovery found (64 B / 4 KiB):

| stop boundary | kills | recovered = acked+1 |
|---|---|---|
| construct | 89 / 20 | 0 / 0 |
| construct-mid (before CRC) | 91 / 17 | 0 / 0 |
| append (before `pwrite`) | 83 / 22 | 0 / 0 |
| append-mid (torn record) | 91 / 25 | 0 / 0 |
| durable (after `pwrite`, before `fdatasync`) | 101 / 23 | **101 / 23** |
| publish (after `fdatasync`) | 104 / 18 | 104 / 18 |
| ack (after publish, before ack) | 78 / 24 | 78 / 24 |
| done (after ack) | 90 / 27 | 0 / 0 |

Every kill at or after `durable` left the in-flight record durable. On this
`sync` mount the commit point is `pwrite(2)`, not `fdatasync(2)`, which confirms
the #86 semantics under crashes. Kills before the `pwrite` finished never left a
valid record.

The random external kills (64 B) landed at: append-mid 268, append 104
(372/418 = 89% inside `pwrite`, i.e. mid-write), and during writer startup or
recovery 46. The recovery process itself is never killed.

### Resource faults (real kernel errors)

| scenario | faults | errno seen by writer | acked records | violations | torn tails repaired | `fdatasync` retry after the error |
|---|---|---|---|---|---|---|
| tmpfs `size=256k` | 30 | ENOSPC ×30 | 36782 | 0 | 22 | returned 0 ×30 |
| FAT image on SD, loop, `sync` | 10 | ENOSPC ×10 | 4438 | 0 | 4 | returned 0 ×10 |
| FAT image on full tmpfs, loop, `sync` | 30 | EIO ×12, ENOSPC ×18 | 15782 | **25 `acked_lost`** | 0 (30 bad full-length records excluded) | returned 0 ×30 |

### Oracle self-test (broken writers, exFAT)

| mutant | faults | expected | reported |
|---|---|---|---|
| `ack-early` (ack before the append) | 100 | `acked_lost` | 41 `acked_lost` |
| `no-repair` (repair is a no-op) | 100 | `torn_exposed` | 33 `torn_exposed` (= 33 torn tails) |

The oracle is not vacuous: both classes of bug are reported whenever the
injected fault exposes them.

## Finding: an acknowledged record lost under a lower-layer write error (vfat on loop, 6.18.38)

In `vfat-eio`, every run with 1000- or 3000-byte records (25/25) lost the
**last acknowledged** record. The 64-byte runs (5/5) were clean. Manual
reproduction (`raw/vfat-eio-acked-loss-repro.txt`):

- `--ops 58` with 3000-byte records: the writer exits 0. `pwrite` on the
  `sync` mount and `fdatasync` returned success for all 58 records, and no
  error was ever returned. The kernel logged `Buffer I/O error on dev loop2 …
  lost async page write`. After a clean umount/remount, recovery finds 57 records:
  seq 58 is zeros from file byte 173056 (sector 338) on.
- The page cache showed seq 58 intact before the remount. The O_DIRECT scan did
  not (the trace's `cached_prefix` = 57), so the data never reached the device.
- The same harness, image and parameters on ubrpi502 (Ubuntu
  `6.8.0-1051-raspi`) returned EIO to the writer and lost nothing.
- The error the writer sees also differs: 6.18.38 surfaces the backing tmpfs's
  ENOSPC as ENOSPC for some writes. 6.8 turned every loop failure into EIO.

What this means for durable-tid: an application that follows the protocol
(ack only after `fdatasync` returns 0) can still lose an acked record if the
kernel drops a lower-layer write error. The failing layer here is artificial
(loop on a full tmpfs), so this is **not** evidence that the exFAT-on-SD path
loses data. But nothing in the writer can detect it. Only a read-back of what
the device holds (the harness's `O_DIRECT` scan) catches it. The trace is
kept as a regression fixture (`raw/fill-vfat-eio.jsonl`) per #88. Not
root-caused in the kernel. Candidates are the vfat `sync` path and the 6.18
loop error propagation, and it needs a separate kernel-side investigation.

## What software injection can and cannot prove

**What it proves (on this board, kernel and media, for the model B writer):**
- The *application protocol* is crash-consistent against process death at every phase boundary and at random points, mid-`pwrite` included. A seq that reached the ack channel was always recovered. At most one un-acked seq (the in-flight op) became durable. Torn and partial records were always detected (CRC, length, seq) and excluded. After `--repair`, no bytes remained past the recovery point, and no valid record ever appeared after an invalid one.
- The writer's recovery agrees with an independent oracle (a second CRC scan in the controller, reading with `O_DIRECT`) on every fault.
- Under real `ENOSPC` (tmpfs, and FAT on a loop image on the SD) and real `EIO` (FAT on a loop device whose backing tmpfs is full), the writer never acknowledges the failed seq, and recovery returns exactly the acknowledged prefix.
- The harness can fail: two deliberately broken writers (`--mutant ack-early`, `--mutant no-repair`) are reported as `acked_lost` and `torn_exposed`.

**What it cannot prove:**
- **Power loss.** `kill -9` kills the process, not the kernel. The page cache, the block layer queue and the card controller all keep running, so every write that `pwrite(2)` accepted still reaches the card. A crash here can only lose work the *process* had not yet handed to the kernel. A power cut can also lose work the kernel or the card had accepted.
- **SD-internal buffering.** The mmc host reports `write_cache = write through`, so Linux never sends a cache flush. "Durable" therefore means "the card acknowledged the write command". Whether the card's controller had programmed the NAND at that point (or holds the data in SRAM, or a pSLC cache that it later folds, or is remapping the FTL) is invisible to the host. `O_DIRECT` read-back proves only that the card *returns* the data, and it can serve that from the same volatile buffer. Only a physical power-cut test can show that acknowledged writes survive power loss: cut power at random points after acks, then scan. Physical power-cut testing was out of scope for #88 and was not done.
- **Torn sectors on the media.** The torn records observed here are made by the harness (records split across several `pwrite` chunks, killed between chunks) or by a short write at ENOSPC. They are not torn 512-byte sectors or pages. Whether this card can tear a sector or page on power loss, or corrupt a neighbouring block during an erase, is again a power-cut question.
- **exFAT metadata atomicity under power loss.** With `sync,dirsync`, each append updates the file's data, size and allocation bitmap in separate device writes. A process kill cannot interleave those writes; a power cut can (for example, size extended but data not yet written, which reads back as zeros or stale data). The CRC check would reject such a record, but losing an *acked* record that way cannot be ruled out by software injection.
- **fdatasync semantics.** On the `sync` mount, `pwrite` is the commit point: stops at the `durable` boundary (after `pwrite`, before `fdatasync`) always recovered the record. After every real ENOSPC/EIO (70/70, 12 of them EIO), a second `fdatasync` returned 0. Linux reports a writeback error once and then clears it (fsyncgate), and the finding below shows it can also drop the error entirely. So a writer must treat the first error as final and never "retry until success". This writer exits without acking, and that is what the harness checks.

## #88 fault list: covered here vs later

| #88 fault | status |
|---|---|
| reset | covered in software as process `SIGKILL` at every boundary + random; board/power reset not done (out of scope) |
| lost acknowledgement | covered: kills at `publish`/`ack` (acked-but-not-received), 182 cases at 64 B + 42 at 4 KiB |
| truncated/corrupted durable record | covered: torn records via split writes (510), short writes at ENOSPC, zero-filled records at EIO |
| stale epoch | partially covered: the writer bumps its epoch on every restart, and `epoch_regress` is checked on every recovery (0 violations); stale-epoch *descriptors* need the FPGA DUT (#87) |
| duplicate submission, delayed ack, malformed descriptor, replay, queue pressure | not covered: these need the descriptor interface of the FPGA DUT (#87/#89). The writer has no descriptor input |
| FPGA result / convergence | `"fpga": null` in every trace line until #87 exists |

## Reproduce

```
nu bin/ss1-fault-campaign.nu build        # static armv7 on ubrpi502
nu bin/ss1-fault-campaign.nu preflight    # waits for update_all/downloader
nu bin/ss1-fault-campaign.nu push
nu bin/ss1-fault-campaign.nu run
nu bin/ss1-fault-campaign.nu fetch --date 2026-09-25
```

Every run is deterministic in its fault schedule: the seed is in each `.jsonl`
line and in the campaign (880001–880007).

## Files

`bench/superstation1/2026-09-25/fault-injection/`:
- `raw/*.jsonl` has one JSON object per injected fault (`i, kind, target,
  target_op, target_chunk, delay_us, recsize, split, exit/signal,
  phase_at_fault, seq_at_fault, fault_errno, acks, last_acked,
  cached_prefix, pre{…}, recovered, recovery_ns, restart_wall_ns, post{…},
  fpga, violations, ok`).
- `raw/*.metrics` has the `SMOLFIRE_METRIC` summaries; `raw/env.txt` and
  `raw/vfat-eio-acked-loss-repro.txt` hold the environment capture and the
  manual repro.
- `records/*.json` holds one `ryanlab.bench.v1` record per scenario (via
  `bin/bench-record.nu`, `commit` = the harness commit).
- `results-table.md` is the table above in short form.

## Related

#88, #86 / PR #108, #87 (FPGA DUT), #89 (model B), #79 / #102 (bench.v1),
`docs/DURABLE-TID-SEQ-VS-ALLOC.md`, `docs/SUPERSTATION-BASELINE-2026-09-24.md`.
