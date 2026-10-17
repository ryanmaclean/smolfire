#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# No guest, VM, or process signal. Synthetic owner/exit and workflow fixtures.
use firecracker-exit-witness.nu [identity_decision exit_decision]

let root = ($env.CURRENT_FILE | path dirname | path dirname)
let owner = {pid: '41', generation: '121', state: 'R', exe: '/mnt/smolfire-ci/firecracker', argv: ['/mnt/smolfire-ci/firecracker' '--no-api' '--config-file' '/mnt/smolfire-ci/firecracker-exit-witness/one-boot-config.json']}
if (identity_decision $owner $owner) != 'WAIT_ABSENT' { error make {msg: 'exact owner not admitted to bounded natural-exit wait'} }
for changed in [($owner | upsert generation '122') ($owner | upsert exe '/foreign/firecracker') ($owner | upsert argv ($owner.argv | append '-drive' 'foreign.img'))] {
    if (identity_decision $changed $owner) != 'HOLD' { error make {msg: 'changed generation/executable/full argv accepted'} }
}
if (identity_decision ($owner | upsert state 'Z' | upsert argv []) $owner) != 'WAIT_ABSENT' { error make {msg: 'same-generation zombie cannot be observed until disappearance'} }
if (exit_decision true true true true true) != 'EXIT_OBSERVED' { error make {msg: 'complete witness refused'} }
for missing in [[false true true true true] [true false true true true] [true true false true true] [true true true false true] [true true true true false]] {
    if (exit_decision ($missing | get 0) ($missing | get 1) ($missing | get 2) ($missing | get 3) ($missing | get 4)) != 'HOLD' { error make {msg: 'console EOF alone, missing reboot, persistent owner, or nonempty scan accepted'} }
}

let runner = (open --raw ($root | path join 'tests' 'firecracker-exit-witness.nu'))
for forbidden in ['^kill ' 'pkill ' 'killall ' '--signal=TERM' 'timeout 60 expect'] {
    if ($runner | str contains $forbidden) { error make {msg: $"probe regained signaling or wrapper timeout: ($forbidden)"} }
}
if (($runner | split row 'spawn $env(FC_EXIT_BINARY)') | length) != 2 { error make {msg: 'probe source does not have exactly one Firecracker spawn'} }
let wf = (open ($root | path join '.github' 'workflows' 'smolfire.yml'))
let steps = $wf.jobs.smolfire.steps
let get_step = {|name| $steps | where {|s| ($s.name? | default '') == $name} | first}
let probe = (do $get_step 'Firecracker FreeBSD reboot exit witness (one boot only)')
let trace = (do $get_step 'Firecracker boot trace')
let qemu = (do $get_step 'QEMU microvm gate')
let record = (do $get_step 'Record microVM gate results')
let teardown = (do $get_step 'Teardown VM')
let late = (do $get_step 'Upload Firecracker exit witness teardown receipt')
let enforce = (do $get_step 'Enforce microVM gates')
let final_upload = (do $get_step 'Upload Firecracker exit witness final verdict')
let selector = "github.event_name == 'workflow_dispatch' && inputs.exit_probe && startsWith(github.ref, 'refs/heads/exp/fc-exit-')"
if $wf.on.workflow_dispatch.inputs.exit_probe.default != false or not ($probe.if | str contains $selector) or not ($probe.if | str contains '!inputs.tslog') or not ($probe.if | str contains '!inputs.boot_mute_control') { error make {msg: 'one-boot probe selector can run automatically or overlap other manual modes'} }
if not ($trace.run | str contains $selector) or not ($qemu.if | str contains $selector) or not ($record.run | str contains $selector) or not ($teardown.run | str contains $selector) or not ($enforce.run | str contains $selector) { error make {msg: 'ordinary gate, QEMU, record, teardown or enforcement missed probe selector'} }
if not ($probe.run | str contains 'firecracker-exit-witness.nu --execute') or not ($teardown.run | str contains 'firecracker-exit-witness.nu --cleanup-only') { error make {msg: 'one-boot runner or always cleanup missing'} }
if not ($teardown.run | str contains 'EXIT_PROBE_CLEANUP_FAIL" != 0') or not ($teardown.run | str contains 'retain TAP for runner-level inspection') { error make {msg: 'failed owner reconciliation still tears down TAP before evidence review'} }
if $late.with.if-no-files-found != 'error' or not ($late.with.path | str contains 'workflow-cleanup.json') or $final_upload.with.if-no-files-found != 'error' { error make {msg: 'late cleanup or final verdict artifact optional'} }
if not ($enforce.run | str contains 'firecracker-exit-witness-finalize.nu') or not ($enforce.run | str contains 'steps.exit_probe_teardown_upload.outcome') { error make {msg: 'late finalizer or upload not enforced'} }
let finalizer_pos = ($enforce.run | str index-of 'nu tests/firecracker-exit-witness-finalize.nu')
let gate_fail_pos = ($enforce.run | str index-of 'test "$gate_fail" = 0')
if $finalizer_pos < 0 or $gate_fail_pos < 0 or $finalizer_pos >= $gate_fail_pos { error make {msg: 'failed early probe could skip final HOLD receipt'} }

let fixture = (($env.TMPDIR? | default '/tmp') | path join $"fc-exit-fixture-(random uuid)")
let dir = ($fixture | path join 'firecracker-exit-witness')
mkdir $dir
{config: '/foreign/config.json', argv: $owner.argv} | to json --raw | save --raw ($dir | path join 'intent.json')
let bad = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($root | path join 'tests' 'firecracker-exit-witness.nu') --cleanup-only --work $fixture | complete })
if $bad.exit_code == 0 or (open ($dir | path join 'workflow-cleanup.json')).state != 'hold-unresolved' { error make {msg: 'forged one-boot intent did not produce structured late HOLD'} }
let unattached = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($root | path join 'tests' 'firecracker-exit-witness.nu') --verify-current --work $fixture | complete })
if $unattached.exit_code == 0 { error make {msg: 'guest reboot could be sent without exact captured owner'} }
let final = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($root | path join 'tests' 'firecracker-exit-witness-finalize.nu') --work $fixture | complete })
if $final.exit_code == 0 or (open ($dir | path join 'final-verdict.json')).verdict != 'HOLD' { error make {msg: 'missing raw/owner evidence did not fail final witness'} }
rm --recursive $fixture
print 'one-boot FreeBSD exit witness source and negative fixtures PASS'
