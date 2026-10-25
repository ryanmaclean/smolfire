#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# FreeBSD releng/15.0 kdb_sysctl_panic() calls panic("kdb_sysctl_panic"),
# and vpanic() prints "panic: %s\n" to the kernel console. The sysctl
# command echo contains "debug.kdb.panic:" but not this kernel panic message.
# sysctl prints the old value before the write without a newline, so a real
# kernel message can be joined to that prefix on the same serial line.
export def panic_kernel_seen [raw: string] {
    $raw
        | str replace --all "\r" "\n"
        | lines
        | any {|line|
            let clean = ($line | str trim)
            ($clean == 'panic: kdb_sysctl_panic') or ($clean =~ '^debug[.]kdb[.]panic: *[0-9]*panic: kdb_sysctl_panic$')
        }
}
