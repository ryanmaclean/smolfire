# Upstream candidate: take the TSC frequency from the KVM pvclock

Patch: `tsc-kvmclock-freq.patch` (unified diff against releng/15.0
`sys/x86/x86/tsc.c`; applied by `bin/build-smolfire.sh`, guarded by
`tests/tsc-kvmclock-patch-test.nu` against the pristine file in
`tests/fixtures/freebsd-releng-15.0/`). Roadmap: `docs/BOOT-TIME-ROADMAP.md` §2.2.

## Problem

On a KVM guest that has neither CPUID leaf 0x40000010 (hypervisor TSC/lapic
frequency — Firecracker does not publish it; QEMU only with
`vmware-cpuid-freq=on`) nor Intel leaf 0x15/0x16 (absent on AMD hosts),
`probe_tsc_freq_early()` finds no frequency, so:

1. `probe_tsc_freq_late()` (SYSINIT `cpu`) spins `DELAY(100000)` against the
   i8254 in `tsc_freq_tc()` — ~101 ms;
2. `tsc_calibrate()` (SYSINIT `clocks`) runs `clockcalib()` for another
   ~130–170 ms because `tsc_early_calib_exact` is unset.

Measured on the SMOLFIRE Firecracker gate (TSLOG run 35829303519): ~259 ms of
a ~476 ms boot, the largest single cost.

KVM already knows the guest TSC rate exactly: it derives the pvclock
`tsc_to_system_mul`/`tsc_shift` scale from the vCPU's virtual TSC kHz. Linux
has used this as the calibrated TSC frequency since 2010
(`kvm_get_tsc_khz()` → `pvclock_tsc_khz()`, `arch/x86/kernel/kvmclock.c`),
and FreeBSD's own `kvm_clock(4)` already exports it as
`dev.kvmclock.0.tsc_freq` via `pvclock_tsc_freq()` — just too late in boot to
avoid calibration.

## Change

`tsc_freq_kvmclock()` — only when `vm_guest == VM_GUEST_KVM` and CPUID
0x40000001 advertises `KVM_FEATURE_CLOCKSOURCE2` (or the legacy bit):
register a private, 64-byte-aligned `pvclock_vcpu_time_info` via
`MSR_KVM_SYSTEM_TIME(_NEW)`, read a consistent (even, non-zero version)
mul/shift, unregister (write 0) so `kvm_clock(4)` can claim the MSR later,
and compute `freq = (10^9 << 32) / mul` then apply the shift (identical to
`pvclock_tsc_freq()`). `probe_tsc_freq_late()` consults it before the PIT
fallback and sets `tsc_early_calib_exact`, so both calibration passes are
skipped. It runs after pmap bootstrap (`vtophys()` of static kernel data).

Opt-out: loader tunable / PVH boot arg `machdep.tsc_kvmclock_freq=0`.
Non-KVM guests, bare metal, and KVM guests that already get 0x40000010 or
leaf 0x15 are unaffected (the new path is reached only when
`tsc_freq == 0` after the early probe).

## Not covered (next step)

The lapic timer still runs its own `clockcalib()` (~11 ms in the TSLOG
split) because `lapic_calibrate_initcount_cpuid_vm()` also keys on 0x40000010.
KVM's emulated APIC timer runs at a fixed bus rate (1 GHz by default,
configurable since Linux 6.10 via `KVM_CAP_X86_APIC_BUS_CYCLES_NS`), which is
not discoverable from the guest, so it is left calibrated.

## Verification

- Hermetic: `nu tests/tsc-kvmclock-patch-test.nu` (applies with no fuzz to
  releng/15.0, ordering before the PIT fallback, pvclock-scale round trip).
- Boot: `smolfire.yml` Firecracker gate (`TIME_TO_READY`, NET_GATE,
  HOST_PING, shell) + QEMU microvm gate, then a `tslog=true` dispatch;
  `SMOLFIRE_TSLOG_META tsc_freq=` must match the prior calibrated value
  (2.445 GHz on the hosted runner) and the `cpu`/`clocks` SYSINITs must drop
  by the ~259 ms above. Results land in `docs/BOOT-TIME-ROADMAP.md` §2.2.
