# Upstream submission: non-Xen PVH boots fault in xen_delay before timecounters

Ready-to-file FreeBSD Bugzilla report (Base System > kern) + patch
(`pvh-early-delay.patch`, unified diff against releng/15.0 `sys/x86/xen/pv.c`;
main is byte-identical at the target as of 2026-07-28). Discovered and
validated by smolfire's SMOLFIRE CI (see `docs/UR-BSD-VERIFY.md`, SMOLFIRE
section, runs #5–#9).

## Summary (paste as the report body)

When FreeBSD/amd64 is booted via the PVH entry point by a non-Xen VMM
(Firecracker, QEMU microvm), `hammer_time_xen()` installs
`xen_pvh_init_ops` whose `early_delay` hook is `xen_delay()`, which
unconditionally dereferences `HYPERVISOR_shared_info` — a page that is
only ever mapped by a Xen hypercall — so any `DELAY()` issued before the
TSC timecounter is usable (e.g. TSC calibration falling back to the
i8254, which is what happens on CPUs without the Intel CPUID 0x15/0x16
frequency leaves, such as AMD guests) faults and the boot dies;
`early_clock_source_init` is likewise the empty `xen_clock_init()`,
leaving the i8254 unprogrammed. `pv.c` already contains `isxen()` (a
CPUID hypervisor-signature probe explicitly documented as "sufficient to
distinguish Xen PVH booting from non-Xen PVH") and already dispatches
`parse_memmap` at runtime, but the early clock/delay hooks were never
given the same treatment. The attached patch adds
`pvh_early_clock_source_init()`/`pvh_early_delay()` wrappers that call
the Xen implementations under Xen and fall back to
`i8254_init()`/`i8254_delay()` (the native `init_ops` pair; both
Firecracker and QEMU microvm emulate an i8254 via the KVM in-kernel PIT)
otherwise — fixing non-Xen PVH boot with no behavior change under real
Xen.

## Reproduction

1. Build a FIRECRACKER-config kernel from releng/15.0 on an AMD host
   (no CPUID 0x15/0x16, so the early TSC frequency probe yields 0).
2. Boot it under Firecracker >= 1.12.0 (first release with PVH) with
   `boot_args = "hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0"`.
3. Observed: `trap 12` / page fault, backtrace
   `pvclock_get_timecount <- xen_delay <- start_TSC`.
   (With calibration left disabled instead: `panic: TSC not initialized`
   in `lapic_init` on the same hosts — either way the kernel cannot
   boot where the CPUID frequency leaves are absent.)
4. With the patch: boots to userland; `Timecounter "TSC-low"` appears
   (i8254-calibrated). Verified on Firecracker v1.12.0 and
   `qemu-system-x86_64 -M microvm -kernel` (QEMU 8.x), 1 vCPU, KVM.

## Notes for review

- Dispatch style mirrors the existing `pvh_parse_memmap` runtime wrapper
  in the same file; `isxen()` caches a pure CPUID probe and is already
  used before `init_ops` is installed (the `CRASH()` macro).
- Alternative shape (mutating the `init_ops` copy in `hammer_time_xen`
  under `!isxen()`) is functionally equivalent if preferred.
- The smolfire build applies this exact patch via
  `bin/build-smolfire.sh`; drop that block once this lands.
