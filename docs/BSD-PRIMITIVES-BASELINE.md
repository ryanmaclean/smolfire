# Existing BSD primitive baseline (#90)

`hps/bsd_primitives_bench.c` measures a single-outstanding-request round trip
between two processes on FreeBSD. It compares release/acquire shared-memory
polling with kqueue notification through two pipes. Payloads stay in the same
shared mapping in both modes. The mapping is either anonymous or an unlinked
temporary file. There is no custom ring, DMA engine or new state owner.

Each request carries a deterministic 64-byte payload derived from the full
64-bit sequence and seed. The consumer validates every byte, writes the
complement response, and publishes completion with a release store. The
producer checks that response after an acquire load. One outstanding operation
prevents reuse before completion; future sequences and corrupt payloads fail.
The executable refuses non-lock-free shared atomics, bounds waits, and only
prints a measurement after every requested operation and the child exit pass.

Latency includes payload construction, observation and validation. Throughput
covers the measured loop; warmup is excluded. Percentiles use nearest rank.
Processes are unbound, so these are scheduler-dependent round-trip measurements,
not isolated instruction or one-way costs. File-backed mmap demonstrates shared
visibility only: it does not call fsync and makes no durability claim. Kqueue
uses pipe readability for notification; it does not replace release/acquire
ordering of the shared payload.

Combined parent/child CPU time and context switches include process setup and
warmup; they are labeled separately from the measured-loop elapsed time. The
runner also records CPU model/count and the kernel's virtualization indicator.
Regression cases inject a corrupted last payload byte and a future sequence;
both must fail without producing a successful measurement.

On an approved FreeBSD builder, using its existing base compiler and shared
build lock:

```text
cc -std=c11 -D__BSD_VISIBLE=1 -O2 -Wall -Wextra -Werror \
  hps/bsd_primitives_bench.c -o /var/tmp/bsd-primitives-bench
nu tests/bsd-primitives-test.nu /var/tmp/bsd-primitives-bench
nu tests/bsd-primitives-runner-test.nu
nu bin/bsd-primitives.nu /var/tmp/bsd-primitives-bench result.json
```

No additional library or tool installation is required. Source and Nu helpers
are Apache-2.0; native linkage is inspected in the recorded run. Do not run a
build on the workstation. The runner refuses to overwrite evidence files and
records the executable hash, workload, timestamps, OS/architecture, clock
resolution and scope limits.

This advances the shared-memory/atomics, file mmap, polling and kqueue portion
of #90. Device MMIO, `bus_dma` synchronization, HPS DMA, coherent HPS–FPGA/ACP,
and hardware-copy/barrier measurements remain separate hardware-specific gates.
These results cannot establish FPGA advantage or justify custom transport.

## First recorded FreeBSD run

The checked-in [raw record](../bench/bsd-primitives/2026-09-27/pop-amd64.json)
contains four validated 100,000-operation runs, each with 1,000 warmup
operations, on FreeBSD 15.1-RELEASE-p3 amd64, a 16-vCPU KVM guest exposing an
AMD Ryzen 9 7950X. The executable was built with base clang 19.1.7, with
`-Wall -Wextra -Werror`; dynamic linkage is only base libc and libsys.
The native Nushell contract suite passed 15 cases. A separate 16-case synthetic
runner suite verifies result-label rejection, executable-change rejection and
evidence preservation; these fixture outputs are not measurements. Compiler,
linkage, source hashes and test records sit alongside the actual measurements.

| Notification | Mapping | p50 round trip (ns) | p99 (ns) | Validated round trips/s |
|---|---|---:|---:|---:|
| polling | anonymous | 671 | 782 | 1,392,973 |
| polling | file | 300 | 341 | 2,975,684 |
| kqueue/pipe | anonymous | 3,737 | 10,459 | 197,146 |
| kqueue/pipe | file | 3,466 | 3,908 | 281,270 |

These are individual runs, not confidence intervals or a causal comparison of
mapping types. Earlier development runs reversed the relative polling order;
unbound scheduling and VM placement remain uncontrolled. The useful acceptance
evidence here is that both existing mechanisms complete verified cross-process
round trips, with measurable latency, CPU time and context switches. Repeated,
controlled hardware measurements are required before transport design decisions.
