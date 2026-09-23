---
phase: 03-tpm-2-0-measured-boot
plan: "07"
subsystem: infra
tags: [github-actions, freebsd, qcow2, tpm2-tools, smolbsd, ci, build-image, <kvm-host>]

requires:
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-03: smolbsd-amd64-tpm.qcow2 at /home/studio/smolbsd-ci/ on <kvm-host> — confirms the build approach and exact make invocation that works"
  - phase: 03-tpm-2-0-measured-boot
    provides: "03-04 / 03-05: tpm-vm-test.yml and CI runner registration confirming <kvm-host>-amd64 runner labels"

provides:
  - ".github/workflows/build-image.yml — CI workflow that rebuilds the smolBSD TPM qcow2 on <kvm-host> via workflow_dispatch or on push to SMOLBSD/smolfire-qemu.conf"
  - "Repeatable CI path for rebuilding the image when kernel config or release conf changes"
  - "SHA256 manifest update step baked into workflow for cache invalidation"

affects:
  - 03-tpm-vm-tests
  - tpm-vm-test.yml (consumes the artifact this workflow produces)

tech-stack:
  added:
    - "GitHub Actions workflow_dispatch + path-based push trigger"
    - "make cloudware-release with SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs (replaces vm-image stub)"
  patterns:
    - "cloudware-release is the correct make target for custom CLOUDWARE types not predefined in Makefile.vm"
    - "MK_DEBUG_FILES=no MK_TESTS=no MK_LIB32=no skip install steps that require bootstrap obj dirs"
    - "QEMUSTATIC probe is informational only for amd64 targets — native execution suffices"
    - "sha256sum manifest written alongside artifact for CI cache invalidation"

key-files:
  created:
    - ".github/workflows/build-image.yml"
  modified: []

key-decisions:
  - "Used make cloudware-release (not make vm-image) because smolbsd is not a predefined cloudware type in Makefile.vm — vm-image only produces a touch stub for unknown types (confirmed in plan-03 deviations)"
  - "VMSIZE=4g used (not 2g) matching plan-03 actual build — smolfire-qemu.conf export VMSIZE=2g is overridden on the make command line"
  - "Image size check is a warn-only step (not a failure gate) because tpm2-tools + 12 deps push image to ~700 MiB, exceeding the 512 MiB soft limit accepted in plan-03"
  - "MK_DEBUG_FILES=no MK_TESTS=no MK_LIB32=no added to make invocation to prevent installworld failures when bootstrap obj dirs have been cleaned"

patterns-established:
  - "Workflow copies configs from checkout into pre-existing freebsd-src tree on <kvm-host> runner — no full src clone needed on each run"
  - "Artifact discovery uses find with -newer /tmp/build.log to locate qcow2 regardless of exact output subdir"
  - "build-image.yml and tpm-vm-test.yml are intentionally separate workflows (D-03): build produces, test consumes"

requirements-completed: [TPM-CI-BUILD-WORKFLOW]

duration: 8min
completed: 2026-06-05
---

# Phase 3 Plan 07: Build Image Workflow Summary

**GitHub Actions workflow build-image.yml targeting <kvm-host>-amd64 runner, building smolBSD qcow2 via make cloudware-release KERNCONF=SMOLBSD with tpm2-tools baked in, saving artifact + SHA256 manifest to /home/studio/smolbsd-ci/**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-05T07:25:00Z
- **Completed:** 2026-06-05T07:33:00Z
- **Tasks:** 1
- **Files modified:** 1 (created)

## Accomplishments
- `.github/workflows/build-image.yml` created — manually triggerable and path-triggered CI workflow
- Workflow copies `sys/amd64/conf/SMOLBSD` and `release/tools/smolfire-qemu.conf` from checkout into `$FREEBSD_SRC` on <kvm-host>
- Build invokes `make cloudware-release KERNCONF=SMOLBSD SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs` — the exact approach proven in plan-03
- No `WITHOUT_QEMU`, `NOPKG`, or `NOPKGBASE` flags — tpm2-tools must be installed via pkg during the build
- Artifact copied to `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` with SHA256 manifest and `BUILD-INFO.txt`

## Task Commits

1. **Task 1: Create build-image.yml for smolBSD TPM image rebuild** - `5a16b0b` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified
- `.github/workflows/build-image.yml` — 182-line GitHub Actions workflow: workflow_dispatch + push triggers, <kvm-host>-amd64 runner, config copy, cloudware-release build, artifact promotion, SHA256 manifest

## Decisions Made
- `make cloudware-release` used instead of `make vm-image`: plan-07 template shows `make -C release vm-image`, but plan-03 confirmed this generates only a `touch vm-image` stub for non-predefined CLOUDWARE types. The `cloudware-release` target with `SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs` is the approach that actually built the image.
- Image size check is warn-only: plan-03 accepted the >512 MiB deviation; failing CI on a known accepted condition would be misleading.
- `VMSIZE=4g` on make command line: overrides `export VMSIZE=2g` in `smolfire-qemu.conf` to match the actual build that produced the working image in plan-03.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Used make cloudware-release instead of make vm-image**
- **Found during:** Task 1 (build step design)
- **Issue:** The plan-07 template shows `make -C release vm-image KERNCONF=SMOLBSD CLOUDWARE=smolbsd ...`. Plan-03-SUMMARY documents that this invocation only generates a `touch vm-image` stub because `smolbsd` is not a predefined cloudware type in `Makefile.vm`. The correct invocation is `make cloudware-release` with `SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs`.
- **Fix:** Replaced `make -C release vm-image` with `make -C release cloudware-release` and added `SMOLBSD_FORMAT=qcow2 SMOLBSD_FSLIST=ufs CLOUDWARE_CONF=...` arguments.
- **Files modified:** `.github/workflows/build-image.yml`
- **Verification:** Build command matches the approach documented as successful in 03-03-SUMMARY.md.
- **Committed in:** `5a16b0b` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — plan template used the non-working vm-image target; replaced with the cloudware-release invocation proven in plan-03)
**Impact on plan:** Required for correctness — the vm-image target would silently succeed (exit 0) without building anything. No scope creep.

## Issues Encountered
- `bin/copy-configs-to-freebsd.sh` referenced in CONTEXT.md as "already implemented" does not exist in the repo. Used direct `cp` commands in the workflow steps instead. Not a blocker — the script was probably planned/mentioned but never committed.

## Known Stubs
None — the workflow is complete and references no placeholder paths or hardcoded mock values. All paths are the actual <kvm-host> paths confirmed in plan-03.

## User Setup Required
None — <kvm-host> runner is already registered (confirmed in plan-04/05 context). No new external configuration required.

## Next Phase Readiness
- `build-image.yml` is ready to trigger whenever the smolBSD kernel config or release conf changes
- After a manual `workflow_dispatch` run, the artifact at `/home/studio/smolbsd-ci/smolbsd-amd64-tpm.qcow2` will be refreshed and SHA256 updated
- `tpm-vm-test.yml` can now reference the stable artifact path with confidence that `build-image.yml` keeps it current

---
*Phase: 03-tpm-2-0-measured-boot*
*Completed: 2026-06-05*
