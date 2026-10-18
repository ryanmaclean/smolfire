#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source-only regression: the real run3 panic log fooled the old substring gate.
use cpuid-panic-evidence.nu panic_kernel_seen

let fixture = ($env.CURRENT_FILE | path dirname | path join 'fixtures' 'panic-control-false-positive.raw')
let bad = (open --raw $fixture)
if not ($bad | str contains 'panic:') {
    error make {msg: 'negative fixture does not reproduce the old broad match'}
}
if (panic_kernel_seen $bad) {
    error make {msg: 'echo-only run3 log was falsely accepted as a kernel panic'}
}
if (panic_kernel_seen "debug.kdb.panic: kdb_sysctl_panic\r\n") {
    error make {msg: 'sysctl output was falsely accepted as kernel output'}
}
if not (panic_kernel_seen "# sysctl debug.kdb.panic=1\r\npanic: kdb_sysctl_panic\r\ncpuid = 0\r\n") {
    error make {msg: 'genuine standalone FreeBSD panic line was rejected'}
}
if not (panic_kernel_seen "debug.kdb.panic: 0panic: kdb_sysctl_panic\r\n") {
    error make {msg: 'kernel panic joined to sysctl old-value prefix was rejected'}
}

# Feed the actual bad raw log through Tcl Expect, proving the old pattern
# accepts it while the proposed kernel-specific line pattern reaches EOF.
let legacy_tcl = "set timeout 2\nspawn cat $env(PANIC_FIXTURE)\nexpect {\n  -re {panic:} { puts LEGACY_ACCEPTED; exit 0 }\n  eof { exit 1 }\n  timeout { exit 2 }\n}\n"
let exact_tcl = "set timeout 2\nspawn cat $env(PANIC_FIXTURE)\nexpect {\n  -re {(^|[\\r\\n]|debug[.]kdb[.]panic: *[0-9]*)panic: kdb_sysctl_panic([\\r\\n]|$)} { puts KERNEL_ACCEPTED; exit 0 }\n  eof { exit 1 }\n  timeout { exit 2 }\n}\n"
let legacy = (with-env {PANIC_FIXTURE: $fixture} { ^expect -c $legacy_tcl | complete })
let exact = (with-env {PANIC_FIXTURE: $fixture} { ^expect -c $exact_tcl | complete })
if $legacy.exit_code != 0 or not ($legacy.stdout | str contains 'LEGACY_ACCEPTED') {
    error make {msg: 'actual run3 raw did not reproduce the old Expect false acceptance'}
}
if $exact.exit_code != 1 or ($exact.stdout | str contains 'KERNEL_ACCEPTED') {
    error make {msg: 'kernel-specific Expect pattern accepted the echo-only raw log'}
}
let positive = (^mktemp | str trim)
"# sysctl debug.kdb.panic=1\r\ndebug.kdb.panic: 0panic: kdb_sysctl_panic\r\ncpuid = 0\r\n" | save --raw --force $positive
let actual = (with-env {PANIC_FIXTURE: $positive} { ^expect -c $exact_tcl | complete })
if $actual.exit_code != 0 or not ($actual.stdout | str contains 'KERNEL_ACCEPTED') {
    error make {msg: 'kernel-specific Expect pattern rejected a sysctl-prefixed kernel panic'}
}
print 'panic evidence fixture PASS: old Expect accepts run3 echo; exact Expect and Nu reject it; standalone and sysctl-prefixed kernel panic message accepted'
