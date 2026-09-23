---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: smolBSD TPM campaign
status: Phase 3 complete — ready for Phase 4 or CI validation
stopped_at: Phase 3 execution complete, T1-T6 all pass
last_updated: "2026-06-05"
progress:
  total_phases: 4
  completed_phases: 3
  total_plans: 7
  completed_plans: 7
---

# smolBSD — Current State

Updated: 2026-06-05

## Phase completion summary

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Minimal FreeBSD 15 amd64 + aarch64 QEMU VM images | ✅ complete |
| 2 | Physical board configs (Pi5, RK3588), bhyve harness, coord FSM | ✅ complete |
| 3 | TPM 2.0 measured boot — QEMU+swtpm, T1–T6 all pass | ✅ complete |
| 4 | Physical fTPM (Pi5 RP1, RK3588 OP-TEE), remote attestation | not started |

## Phase 3 deliverables (all done)

| Deliverable | Status |
|-------------|--------|
| `device tpm` in all SMOLBSD kernel configs | ✅ done |
| `smolfire-qemu.conf`: `VM_EXTRA_PACKAGES=tpm2-tools` | ✅ done |
| SMOLBSD configs on <kvm-host> freebsd-src | ✅ done |
| Nushell 0.112.2 on <kvm-host> runner | ✅ done |
| smolBSD amd64 qcow2 image with tpm2-tools pre-baked | ✅ done — `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` (712 MiB) |
| T1–T6 TPM acceptance suite | ✅ all pass — `03-T1T6-RESULTS.toml` |
| T5 live seal/unseal | ✅ pass — `smolbsd-seal-test` recovered exactly |
| `tpm-vm-test.yml` wired with T1–T6 via bhyve-tpm-pcr-verify.nu | ✅ done |
| `build-image.yml` for repeatable smolBSD TPM image rebuild | ✅ done |
| PR #28 open for review | ✅ pushed to gsd/phase-3-tpm |

## Human verification pending (<kvm-host>)

- [ ] Trigger `build-image.yml` → confirm image rebuild reproducible end-to-end
- [ ] Trigger `tpm-vm-test.yml` → full T1–T6 CI pass with real smolBSD image (not stock FreeBSD)

## Phase 4 prerequisites

- [x] Phase 3 T1–T6 all pass
- [ ] OP-TEE license audit complete (Apache-2.0 / BSD-2-Clause only — no GPL)
- [ ] Physical hardware: Pi 5 or RK3588 board available

## Coordinator FSM stories (backlog)

| Story | Title | Status |
|-------|-------|--------|
| S-001 | Enforce spool message attestation checks | passing |
| S-002 | Per-task halt and resume handling | failing |
| S-003 | Bounded retry policy with escalation | failing |
| S-004 | Capability gate checks during dispatch | failing |
| S-005 | Deterministic state transition telemetry | failing |

These are independent of the TPM track and can run in parallel.
