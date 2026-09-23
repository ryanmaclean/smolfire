# Research briefing — sandboxing, BSD kernels, RVA23 (July 2026)

This three-topic research sweep was run 2026-07-31 by three parallel research
agents against primary sources (FreeBSD release notes and status reports, LWN,
riscv.org, vendor announcements). Findings ranked by relevance to smolfire (formerly smolBSD).

Repo state at time of writing: SMOLFIRE one-ELF microVM boots in 511 ms
(PR #37), image diet at 66.6 MiB raw / 26.6 MiB download (PR #36), TPM
T1–T6 green, hosted-runner build + size + boot gates in CI.

---

## 1. Sandboxing

### FreeBSD jails + OCI convergence (highest relevance)

- FreeBSD 15.0 jail improvements: `zfs.dataset` attachment in jail(8),
  `sysctl -j`, `ngctl -j`, and production-ready mac_do(4) with in-jail rule
  changes via `security.mac.do.rules`.
  <https://vermaden.wordpress.com/2025/11/30/valuable-freebsd-15-0-release-updates/>
- Podman/Buildah run native FreeBSD jails via Doug Rabson's `ocijail`
  runtime; FreeBSD joined the OCI; ZFS is the recommended storage driver.
  Rootless Podman is the documented gap.
  <https://freebsdfoundation.org/blog/oci-containers-on-freebsd/>
  <https://freebsdfoundation.org/blog/advancing-cloud-native-containers-on-freebsd-podman-testing-highlights/>
- 2026Q1: Daemonless (60+ FreeBSD-native OCI images), AppJail X11
  sandboxing, Sylve unified bhyve/jails/ZFS web management.
  <https://www.freebsd.org/status/report-2026-01-2026-03/>

**Actionable**: coordinator subagents could be dispatched into
ocijail/Podman jails instead of ad-hoc isolation; mac_do(4) gives cheap
per-jail privilege rules. See tracking issue.

### Capsicum

- Alpha-Omega-funded bhyve+Capsicum audit follow-on ("Beach Cleaning")
  completed March 2026.
- 2026Q1 completed the process-descriptor API — pdwait(2), pdrfork(2),
  posix_spawnattr_setprocdescp_np(3) — making sandboxed process management
  practical. capsicum-rs covers libcasper/cap_net.
  <https://www.freebsd.org/status/report-2026-01-2026-03/>

### Linux / OpenBSD (context)

- Landlock ABI 7 (kernel 6.15): audit logging of denials; ABI 8 targeted
  at 7.0. <https://lwn.net/Articles/1021648/>
- The seccomp/io_uring bypass is being closed: task-level io_uring
  restrictions (`IORING_REGISTER_RESTRICTIONS_TASK`, cBPF filters),
  v5 January 2026, still in flight. <https://lwn.net/Articles/1054225/>
- BPF-LSM mainstream in enforcement tooling (Tetragon, Tracee; Cilium
  default on EKS).
  <https://eunomia.dev/blog/2025/02/12/ebpf-ecosystem-progress-in-20242025-a-technical-deep-dive/>
- OpenBSD: 7.8 errata removed the `tmppath` pledge promise and fixed
  unveil mountpoint-crossing; 7.9-beta moves libc to a private
  `__pledge_open(2)` syscall. <https://www.openbsd.org/errata78.html>
  <https://www.undeadly.org/cgi?action=article;sid=20260320085305>

### MicroVM / agent-sandboxing landscape

- Cloud Hypervisor nested-KVM (Dec 2025); rust-vmm monorepo +
  RISC-V/IOMMU (FOSDEM 2026); AWS nested virt on C8i/M8i/R8i (Feb 2026);
  Google Cloud Run second-gen microVMs replacing gVisor; KubeVirt 1.8
  abstracting beyond QEMU. <https://emirb.github.io/blog/microvm-2026/>
- Industry consensus for AI-agent code execution is microVM-per-agent
  (Docker Sandboxes, Vercel Sandbox, E2B, Microsandbox).
  <https://northflank.com/blog/how-to-sandbox-ai-agents>

**Positioning**: smolfire — an agent-built FreeBSD microVM with jail/OCI
layering available inside — is a BSD-native instance of the
microVM-per-agent pattern.

---

## 2. BSD kernel features

### pkgbase (validates our pipeline; one gap)

- pkgbase is official in FreeBSD 15.0 (2025-12-02) as a technology
  preview; **default for all VM/cloud images**; expected standard in 16
  (distribution sets removed in 16).
  <https://www.freebsd.org/releases/15.0R/relnotes/>
- Fine-grained packages + meta sets; -dbg/-dev/-man separable.
  <https://vermaden.wordpress.com/2025/10/20/brave-new-pkgbase-world/>
- **Custom pkgbase kernel packages remain unsupported** — SMOLBSD/SMOLFIRE
  kernconfs must stay source-built (pkg-unregister workaround). Watch
  pkgdist/pkgbasify (2026Q1 report; pkg ≥ 2.7 improves conversion).
  <https://forums.freebsd.org/threads/freebsd-15-now-kernel-is-a-package-how-to-install-my-compiled-kernel-as-a-package.101585/>
- **Update 2026-09-22 — now an automated watch.** Verdict still
  `keep-source-built`; status is `knob`. A `KERNCONF` passed to
  `make packages` yields `FreeBSD-kernel-<conf>`, and our cloudware-release
  pipeline already relies on that. There is still no standalone
  kernel-package target, the Handbook does not document it, and the official
  repos ship only GENERIC-family kernels. pkg 2.7 landed on 2026-04-13
  (ports are at 2.8.4); it changes conversion only. The 2026Q2 report has no
  custom-kernel news, and 2026Q3 is not out yet. Details, citations and the
  quarterly `bin/pkgbase-watch.nu` check are in
  [PKGBASE-WATCH.md](PKGBASE-WATCH.md).

### FreeBSD 15.1 (2026-06-16) — one trap for us

- **pkgbase VM/cloud images now auto-update base packages on first
  boot.** For a deterministic, measured-boot edge image this breaks
  reproducibility and TPM PCR stability — disable in our release confs
  when rebasing onto 15.1.
  <https://www.freebsd.org/releases/15.1R/relnotes/>
- Also in 15.1: `kern.sched.name` boot-time scheduler selection, LASS,
  LinuxKPI on Linux 7.0 base.
- 15.0 headline items: KTLS in GENERIC, native inotify(2), LA57,
  NVMe-oF/TCP, SIMD libc, OpenSSL 3.5 (PQC), 32-bit hardware dropped.

### Boot / microVM

- In-tree amd64 `FIRECRACKER` kernconf (virtio-mmio + mptable, no
  ACPI/PCI) — the reference SMOLFIRE builds on; Percival's patches reach
  sub-20 ms kernel boots on Firecracker; GSoC 2025 boot-optimization
  project continues. <https://reviews.freebsd.org/D36672>
  <https://bllgg.github.io/projects/freebsd_boot_process_optimization/>
- EC2 images boot up to 76% faster than 14.0; EC2 now publishes a
  "small" variant (no debug symbols/dev tools) — precedent for our trim
  list. <https://www.freebsd.org/releases/15.0R/relnotes/>
- **Benchmark to beat**: NetBSD 11.0 ships a dedicated MICROVM kernel
  (PVH boot + virtio-mmio) with ~10 ms boots. SMOLFIRE is at 511 ms —
  the gap is a roadmap, not an embarrassment (different init paths), but
  worth studying.
  <https://www.netbsd.org/releases/formal-11/NetBSD-11.0.html>

### bhyve

- 15.0: bhyve/vmm on **arm64 and riscv64** (VirtIO FreeBSD/Linux guests,
  `u-boot-bhyve-arm64` boot, no PCI passthrough yet); libslirp userspace
  networking; guest NUMA (amd64); QEMU backend for native vmm.
- 2026Q1: fine-grained CPUID masking via bhyvectl (groundwork for live
  migration); snapshot save/restore maturing; Sylve/Bhyvemgr management.
  <https://www.freebsd.org/status/report-2026-01-2026-03/>
- swtpm TPM 2.0 emulation works (Win11 guests); 2025 TPM-passthrough and
  XHCI security fixes.

**Actionable**: aarch64 smolfire images can now be boot-gated on bhyve
hosts, not just QEMU/HVF.

### OpenBSD (brief)

- 7.7: SMP/network-stack work. 7.8: AMD SEV guest support, parallel
  softnet, RPi5. Nothing minimal-image-critical.
  <https://www.openbsd.org/plus77.html>
  <https://www.phoronix.com/news/OpenBSD-7.8-Released>

---

## 3. RISC-V RVA23

### Profile and hardware

- RVA23 ratified 2024-10-21; mandates V (vector) and H (hypervisor)
  plus Zicond, Zvbb, cache management — the binary-distro baseline.
  <https://riscv.org/blog/risc-v-announces-ratification-of-the-rva23-profile-standard/>
- **One shipping RVA23 SoC**: SpacemiT K3 (8x X100 ~2.4 GHz + 8x RVA22 AI
  cores, 1024-bit vectors). K3 Pico-ITX SBC / CoM260 SoM ~$299-309
  (shipped May-June 2026); DC-ROMA Mainboard III (Framework 13)
  $699-1,499. Performance is Pi-4/5 class; GPU software-rendered.
  <https://www.cnx-software.com/2026/05/11/rva23-pico-itx-sbc-spacemit-k3-octa-core-risc-v-ai-soc-up-to-32gb-ram-256gb-ufs/>
  <https://www.youngju.dev/blog/2026-07-16-riscv-rva23-profile-baseline-reality>
- SiFive P570 Gen3 IP announced; Ventana/Tenstorrent server parts
  sampling, not buyable. K3 mainline Linux support only in review since
  late 2025.

### Software baselines

- Ubuntu: RVA23S64 minimum from 25.10, cemented in 26.04 LTS — but
  effectively QEMU-only as of July 2026; pre-RVA23 boards stay on
  24.04.4.
  <https://canonical.com/blog/canonical-and-ubuntu-risc-v-a-2025-retro-and-looking-forward-to-2026>
- Debian stays RV64GC; Fedora still pursuing primary-arch status.
  Android's ABI baseline is RVA23 (no devices yet). GCC gained RVA23
  profile support in 16.1 (April 2026); LLVM earlier.

### FreeBSD riscv64

- Tier 2 in 15.0; baseline plain RV64GC (no RVA23 requirement); SMP
  works; **QEMU `virt` is the primary well-supported target**; real-board
  support (VisionFive 2 / JH7110, Star64, Milk-V Mars) partial/flaky.
  <https://www.freebsd.org/releases/15.0R/hardware/>
- **15.0 ships bhyve for riscv64.** <https://wiki.freebsd.org/riscv/bhyve>
- QEMU has `rva23s64`/`rva23u64` CPU models (≥ 9.x) and mature
  H-extension emulation; nested KVM-in-TCG works with rough edges.
  <https://www.qemu.org/docs/master/system/riscv/virt.html>
- NetBSD/riscv64 QEMU-only; OpenBSD/riscv64 ships releases (HiFive
  Unmatched target).

### Verdict

A **QEMU-emulated riscv64 smolfire target is realistic within months** —
mostly kernconf + release-conf + CI-matrix work on the now-proven
pipeline. Real RVA23 hardware deployment is 6-12 months premature: no
FreeBSD support for the only shipping RVA23 silicon (K3), Tier-2 status,
thinner ports coverage. Recommendation: add riscv64/QEMU as an
experimental third target; make no hardware claims.

---

## Action items

Tracked in the "Research follow-ups (2026-07)" GitHub issue:

1. **15.1 rebase guard** — disable first-boot base auto-update in release
   confs before any move to 15.1 (PCR stability + determinism).
2. **riscv64 experimental target** — SMOLBSD kernconf for riscv64, QEMU
   `virt` boot gate in CI, rv64gc baseline (optionally `rva23s64` CPU
   model as a second matrix leg).
3. **Jail/OCI agent dispatch** — evaluate ocijail/Podman jails +
   mac_do(4) as the coordinator's subagent isolation layer.
4. **Boot-time roadmap** — study NetBSD 11 MICROVM (~10 ms) and
   Percival's Firecracker patches (<20 ms kernel) for the next SMOLFIRE
   boot-time round (currently 511 ms).
5. **pkgbase kernel watch** — adopt pkgbase-native custom kernel
   packaging when pkgdist/pkgbasify supports it; drop the source-built
   kernel workaround.
   → Automated: `.github/workflows/pkgbase-watch.yml` runs quarterly and
   comments on #39 only when the verdict becomes `reevaluate`
   ([PKGBASE-WATCH.md](PKGBASE-WATCH.md)).
