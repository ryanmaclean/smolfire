#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Source-only TSLOG gate until FreeBSD guest reboot is proved to exit Firecracker.
# No process is launched, commanded, or signaled by this helper.
use firecracker-owner-scan.nu matching_config_pids

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def result_dir [work: string] { $work | path join 'tslog-control' }
export def preflight_decision [owner_present: bool, receipt_present: bool, same_identity: bool, no_processes: bool] {
    if not $owner_present or not $receipt_present or not $same_identity or not $no_processes { 'HOLD_OWNERSHIP' } else { 'HOLD_FREEBSD_EXIT_UNPROVEN' }
}
def no_firecracker [] {
    let ps = (^pgrep -x firecracker | complete)
    require ($ps.exit_code == 1) 'live or unreadable Firecracker enumeration; no TAP reuse'
}
def preflight [work: string] {
    let owner_path = ($work | path join 'firecracker-owner.json')
    let cleanup_path = ($work | path join 'firecracker-ordinary-cleanup.json')
    require (($owner_path | path exists) and ($cleanup_path | path exists)) 'ordinary gate owner/cleanup receipt absent'
    let owner = (open $owner_path)
    let prior = (open $cleanup_path)
    let config = ($work | path join 'fc.json')
    let binary = ($work | path join 'firecracker')
    require (($owner.pid | into string) =~ '^[0-9]+$' and ($owner.generation | into string) =~ '^[0-9]+$') 'ordinary PID/generation malformed'
    require ($owner.config == $config and $owner.exe == $binary and $owner.argv == [$binary '--no-api' '--config-file' $config]) 'ordinary spawn identity differs from expected config/argv'
    require ($prior.pid == ($owner.pid | into string) and $prior.generation == ($owner.generation | into string) and $prior.scanned_config == $config and $prior.forced == false and $prior.state in ['already-exited' 'naturally-exited'] and ($prior.matching_config_pids | is-empty)) 'ordinary cleanup receipt does not prove recorded owner exit'
    require (not ($"/proc/($owner.pid)" | path exists)) 'ordinary recorded PID remains present or reused; hold TAP'
    require ((matching_config_pids [$config]) | is-empty) 'ordinary exact config still in use'
    no_firecracker
    'HOLD_FREEBSD_EXIT_UNPROVEN'
}
def cleanup [work: string] {
    let dir = (result_dir $work)
    mut configs = []
    for intent_path in (glob ($dir | path join '*-intent.json')) {
        let intent = (open $intent_path)
        require (($intent.config | str starts-with $"($dir)/") and ($intent.config | path exists)) 'TSLOG intent config absent or outside result directory'
        $configs = ($configs | append $intent.config)
    }
    let configs = ($configs | uniq | sort)
    let matches = (matching_config_pids $configs)
    require ($matches | is-empty) 'attempted TSLOG config still used by Firecracker'
    no_firecracker
    require ($configs | is-empty) 'TSLOG boot intent exists although source-only guard must not spawn'
    {state: 'no-tslog-spawn', forced: false, scanned_configs: $configs, matching_config_pids: []}
}
def main [--preflight, --cleanup-only, --work: string = '/mnt/smolfire-ci'] {
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'hosted Linux only'
    require ($preflight != $cleanup_only) 'choose one guard operation'
    let dir = (result_dir $work)
    mkdir $dir
    if $preflight {
        let result = (try { {ok: true, value: (preflight $work)} } catch {|err| {ok: false, value: $err.msg} })
        {state: (if $result.ok { $result.value } else { 'HOLD_OWNERSHIP' }), reason: (if $result.ok { 'FreeBSD reboot-driven Firecracker exit has no hosted witness; no TSLOG spawn' } else { $result.value }), forced: false} | to json --raw | save --raw --force ($dir | path join 'preflight.json')
        error make {msg: $"TSLOG manual path HOLD: ($result.value)"}
    }
    let result = (try { {ok: true, value: (cleanup $work)} } catch {|err| {ok: false, value: $err.msg} })
    let receipt = (if $result.ok { $result.value } else { {state: 'hold-unresolved', forced: false, reason: $result.value} })
    $receipt | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
    require $result.ok $result.value
    print ($receipt | to json --raw)
}
