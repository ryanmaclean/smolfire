# Phase I — Arch Decision: amd64 vs aarch64 vs both

- **Task**: task-0003a (REPLAN)
- **Authored by**: researcher@smolbsd.local
- **Date**: 2026-04-30
- **Inputs**: task-0003a brief, MEMORY.md, feedback_check_first.md,
  feedback_no_projection.md, freebsd-build-vm/raspberry-pi/freebsd-pi
  skills, PHASE-1-FORGE-TINY-BASELINE.md, design-spec v1.1 §11/§14/§17.
- **Status**: decision, design-only, no build commands run.

---

## 0. Verified facts (basis for the decision)

These are facts the coordinator already verified by absolute path on
2026-04-30 — re-stated here so the matrix below is auditable. No
additional probe loops were run for this document (per
`feedback_check_first.md`, one verification is enough; redundant probing
LAN servers is forbidden per CLAUDE.md).

| Fact | Verified by | Source |
|------|-------------|--------|
| `qemu-system-aarch64` present on <hypervisor-host> | absolute-path probe | `/opt/homebrew/bin/qemu-system-aarch64` (QEMU 10.2.1) |
| `qemu-system-x86_64` present on <hypervisor-host> | absolute-path probe | `/opt/homebrew/bin/qemu-system-x86_64` (QEMU 10.2.1) |
| <aarch64-builder> VM is FreeBSD 15 aarch64 | freebsd-build-vm SKILL.md L28 | "FreeBSD 15.0-RELEASE aarch64 (cloud-init qcow2)" |
| HVF accel works only for matching ISA on Apple Silicon | Apple Hypervisor.framework docs | aarch64-on-aarch64 = native HVF; amd64-on-aarch64 = TCG (software) |
| FreeBSD `make TARGET=amd64 TARGET_ARCH=amd64` cross-builds from aarch64 | PHASE-1-FORGE-TINY-BASELINE §10 | already in the existing plan |
| <dev-mac> reaches <hypervisor-host> over Tailscale | task-0003a brief | Tailscale path live; LAN 10.0.3.x not reachable from current network |
| Vultr offers both amd64 and aarch64 instances | MEMORY.md user_cloud_vultr.md + Vultr public catalog | native FreeBSD on both |
| Pi 5 SoC is BCM2712 (Cortex-A76) — aarch64 | raspberry-pi SKILL.md "Pis are ARM64" | aarch64 only |
| RK3588 SoC is Cortex-A76 + A55 — aarch64 | Rockchip public datasheet | aarch64 only |
| Existing Phase-I plan commits to amd64 cross-build inside <aarch64-builder> | PHASE-1-FORGE-TINY-BASELINE §2.1 / §7.2 | "Preferred build host: fb-vm-24 ... TARGET=amd64" |

Soft signal (NOT verified, weighted appropriately): the overwritten jj
commit description "phase 1 = both RK3588 + Pi 5". Treated below as
weight-on-aarch64 evidence, not as a directive — per
`feedback_no_projection.md`, the user has not explicitly confirmed it.

---

## 1. Decision matrix

Letters used:
- **A** = amd64 only (existing plan)
- **B** = aarch64 only
- **C** = both (parallel pipelines, common base + per-arch tail)

Score scale per criterion: ✓ favored, ~ neutral, ✗ disfavored.
"Score" is a coarse rollup; rationale text is the load-bearing part.

| # | Criterion | A (amd64 only) | B (aarch64 only) | C (both) | Notes |
|---|-----------|----------------|------------------|----------|-------|
| 1 | **Build complexity** (cross-compile vs native) | ~ cross-build inside aarch64 <aarch64-builder> — `TARGET=amd64 TARGET_ARCH=amd64`; works but slower than native and more failure modes for kernel/world | ✓ native build; aarch64-on-aarch64 inside <aarch64-builder>; no TARGET swizzling | ~ adds a parallel cross step on top of B; same <aarch64-builder> substrate; two artifact paths but same Makefile.vm machinery | FreeBSD's release/ supports both; aarch64-native is the simpler path |
| 2 | **Test complexity** (HVF, qemu binary, accel) | ✗ amd64 guest on Apple Silicon = TCG only (no HVF); boot-to-login measured in TCG seconds will be 5–10× slower than the §8.2 budget assumes | ✓ aarch64 guest on Apple Silicon = HVF native — same path <aarch64-builder> already uses; `-accel hvf -cpu host` works | ~ needs both qemu binaries, both code paths; but both qemu binaries are present (verified absolute-path) | §8.2 of existing plan implicitly assumes KVM (`-accel kvm`); on <hypervisor-host> only HVF exists, and HVF accelerates aarch64 only |
| 3 | **Deploy fit** | ✓ Vultr amd64, generic x86 cloud, x86 laptops, x86 NUCs — broadest current x86 install base | ✓ Pi 5 (aarch64), RK3588 (aarch64), Vultr aarch64, Apple Silicon dev/test, fbrpi nodes, all existing fleet workers | ✓ covers everything; deploy fit is strictly the union | A misses Pi 5/RK3588; B misses x86 cloud + x86 laptops; only C covers everything |
| 4 | **Fleet alignment** (substrate + ansible patterns) | ~ adds an arch the fleet does not currently consume natively (every fbrpi/fbpi target is aarch64); ansible patterns (zig-cc, freebsd-pi, raspberry-pi) all assume aarch64 | ✓ aligns with every existing FreeBSD aarch64 build path: `freebsd-build-vm`, `zig-cc → aarch64-freebsd`, `gitea-release ...freebsd-aarch64` artifact naming, `fbrpi*` Pi inventory | ✓ A's gap closed; B's coverage retained | The fleet substrate is aarch64-native today; A introduces a "lonely arch" that no other tool consumes |
| 5 | **Time-to-first-boot** (TCG vs HVF on <hypervisor-host>) | ✗ amd64 under TCG: rough estimate 60–180s to login (vs §8.2's 30s budget); will likely fail acceptance §8.2 on the build/test host | ✓ aarch64 under HVF: 10–30s to login; clears §8.2 trivially; matches fb-vm-24's known boot times | ~ aarch64 leg passes §8.2 fast; amd64 leg either retests on a real x86 host (Vultr instance, Linux dev box) or accepts a TCG-relaxed §8.2 budget | This is the criterion that flips A's stated gates: the §8.2 budget was written assuming KVM, not TCG |
| 6 | **Spec footprint / churn** (changes vs current plan) | ✓ no churn; existing plan stays as-is | ✗ existing plan needs to be re-pointed (`amd64`→`aarch64`) in §1, §3.4, §4 path, §5 firmware, §7.2, §8.x QEMU lines, §10 — pervasive | ~ split-and-extend: extract a common §§1-3 base, add per-arch §§4-8 tails; the amd64 work is reused, not thrown away | C preserves the amd64 design effort already paid for |
| 7 | **License floor risk** | ✓ no new deps either way | ✓ no new deps either way | ✓ no new deps either way | All three options use the same FreeBSD release/ tooling, edk2 EFI firmware (BSD-2/MIT), QEMU (GPL-2 — but only as a tool, not linked into the artifact); no impact |
| 8 | **Risk of "lonely arch"** (the artifact is the only of its kind in the fleet) | ✗ amd64 smolBSD VM has no other amd64 consumer in the fleet today; debugging is a one-off | ~ aarch64 smolBSD VM rides the aarch64 fleet substrate; bugs caught here transfer to fbrpi/Pi work | ✓ both arches gain a baseline; future amd64 work (Vultr x86) has a path | This is criterion #4 sharpened — does the artifact compose with the rest of the fleet? |
| 9 | **Soft-signal weight** ("phase 1 = both RK3588 + Pi 5") | ✗ inconsistent with the signal | ✓ consistent (both targets are aarch64) | ✓ consistent (both targets are aarch64; amd64 added orthogonally) | Weighted as 1 vote, not a directive — per `feedback_no_projection.md`, the user has not explicitly confirmed it |

Score rollup (count of ✓ minus count of ✗, ignoring ~):

- A: 3 ✓ − 4 ✗ = **−1**
- B: 6 ✓ − 1 ✗ = **+5**
- C: 5 ✓ − 0 ✗ = **+5** (with the cost of more files/work)

---

## 2. Recommendation: **C — both, aarch64-first**

Phase I produces **both** amd64 and aarch64 baselines, but the **aarch64
leg ships first**, with amd64 as an explicit follow-on within Phase I
(not a separate phase).

**Rationale.** Three things drive this:

1. **HVF asymmetry is the deciding constraint.** The existing plan's §8
   acceptance gates (especially §8.2 time-to-login ≤ 30s) were written
   against KVM-class accel. On <hypervisor-host>, the only available accelerator
   is HVF, and HVF only accelerates the host's native ISA — aarch64.
   amd64 under TCG on Apple Silicon will not clear §8.2 reliably. So
   amd64-only (Option A) is at risk of failing its own gates **on its
   own build host**, before any deploy. aarch64-only (Option B) clears
   §8.2 trivially on the same host. Building a baseline whose own test
   gates fail in the build environment is muri.
2. **The fleet substrate is aarch64.** Every fbrpi node, every Pi 5 and
   RK3588 deploy target, the <aarch64-builder> VM itself, the `freebsd-pi` /
   `raspberry-pi` / `freebsd-build-vm` skills, and the artifact-naming
   convention (`...-freebsd-aarch64`) are all aarch64. An amd64 smolBSD
   image dropped into this substrate is a "lonely arch" with no
   other consumer to share debugging cost. The soft signal "phase 1 =
   both RK3588 + Pi 5" reinforces this even at the lowest weight.
3. **amd64 is not throwaway, it's just second.** Vultr offers native
   FreeBSD on amd64, and the existing PHASE-1-FORGE-TINY-BASELINE
   already specifies the amd64 cross-build path. That work is reused
   verbatim as the amd64 leg; nothing is discarded. Test on amd64 either
   uses a Vultr instance or moves the amd64 acceptance run to a Linux
   x86 host with KVM (out-of-scope for the build host but trivial for
   the test host).

**What "C — aarch64-first" looks like concretely:**

- Phase-I-A (ships first): smolBSD aarch64 VM, native build in <aarch64-builder>,
  HVF test on <hypervisor-host>, Pi 5 + RK3588 fit verified.
- Phase-I-B (same phase, ships second): smolBSD amd64 VM, cross-build
  in <aarch64-builder> with `TARGET=amd64`, test on a KVM-capable x86 host (Vultr
  instance or fleet x86 box), Vultr deploy verified.
- Both legs share §§1-3 (mission, package set, kernel-config strategy)
  and divulge into per-arch §§4-8 tails.
- Phase-I exit gate = both legs pass their respective measured-relics.

**Explicit RK3588 / Pi 5 fit**: aarch64 leg is directly bootable on
both. Caveat: a "VM image" is not a "Pi-bootable image" — the qcow2
artifact must be re-cast to a real-disk layout (`raw` + GPT + EFI + UFS
matching Pi firmware expectations) for Pi5/RK3588 deploy. That's a
**Phase-II** packaging step, not Phase-I; the Phase-I aarch64 baseline
is the *userland and kernel* the Pi image will carry, not a Pi image
yet. Calling this out so future readers don't expect `dd if=qcow2 of=/dev/sdX`
to work.

**Explicit Vultr fit**: Vultr supports custom-ISO upload, snapshot
import, and native FreeBSD images on **both** amd64 and aarch64.
Phase-I qcow2 → `qemu-img convert -O raw` → snapshot upload covers
both. No Linux-rescue trampoline needed (per
`user_cloud_vultr.md`).

---

## 3. Cost delta from current amd64-only plan

**Files affected** (paths relative to repo root):

| Path | Action | Reason |
|------|--------|--------|
| `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md` | refactor: extract §§1-3 as common, move §§4-8 into per-arch tails | Existing amd64 content becomes the amd64 leg's tail; aarch64 leg gets a sibling tail |
| `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE-AARCH64.md` | new sibling | Per-arch tail: kernel config under `sys/arm64/conf/SMOLBSD`, qemu-system-aarch64 launch, EDK2 aarch64 firmware, dtb handling |
| `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE-AMD64.md` | rename of current plan's §§4-8 tail | Per-arch tail; existing kernel-config delta + qemu-system-x86_64 launch live here |
| `plans/tinyos/PHASE-1-COMMON.md` (or §§1-3 left in BASELINE) | new (or in-place §§1-3) | Mission, package set, build-tool decision — arch-independent |
| `release/tools/smolfire-qemu-aarch64.conf` | new | aarch64 sibling to the existing `smolfire-qemu.conf` (renamed `smolfire-qemu-amd64.conf`) |
| `release/tools/smolfire-qemu-amd64.conf` | rename of `smolfire-qemu.conf` | Per-arch release config |
| `sys/arm64/conf/SMOLBSD` | new | aarch64 kernel config delta (parallel structure to amd64 SMOLBSD, but `nodevice` list differs — strip Pi/Apple/Raspberry physical drivers, keep `virtio*` + `vtnet`) |
| (existing) `sys/amd64/conf/SMOLBSD` | unchanged | Already specified in current plan §4.3 |
| `tests/time-to-ready-aarch64.exp` | new | qemu-system-aarch64 + HVF + edk2-aarch64 launch line |
| `tests/time-to-ready-amd64.exp` | rename of existing | qemu-system-x86_64 + accel-conditional (KVM if available, TCG otherwise) |

**Estimated time** (design + write + dispatch, NOT including build/run):

- Aarch64 kernel config delta (parallel to §4.3 amd64): **45 min**
  (the device list to strip is similar — drop Pi-specific physical
  drivers like `bcm2835_*`, keep virtio set; smaller delta than amd64
  because arm64/conf/GENERIC is already leaner).
- aarch64 release config sibling (smolfire-qemu-aarch64.conf): **15 min**
  (only the EFI firmware path + `vtnet` defaults differ).
- aarch64 qemu launch lines + HVF accel + EDK2 aarch64 firmware path
  for §8 tests: **30 min**.
- Plan refactor (extract §§1-3 common, two siblings): **45 min**.
- Per-arch acceptance gate audit (HVF vs KVM vs TCG implications for
  §8.2 budget on each arch): **30 min**.
- Total design-only delta: **~3 hours**, single subagent.

Build-time delta (not part of design): aarch64 native build on <aarch64-builder>
should be **faster** than amd64 cross-build (no cross-toolchain step).
Net build-time impact of going to "both" instead of just amd64:
roughly +60% wall clock on the build host, parallelizable.

---

## 4. Plan revision strategy: **split** (common base + per-arch tails)

**Choice:** *split*, not *edit-in-place* and not *sibling-only*.

Why split beats the alternatives:

- **Edit-in-place** would force every arch decision into one document,
  doubling the per-arch detail (kernel config, qemu launch, firmware,
  test commands) inline with `if amd64 ... if aarch64 ...` prose. The
  existing plan's §4.3 kernel config is already 130+ lines; adding a
  parallel aarch64 block doubles it and makes diffs noisy.
- **Sibling-only** (a separate `PHASE-1-FORGE-TINY-BASELINE-AARCH64.md`
  with everything duplicated) would force §1-§3 (mission, package set,
  build-tool decision) to be copy-pasted, which drifts. The package set
  and the choice of `release/Makefile.vm` are arch-independent and
  belong in exactly one place.
- **Split** keeps the arch-independent §§1-3 in one document, makes
  each arch's §§4-8 stand alone, and lets the two arches evolve at
  different velocities (aarch64 ships first; amd64 follows). It also
  composes with the existing Phase-I exit gate ("both legs pass
  measured-relics"), since each leg has its own measured-relics block.

**Concrete shape:**

```
plans/tinyos/
  PHASE-1-FORGE-TINY-BASELINE.md               # was: full plan
                                                # becomes: §§1-3 common
                                                # + a "see per-arch tail"
                                                # pointer for §§4-8
  PHASE-1-FORGE-TINY-BASELINE-AARCH64.md       # new: aarch64 §§4-8
  PHASE-1-FORGE-TINY-BASELINE-AMD64.md         # new: extracted amd64 §§4-8
  PHASE-1-ARCH-DECISION.md                     # this file
```

Phase-II/III/IV plans reference *the common base* + *one or both arch
tails* as needed.

---

## 5. Self-check

- [x] Decision matrix has ≥ 5 named criteria (this doc has 9): build
      complexity, test complexity, deploy fit, fleet alignment,
      time-to-first-boot, spec footprint/churn, license floor,
      lonely-arch risk, soft-signal weight.
- [x] Each criterion is scored A/B/C with rationale text.
- [x] Recommendation explicitly addresses RK3588 + Pi 5 fit (§2,
      "Explicit RK3588 / Pi 5 fit").
- [x] Recommendation explicitly addresses Vultr fit (§2,
      "Explicit Vultr fit").
- [x] Implementation cost delta is concrete: 9 named files + ~3 hours
      design-only time.
- [x] Plan revision strategy chosen with reasoning vs alternatives:
      *split*.
- [x] No tool-presence/absence claim relies on un-verified probing —
      every assertion in §0 is either absolute-path verified by the
      coordinator or pulled from a documented skill/spec/datasheet.
- [x] Soft signal "phase 1 = both" weighted, not treated as
      directive (§1 row 9 + §2 paragraph 2).
- [x] License floor preserved: edk2 (BSD-2/MIT), QEMU (tool-only,
      not linked), no new deps.

---

*Authored by researcher@smolbsd.local — task-0003a — 2026-04-30*
*In reply to coordinator@smolbsd.local message <task-0003a.coord@smolbsd.local>*
