#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Synthetic filesystem and policy fixtures only; no VM or process operation.
use hosted-qemu-owner.nu [wait_decision matching_marker_pids owner_identity_decision ssh_target_decision ssh_known_hosts_option]

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
let route_owner = ($owner | upsert argv (['qemu-system-x86_64' '-pidfile' '/mnt/smolfire-ci/vm.pid' '-nic' 'user,model=virtio-net-pci,hostfwd=tcp::2253-:22']))
let guest_host_pub = 'ssh-ed25519 AAAAfixturekey ephemeral'
let guest_known = '[127.0.0.1]:2253 ssh-ed25519 AAAAfixturekey'
require ((ssh_target_decision $route_owner '2253' $guest_known $guest_host_pub) == 'MATCH') 'pinned guest route rejected'
require ((ssh_target_decision $route_owner '2254' $guest_known $guest_host_pub) == 'HOLD') 'changed port accepted'
require ((ssh_target_decision $route_owner '2253' '[127.0.0.1]:2253 ssh-ed25519 OTHER' $guest_host_pub) == 'HOLD') 'wrong host key accepted'
require ((ssh_target_decision ($route_owner | upsert argv ['qemu-system-x86_64' '-nic' 'user']) '2253' $guest_known $guest_host_pub) == 'HOLD') 'missing QEMU hostfwd accepted'
require ((ssh_known_hosts_option '/mnt/smolfire-ci/known_hosts') == 'UserKnownHostsFile=/mnt/smolfire-ci/known_hosts') 'known_hosts option kept a literal Nushell variable'
require ((try { ssh_known_hosts_option 'relative/known_hosts'; false } catch { true })) 'relative known_hosts path was accepted'

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
let first_owner_check = ($source | str index-of "require ((owner_identity_decision $first $owner) == 'MATCH')")
let pinned_route_check = ($source | str index-of 'ssh_target_decision $owner $port $known $public')
let guest_command = ($source | str index-of "let command = (^ssh")
let shutdown_required = ($source | str index-of 'require ($shutdown_rc == 0)')
require ($first_owner_check >= 0 and $pinned_route_check > $first_owner_check and $guest_command > $pinned_route_check and $shutdown_required > $guest_command) 'guest shutdown moved before exact owner/route/key check or its result became optional'
require (not ($source | str contains 'UserKnownHostsFile=$known_path')) 'literal Nushell option regression'
require (($source | str contains '-o $known_option') and ($source | str contains "'vm-shutdown-attempt.json'")) 'rendered SSH option or failed-attempt receipt missing'
for forbidden in ['^kill ' 'exec kill ' 'pkill ' 'kill -TERM' 'kill -KILL' 'timeout 60 expect'] {
    require (not ($source | str contains $forbidden)) $"QEMU owner helper regained unsafe signal path: ($forbidden)"
}
print 'synthetic hosted QEMU no-signal ownership policy PASS'
