#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Offline CLI fixture only: no jail, ZFS, podman, network, or host mutation.

def "main contract" [] {
    let schema = if ($env.FAKE_AGENT_MODE? | default "") == "bad-contract" {
        "wrong.contract"
    } else {
        "agent-jail.executor.contract.v1"
    }
    print ({schema: $schema, canonical_repo: "ryanmaclean/agent-jail", executor: "jail", executor_schema: "v1"} | to json)
}

def "main run" [
    task_id: string
    ...commands: any
    --base: string = ""
    --zfs-snapshot: string = ""
    --image: string = ""
    --network
    --timeout: int = 240
    --jail-root: string = "/var/smolfire/jails"
    --allow-unpatched
] {
    let seen = {
        task_id: $task_id
        commands: ($commands | each {|c| $c | into string})
        base: $base
        zfs_snapshot: $zfs_snapshot
        image: $image
        network: $network
        timeout: $timeout
        jail_root: $jail_root
        allow_unpatched: $allow_unpatched
    }
    if ("FAKE_AGENT_LOG" in $env) { $seen | to json | save --force $env.FAKE_AGENT_LOG }
    let mode = $env.FAKE_AGENT_MODE? | default ""
    if $mode == "bad-json" { print "not JSON"; exit 1 }
    let outputs = $seen.commands | each {|cmd| {cmd: $cmd, stdout: "", stderr: "", exit_code: 0} }
    if $mode == "fail" {
        print ({verdict: "fail", boot_sec: 0, outputs: $outputs, error: "fixture failure"} | to json)
        exit 1
    }
    let reported_outputs = if $mode == "short-pass" {
        []
    } else if $mode == "wrong-command-pass" {
        $outputs | each {|o| $o | update cmd "unexpected-command"}
    } else if $mode == "nonzero-pass" {
        $outputs | each {|o| $o | update exit_code 7}
    } else {
        $outputs
    }
    print ({verdict: "pass", boot_sec: 0, outputs: $reported_outputs} | to json)
}

def main [] { print "offline fake agent-jail" }
