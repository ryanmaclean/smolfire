#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/boot-gates-test.nu — (a) aarch64 soft-gate soft|hard promotion switch in
# build-image-hosted.yml, executed against a stub probe; (b) riscv64 boot probe
# verdict classifier (fake qemu) + real qemu-system-riscv64 firmware chain
# (OpenSBI -> U-Boot) when installed. Skips pieces whose tools are absent.

def "assert equal" [left: any, right: any, ctx: string] {
    if $left != $right {
        error make {msg: $"assert equal failed \(($ctx)\)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert-contains [h: string, n: string, ctx: string] {
    if not ($h | str contains $n) { error make {msg: $"assert contains failed \(($ctx)\): missing ($n)\n---\n($h)"} }
}

let root = ($env.FILE_PWD | path dirname)
let tmp = (^mktemp -d | str trim)

# ---------- (a) workflow soft/hard switch ----------
let wf = (open $"($root)/.github/workflows/build-image-hosted.yml")
let inputs = $wf.on.workflow_dispatch.inputs
print "test a1: dispatch inputs default to current soft behaviour"
assert equal $inputs.softgate_mode.default "soft" "mode default"
assert equal $inputs.softgate_mode.options ["soft" "hard"] "mode options"
assert equal $inputs.softgate_budget.default "900" "budget default"

let job = $wf.jobs."aarch64-boot-softgate"
print "test a2: job env falls back to soft/900"
assert-contains $job.env.SOFTGATE_MODE "|| 'soft'" "mode fallback"
assert-contains $job.env.SOFTGATE_BUDGET "|| '900'" "budget fallback"

let step = ($job.steps | where {|s| ($s.name? | default "") | str starts-with "Boot gate" } | first)
let script = $"($tmp)/gate-step.sh"
$step.run | save --force $script
print "test a3: gate step is valid bash"
assert equal (^bash -n $script | complete).exit_code 0 "bash -n"

# Run the real step text in a sandbox with a stub probe returning $probe_rc.
def run-gate [mode: string, probe_rc: int, tmp: string, script: string] {
    let d = $"($tmp)/sb-($mode)-($probe_rc)"
    mkdir $"($d)/bin/ci"
    $"#!/bin/sh\necho \"args: $*\"\nif [ ($probe_rc) -eq 0 ]; then echo TIME_TO_LOGIN=5s; echo VERDICT=pass; fi\nif [ ($probe_rc) -eq 3 ]; then echo VERDICT=inconclusive-timeout LAST_MARKER=kernel; fi\nif [ ($probe_rc) -eq 2 ]; then echo VERDICT=fail-definitive; fi\nexit ($probe_rc)\n" | save --force $"($d)/bin/ci/aarch64-boot-probe.sh"
    touch $"($d)/smolfire-aarch64.qcow2"
    with-env {SOFTGATE_MODE: $mode, SOFTGATE_BUDGET: "77", GITHUB_STEP_SUMMARY: $"($d)/summary"} {
        cd $d
        ^bash $script | complete
    }
}
print "test a4: soft + inconclusive -> exit 0 with warning (unchanged default)"
let r = (run-gate soft 3 $tmp $script)
assert equal $r.exit_code 0 "soft inconclusive"
assert-contains $r.stdout "::warning::" "soft warning"
assert-contains $r.stdout "args: smolfire-aarch64.qcow2 77 max,pauth-impdef=on" "budget plumbed"
print "test a5: hard + inconclusive -> exit 1 (RED) after retry"
let r = (run-gate hard 3 $tmp $script)
assert equal $r.exit_code 1 "hard inconclusive"
assert-contains $r.stdout "attempts=2" "retried once"
print "test a6: pass is green and fail-definitive is red in both modes"
for m in [soft hard] {
    assert equal (run-gate $m 0 $tmp $script).exit_code 0 $"($m) pass"
    assert equal (run-gate $m 2 $tmp $script).exit_code 2 $"($m) fail-definitive"
}
print "test a7: bad mode rejected"
assert equal (run-gate banana 0 $tmp $script).exit_code 64 "bad mode"

# ---------- (b) riscv64 probe ----------
if (which expect | is-empty) {
    print "SKIP riscv64: expect(1) not installed"
    ^rm -rf $tmp
    print "all tests passed"
    exit 0
}
"x" | save --force $"($tmp)/uboot.bin"
"img" | save --force $"($tmp)/img.qcow2"
let fake = $"($tmp)/fake-qemu.sh"
'#!/bin/sh
case "$1" in --version) echo "QEMU emulator version 0.0-fake"; exit 0 ;; esac
case "$FAKE_SCENARIO" in
  pass) echo "OpenSBI v1.3"; echo "U-Boot 2025.10"; echo "Copyright (c) 1992-2025 The FreeBSD Project."
        echo "Setting hostname: smolfire."; printf "login: "; sleep 30 ;;
  panic) echo "U-Boot 2025.10"; echo "panic: boom"; sleep 30 ;;
  hang) echo "OpenSBI v1.3"; echo "U-Boot 2025.10"; sleep 30 ;;
  die) echo "OpenSBI v1.3"; exit 7 ;;
esac
' | save --force $fake
^chmod +x $fake
def run-rv [scenario: string, budget: int, tmp: string, fake: string, root: string] {
    with-env {PROBE_QEMU: $fake, UBOOT_BIN: $"($tmp)/uboot.bin", OPENSBI_FW: "default",
              FAKE_SCENARIO: $scenario, SERIAL_LOG: $"($tmp)/rv-($scenario).log"} {
        ^sh $"($root)/bin/ci/riscv64-boot-probe.sh" $"($tmp)/img.qcow2" ($budget | into string)
    } | complete
}
print "test b1: riscv64 pass -> 0, staged markers"
let r = run-rv pass 30 $tmp $fake $root
assert equal $r.exit_code 0 "rv pass"
for m in ["MARKER=opensbi" "MARKER=uboot" "MARKER=kernel" "MARKER=rc" "VERDICT=pass" "TIME_TO_LOGIN="] { assert-contains $r.stdout $m $m }
print "test b2: riscv64 panic -> 2"
let r = run-rv panic 30 $tmp $fake $root
assert equal $r.exit_code 2 "rv panic"
print "test b3: riscv64 hang -> 3 LAST_MARKER=uboot"
let r = run-rv hang 2 $tmp $fake $root
assert equal $r.exit_code 3 "rv timeout"
assert-contains $r.stdout "LAST_MARKER=uboot" "rv last marker"
print "test b4: riscv64 qemu death -> 4"
let r = run-rv die 30 $tmp $fake $root
assert equal $r.exit_code 4 "rv eof"
assert-contains $r.stdout "QEMU_EXIT status=7" "rv eof status"

let ub = "/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin"
if (which qemu-system-riscv64 | is-empty) or (not ($ub | path exists)) {
    print "SKIP b5: qemu-system-riscv64 / u-boot-qemu not installed"
} else {
    print "test b5: REAL qemu-system-riscv64 firmware chain with blank disk -> OpenSBI+U-Boot reached, no login"
    let blank = $"($tmp)/blank.qcow2"
    ^qemu-img create -f qcow2 $blank 16M | complete | ignore
    let r = (with-env {SERIAL_LOG: $"($tmp)/rv-real.log"} {
        ^sh $"($root)/bin/ci/riscv64-boot-probe.sh" $blank "25" } | complete)
    assert equal $r.exit_code 3 "blank disk -> timeout"
    assert-contains $r.stdout "MARKER=opensbi" "real opensbi"
    assert-contains $r.stdout "MARKER=uboot" "real uboot"
    assert-contains $r.stdout "LAST_MARKER=uboot" "real last marker"
}

^rm -rf $tmp
print "all tests passed"
