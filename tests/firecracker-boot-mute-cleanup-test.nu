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
for state in ['R' 'Z' 'X'] {
    if (owner_decision true $state true) != 'WAIT_ABSENT' { error make {msg: 'readable same-generation owner did not enter natural-exit wait'} }
}
for row in [[false 'R' true] [true 'R' false] [true '' true] [false 'Z' true]] {
    if (owner_decision ($row | get 0) ($row | get 1) ($row | get 2)) != 'HOLD' { error make {msg: 'changed generation or unreadable owner was admitted'} }
}
let owner = {generation: '12', state: 'R', exe: '/mnt/smolfire-ci/firecracker', argv: $exact}
if (owner_identity_decision $owner $owner) != 'WAIT_ABSENT' { error make {msg: 'exact live owner refused natural-exit wait'} }
for changed in [($owner | upsert generation '13') ($owner | upsert exe '/foreign/firecracker') ($owner | upsert argv ($exact | append '--drive' 'foreign.img'))] {
    if (owner_identity_decision $changed $owner) != 'HOLD' { error make {msg: 'changed generation, executable, or argv was accepted for cleanup'} }
}
if (owner_identity_decision ($owner | upsert state 'Z' | upsert argv []) $owner) != 'WAIT_ABSENT' { error make {msg: 'same-generation zombie cannot be observed to disappear'} }
if (prior_firecracker_decision 1) != 'CLEAR' { error make {msg: 'no prior process was not admitted'} }
for exit_code in [0 2] {
    if (prior_firecracker_decision $exit_code) != 'HOLD' { error make {msg: 'live or unknown prior Firecracker was not held'} }
}
let source_text = (open --raw ($env.CURRENT_FILE | path dirname | path join 'firecracker-boot-mute-pairs.nu'))
if ($source_text | str contains '^kill ') or ($source_text | str contains 'exec kill ') or ($source_text | str contains '--signal=TERM') or ($source_text | str contains 'pkill ') { error make {msg: 'diagnostic runner regained a signal-based cleanup path'} }
if not ($source_text | str contains 'global_firecracker_clear') { error make {msg: 'diagnostic cleanup lost global TAP-owner scan'} }
if (read_decision false false false) != 'GONE' { error make {msg: 'vanished PID should be ignored'} }
if (read_decision true true true) != 'INSPECT' { error make {msg: 'readable present PID should be inspected'} }
for bad in [[true false false] [true true false] [true false true]] {
    if (read_decision ($bad | get 0) ($bad | get 1) ($bad | get 2)) != 'HOLD' {
        error make {msg: 'unreadable but present Firecracker PID was omitted from cleanup scan'}
    }
}
let fixture = (($env.TMPDIR? | default '/tmp') | path join $"fc-ab-cleanup-fixture-(random uuid)")
let result = ($fixture | path join 'firecracker-boot-mute')
mkdir $result
'foreign-tag' | save --raw ($result | path join 'current-tag')
let malformed = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($env.CURRENT_FILE | path dirname | path join 'firecracker-boot-mute-pairs.nu') --cleanup-only --work $fixture | complete })
if $malformed.exit_code == 0 or ($malformed.stdout | from json).state != 'hold-unresolved' { error make {msg: 'malformed A/B journal failed without a structured late HOLD receipt'} }
rm --recursive $fixture
print 'synthetic source-only Firecracker owner policy PASS'
