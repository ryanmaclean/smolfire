#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source-only Firecracker --version fixtures. No VMM, kernel, or KVM is run.
use firecracker-version-evidence.nu stable_firecracker_version

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def rejects [raw: string, name: string] {
    let accepted = (try { stable_firecracker_version $raw; true } catch { false })
    require (not $accepted) $"accepted malformed version fixture: ($name)"
}

def main [] {
    let first = "Firecracker v1.12.0\n\n2026-10-08T20:45:16.864503670 [anonymous-instance:main] Firecracker exiting successfully. exit_code=0\n"
    let second = "Firecracker v1.12.0\n\n2026-10-08T20:47:11.627668500 [anonymous-instance:main] Firecracker exiting successfully. exit_code=0\n"
    require ((stable_firecracker_version $first) == 'Firecracker v1.12.0') 'first hosted-style version rejected'
    require ((stable_firecracker_version $second) == (stable_firecracker_version $first)) 'different successful-exit timestamps changed stable version'
    require ((stable_firecracker_version 'Firecracker v1.12.0') == 'Firecracker v1.12.0') 'bare exact banner rejected'

    rejects ($first | str replace 'v1.12.0' 'v1.13.0') 'wrong version'
    rejects ($first | str replace '20:45:16.864503670' '20:45:16') 'missing nanoseconds'
    rejects ($first | str replace 'exit_code=0' 'exit_code=1') 'nonzero exit log'
    rejects ($first | str replace '[anonymous-instance:main]' '[foreign-instance:main]') 'foreign instance log'
    rejects ($first | str replace "\n\n2026" "\n2026") 'missing separator'
    rejects ($first + "extra log line\n") 'extra line'
    rejects ($first + "Firecracker v1.12.0\n") 'duplicate banner'
    rejects ("prefix\n" + $first) 'prefixed banner'
    rejects 'other Firecracker v1.12.0 text' 'embedded version text'
    print 'firecracker-version-evidence-test: PASS'
}
