# Phase 3: TPM 2.0 Measured Boot — Context

**Gathered:** 2026-06-04
**Status:** Ready for planning
**Mode:** auto (all decisions auto-selected from recommended options)

<domain>
## Phase Boundary

Deliver the full T1–T6 TPM 2.0 acceptance suite against a real smolBSD amd64
image (built with `device tpm` compiled in and `tpm2-tools` in the package set)
running inside QEMU + swtpm on <kvm-host>.

**In scope:**
- Build a smolBSD amd64 qcow2 image with `device tpm` + `tpm2-tools`
- Run T1–T6 gates: swtpm socket, `/dev/tpm0` present, manufacturer info, PCR0 read, seal/unseal, PCR extend
- Update `tpm-vm-test.yml` to use the real smolBSD image

**Out of scope:**
- Physical board (Pi 5 / RK3588) — Phase 4
- aarch64 TPM (QEMU `tpm-tis-device` generates ControlArea=0 — not fixable in software)
- Remote attestation / TPM quotes — Phase 4

</domain>

<decisions>
## Implementation Decisions

### D-01: Image Build Strategy
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

### D-02: tpm2-tools Inclusion in Image
Add `tpm2-tools` to the release configuration via `VM_RC_LIST` extension and
add to the `vm_extra_install_packages` hook in `release/tools/smolfire-qemu.conf`.
This avoids any `pkg install` at test time (which requires network/DHCP —
known to fail under QEMU SLIRP with stock images).

Pre-bake approach: image ships with `tpm2-tools` already installed so CI tests
can run `tpm2_pcrread`, `tpm2_createprimary`, `tpm2_unseal` without internet.

Also add to smolfire-qemu.conf:
- `sshd_keygen_enable="NO"` in rc.conf (already added via fix-freebsd-vm.py pattern)
- Explicit `HostKey` list to prevent XMSS blocking (already in qemu.conf)
- `ifconfig_vtnet0="DHCP"` for pkg bootstrap during build (not needed for test)

### D-03: CI Integration — Image Storage
Store the built smolBSD qcow2 on <kvm-host> at a stable path (e.g.,
`/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2`). Update `tpm-vm-test.yml`
to use this local path instead of downloading a stock FreeBSD image.

Cache invalidation: use a SHA256 manifest file alongside the image. CI step
checks if manifest matches; rebuilds only on kernel/conf change.

The `build-image.yml` workflow trigger → builds → saves to that path → marks
manifest → triggers `tpm-vm-test.yml` downstream.

### D-04: T2–T6 Test Execution
Use the existing test scripts that already implement the acceptance spec:
- `tests/tpm-attest.exp` — console Expect script for T2 (boot with /dev/tpm0) and T3 (tpmctl -G)
- `tests/tpm-seal-test.nu` — T5 (seal/unseal with PCR 0+7 policy)
- `tests/bhyve-tpm-pcr-verify.nu` — T1–T6 combined verification script
- `bin/run-vm-tests.nu` — orchestrates all steps with --tpm flag

Update `tpm-vm-test.yml` to:
1. Restore or build smolBSD image
2. Start swtpm via `nu bin/swtpm-setup.nu --action start`
3. Boot QEMU with `nu bin/qemu-smolbsd.nu --image <path> --tpm --arch amd64`
4. Run `nu bin/run-vm-tests.nu --tpm --arch amd64 --backend qemu`
5. Report T1–T6 pass/fail in job summary

### D-05: fix-freebsd-vm.py Not Needed for Real Image
The console-socket fixer (`bin/fix-freebsd-vm.py`) is only needed for the
stock FreeBSD UFS image (which lacks sshd_keygen_enable, XMSS removal, etc.).
The smolBSD image already has all these baked in via `smolfire-qemu.conf`.
For the smolBSD image CI path: poll SSH directly, no console fix step needed.

### Claude's Discretion
- Exact QEMU command flags for the smolBSD image (CPU, memory, accel)
- swtpm state directory path on <kvm-host>
- How to handle T3 (`tpmctl -G`) if `tpmctl(8)` is not in the image (fallback: `tpm2_getcap`)
- Whether to run bhyve or QEMU for the T2–T6 suite (QEMU preferred: CI already validates QEMU path)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase specification
- `plans/tinyos/PHASE-3-TPM.md` — Full T1–T6 acceptance contract, architecture decisions, swtpm setup
- `.planning/STATE.md` — Current status; what's done vs pending

### Release configuration
- `release/tools/smolfire-qemu.conf` — amd64 release build config (ownership fixes, SSH key pre-gen, size-trim)
- `release/tools/smolfire-qemu-aarch64.conf` — aarch64 reference for pattern consistency

### Kernel configs
- `sys/amd64/conf/SMOLBSD` — amd64 kernel (already has `device tpm`)
- `sys/arm64/conf/SMOLBSD` — arm64 reference

### Existing CI/scripts
- `.github/workflows/tpm-vm-test.yml` — Current TPM CI (uses stock FreeBSD image; to be updated)
- `.github/workflows/build-image.yml` — Image build workflow (trigger for <kvm-host> builds)
- `bin/qemu-smolbsd.nu` — QEMU launcher with --tpm flag
- `bin/swtpm-setup.nu` — swtpm lifecycle manager
- `bin/run-vm-tests.nu` — VM test orchestrator with --tpm --arch --backend
- `bin/copy-configs-to-freebsd.sh` — Copies SMOLBSD configs into a FreeBSD src tree
- `bin/fix-freebsd-vm.py` — Console socket fixer (stock FreeBSD only, NOT needed for smolBSD image)

### Test scripts (implement T1–T6)
- `tests/tpm-attest.exp` — T2+T3 console Expect script
- `tests/tpm-seal-test.nu` — T5 seal/unseal with PCR policy
- `tests/bhyve-tpm-pcr-verify.nu` — T1–T6 combined verifier
- `tests/tpm-smoke-test.nu` — Existing QEMU+swtpm orchestrator

### Infrastructure
- `docs/VM-TESTING.md` — Validated QEMU+swtpm command lines, PCR0 proof (2026-05-16)
- `docs/CICD.md` — CI/CD operator guide, runner registration, <kvm-host> setup

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `bin/qemu-smolbsd.nu` — Already supports `--tpm --arch amd64`, starts swtpm inline
- `bin/swtpm-setup.nu` — Full lifecycle: start/stop/status/reset; T1 gate built in
- `bin/run-vm-tests.nu` — 10-step orchestrator, `--tpm` and `--backend qemu` flags already wired
- `tests/bhyve-tpm-pcr-verify.nu` — T1–T6 all implemented; just needs the real image path
- `bin/fix-freebsd-vm.py` — NOT needed for smolBSD image (baked-in sshd config); useful for debugging only
- `bin/copy-configs-to-freebsd.sh` — Copies SMOLBSD kernel + cloudware configs; use in build step

### Established Patterns
- Log-step TOML format (`{ts, step, payload}`) used throughout all .nu scripts
- Attestation `[[claims]]` blocks expected by the coord-tick.nu proveryay hook
- All timestamps use `date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"`
- Tests emit structured TOML results; smolfire-test-report.nu aggregates them

### Integration Points
- `tpm-vm-test.yml` needs: (1) image path env var, (2) remove fix-freebsd-vm.py step, (3) call run-vm-tests.nu
- `build-image.yml` needs: <kvm-host> runner + FreeBSD build VM + scp artifact back
- smolfire-qemu.conf needs: `vm_extra_install_packages` hook for tpm2-tools package

### Known Constraint
- QEMU aarch64 TPM: `tpm-tis-device` generates ControlArea=0 ACPI → FreeBSD CRB driver refuses
- aarch64 TPM testing is Phase 4 (physical board only)
- VMSIZE already reduced to 2g in current smolfire-qemu.conf (was 4g)

</code_context>

<specifics>
## Specific Ideas

- <kvm-host> already ran `pkg install -y tpm2-tools` in a manual FreeBSD QEMU session and it worked (DHCP via SLIRP worked because the session image had `ifconfig_vtnet0="DHCP"` set). This confirms smolBSD images (which have DHCP in rc.conf) CAN bootstrap pkg during build.
- PCR0 validated manually 2026-05-16: `B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727` (documented in docs/VM-TESTING.md)
- Self-hosted runner `<kvm-host>-amd64` is online and confirmed working (labels: `self-hosted, linux, amd64, kvm`)
- The smolBSD release config already has the critical fixes: XMSS removal, SSH key pre-gen, sshd_keygen_enable=NO pattern, PermitRootLogin yes

</specifics>

<deferred>
## Deferred Ideas

- Physical Pi 5 / RK3588 TPM via fTPM/OP-TEE — Phase 4 (prerequisite: Phase 3 T1–T6 pass)
- Remote attestation / TPM quote + verifier service — Phase 4
- aarch64 QEMU TPM (blocked: ControlArea=0) — needs physical board
- Windows guest TPM testing — out of scope for smolBSD
- Measured boot with Secure Boot chain (sbctl, efistub) — Phase 4 candidate

</deferred>

---

*Phase: 03-tpm-2-0-measured-boot*
*Context gathered: 2026-06-04*
