#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Static selector and late-verdict checks; no workflow is dispatched.
let workflow = ($env.CURRENT_FILE | path dirname | path dirname | path join '.github' 'workflows' 'smolfire.yml')
let parsed = (open $workflow)
let steps = $parsed.jobs.smolfire.steps
let selector = "github.event_name == 'workflow_dispatch' && inputs.boot_mute_control && startsWith(github.ref, 'refs/heads/exp/boot-mute-')"
if $parsed.on.workflow_dispatch.inputs.boot_mute_control.default != false { error make {msg: 'manual diagnostic input defaults on'} }
let install = ($steps | where {|x| ($x.name? | default '') == 'Install Nushell for branch-only diagnostics'} | first)
let diagnostic = ($steps | where {|x| ($x.name? | default '') == 'Firecracker boot_mute same-ELF A/B (diagnostic only)'} | first)
let teardown_upload = ($steps | where {|x| ($x.name? | default '') == 'Upload Firecracker A/B teardown receipt'} | first)
let finalizer = ($steps | where {|x| ($x.name? | default '') == 'Finalize Firecracker A/B after teardown'} | first)
let final_upload = ($steps | where {|x| ($x.name? | default '') == 'Upload Firecracker A/B final verdict'} | first)
let teardown = ($steps | where {|x| ($x.name? | default '') == 'Teardown VM'} | first)
let enforce = ($steps | where {|x| ($x.name? | default '') == 'Enforce microVM gates'} | first)
let ordinary = ($steps | where {|x| ($x.name? | default '') == 'Firecracker boot trace'} | first)
let network = ($steps | where {|x| ($x.name? | default '') == 'Firecracker network gate'} | first)
let boot_time = ($steps | where {|x| ($x.name? | default '') == 'Firecracker boot-time gate'} | first)
let shell_gate = ($steps | where {|x| ($x.name? | default '') == 'Firecracker shell gate'} | first)
let qemu = ($steps | where {|x| ($x.name? | default '') == 'QEMU microvm gate'} | first)
let tslog = ($steps | where {|x| ($x.name? | default '') | str starts-with 'TSLOG capture'} | first)
let record = ($steps | where {|x| ($x.name? | default '') == 'Record microVM gate results'} | first)
for selected in [$install $diagnostic $teardown_upload $finalizer $final_upload] {
    if not ($selected.if | str contains $selector) { error make {msg: $"selector missing on ($selected.name)"} }
}
if not ($teardown.run | str contains $selector) { error make {msg: 'teardown selector missing'} }
if not ($enforce.run | str contains $selector) { error make {msg: 'enforcement selector missing'} }
let prep_skip = ($ordinary.run | str index-of 'FIRECRACKER_AB_PREP=pass')
let ordinary_trap = ($ordinary.run | str index-of 'trap cleanup_fc EXIT')
if $prep_skip < 0 or $ordinary_trap <= $prep_skip { error make {msg: 'ordinary numeric-PID cleanup precedes A/B prep-only exit'} }
if not ($ordinary.run | str contains $selector) { error make {msg: 'ordinary Firecracker gate lacks A/B prep-only selector'} }
for skipped in [$network $boot_time $shell_gate $qemu $tslog] {
    if not ($skipped.if | str contains $selector) or not ($skipped.if | str contains '!(') { error make {msg: $"ordinary gate ($skipped.name) still runs for A/B diagnostic"} }
}
if not ($record.run | str contains $selector) or not ($record.run | str contains 'if [') or not ($record.run | str contains 'firecracker_boot_mute_control=') { error make {msg: 'A/B gate results may admit skipped ordinary gates'} }
if not ($teardown.run | str contains $selector) or not ($teardown.run | str contains 'qemu-microvm.pid') { error make {msg: 'A/B teardown may signal ordinary QEMU PID'} }
if not ($finalizer.if | str contains "steps.teardown_vm.outcome == 'success'") or not ($finalizer.if | str contains "steps.firecracker_boot_mute_teardown_upload.outcome == 'success'") { error make {msg: 'finalizer can run before successful teardown/upload'} }
if not ($enforce.run | str contains 'steps.firecracker_boot_mute_final.outcome') { error make {msg: 'finalizer outcome not enforced'} }
let names = ($steps | each {|x| $x.name? | default ''})
let index = {|name| $names | enumerate | where item == $name | first | get index}
if (do $index 'Firecracker boot_mute same-ELF A/B (diagnostic only)') >= (do $index 'Upload artifacts') { error make {msg: 'raw artifacts upload precedes diagnostic'} }
if (do $index 'Upload artifacts') >= (do $index 'Teardown VM') { error make {msg: 'raw artifacts upload must precede teardown'} }
if (do $index 'Teardown VM') >= (do $index 'Upload Firecracker A/B teardown receipt') { error make {msg: 'late receipt upload precedes teardown'} }
if (do $index 'Upload Firecracker A/B teardown receipt') >= (do $index 'Finalize Firecracker A/B after teardown') { error make {msg: 'final verdict precedes late upload'} }
print 'synthetic source-only workflow selector/order PASS: PR and push cannot request branch-only diagnostic'
