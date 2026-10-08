#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Pure ownership decision fixture: no process is started or signaled.
source firecracker-boot-mute-pairs.nu

let work = '/mnt/smolfire-ci'
let cfg = '/mnt/smolfire-ci/firecracker-boot-mute/release-1-off-config.json'
let exact = (argv $work $cfg)
if $exact != ['/mnt/smolfire-ci/firecracker' '--no-api' '--config-file' $cfg] {
    error make {msg: 'exact Firecracker argv changed'}
}
if (cleanup_decision true true false) != 'WAIT' { error make {msg: 'exact owner must receive bounded TERM wait'} }
if (cleanup_decision true true true) != 'KILL' { error make {msg: 'TERM-resistant exact owner must escalate to KILL'} }
for bad in [[false true true] [true false true] [false false true]] {
    if (cleanup_decision ($bad | get 0) ($bad | get 1) ($bad | get 2)) != 'REFUSE' {
        error make {msg: 'changed PID generation or argv was eligible for signal'}
    }
}
print 'synthetic source-only Firecracker owner policy PASS'
