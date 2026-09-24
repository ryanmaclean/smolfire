# ur-BSD — verification runbook for the next FreeBSD build host session

Companion to `docs/UR-BSD.md`. This is the plan to execute **when a FreeBSD 15
build host is available again** (<aarch64-builder> for aarch64; a Linux/KVM x86 host for
amd64). It records what was changed in PR #31 (branch
`claude/ur-bsd-26-qnmjho` at the time; read this doc from main), what was
verified without a build, and the ordered steps to validate — including one
likely latent bug that must be confirmed before trusting the build scripts.

## State of the branch

The ur-bsd changes merged via PR #30 + the fixes below. All changes are repo-side;
**none have been run on a FreeBSD host.** The Linux container this work was done
in cannot build a FreeBSD image.

| Change | File(s) | Verified? |
|---|---|---|
| `MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` | `sys/{arm64,amd64}/conf/SMOLFIRE-VM` | Logic reviewed against `releng/15.0` |
| `options FFS` added (amd64 only) | `sys/amd64/conf/SMOLFIRE-VM` | **Required fix — see Finding 2** |
| `VMSIZE`/`SWAPSIZE` respect caller (`${VMSIZE:-2g}`) | `release/tools/smolfire-qemu*.conf` | Mechanism verified TRUE |
| pkgbase filter: grep replaced by explicit leaf-package list (FIX-10) | `release/tools/smolfire-qemu*.conf` | Names verified vs pkg.freebsd.org 15 catalogs; see Finding 4 |
| size-trim widened (firmware, rescue, clang, share/*, etcupdate) | `release/tools/smolfire-qemu*.conf` | Safe `rm -rf` with DESTDIR guard |
| in-VM make `VMSIZE=2g` (was 4g) | `bin/build-smolfire-vm-image.nu` | — |

## Findings from source review (releng/15.0)

### Finding 1 — VMSIZE override was a real bug; the fix is correct (VERIFIED)
In `release/scripts/mk-vmimage.sh`, `-s <size>` is parsed by `getopts` into the
shell var `VMSIZE`, then the conf is sourced (`. "${VMCONFIG}"`) *before* VMSIZE
is consumed in `vm_create_disk()` (`vmimage.subr`, `MAKEFSARGS="-s ${VMSIZE} -D"`).
An unconditional `export VMSIZE=4g` in the conf therefore clobbered the
command-line `2g`. The fix `export VMSIZE="${VMSIZE:-2g}"` preserves the
caller's value. Correct, not a no-op, not harmful.

### Finding 2 — amd64 MODULES_OVERRIDE would panic at mountroot (FIXED HERE)
`sys/amd64/conf/SMOLFIRE-VM` does `include MINIMAL`, and **amd64 MINIMAL ships
UFS/FFS as a loadable module (`ufs.ko`), not compiled in.** With
`MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"` stripping the module set and no
`ufs_load="YES"` in loader.conf, the kernel could not mount its UFS root →
mountroot panic. **Fix applied:** added `options FFS` to the amd64 kernconf.
arm64 is unaffected — `std.arm64` already compiles `options FFS` in.
(virtio/vtnet/ahci/nvme are statically compiled in both arches — confirmed — so
the device side is fine; only the filesystem driver was the gap.)

Same class, second instance (found in review): `vmimage.subr` appends a
`/dev/gpt/efiboot0 /boot/efi msdosfs` line to fstab AFTER `vm_extra_pre_umount`
runs, and amd64 MINIMAL has no `options MSDOSFS` — with the module set
stripped, `mount -a` fails at boot and rc drops to single-user. Fixed by
adding `options MSDOSFS` to the amd64 kernconf (arm64 has it via std.arm64).

The four override modules (tmpfs/nullfs/fdescfs/procfs) are not actually needed
to reach login (no fstab mounts them), but are cheap, conservative insurance.

### Finding 3 — the build scripts never sourced the conf (CONFIRMED — FIX-9 applied)
`make -C /usr/src/release vm-image ... CLOUDWARE_CONF=<conf>` — the old
invocation in `bin/build-smolfire-vm.nu` and `bin/build-smolfire-vm-image.nu` — did
**not** source the conf:
- `CLOUDWARE_CONF` is not a real variable in `release/Makefile.vm`; the
  per-type variable is `${TYPE}CONF` (`SMOLFIRECONF` for `CLOUDWARE=smolfire`).
- Only `cw-*` cloudware targets pass `-c <conf>` to `mk-vmimage.sh`. The plain
  `vm-image` target passes no `-c`, and its recipe is gated behind
  `WITH_VMIMAGES` (without it the recipe is a no-op `touch`).
- Consequence: `vm_extra_pre_umount()` (SSH keygen + size-trim) and
  `vm_extra_filter_base_packages()` stayed as no-op prototypes via this path.

Confirmation came from the repo's own history, not just the mirror review: the
`.planning/phases/03-*` records and `.github/workflows/build-image.yml` show the
prior self-hosted CI builds succeeded with `cloudware-release` + `CLOUDWARE=smolfire` +
`SMOLFIRE_FORMAT=qcow2 SMOLFIRE_FSLIST=ufs` (generating `cw-smolfire-ufs-qcow2`,
artifact at `<objdir>/usr/src/release/vm.ufs.qcow2`) — while still passing the
fake `CLOUDWARE_CONF`, meaning even those builds never sourced the conf. And
`PHASE-1-RESULTS.md` records the Phase-1 aarch64 image was created **manually**
(`makefs` + `mkimg`), so the scripted path was never validated end-to-end.

**FIX-9 (applied on this branch):** all build invocations now use
`cloudware-release` with `WITH_CLOUDWARE=yes CLOUDWARE=smolfire
SMOLFIRECONF=<conf> SMOLFIRE_FORMAT=<fmt> SMOLFIRE_FSLIST=ufs`, in:
`bin/build-smolfire-vm.nu` (+ `find_qcow2` objdir-root candidates),
`bin/build-smolfire-vm-image.nu`, `.github/workflows/build-image.yml`
(`CLOUDWARE_CONF` → `SMOLFIRECONF`), `bin/harvest.sh` (remote paths, now
env-overridable), the four conf headers, README/BUILDING docs.

### Finding 4 — the pkgbase grep filter was structurally a no-op (FIX-10 applied)
Verified against `releng/15.0` `vmimage.subr` and the official
`pkg.freebsd.org FreeBSD:15 base_release_0` catalogs (496 pkgs): the stock flow
passes only the `FreeBSD-set-*` meta names through
`vm_extra_filter_base_packages()` — on releng/15.0 for amd64/aarch64 that is
six: base, kernels, lib32, each with a `-dbg` twin (`vm_base_packages_list`,
vmimage.subr:73–87) — then `pkg install -r FreeBSD-base $selected` pulls each
surviving set's full dependency closure. `grep -v` of individual names can
never exclude a set dependency — the old filter silently shipped clang
(~220M), zfs, dtrace, rescue, wpa/ppp/wifi-firmware, and the tests packages
via set dependencies. ZFS userland is fully confined to `FreeBSD-zfs*`
packages, but the surviving sets hard-depend on them, so only an explicit
package list excludes it.

**FIX-10 (applied on this branch):** both QEMU confs now emit an explicit
leaf-package list (kernel set, bootloader, clibs/runtime/rc/utilities, ufs,
geom, ssh, dhclient, resolvconf, syslogd/newsyslog/cron/devd,
caroot/certctl/pkg-bootstrap, vi); pkg resolves required libraries as
dependencies. The custom-KERNCONF risk is RETIRED: `release/packages/
create-sets.sh` builds set membership dynamically from the `set` annotations
of the packages actually present in the repo, so a `KERNCONF=SMOLFIRE-VM` build
yields a `FreeBSD-set-kernels` depending on the SMOLFIRE-VM kernel package.
Remaining watch item on first build: confirm sshd's kerberos/GSSAPI libs
arrive as declared dependencies of `FreeBSD-ssh` (expected; check
`ldd /usr/sbin/sshd` in the image). The pi5/rk3588 confs were left on the old
filter deliberately (boards need `FreeBSD-dtb`; fix separately once the VM
path is proven).

## Assumptions retired (verification pass against releng/15.0 sources)

Every FIX-9/FIX-10 assumption was checked directly against
`raw.githubusercontent.com/freebsd/freebsd-src/releng/15.0`:

| Assumption | Verdict | Action taken |
|---|---|---|
| `cloudware-release` exists and needs `WITH_CLOUDWARE` + non-empty `CLOUDWARE` | TRUE (Makefile.vm:112, 307–311; empty target otherwise) | We pass both; also added `WITH_CLOUDWARE=yes` to build-image.yml |
| Per-type conf var is `SMOLFIRECONF`; must be passed explicitly | TRUE (`${_CW:tu}CONF`; auto-default only if `tools/smolfire.conf` exists — it doesn't) | Passed explicitly everywhere |
| `-s ${VMSIZE}` / `SWAPSIZE` reach mk-vmimage on the cw path | TRUE (Makefile.vm:141, 156) | Conf `${VMSIZE:-2g}` pattern correct as-is |
| Artifact basename | `smolfire.ufs.qcow2` in release objdir root (`${_CW:tl}.${_FS}.${_FMT}`, Makefile.vm:124) — `vm.ufs.qcow2` seen in prior self-hosted CI runs is that tree's stable/15 naming | harvest.sh default updated; workflow ls/scp made glob-tolerant; find_qcow2 already globs |
| `WITH_PKGBASE=yes` selects pkgbase | FALSE — no such release variable; pkgbase is the DEFAULT, `NOPKGBASE=yes` opts out (vmimage.subr:98) | Removed from all invocations and headers |
| cw target self-builds the pkgbase repo | TRUE — depends on `pkgbase-repo-dir` → `make -C /usr/src packages` (release/Makefile:218–229), which requires buildworld | Added the missing buildworld step to `bin/build-smolfire-vm-image.nu` |
| `FreeBSD-set-kernels` works with custom KERNCONF | TRUE — sets are generated from package `set` annotations at repo-build time (create-sets.sh) | Watch item removed |
| Workflow header "NOPKGBASE skips tpm2-tools" | FALSE — `vm_extra_install_packages` chroot-installs `VM_EXTRA_PACKAGES` regardless of NOPKGBASE (only `WITHOUT_QEMU` skips it, vmimage.subr:205–247) | Header corrected; `NOPKGBASE=yes` kept in the proven pipeline |
| Conf-provided builds get DHCP/growfs defaults | N/A — `vm_extra_enable_services` adds `ifconfig_DEFAULT`/`growfs_enable` only when NO conf is passed (vmimage.subr:195–201); our conf sets `ifconfig_vtnet0="DHCP"` itself | No change needed (noted so nobody "fixes" it) |
| D-02: "SLIRP has no outbound internet at test time" → pre-bake tpm2-tools | FALSE for hosted runners — `.planning` 03-CONTEXT.md itself records a successful in-guest `pkg install tpm2-tools` over SLIRP (HTTP/HTTPS work; only ICMP doesn't), and run #6's boot gate shows dhclient DHCPACK | tpm2-tools evicted from the image (~15–30 MiB closure); tpm-hosted.yml installs it in-guest at test time, with a skip-if-present guard for pre-eviction artifacts |

## Image diet round 1 — VALIDATED: run #7 GREEN (2026-07-24)

**Run 30109365470, commit 0039c7c: raw 91 MiB (was 223 MiB), compressed
33 MiB shipped, boot gate TIME_TO_LOGIN=9s on the compressed image.**
Compress-step evidence: `raw_bytes=95682560 compressed_bytes=34275328`,
`qemu-img check` clean, `qemu-img compare` "Images are identical"; size
gate PASS at 32 MiB. The trims alone (pkg repo catalogs, tpm2-tools
closure, kernel symbols, static libs) cut ~130 MiB of raw — far above the
~35–60 MiB estimate, mostly the previously-unmeasured `/var/db/pkg/repos`
catalogs. The original sub-100 MiB raw target is MET; the download is
33 MB. The auto-chained TPM run (30122923572) went red exactly as
predicted pre-merge (main's copy predates the eviction — not a
regression; resolves on merge). The SIZEREPORT block is in the run's
`smolfire-build-vm.log` artifact — parse with `nu bin/sizereport.nu` for
round-2 targeting. To publish: dispatch "Release smolfire Image" with
run_id 30109365470.

Changes shipped together, validated by the run above:

1. **qcow2 compression on the runner** (`qemu-img convert -c`, default zlib —
   zstd would require qemu ≥ 5.1 in every consumer). The size gate, boot
   gate, and artifact now all use the compressed file; `qemu-img check` +
   `qemu-img compare` guard the replacement. **Raw bytes stay printed every
   run** — the size trend in this file and PHASE-1-RESULTS.md is tracked in
   raw bytes, and compression must not mask raw-image growth. Expected:
   ~100–130 MiB compressed from 223 MiB raw (run #6's 87 MB artifact zip
   proved ~2.5× whole-file deflate; per-cluster compression is slightly
   worse).
2. **tpm2-tools eviction** (D-02 retirement above).
3. **New trims**: `/boot/kernel/*.symbols|*.debug` (belt+braces, expected
   ~0), `/var/db/pkg/repos` + `repo-*.sqlite` (catalogs are re-fetchable;
   `local.sqlite` kept), recursive `/usr/lib` `*.a` sweep.
4. **SIZEREPORT instrumentation** at the end of `vm_extra_pre_umount`:
   du/largest-files/pkg-by-size printed into the in-VM make log
   (`smolfire-build-vm.log` artifact); parse with `nu bin/sizereport.nu
   smolfire-build-vm.log` (or raw: `grep '^SIZEREPORT:'`). This is
   the ground truth for round 2 (FreeBSD-utilities file-level cuts — the
   ~48 MiB grab-bag leaf with no narrower official replacement on pkgbase).

Deferred to later rounds (in rough value order): FreeBSD-utilities diet,
`WITHOUT_KERBEROS`-class src.conf knobs (blocked on the sshd/GSSAPI ldd
check above), dropping FreeBSD-vi, direct kernel boot dropping ESP+loader
(~35–40 MiB, the docs/UR-BSD.md next phase).

## SMOLFIRE: rump-style one-ELF microVM — GREEN (2026-07-28, run 30393485718)

**The entire OS is one 37 MiB PVH ELF (kernel + static /rescue userland
as embedded MFS root) booting to an interactive shell in
`TIME_TO_READY=543ms` under Firecracker v1.12.0 and 476ms under QEMU
microvm — with the WITNESS debug checker still enabled.** Build:
kernel-toolchain + buildkernel only, ~25 min/cycle, no buildworld, no
pkgbase (the FreeBSD-utilities problem is sidestepped by construction).
Pieces: sys/amd64/conf/SMOLFIRE (include FIRECRACKER + TMPFS),
bin/build-smolfire.sh (rescue rootfs, MFS_IMAGE embed, pv.c patch),
smolfire.yml (build + dual-VMM boot gates + interactive-shell proof),
tests/smolfire-rootfs-test.nu (init(8) contract, in ci.yml).

Eight-run debugging ledger (every layer was the FIRECRACKER conf's EC2
assumptions vs nested-KVM runners — full evidence in the run logs):
1. Firecracker < v1.12.0 has no PVH (merged in PR #5048) → instant
   KVM_EXIT_SHUTDOWN, zero serial.
2. Gate matched literal "panic" and killed the VMM before the message
   printed — gates must drain evidence on failure.
3. hint.acpi.0.disabled=1 forces the mptable enumerator, whose
   unknown-entry panic is unconditional against Firecracker's
   deprecated (since v1.8, ACPI) MP table → boot_args override wins
   (md_envp is consulted before the conf's static env).
4. machdep.disable_tsc_calibration=1 + no Intel CPUID freq leaves on
   AMD runners → tsc_freq=0 → lapic TSC-deadline panic.
5. Enabling calibration exposed the real upstream defect: pv.c installs
   xen_delay (pvclock, no shared-info page on non-Xen PVH) as early
   DELAY unconditionally → page fault in start_TSC. No env fix exists
   (machdep.tsc_freq is RW-only, not a tunable; kvm_clock attaches too
   late). Fix: build-time patch pointing xen_pvh_init_ops at
   i8254_init/i8254_delay — Firecracker/microvm provide a KVM in-kernel
   PIT; equivalent to the native path (native_clock_source_init is
   literally { i8254_init(); }). Upstream candidate.
6. Patch-step lesson: an exact-spacing grep guard silently skipped
   (real file is tab-aligned) — patch guards must fail loud on
   unrecognized shape, and transformations get replay-verified against
   the real upstream file before pushing.

**Round 2 VALIDATED — run 30409991192 (2026-07-29): TIME_TO_READY=511ms
Firecracker / 569ms microvm; NET_GATE pass (guest fetch of a per-run
random token over TCP — TAP on Firecracker, SLIRP on microvm) and
HOST_PING pass (host→guest ICMP over the NAT-less TAP); vtnet0 attaches
via the virtio_mmio.device= cmdline chain on both VMMs.** Changes:
(a) de-debug nooptions block mirroring releng's std.nodebug (upstream
FIRECRACKER still ships GENERIC's -CURRENT debug set; "turn off in
stable branch" was never done) — WITNESS warning gone from boot, KDB+
KDB_TRACE+DDB kept for gate-readable panics; with INVARIANTS off,
run #5's class of bug would be silent (documented trade — SMOLFIRE-DEBUG
variant is the triage path back); (b) rc does kenv-fed static vtnet
config (rescue ships route/ping/fetch/nc — verified in
rescue/rescue/Makefile, MK_INET/MK_NETCAT defaults; loud build guard);
(c) the sed pv.c swap is replaced by the upstream-shaped isxen()
runtime-dispatch unified diff (pvh_early_{clock_source_init,delay} →
i8254 on non-Xen PVH; Xen path preserved; "Timecounter TSC-low quality
800" in the boot log proves it active). Bug-report draft lives in the
round-2 design record.

Next: strip WITNESS/INVARIANTS from SMOLFIRE for production speed,
add vtnet to the rootfs bring-up, ship the ELF as a release asset.
(→ all three done by round 2 above; remaining: submit the pv.c patch
upstream, non-KVM host testing, 9600-baud console → 115200.)
CORRECTION (skeptical audit): the pv.c patch as applied is NOT
upstream-ready — it unconditionally drops Xen PVH bootability; an
upstream version needs runtime isxen() dispatch in the init_ops. The
finding (xen_delay installed on non-Xen PVH) is the upstreamable part.

## Release 0.3.0 shipped-bytes verification (run 30407544832)

A skeptical audit found three gaps: the boot gate never authenticates
(the last real login predated round 2, which removed /etc/ssh/moduli),
TPM never ran against the round-2 image, and nothing had ever booted
the actual release assets. Closed by downloading 0.3.0 from the release
URL and testing THOSE bytes: `sha256sum -c` PASS; released qcow2 booted
with swtpm; **real root-password SSH authentication PASS**; PCR0
read PASS (test-time tpm2-tools install over SLIRP); released gzipped
ELF gunzipped and booted under Firecracker to the FIRE_42 interactive
proof. Remaining honest caveats: release-note "built from merge
6f08ce4" describes tree content (artifacts were built from branch
commits 464a986/66d7e02 whose image/kernel inputs are byte-identical
to the merge; verified by input-file trace, not rebuild); SMOLFIRE on
non-KVM hosts (macOS HVF, TCG) is untested.

## TPM T1-T6: GREEN on the evicted image (2026-07-28, run 30374624881)

The eviction is validated end-to-end: in-guest `pkg bootstrap && pkg
install tpm2-tools` over SLIRP worked (D-02 conclusively dead), and all
six gates pass. Two latent bugs fixed on the way, both predating the diet:

1. **swtpm was never invoked correctly on hosted runners**: `--pid-file`
   is not an swtpm option (`--pid file=<path>` is) — swtpm printed usage
   and exited 1, so every prior hosted TPM run died at T1. The
   "expected red pre-merge" runs were red for this reason, not the
   missing install step.
2. **T5 seal/unseal died with 0x902** ("out of memory for object
   contexts"): swtpm has few transient-object slots and the sequence
   never flushed. `tpm2_flushcontext -t` between steps fixes it.

## Release publishing: the 403 is a workflows-permission check, NOT a ruleset

The 0.2.0 one-shot's git tag push produced the definitive error:
`refusing to allow a GitHub App to create or update workflow
'.github/workflows/build-image-hosted.yml' without 'workflows'
permission`. GITHUB_TOKEN can never hold `workflows`, and creating a
tag/release ref pointing at a commit whose workflow files differ from
main trips this check. The 0.1.0 dispatch's REST 403 was the same thing
(its build commit was a branch commit with workflow changes). **No
settings change needed** — release from commits already on main (the
normal post-merge case) and the check never fires. The earlier
"tag ruleset" hypothesis in this file and release-image.yml is retired.

## SIZEREPORT — run #7 (rootfs 93 MiB); round-2 targets

Top packages (bytes): FreeBSD-utilities 49.5M, kernel-smolbsd 13.9M,
**libmagic 12.3M**, runtime 9.2M, openssl-lib 7.6M, bootloader 6.8M,
**zfs-lib 4.8M**, clibs 4.0M, ssh 3.8M, kerberos-lib 1.8M.
Top dirs (MiB): /usr 44 (share 19, lib 11, bin 8, sbin 7), /boot 21
(kernel 14), /lib 18. Top files: kernel 13M, **magic.mgc 10.2M**,
libcrypto 6.2M, **libzpool.so.2 3.8M**, local.sqlite 2.4M.

**Round 2 VALIDATED — run 30375142187 (2026-07-28): raw 66.6 MiB
(69,861,376 B), compressed 26.6 MiB (27,918,336 B), size gate PASS at
26 MiB, boot gate TIME_TO_LOGIN=9s with healthy serial (dhclient,
sshd, cron, login). The estimate below (~25 MiB) matched reality
(91 → 66.6 MiB). Trend: 1.41 GiB → 223 → 91 → 66.6 MiB raw.**

Round-2 rm list (est. ~25 MiB raw, all file-level, boot-gate validated):
`/usr/share/misc/magic.mgc` + `magic` (~12M, file(1) DB), ZFS userland
libs on a UFS image (`libzpool`, `libzfs*`, `libnvpair`, `libuutil`,
~6M+), unused loader variants (`loader_4th.efi`, `loader_simp.efi`,
`loader.kboot`, `loader_ia32.efi`, `userboot*`, ~3M — keep `loader.efi`
+ BIOS boot blocks + `/boot/lua`), `tcpdump` (1.4M), `pci_vendors` +
`usb_vendors` (2.2M), `libomp` (0.9M), `/etc/ssh/moduli` (0.6M; sshd
falls back to curve25519). Projected: **~66 MiB raw / ~25 MiB download**.

## Empirical results — hosted pipeline run #6: GREEN (2026-07-18)

**The scripted pipeline produced a gated smolfire image end-to-end for the
first time.** Run 29637188773, commit bc852b7: buildworld+kernel ~3h,
cloudware-release ~5m, **size gate PASS** (<= 512 MiB; the whole artifact
zip incl. logs is 87 MB compressed), **boot gate PASS: TIME_TO_LOGIN=9s**
under KVM — serial log shows dhclient DHCPACK on vtnet0, syslogd, sshd,
cron, then the login prompt. FIX-1..FIX-10 all validated in one run.
Remaining from the original plan: aarch64 leg (cross-build + ARM-hardware
boot gate) and the T1-T6 TPM suite against this artifact.

## Empirical results — hosted pipeline runs #3-#4 (2026-07-18)

buildworld 1h50-3h10m (-j3) and buildkernel SMOLFIRE-VM **~2m**
(MODULES_OVERRIDE) both PASS. `make cloudware-release` exits 0 after ~10m —
**but exit 0 is NOT proof of an image**: the cw recipe ends in `|| true`,
and run #4 (with artifact-presence checking) proved no qcow2 was produced.
Run #3's failure at `first?` (fixed) masked the same underlying image-stage
failure. The real mk-vmimage.sh error lives in /var/tmp/smolbsd-build.log
inside the ephemeral VM — as of run #5 that log is always fetched and its
tail printed on failure, so the next cycle is self-diagnosing. Gates
(size/boot) still not reached.

## Ordered plan for the build host

1. **Spot-check FIX-9 spelling against the host's tree** (5 minutes, read-only):
   `grep -n 'CONF\b\|cw-\|CLOUDWARE' /usr/src/release/Makefile.vm | head -40` —
   confirm `cloudware-release` exists, the per-type variable is `${TYPE}CONF`
   (→ `SMOLFIRECONF`), and whether the type list variable is `CLOUDWARE` or
   `CLOUDWARE_TYPES` on this tree. Then dry-check the target:
   `make -C /usr/src/release -V CLOUDWARE_TYPES -V VMSIZE CLOUDWARE=smolfire` .
   FIX-9 is already applied to the scripts with the CI-proven spelling;
   this step only guards against releng-branch drift.
2. **Build via pipeline or host.** Preferred: dispatch
   `.github/workflows/build-image-hosted.yml` (GitHub-hosted runner, KVM,
   no manual host needed — builds, size-gates, and boot-gates amd64
   end-to-end; cross-builds aarch64). Manual alternative: on a FreeBSD host,
   `sudo nu bin/build-smolfire-vm.nu --arch <arch>`, streaming
   `/var/tmp/smolfire-build.log`.
3. **Run the size audit** on the artifact: `sh bin/analyze-image.sh <qcow2>`.
   Capture the top-30 dir/file lists and the budget delta. This is the ground
   truth that replaces all the estimation above.
4. **Boot gate:** `expect tests/time-to-ready-arm64.exp` — confirm login ≤ 30s
   and that sshd comes up (the MODULES_OVERRIDE + FFS changes are validated here:
   a mountroot panic or missing-module failure shows up immediately on serial).
5. **Attribute the savings.** Compare against the 1.41 GiB Phase-1 baseline and
   record per-change deltas (VMSIZE 2g vs 4g; module strip; pkg filter; trim) in
   `docs/PHASE-1-RESULTS.md`. If still over 512 MiB, the analyze-image report
   names the next targets.
6. **amd64** on a Linux/KVM host via `bin/build-smolfire-vm-image.nu`, then
   `bin/analyze-image.sh` + `tests/time-to-ready-amd64-tcg.exp` (or KVM gate).
7. **Then pursue the sub-100 MiB ur-image** per `docs/UR-BSD.md`: direct kernel
   boot (`-kernel`, drop EFI partition), MFS/ramdisk root, and coordinator-driven
   "smallest package set that still passes the gate."

## Rollback criteria
- If aarch64 fails to boot after the module strip: check serial for missing-module
  or mountroot errors; if a needed `.ko` was stripped, add it to MODULES_OVERRIDE
  (or compile the device in) rather than reverting the whole change.
- If the image is not smaller despite a clean build: Finding 3 is the cause — the
  conf was not sourced; fix the invocation (step 1) and rebuild.

## Round-3 prep results (run 30577593606) — premise revised

TCG (no accelerator): the released 0.4.0 kernel boots to the FIRE_42
interactive proof under pure software emulation (18s step) — the
"KVM-only" caveat is closed for the no-accel path (macOS/HVF remains
untested). FreeBSD-utilities enumeration from the shipped 0.3.0 image
(local.sqlite via qemu-nbd): only **527 of 1,915 manifest entries
survive, totaling 13.2 MiB** — the size-trim already removed the bulk;
the ~48 MiB budget figure was the pre-trim package size. Biggest
survivors: nologin 691K, libpcap 356K, libsysdecode 293K, makefs/dtc
247K each, awk 228K, bc/dc 214K, usbdevs 210K, netstat 188K, ar5523
firmware 150K, zstd quartet 135K, RDMA/InfiniBand libs ~460K combined.
REVISED PLAN: a utilities file-cut is worth ~5–8 MiB raw (66.6 → ~59),
not the projected 20–30 — diminishing returns; the full data is the
round3-prep-data artifact. The next order of magnitude for tiny
FreeBSD is SMOLFIRE (already shipped), not further full-image dieting.

## Runner capability map + macOS HVF verification (2026-09-23)

Empirical probe (run 35828986197) of the hosted targets the aarch64/HVF
legs could use — every verdict from a real qemu accel-init attempt, not
flags: **macos-15-intel: HVF WORKS**; macos-latest (Apple silicon):
HV_UNSUPPORTED (runner VM lacks nested virt); ubuntu-24.04-arm: no
/dev/kvm. Two probe bugs found and fixed en route (macOS has no
timeout(1) — gtimeout; and see below). Consequence: **no hosted runner
can hardware-accelerate an aarch64 guest** — the aarch64 boot gate
needs either a TCG soft-gate on ubuntu-24.04-arm (same-ISA translation,
unmeasured — the ledger's >480s figure was cross-ISA) or self-hosted
ARM hardware (owner registration required).

HVF verification of SHIPPED artifacts on macos-15-intel (runs
35829501332 + 35830117437, qemu 11.1.0 via brew): **0.3.0 qcow2 boots
to login (pass, ~22 s step-bounded)** and **0.4.0 one-ELF kernel boots
to the FIRE_42 interactive shell in 1264 ms** under -accel hvf — first
proof that QEMU's PVH loader + microvm machine work on macOS, and the
README's "-accel hvf" claim is now tested. Platform lesson (run #1 of
the verify): without `-cpu host`, HVF guests get QEMU's default vCPU
with NO RDRAND/AES-NI and randomdev_wait_until_seeded stalls ~27 s
before unblocking (28.4 s boot, still pass) — always pass -cpu host
under HVF, and know that entropy-starved platforms cost ~27 s, not a
hang.
## Finding 5 — 15.1 pkgbase first-boot base auto-update: guard installed (2026-08-23)

FreeBSD 15.1 pkgbase VM/cloud images auto-update base packages on first
boot: "A firstboot package auto updater has been introduced for cloud
images. On first boot, the base system packages are automatically
updated to patch the system"
(<https://www.freebsd.org/releases/15.1R/relnotes/>). We are on
releng/15.0 (not yet affected), but the guard is installed NOW so a 15.1
rebase cannot silently break image determinism or TPM PCR stability
(issue #39 item 1; docs/RESEARCH-2026-07.md §2 flagged this).

**Exact mechanism (verified against sources, not just relnotes):**

- The updater is the rc.d script `firstboot_pkg_upgrade`, shipped by the
  ports package `firstboot-pkg-upgrade` (`sysutils/firstboot-pkg-upgrade`,
  `USE_RC_SUBR` → installs to `/usr/local/etc/rc.d/firstboot_pkg_upgrade`).
  Source: `files/firstboot_pkg_upgrade.in` in freebsd-ports
  (<https://github.com/freebsd/freebsd-ports/blob/main/sysutils/firstboot-pkg-upgrade/files/firstboot_pkg_upgrade.in>).
- `KEYWORD: firstboot` — it runs only when the firstboot(7) `/firstboot`
  sentinel exists; rcvar `firstboot_pkg_upgrade_enable` (default NO in
  the script; cloud images set YES); repos limited via
  `firstboot_pkg_upgrade_repos="FreeBSD-base"`. It runs
  `pkg update` + `env AUTOCLEAN=ON IGNORE_OSVERSION=yes pkg upgrade -r
  FreeBSD-base -y`, and on -BETA/-RC/-RELEASE touches
  `/firstboot-reboot` so rc reboots the instance after updating.
- Stock cloud confs (`release/tools/ec2-base.conf`, `ec2-small.conf`,
  `azure.conf`, `gce.conf`, `basic-cloudinit.conf` on freebsd-src main)
  enable it by adding `firstboot_pkg_upgrade` to `VM_RC_LIST` and
  appending `firstboot_pkg_upgrade_repos="FreeBSD-base"` to rc.conf.
  15.1 relnotes also note the related ports updater `firstboot_pkgs` is
  now opt-in on EC2 small (`firstboot_pkgs_enable="YES"` required).

**Guard applied (both `release/tools/smolfire-qemu.conf` and
`release/tools/smolfire-qemu-aarch64.conf`, in `vm_extra_pre_umount`):**

1. rc.conf gets explicit `firstboot_pkg_upgrade_enable="NO"` and
   `firstboot_pkgs_enable="NO"` — **this is the load-bearing guard.**
   These lines are appended after `vm_extra_enable_services` has already
   written its YES lines (mk-vmimage.sh step order: enable_services →
   pre_umount), so the NO wins by rc.conf last-write ordering.
2. `/firstboot` and `/firstboot-reboot` sentinels removed — defensive
   only: verified on releng/15.0 that `vmimage.subr` does
   `touch ${DESTDIR}/firstboot` inside `vm_create_disk`, AFTER
   `vm_extra_pre_umount` returns (same late-write class as the msdosfs
   fstab line in Finding 2). The shipped image WILL contain /firstboot;
   the knob, not the sentinel rm, is what disables the updater. This
   also deliberately keeps other firstboot-keyword scripts (e.g.
   growfs) working.
3. `rm -f` of the rc.d script itself from both plausible homes
   (`/usr/local/etc/rc.d/firstboot_pkg_upgrade`, plus `firstboot_pkgs`
   and a hypothetical base `/etc/rc.d/firstboot_pkg_upgrade`),
   `2>/dev/null || true` — today these paths don't exist in our images
   (our `VM_RC_LIST="sshd"` and FIX-10 package list never install the
   port), so this is belt+braces against a 15.1 vmimage.subr default.

**Re-verify at 15.1 rebase time:**

- Whether 15.1's `vmimage.subr` installs `firstboot-pkg-upgrade`
  unconditionally (via `VM_EXTRA_PACKAGES` defaults or a new hook) or
  only via the per-cloud confs — if a new default hook exists, confirm
  our conf still suppresses it.
- Whether the script moved from ports into base pkgbase packaging (the
  relnotes wording "for cloud images" suggests ports; re-grep
  `libexec/rc/rc.d` and `release/tools` on releng/15.1 — as of this
  writing releng/15.1 raw fetches for a base copy 404).
- Whether `vm_extra_enable_services` / `VM_RC_LIST` semantics changed,
  which would invalidate the rc.conf ordering argument in (1).
- Boot-gate check: serial log must NOT show `pkg update`/`pkg upgrade`
  or a firstboot-triggered second reboot; `pkg info` package versions in
  the booted guest must equal the build-time set (determinism check),
  and TPM T1-T6 PCR values must be stable across two boots of the same
  image.

## Post-rename revalidation — both heavyweight pipelines GREEN (2026-09-23)

The smolBSD → smolfire rename (issue #41) touched kernconfs, release
confs, build scripts, and workflow wiring, but per-push CI only
parse-checks those — no image or kernel had been *built* under the new
names. Temporary push triggers proved both pipelines end-to-end, then
were retired (trigger-retirement commits note the run IDs):

- **Kernel leg** (`smolfire.yml`, run 35834636692): GREEN, ~17 min.
  SMOLFIRE kernconf builds; Firecracker net gate (TAP + token fetch +
  HOST_PING) and QEMU microvm cross-check both PASS.
- **Full image** (`build-image-hosted.yml`, run 35834636637): GREEN,
  3h34m wall. `buildworld` + `buildkernel KERNCONF=SMOLFIRE-VM` +
  `cloudware-release` (CLOUDWARE=smolfire → SMOLFIRECONF) inside the
  nested FreeBSD 15 VM. Verified from the run itself, not assumed:
  - kernel ident in the boot banner: `15.0-RELEASE-p13
    releng/15.0-af58d0db156a SMOLFIRE-VM amd64`
  - guest hostname `smolfire` ("Setting hostname: smolfire." +
    `FreeBSD/amd64 (smolfire) (ttyu0)` login banner) — the renamed
    conf's identity settings took effect in the shipped image
  - size gate PASS: raw_bytes=69861376 (66.6 MiB),
    compressed_bytes=27918336 (26.6 MiB) — byte-identical class to the
    July diet-round-2 baseline (66.6/26.6), i.e. **no size regression
    from the rename**; "Enforce size gate" step skipped is the pass
    path (`if: steps.size.outcome == 'failure'`)
  - KVM boot gate PASS: TIME_TO_LOGIN=8s, VERDICT=pass (July baseline
    9s)
  - artifact `smolfire-amd64` uploaded (qcow2 + build.log +
    smolfire-build-vm.log + serial.log)

Assumption retired: "the renamed heavyweight pipeline still works" was
unverified between the rename merge and this run; it is now a verified
finding for the amd64 leg. The aarch64/riscv64 legs remain cross-built
+ size-gate-only (see runner capability map above) and were not
re-exercised.

## Same-ISA TCG aarch64 boot: MEASURED — fast; stall is stock firstboot, not TCG (2026-09-24)

Design + adversarial review: backlog panel (dynamic workflow
wf_126b3fff-e69). Probe: `.github/workflows/aarch64-tcg-probe.yml`
(TEMPORARY, retired after these results) driving
`bin/ci/aarch64-boot-probe.sh` (staged-marker classifier; verdict
contract unit-tested in `tests/aarch64-boot-probe-test.nu`).

- **Run 35940101688** (probe attempt 1): both legs
  `inconclusive-eof` in <1s — Ubuntu ships the virtio NIC's PXE ROM
  (`efi-virtio.rom`) in `ipxe-qemu`, dropped by
  `--no-install-recommends`. Fixed without a new package:
  `-device virtio-net-pci,...,romfile=` (EFI disk boot never needs a
  PXE ROM). Same missing ROM fired inside the pauth cpu preflight via
  the virt machine's implicit default NIC and masqueraded as "cpu
  property rejected" — preflight now passes `-nic none`. Platform
  lesson: on Ubuntu ARM runners, any `-machine virt` invocation
  without an explicit NIC config can die on the missing ROM.
- **Run 35942080669** (probe attempt 2, stock 15.0-RELEASE arm64
  BASIC-CLOUDINIT under qemu 8.2.2, AAVMF pflash, budget 1200s/leg):
  both cpu legs `inconclusive-timeout LAST_MARKER=rc` — but the
  marker timeline retires the "same-ISA TCG unmeasured" caveat in the
  Runner capability map above:

  | marker | -cpu max,pauth-impdef=on | -cpu neoverse-n1 |
  |---|---|---|
  | uefi (BdsDxe) | 6s | 6s |
  | EFI loader | 6s | 6s |
  | kernel banner | 7s | 6s |
  | rc (Setting hostname) | 22s | 20s |

  **Same-ISA TCG reaches early rc in ~20s** — KVM-class, two orders
  of magnitude better than the >480s CROSS-ISA figure (which stays
  true for x64 hosts only). The 1200s exhaustion is entirely the
  STOCK image's firstboot machinery, visible in the serial: cloud-init,
  growfs, and `freebsd-update` fetching metadata + "Inspecting
  system" (a full installed-world hash walk, glacial under TCG and
  still running at budget). The smolfire image ships none of that
  (Finding-5 guards; no cloud-init). Entropy is a non-issue on this
  path: `random: registering fast source VirtIO Entropy Adapter` on
  both legs and no max-vs-neoverse delta (the HVF RDRAND lesson does
  not transfer — GENERIC's virtio_random covers it; note SMOLFIRE-VM
  excludes the module via MODULES_OVERRIDE, so the smolfire-image
  number may differ — the soft-gate run measures it).

**Consequence:** the aarch64 boot soft-gate (`aarch64-boot-softgate`
job in build-image-hosted.yml, 900s budget, verdict semantics +
recalibration rule documented in-file) is viable on ubuntu-24.04-arm.
The stock number is a GENERIC upper bound and does NOT set the gate
budget; the first `arch=aarch64` dispatch of the image pipeline
produces the authoritative smolfire number — and is also the
first-ever end-to-end run of the scripted aarch64 image leg, so a red
build job there is triaged from smolfire-build-vm.log before any gate
conclusion is drawn.

## First end-to-end aarch64 image + TCG soft-gate PASS (2026-09-24, run 35947103487)

The scripted aarch64 image leg had never executed (only a manual
assembly existed); it is now validated end-to-end on the hosted
pipeline, with two findings en route:

- **Run 35945692124 (attempt 1) — WITHOUT_INSTALLLIB breaks cross
  buildworld.** Died 5s in: `ld: unable to find library -legacy` for
  rpcgen/certctl. Proven by log-diff against the green amd64 run
  (35834636637, which predates the knob) plus releng/15.0 sources:
  Makefile.inc1's stage-1.1 legacy env overrides `MK_INCLUDES=yes` but
  NOT `MK_INSTALLLIB`, so src.conf's `WITHOUT_INSTALLLIB=yes` (added
  in 4088910, a size-trim proposal never build-validated) let
  libegacy.a be built but skipped `_libinstall`. Only cross builds
  notice — rpcgen/certctl are bootstrap-built only when TARGET !=
  host. Knob removed (its trim effect was already redundant: release
  confs rm /usr/lib *.a recursively, FIX-10 excludes -dev packages).
  `WITHOUT_TOOLCHAIN` verified cross-safe (src.opts.mk:
  MK_CLANG_BOOTSTRAP is gated by CROSS_COMPILER, not MK_TOOLCHAIN).
- **Run 35947103487 (attempt 2) — GREEN, and fast:**
  - Build (world + SMOLFIRE-VM kernel + cloudware-release, cross to
    aarch64): **28 minutes** — ~7.5x faster than the 3.5h baseline.
    This is the 4088910 trim-knob set's first successful build
    validation (aarch64 leg; amd64 leg still pending). The knobs also
    change heavyweight-validation economics: a full image run now
    costs ~35 min, not ~3.5h, which weakens the "piggyback-only"
    premise of the round-3 utilities-cut conditional.
  - Size gate PASS: raw_bytes=66125824 (63.1 MiB),
    compressed_bytes=26083328 (24.9 MiB) — the first aarch64 size
    datum; slightly under amd64's 66.6/26.6 pre-knob numbers.
  - **aarch64 boot soft-gate: VERDICT=pass, TIME_TO_LOGIN=31s,
    attempt 1** — the first boot of any smolfire aarch64 image,
    anywhere, and it happened under pure same-ISA TCG on a hosted
    ubuntu-24.04-arm runner. Serial shows `random: fast provider:
    "Armv8 rndr RNG"` — `-cpu max` FEAT_RNG covers entropy exactly as
    the probe design intended (SMOLFIRE-VM has no virtio_random;
    armv8_rng attaches instead). 31s vs the stock image's >1200s
    confirms the stall attribution: firstboot machinery, not TCG.
  - Soft-gate recalibration status: measured run 1 of 3; budget stays
    900s. p95 < 300s so far — on the current trend the gate tightens
    to ~2x p95 and timeout promotes to hard fail after run 3.

The "aarch64: size gate only" era is over: the leg now has a boot
gate, its verdict semantics are honest under TCG, and the evidence
(gate-verdict.txt + serial) uploads with every run.
