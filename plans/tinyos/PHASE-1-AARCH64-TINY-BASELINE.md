# Phase I — aarch64 Tiny Baseline: FreeBSD 15 arm64 Minimal VM

- **Phase**: I of IV — Forge Tiny Baseline (aarch64 leg; PRIMARY per REPLAN)
- **Campaign**: smolBSD — The Tiny Realm vs The Rump Citadel
- **Target**: FreeBSD 15.0-RELEASE arm64, VM-first, headless
- **Authored by**: planner@smolbsd.local (task-0005)
- **Date**: 2026-04-30
- **Status**: design-complete — DO NOT BUILD until this file is accepted
- **REPLAN decision**: `plans/tinyos/PHASE-1-ARCH-DECISION.md` — Option C, aarch64-first

---

## 1. Mission Statement

Build the smallest stable FreeBSD 15 arm64 QEMU VM that boots unattended to a
login prompt in **≤ 30 seconds** (HVF-accelerated on `<hypervisor-host>`), runs sh,
vi/ed, rc.d, and pkg, uses UFS, and fits inside 512 MiB on disk (aspirational:
qcow2 artifact < 128 MiB).

**This is the PRIMARY Phase-I leg.** The HVF accelerator on Apple Silicon
(`<hypervisor-host>`) is native-ISA-only: an aarch64 guest under HVF runs at near-bare-
metal speed, while an amd64 guest falls back to TCG (software emulation, 5–10×
slower). The ≤ 30s time-to-login acceptance gate can only be cleared on the build
host using an aarch64 image; the amd64 leg requires a KVM-capable x86 host for
its timing gate.

This file defines the build contract. No build commands are run here.

---

## 2. Build Host and Build Mode

### 2.1 Build host: `<aarch64-builder>` (FreeBSD 15 aarch64 on `<hypervisor-host>`)

The <aarch64-builder> VM is FreeBSD 15.0-RELEASE **aarch64** — the same ISA as the
target. This means **no cross-compile is needed**: the build system uses
its native toolchain end-to-end.

**<aarch64-builder> operational notes** (see design spec §18 for full detail):

- Skill-canonical name `fb-vm-24` is stale — actual VM name is `<aarch64-builder>`.
- SSH port: `ssh -J <hypervisor-host> -p 2222 builder@localhost` (not the skill's stale 2225).
- virtfs share on host side: `/Users/studio/Users/studio/share/<aarch64-builder>/` (doubled-prefix wrapper bug, documented separately).
- Screen-socket-lost hazard: `pgrep qemu` and `screen -ls` may diverge; see spec §18.4 for recovery.

### 2.2 Build mode: native arm64 — no cross-compile

On an arm64 host building for arm64, `TARGET` and `TARGET_ARCH` may be omitted
or stated explicitly (both are equivalent):

```sh
# Native build (preferred — simpler, fewer failure modes):
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLBSD

# Or with explicit arch (identical result on arm64 host):
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLBSD \
    TARGET=arm64 \
    TARGET_ARCH=aarch64
```

Contrast with the amd64 leg, which must cross-compile from the arm64 <aarch64-builder> host
using `TARGET=amd64 TARGET_ARCH=amd64`. The native path removes the cross-
toolchain step, reducing build time and failure modes.

---

## 3. Package Set

The package set is **identical to the amd64 leg** (see
`PHASE-1-FORGE-TINY-BASELINE.md` §§3.1–3.4). It is arch-independent:
pkgbase names carry no ISA suffix; the same base packages build for both arches.

### 3.1 Floor: OCI runtime image (from `release/tools/oci-image-runtime.conf`)

```
FreeBSD-runtime
FreeBSD-certctl
FreeBSD-kerberos-lib
FreeBSD-libarchive
FreeBSD-libexecinfo
FreeBSD-libucl
FreeBSD-fetch
FreeBSD-rc
FreeBSD-pkg-bootstrap
FreeBSD-mtree
```

### 3.2 smolBSD-specific additions

```
FreeBSD-kernel-generic       # kernel (overridden to SMOLBSD kernel — see §4)
FreeBSD-utilities            # sh, vi, ed, coreutils-equivalent base utilities
FreeBSD-clibs                # PAM, NSS, and other C-level runtime libs
FreeBSD-openssl-lib          # TLS for pkg(8) and ssh
FreeBSD-ee                   # ee (easy editor) — fallback editor, lighter than vi full
```

### 3.3 Explicit exclusions (via `vm_extra_filter_base_packages()`)

```
*-dbg          # debug symbol packages
*-lib32        # 32-bit compat — arm64 VM, no 32-bit userland
FreeBSD-tests* # test suite — ~200 MiB, not needed at runtime
FreeBSD-lldb*  # LLDB debugger — development tool
FreeBSD-devel* # compiler toolchain — install later via pkg if needed
FreeBSD-src*   # kernel source — not needed in the image
FreeBSD-set-kernels-dbg
FreeBSD-kernel-minimal   # do not include — we compile our own SMOLBSD kernel
```

### 3.4 Complete package list (ordered by install dependency)

```
FreeBSD-clibs
FreeBSD-runtime
FreeBSD-libexecinfo
FreeBSD-libucl
FreeBSD-libarchive
FreeBSD-openssl-lib
FreeBSD-kerberos-lib
FreeBSD-certctl
FreeBSD-fetch
FreeBSD-mtree
FreeBSD-rc
FreeBSD-utilities
FreeBSD-ee
FreeBSD-pkg-bootstrap
FreeBSD-kernel-generic      # replaced by SMOLBSD at kernel build time
```

---

## 4. Kernel Config Delta: SMOLBSD (arm64)

### 4.1 Strategy

Same philosophy as the amd64 leg: start from the arm64 `MINIMAL` config, strip
physical-hardware drivers that are dead code in a QEMU virt machine, add arm64-
and QEMU-specific tuning.

The kernel config lives at `sys/arm64/conf/SMOLBSD` (already written to disk
as part of this task-0005 output).

### 4.2 Key arm64 differences from the amd64 kernel config

| Aspect | amd64 SMOLBSD | arm64 SMOLBSD |
|--------|--------------|---------------|
| `machine` line | `machine amd64` (implicit in amd64/conf/) | `machine arm64` |
| Serial console | ISA COM1 (`uart_isa`, comconsole) | PL011 UART (`device uart`, uart0 in FDT) |
| `loader.conf` console | `console="comconsole,vidconsole"` | `console="uart0"` (see §7.3) |
| FDT | not needed (ACPI-only on x86) | `options FDT` — required for virt machine device enumeration |
| ACPI | primary (`device acpi`) | secondary (EDK2 exposes ACPI; FDT is primary) |
| KVM paravirtual clock | `device kvm_clock` (kept) | not applicable (arm64 uses arch-timer; no kvm_clock driver) |
| Xen HVM | `device xenpci`, `device xentimer` (kept) | not present in arm64/conf/MINIMAL |
| PSCI (power state) | not applicable | kept from arm64/MINIMAL (`device psci`) |

### 4.3 Reference baseline sizes (arm64)

- `GENERIC` arm64 kernel binary: ~28–32 MiB (uncompressed)
- `MINIMAL` arm64 kernel binary: ~20–23 MiB
- Target `SMOLBSD` arm64 kernel binary: ~16–19 MiB

arm64 GENERIC is smaller than x86_64 GENERIC (fewer physical device drivers in
the upstream tree for arm64), so the stripping delta is smaller but the end-
result target is roughly the same.

---

## 5. Image Format

**Decision**: `qcow2` — same rationale as amd64 leg.

**Boot firmware**: UEFI via EDK2/AAVMF (`edk2-aarch64-code.fd`).
arm64 QEMU virt machine uses AAVMF instead of x86's `edk2-x86_64-code.fd`.

**Disk layout** (GPT, matches `Makefile.vm` default):

```
Part 1: efi           40 MiB     (FAT32, /boot/loader.efi)
Part 2: freebsd-swap  512 MiB    (reducible to 256 MiB in Phase II)
Part 3: freebsd-ufs   remainder  (UFS2 soft-updates, no journaling by default)
```

Note: arm64/AAVMF does not need a `freebsd-boot` GPT entry (that is an x86
BIOS fallback partition); the EFI partition alone suffices.

**Total provisioned image size**: 4 GiB (`VMSIZE=4g`).
**Expected qcow2 artifact size** after sparse allocation: 128–200 MiB.

---

## 6. Per-Layer Size Budget

Same targets as the amd64 leg. arm64 kernel binary is slightly smaller due to
fewer upstream physical device drivers in the arm64 GENERIC baseline.

| Layer | Budget | Basis |
|-------|--------|-------|
| Kernel binary (`/boot/kernel/kernel`, no -dbg) | 19 MiB | GENERIC ~30 MiB arm64; SMOLBSD strips ~35–40% |
| Kernel modules (`/boot/kernel/*.ko`, minimal set) | 7 MiB | geom_* for boot, loader modules |
| Base userland (`FreeBSD-runtime` + `FreeBSD-clibs`) | 35 MiB | libc, libm, libutil, /etc skeleton, /bin/sh loader |
| Utilities (`FreeBSD-utilities`) | 48 MiB | Largest base package; provides vi, ed, coreutils-equivalent |
| rc.d framework (`FreeBSD-rc`) | 3 MiB | /etc/rc, /etc/rc.d/*, rc.conf |
| pkg runtime (libarchive + openssl-lib + libucl + fetch + pkg-bootstrap) | 18 MiB | pkg dependencies |
| Supporting packages (certctl, kerberos-lib, libexecinfo, mtree, ee) | 6 MiB | Small ancillary packages |
| /boot loader + EFI files | 5 MiB | loader.efi, dtb, hints |
| /etc defaults + /var skeleton + /tmp | 2 MiB | Configuration files, empty dirs |
| **Total on-disk footprint** | **~143 MiB** | Sum of above (kernel ~2 MiB smaller than amd64) |
| **qcow2 artifact size** (sparse) | **~128 MiB** | Sparse allocation ratio ~0.88 for typical UFS |
| **Hard cap** | **512 MiB** | Project constraint; this design is well under |

---

## 7. Build Pipeline: `smolfire-qemu-aarch64.conf`

### 7.1 File: `release/tools/smolfire-qemu-aarch64.conf`

```sh
#!/bin/sh
# smolfire-qemu-aarch64.conf — FreeBSD 15 arm64 minimal QEMU VM image
# Used with: make release KERNCONF=SMOLBSD WITH_PKGBASE=yes \
#                 VMFORMATS=qcow2 VMSIZE=4g \
#                 CLOUDWARE_CONF=tools/smolfire-qemu-aarch64.conf

export VMSIZE=4g
export SWAPSIZE=512m
export VM_RC_LIST="sshd"

vm_extra_filter_base_packages() {
    grep -v \
        -e '.*-dbg$' \
        -e '.*-lib32$' \
        -e '^FreeBSD-tests' \
        -e '^FreeBSD-lldb' \
        -e '^FreeBSD-devel' \
        -e '^FreeBSD-src' \
        -e '^FreeBSD-kernel-minimal' \
        -e '^FreeBSD-set-kernels-dbg'
}

vm_extra_pre_umount() {
    # Minimal rc.conf: enable sshd, DHCP on vtnet0, serial console
    cat >> "${DESTDIR}/etc/rc.conf" <<EOF
hostname="smolbsd-arm64"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
dumpdev="NO"
EOF

    # loader.conf: disable boot menu, use UART serial console (arm64)
    # arm64 QEMU virt machine: serial is uart0, not comconsole
    cat >> "${DESTDIR}/boot/loader.conf" <<EOF
autoboot_delay="-1"
beastie_disable="YES"
loader_logo="none"
console="uart0"
boot_serial="YES"
EOF

    # sshd_config: allow password auth for initial access
    cat >> "${DESTDIR}/etc/ssh/sshd_config" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
EOF

    # Remove XMSS host keys — take hours to generate, block sshd startup
    rm -f "${DESTDIR}/etc/ssh/ssh_host_xmss_key"*

    # Set root password to 'smolbsd' (change on first login)
    echo 'smolbsd' | pw -V "${DESTDIR}/etc" usermod root -h 0 || true

    return 0
}
```

### 7.2 Build invocation sequence (inside <aarch64-builder> — native arm64 build)

```sh
# Inside <aarch64-builder> (FreeBSD 15 aarch64 — ssh -J <hypervisor-host> -p 2222 builder@localhost):

# Step 1: Ensure source tree is present at /usr/src (releng/15.0)
# gitup or: git clone -b releng/15.0 https://git.freebsd.org/src.git /usr/src

# Step 2: Place kernel config
cp sys/arm64/conf/SMOLBSD /usr/src/sys/arm64/conf/SMOLBSD

# Step 3: Place release config
cp smolfire-qemu-aarch64.conf /usr/src/release/tools/smolfire-qemu-aarch64.conf

# Step 4: Build world + kernel (native arm64 — no TARGET flags needed)
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLBSD

# Step 5: Build pkgbase packages
make -j4 -C /usr/src packages

# Step 6: Build the VM image
make -C /usr/src/release vm-image \
    KERNCONF=SMOLBSD \
    WITH_PKGBASE=yes \
    VMFORMATS=qcow2 \
    VMSIZE=4g \
    CLOUDWARE_CONF=/usr/src/release/tools/smolfire-qemu-aarch64.conf

# Output: /usr/obj/arm64.aarch64/usr/src/release/vm/
#   FreeBSD-15.0-RELEASE-arm64-SMOLBSD.qcow2
```

### 7.3 Alternative: Makefile.vm directly

```sh
make -C /usr/src/release -f Makefile.vm vm-image \
    VMBASE=FreeBSD-15-arm64-smolbsd \
    VMFORMATS="qcow2 raw" \
    VMSIZE=4g \
    KERNCONF=SMOLBSD \
    CLOUDWARE_CONF=tools/smolfire-qemu-aarch64.conf
```

---

## 8. Measured Relics — Test Commands

The five Measured Relics are identical in structure to the amd64 leg's §8, with
three substitutions:

1. QEMU binary: `qemu-system-aarch64` (not `qemu-system-x86_64`)
2. Machine flags: `-machine virt,accel=hvf -cpu host` (HVF on Apple Silicon; not `-M q35 -accel kvm`)
3. BIOS: `-bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd` (AAVMF; not `edk2-x86_64-code.fd`)
4. Image name: `FreeBSD-15-arm64-smolbsd.qcow2`
5. Console: `-serial stdio` with uart0 (not comconsole)

### 8.0 Reference launch command (for all tests below)

```sh
/opt/homebrew/bin/qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -m 256M -smp 2 \
  -drive file=FreeBSD-15-arm64-smolbsd.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2231-:22 \
  -serial stdio \
  -nographic
```

Note: use port 2231 (not 2230) to avoid collision with any running amd64 test.

### 8.1 Build Success Rate

```sh
test -f FreeBSD-15-arm64-smolbsd.qcow2 && \
  qemu-img info FreeBSD-15-arm64-smolbsd.qcow2 | grep -E 'virtual size|disk size'
# Acceptance: exit 0 + both lines present
```

### 8.2 Time to Ready State — EXPECTED TO PASS on <hypervisor-host> (HVF)

```sh
# tests/time-to-ready-aarch64.exp
#!/usr/bin/env expect
set timeout 120
set t0 [clock seconds]
spawn /opt/homebrew/bin/qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -m 256M -smp 2 \
  -drive file=FreeBSD-15-arm64-smolbsd.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2231-:22 \
  -serial stdio -nographic
expect {
  "login:" { puts "TIME_TO_LOGIN=[expr {[clock seconds] - $t0}]s" }
  timeout  { puts "TIMEOUT"; exit 1 }
}
# Acceptance: TIME_TO_LOGIN <= 30s
# Expected: PASS on <hypervisor-host> (Apple Silicon, HVF = native-ISA acceleration)
# Contrast: amd64 leg expected to FAIL this gate on <hypervisor-host> (TCG = ~5-10x slower)
```

### 8.3 Peak and Idle Memory

```sh
QEMU_PID=$(pgrep -n qemu-system-aarch64)
ps -o rss= -p $QEMU_PID                 # peak (sample at t+10s)
sleep 60; ps -o rss= -p $QEMU_PID       # idle (sample at t+60s)
ssh -p 2231 root@127.0.0.1 'sysctl vm.stats.vm.v_free_count vm.stats.vm.v_page_size'
# Acceptance: host RSS idle < 300 MiB; in-VM free >= 150 MiB in 256 MiB VM
```

### 8.4 Artifact Size

```sh
qemu-img info --output=json FreeBSD-15-arm64-smolbsd.qcow2 \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['actual-size'])"
# Acceptance: actual-size < 134217728 bytes (128 MiB aspirational)
#             actual-size < 536870912 bytes (512 MiB hard cap)
```

### 8.5 Crash Recovery Time

```sh
kill -9 $(pgrep -n qemu-system-aarch64); T0=$(date +%s)
/opt/homebrew/bin/qemu-system-aarch64 \
  -machine virt,accel=hvf -cpu host \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -m 256M -smp 2 \
  -drive file=FreeBSD-15-arm64-smolbsd.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2231-:22 \
  -serial stdio -nographic &
until ssh -p 2231 root@127.0.0.1 'echo RECOVERED' 2>/dev/null; do sleep 2; done
echo "CRASH_RECOVERY_TIME=$(($(date +%s) - T0))s"
# Acceptance: <= 60s (UFS soft-updates fsck path)
```

---

## 9. Configuration Files to Create

| File | Location in tree | Purpose |
|------|-----------------|---------|
| `SMOLBSD` | `sys/arm64/conf/SMOLBSD` | Kernel config delta (§4, already written) |
| `smolfire-qemu-aarch64.conf` | `release/tools/smolfire-qemu-aarch64.conf` | Release config + package filter (§7.1) |
| `time-to-ready-aarch64.exp` | `tests/time-to-ready-aarch64.exp` | Expect script for §8.2 gate |
| `rc.conf` fragment | injected by `vm_extra_pre_umount()` | Minimal boot config |
| `loader.conf` fragment | injected by `vm_extra_pre_umount()` | UART console + fast boot |
| `sshd_config` fragment | injected by `vm_extra_pre_umount()` | Initial access |

---

## 10. Build Host Requirements

- **OS**: FreeBSD 15.0-RELEASE arm64 (the `<aarch64-builder>` VM on `<hypervisor-host>`)
- **RAM**: 8 GiB minimum (buildworld requires ~4 GiB; <aarch64-builder> has 8 GiB — sufficient)
- **Disk**: 40 GiB free (src tree ~2 GiB, /usr/obj ~18 GiB native, image artifacts ~1 GiB)
- **Tools**: `git` (fetch src), `pkg` (verify package set), `qemu-img` (validate output)
- **No cross-compile toolchain needed**: native arm64 build uses the host's own tools.
  This reduces build time vs the amd64 cross-build leg by approximately 20–30%
  (no cross-toolchain bootstrap step).
- **QEMU test host**: `<hypervisor-host>` (Apple Silicon, HVF available).
  `/opt/homebrew/bin/qemu-system-aarch64` verified present (QEMU 10.2.1).
  `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` (AAVMF) — verify present before first test run.

---

## 11. Key Differences from amd64 Leg (Summary)

| Dimension | amd64 Leg | aarch64 Leg (this doc) |
|-----------|-----------|------------------------|
| Build type | Cross-compile (arm64 host → amd64 target) | Native (arm64 host → arm64 target) |
| `TARGET` / `TARGET_ARCH` | `TARGET=amd64 TARGET_ARCH=amd64` | Not needed (or `TARGET=arm64 TARGET_ARCH=aarch64`) |
| QEMU binary | `qemu-system-x86_64` | `qemu-system-aarch64` |
| Machine flags | `-M q35 -accel kvm -cpu host` | `-machine virt,accel=hvf -cpu host` |
| BIOS/firmware | `edk2-x86_64-code.fd` | `edk2-aarch64-code.fd` (AAVMF) |
| Serial console | `comconsole` (COM1/ISA) | `uart0` (PL011 UART via FDT) |
| `loader.conf console=` | `comconsole,vidconsole` | `uart0` |
| FDT in kernel | Not needed | `options FDT` required |
| kvm_clock device | Kept | Not applicable (arm64 arch-timer) |
| Time-to-login gate | Likely FAIL on <hypervisor-host> (TCG) | Expected PASS on <hypervisor-host> (HVF) |
| Hostfwd test port | 2230 | 2231 (avoids collision) |
| Kernel config path | `sys/amd64/conf/SMOLBSD` | `sys/arm64/conf/SMOLBSD` |
| obj path | `/usr/obj/amd64.amd64/...` | `/usr/obj/arm64.aarch64/...` |

---

## 12. Open Questions for Phase II

1. **Pi 5 / RK3588 physical boot**: the Phase-I qcow2 is a VM image, not a
   Pi-bootable image. Phase II converts the userland/kernel baseline to a real-
   disk layout (raw + GPT + EFI + UFS matching Pi/RK firmware expectations).
   `dd if=FreeBSD-15-arm64-smolbsd.qcow2 of=/dev/sdX` will NOT work directly.
2. **UFS vs ZFS**: same tradeoff as amd64 leg; defer to Phase II.
3. **DTB handling for Pi/RK**: Pi 5 uses BCM2712 DTB; RK3588 uses its own DTB.
   The QEMU virt machine uses a generated DTB at launch — Phase II must pin
   the correct physical-board DTB.
4. **Swap size**: 512 MiB may be reducible for memory-constrained Pi targets.
5. **AAVMF binary path**: `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` —
   verify this path on <hypervisor-host> before first test run (Homebrew QEMU install
   path; could differ across QEMU versions).

---

## 13. Acceptance Gates (self-check)

- [x] Package set named (§3.4 — identical to amd64 leg; arch-independent)
- [x] Kernel config delta from MINIMAL specified (§4, `sys/arm64/conf/SMOLBSD`)
- [x] Build tool chosen with rationale (§2.2: native arm64 build, no cross-compile)
- [x] Image format chosen with rationale (§5: qcow2, AAVMF firmware)
- [x] Per-layer size budget with total (§6: ~143 MiB on-disk, ~128 MiB artifact)
- [x] Build success rate test command (§8.1)
- [x] Time to ready state test command (§8.2) with HVF expectation stated
- [x] Peak + idle memory test commands (§8.3)
- [x] Artifact size test command (§8.4)
- [x] Crash recovery time test command (§8.5)
- [x] Key differences from amd64 leg tabulated (§11)
- [x] No build commands executed — design only
- [x] File located at `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md`

---

*Authored by planner@smolbsd.local — task-0005 — 2026-04-30*
*In reply to coordinator@smolbsd.local message <task-0005.coord@smolbsd.local>*
