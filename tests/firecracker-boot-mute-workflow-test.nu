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
for selected in [$install $diagnostic $teardown_upload $finalizer $final_upload] {
    if not ($selected.if | str contains $selector) { error make {msg: $"selector missing on ($selected.name)"} }
}
if not ($teardown.run | str contains $selector) { error make {msg: 'teardown selector missing'} }
if not ($enforce.run | str contains $selector) { error make {msg: 'enforcement selector missing'} }
if not ($finalizer.if | str contains "steps.teardown_vm.outcome == 'success'") or not ($finalizer.if | str contains "steps.firecracker_boot_mute_teardown_upload.outcome == 'success'") { error make {msg: 'finalizer can run before successful teardown/upload'} }
if not ($enforce.run | str contains 'steps.firecracker_boot_mute_final.outcome') { error make {msg: 'finalizer outcome not enforced'} }
let names = ($steps | each {|x| $x.name? | default ''})
let index = {|name| $names | enumerate | where item == $name | first | get index}
if (do $index 'Firecracker boot_mute same-ELF A/B (diagnostic only)') >= (do $index 'Upload artifacts') { error make {msg: 'raw artifacts upload precedes diagnostic'} }
if (do $index 'Upload artifacts') >= (do $index 'Teardown VM') { error make {msg: 'raw artifacts upload must precede teardown'} }
if (do $index 'Teardown VM') >= (do $index 'Upload Firecracker A/B teardown receipt') { error make {msg: 'late receipt upload precedes teardown'} }
if (do $index 'Upload Firecracker A/B teardown receipt') >= (do $index 'Finalize Firecracker A/B after teardown') { error make {msg: 'final verdict precedes late upload'} }
print 'synthetic source-only workflow selector/order PASS: PR and push cannot request branch-only diagnostic'
