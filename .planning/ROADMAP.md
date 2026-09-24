# smolBSD — Roadmap

Campaign: **smolBSD — The Tiny Realm vs The Rump Citadel**

Build the smallest stable FreeBSD VM that boots unattended in ≤ 30 seconds,
fits under 512 MiB (target: < 128 MiB qcow2), and proves Claude agents can
hand off a long-running build project via BSD mbox + TOML with no shared
conversation history.

---

## Phase 1: Forge Tiny Baseline — COMPLETE

Minimal FreeBSD 15.0-RELEASE amd64 + aarch64 QEMU VM images.

**Exit gates (both arches):**
- `buildkernel` exit 0
- qcow2 artifact produced, size < 512 MiB
- Time to login prompt ≤ 30 s
- Host RSS idle < 300 MiB; in-VM free ≥ 150 MiB
- Crash recovery ≤ 60 s

**Key files:** `sys/amd64/conf/SMOLBSD`, `sys/arm64/conf/SMOLBSD`,
`release/tools/smolfire-qemu.conf`, `release/tools/smolfire-qemu-aarch64.conf`

---

## Phase 2: Fleet Deploy + Coord Wiring — COMPLETE

Physical board configs, bhyve harness, coordinator FSM dispatch wired.

**Delivered:**
- aarch64 image boots on Pi 5 (SMOLBSD-PI5) and RK3588 (SMOLBSD-RK3588)
- `bin/coord-tick.nu` FSM: idle → dispatching → waiting → harvesting → halted
- mbox+TOML spool protocol with attestation enforcement
- CI gate on GitHub Actions (ubuntu-latest + macos-latest)
- End-to-end coord → subagent → reply round-trip demonstrated

---

## Phase 3: TPM 2.0 Measured Boot — IN PROGRESS

TPM 2.0 measured boot and local attestation via QEMU + swtpm on amd64.

**Scope:** build smolBSD image with `device tpm` compiled in, install
`tpm2-tools`, and validate the full T1–T6 acceptance suite inside a QEMU VM
backed by swtpm on <kvm-host> (Ryzen 9 7950X, KVM) before any hardware dependency.

**Acceptance gates (T1–T6):**
- T1: swtpm socket appears within 3 s (CI green)
- T2: smolBSD guest boots with `/dev/tpm0` present (needs real smolBSD image)
- T3: `tpmctl -G` returns TPM 2.0 manufacturer info
- T4: PCR 0 readable, non-zero, stable
- T5: seal/unseal round-trip with PCR 0+7 policy
- T6: PCR value changes after `tpm2_pcrextend`

**Already done:**
- kernel configs (`device tpm` in all SMOLBSD configs)
- swtpm setup scripts, bhyve harness, test scripts
- CI smoke test on <kvm-host> (self-hosted runner, `/dev/tpm0 present` = green)

**Plans:** 7/7 plans complete

Plans:
- [x] 03-01-PLAN.md — Add VM_EXTRA_PACKAGES=tpm2-tools to smolfire-qemu.conf; copy SMOLBSD configs to <kvm-host> freebsd-src
- [x] 03-02-PLAN.md — Create tpm-vm-test.yml skeleton; install Nushell v0.112.2 on <kvm-host>
- [x] 03-03-PLAN.md — Build smolBSD amd64 image on <kvm-host> (make vm-image KERNCONF=SMOLBSD); write SHA256 manifest
- [x] 03-04-PLAN.md — Run bhyve-tpm-pcr-verify.nu T1/T2/T3/T4/T6 against live smolBSD guest
- [x] 03-05-PLAN.md — Run tpm-seal-test.nu live T5 seal/unseal via /dev/tpm0 in guest
- [x] 03-06-PLAN.md — Wire full T1-T6 test sequence into tpm-vm-test.yml; remove fix-freebsd-vm.py
- [x] 03-07-PLAN.md — Create build-image.yml CI workflow for smolBSD TPM image rebuild on <kvm-host>

**Key files:** `bin/swtpm-setup.nu`, `bin/bhyve-smolbsd.nu`, `bin/qemu-smolbsd.nu`,
`tests/tpm-attest.exp`, `tests/tpm-seal-test.nu`, `tests/bhyve-tpm-pcr-verify.nu`,
`.github/workflows/tpm-vm-test.yml`, `.github/workflows/build-image.yml`,
`plans/tinyos/PHASE-3-TPM.md`, `release/tools/smolfire-qemu.conf`

---

## Phase 4: Remote Attestation — READY (hardware-free)

TPM quote + verifier service. Builds and tests against the SAME swtpm+QEMU
stack proven in Phase 3 — no physical hardware required.

**Scope:**
- A1: smolBSD guest generates a TPM 2.0 quote (`tpm2_quote`) over PCR 0+7 with an AK
- A2: Quote includes a fresh nonce (anti-replay) and is signed by an Attestation Key
- A3: Host-side verifier (`bin/attest-verify.nu`) validates the quote signature + PCR digest + nonce
- A4: Verifier emits a structured TOML attestation envelope (verdict + evidence) per the AX-first convention
- A5: CI gate: attestation round-trip passes on <kvm-host> QEMU+swtpm

**Prerequisites:** Phase 3 T1–T6 all pass ✅. License audit complete ✅ (all
components BSD-2/BSD-2-Patent/BSD-3 — see License Compliance below).

**Acceptance gates (A1–A5):**
- A1: `tpm2_createak` produces an AK; `tpm2_quote` succeeds over sha256:0,7
- A2: Quote message contains the supplied nonce; signature verifies with the AK pub
- A3: `tpm2_checkquote` (or equivalent) validates quote against expected PCR digest
- A4: Verifier writes `[attestation]` TOML block with `verdict`, `pcr_digest`, `nonce`, `ak_fingerprint`
- A5: Full quote→verify round-trip green in CI against the smolBSD image

---

## Phase 5: Physical fTPM — BLOCKED (needs hardware)

Physical board TPM via Pi 5 RP1 fTPM (RPi UEFI, edk2-platforms BSD-2-Clause-Patent)
and RK3588 ARM TrustZone + OP-TEE fTPM TA (BSD-2-Clause). Ports the Phase 4
attestation protocol to real hardware.

**Prerequisites:** Phase 4 attestation passes ✅ (when done). Physical Pi 5 or
RK3588 board connected. Pi 5 `pi501` (10.0.3.11) confirmed online 2026-09-24 — Phase 5 may proceed. License audit complete ✅.

---

## License Compliance — Phase 4/5 components (audited 2026-06-05)

| Component | SPDX | Status |
|-----------|------|--------|
| OP-TEE OS | BSD-2-Clause | ✅ allowed |
| ms-tpm-20-ref (fTPM TA) | BSD-2-Clause | ✅ allowed |
| edk2-platforms (RPi UEFI) | BSD-2-Clause-Patent | ✅ allowed (strict superset of BSD-2-Clause — additive patent grant, no new restriction) |
| tpm2-tools | BSD-2/BSD-3-Clause | ✅ allowed |

**One-time approval:** BSD-2-Clause-Patent is accepted for this project. It is
BSD-2-Clause plus an additive royalty-free patent grant (OSI + FSF approved),
strictly more permissive than plain BSD-2-Clause. No GPL/copyleft anywhere.

---

## Coordinator stories backlog

Open FSM user stories (see `prd.json`):

| Priority | Story | Title |
|----------|-------|-------|
| P2 | S-002 | Per-task halt and resume handling |
| P3 | S-003 | Bounded retry policy with escalation |
| P4 | S-004 | Capability gate checks during dispatch |
| P5 | S-005 | Deterministic state transition telemetry |
