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
let verify_call = ($source_text | str index-of 'exec nu $env(FC_AB_HELPER) --verify-current')
let reboot_send = ($source_text | str index-of 'send -- "reboot\r"')
let eof_gate = ($source_text | str index-of 'CONSOLE_EOF=after_reboot')
if $verify_call < 0 or $reboot_send <= $verify_call or $eof_gate <= $reboot_send { error make {msg: 'attached-console reboot lost exact owner-before-send or EOF order'} }
let verify_panic = ($source_text | str index-of 'if {$rc == 0 && $env(FC_AB_MODE) == "panic"}')
let debugger_off = ($source_text | str index-of 'send -- "sysctl debug.debugger_on_panic=0\r"')
let debugger_readback = ($source_text | str index-of 'PANIC_DEBUGGER_READBACK=0')
let panic_trigger = ($source_text | str index-of 'send -- "sysctl debug.kdb.panic=1\r"')
let panic_eof = ($source_text | str index-of 'CONSOLE_EOF=after_panic')
if $verify_panic < 0 or $debugger_off <= $verify_panic or $debugger_readback <= $debugger_off or $panic_trigger <= $debugger_readback or $panic_eof <= $panic_trigger { error make {msg: 'panic-control lost verified debugger disarm or bounded EOF order'} }
if not ($source_text | str contains "($mode == 'panic') and ($tag == 'panic-control')") { error make {msg: 'panic-control owner verification lost exact mode/tag binding'} }
if not ($source_text | str contains "state: 'hold-per-boot'") or not ($source_text | str contains "'hold-sticky.json'") { error make {msg: 'per-boot cleanup HOLD cannot be retained through late cleanup'} }
if (retention_decision true false) != 'CLEAR' or (retention_decision true true) != 'HOLD' or (retention_decision false false) != 'HOLD' { error make {msg: 'late retention decision admitted unresolved or sticky owner'} }
let no_owner = {state: 'no-owner', forced: false, matching_config_pids: [], global_firecracker_pids: []}
if (late_receipt $no_owner '/tmp/hold-sticky.json' true).state != 'hold-prior-per-boot' or (late_receipt $no_owner '/tmp/hold-sticky.json' false).state != 'no-owner' { error make {msg: 'late receipt obscures an earlier per-boot HOLD'} }
let workflow = (open --raw ($env.CURRENT_FILE | path dirname | path join '..' '.github' 'workflows' 'smolfire.yml'))
if not ($workflow | str contains '[ "$FC_AB_CLEANUP_FAIL" != 0 ]') or not ($workflow | str contains 'steps.firecracker_boot_mute_control.outcome') or not ($workflow | str contains 'firecracker-boot-mute/hold-sticky.json') { error make {msg: 'A/B teardown can delete TAP after owner HOLD or lose sticky receipt'} }
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
let foreign_verify = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($env.CURRENT_FILE | path dirname | path join 'firecracker-boot-mute-pairs.nu') --verify-current --work $fixture --tag panic-control --mode release | complete })
if $foreign_verify.exit_code == 0 { error make {msg: 'panic-control tag was admitted to normal reboot owner verification'} }
let missing_verify = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($env.CURRENT_FILE | path dirname | path join 'firecracker-boot-mute-pairs.nu') --verify-current --work $fixture --tag release-1-off | complete })
if $missing_verify.exit_code == 0 { error make {msg: 'missing current-tag was admitted to normal reboot owner verification'} }
let missing_panic_owner = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($env.CURRENT_FILE | path dirname | path join 'firecracker-boot-mute-pairs.nu') --verify-current --work $fixture --tag panic-control --mode panic | complete })
if $missing_panic_owner.exit_code == 0 { error make {msg: 'panic command admitted without current tag and exact owner'} }
rm --recursive $fixture
print 'synthetic source-only Firecracker owner policy PASS'
