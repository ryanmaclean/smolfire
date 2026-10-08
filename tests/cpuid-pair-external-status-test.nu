#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Pure fixture for the Nu 0.115.1 empty-stderr success-path regression.
source cpuid-pair.nu

require_external_success {exit_code: 0, stderr: ''} 'empty-stderr success'
let failed = (try {
    require_external_success {exit_code: 7, stderr: ''} 'empty-stderr failure'
    'NO_ERROR'
} catch {|err| $err.msg })
if not ($failed | str contains 'exit 7: empty stderr') {
    error make {msg: 'nonzero external status with empty stderr was not rejected'}
}
print 'external-status fixture PASS: empty stderr succeeds only for rc=0; rc=7 fails with a nonempty reason'
