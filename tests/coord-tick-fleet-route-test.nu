# SPDX-License-Identifier: Apache-2.0
# coord-tick-fleet-route-test.nu — tick-level fleet routing (resolve-executor +
# state-dispatching → real fleet backend).
#
# Gap under test (proven live in the FANOUT dogfood): bin/coord-tick.nu
# resolve-executor knew only vm|jail, so `fleet-*` roles fell into the
# spawn-subagent claude-CLI path (spawn-skipped) and an explicit
# executor=fleet was refused as unknown.
#
# No live hosts: `ssh` is a stub via a PATH shim directory (same pattern as
# tests/coord-fleet-dispatch-test.nu). The stub records argv so tests assert
# the fleet backend really ran against the expected host. The tick's detached
# fleet child (`coord-fleet-dispatch.nu dispatch`) inherits PATH + env, so the
# stub is what the child execs — a refused/downgraded route leaves no ssh log.
#
# Single-pending FSM is unchanged (no parallel pendings — out of scope).

def "assert equal" [left: any, right: any, msg: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

def read-state [path: string] {
    open --raw $path | from toml
}

def make-msg [
    from_addr:  string
    to_addr:    string
    message_id: string
    body:       string
] {
    ([
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}

# Drop every PATH directory that contains an executable named after a known
# billed-agent CLI (same defense-in-depth as tests/coord-tick-test.nu).
def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

# Write a stub `ssh` into $dir. Logs argv to ssh.log, prints a marker,
# exits 0 (pass). Returns the log path (absent until first invocation).
def write-ssh-stub [dir: string] {
    let log = [$dir, "ssh.log"] | path join
    let ssh_stub = [$dir, "ssh"] | path join
    $"#!/bin/sh\nlog=\"($log)\"\necho \"$@\" >> \"$log\"\necho \"stub-stdout for: $@\"\nexit 0\n" | save --force $ssh_stub
    ^chmod +x $ssh_stub
    $log
}

# Run one coordinator tick, capturing output. The stub dir leads PATH so the
# detached fleet child execs stub ssh; the timeout(1) wrapper is disabled via
# SMOLFIRE_FLEET_TIMEOUT_BIN="" (no stub timeout needed). --fleet toggles
# SMOLFIRE_FLEET_ENABLE=1; without it the flag is hidden (default-off).
def run-tick [root: string, stub_dir: string, --fleet] {
    let nu_bin = $nu.current-exe
    let base_path = strip-agent-bins ($env.PATH | split row ":" | where {|d| $d != "" })
    let full_path = ([$stub_dir] | append $base_path | str join ":")
    with-env {PATH: $full_path, SMOLFIRE_FLEET_TIMEOUT_BIN: ""} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_EXECUTOR
        hide-env -i SMOLFIRE_FLEET_HOST
        hide-env -i SMOLFIRE_FLEET_USER
        if $fleet {
            with-env {SMOLFIRE_FLEET_ENABLE: "1"} {
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
            }
        } else {
            hide-env -i SMOLFIRE_FLEET_ENABLE
            (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
        }
    }
}

# Wait (up to $timeout_sec) for the detached fleet child to append its reply.
def wait-for-fleet-reply [spool_abs: string, timeout_sec: int = 20] {
    mut waited = 0
    while $waited < $timeout_sec {
        let content = try { open --raw $spool_abs } catch { "" }
        if ($content | str contains "fleet-agent@smolfire.local") { return true }
        sleep 1sec
        $waited = $waited + 1
    }
    false
}

const FLEET_TARGET = "tester@fleet-stub.test"

def fleet-request-body [task_id: string] {
    $"task_id = \"($task_id)\"\ntools_required = [\"Bash\"]\n\n[commands]\nrun = [\"echo fleet-ok\"]\n\n[context_pointers]\nfleet_target = \"($FLEET_TARGET)\"\n"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

print "test 1: fleet role + enabled → real fleet dispatch, ssh hits expected host, harvest pass"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    write-spool $spool_abs (make-msg "user@smolfire.local" "fleet-builder-1@smolfire.local" "<req.fleet1@smolfire.local>" (fleet-request-body "t-fleet-1"))

    let r1 = run-tick $tmp $stub_dir --fleet
    assert equal $r1.exit_code 0 "tick1 exits 0"
    # Routed to fleet BEFORE the spawn-subagent classification: the spawn
    # event names the fleet executor/agent, never the claude-CLI role.
    assert ($r1.stdout | str contains 'executor = "fleet"') "dispatch_sent names fleet"
    assert ($r1.stdout | str contains 'agent_type = "fleet-agent"') "fleet spawn event, not claude role"
    assert (not ($r1.stdout | str contains "subagent_spawn_skipped")) "never hit the spawn-subagent path"
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting" "dispatched → waiting"
    assert equal ($st1.task_executors | get "t-fleet-1" | get executor) "fleet" "recorded executor"
    assert ((open --raw $spool_abs) | str contains 'executor = "fleet"') "dispatch envelope tagged fleet"

    assert (wait-for-fleet-reply $spool_abs) "detached fleet child appended a reply"
    assert ((open --raw $ssh_log) | str contains $FLEET_TARGET) "stub ssh called with expected host"
    assert ((open --raw $ssh_log) | str contains "BatchMode=yes") "key-auth-only ssh argv"

    let r2 = run-tick $tmp $stub_dir --fleet
    assert equal $r2.exit_code 0 "tick2 exits 0"
    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle" "pass verdict harvested → idle"
    assert ((open --raw $spool_abs) | str contains "X-Executor: fleet") "fleet reply in spool"
    assert ((open --raw $spool_abs) | str contains "X-Verdict: pass") "pass verdict recorded"
    assert ($r2.stdout | str contains 'verdict = "pass"') "pass verdict telemetry"

    ^rm -rf $tmp
}

print "test 2: fleet role + disabled → old behavior exactly (vm dispatch, spawn-skipped, no ssh)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    write-spool $spool_abs (make-msg "user@smolfire.local" "fleet-builder-1@smolfire.local" "<req.fleet2@smolfire.local>" (fleet-request-body "t-fleet-2"))

    let r = run-tick $tmp $stub_dir
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($r.stdout | str contains "subagent_spawn_skipped") "old spawn-skipped path"
    assert ($r.stdout | str contains 'agent_type = "fleet-builder-1"') "old claude-CLI role classification"
    assert (not ($r.stdout | str contains 'executor = "fleet"')) "no fleet executor anywhere"
    let st = read-state $state_abs
    assert equal $st.fsm_state "waiting" "dispatched as vm → waiting"
    assert equal ($st.task_executors | get "t-fleet-2" | get executor) "vm" "old default executor"
    assert ((open --raw $spool_abs) | str contains 'executor = "vm"') "dispatch envelope tagged vm"
    assert (not ($ssh_log | path exists)) "ssh never invoked"

    ^rm -rf $tmp
}

print "test 3: explicit executor=fleet + enabled → accepted end-to-end (non-fleet role)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    # Explicit executor field wins independent of the recipient role.
    let body = $"task_id = \"t-fleet-3\"\nexecutor = \"fleet\"\ntools_required = [\"Bash\"]\n\n[commands]\nrun = [\"echo fleet-ok\"]\n\n[context_pointers]\nfleet_target = \"($FLEET_TARGET)\"\n"
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.fleet3@smolfire.local>" $body)

    let r1 = run-tick $tmp $stub_dir --fleet
    assert equal $r1.exit_code 0 "tick1 exits 0"
    assert (not ($r1.stdout | str contains "dispatch_executor_refused")) "explicit fleet accepted"
    assert ($r1.stdout | str contains 'executor = "fleet"') "fleet dispatch"
    let st1 = read-state $state_abs
    # Recipient is builder@… (no fleet- prefix): fleet could only come from
    # the explicit request field, proving request-source precedence.
    assert equal ($st1.task_executors | get "t-fleet-3" | get executor) "fleet" "recorded executor"
    assert equal $st1.fsm_state "waiting" "dispatched → waiting"

    assert (wait-for-fleet-reply $spool_abs) "detached fleet child appended a reply"
    assert ((open --raw $ssh_log) | str contains $FLEET_TARGET) "stub ssh called with expected host"

    let r2 = run-tick $tmp $stub_dir --fleet
    assert equal $r2.exit_code 0 "tick2 exits 0"
    assert equal (read-state $state_abs | get fsm_state) "idle" "pass verdict harvested → idle"

    ^rm -rf $tmp
}

print "test 4: explicit executor=fleet + disabled → refused exactly as before"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    let body = $"task_id = \"t-fleet-4\"\nexecutor = \"fleet\"\ntools_required = [\"Bash\"]\n\n[commands]\nrun = [\"echo fleet-ok\"]\n\n[context_pointers]\nfleet_target = \"($FLEET_TARGET)\"\n"
    write-spool $spool_abs (make-msg "user@smolfire.local" "fleet-builder-1@smolfire.local" "<req.fleet4@smolfire.local>" $body)

    let r = run-tick $tmp $stub_dir
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($r.stdout | str contains "dispatch_executor_refused") "refused"
    assert ($r.stdout | str contains "unknown executor 'fleet'") "old unknown-executor error"
    let st = read-state $state_abs
    assert equal $st.fsm_state "idle" "nothing dispatched"
    assert (not ((open --raw $spool_abs) | str contains "action = \"dispatch\"")) "no dispatch appended"
    assert (not ($ssh_log | path exists)) "ssh never invoked"

    ^rm -rf $tmp
}

print "test 5: halted fleet task never dispatches (S-002 intact)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    mkdir ([$tmp, "var", "mail"] | path join)
    mkdir ([$tmp, "var", "run"] | path join)
    # Tick-level halt lives in state.halted_tasks (marker file mirrors it).
    (
        "version = \"1\"\n" +
        "tick_count = 0\n" +
        "fsm_state = \"idle\"\n" +
        "seen_ids = []\n" +
        "last_tick_at = \"2026-01-01T00:00:00Z\"\n" +
        "pending_request_id = \"\"\n" +
        "pending_task_id = \"\"\n" +
        "pending_to_addr = \"\"\n" +
        "dispatched_at = \"\"\n" +
        "halted_tasks = [\"t-fleet-5\"]\n\n" +
        "[attempt_counts]\n"
    ) | save --force $state_abs
    "task_id = \"t-fleet-5\"\n" | save --force ([$tmp, "var", "mail", "HALT.t-fleet-5"] | path join)
    write-spool $spool_abs (make-msg "user@smolfire.local" "fleet-builder-1@smolfire.local" "<req.fleet5@smolfire.local>" (fleet-request-body "t-fleet-5"))

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($r.stdout | str contains "dispatch_skipped_halted") "halt skip logged"
    assert (not ((open --raw $spool_abs) | str contains "action = \"dispatch\"")) "no dispatch appended"
    assert (not ($ssh_log | path exists)) "ssh never invoked"
    assert equal (read-state $state_abs | get fsm_state) "idle" "stays idle"

    ^rm -rf $tmp
}

print "test 6: fleet role with unknown tool → capability mismatch, no dispatch (S-004 intact)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let ssh_log = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    let body = $"task_id = \"t-fleet-6\"\ntools_required = [\"QuantumTeleport\"]\n\n[commands]\nrun = [\"echo no\"]\n\n[context_pointers]\nfleet_target = \"($FLEET_TARGET)\"\n"
    write-spool $spool_abs (make-msg "user@smolfire.local" "fleet-builder-1@smolfire.local" "<req.fleet6@smolfire.local>" $body)

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($r.stdout | str contains "dispatch_capability_mismatch") "§17 gate fires first"
    assert (not ((open --raw $spool_abs) | str contains "action = \"dispatch\"")) "no dispatch appended"
    assert (not ($ssh_log | path exists)) "ssh never invoked"
    assert equal (read-state $state_abs | get fsm_state) "idle" "stays idle"

    ^rm -rf $tmp
}

print "all tests passed"
