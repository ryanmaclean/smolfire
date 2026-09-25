<!-- SPDX-License-Identifier: Apache-2.0 -->
# SuperStation One CPU-only durable-commit baseline (#86) — 2026-09-24

Issue #86: establish the CPU baseline before any FPGA acceleration. Every later
FPGA feature must beat or simplify these numbers to survive.

Owner waiver (recorded on #86, 2026-09-24): the "no Linux target" rule is
waived for SuperStation One; the baseline runs on its stock MiSTer Linux.
The other rules held: no FPGA acceleration, no ring/queue, one outstanding
operation, no RISC-V.

## Device

| Item | Value |
|---|---|
| Board | SuperStation One (SS1-A, software oracle in `docs/SUPERSTATION-PRE-ASIC-PLAN.md`), fleet name `superstation1` |
| SoC | Cyclone V SX (5CSXFC6D6F31I7N), HPS = 2x ARM Cortex-A9, `Hardware: Altera SOCFPGA` |
| Clock | 800 MHz (`cpufreq` governor `performance`) |
| Kernel | `Linux 5.15.1-MiSTer #2 SMP Thu Jul 16 2026 armv7l`, Buildroot, glibc 2.31 |
| RAM | 492 MiB, no swap |
| Rootfs | ext4 loop image `/media/fat/linux/linux.img`, mounted read-only |
| Bench storage | `/media/fat/smolfire-bench` on `/dev/mmcblk0p1`, **exFAT**, mount options `rw,sync,dirsync,noatime,nodiratime,fmask=0022,dmask=0022,iocharset=utf8,errors=remount-ro` |
| Media | 64 GB microSD (manfid 0x0000fe, oemid 0x3432, dated 05/2026); block layer reports `queue/write_cache = write through`, scheduler mq-deadline |
| CPU floor | `/tmp` tmpfs, same binary |

## Storage and durability semantics (exact)

- **`sync,dirsync` mount:** on Linux, `sync` makes every `write(2)` behave as
  `O_SYNC`: the call does not return until the data and the metadata it
  dirtied have been submitted to and completed by the block device. The
  ~1.2 ms `append` phase below *is* the media commit. `fdatasync(2)` after it
  finds nothing dirty and costs ~6-8 µs (about 6 µs above the ~1.7 µs
  clock-read floor measured with `--no-sync`).
- **SD write-through:** the mmc host reports no volatile write cache to the
  block layer, so no FLUSH/`CACHE_FLUSH` command is issued; "durable" means
  "the card acknowledged the write". Card-internal buffering is invisible to
  the host and cannot be measured here; proving it needs power-cut testing
  (#88), which this baseline did not do.
- **exFAT write granularity:** each 64-byte record write produced one 4 KiB
  block write (`/proc/self/io write_bytes` = 4096-4103 B/op). Growing the
  file (`append`) vs. writing in place into a preallocated file (`prealloc`)
  made no difference at p50 and the allocation path is not the tail driver.
- **`fdatasync` vs `fsync`:** `fdatasync` returned 0 on exFAT (no EINVAL
  fallback taken).
- **No HW cycle counter:** `perf_event_open(PERF_COUNT_HW_CPU_CYCLES)` failed
  as root (`perf_event_paranoid=2`; the MiSTer kernel exposes no PMU). CPU
  cost is reported as `CLOCK_PROCESS_CPUTIME_ID` ns; at 800 MHz, cycles ≈
  0.8 × ns (derived, not measured).

## Method

`hps/durable_commit_bench.c` (this PR), model B from
`docs/DURABLE-TID-SEQ-VS-ALLOC.md`: the caller supplies `seq = durable_seq+1`,
exactly one operation outstanding, no queue. Per operation, timed with
`CLOCK_MONOTONIC`:

1. **construct** — 24-byte header (magic, epoch, seq, len, crc) + payload, CRC-32/IEEE over the record;
2. **append** — `pwrite(2)` of the record at `(seq-1)*recsize`;
3. **durable** — `fdatasync(2)`;
4. **publish** — store-release of `visible_seq` into a shared word (stand-in for the completion register);
5. **total** — 1-4.

**Recovery:** open the log, scan records, verify CRC and `seq == prev+1`;
`durable_seq` = last contiguous good record. Measured in-process
(`recovery_ns`) and as process restart wall time (`restart_wall_ns`, fork to exit
of `--recover-only`) after a clean stop.

Iterations: 10 000 ops per 64-byte run, 5 000 per 4 KiB run. Build: static
`arm-linux-gnueabihf-gcc 13.3 -O2 -march=armv7-a -mtune=cortex-a9 -mfpu=neon`
on ubrpi502 (Ubuntu 24.04 aarch64) because the board has no compiler and
492 MiB RAM; static because the device glibc is 2.31.

## Results (µs unless noted; one outstanding request)

| metric           | exfat-append-64 | exfat-prealloc-64 | exfat-append-4096 | exfat-append-64-nosync | tmpfs-append-64 |
| ---------------- | --------------- | ----------------- | ----------------- | ---------------------- | --------------- |
| ops              | 10000           | 10000             | 5000              | 10000                  | 10000           |
| rec_B            | 64              | 64                | 4096              | 64                     | 64              |
| construct_p50_us | 4.6             | 4.6               | 265.6             | 4.6                    | 4.6             |
| append_p50_us    | 1226.7          | 1163.1            | 1441.8            | 1268.7                 | 4.7             |
| append_p99_us    | 2807.8          | 7860.7            | 32700.0           | 8134.5                 | 20.4            |
| durable_p50_us   | 7.5             | 8.3               | 7.9               | 1.7                    | 1.8             |
| durable_p99_us   | 33.8            | 35.1              | 33.7              | 14.8                   | 3.3             |
| publish_p50_us   | 1.3             | 1.2               | 1.5               | 1.2                    | 1.1             |
| total_p50_us     | 1242.9          | 1180.5            | 1727.1            | 1277.7                 | 12.1            |
| total_p95_us     | 1502.9          | 1475.9            | 3969.6            | 3935.3                 | 18.3            |
| total_p99_us     | 2824.1          | 7878.8            | 32962.3           | 8142.7                 | 35.6            |
| total_max_us     | 64666.8         | 64618.9           | 74900.4           | 32071.1                | 2276.4          |
| cpu_us_per_op    | 161.2           | 126.4             | 474.3             | 154.5                  | 14.4            |
| ops_per_s        | 678             | 631               | 368               | 613                    | 66181           |
| block_B_per_op   | 4101            | 4096              | 4102              | 4100                   | 0               |
| payload_B        | 640000          | 640000            | 20480000          | 640000                 | 640000          |
| block_B          | 41005056        | 40960000          | 20508672          | 41000960               | 0               |
| maxrss_kB        | 1692            | 1700              | 1660              | 1700                   | 1640            |
| recover_scan_ms  | 61.6            | 61.7              | 1121.2            | 61.6                   | 62.9            |
| restart_ms       | 77.0            | 77.1              | 1137.4            | 76.9                   | 78.1            |
| recovered_seq    | 10000           | 10000             | 5000              | 10000                  | 10000           |
| bad_tail         | 0               | 0                 | 0                 | 0                      | 0               |

Notes:
- `exfat-append-64-nosync` skips `fdatasync`; its `durable` column is the
  clock-read floor. The `append` cost is unchanged because the `sync` mount
  already makes `write(2)` synchronous.
- `tmpfs-append-64` is the CPU floor: ~12 µs/op total, ~14 µs CPU/op,
  66 k ops/s with one outstanding op. Of that, CRC-32 (bit-serial) is ~4.6 µs
  for 64 bytes and ~267 µs for 4 KiB.
- The 4 KiB recovery scan (20 MB) is CPU-bound in the bit-serial CRC:
  ~1.12 s ≈ 55 ns/byte at 800 MHz. Table-driven or NEON CRC would cut this
  ~10x; it was left bit-serial to match the independent oracle in
  `hps/harness.c`.
- Max latencies of ~64-75 ms appear once or twice per 10 000 ops on exFAT
  (card-internal housekeeping); p99 stays 2.8-8 ms for 64-byte records.
- RSS: ~1.7 MB max (static binary, 10 000 × 5 timestamps).

## Records

`bench/superstation1/2026-09-24/records/*.json` — one `ryanlab.bench.v1`
record per run and per recovery run, emitted with `bin/bench-record.nu`
(`--runtime superstation1-mister-linux-armv7 --filesystem exfat|tmpfs`). Raw
`SMOLFIRE_METRIC` logs and the environment capture are under
`bench/superstation1/2026-09-24/raw/`. The `exfat-append-4096` (no `-r2`)
recovery log is invalid: the scan was run with 64-byte framing by mistake;
`exfat-append-4096-r2` is the corrected run and is the one in the table.

## What the FPGA has to beat

For a 64-byte record on this board and media, the CPU path costs ~1.24 ms
p50 / 2.8 ms p99 end to end, of which ~1.23 ms is the SD write itself and
~15 µs is everything the FPGA could plausibly replace (construct + CRC +
publish + fdatasync bookkeeping), at ~160 µs CPU per op and ~680 ops/s with
one outstanding request. Recovery is 6 µs per 64-byte record (CRC-bound).
An FPGA commit path that still ends in this SD card cannot move the p50; it
can only remove the ~160 µs CPU/op and tighten the tail. Beating the p50
requires different media (SuperDock M.2 / NVMe FUA), which is #73 territory.

## Related

#86, #79 (bench.v1), #102 (`bin/bench-record.nu`), #88 (fault injection —
not done here), #73, #78, #87/#89 (model B), `docs/MISTER-DUT-PLAN.md`.
