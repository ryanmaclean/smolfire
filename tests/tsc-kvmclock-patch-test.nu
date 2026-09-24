#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/tsc-kvmclock-patch-test.nu — hermetic checks for the TSC-from-KVM-
# pvclock kernel patch (docs/upstream/tsc-kvmclock-freq.md,
# docs/BOOT-TIME-ROADMAP.md §2.2). The real proof is the Firecracker gate +
# TSLOG run in smolfire.yml; this guards the patch artifact and the build
# script wiring so a stale or unapplied patch fails before a 45-min CI build.
#
# Fixture: tests/fixtures/freebsd-releng-15.0/sys/x86/x86/tsc.c is the
# unmodified releng/15.0 file (BSD-2-Clause, header retained).

def fail [msg: string] {
    print $"tsc-kvmclock-patch-test: FAIL — ($msg)"
    exit 1
}

let patch_file = ("docs/upstream/tsc-kvmclock-freq.patch" | path expand)
let fixture = ("tests/fixtures/freebsd-releng-15.0/sys/x86/x86/tsc.c" | path expand)
let build = (open --raw bin/build-smolfire.sh)
let workflow = (open --raw .github/workflows/smolfire.yml)

if not ($patch_file | path exists) { fail "patch file missing" }
if not ($fixture | path exists) { fail "releng/15.0 tsc.c fixture missing" }

# 1. The patch applies cleanly (no fuzz, no offset drift) to pristine releng/15.0.
let tmp = (mktemp -d)
let tree = ($tmp | path join "src")
mkdir ($tree | path join "sys/x86/x86")
cp $fixture ($tree | path join "sys/x86/x86/tsc.c")
let r = (do { ^patch -p1 -F0 -d $tree -i $patch_file } | complete)
if $r.exit_code != 0 { rm -rf $tmp; fail $"patch does not apply to releng/15.0 tsc.c: ($r.stdout) ($r.stderr)" }
if ($r.stdout | str contains "offset") or ($r.stdout | str contains "fuzz") {
    rm -rf $tmp; fail $"patch applied with drift: ($r.stdout)"
}
let patched = (open --raw ($tree | path join "sys/x86/x86/tsc.c"))

# 2. The patched file has the load-bearing pieces.
for needle in [
    "static bool\ntsc_freq_kvmclock(uint64_t *res)"
    "#include <x86/kvm.h>"
    "#include <machine/pvclock.h>"
    "#include <vm/pmap.h>"
    "if (vm_guest != VM_GUEST_KVM || !tsc_kvmclock_freq)"
    "KVM_MSR_SYSTEM_TIME_NEW"
    "wrmsr(msr, vtophys(ti) | 1);"
    "wrmsr(msr, 0);"
    "freq = (1000000000ULL << 32) / mul;"
    "SYSCTL_INT(_machdep, OID_AUTO, tsc_kvmclock_freq, CTLFLAG_RDTUN,"
] {
    if not ($patched | str contains $needle) { rm -rf $tmp; fail $"patched tsc.c missing: ($needle)" }
}

# 3. The pvclock path is consulted in probe_tsc_freq_late BEFORE the PIT
#    fallback and marks the frequency exact (that is what skips clockcalib).
let late = ($patched | split row "probe_tsc_freq_late(void)\n{" | get 1 | split row "\nvoid\nstart_TSC" | get 0)
let i_kvm = ($late | str index-of "tsc_freq_kvmclock(&tsc_freq)")
let i_exact = ($late | str index-of "tsc_early_calib_exact = 1;")
let i_pit = ($late | str index-of "tsc_freq_tc(&tsc_freq)")
if $i_kvm < 0 or $i_exact < 0 or $i_pit < 0 { rm -rf $tmp; fail "probe_tsc_freq_late lacks kvmclock/exact/PIT markers" }
if not ($i_kvm < $i_exact and $i_exact < $i_pit) { rm -rf $tmp; fail "kvmclock path must precede the 8254 PIT calibration" }
if not ($patched | str contains "if (tsc_early_calib_exact)\n\t\tgoto calibrated;") {
    rm -rf $tmp; fail "tsc_calibrate no longer short-circuits on tsc_early_calib_exact"
}

# 4. Re-applying is detected (build script classifies patched trees).
let r2 = (do { ^patch -p1 -N --dry-run -d $tree -i $patch_file } | complete)
if $r2.exit_code == 0 { rm -rf $tmp; fail "patch re-applies to an already-patched tree" }
rm -rf $tmp

# 5. The pvclock frequency formula matches KVM's scale for known rates
#    (freq = (1e9 << 32) / mul, then shift) — mirror of pvclock_tsc_freq().
def kvm_scale [hz: int] {
    # KVM kvm_get_time_scale(NSEC_PER_SEC, hz): find shift so that
    # base_hz <= 2^32 * 1e9 range, then mul = (1e9 << 32) / scaled_hz.
    mut shift = 0
    mut tps = $hz
    let scaled = 1_000_000_000
    while $tps > ($scaled * 2) { $tps = ($tps // 2); $shift = $shift - 1 }
    while $tps <= $scaled { $tps = ($tps * 2); $shift = $shift + 1 }
    { mul: (($scaled * 4294967296) // $tps), shift: $shift }
}
def pv_freq [mul: int, shift: int] {
    let f = ((1_000_000_000 * 4294967296) // $mul)
    if $shift < 0 { $f * (2 ** (0 - $shift)) } else { $f // (2 ** $shift) }
}
for hz in [2_445_000_000 2_095_078_000 3_000_000_000 1_000_000_000] {
    let s = (kvm_scale $hz)
    let got = (pv_freq $s.mul $s.shift)
    let err_ppm = ((($got - $hz) | math abs) * 1_000_000 / $hz)
    if $err_ppm > 1 { fail $"pvclock round-trip for ($hz) Hz off by ($err_ppm) ppm \(got ($got)\)" }
}

# 6. Build script wiring: fail-loud three-way classification + opt-out doc.
for needle in [
    "TSC_PATCH=\"$REPO_DIR/docs/upstream/tsc-kvmclock-freq.patch\""
    "grep -q 'tsc_freq_kvmclock' \"$TSC\""
    "patch -p1 -d /usr/src < \"$TSC_PATCH\""
    "ERROR: tsc.c shape unrecognized"
    "machdep.tsc_kvmclock_freq=0"
] {
    if not ($build | str contains $needle) { fail $"bin/build-smolfire.sh missing: ($needle)" }
}
# Patch must be applied before buildkernel.
if ($build | str index-of "TSC_PATCH") > ($build | str index-of "buildkernel \\") {
    fail "tsc.c patch block must precede buildkernel"
}
# The repo tree reaches the build VM (tar of the checkout) and CI rebuilds on patch edits.
if not ($workflow | str contains "docs/upstream/tsc-kvmclock-freq.patch") {
    fail "smolfire.yml path filters must include the tsc patch"
}

print "tsc-kvmclock-patch-test: ok"
