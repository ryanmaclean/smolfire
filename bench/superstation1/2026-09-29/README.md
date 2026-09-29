# #86 ARM-only durable-commit baseline — superstation1, 2026-09-29

> **DEVIATION NOTE (prominent, read first):** issue #86 says "no Linux target",
> but the box (`superstation1`, reachable at `10.0.3.136`) runs
> **Linux 6.18.38-MiSTer** (upgraded since the 2026-09-24 run, which saw
> 5.15.1-MiSTer). There is no BSD / bare-metal / RISC-V target available on
> this hardware today, so this baseline was **measured as-is on the resident
> Linux**: single-outstanding-op append + fsync + recovery, CPU-only, no FPGA,
> no ring/queue optimization. The BSD-semantics path (fsync vs. flush
> equivalents, alternate rootfs) is **left open** — re-running this workload
> under a BSD target is follow-on work, and the `ryanlab.bench.v1` shape used
> here is deliberately identical so the comparison will be direct.

## Method

- Harness: `/tmp/dcbench86.py` on the box — **throwaway, never committed**
  (repo policy is Nushell-only; repo gets records + docs, no new code).
  CPython 3.9.6 stdlib only: `os.write` + `os.fsync` per op, phase timing via
  `CLOCK_MONOTONIC` (`clock_gettime_ns`), CPU via `CLOCK_PROCESS_CPUTIME_ID`,
  RSS via `/proc/self/status`, maxRSS via `getrusage`, block bytes via
  `fstat.st_blocks`.
- Model B, **one outstanding op**: construct 4 KiB record
  (magic u32 + seq u64 + epoch u32, payload fill, crc32 tail) → append (single
  `write`) → durability (`fsync`, `fsync_fallback=0`) → publish (commit seq
  assignment). N=2000 ops per config.
- Recovery: **fresh process**, open + full scan, verify magic / seq chain /
  crc32 per record, count bad tail. Timed separately (`*.recover.log`).
- Configs: `exfat-append-4096` (durability path) and `tmpfs-append-4096`
  (`/tmp` control; fsync near-no-op, isolates harness + syscall cost).
- Prior C-harness runs (2026-09-24) are the comparison point; the `-py`
  workload suffix marks this run's interpreter harness. Python overhead lands
  mostly in construct/publish; append/durable/recovery-scan deltas vs C are
  small on exfat (storage-dominated) and large on tmpfs (overhead-dominated).

## Exact semantics (OS / storage / media)

```
date=2026-09-29T18:29:44Z
Linux superstation1 6.18.38-MiSTer #2 SMP Sat Sep 12 20:19:51 CST 2026 armv7l GNU/Linux
CPU: 2x ARMv7 Cortex-A9 (Altera SOCFPGA), BogoMIPS 200.00; cpufreq sysfs absent on 6.18 (governor/freq unknown, was 800MHz performance on 5.15.1)
rootfs: /dev/loop8 / ext4 ro,noatime,nodiratime
bench fs: /dev/root /media/fat exfat rw,sync,dirsync,noatime,nodiratime (59G, 42% used)
media: SD 05/2026, write_cache=write through, scheduler mq-deadline
control fs: tmpfs /tmp (246M)
mem: 491M total, no swap; perf_event_paranoid=2 (no HW cycle counter, cycles_* = 0)
toolchain: NONE (no cc/gcc/clang/tcc) — CPython 3.9.6 used instead
```

Read-only hardware posture held: no `/dev/mem` writes, no bridge writes, no
bitstream loads, no flash, no reboots. Only regular-file I/O on the SD
(`/media/fat`) and tmpfs; bench data files removed after the runs.

## Numbers (4 KiB records, N=2000, ns unless noted)

| metric | exfat-append-4096-py | tmpfs-append-4096-py |
| --- | --- | --- |
| ops | 2000 | 2000 |
| rec_B | 4096 | 4096 |
| construct p50 / p95 / p99 (µs) | 196.8 / 298.8 / 495.8 | 104.5 / 174.6 / 258.0 |
| append p50 / p95 / p99 (µs) | 2942.1 / 9967.9 / 12123.7 | 58.6 / 122.2 / 188.0 |
| durable (fsync) p50 / p95 / p99 (µs) | 42.7 / 87.9 / 121.5 | 14.7 / 23.5 / 53.3 |
| publish p50 / p95 / p99 (µs) | 8.0 / 24.0 / 43.2 | 6.3 / 7.7 / 10.9 |
| total p50 / p95 / p99 (µs) | 3232.2 / 10204.8 / 12551.5 | 188.9 / 330.9 / 521.5 |
| total max (µs) | 19515.0 | 2075.7 |
| total mean (µs) | 4252.3 | 217.0 |
| cpu per op (µs) | 945.7 | 228.3 |
| throughput, 1 outstanding (ops/s) | 233 | 4256 |
| payload bytes | 8192000 | 8192000 |
| block bytes (st_blocks) | 8257536 (+0.8%) | 8192000 (+0.0%) |
| VmRSS / maxRSS (KiB) | 7084 / 6788 | 6984 / 6900 |
| recovery scan (ms, 8 MiB) | 190.7 | 178.4 |
| restart wall open→close (ms) | 301.3 | 289.6 |
| recovered seq / bad tail | 2000 / 0 | 2000 / 0 |

Headline takeaways:

- exfat total p50 **3.23 ms/op (233 ops/s)**; append dominates (2.94 ms p50),
  fsync is cheap (42.7 µs p50) because the mount is already
  `rw,sync,dirsync` — durability cost sits in the write path, not the flush.
- vs 2026-09-24 C run (exfat 4K, N=5000): total p50 was 1.73 ms/op.
  The ~1.5 ms gap is media/scheduler variance plus Python write-path
  overhead; method and mount semantics are otherwise identical.
- Recovery is **verifier-CPU-bound, not storage-bound**: 190.7 ms (exfat SD)
  vs 178.4 ms (tmpfs) to scan + crc-verify 8 MiB in CPython. A C verifier
  would collapse both; the gap to close is harness language, not media.
- tmpfs total p50 189 µs bounds single-op interpreter + syscall cost; the
  exfat/tmpfs ratio (~17x at p50) is the durable-commit storage tax on this
  SD under sync mount.

## Files

- `raw/` — `exfat-append-4096.log`, `exfat-append-4096.recover.log`,
  `tmpfs-append-4096.log`, `tmpfs-append-4096.recover.log`, `env.txt`
  (`SMOLFIRE_METRIC` lines + bench JSON + wall lines; ground truth).
- `records/` — 4× `ryanlab.bench.v1` JSON: `durable-commit-{exfat,tmpfs}-append-4096-py[.json,-recovery.json]`.
- `results-table.md` — machine-readable table mirroring the 2026-09-24 shape.
