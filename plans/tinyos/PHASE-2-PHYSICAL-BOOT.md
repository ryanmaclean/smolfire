# Phase II — Physical Boot: Pi 5 + RK3588

- **Phase**: II of IV — Physical Boot
- **Campaign**: smolBSD — The Tiny Realm vs The Rump Citadel
- **Target**: FreeBSD 15.0-RELEASE aarch64, Pi 5 (BCM2712) + RK3588, headless physical
- **Authored by**: planner@smolbsd.local (task-0023)
- **Date**: 2026-05-03
- **Status**: design-complete — DO NOT BUILD until this file is accepted

---

## 1. Mission Statement

Phase-I produced a working QEMU/HVF aarch64 VM image
(`FreeBSD-15.0-RELEASE-aarch64-SMOLBSD.qcow2`) that passes all five Measured
Relics gates. Phase II re-casts that same userland+kernel baseline into a
physical-board-bootable image for:

1. **Raspberry Pi 5** — BCM2712 SoC, RPi UEFI firmware (ACPI or FDT path)
2. **RK3588** — Cortex-A76 + A55, Rockchip UEFI or u-boot FDT path

The goal is a single bootable SD card (or NVMe) image per board that reaches
a login prompt unattended, passes the same five gate categories as Phase I
(with latency gates relaxed for physical hardware where appropriate), and
stays within the same 512 MiB hard-cap on raw disk footprint.

This file defines the build and test contract. No build commands are run here.

---

## 2. Scope

### 2.1 In scope

| Item | Notes |
|------|-------|
| qcow2 → raw + GPT conversion | `qemu-img convert` + `gpart` to produce a bootable raw image |
| Board-specific DTB injection | Pi 5: `bcm2712-rpi-5-b.dtb`; RK3588: vendor DTB from FreeBSD ports tree |
| Boot firmware selection | RPi UEFI (pftf/RPi4 adapted for Pi 5) vs u-boot per board |
| EFI System Partition layout | FAT32 ESP with firmware blob + DTB + loader.efi |
| `loader.conf` UART tuning | Physical UART path differs from QEMU virtio console |
| First-boot SD card partition layout | ESP + UFS root, GPT labels matching `fstab` |
| Serial console capture test harness | screen + expect scripts for physical board CI |
| Acceptance gates (five Measured Relics) | Adapted from Phase-I §8; latency gates relaxed for physical boot |

### 2.2 Out of scope (Phase II)

| Item | Rationale |
|------|-----------|
| Custom device drivers | Use upstream FreeBSD 15 aarch64 drivers only |
| WiFi / Bluetooth | Adds complexity; broadcom-wl and rkwifi deferred to Phase III |
| GPU / display output | smolBSD is headless; framebuffer deferred |
| NVMe boot | SD card only for Phase II; NVMe adapter support in Phase III |
| Secure boot / signed images | Out of scope; no signing infra in fleet yet |
| OTA update path | Fleet-ops concern; not part of image format for Phase II |
| 32-bit armv7 targets | BCM2712 and RK3588 are both 64-bit; no armv7 needed |

---

## 3. Board Profiles

| Field | Raspberry Pi 5 | RK3588 |
|-------|---------------|--------|
| SoC | BCM2712 (Cortex-A76 × 4) | RK3588 (Cortex-A76 × 4 + A55 × 4) |
| RAM typical | 4 GiB / 8 GiB | 8 GiB / 16 GiB |
| Boot firmware | RPi UEFI (pftf/RPi4, Pi 5 branch) | Rockchip UEFI (edk2-rk35xx) or u-boot |
| ACPI support | Yes (via RPi UEFI + ACPI tables) | No — FDT only |
| DTB file | `bcm2712-rpi-5-b.dtb` | Board-specific (e.g. `rk3588-rock-5b.dtb`) |
| Console UART | `/dev/uart0` (miniUART / PL011) | `/dev/uart2` (typical; board-dependent) |
| Storage interface | SD card (SDHOST), USB3, PCIe NVMe | eMMC, SD card, NVMe |
| FreeBSD support tier | Tier 2 (community) | Tier 3 (ports tree + wiki) |
| EFI loader path | `EFI/BOOT/BOOTAA64.EFI` | `EFI/BOOT/BOOTAA64.EFI` |
| Time-to-login gate | ≤ 60s (native; HVF baseline was 18s) | ≤ 90s (slower eMMC init) |

### 3.1 Pi 5 firmware notes

The pftf/RPi4 project (https://github.com/pftf/RPi4) targets Pi 4 but
maintains a Pi 5 branch (`rpi5`). As of 2026-05 the Pi 5 UEFI firmware is
considered beta — ACPI tables are incomplete but the FDT path works. Use
`config.txt` to select `device_tree_address` for the BCM2712 DTB.

Key `config.txt` settings for FreeBSD:

```
arm_64bit=1
enable_uart=1
dtoverlay=disable-bt
gpu_mem=16
```

### 3.2 RK3588 firmware notes

Two paths exist:

- **edk2-rk35xx** (https://github.com/edk2-porting/edk2-rk35xx) — EDK2-based
  UEFI for Rockchip; boots BOOTAA64.EFI without u-boot intermediary. Preferred
  if the target board (e.g. ROCK 5B, Orange Pi 5 Plus) has a release build.
- **u-boot + EFI stub** — mainline u-boot with `CONFIG_EFI_LOADER=y` loads
  BOOTAA64.EFI. More portable; slower first-stage boot.

Decision deferred to §5 (Boot Firmware Decision).

---

## 4. Conversion Pipeline

### 4.1 Overview

```
Phase-I artifact:
  FreeBSD-15.0-RELEASE-aarch64-SMOLBSD.qcow2  (128–135 MiB virtual disk)

Step 1: Convert to raw
  qemu-img convert -f qcow2 -O raw \
    FreeBSD-15.0-RELEASE-aarch64-SMOLBSD.qcow2 \
    smolbsd-aarch64.raw

Step 2: Mount raw image (macOS: hdiutil / FreeBSD: mdconfig)
  # On FreeBSD build host (<aarch64-builder>):
  mdconfig -f smolbsd-aarch64.raw -u 0   # -> /dev/md0

Step 3: Inject board DTB into ESP
  # Mount ESP (partition 1, FAT32)
  mount_msdosfs /dev/md0s1 /mnt/esp
  cp /usr/share/dtb/bcm2712-rpi-5-b.dtb  /mnt/esp/   # Pi 5
  # or
  cp /usr/share/dtb/rk3588-rock-5b.dtb   /mnt/esp/   # RK3588

Step 4: Adjust loader.conf for physical UART
  # Mount UFS root (partition 2)
  mount /dev/md0s2 /mnt/root
  # Pi 5:
  echo 'console="uart,io,0xfe201000"' >> /mnt/root/boot/loader.conf
  # RK3588 (uart2 base varies by board):
  echo 'console="uart,io,0xff1a0000"' >> /mnt/root/boot/loader.conf

Step 5: Place EFI firmware blob in ESP
  # Pi 5: copy RPI_EFI.fd from pftf/RPi4 Pi5 release
  cp RPI_EFI.fd /mnt/esp/
  # RK3588: edk2-rk35xx produces BOOTAA64.EFI directly; no separate blob

Step 6: Unmount + seal
  umount /mnt/esp
  umount /mnt/root
  mdconfig -d -u 0
  # Optionally compress:
  xz -9 smolbsd-aarch64-pi5.raw
```

### 4.2 SD card write

```sh
# On macOS (<hypervisor-host>):
diskutil unmountDisk /dev/diskN
dd if=smolbsd-aarch64-pi5.raw of=/dev/rdiskN bs=4m status=progress
sync
```

The raw image must be at least 512 MiB; pad with `truncate -s 512m` before
writing if the qcow2 virtual disk is smaller.

### 4.3 GPT partition layout (target)

| # | Type | Size | Label | Purpose |
|---|------|------|-------|---------|
| 1 | EFI (FAT32) | 64 MiB | ESP | Firmware blob + DTB + loader.efi |
| 2 | FreeBSD UFS | remainder | rootfs | smolBSD root filesystem |

UFS soft-updates enabled. No swap partition in Phase II (256 MiB RAM target;
add swap in Phase III for production use).

---

## 5. Boot Firmware Decision

### 5.1 Pi 5

| Option | Verdict | Rationale |
|--------|---------|-----------|
| **RPi UEFI (pftf/RPi4 Pi5 branch)** | CHOSEN | Proven FDT path; ACPI partial but not required for FreeBSD headless. Loads `BOOTAA64.EFI` from ESP. Active upstream community. |
| u-boot + EFI stub | Fallback | Use if pftf Pi5 UEFI has regressions. Adds ~3s to first-stage boot. |
| RPi bootloader direct (config.txt only) | Reject | Cannot load FreeBSD loader.efi without UEFI intermediary. No `BOOTAA64.EFI` chain. |

**Phase II default**: RPi UEFI Pi5 branch, latest release tag.

### 5.2 RK3588

| Option | Verdict | Rationale |
|--------|---------|-----------|
| **edk2-rk35xx** | PREFERRED | Clean UEFI path; no u-boot required; BOOTAA64.EFI loads directly. Available for ROCK 5B, Orange Pi 5 Plus. |
| **u-boot + EFI loader** | FALLBACK | Use for boards without edk2-rk35xx release (e.g. Khadas Edge2). `CONFIG_EFI_LOADER=y` + distro boot. |
| Petitboot | Reject | IBM-lineage bootloader; overkill, LGPL-tainted components. |

**Phase II default**: edk2-rk35xx for ROCK 5B reference board; u-boot fallback
for boards without an edk2-rk35xx release.

---

## 6. Test Strategy

### 6.1 Serial console harness

All physical-board tests use a 3.3V USB-UART adapter (CP2102 or similar)
connected to the board's debug UART header. Screen session captures output;
expect script drives the gate test.

```sh
# Attach serial console (115200 8N1)
screen /dev/tty.usbserial-* 115200

# Or via expect script (non-interactive):
expect tests/time-to-ready-physical.exp
```

### 6.2 time-to-ready-physical.exp

```sh
#!/usr/bin/env expect
# Acceptance: login prompt appears within threshold_sec
set threshold_sec 60
set t0 [clock seconds]
spawn screen -S smolbsd-serial /dev/tty.usbserial-* 115200
expect {
  "login:" {
    set elapsed [expr {[clock seconds] - $t0}]
    puts "TIME_TO_LOGIN=${elapsed}s"
    if {$elapsed > $threshold_sec} { exit 1 }
  }
  timeout { puts "TIMEOUT"; exit 1 }
}
```

Adjust `threshold_sec` per board profile (Pi 5: 60s, RK3588: 90s).

### 6.3 SSH gate (post-login)

Once login prompt is confirmed via serial, SSH is tested via the board's
Ethernet port (mDNS or static IP):

```sh
ssh -o ConnectTimeout=10 root@smolbsd-pi5.local 'uptime'
# Acceptance: exit 0, uptime string present
```

### 6.4 Test matrix

| Gate | Pi 5 | RK3588 | Method |
|------|------|--------|--------|
| 8.1 Build success | shared qcow2 → board image conversion | Verify raw image + md5 | |
| 8.2 Time to login | ≤ 60s | ≤ 90s | Serial expect |
| 8.3 Memory | host N/A; in-VM free ≥ 150 MiB | Same | SSH + sysctl |
| 8.4 Image size | raw ≤ 512 MiB | Same | ls -l |
| 8.5 Crash recovery | ≤ 90s | ≤ 120s | power-cycle + serial |

---

## 7. Acceptance Gates

Five Measured Relics, adapted for physical hardware. Gates mirror Phase-I §8
with latency ceilings raised for real-hardware boot paths.

### 7.1 Build Success (§8.1)

```sh
test -f smolbsd-aarch64-pi5.raw   && ls -lh smolbsd-aarch64-pi5.raw
test -f smolbsd-aarch64-rk3588.raw && ls -lh smolbsd-aarch64-rk3588.raw
# Acceptance: both files present, size > 256 MiB, < 512 MiB
```

### 7.2 Time to Login (§8.2)

- **Pi 5**: `TIME_TO_LOGIN` ≤ 60s via serial expect
- **RK3588**: `TIME_TO_LOGIN` ≤ 90s via serial expect (slower eMMC init +
  edk2-rk35xx POST)

### 7.3 In-VM Memory (§8.3)

```sh
ssh root@smolbsd-pi5.local \
  'sysctl vm.stats.vm.v_free_count vm.stats.vm.v_page_size'
# Acceptance: in-VM free >= 150 MiB (same as Phase-I)
# No host-RSS metric for physical boards; replace with board power-draw note only
```

### 7.4 Image Size (§8.4)

```sh
ls -l smolbsd-aarch64-pi5.raw
# Acceptance: size <= 536870912 bytes (512 MiB hard cap)
# Note: raw image includes 64 MiB ESP overhead not present in qcow2 baseline
```

### 7.5 Crash Recovery (§8.5)

```sh
# Power-cycle board (or assert /sys/class/gpio reset line via USB relay)
# Poll serial until "login:" reappears
# Acceptance: Pi 5 <= 90s, RK3588 <= 120s
```

---

## 8. Files to Create

| Path | Purpose | Status |
|------|---------|--------|
| `plans/tinyos/PHASE-2-PHYSICAL-BOOT.md` | This scope document | done |
| `release/tools/smolfire-pi5.conf` | Board config for Pi 5 raw image conversion | pending |
| `release/tools/smolfire-rk3588.conf` | Board config for RK3588 raw image conversion | pending |
| `tests/time-to-ready-physical.exp` | Serial expect script for physical time-to-login gate | pending |
| `tests/crash-recovery-physical.exp` | Power-cycle + serial recovery gate | pending |
| `scripts/qcow2-to-board-raw.sh` | Conversion pipeline wrapper (steps 1–6 of §4.1) | pending |
| `config/pi5/config.txt` | RPi firmware config (arm_64bit, uart, gpu_mem) | pending |
| `config/pi5/loader.conf.append` | UART console lines for Pi 5 boot/loader.conf | pending |
| `config/rk3588/loader.conf.append` | UART console lines for RK3588 boot/loader.conf | pending |

---

## 9. Open Questions

1. **Pi 5 UEFI maturity**: pftf/RPi4 Pi5 branch is beta as of 2026-05. If
   ACPI tables cause `acpi_error` panics on FreeBSD 15 aarch64, fall back to
   `config.txt`-driven FDT-only boot. Monitor upstream issue tracker.

2. **RK3588 board selection**: Phase II uses ROCK 5B as the reference board
   for RK3588. Other boards (Orange Pi 5 Plus, Khadas Edge2) may require
   different DTBs and UART base addresses. A board-variant matrix should be
   added in Phase III.

3. **DTB source**: FreeBSD 15 `sys/contrib/device-tree/` includes many ARM
   DTBs but BCM2712 and RK3588 coverage is still catching up. May need to
   pull DTBs from upstream Linux `arch/arm64/boot/dts/` and compile with
   `dtc` on <aarch64-builder>.

4. **UFS vs ZFS on SD**: SD cards have limited random-write endurance. UFS
   soft-updates (no journaling) is preferred for Phase II. ZFS deferred; its
   write amplification would exceed SD wear budgets.

5. **Swap on Pi 5**: BCM2712 boards typically ship with 4–8 GiB RAM. smolBSD
   targets 256 MiB allocation but physical boards allow more. A 256 MiB swap
   partition on SD is possible but adds 10–15 MiB/day wear at light load.
   Decision deferred to Phase III.

6. **SD card speed class**: Phase II tests on Class 10 / UHS-I A1. Time-to-
   login gate of 60s may be tight on slower cards. If UHS-I A1 fails, relax
   gate to 90s and note card class in evidence.

7. **USB serial adapter availability**: The CI harness assumes a CP2102-based
   USB-UART adapter is present on <hypervisor-host>. Verify `/dev/tty.usbserial-*`
   exists before running expect scripts.

---

## 10. Self-Check (Acceptance Gates)

- [x] Mission stated: convert Phase-I qcow2 to physical-boot image for Pi 5 + RK3588 (§1)
- [x] Scope table: in-scope vs out-of-scope items listed (§2)
- [x] Board profiles: Pi 5 (BCM2712) and RK3588 tabulated with firmware, DTB, UART, tier (§3)
- [x] Conversion pipeline: qcow2 → raw, DTB inject, loader.conf, ESP layout, SD write (§4)
- [x] Boot firmware decision: RPi UEFI chosen for Pi 5, edk2-rk35xx preferred for RK3588, rationale given (§5)
- [x] Test strategy: serial console harness, expect scripts, SSH gate, test matrix (§6)
- [x] Acceptance gates: five Measured Relics adapted for physical hardware (§7)
- [x] Files-to-create table with path, purpose, status (§8)
- [x] Open questions: 7 items covering firmware maturity, DTB source, UFS/ZFS, swap, SD class (§9)
- [x] No build commands executed — design only
- [x] File located at `plans/tinyos/PHASE-2-PHYSICAL-BOOT.md`

---

*Authored by planner@smolbsd.local — task-0023 — 2026-05-03*
*In reply to coordinator@smolbsd.local message <task-0023.coord@smolbsd.local>*
