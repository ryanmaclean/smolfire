#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# The only stage allowed to assert the hard Firecracker release goal.
def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def sha [path: string] { require ($path | path exists) $"missing ($path)"; open --raw $path | hash sha256 }
def live_generation [pid: string] {
    let stat = $"/proc/($pid)/stat"
    if not ($stat | path exists) { return '' }
    let fields = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19) 'live owner stat malformed during finalization'
    $fields | get 19
}
def main [--work: string = '/mnt/smolfire-ci', --audit: string = 'tests/firecracker-boot-mute-audit.nu'] {
    let dir = ($work | path join 'firecracker-boot-mute')
    let report_path = ($dir | path join 'report.json')
    let audit_path = ($dir | path join 'audit.json')
    let replay_path = ($dir | path join 'workflow-audit.json')
    let cleanup_path = ($dir | path join 'workflow-cleanup.json')
    for p in [$report_path $audit_path $replay_path $cleanup_path] { require ($p | path exists) $"mandatory receipt absent: ($p)" }
    let report = (open $report_path)
    let prior = (open $audit_path)
    let replay = (open $replay_path)
    let independent = (^nu $audit $report_path | complete)
    require ($independent.exit_code == 0) 'independent post-teardown audit failed'
    let fresh = ($independent.stdout | from json)
    require ($prior == $fresh and $replay == $fresh) 'pre-teardown and independent audit differ'
    require ($fresh.mechanism_pairs_complete and $fresh.panic_visibility and $fresh.firecracker_release_goal == 'PENDING_TEARDOWN') 'pre-teardown evidence incomplete'
    let late = (open $cleanup_path)
    require (not $late.forced and $late.state == 'no-owner') 'late teardown did not reconcile to no-owner'
    require (not ($dir | path join 'current-tag' | path exists)) 'current owner remains after teardown'
    require (($report.samples | length) == 6) 'report lacks six timed boots'
    let all = ($report.samples | append $report.panic_control)
    for s in $all {
        require ((sha $s.cleanup_path) == $s.cleanup_sha256) 'per-boot cleanup changed after audit'
        let receipt = (open $s.cleanup_path)
        require (not $receipt.forced and ($receipt.state in ['term-exited' 'already-exited'])) 'forced or unresolved per-boot owner'
        if (($env.GITHUB_ACTIONS? | default '') == 'true') {
            require ((live_generation ($receipt.pid | into string)) != ($receipt.generation | into string)) 'an exact owned VM remains live after teardown'
        }
    }
    let pass = ($fresh.all_muted_within_100ms and ($fresh.paired_results | length) == 3)
    let verdict = {kind: 'firecracker-boot-mute-final-v1', source_commit: $report.source_commit, report_sha256: (sha $report_path), audit_sha256: (sha $audit_path), workflow_audit_sha256: (sha $replay_path), workflow_cleanup_sha256: (sha $cleanup_path), per_boot_cleanup_sha256: ($all | each {|s| {tag: $s.tag, sha256: (sha $s.cleanup_path)}}), paired_results: $fresh.paired_results, mechanism_pairs_complete: true, panic_visibility: true, all_muted_within_100ms: $pass, firecracker_release_goal: (if $pass { 'PASS' } else { 'FAIL_OVER_100MS' })}
    $verdict | to json --indent 2 | save --raw --force ($dir | path join 'final-verdict.json')
    print ($verdict | to json --indent 2)
    require $pass 'all muted Firecracker release boots did not meet strict <=100ms goal'
}
