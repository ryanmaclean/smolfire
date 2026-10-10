#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Pure source policy checks: no process is launched, waited, or signaled.
use firecracker-ordinary-cleanup.nu wait_decision

if (wait_decision false true true false) != 'EXITED' { error make {msg: 'absent PID was not recognized'} }
if (wait_decision true true true false) != 'WAIT' { error make {msg: 'readable same-generation PID did not wait naturally'} }
for row in [[true false true false] [true true false false] [true true true true]] {
    if (wait_decision ($row | get 0) ($row | get 1) ($row | get 2) ($row | get 3)) != 'HOLD' {
        error make {msg: 'reused PID, unreadable state, or bounded-wait expiry was accepted'}
    }
}
let source_text = (open --raw ($env.CURRENT_FILE | path dirname | path join 'firecracker-ordinary-cleanup.nu'))
if ($source_text | str contains '^kill ') or ($source_text | str contains 'exec kill ') or ($source_text | str contains '--signal=TERM') {
    error make {msg: 'ordinary cleanup regained a signal path'}
}
print 'synthetic ordinary Firecracker no-signal cleanup policy PASS'
