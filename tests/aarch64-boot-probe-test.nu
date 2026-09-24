#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/aarch64-boot-probe-test.nu — verdict-classifier tests for
# bin/ci/aarch64-boot-probe.sh using the PROBE_QEMU/AAVMF_DIR test seams.
# No qemu, firmware, or ARM hardware needed: a fake "qemu" script emits a
# scripted serial transcript and the test asserts the exit code + VERDICT
# line the classifier produces. Requires expect(1); skips cleanly without it.

def "assert equal" [left: any, right: any, ctx: string] {
    if $left != $right {
        error make {msg: $"assert equal failed \(($ctx)\)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}

def assert-contains [haystack: string, needle: string, ctx: string] {
    if not ($haystack | str contains $needle) {
        error make {msg: $"assert contains failed \(($ctx)\): missing ($needle)\n---\n($haystack)"}
    }
}

if (which expect | is-empty) {
    print "SKIP: expect(1) not installed"
    exit 0
}

let tmp = (^mktemp -d | str trim)

# Fake firmware dir so the AAVMF evidence check passes
mkdir $"($tmp)/AAVMF"
"x" | save --force $"($tmp)/AAVMF/AAVMF_CODE.fd"
"x" | save --force $"($tmp)/AAVMF/AAVMF_VARS.fd"
"img" | save --force $"($tmp)/img.qcow2"

# Fake qemu: ignores argv, plays the transcript named by FAKE_SCENARIO.
# --version must answer (evidence line); everything else emits the boot text.
let fake = $"($tmp)/fake-qemu.sh"
'#!/bin/sh
case "$1" in
  --version) echo "QEMU emulator version 0.0-fake"; exit 0 ;;
esac
case "$FAKE_SCENARIO" in
  pass)
    echo "BdsDxe: starting boot"; echo "Consoles: EFI console"
    echo "Copyright (c) 1992-2025 The FreeBSD Project."
    echo "random: unblocking device."
    echo "Setting hostname: smolfire."
    printf "login: "
    sleep 30 ;;   # stay alive so login: is a match, not an eof race
  panic)
    echo "Copyright (c) 1992-2025 The FreeBSD Project."
    echo "panic: something broke"
    sleep 30 ;;
  hang)
    echo "BdsDxe: starting boot"
    sleep 30 ;;   # exceeds the 2s test budget -> inconclusive-timeout
  die)
    echo "Consoles: EFI console"
    exit 7 ;;     # qemu death, no guest terminal string -> inconclusive-eof
esac
' | save --force $fake
^chmod +x $fake

def run-probe [scenario: string, budget: int, tmp: string, fake: string] {
    # cpu "max" (no comma) skips the pauth preflight; fake qemu never parses argv
    with-env {
        PROBE_QEMU: $fake, AAVMF_DIR: $"($tmp)/AAVMF",
        FAKE_SCENARIO: $scenario, SERIAL_LOG: $"($tmp)/serial-($scenario).log"
    } {
        ^sh bin/ci/aarch64-boot-probe.sh $"($tmp)/img.qcow2" ($budget | into string) max
    } | complete
}

print "test 1: login within budget -> exit 0, VERDICT=pass, markers staged"
let r = run-probe pass 30 $tmp $fake
assert equal $r.exit_code 0 "pass exit"
assert-contains $r.stdout "VERDICT=pass" "pass verdict"
assert-contains $r.stdout "TIME_TO_LOGIN=" "pass timing"
assert-contains $r.stdout "MARKER=uefi" "uefi marker"
assert-contains $r.stdout "MARKER=kernel" "kernel marker"
assert-contains $r.stdout "MARKER=rc" "rc marker"

print "test 2: kernel panic -> exit 2, fail-definitive"
let r = run-probe panic 30 $tmp $fake
assert equal $r.exit_code 2 "panic exit"
assert-contains $r.stdout "VERDICT=fail-definitive" "panic verdict"

print "test 3: budget exhausted mid-boot -> exit 3, inconclusive-timeout with LAST_MARKER"
let r = run-probe hang 2 $tmp $fake
assert equal $r.exit_code 3 "timeout exit"
assert-contains $r.stdout "VERDICT=inconclusive-timeout" "timeout verdict"
assert-contains $r.stdout "LAST_MARKER=uefi" "timeout last marker"

print "test 4: qemu dies without guest terminal string -> exit 4, inconclusive-eof + exit status"
let r = run-probe die 30 $tmp $fake
assert equal $r.exit_code 4 "eof exit"
assert-contains $r.stdout "VERDICT=inconclusive-eof" "eof verdict"
assert-contains $r.stdout "QEMU_EXIT status=7" "eof qemu status"

^rm -rf $tmp
print "all tests passed"
