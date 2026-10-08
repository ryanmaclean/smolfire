#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source-only cleanup policy fixture. No process is started or signaled.
source cpuid-pair.nu

let work = '/tmp/smolfire-source-only-fixture'
let release = ($work | path join 'smolfire-kernel')
let tslog = ($work | path join 'smolfire-kernel-tslog')
let pidfile = ($work | path join 'cpuid-control' 'current-qemu.pid')
let control = (qemu_argv $work $release 'off')
if not (matches_qemu_argv $control 'control' $pidfile $release $tslog) {
    error make {msg: 'exact diagnostic QEMU command was refused'}
}
for extra in [['-drive' 'file=foreign.img'] ['-device' 'foreign-device']] {
    if (matches_qemu_argv ($control | append $extra) 'control' $pidfile $release $tslog) {
        error make {msg: 'diagnostic QEMU with extra drive/device was accepted for cleanup'}
    }
}
let foreign_append = ($control | update 12 'extra=foreign')
if (matches_qemu_argv $foreign_append 'control' $pidfile $release $tslog) {
    error make {msg: 'diagnostic QEMU with changed append arguments was accepted for cleanup'}
}
let prior = (prior_qemu_argv $release)
if not (matches_qemu_argv $prior 'prior' ($work | path join 'qemu-microvm.pid') $release $tslog) {
    error make {msg: 'exact stock QEMU command was refused'}
}
if (matches_qemu_argv ($prior | append '-drive' 'file=foreign.img') 'prior' ($work | path join 'qemu-microvm.pid') $release $tslog) {
    error make {msg: 'stock QEMU with extra drive was accepted for cleanup'}
}

if (cleanup_decision true true false) != 'WAIT' {
    error make {msg: 'live exact QEMU must get the bounded TERM grace period'}
}
if (cleanup_decision true true true) != 'KILL' {
    error make {msg: 'TERM-resistant exact QEMU was not escalated to KILL'}
}
for case in [[false true true] [true false true] [false false true]] {
    if (cleanup_decision ($case | get 0) ($case | get 1) ($case | get 2)) != 'REFUSE' {
        error make {msg: 'changed generation or foreign argv was allowed to receive KILL'}
    }
}
print 'source-only cleanup policy PASS: exact argv admits; extra drive/device/append refuses; TERM-resistant exact owner escalates; changed identity refuses'
