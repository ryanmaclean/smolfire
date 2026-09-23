#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/coord-dispatch.nu — launch a subagent via the claude CLI or a real VM
#
# The coordinator writes a task brief to the spool (already implemented).
# This module actually spawns the subagent process that will read that brief
# and write a reply back to the spool.
#
# Role routing:
#   vm-*@smolfire.local  → dispatch-vm  (boots qcow2, runs commands via SSH)
#   anything else       → dispatch-claude (spawns claude CLI)

# Find the claude CLI binary.
#
# SMOLFIRE_SUBAGENT_CMD, when set, overrides resolution entirely — it is
# used verbatim (after an existence check) instead of the hard-coded
# absolute-path probe below. This lets tests point find-claude at a stub
# deterministically, since PATH stripping alone cannot intercept these
# hard-coded paths (see docs/UR-BSD.md and tests/coord-dispatch-test.nu).
def find-claude [] {
    let override = $env | get SMOLFIRE_SUBAGENT_CMD? | default ""
    if $override != "" {
        return (if ($override | path exists) { $override } else { null })
    }
    let candidates = [
        "/opt/homebrew/bin/claude"
        "/usr/local/bin/claude"
        ($env.HOME | path join ".local/bin/claude")
    ]
    let found = $candidates | where { |p| $p | path exists }
    if ($found | is-empty) { null } else { $found | first }
}

# ── Private: claude CLI path ───────────────────────────────────────────────────

# Dispatch a task to a claude CLI subagent.
# Returns {launched: bool, pid: int, log_path: string}
#
# Billed-subprocess guard: same opt-in kill switch as bin/coord-tick.nu's
# spawn-subagent — spawning a real, billed subagent is OFF by default and
# requires SMOLFIRE_SPAWN_SUBAGENT=1. This is defense-in-depth: no test in
# this repo currently exercises dispatch-claude (only dispatch-vm is
# covered by tests/coord-vm-e2e-tests.nu), but without this gate any future
# test that reaches this function on a host with a real claude CLI installed
# would launch and bill a real subagent via `job spawn`.
def dispatch-claude [
    task_id:   string
    role:      string
    brief:     string
    spool:     string
    log_dir:   string = "var/run/dispatch-logs"
] {
    if (($env | get SMOLFIRE_SPAWN_SUBAGENT? | default "") != "1") {
        return {launched: false, pid: 0, log_path: "", error: "subagent spawning disabled by default (set SMOLFIRE_SPAWN_SUBAGENT=1 to enable)"}
    }
    let claude = find-claude
    if $claude == null {
        return {launched: false, pid: 0, log_path: "", error: "claude CLI not found"}
    }

    # Build the prompt: instruct the agent to read the spool for its task
    # and append a reply using the mbox+TOML protocol.
    let prompt = $"You are a smolfire subagent with role '($role)'.

Your task brief \(task_id: ($task_id)\) is in the spool at ($spool).
Find the message with Message-ID containing '($task_id).coord@smolfire.local', read the TOML body for your instructions, do the work, then append a properly-formatted mbox+TOML reply to ($spool).

Brief summary:
($brief | str substring ..500)

Reply format: standard smolfire mbox+TOML envelope with X-Verdict: pass|fail and [[claims]] blocks."

    # Ensure log dir exists
    if not ($log_dir | path exists) { mkdir $log_dir }
    let log_path = [$log_dir, $"($task_id)-($role).log"] | path join
    let ts = date now | format date "%Y-%m-%dT%H:%M:%SZ"

    let result = try {
        let claude_bin = $claude
        # override with SMOLFIRE_CLAUDE_MODEL env var
        let model = $env | get SMOLFIRE_CLAUDE_MODEL? | default "claude-sonnet-5"
        let job_id = job spawn {
            ^$claude_bin --print --bare --allowedTools "Write,Bash,Read,Glob,Grep" --max-budget-usd 1.0 --model $model $prompt o> $log_path e>> $log_path
        }
        {launched: true, pid: $job_id, log_path: $log_path, started_at: $ts}
    } catch {|err|
        {launched: false, pid: 0, log_path: $log_path, error: ($err | get msg? | default "spawn failed"), started_at: $ts}
    }

    $result
}

# ── Private: VM execution path ─────────────────────────────────────────────────

# Dispatch a task to a real smolfire VM (role pattern: vm-*@smolfire.local).
# Reads commands from the task TOML body's [commands] run = [...] section.
# Returns {launched: bool, mode: string, verdict: string, boot_sec: int}
export def dispatch-vm [
    task_id: string
    role:    string
    brief:   string   # full TOML body — must contain [commands] run = [...]
    spool:   string
] {
    let parsed   = try { $brief | from toml } catch { {} }
    let commands = $parsed | get -o commands.run | default []
    let image    = $parsed | get -o context_pointers.image_path | default "build/FreeBSD-15-aarch64-smolfire.qcow2"
    let arch     = $parsed | get -o context_pointers.arch | default "arm64"

    if ($commands | length) == 0 {
        return {launched: false, error: "no commands.run in task brief"}
    }

    use vm-execute.nu [run-vm-task]
    let result = run-vm-task $task_id $image $commands --arch $arch --use-overlay

    # Build reply envelope and append to spool
    let ts     = date now | format date "%a, %d %b %Y %H:%M:%S -0000"
    let dstamp = date now | format date "%a %b %e %H:%M:%S %Y"

    let outputs_toml = $result.outputs | enumerate | each {|e|
        let o = $e.item
        $"  {cmd = ($o.cmd | to json), stdout = ($o.stdout | to json), exit_code = ($o.exit_code)}"
    } | str join ",\n"

    let cmd_count = $result.outputs | length
    let evidence_str = $"($cmd_count) commands run"
    let reply_body = $"task_id = ($task_id | to json)
verdict  = ($result.verdict | to json)

[result]
boot_sec = ($result.boot_sec)
outputs = [
($outputs_toml)
]

[[claims]]
subject  = \"VM executed all commands\"
expected = \"all commands exit 0\"
evidence = ($evidence_str | to json)
verdict  = ($result.verdict | to json)
"

    let error_line = if "error" in $result { $"\nX-VM-Error: ($result.error)" } else { "" }
    let reply_envelope = $"From vm-agent@smolfire.local ($dstamp)
From: vm-agent@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [($task_id)] VM execution result
Date: ($ts)
Message-ID: <($task_id).vm-agent@smolfire.local>
In-Reply-To: <($task_id).coord@smolfire.local>
X-Project: smolfire
X-Verdict: ($result.verdict)($error_line)
Content-Type: text/toml; charset=utf-8

($reply_body)
"

    $reply_envelope | save --append $spool
    {launched: true, mode: "vm-direct", verdict: $result.verdict, boot_sec: $result.boot_sec}
}

# ── Public: unified dispatch entry point ──────────────────────────────────────

# Dispatch a subagent for a task.
# Routes to the VM path when role starts with "vm-"; otherwise uses the claude CLI.
# Returns a record with {launched: bool, ...} — signature is stable for coord-tick.nu.
export def dispatch-subagent [
    task_id:   string   # e.g. "task-0007"
    role:      string   # e.g. "builder" | "vm-runner" — determines dispatch path
    brief:     string   # the full task brief (TOML body from the spool message)
    spool:     string   # path to the spool file (so agent can append reply)
    log_dir:   string = "var/run/dispatch-logs"  # where to write agent stdout (claude path)
] {
    if ($role | str starts-with "vm-") {
        dispatch-vm $task_id $role $brief $spool
    } else {
        dispatch-claude $task_id $role $brief $spool $log_dir
    }
}

# Check if a dispatched subagent job is still running.
# pid here is a Nushell job ID (returned by job spawn), not an OS PID.
export def agent-running? [pid: int] {
    if $pid == 0 { return false }
    let jobs = job list
    ($jobs | where id == $pid | length) > 0
}
