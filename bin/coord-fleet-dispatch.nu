#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/coord-fleet-dispatch.nu — dispatch coordinator tasks to remote fleet workers over SSH
#
# Sibling of bin/vm-execute.nu and bin/jail-execute.nu with the same contract:
# task id + commands in,
# {verdict, boot_sec, outputs: [{cmd, stdout, stderr, exit_code}], error?} out.
# `boot_sec` here is preflight (key-auth probe) time, not a VM boot.
#
# Backend: real `ssh` exec. Key-based auth ONLY (repo AUTH policy — never
# guess users/passwords, never pass -o PasswordAuthentication=yes, never
# sshpass). Every invocation carries `-o BatchMode=yes` so a rejected key
# fails fast instead of prompting, plus `-o ConnectTimeout=5`.
#
# Compute targets vs exclusions (see docs/FLEET-DISPATCH.md §2):
#   studio@10.0.2.42  known-good compute worker (7950x4090pop, Linux x86_64)
#   root@10.0.2.61    known-good SSH but EXCLUDED — MiSTer is a gaming box
#                     (armv7l), not a compute target. resolve-target refuses it.
# Any other host runs only with owner-provided access (SMOLFIRE_FLEET_HOST);
# unknown hosts get a conservative capability set (no Network).
#
# Opt-in: fleet dispatch is OFF by default. bin/coord-dispatch.nu routes
# `fleet-*` roles here only when SMOLFIRE_FLEET_ENABLE=1 (same pattern as
# SMOLFIRE_SPAWN_SUBAGENT / SMOLFIRE_EXECUTOR=jail).
#
# S-004 capability gates carry over: the coordinator's §17 check
# (tools_required vs AGENT_CAPABILITIES) still runs before dispatch, AND the
# executor re-checks per-host capabilities here — a "Network" task on a host
# without Network is refused, never silently downgraded.
#
# S-001 attestation carries over: reply-envelope emits one [[claims]] block
# with kind = "command_executed" (same as the jail executor), so the
# coordinator's request-linked attestation check treats fleet replies exactly
# like jail/vm replies. No bypass.
#
# Usage:
#   use coord-fleet-dispatch.nu [run-fleet-task]
#   run-fleet-task "task-0042" ["uname -a"] --target studio@10.0.2.42
#   nu bin/coord-fleet-dispatch.nu run task-0042 --target studio@10.0.2.42 "uname -a"
#   nu bin/coord-fleet-dispatch.nu dispatch --task-id T --dispatch-id D --request-id R --spool S

use ./mbox-parse.nu [parse-mbox, extract-toml, msg-id]

export const FLEET_EXECUTOR_SCHEMA = "v1"
# coord-tick.nu treats a task with no reply after 300 s as failed; keep the
# task deadline inside that window (same clamp as the jail executor).
export const COORD_REPLY_WINDOW_SEC = 300
export const TEARDOWN_RESERVE_SEC   = 30
export const DEFAULT_TIMEOUT_SEC    = 240
export const SSH_CONNECT_TIMEOUT_SEC = 5
export const SSH_ERROR_EXIT_CODE    = 255   # ssh itself failed (not the remote command)
# MiSTer gaming box — reachable over SSH but never a compute target.
export const MISTER_HOST = "10.0.2.61"
export const MISTER_USER_AT_HOST = "root@10.0.2.61"
# The only known-good compute worker (7950x4090pop).
export const KNOWN_COMPUTE_HOST = "10.0.2.42"
# The only tools_required entry that grants fleet network use. Mirrors the
# jail executor: a coordinator-level capability, not a remote firewall rule —
# unknown hosts simply do not get Network tasks at all.
export const NETWORK_CAPABILITY = "Network"

# ── Pure helpers (unit-tested without live hosts) ─────────────────────────────

# Fleet dispatch opt-in gate. Default OFF.
export def fleet-enabled [] {
    ($env | get SMOLFIRE_FLEET_ENABLE? | default "") == "1"
}

# Parse a fleet target into {user, host, target, error}.
# Accepts "user@host", or a bare host with --user / SMOLFIRE_FLEET_USER.
# Refuses: empty input, bad characters, and the MiSTer gaming box.
export def resolve-target [target: string, --user: string = ""] {
    let t = ($target | str trim)
    let u = if $user != "" { $user } else { $env.SMOLFIRE_FLEET_USER? | default "" }
    let raw = if ($t | str contains "@") { $t } else if $t != "" and $u != "" { $"($u)@($t)" } else { $t }
    if $raw == "" {
        return {user: "", host: "", target: "", error: "no fleet target: pass --target user@host (or set SMOLFIRE_FLEET_HOST / SMOLFIRE_FLEET_USER)"}
    }
    let parts = $raw | split row "@"
    if ($parts | length) != 2 or $parts.0 == "" or $parts.1 == "" {
        return {user: "", host: "", target: "", error: $"bad fleet target '($raw)' \(want user@host\)"}
    }
    let user_part = $parts.0
    let host_part = $parts.1
    if not ($user_part =~ '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') {
        return {user: "", host: "", target: "", error: $"unsafe fleet user: ($user_part)"}
    }
    if not ($host_part =~ '^[A-Za-z0-9.:-]+$') {
        return {user: "", host: "", target: "", error: $"unsafe fleet host: ($host_part)"}
    }
    if $host_part == $MISTER_HOST {
        return {user: "", host: "", target: "", error: $"fleet target ($raw) is the MiSTer gaming box — excluded from compute targets \(see docs/FLEET-DISPATCH.md\); use a real worker"}
    }
    {user: $user_part, host: $host_part, target: $"($user_part)@($host_part)", error: ""}
}

# Declared capabilities per fleet host. The known compute worker gets the full
# general-purpose set including Network; owner-provided unknown hosts get a
# conservative default WITHOUT Network (S-004: never grant more than declared).
export def capabilities-for [host: string] {
    if $host == $KNOWN_COMPUTE_HOST {
        ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch", "Network"]
    } else {
        ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    }
}

# Which of tools_required are missing from the host's declared capabilities.
export def missing-capabilities [host: string, tools_required: list<string>] {
    let caps = capabilities-for $host
    $tools_required | where {|t| not ($t in $caps) }
}

# Network is granted only by an explicit "Network" entry in tools_required
# AND a host that declares it.
export def network-wanted [tools_required: list<string>] {
    $NETWORK_CAPABILITY in $tools_required
}

# Clamp the requested task timeout into [1, COORD_REPLY_WINDOW - TEARDOWN_RESERVE].
export def clamp-timeout [timeout_sec: int] {
    let max = $COORD_REPLY_WINDOW_SEC - $TEARDOWN_RESERVE_SEC
    if $timeout_sec < 1 { 1 } else if $timeout_sec > $max { $max } else { $timeout_sec }
}

# Whole seconds left before `deadline_ns` (epoch ns), never negative.
export def remaining-sec [deadline_ns: int, now_ns: int] {
    let left = ($deadline_ns - $now_ns) // 1_000_000_000
    if $left < 0 { 0 } else { $left }
}

# POSIX single-quote a string for safe remote `sh -c`. Pure and tested:
#   sh-quote "echo 'hi'" => 'echo '\''hi'\'''
export def sh-quote [s: string] {
    "'" + ($s | str replace --all "'" "'\\''") + "'"
}

# Base ssh options. Key-based auth only: BatchMode=yes fails fast on a
# rejected key instead of prompting; ConnectTimeout bounds the TCP handshake.
export def ssh-base-args [] {
    ["-o" "BatchMode=yes" "-o" $"ConnectTimeout=($SSH_CONNECT_TIMEOUT_SEC)" "-o" "StrictHostKeyChecking=accept-new"]
}

# Which `timeout(1)` wraps remote exec, or "" for none.
# SMOLFIRE_FLEET_TIMEOUT_BIN overrides ("" disables); else `timeout` on PATH.
export def resolve-timeout-bin [] {
    let override = $env.SMOLFIRE_FLEET_TIMEOUT_BIN? | default "UNSET"
    if $override != "UNSET" {
        $override
    } else if ((which timeout | length) > 0) {
        "timeout"
    } else {
        ""
    }
}

# Argument vector (without privilege prefix — there is none; the remote user
# is fixed by key auth) that runs one command on the worker under the task
# deadline. The command travels as a single shell-quoted `sh -c` payload so
# ssh's argv-joining cannot split it.
export def exec-argv [target: string, cmd: string, remaining: int, --timeout-bin: string = "UNSET", --ssh: string = "ssh"] {
    let tb = if $timeout_bin == "UNSET" { resolve-timeout-bin } else { $timeout_bin }
    let base_args = ssh-base-args
    let remote = ["sh" "-c" (sh-quote $cmd)]
    let ssh_cmd = [$ssh ...$base_args "--" $target ...$remote]
    if $tb == "" {
        $ssh_cmd
    } else {
        [$tb "-k" "5" ($remaining | into string) ...$ssh_cmd]
    }
}

# The result record — identical keys to vm-execute.nu / jail-execute.nu.
export def result-record [verdict: string, boot_sec: int, outputs: list, error: string = ""] {
    let r = {verdict: $verdict, boot_sec: $boot_sec, outputs: $outputs}
    if $error == "" { $r } else { $r | insert error $error }
}

# Add a `warnings` key only when non-empty (same parity shape as jail).
export def attach-warnings [result: record, warnings: list<string>] {
    if ($warnings | is-empty) { $result } else { $result | insert warnings $warnings }
}

# mbox reply envelope for a fleet run. Mirrors dispatch-vm / jail
# reply-envelope ([result] boot_sec/outputs + one [[claims]] block with
# kind = "command_executed") so harvesting stays executor-agnostic (S-001);
# In-Reply-To is the coordinator's dispatch Message-ID (what state-waiting
# matches on).
export def reply-envelope [task_id: string, dispatch_id: string, result: record, --now: string = ""] {
    let stamp  = if $now == "" { date now | format date "%Y%m%d%H%M%S" } else { $now }
    let dstamp = date now | format date "%a %b %e %H:%M:%S %Y"
    let outputs_toml = $result.outputs | each {|o|
        $"  {cmd = ($o.cmd | to json), stdout = ($o.stdout | to json), stderr = ($o.stderr | to json), exit_code = ($o.exit_code)}"
    } | str join ",\n"
    let err = $result | get -o error | default ""
    let error_line = if $err != "" { $"\nX-Fleet-Error: ($err | str replace --all "\n" " ")" } else { "" }
    let exit_codes = $result.outputs | get -o exit_code | default [] | each {|c| $c | into string} | str join ","
    let target = $result | get -o target | default ""
    $"From fleet-agent@smolfire.local ($dstamp)
From: fleet-agent@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [($task_id)] fleet execution result
Message-ID: <($task_id).fleet-agent.($stamp)@smolfire.local>
In-Reply-To: ($dispatch_id)
X-Project: smolfire
X-Executor: fleet
X-Verdict: ($result.verdict)($error_line)
Content-Type: text/toml; charset=utf-8

task_id = ($task_id | to json)
verdict = ($result.verdict | to json)
fleet_target = ($target | to json)

[result]
boot_sec = ($result.boot_sec)
outputs = [
($outputs_toml)
]

[[claims]]
kind      = \"command_executed\"
task_id   = ($task_id | to json)
subject   = \"fleet worker executed all commands\"
expected  = \"all commands exit 0\"
evidence  = ($"($result.outputs | length) commands run on ($target); exit codes [($exit_codes)]" | to json)
verdict   = ($result.verdict | to json)

"
}

# What to write before appending a message to an mbox whose current contents
# are `existing`, so the new "From " line follows a blank line (strict mbox).
export def mbox-append-prefix [existing: string] {
    if $existing == "" or ($existing | str ends-with "\n\n") {
        ""
    } else if ($existing | str ends-with "\n") {
        "\n"
    } else {
        "\n\n"
    }
}

# Per-task HALT marker path under a coordinator root. A halted task must not
# dispatch (halt/resume compatible): run-fleet-task refuses when it exists.
export def halt-marker-path [root: string, task_id: string] {
    [$root "var" "mail" $"HALT.($task_id)"] | path join
}

# Derive the coordinator root from a spool path (<root>/var/mail/spool) so the
# halt check works without extra plumbing. Falls back to ".".
export def root-for-spool [spool: string] {
    let marker = ["var" "mail" "spool"] | path join
    if ($spool | str ends-with $marker) {
        $spool | path dirname | path dirname | path dirname
    } else {
        "."
    }
}

export def task-halted? [root: string, task_id: string] {
    (halt-marker-path $root $task_id) | path exists
}

# ── Side-effecting helpers ────────────────────────────────────────────────────

# Run argv; never throws. Returns {stdout, stderr, exit_code}.
def exec-run [argv: list<string>] {
    let exe  = $argv | first
    let rest = $argv | skip 1
    try {
        ^$exe ...$rest | complete
    } catch {|e|
        {stdout: "", stderr: ($e | get -o msg | default "spawn failed"), exit_code: 127}
    }
}

def now-ns [] { date now | into int }

def diag [event: string, payload: record] {
    let row = {ts: (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"), event: $event} | merge $payload
    print -e ($row | to toml)
    print -e "---"
}

# Key-auth probe: `ssh <opts> <target> true`. Returns {ok: bool, error: string}.
export def preflight-target [target: string, --ssh: string = "ssh"] {
    let base_args = ssh-base-args
    let r = exec-run ([$ssh ...$base_args "--" $target "true"])
    if $r.exit_code == 0 {
        {ok: true, error: ""}
    } else {
        {ok: false, error: $"fleet preflight failed for ($target): key auth or reachability check failed \(exit ($r.exit_code)\): (($r.stderr | str trim))"}
    }
}

# ── Public: run a task on a fleet worker ──────────────────────────────────────

# Run a list of commands on a remote fleet worker over SSH and return the same
# record shape as run-vm-task / run-jail-task:
# {verdict, boot_sec, outputs, target, error?}.
export def run-fleet-task [
    task_id:  string
    commands: list<string>
    --target:          string = ""       # user@host (or SMOLFIRE_FLEET_HOST)
    --user:            string = ""       # user for a bare-host --target / SMOLFIRE_FLEET_USER
    --tools-required:  list<string> = [] # re-checked against per-host capabilities (S-004)
    --timeout:         int    = 240      # whole-task wall clock, seconds (clamped)
    --ssh:             string = ""       # ssh binary override (tests stub via PATH instead)
    --timeout-bin:     string = "UNSET"  # timeout(1) override; "" disables the wrapper
    --skip-preflight                 # skip the key-auth probe (tests; live runs keep it)
    --root:            string = "."      # coordinator root for the HALT check
] {
    if (task-halted? $root $task_id) {
        return (result-record "fail" 0 [] $"task ($task_id) is halted \(($root)/var/mail/HALT.($task_id) present\); refusing to dispatch")
    }
    if ($commands | length) == 0 { return (result-record "fail" 0 [] "no commands to run") }

    let raw_target = if $target != "" { $target } else { $env.SMOLFIRE_FLEET_HOST? | default "" }
    let rt = resolve-target $raw_target --user $user
    if $rt.error != "" { return (result-record "fail" 0 [] $rt.error) }

    let missing = missing-capabilities $rt.host $tools_required
    if ($missing | length) > 0 {
        return (result-record "fail" 0 [] $"fleet host ($rt.host) does not declare capabilities: ($missing | str join ', ') \(tools_required: ($tools_required | str join ', ')\)")
    }

    let ssh_bin = if $ssh != "" { $ssh } else { $env.SMOLFIRE_FLEET_SSH? | default "ssh" }
    let t0 = now-ns
    if not $skip_preflight {
        let pf = preflight-target $rt.target --ssh $ssh_bin
        if not $pf.ok { return (result-record "fail" 0 [] $pf.error) }
    }
    let boot_sec = ((now-ns) - $t0) // 1_000_000_000

    let tb = if $timeout_bin == "UNSET" { resolve-timeout-bin } else { $timeout_bin }
    mut warnings = []
    if $tb == "" {
        $warnings = $warnings | append "no timeout\(1\) on PATH: per-command deadline wrapper disabled; ssh ConnectTimeout still bounds connection setup"
    }
    let budget = clamp-timeout $timeout
    let deadline = (now-ns) + ($budget * 1_000_000_000)

    # ── run ──────────────────────────────────────────────────────────────────
    mut outputs = []
    mut all_ok = true
    mut run_error = ""
    for cmd in $commands {
        let rem = remaining-sec $deadline (now-ns)
        if $rem <= 0 {
            $all_ok = false
            $run_error = $"task timeout: ($budget)s budget exhausted before `($cmd)`"
            break
        }
        let r = exec-run (exec-argv $rt.target $cmd $rem --timeout-bin $tb --ssh $ssh_bin)
        $outputs = $outputs | append {
            cmd:       $cmd
            stdout:    ($r.stdout | str trim)
            stderr:    ($r.stderr | str trim)
            exit_code: $r.exit_code
        }
        if $r.exit_code != 0 { $all_ok = false }
        if $r.exit_code == $SSH_ERROR_EXIT_CODE {
            $run_error = $"ssh to ($rt.target) failed during `($cmd)`: (($r.stderr | str trim))"
            break
        }
    }

    # ── teardown ─────────────────────────────────────────────────────────────
    # Nothing persistent exists server-side: each command is its own `ssh`
    # invocation, so a finished or killed ssh leaves no remote process behind
    # (no keep-alive container, no jail, no overlay to destroy). Teardown is
    # therefore a no-op by construction; recorded here so the doc claim is
    # greppable next to the jail executor's teardown.
    let verdict = if $all_ok { "pass" } else { "fail" }
    let base = result-record $verdict $boot_sec $outputs $run_error | insert target $rt.target
    attach-warnings $base $warnings
}

# ── CLI ───────────────────────────────────────────────────────────────────────

# Exit status for a result: 0 pass, 2 refused (halted / bad target /
# capability refusal / preflight failure), 1 otherwise.
export def result-exit [result: record] {
    let err = ($result | get -o error | default "")
    if $result.verdict == "pass" {
        0
    } else if ($err | str starts-with "task ") and ($err | str contains "is halted") {
        2
    } else if ($err | str starts-with "no fleet target") or ($err | str starts-with "bad fleet target") or ($err | str starts-with "unsafe fleet") or ($err | str starts-with "fleet target ") or ($err | str starts-with "fleet host ") or ($err | str starts-with "fleet preflight") {
        2
    } else {
        1
    }
}

# Run commands on a fleet worker and print the result record as JSON.
def "main run" [
    task_id: string
    ...commands: any    # any: nu's script-arg parser turns bare `true`/`42` into non-strings
    --target: string = ""
    --user: string = ""
    --timeout: int = 240
    --skip-preflight
] {
    let cmds = $commands | each {|c| $c | into string }
    let result = run-fleet-task $task_id $cmds --target $target --user $user --timeout $timeout --skip-preflight=$skip_preflight
    print ($result | to json)
    exit (result-exit $result)
}

# Coordinator entry point (spawned detached by coord-dispatch.nu when the
# fleet backend is enabled). Reads the ORIGINAL request (--request-id) from
# the spool for commands / fleet target / tools_required, runs it, and
# appends a reply whose In-Reply-To is the coordinator's dispatch Message-ID
# (--dispatch-id).
def "main dispatch" [
    --task-id: string
    --dispatch-id: string
    --request-id: string
    --spool: string
] {
    let root = root-for-spool $spool
    let msgs = parse-mbox (open --raw $spool)
    let req = $msgs | where {|m| (msg-id $m) == $request_id } | first 1
    let payload = if ($req | is-empty) { {} } else { extract-toml ($req | first) }

    let commands = if ($payload | get -o commands.run | default [] | is-not-empty) {
        $payload | get commands.run
    } else if ($payload | get -o command | default "") != "" {
        [$payload.command]
    } else { [] }
    let cp = $payload | get -o context_pointers | default {}
    let target = $cp | get -o fleet_target | default ($env.SMOLFIRE_FLEET_HOST? | default "")
    let user = $cp | get -o fleet_user | default ""
    let tools = $payload | get -o tools_required | default []
    let timeout = $payload | get -o timeout_sec | default ($env.SMOLFIRE_FLEET_TIMEOUT? | default $DEFAULT_TIMEOUT_SEC | into int)

    let result = if ($req | is-empty) {
        result-record "fail" 0 [] $"request ($request_id) not found in spool"
    } else {
        run-fleet-task $task_id $commands --target $target --user $user --tools-required $tools --timeout $timeout --root $root
    }
    # Strict mbox: the reply's "From " line must follow a blank line.
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    (mbox-append-prefix $existing) + (reply-envelope $task_id $dispatch_id $result) | save --append $spool
    diag "fleet_dispatch_done" {task_id: $task_id, verdict: $result.verdict, boot_sec: $result.boot_sec, error: ($result | get -o error | default "")}
    exit (result-exit $result)
}

def main [] {
    print "coord-fleet-dispatch.nu — fleet SSH executor (opt-in; see docs/FLEET-DISPATCH.md)"
    print "  nu bin/coord-fleet-dispatch.nu run <task_id> <cmd>... --target user@host [--timeout N]"
    print "  nu bin/coord-fleet-dispatch.nu dispatch --task-id T --dispatch-id D --request-id R --spool PATH"
}
