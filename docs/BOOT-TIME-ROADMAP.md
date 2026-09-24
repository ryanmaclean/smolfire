# SMOLFIRE boot-time roadmap — 511 ms to sub-100 ms

> **2026-09-23:** §1 is now measured (TSLOG, run 35829303519); §2 re-ranked.
> TSC/lapic calibration (~259 ms) and console output (~126 ms) are ~80 % of the boot.
>
> **2026-09-24:** §2.2 landed via a guest-side patch (TSC frequency from the KVM
> pvclock — no Firecracker change needed): release wall clock median 476 → **240 ms**
> (run 35956015747; partly a faster host, see §2.2). Remaining big items: console
> output (§2.3), phantom UARTs (§2.4), lapic clockcalib (~17 ms).

Issue #39 items 3+4. Written 2026-08-23 against the round-2 SMOLFIRE state
(run 30409991192: `TIME_TO_READY=511ms` Firecracker v1.12.0 / 569 ms QEMU
microvm). Companion to `docs/UR-BSD-VERIFY.md` (SMOLFIRE section) and
`docs/RESEARCH-2026-07.md` §2. Read UR-BSD-VERIFY before touching
`sys/amd64/conf/SMOLFIRE` or `bin/build-smolfire.sh`.

## 1. Where the 511 ms goes — MEASURED (TSLOG, run 35829303519)

`TIME_TO_READY` is a **wall-clock expect-gate measure**: VMM process exec →
`SMOLFIRE_READY` on serial. TSLOG now splits it (§3 steps 1–3 done).

**Method.** `SMOLFIRE-TSLOG` kernel (`include SMOLFIRE` + `options TSLOG`),
TSLOG `/etc/rc` tail dumps `debug.tslog` + `debug.tslog_user` to serial
*after* READY (outside the measured window); `bin/tslog-phases.nu` pairs
ENTER/EXIT records and anchors the kernel clock to the wall clock with the
TSC stamp of the `/rescue/echo` that prints READY (KVM starts guest TSC at 0
on vCPU creation — checked per run: first record < wall READY).
**Environment.** GitHub-hosted `ubuntu-latest` x64 runner (nested KVM, AMD
host CPU, no CPUID TSC-frequency leaf), Firecracker v1.12.0, 1 vCPU,
512 MiB, TAP net + token-fetch gate armed (same `boot_args` as the gate);
guest TSC 2.445 GHz. **Run** <https://github.com/ryanmaclean/smolfire/actions/runs/35829303519>,
2026-09-23T06:58Z (2026-09-22 PDT). **n = 3** TSLOG boots + 3 release boots.
**Images** (the ELF is the whole OS): release `smolfire-kernel` sha256
`1fbf1963aceae06458a2c3a142d0960d9be6d79843d3af761e88cdaac791f302`; `smolfire-kernel-tslog` sha256
`981afa8eba60b3858effc2b592b84adb89ea4ba2610ffb5937281561c1960eac`. Raw logs + derived JSON:
[`docs/boot-time/2026-09-22/`](boot-time/2026-09-22/) (`tslog-run*.log`,
`release-run*.log`, `smolfire-tslog-phases.{json,txt}`).

| Phase | Boundary (TSLOG record) | median ms | min–max ms |
|---|---|---|---|
| VMM exec → vCPU start | wall(READY) − tsc(READY): Firecracker start, guest RAM, 37 MiB ELF load | 5 | 3.8–5.7 |
| vCPU start → kernel entry | TSC 0 → `ENTER hammer_time` (PVH entry) | 5.8 | 5.8–6.2 |
| Early kernel | `hammer_time` → `ENTER mi_startup` | 5.7 | 5.3–6.3 |
| **SYSINIT + devices** | `mi_startup` → `ENTER start_init` | **440.3** | 410.3–452.7 |
| ↳ TSC + lapic calibration | `DELAY` 100 ms in `tsc_freq_tc()` + `clockcalib` TSC + lapic (SYSINITs `cpu`, `clocks`) | ~259 (101.5 + 157.7) | 228–272 |
| ↳ kernel console printf | `_vprintf` self time, 106 calls, ~6.3 KB at ~20 µs/byte (nested-KVM port-I/O exits, not baud) | ~126 | 125.0–126.5 |
| ↳ uart probes | `DEVICE_PROBE uart` ×8: Firecracker's ACPI lists COM1–4, all four attach | ~31 | 30.7–32.0 |
| ↳ everything else | acpi attach (10 self), uma slabs (7), nexus (6), kvmclock (3), virtio_mmio (2) … | ~24 | — |
| Root mount | `vfs_mountroot` (MFS md0) | 2.6 | 2.4–2.7 |
| exec /sbin/init | rest of `start_init` | 0.5 | 0.5–0.5 |
| init + `/etc/rc` → READY | `EXIT start_init` → `/rescue/echo` exit: 9 fork+execs; `ifconfig vtnet0 inet … up` 10 ms, `fetch` 2 ms, rest ≤3 ms each | 33.1 | 30–34 |
| **Total, TSLOG kernel** | expect wall clock, VMM exec → READY | **494** | 464–501 |
| Total, release kernel (no TSLOG) | same harness, `release-run*.log` | 476 | 399–477 |

Same-run gate numbers: Firecracker gate `TIME_TO_READY=493ms` (NET_GATE +
HOST_PING pass), QEMU microvm 510 ms. TSLOG overhead ≈ 18 ms (494 vs 476
median). Off-critical-path waits (`_sleep`, ~65–75 ms summed across kernel
threads) overlap thread0 work and are not additive.

**What the data changes:** the estimate had the i8254 calibration in "early
kernel" at 50–150 ms and SYSINIT at 100–250 ms. In reality early kernel is
6 ms; the calibration runs later inside SYSINIT and is **~259 ms — over half
the boot**, and kernel console output is another ~126 ms. VMM + ELF load is
~11 ms (not 10–50), and init + rc is 33 ms (not 50–150).

<details>
<summary>Previous estimate (2026-08-23, unmeasured) — kept for comparison</summary>

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

</details>

### 1.1 aarch64 disk-image path (serial-timestamp, local HVF)

Different system, different method — **not** comparable with the table
above: the Phase-1 aarch64 VM image (`SMOLBSD` kernel, EDK2 → loader.efi →
UFS root → full `/etc/rc` → getty), measured wall clock with
`bin/boot-phases.nu` (serial line arrival, 10 ms poll; resolution ≈ ±20 ms).
**Environment:** MacBookPro18,4 (M1 Max, 10 cores), macOS 26.6.2, QEMU
10.2.1 `-machine virt,accel=hvf -cpu host`, edk2-stable202408, 256 MiB,
2 vCPU, SLIRP NIC, `snapshot=on`. Host was heavily loaded by other jobs
(load average ~250–330) — rc-phase variance below is mostly host noise.
**Image:** `build/FreeBSD-15-aarch64-smolbsd.qcow2` (sha256
`6d2a81cf448d596ac40a0e741eb76cfbc764193b413a7996126ff07379d0da3b`) → APFS clone after one clean ACPI
shutdown to clear its dirty-fs flag (sha256 `f7d560db57c0e9f9453a199841aaf436645b6023678f07068496d55fa7983b57`).
3 boots each, 2026-09-23 local; raw logs `aarch64-hvf-diskimage*-run*.log`.

| Phase | default: median ms | min–max | `splash-time=0`: median ms | min–max |
|---|---|---|---|---|
| Firmware (exec → loader banner) | 5,587 | 5,489–6,851 | 542 | 392–842 |
| Loader (→ `---<<BOOT>>---`) | 599 | 206–613 | 231 | 63–379 |
| Kernel (→ `Trying to mount root`) | 239 | 148–469 | 297 | 79–299 |
| Root mount → first rc line | 994 | 151–1,243 | 713 | 696–910 |
| rc → `login:` | 8,719 | 3,792–10,538 | 6,294 | 3,894–10,759 |
| **Total → `login:`** | **17,632** | 9,786–18,220 | **8,525** | 5,876–11,989 |

Findings: (1) **EDK2 waits ~5.1 s at the BDS boot-menu timeout** before
loading `BOOTAA64.EFI` on every boot (5.04–5.28 s gap after the last firmware line) — not PXE (a `-nic none` control keeps
it: firmware 5,351 ms median, 5,251–5,368). QEMU's `-boot menu=on,splash-time=0`
(fw_cfg `etc/boot-menu-wait`=0) removes it; the Phase-1 "11 s" figure
very likely carried this 5 s too. **Wired in (2026-09-23, `exp/a64-boot-menu`):**
`bin/qemu-smolfire-vm.nu` (aarch64 + HVF only; `--fw-menu-wait` opts out),
`bin/run-vm-tests.nu`, and both HVF gates `tests/time-to-ready-{aarch64,arm64}.exp`
(`SMOLFIRE_FW_MENU_WAIT=1` opts out; gates now also `snapshot=on`). Re-measured
A/B, interleaved, 3 boots each at load avg 186–290: firmware 6,756 → 1,152 ms
median. (2) rc dominates what remains: a
1.9–6.8 s gap between `Starting devd.` and `Starting dhclient.` — **now
attributed, §1.2** — then sshd config
check, sshd, cron (~0.3–0.7 s each). (3) An unclean previous shutdown adds a foreground fsck of
~3.4 s (`aarch64-hvf-diskimage-dirtyfs-run1.log`) — killed-VM gates should
use `snapshot=on`.

### 1.2 The `Starting devd.` → `Starting dhclient.` gap — ATTRIBUTED (2026-09-23)

**Method.** `tests/boot-gap-experiments.nu` (`prepare`/`run`/`analyze`):
`--base` is an APFS clone (`cp -c`) of the Phase-1 image, booted clean once
to clear the dirty-fs flag; each of 11 variants gets its own APFS-cloned,
one-time-configured qcow2 (`prepare`), then 3 interleaved boots each
(`run --runs 3`, `snapshot=on`, `-boot menu=on,splash-time=0`) through
`bin/boot-phases.nu`, serial-timestamped. Host was shared with other
concurrent jobs (load average 12→150 over the session — see the wide
min–max bands below); medians are reported precisely because of that noise.
Raw logs + per-boot JSON: `docs/boot-time/2026-09-23/aarch64-hvf-gap-*.log`.
Analysis: `nu tests/boot-gap-experiments.nu analyze --out-dir
docs/boot-time/2026-09-23` (schema `smolfire.boot-gap/v1`).

| Variant (one change from baseline) | devd→dhclient median ms (n=3, range) | login median ms (range) |
|---|---|---|
| baseline | 3,166 (2,516–6,004) | 10,739 (8,434–12,405) |
| a-dad0: `net.inet6.ip6.dad_count=0` + `net.inet.ip.dad_count=0` | 4,495 (2,916–6,909) | 13,937 (7,399–14,197) |
| b1-syncdhcp: `ifconfig_vtnet0="SYNCDHCP"` | n/a (dhclient starts *before* devd — see below) | 8,553 (7,078–9,521) |
| b2-bgdhclient: `background_dhclient="YES"` | 3,868 (2,457–6,922) | 11,429 (7,452–14,953) |
| c-nodevd: `devd_enable="NO"` | n/a (no devd, no `Starting dhclient.` line) | **37,650** (35,373–44,145) |
| d-rcdebug: `rc_debug="YES"` | 9,507 (6,910–12,615) | 23,502 (17,986–31,570) |
| e-nousb: `-machine usb=off` | 4,010 (3,892–10,920) | 13,835 (9,129–22,377) |
| f-devd-n: `devd_flags="-n"` | n/a (no `Starting dhclient.` line, 3/3 boots) | 8,878 (5,442–23,695) |
| g-nodevmatch: `devmatch_enable="NO"` | 2,800 (1,582–7,142) | 7,009 (3,774–18,088) |
| h-nomatch-mmio: devd.conf `nomatch` policy for `_HID "LNRO0005"` | 993 (990–1,678) | 6,609 (4,343–15,450) |
| **i-nomatch-tunable: `hw.bus.devctl_nomatch_enabled="0"`** | **329 (257–1,401)** | **4,827 (1,680–14,217)** |

**Attribution.** `d-rcdebug`'s `rc_debug=YES` trace places the cause
precisely: once `/etc/rc.d/dhclient`'s `run_rc_command` actually fires,
`dhclient_prestart` → `Starting dhclient.` takes ~100 ms — dhclient itself
is not slow. What *is* slow, filling the gap, is `/etc/rc.d/devmatch`
being invoked over and over — `DEBUG: run_rc_command: doit: devmatch_start`
recurs roughly every 150–400 ms, back to back, for more than a dozen
iterations in the same trace. `/etc/devd/devmatch.conf` (base FreeBSD)
wires a `notify` action (`/etc/rc.d/devmatch quietstart`, one `/bin/sh`
fork+exec + `rc.subr`/`rc.conf` resourcing per event) to every DEVFS
`CREATE`, and a `nomatch` action (`kldload -n $pnpinfo`, another fork+exec)
to every unmatched device. `/etc/rc.d/dhclient` `REQUIRE`s `devd`, and rc.d
scripts run strictly serially, so dhclient cannot start until `devd`'s own
start action returns — and that action must first replay devd's queued
cold-plug backlog of these per-event shell actions. On this image (QEMU
`virt` + EDK2 ACPI), that backlog is inflated by spurious/duplicate ACPI
child nodes with no matching driver (the `h`/`i` experiments target exactly
this: `_HID "LNRO0005"` is one such node). The four variants that touch
different layers of this pipeline show effect sizes that line up with the
theory: `i` (kill NOMATCH events at the kernel, so neither the `kldload`
nomatch action nor most of the coldplug DEVFS churn happens) removes ~90 %
of the gap; `h` (devd.conf policy silencing nomatch for just that one HID)
removes ~69 %; `g` (`devmatch_enable=NO`, which only short-circuits
`devmatch_start`'s payload *after* the fork+exec has already happened)
removes only ~12 %; and `c` (no devd at all) does not skip the wait, it
relocates and enlarges it — FreeBSD's `/etc/rc` falls back to its
~30 s device-wait timeout elsewhere, so total boot gets **3.5× worse**, not
better. `a-dad0` (the mechanism a prior NetBSD investigation attributed a
similar-looking gap to) shows no improvement on this image — duplicate
address detection is not implicated here. `b1-syncdhcp` corroborates the
model from a different angle: `SYNCDHCP` makes `/etc/rc.d/netif` invoke
`dhclient` synchronously and directly, bypassing the standalone
`/etc/rc.d/dhclient` service (and its `REQUIRE: devd`) entirely — in that
variant's logs `Starting dhclient.` sometimes prints *before*
`Starting devd.`, which is only possible if dhclient is not gated on devd
in that path.

**Fix applied:** `hw.bus.devctl_nomatch_enabled="0"` added to
`release/tools/smolfire-qemu-aarch64.conf`'s `loader.conf` heredoc — a
one-line, kernel-level tunable, no devd.conf changes needed, the largest and
most reproducible effect of the 9 variants tested. Not applied: disabling
devd (`c`, regresses hard), `rc_debug` (diagnostic only, not a fix),
`-machine usb=off` (`e`, no significant effect — USB was not implicated on
this board). `f-devd-n`'s dropped `Starting dhclient.` line in all 3 boots
is unexplained and out of scope here; flagged for follow-up, not relied on
for the fix.

**Caveat:** the host ran other concurrent jobs throughout (load average
12→150); absolute medians should be treated as ballpark, but the *relative*
ranking across variants — reproduced over 3 interleaved-per-round boots
each, on the same noisy host — is the load-bearing evidence, not any single
absolute number.

### 1.3 aarch64 TSLOG (HVF, kernel-internal, measured)

Issue #39 item 4 continuation: §1.1 above is wall-clock only (serial line
arrival); this section is the kernel-internal TSLOG counterpart, filling
the "No aarch64 `SMOLFIRE-VM-TSLOG` hosted build" gap PR #55 left open. The
hosted `SMOLFIRE-VM-TSLOG` kernel now exists
(<https://github.com/ryanmaclean/smolfire/actions/runs/35835055263>,
`smolfire-aarch64-kernel-SMOLFIRE-VM-TSLOG` artifact) and was measured
against the Phase-1 disk image, not the crunched SMOLFIRE microVM — so this
extends `bin/tslog-phases.nu` (written for the amd64 Firecracker leg in
PR #55) to a full FreeBSD boot for the first time.

**Environment:** MacBookPro18,4 (Apple M1 Max), macOS 26.6.2, QEMU 10.2.1
`-machine virt,accel=hvf -cpu host`, EDK2 aarch64 firmware, 256 MiB, 2 vCPU,
SLIRP NIC with `hostfwd` for SSH, `-boot menu=on,splash-time=0` (§1.1
finding 1). Image: an APFS clone (`cp -c`, original untouched) of
`build/FreeBSD-15-aarch64-smolbsd.qcow2`, truncated sha256 `6d2a8...da3b`
(full digest intentionally not recorded — see `docs/boot-time/2026-09-23/aarch64/README.md`).
Unlike §1.1, this clone was **not** booted with `snapshot=on`: the setup
boot installed the TSLOG kernel at `/boot/kernel.tslog/` (4 modules),
set `loader.conf` `kernel="kernel.tslog"`, and added
`hw.bus.devctl_nomatch_enabled="0"` (PR #82's devd→dhclient fix, applied
here so this leg's rc phase already reflects it even though #82 was still
open at measurement time) — those writes had to persist across the 3
measurement reboots. n=3, raw dumps and methodology notes in
`docs/boot-time/2026-09-23/aarch64/`.

| Phase | median (ms) | min–max (ms) |
|---|---|---|
| VMM exec → vCPU (cross-clock stitch — noisy, see caveats) | 166.3 | -53.6–223.9 |
| vCPU → kernel entry (`hammer_time`) | 289.2 | 222.0–1,049.2 |
| Early kernel (→ `mi_startup`) | 451.0 | 69.1–1,067.1 |
| SYSINIT + devices (→ `start_init`) | 369.2 | 64.6–444.9 |
| Root mount | 172.1 | 26.5–269.0 |
| `start_init` other (excl. mount) | 4.2 | 2.3–9.7 |
| init + `/etc/rc` → `login:` | 5,663.5 | 1,658.4–6,477.5 |
| **Wall, TSLOG kernel (exec → `login:`)** | **7,812.0** | 2,209.0–8,625.0 |
| Kernel-internal only (first TSLOG record → READY) | 7,351.9 | 1,820.8–7,576.3 |

Generated with `nu bin/tslog-phases.nu --dir docs/boot-time/2026-09-23/aarch64 --md`
(read-only use of the unmodified PR #55 tool); full JSON in
`docs/boot-time/2026-09-23/aarch64/tslog-phases.json`.

**Caveats** (see the dataset README for the full explanation): this image's
rc has no built-in `SMOLFIRE_READY` gate, so `TIME_TO_READY` is stitched
from the serial `login:` timestamp (host wall clock) and a separate SSH
`/bin/echo` anchor (TSC clock) — good enough for the *sum* (`wall_to_ready`)
but it makes the pre-kernel split noisy, visible as the -53.6 ms minimum on
`VMM exec → vCPU`. Host load also varied a lot between runs (run 1: 2.2 s
to login; runs 2–3: 7.8–8.6 s), same noise §1.1 already flagged.

**Re-ranked aarch64 candidates:** rc still dominates (`init + /etc/rc →
login:` is 5.7 s of a 7.8 s median boot, ~73%) even with PR #82's fix
applied — confirming §1.1 finding (2) rather than replacing it; the
devd→dhclient stall PR #82 targets is one contributor among several rc
steps (sshd keygen check, cron, background-fsck scheduling), so (1) further
rc slimming — a custom init in the spirit of §2.5's Firecracker plan, or at
minimum trimming `/etc/rc.d` script count — now outranks (2) firmware/EDK2
work (§1.1's 5 s BDS wait is already fixed by `splash-time=0`, and this
run's `VMM exec → vCPU` + `vCPU → kernel entry` together are only
~0.2–1.3 s of measurement noise, not a real optimization target); (3)
`early_kernel` + `sysinit_devices` (~450 + 370 ms median) is a new,
previously-unattributed cost worth a follow-up TSLOG `top_self_by_name`
pass (`docs/boot-time/2026-09-23/aarch64/tslog-phases.json`) before ranking
it against rc-slimming.

## 2. Ranked candidate reductions — re-ranked on measured data

Ranked by measured removable time ÷ effort (SMOLFIRE / Firecracker, §1).
Re-run the TSLOG build after each accepted change (`gh workflow run
smolfire.yml -f tslog=true`, then `nu bin/tslog-phases.nu --dir <artifacts>`).

### 2.1 Measure before optimizing — TSLOG (DONE, 2026-09-23)

`sys/amd64/conf/SMOLFIRE-TSLOG` + `SMOLFIRE_TSLOG=1` in
`bin/build-smolfire.sh` + `smolfire.yml` `tslog` input + `bin/tslog-phases.nu`.

### 2.2 Skip TSC + lapic calibration via CPUID 0x40000010 (effort: S–M, measured ~259 ms removable — was "20–100 ms")

**DONE for the TSC (2026-09-24) — by a different route than planned below.**
Instead of waiting for a VMM to publish 0x40000010, the guest takes the TSC
frequency from the KVM pvclock scale (the value Linux's `kvm_get_tsc_khz()`
trusts): `docs/upstream/tsc-kvmclock-freq.{patch,md}`, applied by
`bin/build-smolfire.sh`, guarded by `tests/tsc-kvmclock-patch-test.nu`.
Measured, TSLOG run 35956015747 (n=3): `DELAY` 101.5 → 1.3 ms; `clockcalib`
170 ms / 2 calls → 17 ms / 1 call (lapic only); SYSINIT `cpu` 143.6 → 30.1 ms,
`clocks` 160.1 → 60.2 ms; `machdep.tsc_freq` = 2,596,122,000 Hz on every boot,
within ~50 ppm of the 2596.25 MHz the stock, calibrating GENERIC build VM
measured on the same runner. Release wall clock median 476 → 240 ms (228–247); QEMU microvm
510 → 263–304 ms; Firecracker gate 314 ms (push run 35955999089; the dispatch
run's single cold gate boot read 534 ms). **Host caveat:** this runner was a
2.596 GHz EPYC 9V74 vs 2.446 GHz for the baseline, and untouched `_vprintf`
also fell 126 → 78 ms, so the attributable saving is the removed DELAY +
TSC clockcalib (≈ 250 ms of thread0), not the whole wall-clock drop. Data:
[`docs/boot-time/2026-09-24-tsc-kvmclock/`](boot-time/2026-09-24-tsc-kvmclock/).
Still open from this item: the lapic `clockcalib` (KVM's APIC bus rate is
not guest-discoverable without 0x40000010), and dropping
`machdep.disable_tsc_calibration=0` from `boot_args` (harmless now — the
pvclock path runs first; kept as the non-KVM fallback).

Original plan (kept for the record):

Measured: `tsc_freq_tc()` spins a flat `DELAY(100000)` against the i8254
(`probe_tsc_freq_late`, sys/x86/x86/tsc.c), then `tsc_calibrate()` runs
`clockcalib()` for another 126–170 ms, and the lapic timer gets its own
~11 ms `clockcalib`. All three are skipped when the hypervisor CPUID leaf
0x40000010 is present: `tsc_freq_cpuid_vm()` sets `tsc_early_calib_exact`
(no PIT DELAY, no late clockcalib) and `lapic_calibrate_initcount_cpuid_vm()`
reads the lapic kHz from EBX. Our AMD-host runners give no leaf 0x15 and
Firecracker v1.12 does not publish 0x40000010, hence the
`machdep.disable_tsc_calibration=0` override (ledger #4). Actions, in order:
(a) prove the saving on the QEMU microvm leg first with
`-cpu host,+invtsc,vmware-cpuid-freq=on` (QEMU publishes 0x40000010 when the
TSC rate is known) — expect ~494 → ~235 ms; (b) Firecracker: check upstream
for 0x40000010 support (Percival's Firecracker-side change,
[USENIX ;login:](https://www.usenix.org/publications/loginonline/freebsd-firecracker)),
else a CPU template / patched binary in CI; (c) once the leaf is present, drop
the `disable_tsc_calibration=0` boot_arg. Ledger constraint stands:
`machdep.tsc_freq` is RW-only, not a tunable.

### 2.3 Cut kernel console output (effort: S, measured ~126 ms)

Measured: `_vprintf` holds ~126 ms of self time for ~6.3 KB of boot
messages (≈20 µs/byte: each byte is a port-I/O exit to Firecracker under
nested KVM; the 9600-baud setting is not the limiter). Options: `boot_mute=YES`
in `boot_args` (PVH cmdline → `boot_env_to_howto` → RB_MUTE) — **verify a
panic still prints** before adopting, the gates match on panic text; or trim
the chatter (CPU feature dump, per-device lines, copyright/trademark SYSINITs
`version`/`announce`/`trademark` ≈ 21 ms of it).

### 2.4 Disable the phantom COM2–4 (effort: S, measured ~23 ms)

Measured: Firecracker's ACPI tables list COM1–4; `uart0`–`uart3` all probe
and attach, ~7.7 ms per probe ("UART FCR is broken" FIFO probing). Only
`uart0` exists. Try `hint.uart.1.disabled=1 hint.uart.2.disabled=1
hint.uart.3.disabled=1` in `boot_args` (or the conf); keeps the console.

### 2.5 Slim the rc path / custom init (effort: S–M, measured ≤ ~25 ms — was "30–100 ms")

Measured init + rc → READY = 33 ms with 9 fork+execs; the only big one is
`ifconfig vtnet0 inet … up` (10 ms, driver work, not exec). hostname / lo0 /
kenv ×3 / route are 0.4–1.1 ms each, fetch 2.2 ms. A custom static init saves
the ~8 exec costs and `sh` startup — worth doing after §2.2–2.4, not before.
Keep the `SMOLFIRE_READY` + interactive-shell contract and
`tests/smolfire-rootfs-test.nu` in sync.

### 2.6 Audit remaining probe/alloc costs (effort: M, measured ~24 ms)

What is left of SYSINIT after §2.2–2.4: acpi attach (~10 ms self),
`keg_alloc_slab` (~7 ms over 1,694 calls), nexus (~6), kvmclock (~3),
virtio_mmio (~2). Percival's `nswbuf`-class sizing fixes are candidates here;
check each against releng/15.0 and track cherry-picks in `docs/upstream/`.

### 2.7 Shrink the ELF (effort: M, measured ≤ ~5 ms — was "10–40 ms")

Measured: VMM exec → vCPU start (which includes loading the 37 MiB ELF) is
3.8–5.7 ms, and vCPU → kernel entry 5.8 ms. ELF size is not a boot-time
lever; pursue it for size reasons only. Do not gzip (PVH wants a plain ELF).

### 2.8 Gate-harness honesty (partly DONE)

The §1 split now separates VMM start from guest boot and reports wall-clock
next to kernel-internal numbers. Remaining: emit the TSLOG phase JSON as a
CI step summary on every `tslog=true` run (needs `nu` on the runner).

**Projected:** 476 ms (release median) − 259 − ~100 (console) − 23 ≈ **~95 ms**,
i.e. §2.2–2.4 alone plausibly reach the ≤100 ms exit criterion; §2.5–2.6 are
margin. Every step still needs its own measured delta.

## 3. Measurement plan — TSLOG on the hosted runner

TSLOG is Percival's timestamp framework for exactly this job: it traces from
early kernel entry (where DTrace cannot run) through device attach into
userland, dumped post-boot via the `debug.tslog` sysctl and rendered as a
flame chart ([tslog(9)](https://man.freebsd.org/cgi/man.cgi?query=tslog),
[BSDCan 2018 paper](https://papers.freebsd.org/2018/bsdcan/percival-profiling_the_freebsd_kernel_boot/),
[cperciva/freebsd-boot-profiling](https://github.com/cperciva/freebsd-boot-profiling)).
It drove FreeBSD's ~30 s → ~9 s (2017→2022) and the Firecracker work.

Plan (one CI cycle on the existing `smolfire.yml` hosted-runner pipeline):

1. **DONE** — `sys/amd64/conf/SMOLFIRE-TSLOG`: `include SMOLFIRE` +
   `options TSLOG` + `options TSLOGSIZE=262144` (the real option name —
   `TSLOG_PAGES` does not exist; a SMOLFIRE boot logs ~9,100 records, so the
   default has ~29× headroom). Never ships in the release ELF — TSLOG costs
   ~18 ms.
2. **DONE** — TSLOG `/etc/rc` tail (`SMOLFIRE_TSLOG=1` only): READY via
   `/rescue/echo`, then `debug.tslog` + filtered `debug.tslog_user` to serial
   *after* READY (dumping before READY would distort the measured window).
3. **DONE (table, no flame chart)** — `bin/tslog-phases.nu` (Nushell,
   Apache-2.0). cperciva/freebsd-boot-profiling was not used: the repo has
   no license and its `flamechart.pl` derives from CDDL FlameGraph, both
   outside the project's license policy.
4. **DONE (first pass)** — Land the phase table in §1 as measured numbers, re-rank §2, and re-run
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

**Status:** the experiment's tool has landed as an opt-in executor —
`bin/jail-execute.nu`, selected with `SMOLFIRE_EXECUTOR=jail` (default stays
`vm`). Scope, security boundaries and the real-host verification checklist:
`docs/JAIL-EXECUTOR.md`.

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
