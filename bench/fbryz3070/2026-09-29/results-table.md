# Results table — #90 BSD transport primitives, fbryz3070, 2026-09-29

Canonical run (`raw/prim90.log`). Workload → record file; all values ns unless noted.

| workload | record | p50 | p95 | p99 | extra |
| --- | --- | --- | --- | --- | --- |
| pipe-rtt-1b | records/bsd-primitive-pipe-rtt-1b.json | 3090 | 3390 | 3690 | n=20000, min=2560, max=36149, mean=3137 |
| pipe-rtt-4k | records/bsd-primitive-pipe-rtt-4k.json | 3500 | 3650 | 3940 | n=20000, min=3009, max=29889, mean=3522 |
| socketpair-rtt-1b | records/bsd-primitive-socketpair-rtt-1b.json | 3259 | 3409 | 3580 | n=20000, min=2900, max=34118, mean=3270 |
| socketpair-rtt-4k | records/bsd-primitive-socketpair-rtt-4k.json | 3470 | 3590 | 3810 | n=20000, min=3400, max=29009, mean=3488 |
| pipe-stream-64k | records/bsd-primitive-pipe-stream-64k.json | — | — | — | 268435456 B, 13136.4 MB/s |
| socketpair-stream-64k | records/bsd-primitive-socketpair-stream-64k.json | — | — | — | 268435456 B, 24550.3 MB/s |
| shm-mmap-64M | records/bsd-primitive-shm-mmap-64M.json | — | — | — | write 21.22 GB/s; 4K-stride readscan 409.34 GB/s equiv |
| kqueue-user-trigger-wait | records/bsd-primitive-kqueue-user-trigger-wait.json | 280 | 290 | 300 | n=20000, min=269, max=1330, mean=287 |
| kqueue-trigger-batch-1 | records/bsd-primitive-kqueue-trigger-batch-1.json | — | — | — | 8338482 ops/s |
| kqueue-trigger-batch-64 | records/bsd-primitive-kqueue-trigger-batch-64.json | — | — | — | 8367088 ops/s |
| mutex-condvar-pingpong | records/bsd-primitive-mutex-condvar-pingpong.json | 5940 | 6430 | 6900 | n=20000, min=5590, max=29128, mean=6019 |
| atomic-flag-handoff-2thread | records/bsd-primitive-atomic-flag-handoff-2thread.json | 129 | 130 | 140 | n=20000, min=89, max=2240, mean=117 |
| atomic-fetchadd-local | records/bsd-primitive-atomic-fetchadd-local.json | — | — | — | 1.5 ns/op, n=5000000 |

Run-to-run p50 ranges (3 runs): pipe-1B 3090–5960, pipe-4K 3500–3750,
sock-1B 3259–3420, sock-4K 3470–3780, pipe-stream 12530–13136 MB/s,
sock-stream 21511–24550 MB/s, shm-write 21.20–21.22 GB/s,
kqueue 280–340 ns / 6.9–8.3 M/s, mutex 3740–6870 ns, atomic-handoff 90–129 ns.
