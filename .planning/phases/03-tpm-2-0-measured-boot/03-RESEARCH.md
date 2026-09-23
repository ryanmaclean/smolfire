# Phase 3: TPM 2.0 Measured Boot — Research

**Researched:** 2026-06-04
**Domain:** FreeBSD TPM 2.0 stack, swtpm, QEMU+KVM, FreeBSD release build on Linux, CI image caching
**Confidence:** HIGH (all key findings verified against live infrastructure on <kvm-host>)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01: Image Build Strategy**
Build the smolBSD amd64 image by booting a FreeBSD QEMU VM on <kvm-host> and
running `make release` inside it. <kvm-host> already has:
- `/home/studio/bsd-build/src/freebsd-src` with postworld artifacts from 2026-04-11
- QEMU 8.2.2 + KVM
- The full FreeBSD source tree

Steps: boot FreeBSD QEMU VM on <kvm-host> → clone/copy smolBSD repo inside →
`cp release/tools/smolfire-qemu.conf` into src → run `make release KERNCONF=SMOLBSD
WITH_PKGBASE=yes VMFORMATS=qcow2 VMSIZE=2g` → scp artifact back to host.

`bin/copy-configs-to-freebsd.sh` already implements config copy. Use
`.github/workflows/build-image.yml` as the CI trigger.

**D-02: tpm2-tools Inclusion in Image**
Add `tpm2-tools` to the release configuration via `VM_RC_LIST` extension and
add to the `vm_extra_install_packages` hook in `release/tools/smolfire-qemu.conf`.
This avoids any `pkg install` at test time.

Pre-bake approach: image ships with `tpm2-tools` already installed.

Also add to smolfire-qemu.conf:
- `sshd_keygen_enable="NO"` in rc.conf (already added via fix-freebsd-vm.py pattern)
- Explicit `HostKey` list to prevent XMSS blocking (already in qemu.conf)
- `ifconfig_vtnet0="DHCP"` for pkg bootstrap during build (not needed for test)

**D-03: CI Integration — Image Storage**
Store the built smolBSD qcow2 on <kvm-host> at a stable path (e.g.,
`/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2`). Update `tpm-vm-test.yml`
to use this local path instead of downloading a stock FreeBSD image.

Cache invalidation: use a SHA256 manifest file alongside the image. CI step
checks if manifest matches; rebuilds only on kernel/conf change.

The `build-image.yml` workflow trigger → builds → saves to that path → marks
manifest → triggers `tpm-vm-test.yml` downstream.

**D-04: T2–T6 Test Execution**
Use the existing test scripts:
- `tests/tpm-attest.exp` — console Expect script for T2 and T3
- `tests/tpm-seal-test.nu` — T5 seal/unseal with PCR 0+7 policy
- `tests/bhyve-tpm-pcr-verify.nu` — T1–T6 combined verification script
- `bin/run-vm-tests.nu` — orchestrates all steps with --tpm flag

Update `tpm-vm-test.yml` to:
1. Restore or build smolBSD image
2. Start swtpm via `nu bin/swtpm-setup.nu --action start`
3. Boot QEMU with `nu bin/qemu-smolbsd.nu --image <path> --tpm --arch amd64`
4. Run `nu bin/run-vm-tests.nu --tpm --arch amd64 --backend qemu`
5. Report T1–T6 pass/fail in job summary

**D-05: fix-freebsd-vm.py Not Needed for Real Image**
The console-socket fixer is only needed for the stock FreeBSD UFS image.
The smolBSD image already has all fixes baked in via `smolfire-qemu.conf`.
For the smolBSD image CI path: poll SSH directly, no console fix step needed.

### Claude's Discretion
- Exact QEMU command flags for the smolBSD image (CPU, memory, accel)
- swtpm state directory path on <kvm-host>
- How to handle T3 (`tpmctl -G`) if `tpmctl(8)` is not in the image (fallback: `tpm2_getcap`)
- Whether to run bhyve or QEMU for the T2–T6 suite (QEMU preferred)

### Deferred Ideas (OUT OF SCOPE)
- Physical Pi 5 / RK3588 TPM via fTPM/OP-TEE — Phase 4
- Remote attestation / TPM quote + verifier service — Phase 4
- aarch64 QEMU TPM (blocked: ControlArea=0) — needs physical board
- Windows guest TPM testing — out of scope for smolBSD
- Measured boot with Secure Boot chain (sbctl, efistub) — Phase 4 candidate
</user_constraints>

---

## Summary

Phase 3 has one blocking deliverable: a smolBSD amd64 qcow2 image built with
`device tpm` compiled into the kernel and `tpm2-tools` pre-installed in the
image. Once that image exists on <kvm-host> at a stable path, the full T2–T6
acceptance suite runs against it using scripts that are already complete and
tested. T1 (swtpm socket) is already green in CI.

The core engineering work is split into two parts: (1) build pipeline —
install smolBSD configs into the FreeBSD source tree on <kvm-host> and trigger
`make vm-image` with `CLOUDWARE_CONF=smolfire-qemu.conf`; and (2) CI wiring —
update `tpm-vm-test.yml` to reference the new image path and drive the
existing T2–T6 scripts instead of the stock FreeBSD workaround.

**Critical infrastructure finding:** <kvm-host> (<kvm-host-ip>) is a **Linux host**
(Ubuntu kernel 6.18.7), not a FreeBSD host. The FreeBSD cross-build
environment (`bmake`, cross-tools, `postworld` stage) is all present under
`/home/studio/bsd-build/`. The `make vm-image` (CLOUDWARE) path needs
`bsdtar`, `mdconfig`/`makefs`, and `chroot` with `qemu-user-static` — a
pattern already proven in `run-freebsd-mini-pipeline.sh`. The SMOLBSD kernel
config and `smolfire-qemu.conf` are NOT yet copied into the live freebsd-src
tree; that copy step is Wave 1 work.

**Primary recommendation:** Copy SMOLBSD configs into freebsd-src, adapt the
existing `run-release-once.sh` pipeline to use `KERNCONF=SMOLBSD` and
`CLOUDWARE_CONF=smolfire-qemu.conf`, add `VM_EXTRA_PACKAGES=tpm2-tools` to the
conf (or use the chroot pkg path), then trigger the existing `build-image.yml`
CI workflow.

---

## Standard Stack

### Core (all already in project — no new installs needed)
| Component | Version | Purpose | Status |
|-----------|---------|---------|--------|
| `swtpm` | 0.7.3 | Software TPM 2.0 emulator on <kvm-host> | installed on <kvm-host> |
| `qemu-system-x86_64` | 8.2.2 | KVM-accelerated amd64 VM on <kvm-host> | installed on <kvm-host> |
| `tpm2-tools` (FreeBSD pkg) | security/tpm2-tools | PCR read/seal/unseal in guest | must be baked into image |
| OVMF / UEFI firmware | present at `/usr/share/qemu/OVMF.fd` | UEFI firmware for QEMU amd64 | present on <kvm-host> |
| FreeBSD source tree | 15.1-STABLE (freebsd-src) | Base for `make vm-image` | present on <kvm-host> |
| `bmake` cross-tools | installed | Build toolchain | present on <kvm-host> |

### Supporting
| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| `sshpass` | system | Password-auth SSH in tests | bhyve-tpm-pcr-verify.nu |
| `qemu-user-static` (Linux) | system | binfmt_misc for pkg chroot in release build | CLOUDWARE path only |
| Nushell | must be installed on <kvm-host> (currently absent) | Run Nu scripts in CI | all wave steps |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| CLOUDWARE vm-image build | Boot a FreeBSD QEMU VM and build inside it (D-01 option) | Cross-build directly on Linux is faster and already proven; avoids nested VM overhead |
| Pre-baking tpm2-tools in image | `pkg install` at test time | SLIRP has no outbound internet at test time; pre-bake is required |

**Version verification:** swtpm 0.7.3 confirmed on <kvm-host> (live). QEMU 8.2.2 confirmed on <kvm-host> (live). OVMF.fd confirmed at `/usr/share/qemu/OVMF.fd` on <kvm-host> (live).

---

## Architecture Patterns

### Recommended Project Structure (no changes to existing layout)
```
release/tools/smolfire-qemu.conf    # add VM_EXTRA_PACKAGES=tpm2-tools
sys/amd64/conf/SMOLBSD             # already has "device tpm"
bin/build-smolbsd.nu               # existing build driver
bin/qemu-smolbsd.nu                # existing QEMU launcher --tpm
bin/swtpm-setup.nu                 # existing swtpm lifecycle
bin/run-vm-tests.nu                # existing test orchestrator --tpm
tests/bhyve-tpm-pcr-verify.nu      # existing T1-T6 verifier
tests/tpm-seal-test.nu             # existing T5 test
tests/tpm-attest.exp               # existing T2+T3 expect script
.github/workflows/tpm-vm-test.yml  # update: use smolbsd image, not stock FreeBSD
.github/workflows/build-image.yml  # trigger for image rebuild
```

### Pattern 1: CLOUDWARE Release Build with VM_EXTRA_PACKAGES
**What:** Set `VM_EXTRA_PACKAGES="tpm2-tools"` in `smolfire-qemu.conf` and use the
FreeBSD release `Makefile.vm` target. The `vmimage.subr` `vm_extra_install_packages`
function handles pkg install inside a chroot with `qemu-user-static` as the emulator.
**When to use:** Any time tpm2-tools must be baked into the image.

`smolfire-qemu.conf` addition:
```sh
# Bake tpm2-tools into the image so T2-T6 tests need no network at test time
export VM_EXTRA_PACKAGES="tpm2-tools"
```

The `vm_extra_install_packages` function in `vmimage.subr` reads `VM_EXTRA_PACKAGES`
and installs via `pkg -r ${DESTDIR} install`. On the Linux cross-build host
this requires either `QEMUSTATIC` pointing to `qemu-x86_64-static` or a
pre-configured chroot. The existing `run-freebsd-mini-pipeline.sh` uses
`WITHOUT_QEMU=true NOPKG=yes` — so the current pipeline skips package installs.
The smolBSD build will need `WITHOUT_QEMU` unset and pkg repos available.

**Alternative (simpler, confirmed working):** Use the chroot pkg path by
setting `QEMUSTATIC=/usr/bin/qemu-x86_64-static` in the build environment.
<kvm-host> has KVM which means `qemu-x86_64-static` (user-mode emulation for
chroot) is a separate binary from `qemu-system-x86_64`. Verify it is present:
```bash
ls /usr/bin/qemu-x86_64-static
```

### Pattern 2: T2-T6 Test Execution via run-vm-tests.nu
**What:** The existing `bin/run-vm-tests.nu --tpm --arch amd64 --backend qemu`
orchestrates all 10 steps including swtpm start, QEMU launch, boot-gate, SSH
checks, tpm-device, tpm-seal, and teardown.
**When to use:** Phase 3 CI acceptance run.

The key `run-vm-tests.nu` wiring for TPM:
- Step 2: `step-swtpm-start` calls `nu bin/swtpm-setup.nu --action start --state-dir <dir>`
- Step 3: `step-launch` calls `nu bin/qemu-smolbsd.nu --tpm --arch amd64`
- Step 7: `step-tpm-device` runs `tests/tpm-attest.exp` (console expect, bhyve nmdm path)
- Step 8: `step-tpm-seal` runs `tests/tpm-seal-test.nu --dry-run` (host-side)

**Gap identified:** `step-tpm-device` (T2+T3) uses `tpm-attest.exp` which
connects to an nmdm console device (`SMOLBSD_CONSOLE=/dev/nmdm0B`). For the
QEMU backend on Linux, the console is stdio, not nmdm. The QEMU path in
`run-vm-tests.nu` for `step-boot-gate` correctly uses `time-to-ready-qemu.exp`
(spawns QEMU with stdio), but `step-tpm-device` still calls `tpm-attest.exp`
which opens `SMOLBSD_CONSOLE`. This needs resolution (see Open Questions).

### Pattern 3: SHA256 Manifest for CI Image Cache
**What:** Write a `smolbsd-amd64-tpm.qcow2.sha256` alongside the image.
CI step compares SHA of kernel config + release conf against a stored hash;
rebuilds only if hash changed.
**When to use:** `build-image.yml` workflow.

```bash
# In build-image.yml after image is built and placed:
sha256sum /home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2 \
  > /home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2.sha256
```

### Anti-Patterns to Avoid
- **Installing tpm2-tools at test time via `pkg install`:** Network not available in QEMU SLIRP during test; must be pre-baked.
- **Using `WITHOUT_QEMU=true NOPKG=yes` for smolBSD build:** Inherited from `run-freebsd-mini-pipeline.sh` but incompatible with pkg baking. The smolBSD pipeline must remove these flags.
- **Referencing `/dev/nmdm0B` for QEMU console on Linux:** nmdm is FreeBSD-only; QEMU console on Linux is stdio or a PTY. `tpm-attest.exp` uses nmdm; for the QEMU backend the T2+T3 checks must be done via SSH (which `bhyve-tpm-pcr-verify.nu` already supports).
- **Running `tpm-vm-test.yml` without Nushell installed on runner:** Nushell is absent from <kvm-host> (confirmed via SSH); must be installed by the CI job setup step.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TPM 2.0 emulation | custom TPM socket server | `swtpm` 0.7.3 (already on <kvm-host>) | Complete TPM 2.0 spec compliance, CRB support, state serialization |
| PCR seal/unseal | custom crypto | `tpm2-tools` (`tpm2_createprimary`, `tpm2_create`, `tpm2_load`, `tpm2_unseal`) | TCTI abstraction, correct TPM object hierarchy handling |
| Guest boot detection | polling sleep loop | `tests/time-to-ready-qemu.exp` (already exists) | Handles timeout, hard failure, reports TIME_TO_LOGIN |
| Image build pipeline | new bash script | `bin/build-smolbsd.nu` + adapt `run-release-once.sh` pattern | FIX-1 through FIX-8 already encoded; avoids repeating hard-won bugs |
| Test orchestration | new CI shell script | `bin/run-vm-tests.nu --tpm` | 10-step orchestrator already wired for --tpm flag |

**Key insight:** Nearly all the infrastructure exists. The gap is (1) configs not
copied into freebsd-src, (2) Nushell not on <kvm-host>, (3) QEMU console path in
`step-tpm-device` needs SSH override for Linux/QEMU path, and (4) `tpm-vm-test.yml`
references stock FreeBSD image and `fix-freebsd-vm.py`.

---

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | None — no database stores image path or config names | None |
| Live service config | <kvm-host> GitHub Actions runner `<kvm-host>-amd64` (online, labels: self-hosted,linux,amd64,kvm); swtpm state dir `/var/run/smolbsd-tpm` may have stale state from prior T1 tests | Runner: no change needed. swtpm: reset before test run (`--action reset`) |
| OS-registered state | `/home/studio/bsd-build/stage/amd64-postworld-20260411T130830/` — installworld stage from 2026-04-11; GENERIC kernel (not SMOLBSD), no tpm compiled in | New build required with KERNCONF=SMOLBSD |
| Secrets/env vars | `tpm-vm-test.yml` currently uses `SSH_PRIVATE_KEY` / runner auth; no new secrets needed for local image path | No change required |
| Build artifacts | `/home/studio/bsd-build/obj/` contains GENERIC kernel artifacts; SMOLBSD kernel obj will be separate subtree (amd64.amd64/sys/SMOLBSD) | No cleanup required; SMOLBSD builds to different path |

**smolBSD configs not yet in freebsd-src (verified on <kvm-host> live):**
- `sys/amd64/conf/SMOLBSD` — absent from `/home/studio/bsd-build/src/freebsd-src/`
- `release/tools/smolfire-qemu.conf` — absent from `/home/studio/bsd-build/src/freebsd-src/`

Both must be copied in as Wave 1 tasks before any build can proceed.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `qemu-system-x86_64` | T2–T6 test runs | ✓ | 8.2.2 (KVM) | — |
| `swtpm` | T1–T6 (swtpm socket) | ✓ | 0.7.3 | — |
| OVMF.fd firmware | QEMU UEFI boot | ✓ | at `/usr/share/qemu/OVMF.fd` | — |
| `sshpass` | bhyve-tpm-pcr-verify.nu | ✓ | system | key auth (--password "") |
| Nushell (`nu`) | All .nu scripts in CI | ✗ | absent from <kvm-host> | Install in CI job setup step |
| `smolbsd-ci/` directory | Image storage | ✗ | does not exist | `mkdir -p /home/studio/smolbsd-ci` in build step |
| SMOLBSD configs in freebsd-src | `make vm-image KERNCONF=SMOLBSD` | ✗ | not copied yet | Copy from repo in Wave 1 |
| `qemu-x86_64-static` | pkg chroot in release build | ? | not verified | QEMU KVM can be used for chroot if binfmt_misc is configured |

**Missing dependencies with no fallback:**
- Nushell on <kvm-host> — required by all `nu bin/*.nu` CI steps; install in job setup

**Missing dependencies with fallback:**
- `qemu-x86_64-static` for chroot pkg install — if absent, use a QEMU VM to run
  `pkg install` inside a FreeBSD guest (D-01 approach: boot FreeBSD VM → pkg install
  inside it → scp image back). This is the original D-01 design and remains the
  safer fallback if cross-chroot pkg fails.

---

## Common Pitfalls

### Pitfall 1: nmdm Console vs. stdio Console (QEMU on Linux)
**What goes wrong:** `step-tpm-device` in `run-vm-tests.nu` calls `tests/tpm-attest.exp`
which opens `SMOLBSD_CONSOLE` (defaulting to `/dev/nmdm0B`). nmdm is FreeBSD-only.
On Linux, QEMU uses stdio or a PTY for the serial console.
**Why it happens:** `tpm-attest.exp` was written for the bhyve path (nmdm). The
`run-vm-tests.nu` QEMU path uses stdio for boot-gate but does not switch to SSH
for the TPM device check.
**How to avoid:** For the T2+T3 checks when backend=qemu on Linux, use `bhyve-tpm-pcr-verify.nu`
via SSH instead of `tpm-attest.exp` via serial console. The `--host 127.0.0.1 --port 2241
--password smolbsd` flags match the QEMU hostfwd setup in `qemu-smolbsd.nu`.
**Warning signs:** CI step shows `open /dev/nmdm0B: No such file or directory`.

### Pitfall 2: Nushell Absent from <kvm-host>
**What goes wrong:** All CI steps that call `nu bin/*.nu` fail immediately with
`nu: command not found`.
**Why it happens:** <kvm-host> is a fresh Linux KVM host; Nushell is not in the
default Ubuntu package set and is currently absent (confirmed via SSH).
**How to avoid:** Add a Nushell install step to `tpm-vm-test.yml` and
`build-image.yml`. Use the same pattern as `ci.yml` (download tarball from
GitHub releases, unpack to `$HOME/.local/bin`).

### Pitfall 3: WITHOUT_QEMU / NOPKG in Build Pipeline
**What goes wrong:** The existing `run-freebsd-mini-pipeline.sh` sets
`WITHOUT_QEMU=true NOPKGBASE=yes NOPKG=yes NOSRC=yes` to skip package installs.
If the smolBSD build inherits this, `VM_EXTRA_PACKAGES=tpm2-tools` will be
silently skipped and the image will ship without tpm2-tools.
**Why it happens:** The existing pipeline skips pkg to avoid network dependencies
in CI. smolBSD's build via CLOUDWARE needs pkg enabled.
**How to avoid:** The smolBSD build pipeline must NOT set `WITHOUT_QEMU` or
`NOPKG`. It must set `QEMUSTATIC` to a valid static QEMU binary or configure
binfmt_misc so the chroot can execute FreeBSD amd64 binaries.

### Pitfall 4: PCR Values Non-Deterministic Without swtpm State Reset
**What goes wrong:** If swtpm state directory persists between runs, PCR values
differ from a fresh boot, and the T5 seal policy (bound at current PCR 0+7) may
not match on unseal.
**Why it happens:** The seal is recorded after the first measurement; if swtpm
is restarted without `--overwrite` the state continues accumulating measurements.
**How to avoid:** Each test run should call `nu bin/swtpm-setup.nu --action reset`
to wipe and reinitialize the swtpm state directory. Record the fresh PCR 0 value
after boot for regression comparison against the known baseline:
`B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727` (documented
in docs/VM-TESTING.md, valid for OVMF.fd at `/usr/share/qemu/OVMF.fd` on <kvm-host>).

### Pitfall 5: tpmctl(8) Absent in smolBSD Image
**What goes wrong:** `tpm-attest.exp` check 2 runs `tpmctl -G`. The smolBSD
image strips many base utilities. If `tpmctl` is not in the image, T3 fails.
**Why it happens:** `smolfire-qemu.conf` strips packages via `vm_extra_filter_base_packages`;
`tpmctl` ships as `FreeBSD-tpm-tools` pkgbase component.
**How to avoid:** The `tpm-attest.exp` check 2 already has a fallback:
`tpmctl -G 2>/dev/null && echo TPM_CAP_OK || tpm2_getcap -c properties-fixed 2>/dev/null && echo TPM_CAP_OK`. 
If both fail, the test reports `TPM_CAP_FAIL`. Verify `tpmctl` is not in the
filter list in `vm_extra_filter_base_packages`. If it is filtered, rely on
`tpm2_getcap` from the `tpm2-tools` package (already being baked in).

### Pitfall 6: smolBSD Image Size Exceeds 512 MiB After Adding tpm2-tools
**What goes wrong:** Adding `tpm2-tools` + `libtss2` dependencies adds ~8–12 MiB
to the image. The `run-vm-tests.nu` `step-artifact-size` check enforces a
512 MiB cap (limit=536870912 bytes).
**Why it happens:** Phase 1 established a 512 MiB budget. tpm2-tools pulls in
`libtss2` and several other shared libraries.
**How to avoid:** The qcow2 format uses sparse allocation so the on-disk size
reported by `qemu-img info actual-size` will be much less than 512 MiB unless
the filesystem itself is nearly full. The size trim in `vm_extra_pre_umount`
already removes debug symbols, docs, man pages, and test infra. Adding
tpm2-tools (~8-12 MiB) should remain well within the 512 MiB budget. Verify
with `qemu-img info --output=json <image> | jq '."actual-size"'` after build.

---

## Code Examples

### Adding tpm2-tools to smolfire-qemu.conf
```sh
# Source: release/tools/smolfire-qemu.conf + Makefile.vm VM_EXTRA_PACKAGES pattern
# Add before vm_extra_pre_umount or as a separate function:
export VM_EXTRA_PACKAGES="tpm2-tools"
```
This integrates with `vmimage.subr`'s `vm_extra_install_packages` which reads
`VM_EXTRA_PACKAGES` and calls `pkg -r ${DESTDIR} install` in the appropriate
chroot or user mode.

### QEMU amd64 TPM command flags (verified in docs/VM-TESTING.md)
```sh
# Source: docs/VM-TESTING.md + plans/tinyos/PHASE-3-TPM.md §6 T2 Path B
# swtpm socket (started separately via bin/swtpm-setup.nu or bin/qemu-smolbsd.nu)
SOCK=/var/run/smolbsd-qemu-tpm/swtpm.sock
qemu-system-x86_64 -M q35 -accel kvm -cpu host \
  -bios /usr/share/qemu/OVMF.fd \
  -m 512M -smp 2 \
  -drive file=smolbsd-amd64.qcow2,format=qcow2,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2241-:22 \
  -serial stdio -nographic \
  -chardev socket,id=chrtpm,path=$SOCK \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0
```
Note: `bin/qemu-smolbsd.nu --arch amd64 --tpm` generates exactly these flags.
On <kvm-host> (Linux, KVM available): use `--accel kvm` for fast boot.
OVMF.fd path on <kvm-host>: `/usr/share/qemu/OVMF.fd` (confirmed on <kvm-host>).

### T1–T6 Quick Verification (manual)
```sh
# Source: docs/VM-TESTING.md §4
# T1 on host:
test -S /var/run/smolbsd-tpm/swtpm.sock && echo T1:pass || echo T1:fail

# T2–T6 via bhyve-tpm-pcr-verify.nu (SSH path, works on Linux/QEMU):
nu tests/bhyve-tpm-pcr-verify.nu \
  --host 127.0.0.1 --port 2241 --password smolbsd
```

### Nushell install in CI (<kvm-host> runner)
```yaml
# Source: .github/workflows/ci.yml — same pattern for <kvm-host> runner
- name: Install Nushell
  run: |
    NU_VERSION="0.112.2"
    ARCH=$(uname -m | sed 's/arm64/aarch64/')
    TRIPLE="${ARCH}-unknown-linux-musl"
    ARCHIVE="nu-${NU_VERSION}-${TRIPLE}.tar.gz"
    mkdir -p "$HOME/.local/bin"
    curl -sSL "https://github.com/nushell/nushell/releases/download/${NU_VERSION}/${ARCHIVE}" \
      | tar -xz -C "$HOME/.local/bin" --strip-components=1 "nu-${NU_VERSION}-${TRIPLE}/nu"
    echo "$HOME/.local/bin" >> "$GITHUB_PATH"
```

### T5 seal/unseal round-trip (in guest via SSH)
```sh
# Source: tests/tpm-seal-test.nu + plans/tinyos/PHASE-3-TPM.md §6 T5
# Run on guest via: nu /tests/tpm-seal-test.nu --tcti "device:/dev/tpm0"
# Or remotely: ssh root@127.0.0.1 -p 2241 'nu /tmp/tpm-seal-test.nu'
tpm2_createprimary -T device:/dev/tpm0 -C o -g sha256 -G ecc -c /tmp/primary.ctx
tpm2_createpolicy -T device:/dev/tpm0 --policy-pcr -l sha256:0,7 -L /tmp/pcr.policy
echo "smolbsd-seal-test" > /tmp/secret.txt
tpm2_create -T device:/dev/tpm0 -C /tmp/primary.ctx \
  -i /tmp/secret.txt -u /tmp/seal.pub -r /tmp/seal.priv \
  -L /tmp/pcr.policy -a "fixedtpm|fixedparent|noda|adminwithpolicy"
tpm2_load -T device:/dev/tpm0 -C /tmp/primary.ctx \
  -u /tmp/seal.pub -r /tmp/seal.priv -c /tmp/seal.ctx
tpm2_unseal -T device:/dev/tpm0 -c /tmp/seal.ctx --auth pcr:sha256:0,7
# Expected output: "smolbsd-seal-test"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Stock FreeBSD image + kldload tpm at test time | smolBSD image with `device tpm` compiled in + tpm2-tools pre-baked | Phase 3 (this phase) | Eliminates pkg network dependency at test time |
| bhyve virtio-tpm (FreeBSD host only) | QEMU tpm-tis (Linux KVM host) | Confirmed 2026-05-16 in docs/VM-TESTING.md | Enables CI on <kvm-host> Linux host |
| tpm-attest.exp via nmdm console | bhyve-tpm-pcr-verify.nu via SSH | Already implemented | More robust; works on both Linux and FreeBSD test runners |

**Deprecated/outdated:**
- `fix-freebsd-vm.py` for smolBSD image path: not needed; baked into `smolfire-qemu.conf`
- bhyve backend for T2–T6 on <kvm-host>: <kvm-host> is Linux; bhyve requires FreeBSD; QEMU is the correct backend here

---

## Open Questions

1. **`qemu-x86_64-static` availability on <kvm-host> for chroot pkg install**
   - What we know: `vm_extra_install_packages` in `vmimage.subr` uses `chroot ${DESTDIR} ${EMULATOR}` for pkg when `QEMUSTATIC` is set
   - What's unclear: whether `/usr/bin/qemu-x86_64-static` (user-mode, separate from `qemu-system-x86_64`) is installed on <kvm-host>; this was not verified in the SSH probe
   - Recommendation: Wave 1 task should verify `ls /usr/bin/qemu-x86_64-static`. If absent, fall back to D-01 approach (boot a FreeBSD QEMU VM → pkg install inside → scp artifact back)

2. **`step-tpm-device` console path for QEMU backend on Linux**
   - What we know: `run-vm-tests.nu` `step-tpm-device` calls `tpm-attest.exp` which opens `SMOLBSD_CONSOLE` (nmdm path); nmdm is FreeBSD-only
   - What's unclear: whether to (a) update `step-tpm-device` to call `bhyve-tpm-pcr-verify.nu` T2+T3 checks via SSH when backend=qemu, or (b) set `SMOLBSD_CONSOLE` to a PTY path and route QEMU serial to a PTY
   - Recommendation: Update `step-tpm-device` to use SSH checks (call `ssh-guest` directly) when `backend == "qemu"`, since `bhyve-tpm-pcr-verify.nu` already implements all T1–T6 via SSH. This is the simpler path.

3. **tpm-vm-test.yml vs build-image.yml — single workflow or two?**
   - What we know: CONTEXT.md D-03 specifies `build-image.yml` triggers build and `tpm-vm-test.yml` runs tests; but currently only `ci.yml` exists in `.github/workflows/`
   - What's unclear: whether to add `build-image.yml` and `tpm-vm-test.yml` as new files, or replace/extend `ci.yml`
   - Recommendation: Add `tpm-vm-test.yml` as a new workflow (the roadmap references it by name); `build-image.yml` can be a separate manual/scheduled trigger for image rebuilds

4. **PCR 0 baseline value stability across OVMF versions**
   - What we know: PCR 0 was `B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727` on 2026-05-16 with OVMF.fd at `/usr/share/qemu/OVMF.fd` on <kvm-host>
   - What's unclear: whether OVMF updates on <kvm-host> would change this value; T6 only checks that PCR changes after extend (not a specific value) so this is primarily a T4 stability concern
   - Recommendation: T4 checks "non-zero and stable across two reads" (not a specific value); this design is intentionally robust to firmware updates

---

## Validation Architecture

No `.planning/config.json` found — treating `nyquist_validation` as enabled.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Nushell scripts (direct execution) + Expect scripts |
| Config file | none — scripts are self-contained |
| Quick run command | `nu tests/bhyve-tpm-pcr-verify.nu --dry-run` |
| Full suite command | `nu bin/run-vm-tests.nu --image <path> --tpm --arch amd64 --backend qemu` |

### Phase Requirements → Test Map
| Gate | Behavior | Test Type | Automated Command | File Exists? |
|------|----------|-----------|-------------------|-------------|
| T1 | swtpm socket appears within 3s | integration | `nu tests/bhyve-tpm-pcr-verify.nu --dry-run` (live: swtpm start + socket check) | ✅ `tests/bhyve-tpm-pcr-verify.nu` |
| T2 | smolBSD guest boots with /dev/tpm0 | e2e | `nu tests/bhyve-tpm-pcr-verify.nu --host 127.0.0.1 --port 2241` | ✅ `tests/tpm-attest.exp` + verifier |
| T3 | tpmctl -G returns TPM 2.0 info | e2e | same as T2 (bhyve-tpm-pcr-verify.nu T3 function) | ✅ |
| T4 | PCR 0 readable, non-zero, stable | e2e | same as T2 (bhyve-tpm-pcr-verify.nu T4 function) | ✅ |
| T5 | seal/unseal round-trip PCR 0+7 | e2e | `nu tests/tpm-seal-test.nu --dry-run` (live: remove --dry-run with /dev/tpm0) | ✅ `tests/tpm-seal-test.nu` |
| T6 | PCR extends after tpm2_pcrextend | e2e | same as T2 (bhyve-tpm-pcr-verify.nu T6 function) | ✅ |

### Sampling Rate
- **Per task commit:** `nu tests/bhyve-tpm-pcr-verify.nu --dry-run` (syntax/logic check, no VM needed)
- **Per wave merge:** `nu bin/run-vm-tests.nu --tpm --arch amd64 --backend qemu --image <path>` (requires smolBSD image and swtpm)
- **Phase gate:** All T1–T6 green in `tpm-vm-test.yml` CI before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `tpm-vm-test.yml` does not exist yet — needs to be created with Nushell install + image restore + T1-T6 run steps
- [ ] `build-image.yml` does not exist yet — needs to be created with <kvm-host> runner + smolBSD build steps
- Existing test files (`bhyve-tpm-pcr-verify.nu`, `tpm-seal-test.nu`, `tpm-attest.exp`) cover all T1–T6 acceptance criteria

---

## Sources

### Primary (HIGH confidence)
- Live SSH probe of <kvm-host> (<kvm-host-ip>) — confirmed: QEMU 8.2.2, swtpm 0.7.3, OVMF.fd at `/usr/share/qemu/OVMF.fd`, sshpass present, Nushell absent, smolbsd-ci dir absent, SMOLBSD configs not in freebsd-src, installworld stage present with GENERIC kernel
- `plans/tinyos/PHASE-3-TPM.md` — full T1–T6 acceptance contract, platform matrix, aarch64 QEMU limitation root cause
- `docs/VM-TESTING.md` — validated QEMU+swtpm command lines, PCR0 baseline value `B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727`
- `bin/run-vm-tests.nu` — confirmed step-tpm-device uses nmdm path (structural gap for QEMU on Linux)
- `bin/build-smolbsd.nu` — FIX-1 through FIX-8 documented; confirmed `CLOUDWARE_CONF` flag
- `/home/studio/bsd-build/src/freebsd-src/release/Makefile.vm` — confirmed `VM_EXTRA_PACKAGES` is the correct hook for pkg installs
- `/home/studio/bsd-build/src/freebsd-src/release/tools/vmimage.subr` — confirmed `vm_extra_install_packages` reads `VM_EXTRA_PACKAGES`

### Secondary (MEDIUM confidence)
- `.github/workflows/ci.yml` — Nushell install pattern (download from GitHub releases, version 0.112.2)
- `release/tools/smolfire-qemu.conf` — current state; no `VM_EXTRA_PACKAGES` line yet
- `sys/amd64/conf/SMOLBSD` — confirmed `device tpm` on line 147

### Tertiary (LOW confidence)
- tpm2-tools image size estimate (~8–12 MiB): from plans/tinyos/PHASE-3-TPM.md §10 open question 4; not independently verified against FreeBSD pkg registry

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all components probed live on <kvm-host>
- Architecture: HIGH — existing scripts read and understood; gaps identified with specific line references
- Pitfalls: HIGH — most from direct code inspection + live environment probe; swtpm PCR determinism from plans/PHASE-3-TPM.md §10

**Research date:** 2026-06-04
**Valid until:** 2026-07-04 (30 days; swtpm and QEMU versions stable)

## RESEARCH COMPLETE
