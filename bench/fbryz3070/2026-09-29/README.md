# #90 BSD transport-primitives baseline — fbryz3070, 2026-09-29

> Tracking issue: smolBSD #90. "Do not design a custom ring/DMA/coherence
> mechanism until this benchmark demonstrates a missing primitive."

## Method

- Harness: throwaway C (`cc -O2 -pthread`, never committed — repo policy is
  Nushell-only; repo gets records + docs, no new code). Ran on the host in
  `/tmp` under `nice -n 10`, three bounded runs (seconds each), then removed.
- Timing: `CLOCK_MONOTONIC` (`clock_gettime`), per-op samples (N=20000 for
  latency workloads) sorted in-process for min/p50/p95/p99/max/mean.
- RTT workloads: `fork()` ping-pong child echoes the payload back over a
  second pipe/socketpair (full-duplex pair); parent times write+read round trip.
- Stream workloads: child drains 256 MiB in 64 KiB chunks; parent times writes.
- shm: 64 MiB `MAP_SHARED|MAP_ANON` mmap; `memcpy` write timed in full;
  read side is a 4 KiB-stride scan (touches one byte per page — cache/TLB
  behavior, NOT full bandwidth; reported honestly as `readscan`).
- kqueue: `EVFILT_USER` + `NOTE_TRIGGER` self-notify then blocking `kevent`
  wait (latency); batch rows measure the `kevent`-trigger syscall rate
  (N triggers, triggers coalesce under `EV_CLEAR`, single drain).
- mutex: two-thread ping-pong through `pthread_mutex_t` + `pthread_cond_t`
  (lock/signal/wait round trip per sample). atomic: two-thread
  acquire/release flag handoff (spin), plus local `fetch_add` rate.
- Context-switch cost is an *estimate* derived from the 1-byte pipe RTT
  (see table note), not a direct measurement.

## Exact semantics (OS / CPU / toolchain)

```
host=fbryz3070
FreeBSD fbryz3070 15.0-RELEASE-p11 FreeBSD 15.0-RELEASE-p11 #0 -dirty: Tue Jun 30 05:54:41 UTC 2026 root@amd64-builder.daemonology.net:/usr/obj/usr/src/amd64.amd64/sys/GENERIC amd64
hw.model=AMD Ryzen 9 5950X 16-Core Processor (3400.36-MHz K8-class CPU)
hw.ncpu=32  hw.physmem=128 GiB (137313521664)
kern.osrelease=15.0-RELEASE-p11
toolchain=FreeBSD clang version 19.1.7, -O2 -pthread
```

Read-only posture held: no installs, no config changes, no reboots; all
transient files in `/tmp` on the host, removed after the runs. Repo receives
only `ryanlab.bench.v1` JSON records + this README + `results-table.md`.

## Numbers (canonical run; run-to-run p50 range across 3 runs in last column)

| primitive | p50 | p95 | p99 | throughput | p50 range (3 runs) |
| --- | --- | --- | --- | --- | --- |
| pipe RTT 1 B (2 procs) | 3090 ns | 3390 ns | 3690 ns | — | 3090–5960 ns |
| pipe RTT 4 KiB (2 procs) | 3500 ns | 3650 ns | 3940 ns | — | 3500–3750 ns |
| socketpair RTT 1 B | 3259 ns | 3409 ns | 3580 ns | — | 3259–3420 ns |
| socketpair RTT 4 KiB | 3470 ns | 3590 ns | 3810 ns | — | 3470–3780 ns |
| pipe stream 64 KiB chunks | — | — | — | 13136 MB/s | 12530–13136 MB/s |
| socketpair stream 64 KiB chunks | — | — | — | 24550 MB/s | 21511–24550 MB/s |
| shm mmap memcpy 64 MiB | — | — | — | 21.22 GB/s write | 21.20–21.22 GB/s |
| shm 4K-stride scan (not full BW) | — | — | — | 409 GB/s equiv | 409–691 GB/s equiv |
| kqueue EVFILT_USER trigger+wait | 280 ns | 290 ns | 300 ns | 8.3 M triggers/s | 280–340 ns |
| mutex+condvar ping-pong (2 threads) | 5940 ns | 6430 ns | 6900 ns | — | 3740–6870 ns |
| atomic flag handoff (2 threads, spin) | 129 ns | 130 ns | 140 ns | — | 90–129 ns |
| atomic fetch_add local | 1.5 ns/op | — | — | — | 1.5–1.6 ns/op |
| ctx-switch estimate (½ × 1 B pipe RTT) | ~1.5 µs | — | — | — | ~1.5–3 µs |

Run-to-run variance is real (frequency scaling / placement; e.g. mutex p50
3.7→6.9 µs, pipe-1B 3.1→6.0 µs across runs) — the ranges above are the honest
picture, not just the canonical best. Full per-run detail: run 1 and run 2
values are quoted in the issue comment report; `raw/prim90.log` is the
canonical run.

Copies in path: pipe/socketpair RTT = 2 user→kernel→user copies + 2 process
wakeups per round trip; stream = 1 copy per direction bounded by pipe buffer;
shm memcpy = zero-syscall, memory-bandwidth-bound.

## GATE VERDICT

Issue #90's rule, quoted back: **"Do not design a custom ring/DMA/coherence
mechanism until this benchmark demonstrates a missing primitive."**
Verdict per custom-mechanism temptation:

- **Custom ring (request publication path): NOT demonstrated missing.**
  Cheapest publication already available: C11 acquire/release flag in shared
  mmap at ~90–130 ns p50, kqueue notification at ~280–340 ns p50 /
  ~7–8 M events/s. A custom ring would remove syscalls that the atomic path
  already avoids. Threshold reasoning: a ring is only justified by a
  sub-100 ns or cross-coherence-domain (CPU↔FPGA) requirement — neither is
  evidenced here, and the latter needs SoC hardware (see BLOCKED).
- **Custom DMA (bulk-move path): NOT demonstrated missing.**
  `memcpy` in shared mapping runs at 21.2 GB/s (memory-bandwidth-bound);
  socketpair streams at 21.5–24.5 GB/s, pipe at 12.5–13.1 GB/s. No copy
  bottleneck exists on this host that a custom DMA engine would remove.
  `bus_dma` synchronization and HPS DMA are SoC-specific → BLOCKED.
- **Custom coherence/notification: NOT demonstrated missing.**
  kqueue delivery (~0.3 µs) and mutex/condvar (~4–7 µs) cover sleeping
  notification; spin-handoff (~0.1 µs) covers polling. The OS already
  guarantees what a custom coherent path would provide on cache-coherent SMP.
  A coherent HPS↔FPGA/ACP path cannot be evaluated here → BLOCKED.

## Issue coverage

- shared memory + atomics: MEASURED (shm-mmap-64M, atomic-flag-handoff,
  atomic-fetchadd-local).
- mmap/device mapping: PARTIALLY measured (anonymous shared mmap; `/dev/mem`
  device mapping not attempted — read-only posture, and no FPGA aperture
  exists on this amd64 box).
- polling: MEASURED via spin-handoff (atomic-flag-handoff-2thread).
- kqueue notification: MEASURED (trigger+wait latency, trigger rate).
- bus_dma synchronization: BLOCKED — no SoC DMA hardware on fbryz3070
  (generic amd64 builder); unblocked by a FreeBSD-supported SoC board with a
  `bus_dma` attachment.
- existing HPS DMA: BLOCKED — no HPS/FPGA fabric on this host; unblocked by
  Cyclone V-class SoC hardware (e.g. DE10-Nano) with resident BSD.
- coherent HPS↔FPGA memory path / ACP: BLOCKED — same hardware as above.
