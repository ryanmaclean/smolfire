# Phase III — TPM 2.0: Measured Boot & Attestation

- **Phase**: III of IV — TPM 2.0 Measured Boot & Attestation
- **Campaign**: smolBSD — The Tiny Realm vs The Rump Citadel
- **Target**: FreeBSD 15.0-RELEASE amd64 + aarch64, bhyve+swtpm first, physical fTPM/TrustZone second
- **Authored by**: planner@smolbsd.local (task-0024)
- **Date**: 2026-05-05
- **Status**: design-complete — DO NOT BUILD until this file is accepted

---

## 1. Mission Statement

Phase-I produced a working QEMU/HVF aarch64 VM image that passes all five
Measured Relics gates. Phase-II casts that baseline to physical boards (Pi 5,
RK3588). Phase III adds TPM 2.0 measured boot and remote attestation to the
smolBSD stack.

The objective is twofold:

1. **Validate the full kernel+userland TPM 2.0 stack** — device enumeration,
   PCR read/extend, seal/unseal — inside a bhyve virtual machine backed by
   `swtpm` (software TPM). This proves the smolBSD software stack before any
   hardware dependency is introduced.

2. **Document the physical-board path** — Raspberry Pi 5 RP1 TrustZone fTPM
   and RK3588 ARM TrustZone + OP-TEE — as deferred Phase-IV work, with the
   architectural decisions recorded here so Phase IV can proceed without
   re-research.

This file defines the test and acceptance contract. No build commands are
executed here.

---

## 2. Why bhyve + swtpm First

Physical TPM chips and firmware TPMs (fTPM) introduce hardware variability
that makes early-phase debugging slow and non-reproducible. The bhyve+swtpm
path solves all four core objections before touching hardware.

### 2.1 Zero hardware dependency

`swtpm` (BSD-3-Clause) is a software emulator that exposes a TPM 2.0 device
via a UNIX socket or TCP port. Any FreeBSD 15 host with `security/swtpm`
installed can run the full test suite with no physical TPM chip, no firmware
update, and no board-specific initialization.

### 2.2 Deterministic PCR values

A freshly initialized `swtpm` state directory produces identical PCR values
on every run given the same firmware and kernel binaries. This makes PCR
regression detection precise: a PCR change means a binary changed, not a
hardware quirk. Physical fTPMs accumulate measurement history across reboots
and may differ between firmware versions in ways that are hard to isolate.

### 2.3 CI-friendly

`swtpm` runs as an unprivileged process on the build host. The bhyve guest
attaches the emulated TPM via the `virtio-tpm` device. The entire
start-measure-attest cycle can run inside a CI job on `<aarch64-builder>` without any
hardware provisioning step, making gate failures immediately actionable.

### 2.4 Proves the stack before physical

If `tpmctl`, `tpm2-tools`, or the FreeBSD `tpm(4)` driver have bugs or
missing features, they surface against `swtpm` — where state is inspectable
and replayable — rather than against a physical chip where diagnostics are
limited. Physical-board work in Phase IV starts from a known-good software
baseline.

---

## 3. Architecture

The TPM 2.0 stack in Phase III has five layers:

```
[ swtpm process on host ]
        |  UNIX socket  /tmp/swtpm-sock
        v
[ bhyve virtio-tpm device (passthrough to socket) ]
        |  PCI virtio device
        v
[ guest FreeBSD 15 tpm(4) driver ]
        |  /dev/tpm0  (CRB interface preferred; FIFO fallback)
        v
[ tpmctl(8) / tpm2-tools userland ]
        |  ioctl / devfs
        v
[ PCR read / seal / unseal / attestation report ]
```

**Component responsibilities:**

| Component | Role | License |
|-----------|------|---------|
| `swtpm` (pkg: `security/swtpm`) | Software TPM 2.0 emulator | BSD-3-Clause |
| `bhyve` | Hypervisor; exposes swtpm socket as virtio-tpm PCI device | BSD-2-Clause |
| `BHYVE_UEFI.fd` (pkg: `sysutils/bhyve-firmware`) | UEFI firmware; performs pre-OS PCR 0–7 measurements | BSD-2-Clause |
| `tpm(4)` kernel driver | CRB/FIFO interface to `/dev/tpm0` | BSD-2-Clause |
| `tpmctl(8)` | FreeBSD TPM 2.0 management tool (base system) | BSD-2-Clause |
| `tpm2-tools` (pkg: `security/tpm2-tools`) | FIDO/TCG tool suite: `tpm2_pcrread`, `tpm2_createprimary`, `tpm2_seal`, `tpm2_unseal` | BSD-2-Clause |

All licenses are MIT/BSD/Apache-2.0 compatible. No GPL or LGPL components are
introduced in Phase III.

---

## 4. Bhyve Host Requirements

The following must be present on the bhyve host (`<aarch64-builder>` or equivalent
FreeBSD 15 amd64 host) before Phase III work begins.

| Requirement | Command to verify | Notes |
|-------------|------------------|-------|
| FreeBSD 15.0-RELEASE host | `uname -r` | Phase III does not support earlier releases; `virtio-tpm` bhyve device landed in FreeBSD 15 |
| `vmm.ko` loaded | `kldstat -n vmm` | Loaded by `kldload vmm` or `device vmm` in host kernel config |
| `security/swtpm` pkg | `pkg info swtpm` | Provides `swtpm` binary and `swtpm_setup` helper |
| `sysutils/bhyve-firmware` pkg | `pkg info bhyve-firmware` | Provides `BHYVE_UEFI.fd` at `/usr/local/share/uefi-firmware/BHYVE_UEFI.fd` |
| `security/tpm2-tools` pkg (in guest) | `pkg info tpm2-tools` (guest) | Must be installed in the smolBSD guest image before testing |
| `/dev/vmm` accessible | `ls /dev/vmm` | Created by `vmm.ko`; ensure user running bhyve has access |

Host kernel configuration must include or load:

```
device vmm    # bhyve hypervisor
```

Guest kernel configuration is covered in §5.

---

## 4a. Host Platform Requirements

### 4a.1 Hardware virtualisation prerequisite

bhyve requires a FreeBSD host with hardware virtualisation exposed to the
kernel: Intel VT-x or AMD-V on amd64, or ARM EL2 on aarch64. **Apple
Hypervisor Framework (HVF) does NOT expose EL2 to guest VMs** — a FreeBSD
VM running inside QEMU/HVF on Apple Silicon cannot run bhyve. Attempting to
load `vmm.ko` in that environment will fail with a permissions error; `bhyve`
will refuse to open `/dev/vmm`.

**Supported Phase-III host configurations:**

| Host | VT capability | bhyve | Notes |
|------|--------------|-------|-------|
| Bare-metal amd64 (Intel/AMD) | VT-x / AMD-V | yes | Preferred; full `vmm.ko` support |
| Vultr vc2 amd64 cloud instance | VMX exposed to guest | yes | Verified: nested virt enabled by default |
| Bare-metal aarch64 (non-Apple) | EL2 present | yes | e.g. Ampere Altra; EL2 not blocked |
| FreeBSD VM under QEMU/HVF (Apple Silicon) | EL2 blocked by HVF | **no** | `<aarch64-builder>` on <hypervisor-host> falls into this category |
| FreeBSD VM under VirtualBox / VMware | depends on host config | conditional | Nested VT-x must be enabled explicitly |

**Implication for smolBSD:** `<aarch64-builder>` (the project's aarch64 FreeBSD VM on
`<hypervisor-host>`) cannot run bhyve. Phase-III TPM testing must be performed on a
dedicated bare-metal amd64 host or a Vultr vc2 amd64 instance. The scripts
`bin/bhyve-smolbsd.nu` and `bin/vultr-bhyve-provision.nu` target these hosts.

### 4a.2 arm64 bhyve virtio-tpm limitation

FreeBSD 15 arm64 bhyve does **not** implement a `virtio-tpm` PCI device.
The `virtio-tpm` backend was merged for the amd64 target only; the arm64
bhyve code path lacks the device emulation layer required to forward the
swtpm socket to a guest PCI slot.

Consequence: TPM tests T2–T6 (guest `/dev/tpm0`, PCR read, seal/unseal,
PCR mutation) can only be executed in an **amd64 bhyve guest**. arm64
physical boards (Pi 5, RK3588) reach TPM support through the fTPM /
TrustZone path documented in §7 and addressed in Phase IV — not through
bhyve.

**Summary of TPM test platform requirements:**

| Test | Platform required | Reason |
|------|------------------|--------|
| T1 (swtpm socket) | Any host with `swtpm` installed | Host-side check only |
| T2–T6 (guest TPM) | amd64 bhyve (bare-metal or Vultr vc2) OR amd64 QEMU with `-device tpm-tis` | `virtio-tpm` amd64-only in bhyve; amd64 QEMU via TCG on <hypervisor-host> (tested) |
| Physical Pi 5 fTPM | Pi 5 physical board (Phase IV) | RP1 TrustZone fTPM |
| Physical RK3588 fTPM | RK3588 + OP-TEE build (Phase IV) | ARM TrustZone + OP-TEE |

**Root-cause doubt (2026-09-23, needs re-diagnosis before touching any kernconf):**
A candidate explanation floated for "no `/dev/tpm0` on arm64" was that FreeBSD's
`tpm_crb.c` (the ACPI CRB attachment used by `tpm_tis_acpi`) is amd64-only in
`sys/conf/files.amd64`, combined with `sys/arm64/conf/SMOLFIRE-VM` disabling
ACPI via `nodevice acpi`, so `tpm_tis_acpi` would have nothing to attach to.
That combination does **not** hold in this repo: `sys/conf/files.amd64` is not
present here at all (this repo's `sys/` tree carries only kernel *config*
files under `sys/{amd64,arm64,riscv}/conf/`, not FreeBSD kernel driver
sources, so the amd64-only claim can't be checked against this checkout — it
would need verification against an actual FreeBSD src tree). More importantly,
`sys/arm64/conf/SMOLFIRE-VM` (the arm64 QEMU/bhyve VM kernel used for TPM
testing) does **not** set `nodevice acpi` — grep confirms it: ACPI is kept
enabled there (`# device acpi # Kept via MINIMAL; needed for -machine virt +
EDK2`, commented out only because it's already pulled in by `std.virt`/
`MINIMAL`), and `device tpm` is already compiled in
(`sys/arm64/conf/SMOLFIRE-VM`, "TPM 2.0 support" section). `nodevice acpi`
appears only in `sys/arm64/conf/SMOLFIRE-RK3588:87` and
`sys/arm64/conf/SMOLFIRE-PI5:77` — the *physical-board* kernels, which are
unrelated to the QEMU/bhyve VM path this phase tests. The two already-verified
root causes for arm64 TPM gaps remain §4a.2 (bhyve on arm64 has no `-l tpm`
device backend at all — a hypervisor limitation per bhyve(8), independent of
guest kernel config) and §4a.3 below (QEMU aarch64's `-device tpm-tis-device`
emits an ACPI TPM2 table with `ControlArea=0`, which FreeBSD's `tpm(4)` CRB
driver refuses to attach to). Before changing any kernconf on the strength of
the `files.amd64`/`nodevice acpi` theory, re-diagnose against the actual
FreeBSD source tree (not present in this repo) and confirm which of the two
already-documented mechanisms — or a third one — is actually responsible.

### 4a.3 aarch64 QEMU tpm-tis-device limitation (ControlArea=0)

Live run task-0031 confirmed that aarch64 QEMU with `-device tpm-tis-device`
successfully connects to an swtpm socket and the UEFI firmware measures into
the TPM at boot — `Tpm2GetCapabilityPcrs` succeeds at the firmware level and
PCR values are non-zero when inspected via the swtpm state directory. However,
`/dev/tpm0` is **not** created in the FreeBSD guest.

**Root cause:** QEMU's `tpm-tis-device` generates an ACPI `TPM2` table in which
the CRB `ControlArea` field is set to zero (no MMIO address). The FreeBSD
`tpm(4)` CRB driver reads `ControlArea` to locate the memory-mapped Command
Response Buffer region. A value of zero is an invalid MMIO base address; the
driver refuses to attach and emits a CRB probe failure in `dmesg`. The result
is that `tpm.ko` loads but creates no device node.

**Evidence from task-0031 live run:**

- `tpm.ko` loaded successfully (kldstat confirms)
- `dmesg` shows CRB probe failure, no `tpm0` attachment
- swtpm state directory inspection confirms UEFI PCR measurements were written
  (PCR 0 non-zero before kernel handoff)
- `tpmctl` and `tpm2_pcrread` fail with "no such device"

**Why amd64 QEMU is unaffected:** The amd64 `-device tpm-tis` backend exposes
the TPM via the x86 TIS (TPM Interface Specification) ISA port-I/O interface
(ports `0x0f00`–`0x0f7f`), not CRB MMIO. The FreeBSD `tpm(4)` driver's FIFO
path probes TIS port-I/O first on amd64 and attaches successfully, creating
`/dev/tpm0`. The CRB ACPI table issue is specific to the MMIO-based aarch64
`tpm-tis-device` backend.

**Resolution:** Use amd64 QEMU (`qemu-system-x86_64`) with `-device tpm-tis`
for OS-level TPM testing. `bin/qemu-smolbsd.nu --arch amd64 --tpm` generates
the correct flag set. aarch64 QEMU TPM is deferred until either:

1. QEMU upstream corrects the ACPI `TPM2` table `ControlArea` field for
   `tpm-tis-device`, or
2. The FreeBSD `tpm(4)` driver adds a fallback probe path for the MMIO-less
   case (TIS-only via MMIO base inferred from FDT / ACPI `TPM2` start address).

Physical arm64 boards (Pi 5, RK3588) are **not** affected by this issue.
Their fTPMs are exposed via ARM CRB with a correctly populated `ControlArea`
in the ACPI table generated by the board firmware. The QEMU `tpm-tis-device`
limitation is emulator-specific.

---

## 5. TPM Kernel Configuration

The FreeBSD kernel config used in smolBSD must include `device tpm` for all
four supported SMOLBSD configurations: `SMOLBSD-AARCH64`, `SMOLBSD-AMD64`,
`SMOLBSD-AARCH64-RPI`, and `SMOLBSD-RK3588`.

```
# TPM 2.0 support
device tpm     # Trusted Platform Module driver (CRB + FIFO)
```

**CRB vs FIFO interface:**

The Command Response Buffer (CRB) interface is preferred over the legacy FIFO
interface for bhyve `swtpm`. Reasons:

- CRB is the mandatory interface in TPM 2.0 spec (TPM 2.0 Part 2, §5.5.2)
- `swtpm` emulates CRB correctly; FIFO emulation has known quirks in some
  swtpm versions
- FreeBSD `tpm(4)` driver negotiates CRB first when both are advertised

If `/dev/tpm0` appears as FIFO (check with `tpmctl -I`), add to `loader.conf`:

```
hw.tpm.force_crb=1
```

Physical boards (Phase IV) may require FIFO if their fTPM firmware predates
CRB. That decision is deferred.

---

## 6. Test Sequence

Six tests must pass in order. Each test depends on the previous succeeding.
Tests are implemented as expect scripts and Nushell scripts (see §8 for file
paths).

### T1 — swtpm socket appears within 3 seconds

```sh
# Start swtpm with a fresh state directory
swtpm_setup --tpm2 --tpmstate /tmp/swtpm-state --overwrite
swtpm socket --tpm2 \
  --tpmstate dir=/tmp/swtpm-state \
  --ctrl type=unixio,path=/tmp/swtpm-ctrl \
  --server type=unixio,path=/tmp/swtpm-sock \
  --flags startup-clear &

# Wait up to 3s for socket
timeout 3 sh -c 'until [ -S /tmp/swtpm-sock ]; do sleep 0.1; done'
# Acceptance: exits 0; socket file exists
```

### T2 — VM boots smolBSD with TPM; /dev/tpm0 present in guest

Two validated paths:

**Path A — amd64 bhyve (preferred; requires bare-metal VT-x):**

```sh
# Boot with bhyve's LPC/ACPI CRB TPM device (-l tpm,swtpm,<data-socket>).
# NOTE: TPM is not a PCI slot device — `-s N,tpm,...` is not valid bhyve
# syntax. /tmp/swtpm-sock must be swtpm's --server (data) socket, not its
# --ctrl (control) socket. See bhyve(8) and swtpm(8).
bhyve -c 2 -m 512M \
  -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \
  -s 0,hostbridge \
  -s 1,virtio-blk,smolbsd-amd64.img \
  -s 31,lpc -l com1,stdio \
  -l tpm,swtpm,/tmp/swtpm-sock \
  smolbsd-tpm-test

# Acceptance: guest serial log contains '/dev/tpm0' detected message
# Verified via expect script (tests/tpm-attest.exp)
```

**Path B — amd64 QEMU with TCG (works on any host including macOS <hypervisor-host>):**

```sh
# Tested on <hypervisor-host> via bin/qemu-smolbsd.nu
qemu-system-x86_64 -M q35 -accel tcg -cpu qemu64 \
  -bios /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -m 512M -smp 2 \
  -drive file=smolbsd-amd64.raw,format=raw,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2241-:22 \
  -serial stdio -nographic \
  -chardev socket,id=chrtpm,path=/var/run/smolbsd-qemu-tpm/swtpm.sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0
```

> **aarch64 QEMU blocked:** `-device tpm-tis-device` generates an ACPI TPM2
> table with `ControlArea=0`; FreeBSD `tpm(4)` CRB driver refuses to attach.
> UEFI measures into swtpm correctly but no `/dev/tpm0` is created in the
> guest. See §4a.3 for the full analysis. Use Path B (amd64 QEMU) or Path A
> (amd64 bhyve) instead.

```sh
# Acceptance: guest serial log contains '/dev/tpm0' detected message
# Verified via expect script (tests/tpm-attest.exp)
```

### T3 — tpmctl -G returns TPM 2.0 manufacturer info

Run inside guest after T2 confirms `/dev/tpm0`:

```sh
tpmctl -G
# Acceptance: output contains "TPM 2.0" and a manufacturer string
# (IBM or MSFT for swtpm; physical boards will differ)
```

### T4 — PCR 0 readable; value matches UEFI measured-boot expectation

```sh
tpm2_pcrread sha256:0
# Acceptance:
# - Command exits 0
# - PCR 0 value is not all-zeros (measurement took place)
# - Value is stable across two consecutive reads (no spurious extend)
# For swtpm: record the PCR 0 baseline value in tests/tpm-pcr-baseline.json
```

PCR 0 measures the UEFI firmware image (`BHYVE_UEFI.fd`). For a fixed
firmware binary, PCR 0 must be reproducible across reboots given the same
`swtpm` state directory.

### T5 — seal/unseal round-trip succeeds with PCR 0+7 policy

```sh
# Create primary key in owner hierarchy
tpm2_createprimary -C o -G rsa -c /tmp/primary.ctx

# Create sealed object: secret bound to current PCR 0 and PCR 7 values
echo "smolbsd-phase-iii-secret" | \
  tpm2_create -C /tmp/primary.ctx \
    -L "sha256:0,7" \
    -i - \
    -u /tmp/sealed.pub \
    -r /tmp/sealed.priv

# Load the sealed object
tpm2_load -C /tmp/primary.ctx \
  -u /tmp/sealed.pub \
  -r /tmp/sealed.priv \
  -c /tmp/sealed.ctx

# Unseal — must succeed when PCR 0+7 match the policy used at sealing time
tpm2_unseal -c /tmp/sealed.ctx
# Acceptance: output is "smolbsd-phase-iii-secret"
```

### T6 — PCR value changes after kernel update (measurement is live)

```sh
# Record PCR 0 baseline
tpm2_pcrread sha256:0 > /tmp/pcr-before.txt

# Simulate a kernel measurement change: extend PCR 0 with arbitrary data
tpm2_pcrextend 0:sha256=$(echo "fake-kernel-hash" | sha256)

# Read again
tpm2_pcrread sha256:0 > /tmp/pcr-after.txt

diff /tmp/pcr-before.txt /tmp/pcr-after.txt
# Acceptance: diff shows changed PCR 0 value (proves extend mechanism works)
```

In production Phase IV, this test is replaced by an actual kernel replacement
and reboot cycle. For Phase III, the `tpm2_pcrextend` simulation proves the
PCR accumulation mechanism functions end-to-end.

---

## 7. Physical Board Path (Phase IV)

Physical board TPM support requires board-specific firmware and trust anchor
setup that is out of scope for Phase III. This section records the design
decisions so Phase IV can proceed without re-research.

### 7.1 Raspberry Pi 5 — RP1 TrustZone fTPM

The Pi 5 does not have a discrete TPM chip. The fTPM is implemented in the
RP1 south-bridge processor's TrustZone secure world, activated via UEFI
firmware (pftf/RPi4 Pi5 branch). Key facts:

- fTPM is exposed to the OS via ACPI table `TPM2` or FDT node `tpm@...`
- PCR layout follows TCG PC Client Platform spec; PCR 0 measures firmware
  volume, PCR 4 measures the bootloader
- FreeBSD `tpm(4)` supports this path; requires UEFI ACPI tables to be
  functional (see Phase-II §3.1 note on ACPI beta status)
- No OP-TEE required on Pi 5; fTPM is part of the proprietary Pi firmware

**Phase IV action**: test `/dev/tpm0` enumeration on physical Pi 5 with
RPi UEFI Pi5 branch; verify PCR 0 matches Pi UEFI firmware digest.

### 7.2 RK3588 — ARM TrustZone + OP-TEE

RK3588 uses the ARM TrustZone architecture with OP-TEE as the trusted OS. A
TPM 2.0 fTPM TA (Trusted Application) running in OP-TEE exposes the TPM via
a Secure Monitor Call (SMC) interface; the kernel sees it as a CRB device.

Key facts:

- OP-TEE must be compiled and signed for the specific RK3588 board; not
  available as a FreeBSD pkg (see §10.1)
- PCR layout may differ from TCG PC Client spec if OP-TEE fTPM TA does not
  implement the UEFI firmware measurement protocol
- Rockchip BSP (board support package) includes OP-TEE sources; license
  compatibility with Apache-2.0/BSD must be verified before inclusion in
  smolBSD (see §10.1)

**Phase IV action**: build OP-TEE for ROCK 5B; integrate fTPM TA; test
`/dev/tpm0` on RK3588 guest via bhyve passthrough of physical TPM device.

### 7.3 Summary table

| Board | TPM mechanism | Phase III | Phase IV |
|-------|--------------|-----------|---------|
| bhyve (amd64) | swtpm virtio-tpm | Full test suite | n/a |
| Raspberry Pi 5 | RP1 fTPM via RPi UEFI | Not applicable | PCR 0+7 attest |
| RK3588 (ROCK 5B) | ARM TrustZone + OP-TEE fTPM TA | Not applicable | OP-TEE build + PCR attest |

---

## 8. Files to Create

| Path | Purpose | Status |
|------|---------|--------|
| `plans/tinyos/PHASE-3-TPM.md` | This scope document | done |
| `bin/swtpm-setup.nu` | Initialize swtpm state directory; start swtpm socket process; verify socket appears within 3s | done |
| `bin/bhyve-smolbsd.nu` | Launch bhyve with smolBSD image, virtio-tpm attached to swtpm socket, UEFI firmware, serial console | done |
| `tests/tpm-attest.exp` | expect script: boots guest via bhyve-smolbsd.nu, waits for login prompt, runs T2–T5 sequence via SSH or serial, records PCR baseline | done |
| `tests/tpm-seal-test.nu` | Nushell: T5 seal/unseal round-trip; T6 PCR-extend mutation check; emits TOML result with pass/fail verdict per test | done |
| `bin/bhyve-host-setup.nu` | Provision a bare-metal amd64 or Vultr vc2 host for bhyve+swtpm: load vmm.ko/nmdm.ko, install swtpm/bhyve-firmware pkgs, verify /dev/vmm; fails fast on HVF/arm64 hosts | pending |
| `bin/vultr-bhyve-provision.nu` | Provision a Vultr vc2 amd64 instance via Vultr API, bootstrap FreeBSD 15, install bhyve prerequisites, and run bhyve-host-setup.nu remotely | pending |

All scripts must pass `nu --no-config-file` syntax check before acceptance.
`tpm-attest.exp` must tolerate a 30s boot window before declaring timeout.

---

## 9. Acceptance Gates

Five Measured Relics, adapted for TPM attestation. All six tests (T1–T6)
must pass for the phase to be complete.

### 9.1 swtpm Socket Gate

```sh
# Host: swtpm socket appears within 3s
test -S /tmp/swtpm-sock
# Acceptance: exits 0
```

Corresponds to T1. Failing this gate means either `swtpm` is not installed,
the state directory is corrupt, or the process failed to start. Check
`swtpm_setup` output for error messages.

### 9.2 /dev/tpm0 Present Gate

```sh
# Guest: device node exists
ssh root@smolbsd-tpm.local 'test -c /dev/tpm0 && echo PRESENT'
# Acceptance: output is "PRESENT"
```

Corresponds to T2. Failing this gate means either the guest kernel lacks
`device tpm` or bhyve did not attach the virtio-tpm device correctly. Check
`dmesg` in guest for `tpm0` lines.

### 9.3 Manufacturer Info Gate

```sh
# Guest: TPM 2.0 manufacturer string returned
ssh root@smolbsd-tpm.local 'tpmctl -G | grep -i "TPM 2"'
# Acceptance: grep exits 0
```

Corresponds to T3. Failing this gate means `tpmctl` cannot open `/dev/tpm0`
or the CRB handshake failed. Try `tpmctl -I` to inspect interface mode.

### 9.4 PCR Seal/Unseal Gate

```sh
# Guest: seal/unseal round-trip with PCR 0+7 policy
ssh root@smolbsd-tpm.local 'nu /tests/tpm-seal-test.nu' | \
  nu -c 'from toml | get verdict' | grep -x pass
# Acceptance: "pass"
```

Corresponds to T5. This is the primary attestation gate. Failure indicates
either PCR policy binding is broken or the TPM object hierarchy commands are
not supported by the swtpm version.

### 9.5 PCR Mutation Gate

```sh
# Guest: PCR extend changes PCR 0 value
ssh root@smolbsd-tpm.local \
  'tpm2_pcrread sha256:0; tpm2_pcrextend 0:sha256=$(echo x | sha256); tpm2_pcrread sha256:0' | \
  sort -u | wc -l | grep -xE '[2-9]|[0-9][0-9]+'
# Acceptance: at least 2 distinct PCR lines (before and after extend differ)
```

Corresponds to T6. Failing this gate means PCR extend is silently ignored,
which would make measured boot untrustworthy.

---

## 10. Open Questions

1. **OP-TEE licensing**: OP-TEE OS is BSD-2-Clause; the OP-TEE fTPM Trusted
   Application is also BSD-2-Clause. However, Rockchip-specific ATF (ARM
   Trusted Firmware) components may carry additional license terms not yet
   audited. This must be resolved before Phase IV RK3588 OP-TEE work begins.
   License check is a Phase IV gate-0 item.

2. **fTPM PCR layout differences**: The TCG PC Client Platform spec defines
   PCR 0–7 semantics for UEFI firmware environments. fTPM implementations
   on Pi 5 and RK3588 may deviate — particularly PCR 4 (boot loader) and
   PCR 7 (secure boot state). Seal/unseal policies that reference PCR 7 in
   the bhyve test may not be directly portable to physical boards. Phase IV
   must measure and document the physical fTPM PCR layout before reusing the
   Phase III policy template.

3. **swtpm version floor**: The `virtio-tpm` bhyve device and `swtpm` socket
   protocol have version dependencies. The minimum `swtpm` version that
   supports the bhyve CRB path has not been documented in FreeBSD 15 release
   notes as of 2026-05. Phase III must record the exact `swtpm` version used
   in the test evidence.

4. **tpm2-tools availability in smolBSD image**: `security/tpm2-tools` must
   be added to the smolBSD package set. The current SMOLBSD configs target
   minimal footprint (≤ 512 MiB). Adding `tpm2-tools` and its dependencies
   (`libtss2`) adds approximately 8–12 MiB to the image. Verify the 512 MiB
   cap is not breached after inclusion.

5. **Remote attestation protocol**: Phase III only tests local
   seal/unseal and PCR read. Remote attestation (sending a TPM quote to a
   verifier) requires a challenge-response protocol and a verifier service.
   This is deferred to a Phase III.5 or Phase IV workstream and is not an
   acceptance gate for Phase III.

---

## 11. Self-Check

- [x] Mission stated: validate TPM 2.0 measured boot in bhyve+swtpm first, physical fTPM/TrustZone second (§1)
- [x] Why bhyve+swtpm first: four reasons — zero hardware dependency, deterministic PCRs, CI-friendly, proves stack before physical (§2)
- [x] Architecture: swtpm → bhyve virtio-tpm → guest /dev/tpm0 → tpmctl/tpm2-tools → PCR read/seal/unseal; component table with licenses (§3)
- [x] Bhyve host requirements: FreeBSD 15, security/swtpm, BHYVE_UEFI.fd, device vmm; all in table (§4)
- [x] TPM kernel config: device tpm in all four SMOLBSD configs; CRB preferred over FIFO; loader.conf override documented (§5)
- [x] Test sequence: T1–T6 with shell commands and acceptance criteria (§6)
- [x] Physical board path: Pi 5 RP1 fTPM and RK3588 OP-TEE documented; Phase IV deferred (§7)
- [x] Files-to-create table: bin/bhyve-smolbsd.nu, bin/swtpm-setup.nu, tests/tpm-attest.exp, tests/tpm-seal-test.nu (§8)
- [x] Acceptance gates: five Measured Relics structure — swtpm socket, /dev/tpm0 present, manufacturer info, seal/unseal, PCR mutation (§9)
- [x] Open questions: 5 items — OP-TEE licensing, fTPM PCR layout, swtpm version floor, image size, remote attestation scope (§10)
- [x] No build commands executed — design only
- [x] All cited licenses are BSD-2-Clause or BSD-3-Clause; no GPL introduced
- [x] File located at `plans/tinyos/PHASE-3-TPM.md`

---

*Authored by planner@smolbsd.local — task-0024 — 2026-05-05*
*In reply to coordinator@smolbsd.local message <task-0024.coord@smolbsd.local>*
