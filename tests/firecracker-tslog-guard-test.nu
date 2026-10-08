#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source-only negative fixtures; no guest, VM, or process signal.
use firecracker-tslog-guard.nu preflight_decision

if (preflight_decision true true true true) != 'HOLD_FREEBSD_EXIT_UNPROVEN' { error make {msg: 'TSLOG prematurely enabled without FreeBSD exit witness'} }
for bad in [[false true true true] [true false true true] [true true false true] [true true true false]] {
    if (preflight_decision ($bad | get 0) ($bad | get 1) ($bad | get 2) ($bad | get 3)) != 'HOLD_OWNERSHIP' { error make {msg: 'missing owner, mismatched identity, or foreign process was not held'} }
}
let root = ($env.CURRENT_FILE | path dirname | path dirname)
let source_text = (open --raw ($root | path join 'tests' 'firecracker-tslog-guard.nu'))
for forbidden in ['pkill ' 'killall ' '^kill ' 'timeout 60 expect'] {
    if ($source_text | str contains $forbidden) { error make {msg: $"TSLOG guard contains forbidden process action: ($forbidden)"} }
}
let wf = (open ($root | path join '.github' 'workflows' 'smolfire.yml'))
let steps = $wf.jobs.smolfire.steps
let selected = ($steps | where {|s| ($s.name? | default '') | str starts-with 'TSLOG scoped-run preflight'} | first)
let teardown = ($steps | where {|s| ($s.name? | default '') == 'Teardown VM'} | first)
let upload = ($steps | where {|s| ($s.name? | default '') == 'Upload TSLOG guard teardown receipt'} | first)
let enforce = ($steps | where {|s| ($s.name? | default '') == 'Enforce microVM gates'} | first)
if not ($selected.if | str contains "github.event_name == 'workflow_dispatch'") or not ($selected.if | str contains "startsWith(github.ref, 'refs/heads/exp/cpuid-freq-')") { error make {msg: 'TSLOG selector permits automatic or unrelated dispatch'} }
if not ($selected.run | str contains 'firecracker-tslog-guard.nu --preflight') or ($selected.run | str contains 'spawn ') { error make {msg: 'TSLOG source-only preflight replaced by runnable boot'} }
if not ($teardown.run | str contains 'firecracker-tslog-guard.nu --cleanup-only') or not ($teardown.run | str contains 'test "$TSLOG_CLEANUP_FAIL" = 0') { error make {msg: 'TSLOG late cleanup not enforced'} }
if $upload.with.if-no-files-found != 'error' or not ($upload.with.path | str contains 'workflow-cleanup.json') { error make {msg: 'TSLOG late receipt not required'} }
if not ($enforce.run | str contains 'steps.tslog_capture.outcome') or not ($enforce.run | str contains 'steps.tslog_guard_teardown_upload.outcome') { error make {msg: 'TSLOG continuation can mask HOLD'} }
if (($wf | to json --raw) | str contains "pkill -f 'firecracker --no-api'") { error make {msg: 'broad Firecracker pkill remains in workflow'} }
let fixture = (($env.TMPDIR? | default '/tmp') | path join $"tslog-guard-fixture-(random uuid)")
mkdir $fixture
let missing = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($root | path join 'tests' 'firecracker-tslog-guard.nu') --preflight --work $fixture | complete })
if $missing.exit_code == 0 or (open ($fixture | path join 'tslog-control' 'preflight.json')).state != 'HOLD_OWNERSHIP' { error make {msg: 'missing ordinary owner did not write a fail-closed receipt'} }
let outside = ($fixture | path join 'outside-config.json')
'{}' | save --raw $outside
{config: $outside} | to json --raw | save --raw ($fixture | path join 'tslog-control' 'release-1-intent.json')
let forged = (with-env {GITHUB_ACTIONS: 'true', RUNNER_OS: 'Linux'} { ^nu ($root | path join 'tests' 'firecracker-tslog-guard.nu') --cleanup-only --work $fixture | complete })
if $forged.exit_code == 0 or (open ($fixture | path join 'tslog-control' 'workflow-cleanup.json')).state != 'hold-unresolved' { error make {msg: 'out-of-directory TSLOG config intent was accepted'} }
rm --recursive $fixture
print 'TSLOG manual selector, no-signal guard, and negative policy fixtures PASS'
