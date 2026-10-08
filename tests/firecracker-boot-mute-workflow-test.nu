#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Static selector and late-verdict checks; no workflow is dispatched.
let workflow = ($env.CURRENT_FILE | path dirname | path dirname | path join '.github' 'workflows' 'smolfire.yml')
let parsed = (open $workflow)
let steps = $parsed.jobs.smolfire.steps
let selector = "github.event_name == 'workflow_dispatch' && inputs.boot_mute_control && startsWith(github.ref, 'refs/heads/exp/boot-mute-')"
if $parsed.on.workflow_dispatch.inputs.boot_mute_control.default != false { error make {msg: 'manual diagnostic input defaults on'} }
let install = ($steps | where {|x| ($x.name? | default '') == 'Install Nushell for hosted gates'} | first)
let diagnostic = ($steps | where {|x| ($x.name? | default '') == 'Firecracker boot_mute same-ELF A/B (diagnostic only)'} | first)
let teardown_upload = ($steps | where {|x| ($x.name? | default '') == 'Upload Firecracker A/B teardown receipt'} | first)
let ordinary_teardown_upload = ($steps | where {|x| ($x.name? | default '') == 'Upload ordinary Firecracker teardown receipt'} | first)
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
for selected in [$diagnostic $teardown_upload $finalizer $final_upload] {
    if not ($selected.if | str contains $selector) { error make {msg: $"selector missing on ($selected.name)"} }
}
if $install.if != '${{ !cancelled() }}' { error make {msg: 'Nushell not installed for ordinary gate cleanup'} }
if not ($teardown.run | str contains $selector) { error make {msg: 'teardown selector missing'} }
if not ($enforce.run | str contains $selector) { error make {msg: 'enforcement selector missing'} }
let prep_skip = ($ordinary.run | str index-of 'FIRECRACKER_AB_PREP=pass')
let ordinary_spawn = ($ordinary.run | str index-of 'spawn ')
if $prep_skip < 0 or $ordinary_spawn <= $prep_skip { error make {msg: 'ordinary Firecracker spawn precedes A/B prep-only exit'} }
if not ($ordinary.run | str contains $selector) { error make {msg: 'ordinary Firecracker gate lacks A/B prep-only selector'} }
if ($ordinary.run | str contains 'trap cleanup_fc') or ($ordinary.run | str contains 'kill "$(cat "$WORK/firecracker.pid")"') or ($ordinary.run | str contains 'timeout 60 expect') { error make {msg: 'ordinary Firecracker gate retained a numeric or wrapper signal path'} }
if not ($ordinary.run | str contains 'firecracker-ordinary-cleanup.nu') { error make {msg: 'ordinary gate lacks no-signal cleanup'} }
if not ($ordinary.run | str contains 'firecracker-owner.json') or not ($ordinary.run | str contains 'generation') { error make {msg: 'ordinary gate lacks spawn-time generation record'} }
for skipped in [$network $boot_time $shell_gate $qemu $tslog] {
    if not ($skipped.if | str contains $selector) or not ($skipped.if | str contains '!(') { error make {msg: $"ordinary gate ($skipped.name) still runs for A/B diagnostic"} }
}
if not ($record.run | str contains $selector) or not ($record.run | str contains 'if [') or not ($record.run | str contains 'firecracker_boot_mute_control=') { error make {msg: 'A/B gate results may admit skipped ordinary gates'} }
if not ($teardown.run | str contains $selector) or not ($teardown.run | str contains 'selector-skipped') { error make {msg: 'A/B teardown may enter ordinary QEMU path'} }
if ($teardown.run | str contains 'kill "$(cat "$WORK/firecracker.pid")"') or not ($teardown.run | str contains 'firecracker-ordinary-cleanup.nu') { error make {msg: 'ordinary always teardown retained numeric PID kill or lost no-signal cleanup'} }
if not ($record.run | str contains 'firecracker_trace=') { error make {msg: 'ordinary cleanup failure can be omitted from enforcement'} }
if not ($finalizer.if | str contains "steps.teardown_vm.outcome == 'success'") or not ($finalizer.if | str contains "steps.firecracker_boot_mute_teardown_upload.outcome == 'success'") { error make {msg: 'finalizer can run before successful teardown/upload'} }
if not ($enforce.run | str contains 'steps.firecracker_boot_mute_final.outcome') { error make {msg: 'finalizer outcome not enforced'} }
let names = ($steps | each {|x| $x.name? | default ''})
let index = {|name| $names | enumerate | where item == $name | first | get index}
if (do $index 'Firecracker boot_mute same-ELF A/B (diagnostic only)') >= (do $index 'Upload artifacts') { error make {msg: 'raw artifacts upload precedes diagnostic'} }
if (do $index 'Install Nushell for hosted gates') >= (do $index 'Firecracker boot trace') { error make {msg: 'ordinary gate starts before pinned Nushell is installed'} }
if (do $index 'Upload artifacts') >= (do $index 'Teardown VM') { error make {msg: 'raw artifacts upload must precede teardown'} }
if (do $index 'Teardown VM') >= (do $index 'Upload Firecracker A/B teardown receipt') { error make {msg: 'late receipt upload precedes teardown'} }
if (do $index 'Teardown VM') >= (do $index 'Upload ordinary Firecracker teardown receipt') { error make {msg: 'ordinary late receipt upload precedes teardown'} }
if not ($enforce.run | str contains 'steps.ordinary_firecracker_teardown_upload.outcome') { error make {msg: 'ordinary late receipt upload outcome not enforced'} }
let build = ($steps | where {|x| ($x.name? | default '') == 'Boot FreeBSD build VM (KVM)'} | first)
let hosted_qemu_upload = ($steps | where {|x| ($x.name? | default '') == 'Upload hosted QEMU teardown receipts'} | first)
if not ($build.run | str contains 'hosted-qemu-owner.nu" --mode build --capture') { error make {msg: 'build VM owner is not captured after launch'} }
let seed = ($steps | where {|x| ($x.name? | default '') == 'Create cloud-init NoCloud seed (root SSH key)'} | first)
if not ($seed.run | str contains 'ssh_keys:') or not ($seed.run | str contains 'ed25519_private:') or not ($seed.run | str contains 'known_hosts') { error make {msg: 'guest host key was not pinned from seed'} }
if ($build.run | str contains 'StrictHostKeyChecking=no') or not ($build.run | str contains 'StrictHostKeyChecking=yes') { error make {msg: 'build VM first SSH did not verify pinned host identity'} }
let vm_build = ($steps | where {|x| ($x.name? | default '') == 'Build SMOLFIRE kernel inside VM'} | first)
if ($vm_build.run | str contains 'StrictHostKeyChecking=no') or not ($vm_build.run | str contains 'StrictHostKeyChecking=yes') { error make {msg: 'build commands did not verify pinned host identity'} }
if not ($qemu.run | str contains 'hosted-qemu-owner.nu --mode microvm --capture') or not ($qemu.run | str contains '--mode microvm --cleanup') { error make {msg: 'ordinary QEMU gate lacks ownership and natural-exit reconciliation'} }
if ($qemu.run | str contains 'timeout 60 expect') or ($teardown.run | str contains 'kill "$(cat "$WORK/qemu-microvm.pid")"') or ($teardown.run | str contains 'kill "$(cat "$WORK/vm.pid")"') { error make {msg: 'automatic workflow retained numeric or wrapper signal path'} }
if not ($teardown.run | str contains '--mode build --cleanup') or not ($teardown.run | str contains '--mode microvm --cleanup') { error make {msg: 'QEMU late teardown missing'} }
if not ($parsed.jobs.smolfire.services.token-http.image | str starts-with 'nginx@sha256:') or ($teardown.run | str contains 'httpd.pid') { error make {msg: 'token server is not runner-managed'} }
let service = $parsed.jobs.smolfire.services.token-http
if (($service.ports.0 | into string) != '8080:80') or $service.volumes.0 != '/mnt/smolfire-ci/www:/usr/share/nginx/html:ro' { error make {msg: 'hosted HTTP mount or port differs from guest fetch contract'} }
if not ($ordinary.run | str contains '"$WORK/www/token.txt"') or not ($ordinary.run | str contains '[ "$HTTP_TOKEN" = "$TOK" ]') or not ($ordinary.run | str contains 'http://172.16.0.1:8080/token.txt') { error make {msg: 'ordinary gate does not prove TAP token content from mount'} }
if not ($qemu.run | str contains 'http://10.0.2.2:8080/token.txt') { error make {msg: 'QEMU SLIRP fetch URL does not map to hosted service port'} }
if $hosted_qemu_upload.if != 'always()' or not ($hosted_qemu_upload.with.path | str contains 'vm-workflow-cleanup.json') { error make {msg: 'QEMU late cleanup receipt not uploaded'} }
if not ($enforce.run | str contains 'steps.hosted_qemu_teardown_upload.outcome') { error make {msg: 'QEMU late receipt upload outcome not enforced'} }
if (do $index 'Teardown VM') >= (do $index 'Upload hosted QEMU teardown receipts') { error make {msg: 'QEMU late receipt upload precedes teardown'} }
if (do $index 'Upload Firecracker A/B teardown receipt') >= (do $index 'Finalize Firecracker A/B after teardown') { error make {msg: 'final verdict precedes late upload'} }
print 'synthetic source-only workflow selector/order PASS: PR and push cannot request branch-only diagnostic'
