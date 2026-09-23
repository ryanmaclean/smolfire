# VM Testing — smolfire bhyve + swtpm Test Suite

Operator guide for running the Phase-III TPM test suite against a smolfire image
inside bhyve on a FreeBSD 15 host.

---

## Host Requirements

> **bhyve requires a bare-metal amd64 host with VT-x/AMD-V.** arm64 bhyve
> (Apple Silicon HVF guest) cannot run nested VMs. TPM testing requires amd64
> bhyve.
>
> | Scenario | Supported? | Notes |
> |---|---|---|
> | FreeBSD 15 amd64 bare-metal (VT-x/AMD-V) | Yes | Full test suite including TPM |
> | Vultr vc2/vhf amd64 cloud instance | Yes | VMX exposed by default |
> | FreeBSD 15 aarch64 bare-metal (Ampere/Vultr arm64) | Partial | `--arch arm64` works; no TPM |
> | Apple Silicon Mac running FreeBSD under HVF | No | HVF does not expose EL2; `vmm.ko` fails to load |
> | Any VM with nested virtualisation disabled | No | bhyve requires hardware VMX/SVM |
>
> Passing `--tpm` with `--arch arm64` to `bin/bhyve-smolfire-vm.nu` will produce
> an explicit error: `arm64 bhyve has no virtio-tpm device; TPM testing
> requires --arch amd64`.

---

## 1. Prerequisites

> **⚠ bhyve host requirement: bare-metal amd64 with VT-x/AMD-V, OR a cloud VM
> with nested virtualization exposed. Apple Silicon Macs running FreeBSD under
> HVF cannot run bhyve — HVF does not expose EL2 to guest VMs, so `vmm.ko`
> will fail to load. Vultr vc2/vhf amd64 instances work (VMX is exposed by
> default). arm64 bhyve lacks `virtio-tpm` — TPM tests T2–T6 require an amd64
> bhyve host. See `plans/tinyos/PHASE-3-TPM.md §4a` for the full platform
> requirements matrix.**

**Host OS:** FreeBSD 15.0-RELEASE amd64 (bhyve `virtio-tpm` landed in FreeBSD 15).

**Kernel modules** (load once per boot, or add to `/boot/loader.conf`):

```sh
kldload vmm
kldload nmdm
```

**Packages:**

```sh
pkg install security/swtpm sysutils/bhyve-firmware emulators/qemu-utils \
            lang/expect
```

| Package | Provides | License |
|---|---|---|
| `security/swtpm` | `swtpm`, `swtpm_setup` | BSD-3-Clause |
| `sysutils/bhyve-firmware` | `BHYVE_UEFI.fd` at `/usr/local/share/uefi-firmware/` | BSD-2-Clause |
| `emulators/qemu-utils` | `qemu-img` (convert + check) | Apache-2.0 |
| `lang/expect` | `expect` interpreter for serial console scripts | BSD-derived |

**Guest image must include** (baked into the smolfire build):

```sh
pkg install security/tpm2-tools   # tpm2_pcrread, tpm2_create, tpm2_seal, tpm2_unseal
```

**Verify host readiness** before running any test:

```sh
nu bin/prep-bhyve-image.nu --help   # smoke-tests nu availability
nu -c 'use bin/prep-bhyve-image.nu; check-bhyve-host | to toml'
```

`check-bhyve-host` returns `{ready: true, missing: []}` when all four
conditions pass: `/dev/vmm` exists, `/usr/sbin/bhyve` present, `BHYVE_UEFI.fd`
findable, `/dev/nmdm0A` exists.

---

## 2. Quick Start

Four commands from a fresh qcow2 artifact to a passing test suite:

```sh
# 1. Convert qcow2 → raw (pads to 512 MiB minimum, verifies disk signature)
nu bin/prep-bhyve-image.nu --input FreeBSD-15.0-RELEASE-amd64-SMOLFIRE-VM.qcow2

# 2. Initialize and start the software TPM daemon
nu bin/swtpm-setup.nu --action start

# 3. Boot the VM (blocks until bhyve exits; attach console in another terminal)
nu bin/bhyve-smolfire-vm.nu --image FreeBSD-15.0-RELEASE-amd64-SMOLFIRE-VM.raw --tpm

# 4. Run the TPM test suite against the running guest
nu bin/run-vm-tests.nu --image FreeBSD-15.0-RELEASE-amd64-SMOLFIRE-VM.raw --tpm
```

Attach the serial console from a second terminal while step 3 runs:

```sh
cu -l /dev/nmdm0B
# or: minicom -D /dev/nmdm0B
```

---

## 3. Test Coverage

| Test | What it validates | Pass threshold |
|---|---|---|
| T1 swtpm-socket | swtpm Unix socket appears within 3 s of daemon start | socket file present; `test -S` exits 0 |
| T2 tpm0-present | Guest kernel enumerates `/dev/tpm0` via `tpm(4)` driver | dmesg / `test -c /dev/tpm0` exits 0 |
| T3 manufacturer-info | `tpmctl -G` returns TPM 2.0 manufacturer string | output contains `TPM 2` |
| T4 pcr-read | `tpm2_pcrread sha256:0` exits 0; PCR 0 is non-zero and stable | two consecutive reads return identical non-zero value |
| T5 seal-unseal | Seal secret under PCR 0+7 policy; unseal returns exact secret | unseal stdout == `smolfire-seal-test` |
| T6 pcr-extend | `tpm2_pcrextend` changes PCR 0 value (proves accumulation) | before/after PCR 0 values differ |

All six must pass for Phase III acceptance.

> **aarch64 QEMU TPM limitation:** `swtpm` + `-device tpm-tis-device` works at
> firmware level (UEFI measures into PCRs; swtpm state shows non-zero PCR 0
> before kernel handoff) but `/dev/tpm0` is **not** created in the FreeBSD
> guest. Root cause: QEMU aarch64 generates an ACPI `TPM2` table with
> `ControlArea=0`; the FreeBSD `tpm(4)` CRB driver reads `ControlArea` to
> locate the MMIO CRB region, treats zero as invalid, and refuses to attach.
> **Use amd64 QEMU with `-device tpm-tis`** (`bin/qemu-smolfire-vm.nu --arch amd64
> --tpm`) for OS-level TPM testing (T2–T6). amd64 QEMU with TCG works on
> macOS/<hypervisor-host> without VT-x. See `plans/tinyos/PHASE-3-TPM.md §4a.3` for
> the full analysis and evidence from task-0031.

---

## 4. TPM Test Sequence (T1–T6)

```sh
# T1 — swtpm socket: run on HOST after swtpm-setup.nu start
test -S /var/run/smolfire-tpm/swtpm.sock && echo T1:pass || echo T1:fail

# T2 — /dev/tpm0: run in GUEST via serial or SSH
ssh root@<guest-ip> 'test -c /dev/tpm0 && echo T2:pass || echo T2:fail'

# T3 — manufacturer info: run in GUEST
ssh root@<guest-ip> 'tpmctl -G | grep -qi "TPM 2" && echo T3:pass || echo T3:fail'

# T4 — PCR 0 readable and stable: run in GUEST
ssh root@<guest-ip> 'a=$(tpm2_pcrread sha256:0); b=$(tpm2_pcrread sha256:0); [ "$a" = "$b" ] && echo T4:pass || echo T4:fail'

# T5 — seal/unseal round-trip: run in GUEST
ssh root@<guest-ip> 'nu /tests/tpm-seal-test.nu' | nu -c 'from toml | get verdict'

# T6 — PCR extend mutates PCR 0: run in GUEST
ssh root@<guest-ip> 'before=$(tpm2_pcrread sha256:0); tpm2_pcrextend 0:sha256=$(echo fake | sha256); after=$(tpm2_pcrread sha256:0); [ "$before" != "$after" ] && echo T6:pass || echo T6:fail'
```

The `tests/tpm-attest.exp` expect script drives T2–T5 automatically over the
bhyve serial console without requiring SSH or a guest IP.

---

## 5. Reading the Results TOML

Every `bin/*.nu` script emits structured TOML log-step blocks separated by
`---`. Capture and parse with:

```sh
# Capture all log output from a test run
nu bin/run-vm-tests.nu --image smolfire.raw --tpm | tee run.toml

# Extract only pass/fail verdicts
nu -c "open run.toml | lines | where ($it | str contains 'verdict') | print"

# Parse individual step records (each block between --- is one TOML document)
nu -c "
  open --raw run.toml
  | split row '---'
  | each { |block| $block | str trim }
  | where ($it | str length) > 0
  | each { |block| $block | from toml }
  | where step =~ '^T[1-6]'
  | select step verdict
  | to table
"
```

The seal/unseal test (`tests/tpm-seal-test.nu`) emits a single top-level
record with a `verdict` field: `pass` or `fail`, plus per-test detail fields
`t5_unseal_output` and `t6_pcr_changed`.

---

## 6. Troubleshooting

**`/dev/nmdm0A` not available**

```
Error: nmdm.ko not loaded
```

```sh
kldload nmdm
# persist: echo 'nmdm_load="YES"' >> /boot/loader.conf
```

**swtpm socket timeout (T1 fails)**

```
swtpm socket did not appear within 3s
```

Check that `swtpm_setup` initialized the state directory first:

```sh
swtpm_setup --tpm2 --tpmstate /var/run/smolfire-tpm --overwrite
nu bin/swtpm-setup.nu --action status
# If still failing, inspect syslog: grep swtpm /var/log/messages
```

**bhyve UEFI firmware not found**

```
WARNING: UEFI ROM not found — install sysutils/bhyve-firmware
```

```sh
pkg install sysutils/bhyve-firmware
ls /usr/local/share/uefi-firmware/BHYVE_UEFI.fd
```

**`/dev/tpm0` missing in guest (T2 fails)**

The guest kernel must have `device tpm` compiled in. Check:

```sh
# In guest
dmesg | grep -i tpm
# Expected: tpm0: <TPM 2.0> on pci0
```

If absent, the smolfire kernel config is missing `device tpm` or the VM was
launched without `--tpm`. Confirm the bhyve command line includes:

```
-s 5,tpm,type=swtpm,path=/var/run/smolfire-tpm/swtpm.sock
```

Or for QEMU amd64, confirm the command includes:

```
-chardev socket,id=chrtpm,path=/var/run/smolfire-qemu-tpm/swtpm.sock
-tpmdev emulator,id=tpm0,chardev=chrtpm
-device tpm-tis,tpmdev=tpm0
```

**aarch64 QEMU special case — `tpm.ko` loads but no `/dev/tpm0`:**
If `dmesg` shows `tpm.ko` loaded but no `tpm0` device attachment, and you are
running aarch64 QEMU with `-device tpm-tis-device`, this is a known limitation:
QEMU sets `ControlArea=0` in the ACPI `TPM2` table, which the FreeBSD CRB
driver treats as invalid. The UEFI firmware still uses swtpm correctly (PCRs
are non-zero) but the OS-level driver does not attach. **Solution: switch to
amd64 QEMU** (`qemu-system-x86_64 -device tpm-tis`). See
`plans/tinyos/PHASE-3-TPM.md §4a.3`.

If `/dev/tpm0` appears as FIFO instead of CRB, add to guest `/boot/loader.conf`:

```
hw.tpm.force_crb=1
```

**TPM CRB handshake fails (T3 fails with `tpmctl` error)**

```sh
# In guest — check interface mode
tpmctl -I
# Should report: Interface: CRB
# If FIFO: add hw.tpm.force_crb=1 to loader.conf and reboot
```

Also verify swtpm version supports the bhyve CRB path; record the version in
test evidence:

```sh
swtpm --version
```

## Validated: QEMU + swtpm TPM 2.0 on <kvm-host> (2026-05-16)

**Host:** <kvm-host> — AMD Ryzen 9 7950X, Pop!_OS 24.04, KVM available (`/dev/kvm`)
**Guest:** FreeBSD 15.1-STABLE amd64 (`GENERIC` kernel with `kldload tpm`)
**swtpm:** 0.7.3
**QEMU:** 8.2.2

### Verified working command line

```sh
# Start swtpm
sudo swtpm socket --tpmstate dir=/tmp/smolfire-tpm --tpm2 \
  --ctrl type=unixio,path=/tmp/smolfire-tpm/swtpm.sock --daemon

# Launch FreeBSD VM with TPM
sudo qemu-system-x86_64 \
  -M q35 -accel kvm -cpu host \
  -bios /usr/share/qemu/OVMF.fd \
  -m 512M -smp 2 \
  -drive file=<image>.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2241-:22 \
  -chardev socket,path=/tmp/smolfire-tpm/swtpm.sock,id=chrtpm \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -nographic -monitor none
```

### Guest-side verification

```
# In guest (after kldload tpm):
tpm2_pcrread sha256:0
# sha256:
#   0 : 0xB6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727
```

**Key notes:**
- Standard FreeBSD UFS VM image generates XMSS host keys on first boot, blocking sshd for hours.
  Fix: `rm -f /etc/ssh/ssh_host_xmss_key*` before sshd starts (smolfire conf already does this).
- `tpm-tis` device works on amd64 QEMU; `tpm-tis-device` (aarch64) generates ControlArea=0 in ACPI.
- `kldload tpm` is required in GENERIC kernel; smolfire kernel configs already include `device tpm`.
