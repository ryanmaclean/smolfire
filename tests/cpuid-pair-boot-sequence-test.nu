#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Exercises the real boot control flow with first-party Nu stubs; no VM/network.
source cpuid-pair.nu

let root = (^mktemp -d | str trim)
let work = ($root | path join 'work')
let result_dir = ($work | path join 'cpuid-control')
let token_file = ($work | path join 'www' 'token.txt')
mkdir $result_dir ($work | path join 'www')
let fixture_bin = ($env.CURRENT_FILE | path dirname | path join 'fixtures' 'bin')
with-env {PATH: ($env.PATH | prepend $fixture_bin), CPUID_TOKEN_FILE: $token_file} {
    let off = (boot $work ($work | path join 'smolfire-kernel-tslog') 'off' 'probe' 'smoke-off')
    let on = (boot $work ($work | path join 'smolfire-kernel-tslog') 'on' 'probe' 'smoke-on')
    if not (($off.log | path exists) and ($on.log | path exists)) {
        error make {msg: 'successful first boot silently stopped before the second smoke boot'}
    }
    if $off.nonce == $on.nonce or not ($on.stdout | str contains $"SMOLFIRE_NET_OK ($on.nonce)") {
        error make {msg: 'fresh nonce sequence did not survive the second boot'}
    }
}
print 'source-only boot sequence PASS: both smoke boots returned through empty-stderr success paths'
