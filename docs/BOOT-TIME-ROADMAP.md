# SMOLFIRE boot-time roadmap — 511 ms to sub-100 ms

Issue #39 items 3+4. Written 2026-08-23 against the round-2 SMOLFIRE state
(run 30409991192: `TIME_TO_READY=511ms` Firecracker v1.12.0 / 569 ms QEMU
microvm). Companion to `docs/UR-BSD-VERIFY.md` (SMOLFIRE section) and
`docs/RESEARCH-2026-07.md` §2. Read UR-BSD-VERIFY before touching
`sys/amd64/conf/SMOLFIRE` or `bin/build-smolfire.sh`.

## 1. Where the 511 ms goes (best current knowledge)

`TIME_TO_READY` is a **wall-clock expect-gate measure**: VMM process exec →
`SMOLFIRE_READY` on serial. It bundles four phases we have never separated:

| Phase | What happens | Estimate | Evidence |
|---|---|---|---|
| VMM start + ELF load | Firecracker API socket, load the 37 MiB PVH ELF (kernel + embedded MFS root) into guest RAM | 10–50 ms | unmeasured; scales with ELF size |
| Early kernel | PVH entry, mptable CPU enum, i8254-calibrated TSC (`pvh_early_delay` patch, `docs/upstream/pvh-early-delay.md`), lapic setup | 50–150 ms | i8254 calibration is DELAY-loop bound; Percival measured ~20 ms saved just by advertising TSC freq via CPUID ([USENIX ;login:](https://www.usenix.org/publications/loginonline/freebsd-firecracker)) |
| SYSINIT + devices | virtio-mmio probe via `virtio_mmio.device=` cmdline, vtnet, md0 attach, UFS root mount | 100–250 ms | debug checkers already stripped (round 2 de-debug); releng/15.0 carries the upstreamed SYSINIT mergesort |
| init + /etc/rc | `/sbin/init` → `/bin/sh /etc/rc`: hostname, lo0, vtnet0, route, optional fetch — each a fork/exec of the crunched rescue binary (~15 MiB, unmeasured) | 50–150 ms | unmeasured; ~6–8 execs |

Estimates are deliberately wide — **step one of this roadmap is replacing
this table with TSLOG data** (§3). What is already done, so not on the
candidate list: WITNESS/INVARIANTS/DEADLKRES removal (round 2), ACPI/PCI
elimination (inherited from the in-tree `FIRECRACKER` conf,
[commit 469ad86](https://lists.freebsd.org/archives/dev-commits-src-all/2022-October/017969.html)),
no bootloader/ESP (PVH direct boot), no fsck (read-only-fresh MFS root).

Reference points:

- **NetBSD 11.0 MICROVM: ~10 ms** — PVH direct boot, virtio-mmio devices
  named on the kernel cmdline (no bus scan), no ACPI/PCI
  ([NetBSD 11.0 release notes](https://www.netbsd.org/releases/formal-11/NetBSD-11.0.html),
  [imil's microvm wiki](https://wiki.netbsd.org/users/imil/microvm/) — "kernel
  boot time: 9ms" on a Ryzen 7 5800X). Caution: that figure is the
  **kernel-printed boot time**, not VMM-exec-to-shell wall clock, and the
  smolBSD (NetBSD micro-VM project, unaffiliated) images pair it with a
  purpose-built tiny init
  ([FOSDEM 2026 talk](https://fosdem.org/2026/schedule/event/BGPF3M-smolbsd/)).
- **FreeBSD on Firecracker (Percival): <20 ms kernel** with experimental
  patches to both FreeBSD and Firecracker; ~25 ms reported publicly
  ([The Register](https://www.theregister.com/2023/08/29/freebsd_boots_in_25ms/)).
  Much of the laundry list is upstream by 15.0 (mergesort SYSINITs, mptable
  path, FIRECRACKER conf); some pieces were Firecracker-side or experimental
  and need re-verification (§2.2).

So 511 ms → sub-100 ms wall clock is credible without heroics; matching
NetBSD's 10 ms kernel-only number is a stretch goal, not the target.

## 2. Ranked candidate reductions

Ranked by (expected savings ÷ effort), pending TSLOG confirmation.

### 2.1 Measure before optimizing — TSLOG (effort: S, savings: enables all)

No further blind tuning. See §3.

### 2.2 Kill i8254 TSC calibration (effort: M, expected 20–100 ms)

FreeBSD without CPUID frequency leaves calibrates TSC against the i8254 with
DELAY loops — the exact path our `pvh_early_delay` patch exists to survive on
AMD-host runners. Percival measured **20 ms saved** by teaching Firecracker to
advertise TSC + lapic frequencies via the hypervisor CPUID leaf
([USENIX ;login:](https://www.usenix.org/publications/loginonline/freebsd-firecracker));
on our nested-KVM runners the calibration is likely costlier. Actions:
(a) verify whether Firecracker ≥ v1.12 exposes the TSC kHz CPUID leaf
(0x40000010) on our runners — dump CPUID from the guest; (b) if not, carry
the Firecracker-side patch or pass frequency by template; (c) check
releng/15.0's deferred/faster `tsc_calib`
([D32758](https://reviews.freebsd.org/D32758)) actually engages on the PVH
path. Ledger constraint: `machdep.tsc_freq` is RW-only, not a tunable — the
kenv shortcut does not exist (UR-BSD-VERIFY, SMOLFIRE run #4/#5 notes).

### 2.3 Slim the rc path / custom init (effort: S–M, expected 30–100 ms)

Each `/etc/rc` line is a fork+exec of the crunched rescue binary; `fetch`
adds a TCP round-trip when the net gate is armed. Options, in order:
drop `hostname`/`lo0` (cosmetic), collapse vtnet+route into one `ifconfig`
where possible, and ultimately replace `/sbin/init`+`sh` with a ~100-line
static C init that does hostname/ifconfig/route via ioctls and execs the
shell — the approach behind the NetBSD micro-VM numbers
([OSTechNix on smolBSD](https://ostechnix.com/build-10mb-netbsd-vms-boot-10ms-smolbsd/)).
Keep the `SMOLFIRE_READY` + interactive-shell gate contract and
`tests/smolfire-rootfs-test.nu` (init(8) contract) in sync.

### 2.4 Shrink the ELF (effort: M, expected 10–40 ms load-time)

37 MiB is dominated by the MFS image (full /rescue — roughly 15 MiB crunched, unmeasured, plus
UFS headroom). Smaller image → faster VMM load + less vm_page/copy work:
trim the crunch tool list to what `/etc/rc` and the gates use, or a
`MD_ROOT` image built with tighter `makefs` parameters. Do not gzip — the
PVH loader wants a plain ELF, and decompression would trade load for CPU.

### 2.5 Audit remaining DELAY/probe stalls (effort: M, expected 10–50 ms)

TSLOG will show them: uart probe, lapic timer calibration, `vt`/console
init, root-mount wait (`vfs.mountroot.timeout`), `kern.nswbuf`-class sizing
(Percival: nswbuf 256 → 32×ncpu saved 5 ms on 1-vCPU;
[USENIX ;login:](https://www.usenix.org/publications/loginonline/freebsd-firecracker)).
Check each against releng/15.0 — several of Percival's fixes are already in;
cherry-pick the ones that never landed (track in `docs/upstream/`).

### 2.6 Gate-harness honesty (effort: S, savings: measurement only)

Separate VMM-start overhead from guest boot: timestamp Firecracker's
`InstanceStart` vs first serial byte vs `SMOLFIRE_READY` in the expect gates.
Report both wall-clock and kernel-internal (TSLOG) numbers in CI so we never
compare our wall clock against others' kernel-only figures.

## 3. Measurement plan — TSLOG on the hosted runner

TSLOG is Percival's timestamp framework for exactly this job: it traces from
early kernel entry (where DTrace cannot run) through device attach into
userland, dumped post-boot via the `debug.tslog` sysctl and rendered as a
flame chart ([tslog(9)](https://man.freebsd.org/cgi/man.cgi?query=tslog),
[BSDCan 2018 paper](https://papers.freebsd.org/2018/bsdcan/percival-profiling_the_freebsd_kernel_boot/),
[cperciva/freebsd-boot-profiling](https://github.com/cperciva/freebsd-boot-profiling)).
It drove FreeBSD's ~30 s → ~9 s (2017→2022) and the Firecracker work.

Plan (one CI cycle on the existing `smolfire.yml` hosted-runner pipeline):

1. New kernconf `sys/amd64/conf/SMOLFIRE-TSLOG`: `include SMOLFIRE` +
   `options TSLOG` + `options TSLOG_PAGES=…` (sized up; default overflows on
   busy boots). Never ships in the release ELF — TSLOG itself costs time.
2. `/etc/rc` (TSLOG builds only): `sysctl debug.tslog` → serial or a shared
   file before `SMOLFIRE_READY`, so the gate harvests it as an artifact.
3. Post-process with the freebsd-boot-profiling scripts into a flame chart;
   attach SVG + raw log to the CI run (same pattern as SIZEREPORT +
   `bin/sizereport.nu`).
4. Land the phase table in §1 as measured numbers, re-rank §2, and re-run
   the TSLOG build after every accepted change — no unmeasured claims
   (run #7's lesson: guards and claims fail loud, not silent).
5. Baseline both VMMs — the 58 ms Firecracker/microvm gap is itself a datum.

Exit criteria for this roadmap: `TIME_TO_READY` ≤ 100 ms on Firecracker on
the hosted runner, net gate + host-ping still green, release ELF still
TSLOG-free, and each accepted change carries its measured delta in
UR-BSD-VERIFY.

## 4. Subagent isolation: jail/OCI option (issue #39 item 3)

`docs/RESEARCH-2026-07.md` §1 findings: FreeBSD 15.0 jails are
OCI-converged — Podman/Buildah run native jails via Doug Rabson's `ocijail`
runtime, FreeBSD joined the OCI, ZFS is the recommended storage driver, and
`mac_do(4)` is production-ready for cheap per-jail privilege rules
([FreeBSD Foundation](https://freebsdfoundation.org/blog/oci-containers-on-freebsd/),
[Podman testing](https://freebsdfoundation.org/blog/advancing-cloud-native-containers-on-freebsd-podman-testing-highlights/),
[vermaden 15.0 notes](https://vermaden.wordpress.com/2025/11/30/valuable-freebsd-15-0-release-updates/)).
The 2026Q1 report adds 60+ FreeBSD-native OCI images (Daemonless)
([status report](https://www.freebsd.org/status/report-2026-01-2026-03/)).
**Rootless Podman remains the documented gap** — jailed subagents would run
under a root-owned Podman on the FreeBSD host.

Applied to the coordinator: subagents are Claude Code processes dispatched by
`bin/coord-tick.nu` on the operator's host (Linux/macOS in practice). Jails
require a FreeBSD host, so ocijail/Podman cannot be the coordinator's
*primary* isolation layer today; and the root-Podman requirement conflicts
with least-privilege dispatch.

**Recommendation: NO-GO as the coordinator's default isolation layer now;
conditional GO as a bounded experiment.** Rationale: (a) host-OS mismatch;
(b) rootless gap; (c) the industry pattern for AI-agent code execution is
microVM-per-agent ([Northflank survey](https://northflank.com/blog/how-to-sandbox-ai-agents)),
and SMOLFIRE **is** our microVM — a sub-100 ms boot makes VM-per-task
dispatch cheaper than jail setup, with a harder boundary. The experiment
worth funding after the boot work: on the FreeBSD build VM, run one build
subagent in an ocijail + `mac_do(4)` jail and compare wall time, escape
surface, and spool ergonomics against a SMOLFIRE-per-task dispatch.
Re-evaluate at the FreeBSD 15.1/16 rebase (rootless Podman progress is the
trigger to revisit).

## Sources

- <https://www.usenix.org/publications/loginonline/freebsd-firecracker>
- <https://www.theregister.com/2023/08/29/freebsd_boots_in_25ms/>
- <https://man.freebsd.org/cgi/man.cgi?query=tslog> ·
  <https://papers.freebsd.org/2018/bsdcan/percival-profiling_the_freebsd_kernel_boot/> ·
  <https://github.com/cperciva/freebsd-boot-profiling>
- <https://reviews.freebsd.org/D32758> ·
  <https://lists.freebsd.org/archives/dev-commits-src-all/2022-October/017969.html>
- <https://www.netbsd.org/releases/formal-11/NetBSD-11.0.html> ·
  <https://wiki.netbsd.org/users/imil/microvm/> ·
  <https://fosdem.org/2026/schedule/event/BGPF3M-smolbsd/> ·
  <https://ostechnix.com/build-10mb-netbsd-vms-boot-10ms-smolbsd/>
- <https://freebsdfoundation.org/blog/oci-containers-on-freebsd/> ·
  <https://freebsdfoundation.org/blog/advancing-cloud-native-containers-on-freebsd-podman-testing-highlights/> ·
  <https://www.freebsd.org/status/report-2026-01-2026-03/> ·
  <https://northflank.com/blog/how-to-sandbox-ai-agents>
