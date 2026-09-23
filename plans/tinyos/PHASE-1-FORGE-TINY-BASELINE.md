# Phase I — Forge Tiny Baseline: FreeBSD 15 amd64 Minimal VM

- **Phase**: I of IV — Forge Tiny Baseline
- **Campaign**: smolBSD — The Tiny Realm vs The Rump Citadel
- **Target**: FreeBSD 15.0-RELEASE amd64, VM-first, headless
- **Authored by**: architect@smolbsd.local (task-0001)
- **Date**: 2026-04-30
- **Status**: design-complete — DO NOT BUILD until this file is accepted

> **Scope note (2026-05-04):** Per `PHASE-1-ARCH-DECISION.md`, amd64 is the
> secondary Phase I leg. aarch64 (see `PHASE-1-AARCH64-TINY-BASELINE.md`) is
> primary. The amd64 leg targets a KVM-capable x86 host (Vultr) for its
> acceptance gate — not Apple Silicon, where TCG emulation cannot meet the ≤30s
> time-to-login constraint.

---

## 1. Mission Statement

Build the smallest stable FreeBSD 15 amd64 QEMU VM that boots unattended to a
login prompt, runs sh, vi/ed, rc.d, and pkg, uses UFS, and fits inside 512 MiB
on disk (aspirational: qcow2 artifact < 128 MiB).

This file defines the build contract. No build commands are run here.

---

## 2. Prior Art and Tooling Assessment

### 2.1 What the `freebsd-build-vm` skill already provides

The existing build VM on `<hypervisor-host>` (skill-canonical name: `fb-vm-24` (drift;
actual VM is `<aarch64-builder>`) — see spec §18.1) is FreeBSD 15.0-RELEASE **aarch64**
built via the official `release/` scripts and `mk-vmimage.sh`. It demonstrates:

- `release/Makefile.vm` with `WITH_PKGBASE=yes` and `VMFORMATS=qcow2` works end-to-end
- `vm_extra_filter_base_packages()` pattern for stripping -dbg/-lib32/-tests/-lldb
- virtiofs shared folder + screen+socket serial launch pattern (mandatory for detached QEMU)
- SSH hostfwd: actual port is **2222** on `<hypervisor-host>` (the freebsd-build-vm skill
  prose says `2225`; ground-truth verified on the live qemu pid is `2222` —
  see spec §18.2). Use port 2226+ for any additional smolBSD build VM peer.

This skill does NOT cover amd64. The smolBSD build will produce a new amd64 image,
not reuse the aarch64 <aarch64-builder> image. We run the build **inside** <aarch64-builder> (which is
a FreeBSD 15 aarch64 host), targeting the amd64 cross-build path, OR we use an
amd64 cloud/build host with FreeBSD 15 installed.

**Preferred build host for Phase I**: `<aarch64-builder>` (skill-canonical name: `fb-vm-24`
(drift; actual VM is `<aarch64-builder>`) — FreeBSD 15.0-RELEASE aarch64) running
`make -j4 buildworld buildkernel KERNCONF=SMOLBSD TARGET=amd64 TARGET_ARCH=amd64`
then `make release KERNCONF=SMOLBSD WITH_PKGBASE=yes VMFORMATS=qcow2`.

**Operational caveats** (see spec §18 for full detail):

- The freebsd-build-vm skill upstream (`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md`) is **stale** on VM name (`fb-vm-24` → `<aarch64-builder>`) and SSH port (`2225` → `2222`); needs a separate update PR.
- The virtfs share path on the host side is currently `/Users/studio/Users/studio/share/<aarch64-builder>` (doubled-prefix launch-wrapper bug; documented to fix in fleet-ops `vm-templates/run-freebsd-vm.sh.template` separately).
- The <aarch64-builder> qemu process can outlive its launching screen socket — `screen -r <aarch64-builder>` may fail even while the VM is reachable on `ssh -p 2222`. Recovery: `pkill -f qemu-system-aarch64` + relaunch via `~/vms/run-fb-vm-24.sh`. See spec §18.4.

### 2.2 Build tool decision: `release/Makefile.vm` (not nanobsd, not mkimg standalone)

| Tool | Verdict | Rationale |
|------|---------|-----------|
| **release/Makefile.vm + mk-vmimage.sh** | CHOSEN | Official FreeBSD release tooling, pkgbase-native, qcow2 output, actively maintained for FreeBSD 15, aligns with existing fleet skill. `vm_extra_filter_base_packages()` hook gives precise control over installed set. Proven path for the campaign. |
| `nanobsd` | Reject | Designed for embedded flash appliances; assumes cramped media with two fixed-size partitions and no pkg upgrade path. Actively de-emphasized upstream. Doesn't support pkgbase. Last major use case (pfSense) moved off it. |
| `mkimg` (standalone) | Reject for Phase I | `mkimg(8)` is a low-level image stamper, not a builder. Using it standalone requires hand-assembling the filesystem via `makefs(8)` and manually invoking `bsdinstall` or `installworld`. This is exactly what `mk-vmimage.sh` wraps. Use mkimg as a sub-tool, not the orchestrator. |
| `poudriere image` | Reject | Alpha feature, interface unstable; better for port-heavy images, not base-only. |

**Decision**: Use `release/Makefile.vm` with a custom `.conf` file
(`release/tools/smolfire-qemu.conf`) that invokes `vm_extra_filter_base_packages()`
to enforce the package set below.

---

## 3. Package Set

### 3.1 Floor: OCI runtime image (from `release/tools/oci-image-runtime.conf`)

The FreeBSD project's smallest functional container image installs exactly:

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

This gives `/bin/sh`, the loader, libc, /etc skeleton, rc.d, fetch(1), and pkg
bootstrap. It does NOT include vi/ed, full utilities, or the kernel.

### 3.2 smolBSD-specific additions above the OCI floor

```
FreeBSD-kernel-generic       # kernel (overridden to SMOLBSD kernel — see §4)
FreeBSD-utilities            # sh, vi, ed, coreutils-equivalent base utilities
FreeBSD-clibs                # PAM, NSS, and other C-level runtime libs
FreeBSD-openssl-lib          # TLS for pkg(8) and ssh
FreeBSD-ee                   # ee (easy editor) — fallback editor, lighter than vi full
```

Note: `FreeBSD-utilities` at 48.6 MiB installed is the largest non-kernel package.
It provides `vi`, `ed`, `sort`, `cat`, `ls`, `cp`, `mv`, `rm`, `tar`, `sh` binaries.

### 3.3 Explicit exclusions (applied via `vm_extra_filter_base_packages()`)

```
*-dbg          # debug symbol packages — strip for production image
*-lib32        # 32-bit compatibility — headless amd64 VM, no 32-bit userland needed
FreeBSD-tests* # test suite — ~200 MiB, not needed at runtime
FreeBSD-lldb*  # LLDB debugger — development tool, not runtime
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

After first boot, `pkg install` adds any missing runtime dependencies.
The `FreeBSD-pkg-bootstrap` package seeds `/usr/local/sbin/pkg` so pkg can
self-install on first invocation (`pkg bootstrap -f` not needed).

---

## 4. Kernel Config Delta: SMOLBSD

### 4.1 Strategy

Use the `include GENERIC` delta pattern. The SMOLBSD config lives at
`/usr/src/sys/amd64/conf/SMOLBSD` and expresses only what differs from GENERIC.

The existing `MINIMAL` config at `sys/amd64/conf/MINIMAL` already strips most
loadable-module functionality from GENERIC (leaving networking, UFS, virtio,
serial, crypto in-kernel). SMOLBSD extends MINIMAL's approach by also stripping
physical-hardware SCSI/RAID controllers and wireless — safe because the only
target is QEMU with virtio devices.

### 4.2 Reference baseline sizes

- `GENERIC` kernel binary: ~32–35 MiB (uncompressed)
- `MINIMAL` kernel binary: ~22–25 MiB (strips loadable-module candidates)
- Target `SMOLBSD` kernel binary: ~18–20 MiB

### 4.3 SMOLBSD kernel config file

```
# SMOLBSD — FreeBSD 15 amd64 minimal QEMU-only kernel
# Target: headless VM, virtio block + net, UFS root, no physical hardware.
# Derived from MINIMAL (which is derived from GENERIC).
#
# DO NOT add physical device support here. This kernel is for QEMU/KVM only.
#
# Maintainer: architect@smolbsd.local
# Format: include MINIMAL, then remove what MINIMAL still carries for
# physical hardware; then add back QEMU-specific tuning.

include MINIMAL
ident SMOLBSD

# -----------------------------------------------------------------------
# Strip physical storage controllers (not needed in QEMU virtio-blk world)
# -----------------------------------------------------------------------
nodevice ahc            # Adaptec SCSI — physical only
nodevice ahd            # Adaptec Ultra320 — physical only
nodevice hptiop         # HighPoint RAID — physical only
nodevice isp            # Qlogic SCSI — physical only
nodevice mpt            # LSI 53C1030 — physical only
nodevice mps            # LSI SAS 2 — physical only
nodevice mpr            # LSI SAS 3 — physical only
nodevice mpi3mr         # Broadcom SAS 3.5 — physical only
nodevice sym            # Symbios 53c8xx — physical only
nodevice isci           # Intel ISCI — physical only
nodevice ocs_fc         # Emulex FC — physical only
nodevice pvscsi         # VMware PVSCSI — not QEMU virtio
nodevice arcmsr         # Areca RAID — physical only
nodevice ciss           # Compaq/HP RAID — physical only
nodevice aac            # Adaptec RAID — physical only
nodevice mfi            # LSI MegaRAID — physical only
nodevice mrsas          # LSI MegaRAID SAS — physical only
nodevice ata            # Legacy parallel ATA — virtio-blk handles storage
nodevice mvs            # Marvell SATA — physical only
nodevice siis           # SiliconImage SATA — physical only
nodevice ufshci         # UFS Host Controller — embedded storage
nodevice vmd            # Intel VMD — bare-metal NVMe aggregator

# -----------------------------------------------------------------------
# Strip physical NICs (QEMU uses virtio-net / vmxnet / e1000 emulation)
# We keep vtnet (VirtIO NIC) and remove all physical Ethernet drivers.
# -----------------------------------------------------------------------
nodevice em             # Intel 82540/82571 — use virtio-net or e1000e emul
nodevice igc            # Intel I225 2.5G — physical only
nodevice ix             # Intel 10G ixgbe — physical only
nodevice ixv            # Intel 10G ixgbe VF — physical only
nodevice ixl            # Intel 40G i40e — physical only
nodevice iavf           # Intel AVF VF — physical only
nodevice ice            # Intel E810 — physical only
nodevice mlx5           # Mellanox ConnectX-5 — physical only
nodevice aq             # Aquantia — physical only
nodevice bxe            # Broadcom 10G — physical only
nodevice rge            # Realtek 8169 — physical only
nodevice ti             # Alteon/Tigon — physical only
# Keep: vtnet (virtio-net), vmx (VMware — used by QEMU with -device vmxnet3)

# -----------------------------------------------------------------------
# Strip wireless (headless VM, no WiFi hardware)
# -----------------------------------------------------------------------
nodevice wlan           # 802.11 stack — no wireless in VM
nodevice wlan_amrr
nodevice wlan_ccmp
nodevice wlan_tkip
nodevice wlan_xauth
nodevice ath
nodevice ath_pci
nodevice ath_hal
nodevice iwn
nodevice iwi
nodevice ipw
nodevice malo
nodevice mwl
nodevice ral
nodevice wpi
nodevice iwlwifi
nodevice rtwn
nodevice rsu

# -----------------------------------------------------------------------
# Strip USB (no USB devices in headless QEMU VM)
# -----------------------------------------------------------------------
nodevice uhci           # USB 1.1 OHCI/UHCI — no USB in smolBSD QEMU
nodevice ohci
nodevice ehci           # USB 2.0
nodevice xhci           # USB 3.0
nodevice usb
nodevice usbhid
nodevice hkbd
nodevice ukbd           # USB keyboard
nodevice umass          # USB mass storage

# -----------------------------------------------------------------------
# Strip parallel port / legacy I/O
# -----------------------------------------------------------------------
nodevice ppc
nodevice ppbus
nodevice lpt

# -----------------------------------------------------------------------
# Strip sound (headless server image)
# -----------------------------------------------------------------------
nooptions SND_SUPPORT
nodevice sound
nodevice snd_hda
nodevice snd_ich
nodevice snd_via8233

# -----------------------------------------------------------------------
# Strip Hyper-V (QEMU target only, not Hyper-V)
# -----------------------------------------------------------------------
nodevice hyperv

# -----------------------------------------------------------------------
# QEMU-specific tuning
# -----------------------------------------------------------------------
# VirtIO devices kept from MINIMAL:
#   virtio, virtio_pci, virtio_blk, vtnet (virtio-net), virtio_balloon
# NVMe kept from MINIMAL (QEMU supports nvme emulation as alternative)
# Keep: ahci — QEMU also emulates AHCI SATA (needed for non-virtio disk)
# Keep: xenpci, xentimer — for Xen HVM compatibility (low cost, wide deploy)
# Keep: kvm_clock — KVM paravirtual clock (essential for timing correctness)
# Keep: efidev, efirtc — UEFI boot support
# Keep: acpi — QEMU exposes ACPI tables; graceful shutdown requires acpi

# Reduce debug overhead in production image
makeoptions    DEBUG=            # no debug symbols in kernel binary
nooptions      KDB_UNATTENDED    # panic reboot, not drop to debugger
nooptions      WITNESS           # no lock order checker in production
nooptions      INVARIANTS        # no internal consistency checks
nooptions      INVARIANT_SUPPORT
nooptions      BUF_TRACKING
nooptions      FULL_BUF_TRACKING

# compat shims: keep COMPAT_FREEBSD12 onward (needed for pkg(8) ABI)
# COMPAT_FREEBSD10, COMPAT_FREEBSD11 can be dropped for size
nooptions      COMPAT_FREEBSD10
nooptions      COMPAT_FREEBSD11
```

### 4.4 Rationale per device class

| Class | Decision | Rationale |
|-------|----------|-----------|
| SCSI/RAID controllers (ahc, ahd, mpt, mps, mpr, etc.) | STRIP | QEMU uses virtio-blk or AHCI SATA emulation. Physical SCSI/RAID drivers add ~3–6 MiB each and are dead code in a VM. |
| Physical NICs (em, ix, ixl, ice, mlx5, etc.) | STRIP | QEMU uses `virtio-net-pci` (vtnet driver) or `e1000` emulation. All physical NIC drivers are dead code. `vtnet` is kept. |
| Wireless (wlan stack, ath, iwn, etc.) | STRIP | No WiFi hardware exists in any QEMU VM. The wlan stack alone adds ~2 MiB. |
| USB stack (uhci, ohci, ehci, xhci) | STRIP | QEMU does support USB pass-through but smolBSD headless has no USB devices. Can be added as KLD if ever needed. |
| Sound | STRIP | Headless server image. Zero use case. |
| Hyper-V | STRIP | We target QEMU/KVM only. Hyper-V drivers are dead code. |
| VirtIO (virtio, virtio_pci, virtio_blk, vtnet, virtio_balloon) | KEEP | Core I/O path for QEMU virtio-net and virtio-blk. Non-negotiable. |
| AHCI | KEEP | QEMU supports AHCI SATA emulation (`-device ahci`); some deployment configs use it instead of virtio-blk. Low cost to retain. |
| NVMe (nvme, nvd) | KEEP | QEMU also emulates NVMe (`-device nvme`). Trivial size, enables flexible disk attachment. |
| ACPI | KEEP | QEMU exposes ACPI; `acpi_shutdown` provides graceful poweroff from the host. |
| KVM clock (kvm_clock) | KEEP | Paravirtual clock provides stable monotonic time; critical for TLS, logging, and time-to-ready measurements. |
| Xen HVM (xenpci, xentimer) | KEEP | Low cost; broadens deployment to Xen-based clouds (Hetzner, Citrix). |
| WITNESS/INVARIANTS | STRIP | Production kernel only. Adds ~15% memory and CPU overhead. |
| COMPAT_FREEBSD10/11 | STRIP | pkg(8) requires COMPAT_FREEBSD12+; older shims not needed. |
| DEBUG symbols | STRIP | Reduces kernel binary by ~50%. Debug build is a separate target. |

---

## 5. Image Format

**Decision**: `qcow2` (QEMU Copy-on-Write v2)

| Format | Verdict | Rationale |
|--------|---------|-----------|
| **qcow2** | CHOSEN | Native QEMU format. Supports sparse allocation (actual disk usage matches data written, not provisioned size). Snapshots at zero cost. Directly usable with `-drive file=img.qcow2,format=qcow2`. Aligns with existing fleet skill (`<aarch64-builder>` (skill-canonical name: `fb-vm-24` (drift)) produces qcow2). The FreeBSD 15.0-RELEASE official VM images ship in qcow2. |
| raw | Fallback/test | No overhead, maximum compatibility with any hypervisor. Use `qemu-img convert -O qcow2` to derive from raw. Raw is the build intermediate; qcow2 is the shipped artifact. |
| vmdk | Reject for Phase I | VMware/VirtualBox format. No current fleet use case. Can be derived from raw/qcow2 with qemu-img if needed later. |
| vhd/vhdx | Reject for Phase I | Azure/Hyper-V format. Not in current fleet scope. |

**Boot firmware**: UEFI (`edk2-x86_64-code.fd`). The release scripts default to GPT+EFI
partition layout, which requires UEFI. BIOS/MBR is a fallback if UEFI proves problematic.

**Disk layout** (GPT, matches `Makefile.vm` default):
```
Part 1: freebsd-boot  512 KiB    (GPT boot block, for BIOS fallback)
Part 2: efi           40 MiB     (FAT32, /boot/loader.efi)
Part 3: freebsd-swap  512 MiB    (1 GiB reduced to 512 MiB for smolBSD)
Part 4: freebsd-ufs   remainder  (UFS2 soft-updates, no journaling by default)
```

**Total provisioned image size**: 4 GiB (matches `VMSIZE=4g` in smolfire-qemu.conf).
**Expected qcow2 artifact size** after sparse allocation: 128–200 MiB.

---

## 6. Per-Layer Size Budget

All sizes are on-disk installed (UFS2, no compression). Kernel size is the binary
written to `/boot/kernel/kernel`.

| Layer | Budget | Basis |
|-------|--------|-------|
| Kernel binary (`/boot/kernel/kernel`, no -dbg) | 20 MiB | GENERIC ~32 MiB; SMOLBSD strips ~35–40% via nodevice/nooptions/no-DEBUG |
| Kernel modules (`/boot/kernel/*.ko`, minimal set) | 8 MiB | Only modules that can't be baked in: geom_* for boot, loader modules |
| Base userland (`FreeBSD-runtime` + `FreeBSD-clibs`) | 35 MiB | libc, libm, libutil, /etc skeleton, /bin/sh loader |
| Utilities (`FreeBSD-utilities`) | 48 MiB | Largest base package; provides vi, ed, coreutils-equivalent |
| rc.d framework (`FreeBSD-rc`) | 3 MiB | /etc/rc, /etc/rc.d/*, rc.conf |
| pkg runtime (libarchive + openssl-lib + libucl + fetch + pkg-bootstrap) | 18 MiB | pkg dependencies; FreeBSD-libarchive alone ~12 MiB installed |
| Supporting packages (certctl, kerberos-lib, libexecinfo, mtree, ee) | 6 MiB | Small ancillary packages |
| /boot loader + EFI files | 5 MiB | loader.efi, dtb, hints |
| /etc defaults + /var skeleton + /tmp | 2 MiB | Configuration files, empty dirs |
| **Total on-disk footprint** | **~145 MiB** | Sum of above |
| **qcow2 artifact size** (sparse) | **~128 MiB** | Sparse allocation ratio ~0.88 for typical UFS with ext4-like fill |
| **Hard cap** | **512 MiB** | Project constraint; this design is well under |

**Aspirational target**: qcow2 artifact < 128 MiB. Achievable if kernel modules
are further pruned and pkg bootstrap is deferred to first-boot script.

**Size reduction levers** (if over budget):
1. Replace `FreeBSD-kernel-generic` with compiled `SMOLBSD` kernel (saves ~12 MiB over generic binary)
2. Strip `/usr/share/man` from image (adds to first-boot pkg install; saves ~8 MiB)
3. Replace `FreeBSD-utilities` with hand-selected binaries from `FreeBSD-runtime` only (saves ~30 MiB but risks missing tools)
4. Compress kernel modules with `gzip -9` (loader supports compressed .ko)

---

## 7. Build Pipeline: `smolfire-qemu.conf`

The build uses FreeBSD's standard `release/` machinery. The custom configuration
file is the only novel artifact.

### 7.1 File: `release/tools/smolfire-qemu.conf`

```sh
#!/bin/sh
# smolfire-qemu.conf — FreeBSD 15 amd64 minimal QEMU VM image
# Used with: make release KERNCONF=SMOLBSD WITH_PKGBASE=yes \
#                 VMFORMATS=qcow2 VMSIZE=4g \
#                 CLOUDWARE=smolbsd CLOUDWARE_FLAGS=...

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
hostname="smolbsd"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
dumpdev="NO"
EOF

    # loader.conf: disable boot menu, use serial console
    cat >> "${DESTDIR}/boot/loader.conf" <<EOF
autoboot_delay="-1"
beastie_disable="YES"
loader_logo="none"
console="comconsole,vidconsole"
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

### 7.2 Build invocation sequence (inside <aarch64-builder> or amd64 build host)

```sh
# Inside FreeBSD 15 build host:
# (skill-canonical name: fb-vm-24 (drift; actual VM is `<aarch64-builder>`) — see spec §18.1)

# Step 1: Ensure source tree is present at /usr/src (releng/15.0)
# gitup or: git clone -b releng/15.0 https://git.freebsd.org/src.git /usr/src

# Step 2: Place kernel config
cp /usr/src/sys/amd64/conf/SMOLBSD.conf /usr/src/sys/amd64/conf/SMOLBSD
# (or write it per §4.3 above)

# Step 3: Place release config
cp smolfire-qemu.conf /usr/src/release/tools/smolfire-qemu.conf

# Step 4: Build world + kernel cross-compiled to amd64
# (if on aarch64 <aarch64-builder>):
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLBSD \
    TARGET=amd64 \
    TARGET_ARCH=amd64

# Step 5: Build pkgbase packages (creates the package repo)
make -j4 -C /usr/src packages \
    TARGET=amd64 \
    TARGET_ARCH=amd64

# Step 6: Build the VM image
make -C /usr/src/release vm-image \
    KERNCONF=SMOLBSD \
    TARGET=amd64 \
    TARGET_ARCH=amd64 \
    WITH_PKGBASE=yes \
    VMFORMATS=qcow2 \
    VMSIZE=4g \
    CLOUDWARE_CONF=/usr/src/release/tools/smolfire-qemu.conf

# Output: /usr/obj/amd64.amd64/usr/src/release/vm/
#   FreeBSD-15.0-RELEASE-amd64-SMOLBSD.qcow2
```

### 7.3 Alternative: Use Makefile.vm directly (if full release script is overkill)

```sh
make -C /usr/src/release -f Makefile.vm vm-image \
    VMBASE=FreeBSD-15-amd64-smolbsd \
    VMFORMATS="qcow2 raw" \
    VMSIZE=4g \
    KERNCONF=SMOLBSD \
    CLOUDWARE_CONF=tools/smolfire-qemu.conf
```

---

## 8. Measured Relics — Test Commands

The four Trial Gates from the campaign plan produce five metrics ("four Measured
Relics" with memory split into peak+idle). Each test command below is runnable
against a booted QEMU VM launched as:

```sh
# Reference launch command (for all tests below):
qemu-system-x86_64 \
  -M q35 -accel kvm -cpu host \
  -m 256M -smp 2 \
  -drive file=FreeBSD-15-amd64-smolbsd.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2230-:22 \
  -serial unix:/tmp/smolbsd.sock,server,nowait \
  -nographic
```

### 8.1 Build Success Rate

```sh
test -f FreeBSD-15-amd64-smolbsd.qcow2 && \
  qemu-img info FreeBSD-15-amd64-smolbsd.qcow2 | grep -E 'virtual size|disk size'
# Acceptance: exit 0 + both lines present
```

### 8.2 Time to Ready State

```sh
# tests/time-to-ready.exp
#!/usr/bin/env expect
set timeout 120
set t0 [clock seconds]
spawn qemu-system-x86_64 \
  -M q35 -accel kvm -cpu host -m 256M -smp 2 \
  -drive file=FreeBSD-15-amd64-smolbsd.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2230-:22 \
  -serial stdio -nographic
expect {
  "login:" { puts "TIME_TO_LOGIN=[expr {[clock seconds] - $t0}]s" }
  timeout  { puts "TIMEOUT"; exit 1 }
}
# Acceptance: TIME_TO_LOGIN <= 30s
```

### 8.3 Peak and Idle Memory

```sh
QEMU_PID=$(pgrep -n qemu-system-x86_64)
ps -o rss= -p $QEMU_PID                 # peak (sample at t+10s)
sleep 60; ps -o rss= -p $QEMU_PID       # idle (sample at t+60s)
ssh -p 2230 root@127.0.0.1 'sysctl vm.stats.vm.v_free_count vm.stats.vm.v_page_size'
# Acceptance: host RSS idle < 300 MiB; in-VM free >= 150 MiB in 256 MiB VM
```

### 8.4 Artifact Size

```sh
qemu-img info --output=json FreeBSD-15-amd64-smolbsd.qcow2 \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['actual-size'])"
# Acceptance: actual-size < 134217728 bytes (128 MiB aspirational)
#             actual-size < 536870912 bytes (512 MiB hard cap)
```

### 8.5 Crash Recovery Time

```sh
# Boot, wait 75s, kill -9, relaunch, poll SSH until ready
kill -9 $(pgrep -n qemu-system-x86_64); T0=$(date +%s)
qemu-system-x86_64 ... &      # relaunch
until ssh -p 2230 root@127.0.0.1 'echo RECOVERED' 2>/dev/null; do sleep 2; done
echo "CRASH_RECOVERY_TIME=$(($(date +%s) - T0))s"
# Acceptance: <= 60s (UFS soft-updates fsck path)
```

---

## 9. Configuration Files to Create

| File | Location in tree | Purpose |
|------|-----------------|---------|
| `SMOLBSD` | `/usr/src/sys/amd64/conf/SMOLBSD` | Kernel config delta (§4.3) |
| `smolfire-qemu.conf` | `/usr/src/release/tools/smolfire-qemu.conf` | Release config + package filter (§7.1) |
| `rc.conf` fragment | injected by `vm_extra_pre_umount()` | Minimal boot config |
| `loader.conf` fragment | injected by `vm_extra_pre_umount()` | Serial console + fast boot |
| `sshd_config` fragment | injected by `vm_extra_pre_umount()` | Initial access |

---

## 10. Build Host Requirements

- **OS**: FreeBSD 15.0-RELEASE (any arch that can cross-compile to amd64)
- **RAM**: 8 GiB minimum (buildworld requires ~4 GiB; <aarch64-builder> has 8 GiB — sufficient)
- **Disk**: 40 GiB free (src tree ~2 GiB, /usr/obj ~20 GiB, image artifacts ~1 GiB)
- **Tools**: `git` (fetch src), `pkg` (verify package set), `qemu-img` (validate output)
- **Cross-compile**: aarch64 → amd64 is supported by FreeBSD's build system with
  `TARGET=amd64 TARGET_ARCH=amd64`; `<aarch64-builder>` (skill-canonical name: `fb-vm-24`
  (drift)) is a valid build host. SSH access via `ssh -J <hypervisor-host> -p 2222 builder@localhost` (note port 2222, not the skill's stale 2225 — see spec §18.2).

---

## 11. Open Questions for Phase II

1. **UFS vs ZFS**: Phase I uses UFS for simplicity and size. Phase II may explore ZFS+zstd-19 (vermaden's 150 MiB physical footprint result). Tradeoff: ZFS adds ~40 MiB but enables compression that may net smaller total.
2. **pkg mirror**: Phase I assumes public pkg.freebsd.org. Phase II should seed a local Gitea-hosted pkg mirror.
3. **Swap size**: 512 MiB swap may be reducible to 256 MiB or eliminated for memory-constrained testing.
4. **cwm GUI side-quest**: Add `x11-wm/cwm` + minimal X11 as a separate image variant in Phase II.

---

## 12. Acceptance Gates (self-check)

- [x] Package set named (§3.4)
- [x] Kernel config delta from GENERIC specified (§4.3)
- [x] Build tool chosen with rationale (§2.2: release/Makefile.vm)
- [x] Image format chosen with rationale (§5: qcow2)
- [x] Per-layer size budget with total (§6: ~145 MiB on-disk, ~128 MiB artifact)
- [x] Build success rate test command (§8.1)
- [x] Time to ready state test command (§8.2)
- [x] Peak + idle memory test commands (§8.3)
- [x] Artifact size test command (§8.4)
- [x] Crash recovery time test command (§8.5)
- [x] No build commands executed — design only
- [x] File located at plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md

---

*Authored by architect@smolbsd.local — task-0001 — 2026-04-30*
*In reply to coordinator@smolbsd.local message <task-0001.coord@smolbsd.local>*
