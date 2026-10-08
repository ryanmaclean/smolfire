#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Synthetic filesystem and policy fixtures only; no VM or process operation.
use hosted-qemu-owner.nu [wait_decision matching_marker_pids owner_identity_decision]

def require [ok: bool, reason: string] { if not $ok { error make {msg: $reason} } }

require ((wait_decision false true true false) == 'EXITED') 'absent PID was not classified exited'
require ((wait_decision true true true false) == 'WAIT') 'same-generation readable PID did not wait'
for row in [[true false true false] [true true false false] [true true true true]] {
    require ((wait_decision ($row | get 0) ($row | get 1) ($row | get 2) ($row | get 3)) == 'HOLD') 'reused, unreadable, or persistent PID was accepted'
}
let owner = {generation: '111', exe: '/usr/bin/qemu-system-x86_64', argv: ['qemu-system-x86_64' '-pidfile' '/mnt/smolfire-ci/vm.pid']}
let observed = {generation: '111', state: 'S', exe: '/usr/bin/qemu-system-x86_64', argv: ['qemu-system-x86_64' '-pidfile' '/mnt/smolfire-ci/vm.pid']}
require ((owner_identity_decision $observed $owner) == 'MATCH') 'exact QEMU owner rejected'
require ((owner_identity_decision ($observed | upsert generation '222') $owner) == 'HOLD') 'reused PID was accepted'
require ((owner_identity_decision ($observed | upsert argv (['qemu-system-x86_64' '-pidfile' '/mnt/smolfire-ci/vm.pid' '-drive' 'file=/other.qcow2'])) $owner) == 'HOLD') 'extra argv was accepted'
require ((owner_identity_decision ($observed | upsert exe '/bin/other') $owner) == 'HOLD') 'changed executable was accepted'

let fixture = (($env.TMPDIR? | default '/tmp') | path join $"smolfire-qemu-owner-fixture-(random uuid)")
mkdir ($fixture | path join '123')
let marker = '/mnt/smolfire-ci/smolfire-kernel'
'qemu-system-x86' | save --raw ($fixture | path join '123' 'comm')
(['qemu-system-x86_64' '-kernel' $marker] | str join (char nul)) | save --raw ($fixture | path join '123' 'cmdline')
require ((matching_marker_pids $marker $fixture) == ['123']) 'exact-marker match was missed'
require ((matching_marker_pids '/other/kernel' $fixture | is-empty)) 'unrelated marker was matched'
rm ($fixture | path join '123' 'comm')
let unreadable = (try { matching_marker_pids $marker $fixture; false } catch { true })
require $unreadable 'unreadable process metadata was accepted'
rm -r $fixture

let source = (open --raw ($env.CURRENT_FILE | path dirname | path join 'hosted-qemu-owner.nu'))
for forbidden in ['^kill ' 'exec kill ' 'pkill ' 'kill -TERM' 'kill -KILL' 'timeout 60 expect'] {
    require (not ($source | str contains $forbidden)) $"QEMU owner helper regained unsafe signal path: ($forbidden)"
}
print 'synthetic hosted QEMU no-signal ownership policy PASS'
