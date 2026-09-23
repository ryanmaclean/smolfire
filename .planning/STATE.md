---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: smolBSD TPM campaign
status: Phase 4 A1-A5 complete — pending CI runner verification
stopped_at: Phase 4 execution complete — all A1-A5 gates implemented, tests green, CI workflow updated
last_updated: "2026-09-23"
progress:
  total_phases: 4
  completed_phases: 3
  total_plans: 8
  completed_plans: 7
---

# smolBSD — Current State

Updated: 2026-09-23

## Phase completion summary

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Minimal FreeBSD 15 amd64 + aarch64 QEMU VM images | ✅ complete |
| 2 | Physical board configs (Pi5, RK3588), bhyve harness, coord FSM | ✅ complete |
| 3 | TPM 2.0 measured boot — QEMU+swtpm, T1–T6 all pass | ✅ complete |
| 4 | Remote attestation — TPM quote + verifier (hardware-free) | ✅ A1-A5 implemented, pending CI runner |

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
| `build-image.yml` image rebuild reproducible end-to-end | ✅ verified |
| `tpm-vm-test.yml` full T1–T6 CI pass with real smolBSD image | ✅ verified |

## Phase 4 deliverables (A1-A5 implemented)

| Artifact | Status |
|----------|--------|
| 04-CONTEXT.md | ✅ created |
| 04-PLAN.md | ✅ created |
| 04-ACCEPTANCE.md | ✅ updated — all criteria marked done |
| `bin/guest-attest.nu` | ✅ created — guest-side TPM quote generator |
| `bin/attest-verify.nu` | ✅ created — host-side quote verifier |
| `tests/tpm-attest-verify-test.nu` | ✅ created — 7/7 tests passing |
| `.github/workflows/tpm-vm-test.yml` | ✅ updated — A5 CI integration |
| A1-A5 gates | ✅ implemented |

## Phase 4 prerequisites

- [x] Phase 3 T1–T6 all pass
- [x] OP-TEE license audit complete (Apache-2.0 / BSD-2-Clause / BSD-2-Clause-Patent — no GPL)
- [x] Phase 4 scoped as hardware-free (QEMU+swtpm reuse — no physical board needed)
- [ ] Physical hardware: Pi 5 or RK3588 board available — Phase 5 only

## Phase 5 status

Blocked pending Phase 4 completion and physical hardware availability.

## Coordinator FSM stories

| Story | Title | Status |
|-------|-------|--------|
| S-001 | Enforce spool message attestation checks | passing |
| S-002 | Per-task halt and resume handling | passing (halt/resume bug fixed) |
| S-003 | Bounded retry policy with escalation | passing |
| S-004 | Capability gate checks during dispatch | passing |
| S-005 | Deterministic state transition telemetry | passing |

All coordinator stories are now passing. No blockers.

## Next actions

1. Execute Phase 4 Plan 01: A1-A5 remote attestation implementation
2. Key files to create: `bin/attest-verify.nu`, `tests/tpm-attest-verify-test.nu`
3. Extend `.github/workflows/tpm-vm-test.yml` with A5 gate
