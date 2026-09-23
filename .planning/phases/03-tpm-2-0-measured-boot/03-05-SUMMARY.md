---
phase: 03-tpm-2-0-measured-boot
plan: "05"
subsystem: infra
tags: [freebsd, tpm2, swtpm, qemu, pcr, measured-boot, seal-unseal, testing]

requires:
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-03: smolbsd-amd64-tpm.qcow2 at /home/studio/smolbsd-ci/ on <kvm-host>"
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-04: T1-T6 acceptance tests all pass"

provides:
  - "T5 live seal/unseal verdict=pass at .planning/phases/03-tpm-2-0-measured-boot/03-T5-RESULTS.toml"
  - "tpm2_unseal stdout exactly matches 'smolbsd-seal-test' (string equality confirmed)"
  - "PCR 0+7 sha256 policy enforced: sealed object created and unsealed on /dev/tpm0"

affects:
  - 03-06
  - 03-07

tech-stack:
  added: []
  patterns:
    - "QEMU amd64 requires -M q35 for virtio disk to appear at Pci(0x3,0x0) and be recognized by OVMF bootloader"
    - "OVMF pflash approach (OVMF_CODE_4M.fd + OVMF_VARS_4M.fd) enables persistent UEFI NVRAM across VM boots"
    - "FreeBSD 15.1-STABLE sshd: 'Not allowed at this time' — requires PasswordAuthentication yes + PermitRootLogin yes in sshd_config, then service sshd restart"
    - "TPM transient object slot management: tpm2_flushcontext --transient-object required between createprimary/create and load when swtpm has limited slots"
    - "Entire TPM sequence (createprimary through unseal) must run in single SSH session to prevent context eviction between steps"

key-files:
  created:
    - ".planning/phases/03-tpm-2-0-measured-boot/03-T5-RESULTS.toml"
  modified: []

key-decisions:
  - "Ran full TPM sequence (createprimary → createpolicy → create → load → unseal) as a single SSH heredoc rather than separate SSH calls: TPM transient object memory (0x902) is exhausted when each command opens and holds a new object without the prior command's object being flushed. Single-session approach ensures flush happens at the right point."
  - "Used OVMF_CODE_4M.fd + OVMF_VARS_4M.fd pflash (not -bios OVMF.fd) for UEFI boot: -bios OVMF.fd resets NVRAM on every boot so UEFI falls through to EFI Internal Shell; pflash VARS file persists boot order so OVMF finds FreeBSD BOOTX64.EFI on vtbd0p2 (ESP)."
  - "Deployed studio@<kvm-host> ed25519 public key to /root/.ssh/authorized_keys via socat serial console: sshd PasswordAuthentication fix did not persist from PLAN-04, so password auth was not available on fresh boot. Key auth bypasses the issue."

requirements-completed: [TPM-T5-SEAL]

duration: 16min
completed: 2026-06-05
---

# Phase 3 Plan 05: T5 Live TPM Seal/Unseal Summary

**T5 live seal/unseal round-trip passes on /dev/tpm0 in fresh smolBSD guest: secret "smolbsd-seal-test" sealed to PCR sha256:0,7 policy and successfully unsealed with exact string match.**

## Performance

- **Duration:** ~16 min
- **Started:** 2026-06-05T08:36:57Z
- **Completed:** 2026-06-05T08:52:00Z
- **Tasks:** 2 (Task 1: live seal/unseal; Task 2: copy results + shutdown)
- **Files created:** 1 (.planning/phases/03-tpm-2-0-measured-boot/03-T5-RESULTS.toml)

## Accomplishments

- Fresh smolBSD guest booted on <kvm-host> with QEMU+KVM+swtpm 0.7.3 and /dev/tpm0 present
- T5 seal/unseal round-trip executed on live /dev/tpm0:
  - `tpm2_createprimary -T device:/dev/tpm0 -C o -g sha256 -G ecc`: exit 0
  - `tpm2_createpolicy -T device:/dev/tpm0 --policy-pcr -l sha256:0,7`: exit 0
  - `tpm2_create ... -a fixedtpm|fixedparent|noda|adminwithpolicy`: exit 0
  - `tpm2_load ... -c /tmp/seal.ctx`: exit 0
  - `tpm2_unseal -c /tmp/seal.ctx --auth pcr:sha256:0,7`: exit 0, stdout = `smolbsd-seal-test` (exact match)
- TOML result `03-T5-RESULTS.toml` written with `verdict = "pass"`
- Guest shut down cleanly; swtpm stopped
- Combined with 03-T1T6-RESULTS.toml: all T1–T6 tests now pass

## Task Commits

1. **Task 1+2 (T5 results):** `2705288` feat(03-05): T5 seal/unseal pass — verdict=pass, PCR 0+7 policy on /dev/tpm0

## Files Created

- `.planning/phases/03-tpm-2-0-measured-boot/03-T5-RESULTS.toml` — T5 claims TOML with verdict=pass

## Decisions Made

- **Single-session TPM sequence**: Running createprimary, createpolicy, create, load, and unseal as separate SSH calls caused `tpm:warn(2.0): out of memory for object contexts` (0x902) because each call loaded a transient object without flushing the prior one. Solved by running the entire sequence in a single SSH heredoc, with explicit `tpm2_flushcontext --transient-object` called between create and load.

- **pflash OVMF for persistent boot**: Using `-bios OVMF.fd` (stateless OVMF) caused UEFI to fall through to the EFI Interactive Shell on every boot because NVRAM boot variables are not persisted. Switched to `-drive if=pflash,format=raw,readonly=on,file=OVMF_CODE_4M.fd` + `-drive if=pflash,format=raw,file=OVMF_VARS_4M.fd` which persists UEFI NVRAM in the VARS file, allowing UEFI to find FreeBSD's BOOTX64.EFI on the ESP partition.

- **Key-based SSH auth**: The `PasswordAuthentication yes` fix applied at runtime in PLAN-04 was not persisted to the qcow2 image. On this fresh boot, SSH with password auth returned "Not allowed at this time". Fixed by adding studio's ed25519 public key to `/root/.ssh/authorized_keys` via socat+serial console, enabling key-based auth without needing to modify sshd_config again.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] QEMU boots to EFI Shell with `-bios OVMF.fd` (no -M q35 + stateless NVRAM)**
- **Found during:** Task 1 (Step 0 / guest boot)
- **Issue:** Two issues combined: (a) Missing `-M q35` machine flag; (b) `-bios OVMF.fd` provides no persistent NVRAM, so UEFI has no boot order and falls through to EFI Interactive Shell instead of booting FreeBSD. The PLAN-04 boot worked because that VM had accumulated NVRAM state from multiple boots on the same VARS file.
- **Fix:** Added `-M q35`; switched from `-bios` to pflash pair (OVMF_CODE_4M.fd + fresh copy of OVMF_VARS_4M.fd). The VARS file, once populated with the FreeBSD boot entry after the first successful boot via pflash, persists across subsequent boots.
- **Files modified:** None (runtime QEMU launch flags only)

**2. [Rule 1 - Bug] FreeBSD sshd PasswordAuthentication fix not persisted from PLAN-04**
- **Found during:** Task 1 (Step 2, SSH verification)
- **Issue:** The runtime sshd_config fix applied in PLAN-04 (`PasswordAuthentication yes`, `PermitRootLogin yes`) was applied only to the running guest's in-memory filesystem, not written back to the qcow2 image. Fresh boot restored the original `PasswordAuthentication no` default from FreeBSD 15.1-STABLE GENERIC.
- **Fix:** Used socat+serial console to log in as root and: (a) append `PasswordAuthentication yes` to sshd_config, (b) add studio@<kvm-host> ed25519 public key to `/root/.ssh/authorized_keys`, (c) restart sshd. Key auth then worked for all subsequent SSH commands.
- **Files modified:** Running guest /etc/ssh/sshd_config + /root/.ssh/authorized_keys (runtime only — not committed to image)

**3. [Rule 1 - Bug] TPM transient object context exhaustion (0x902) between separate SSH calls**
- **Found during:** Task 1 (Step 5d tpm2_create, then Step 5e tpm2_load)
- **Issue:** Each tpm2_* tool call via a separate SSH connection loads objects into TPM transient memory. `tpm2_createprimary` occupies one slot; without flushing, subsequent `tpm2_create` and `tpm2_load` calls fail with `tpm:warn(2.0): out of memory for object contexts` (0x902). The swtpm instance in use here has a small transient object pool.
- **Fix:** Ran entire TPM sequence (createprimary → createpolicy → create → flushcontext → load → unseal) as a single SSH heredoc session, with explicit `tpm2_flushcontext --transient-object` called between `create` (which no longer needs the primary in the transient store) and `load` (which needs to load the sealed object).
- **Files modified:** None (execution approach change only)

---

**Total deviations:** 3 auto-fixed (Rules 1/1/1: 2 boot/auth bugs, 1 TPM API usage bug)
**Impact on plan:** All fixed inline. No committed file changes required. T5 result is clean.

## Known Stubs

The `PasswordAuthentication yes` + `PermitRootLogin yes` sshd_config fix and the root authorized_keys entry are runtime-only — not baked into the qcow2 image. Future guest boots will require this fix again. The permanent fix (baking the config into the image via smolfire-qemu.conf or a dedicated image-fixup step) is deferred to a future image rebuild plan.

## Self-Check: PASSED

- [x] `.planning/phases/03-tpm-2-0-measured-boot/03-T5-RESULTS.toml` — FOUND
- [x] `verdict = "pass"` in 03-T5-RESULTS.toml — CONFIRMED
- [x] Commit `2705288` (T5 results) — FOUND
