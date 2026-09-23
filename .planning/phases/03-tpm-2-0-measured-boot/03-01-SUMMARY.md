---
phase: 03-tpm-2-0-measured-boot
plan: "01"
subsystem: infra
tags: [freebsd, tpm2-tools, qemu, smolbsd, vmimage, build-config]

# Dependency graph
requires:
  - phase: 02-physical-board-configs
    provides: freebsd-src tree on <kvm-host> with bhyve harness
provides:
  - smolfire-qemu.conf with VM_EXTRA_PACKAGES=tpm2-tools baked in
  - SMOLBSD kernel config (device tpm) present in freebsd-src tree on <kvm-host>
  - smolfire-qemu.conf present in freebsd-src tree on <kvm-host>
  - /home/studio/smolbsd-ci output directory created on <kvm-host>
  - qemu-x86_64-static status documented (ABSENT — native amd64 build required)
affects:
  - 03-02-PLAN.md (Wave 2 build — uses these configs)
  - 03-03-PLAN.md (image verification)

# Tech tracking
tech-stack:
  added: [tpm2-tools (via VM_EXTRA_PACKAGES in smolfire-qemu.conf)]
  patterns:
    - VM_EXTRA_PACKAGES export in smolfire-qemu.conf for baking ports/pkg into image at build time
    - bin/copy-configs-to-freebsd.sh used as canonical mechanism to push smolBSD configs into freebsd-src tree

key-files:
  created:
    - .planning/phases/03-tpm-2-0-measured-boot/03-PREFLIGHT-NOTES.md (<kvm-host> probe results)
  modified:
    - release/tools/smolfire-qemu.conf (added VM_EXTRA_PACKAGES=tpm2-tools)

key-decisions:
  - "D-02 confirmed: pre-bake tpm2-tools into image (not install at test time) — SLIRP has no outbound internet"
  - "qemu-x86_64-static ABSENT on <kvm-host> — Wave 2 uses native amd64 build, no cross-arch emulation needed"

patterns-established:
  - "Pattern 1: VM_EXTRA_PACKAGES in smolfire-qemu.conf drives pkg install into DESTDIR chroot during make vm-image"
  - "Pattern 2: pre-bake tools into image rather than relying on network at test time"

requirements-completed: [TPM-BUILD-CONFIG]

# Metrics
duration: 7min
completed: 2026-06-04
---

# Phase 3 Plan 01: smolfire-qemu.conf tpm2-tools + <kvm-host> build prep Summary

**smolfire-qemu.conf updated with VM_EXTRA_PACKAGES=tpm2-tools, SMOLBSD configs deployed to freebsd-src on <kvm-host>, qemu-x86_64-static probed ABSENT (native build path confirmed)**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-06-04T22:32:14Z
- **Completed:** 2026-06-04T22:39:00Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `export VM_EXTRA_PACKAGES="tpm2-tools"` to `release/tools/smolfire-qemu.conf` immediately after `VM_RC_LIST`, passing shellcheck
- Probed <kvm-host> (<kvm-host-ip>): qemu-x86_64-static is ABSENT — Wave 2 build runs natively (amd64 host = amd64 target, no cross-emulation needed)
- Created `/home/studio/smolbsd-ci` output directory on <kvm-host>
- Copied SMOLBSD kernel config (containing `device tpm`) into `/home/studio/bsd-build/src/freebsd-src/sys/amd64/conf/SMOLBSD`
- Copied updated smolfire-qemu.conf (with `VM_EXTRA_PACKAGES=tpm2-tools`) into `/home/studio/bsd-build/src/freebsd-src/release/tools/smolfire-qemu.conf`
- Documented all findings in `03-PREFLIGHT-NOTES.md`

## Task Commits

Each task was committed atomically:

1. **Task 1: Add VM_EXTRA_PACKAGES to smolfire-qemu.conf** - `b87cd1d` (feat) — worktree commit
2. **Task 2: Probe <kvm-host> and prepare build directory** - `beeae92` (feat) — main repo commit

## Files Created/Modified

- `release/tools/smolfire-qemu.conf` — Added VM_EXTRA_PACKAGES="tpm2-tools" export (4 lines: blank line, 2 comment lines, export line)
- `.planning/phases/03-tpm-2-0-measured-boot/03-PREFLIGHT-NOTES.md` — Appended <kvm-host> probe results: qemu-x86_64-static status, smolbsd-ci creation, freebsd-src config verification

## Decisions Made

- D-02 confirmed: pre-bake tpm2-tools into the image at build time. The SLIRP network in the QEMU test environment has no outbound internet access, so installing via pkg at test time is not feasible.
- qemu-x86_64-static is ABSENT on <kvm-host> but this is not a blocker: the build host is x86_64 Linux and the target is amd64 FreeBSD, so pkg can install into the DESTDIR chroot natively without a static emulator.

## Deviations from Plan

None - plan executed exactly as written.

The plan specified `scp` as the mechanism to copy files to <kvm-host>; `bin/copy-configs-to-freebsd.sh` was referenced for context only (it is a local-to-local copy tool, not an scp wrapper). Used direct `scp` commands as specified.

## Issues Encountered

None. SSH to <kvm-host>, scp transfers, and all remote verifications succeeded on first attempt.

## User Setup Required

None - no external service configuration required. All preparation was fully automated.

## Next Phase Readiness

Wave 2 (Plan 03-02) can proceed:

- freebsd-src tree on <kvm-host> has both SMOLBSD kernel config and smolfire-qemu.conf with tpm2-tools
- /home/studio/smolbsd-ci is ready to receive build output
- qemu-x86_64-static absence is documented; Wave 2 executor should use native build path (no QEMUSTATIC needed for amd64)
- No blockers

---
*Phase: 03-tpm-2-0-measured-boot*
*Completed: 2026-06-04*
