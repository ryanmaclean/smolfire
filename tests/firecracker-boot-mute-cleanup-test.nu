#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Pure ownership decision fixture: no process is started or signaled.
source firecracker-boot-mute-pairs.nu
use firecracker-owner-scan.nu read_decision

let work = '/mnt/smolfire-ci'
let cfg = '/mnt/smolfire-ci/firecracker-boot-mute/release-1-off-config.json'
let exact = (argv $work $cfg)
if $exact != ['/mnt/smolfire-ci/firecracker' '--no-api' '--config-file' $cfg] {
    error make {msg: 'exact Firecracker argv changed'}
}
if (cleanup_decision true true false) != 'WAIT' { error make {msg: 'exact owner must receive bounded TERM wait'} }
if (cleanup_decision true true true) != 'KILL' { error make {msg: 'TERM-resistant exact owner must escalate to KILL'} }
if (owner_decision true 'R' true true true) != 'SIGNAL' { error make {msg: 'exact live owner did not qualify for normal cleanup'} }
for row in [[true 'Z' false false true] [true 'R' false true true] [true 'R' true false true]] {
    if (owner_decision ($row | get 0) ($row | get 1) ($row | get 2) ($row | get 3) ($row | get 4)) != 'WAIT_ABSENT' {
        error make {msg: 'exited or mismatched owner was incorrectly signallable'}
    }
}
for row in [[false 'R' true true true] [true 'R' true true false] [false 'Z' false false true]] {
    if (owner_decision ($row | get 0) ($row | get 1) ($row | get 2) ($row | get 3) ($row | get 4)) != 'HOLD' {
        error make {msg: 'changed generation or unreadable owner was admitted'}
    }
}
if (prior_firecracker_decision 1) != 'CLEAR' { error make {msg: 'no prior process was not admitted'} }
for exit_code in [0 2] {
    if (prior_firecracker_decision $exit_code) != 'HOLD' { error make {msg: 'live or unknown prior Firecracker was not held'} }
}
for bad in [[false true true] [true false true] [false false true]] {
    if (cleanup_decision ($bad | get 0) ($bad | get 1) ($bad | get 2)) != 'REFUSE' {
        error make {msg: 'changed PID generation or argv was eligible for signal'}
    }
}
if (read_decision false false false) != 'GONE' { error make {msg: 'vanished PID should be ignored'} }
if (read_decision true true true) != 'INSPECT' { error make {msg: 'readable present PID should be inspected'} }
for bad in [[true false false] [true true false] [true false true]] {
    if (read_decision ($bad | get 0) ($bad | get 1) ($bad | get 2)) != 'HOLD' {
        error make {msg: 'unreadable but present Firecracker PID was omitted from cleanup scan'}
    }
}
print 'synthetic source-only Firecracker owner policy PASS'
