# SPDX-License-Identifier: Apache-2.0
# coord-concurrent-pendings-test.nu — per-executor pending slots acceptance
# (docs/CONCURRENT-PENDINGS-DESIGN.md §6).
#
# Covers: two-executor parallel green path, same-task-never-twice under
# crash injection (extends coord-double-dispatch-test.nu), halt/retry/
# heartbeat interplay, SMOLFIRE_CONCURRENT=0 kill-switch restoring
# single-pending, and legacy scalar state migration.
#
# Nushell only (no-new-python policy). No hardware touches; fleet dispatch
# uses the stub-ssh PATH shim from coord-tick-fleet-route-test.nu.

def "assert equal" [left: any, right: any, msg: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

def write-state [path: string, state: record] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $state | to toml | save --force $path
}
def read-state [path: string] { open --raw $path | from toml }

def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

def make-msg [
    from_addr: string
    to_addr: string
    message_id: string
    body: string
    --in-reply-to: string = ""
] {
    mut header_lines = [
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ]
    if $in_reply_to != "" {
        $header_lines = $header_lines | append $"In-Reply-To: ($in_reply_to)"
    }
    ($header_lines | str join "\n") + "\n\n" + $body + "\n"
}

def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

def write-ssh-stub [dir: string] {
    let log = [$dir, "ssh.log"] | path join
    let ssh_stub = [$dir, "ssh"] | path join
    $"#!/bin/sh\nlog=\"($log)\"\necho \"$@\" >> \"$log\"\necho \"stub-stdout for: $@\"\nexit 0\n" | save --force $ssh_stub
    ^chmod +x $ssh_stub
    $log
}

# Run one tick with explicit env toggles. Returns the completed process
# (exit_code + stdout). Fleet children inherit PATH, so the stub dir leads.
def run-tick [root: string, stub_dir: string, --fleet, --sequential] {
    let nu_bin = $nu.current-exe
    let base_path = strip-agent-bins ($env.PATH | split row ":" | where {|d| $d != "" })
    let full_path = ([$stub_dir] | append $base_path | str join ":")
    with-env {PATH: $full_path, SMOLFIRE_FLEET_TIMEOUT_BIN: ""} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_EXECUTOR
        if $fleet { with-env {SMOLFIRE_FLEET_ENABLE: "1"} {
            if $sequential { with-env {SMOLFIRE_CONCURRENT: "0"} {
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
            } } else {
                hide-env -i SMOLFIRE_CONCURRENT
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
            }
        } } else {
            hide-env -i SMOLFIRE_FLEET_ENABLE
            if $sequential { with-env {SMOLFIRE_CONCURRENT: "0"} {
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
            } } else {
                hide-env -i SMOLFIRE_CONCURRENT
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $root | complete)
            }
        }
    }
}

def wait-for-fleet-reply [spool_abs: string, timeout_sec: int = 25] {
    mut waited = 0
    while $waited < $timeout_sec {
        let content = try { open --raw $spool_abs } catch { "" }
        if ($content | str contains "fleet-agent@smolfire.local") { return true }
        sleep 1sec
        $waited = $waited + 1
    }
    false
}

def count-coord-dispatches [spool_abs: string] {
    let content = try { open --raw $spool_abs } catch { "" }
    ($content | split row "Message-ID: <coord." | length) - 1
}

def slot-of [state: record, executor: string] {
    $state.pending_slots | get $executor
}

def base-state [] {
    {
        version:            "1"
        tick_count:         10
        fsm_state:          "idle"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
        dispatched_at:      ""
        attempt_counts:     {}
        halted_tasks:       []
        task_executors:     {}
        inflight:           {}
        workers:            {}
    }
}

const FLEET_TARGET = "tester@fleet-stub.test"

def fleet-body [task_id: string] {
    $"task_id = \"($task_id)\"\nexecutor = \"fleet\"\ntools_required = [\"Bash\"]\n\n[commands]\nrun = [\"echo fleet-ok\"]\n\n[context_pointers]\nfleet_target = \"($FLEET_TARGET)\"\n"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

print "pendings 1: two-executor parallel green path (vm + fleet in one tick)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    write-spool $spool_abs ((make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp1.vm@host>" 'task_id = "t-cp-vm"') + (make-msg "user@smolfire.local" "fleet-builder-9@smolfire.local" "<req.cp1.fleet@host>" (fleet-body "t-cp-fleet")))
    write-state $state_abs (base-state)

    let r1 = run-tick $tmp $stub_dir --fleet
    assert equal $r1.exit_code 0 "tick1 exits 0"
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting" "parallel dispatch ends in waiting"
    assert equal (slot-of $st1 "vm" | get task_id) "t-cp-vm" "vm slot holds the vm task"
    assert equal (slot-of $st1 "fleet" | get task_id) "t-cp-fleet" "fleet slot holds the fleet task"
    assert ((slot-of $st1 "vm" | get request_id | str starts-with "<coord.") ) "vm slot carries the dispatch id"
    assert ((slot-of $st1 "fleet" | get request_id | str starts-with "<coord.") ) "fleet slot carries the dispatch id"
    assert equal (count-coord-dispatches $spool_abs) 2 "exactly two dispatch messages appended in one tick"

    # Fleet child replies asynchronously via stub ssh; the vm reply is
    # crafted (vm spawn is hermetic-skipped, so no vm child ever answers).
    assert (wait-for-fleet-reply $spool_abs) "detached fleet child answered"
    let st1b = read-state $state_abs
    let vm_reply = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.cp1.vm@host>" "task_id = \"t-cp-vm\"\nverdict = \"pass\"" --in-reply-to (slot-of $st1b "vm" | get request_id)
    $vm_reply | save --append $spool_abs

    let r2 = run-tick $tmp $stub_dir --fleet
    assert equal $r2.exit_code 0 "tick2 exits 0"
    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle" "both replies harvested to idle"
    assert equal (slot-of $st2 "vm" | get task_id) "" "vm slot drained"
    assert equal (slot-of $st2 "fleet" | get task_id) "" "fleet slot drained"
    assert (($st2.inflight | columns | is-empty)) "no inflight leak"
    assert (($st2.attempt_counts | columns | is-empty)) "no attempt leak"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 2: crash injection with 2 slots — zero re-dispatch, both resume"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    # On-disk state is pre-dispatch (idle, stale seen_ids): the crash lost
    # the harvest stamps. The spool already holds both coordinator
    # dispatches, unanswered.
    let req_a = make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp2.a@host>" 'task_id = "t-a"'
    let req_b = make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp2.b@host>" "task_id = \"t-b\"\nexecutor = \"fleet\""
    let disp_a = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<disp.cp2.a@host>" 'task_id = "t-a"
action = "dispatch"
executor = "vm"' --in-reply-to "<req.cp2.a@host>"
    let disp_b = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<disp.cp2.b@host>" 'task_id = "t-b"
action = "dispatch"
executor = "fleet"' --in-reply-to "<req.cp2.b@host>"
    write-spool $spool_abs ($req_a + $req_b + $disp_a + $disp_b)
    write-state $state_abs (base-state)
    let spool_before = open --raw $spool_abs

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    assert equal (open --raw $spool_abs) $spool_before "restart appends zero bytes"
    assert ($r.stdout | str contains "dispatch_skipped_inflight") "per-slot S-012 guard fired"
    let st = read-state $state_abs
    assert equal $st.fsm_state "waiting" "both slots resume waiting"
    assert equal (slot-of $st "vm" | get task_id) "t-a" "vm slot resumed"
    assert equal (slot-of $st "vm" | get request_id) "<disp.cp2.a@host>" "vm slot resumes the existing dispatch id"
    assert equal (slot-of $st "fleet" | get task_id) "t-b" "fleet slot resumed"
    assert equal (slot-of $st "fleet" | get request_id) "<disp.cp2.b@host>" "fleet slot resumes the existing dispatch id"
    assert (($st.attempt_counts | columns | is-empty)) "resume burns no attempts"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 3: same task in two requests dispatches once, second defers unseen"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    write-spool $spool_abs ((make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp3.vm@host>" 'task_id = "t-dup"') + (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp3.fleet@host>" "task_id = \"t-dup\"\nexecutor = \"fleet\""))
    write-state $state_abs (base-state)

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($r.stdout | str contains "dispatch_skipped_duplicate_task") "duplicate refused and logged"
    assert equal (count-coord-dispatches $spool_abs) 1 "exactly one dispatch for the duplicated task"
    let st = read-state $state_abs
    assert equal (slot-of $st "vm" | get task_id) "t-dup" "first request fills its slot"
    assert equal (slot-of $st "fleet" | get task_id) "" "same task never occupies a second slot"
    assert (not ("<req.cp3.fleet@host>" in $st.seen_ids)) "duplicate trigger stays unseen for rediscovery"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 4: HALT on slot A clears only A; slot B accepts in the same run"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    mkdir ([$tmp, "var", "mail"] | path join)

    let fail_a = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<fail.cp4.a@host>" "task_id = \"t-ha\"\nverdict = \"fail\""
    let pass_b = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<pass.cp4.b@host>" "task_id = \"t-hb\"\nverdict = \"pass\""
    write-spool $spool_abs ($fail_a + $pass_b)
    write-state $state_abs ((base-state)
        | update attempt_counts {"t-ha": 3}
        | update task_executors {"t-ha": {executor: "vm", network: false, request_id: "<req.cp4.a@host>"}, "t-hb": {executor: "fleet", network: false, request_id: "<req.cp4.b@host>"}}
        | update inflight {"t-ha": {executor: "vm", since_tick: 10}, "t-hb": {executor: "fleet", since_tick: 10}})

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    assert (([$tmp, "var", "mail", "HALT.t-ha"] | path join) | path exists) "exhausted task escalates to HALT"
    assert (not (([$tmp, "var", "mail", "HALT.t-hb"] | path join) | path exists)) "accepted task never halts"
    let st = read-state $state_abs
    assert equal $st.fsm_state "idle" "run ends idle"
    assert equal (slot-of $st "vm" | get task_id) "" "halted task frees its slot"
    assert equal (slot-of $st "fleet" | get task_id) "" "accepted task frees its slot"
    assert ("t-ha" in $st.halted_tasks) "halt recorded per-task"
    assert (not ("t-hb" in $st.halted_tasks)) "accepted task not halted"
    assert equal (count-coord-dispatches $spool_abs) 0 "halt/accept appends no dispatch"
    assert (($st.inflight | columns | is-empty)) "no inflight leak"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 5: fail, fail, pass retries through the same slot then accepts"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp5@host>" 'task_id = "t-rt"')
    write-state $state_abs (base-state)
    run-tick $tmp $stub_dir | ignore
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting" "request dispatched"
    let d1 = slot-of $st1 "vm" | get request_id

    for i in [1 2] {
        let fail_id = "<fail.cp5." + ($i | into string) + "@host>"
        let f = make-msg "builder@smolfire.local" "coordinator@smolfire.local" $fail_id "task_id = \"t-rt\"\nverdict = \"fail\"" --in-reply-to (slot-of (read-state $state_abs) "vm" | get request_id)
        $f | save --append $spool_abs
        let r = run-tick $tmp $stub_dir
        assert equal $r.exit_code 0 $"retry tick ($i) exits 0"
        let st = read-state $state_abs
        assert equal $st.fsm_state "waiting" $"fail ($i) retries to waiting"
        assert equal (slot-of $st "vm" | get task_id) "t-rt" $"retry ($i) reuses the vm slot"
        assert ((slot-of $st "vm" | get request_id) != $d1) $"retry ($i) carries a fresh dispatch id"
    }
    assert equal ((read-state $state_abs).attempt_counts | get "t-rt") 3 "two fails + initial dispatch = 3 attempts"

    let p = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<pass.cp5@host>" "task_id = \"t-rt\"\nverdict = \"pass\"" --in-reply-to (slot-of (read-state $state_abs) "vm" | get request_id)
    $p | save --append $spool_abs
    let r = run-tick $tmp $stub_dir
    assert equal $r.exit_code 0 "pass tick exits 0"
    let st = read-state $state_abs
    assert equal $st.fsm_state "idle" "pass harvests to idle"
    assert equal (slot-of $st "vm" | get task_id) "" "accept frees the slot"
    assert (not ("t-rt" in ($st.attempt_counts | columns))) "accept clears the budget"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 6: attempts == 3 escalates and frees the slot"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    mkdir ([$tmp, "var", "mail"] | path join)

    write-spool $spool_abs (make-msg "agent@smolfire.local" "coordinator@smolfire.local" "<fail.cp6@host>" "verdict = \"fail\"\ntask_id = \"t-e\"")
    write-state $state_abs ((base-state)
        | update attempt_counts {"t-e": 3}
        | update task_executors {"t-e": {executor: "vm", network: false, request_id: "<req.cp6@host>"}}
        | update inflight {"t-e": {executor: "vm", since_tick: 10}})

    let r = run-tick $tmp $stub_dir
    assert equal $r.exit_code 0 "tick exits 0"
    assert (([$tmp, "var", "mail", "HALT.t-e"] | path join) | path exists) "budget edge escalates"
    let st = read-state $state_abs
    assert (($st.inflight | columns | is-empty)) "escalation releases the inflight slot"
    assert equal (slot-of $st "vm" | get task_id) "" "escalation frees the pending slot"
    assert equal $st.fsm_state "idle" "ends idle"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 7: dead fleet worker reaps only its tasks; live vm slot untouched"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    # t-flt is a slot-less inflight orphan on the dead fleet worker (e.g.
    # pre-slot accounting); t-vm is slotted to the live vm worker.
    write-spool $spool_abs ""
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update task_executors {"t-flt": {executor: "fleet", network: false, request_id: "<req.cp7.flt@host>"}, "t-vm": {executor: "vm", network: false, request_id: "<req.cp7.vm@host>"}}
        | update inflight {"t-flt": {executor: "fleet", since_tick: 99}, "t-vm": {executor: "vm", since_tick: 99}}
        | update workers {"fleet": {last_seen_tick: 70, consecutive_failures: 0, dead: false}, "vm": {last_seen_tick: 100, consecutive_failures: 0, dead: false}})

    # Fleet cap 0 keeps the reaped retry deferred (no fleet spawn in test).
    let nu_bin = $nu.current-exe
    let base_path = strip-agent-bins ($env.PATH | split row ":" | where {|d| $d != "" })
    let full_path = ([$stub_dir] | append $base_path | str join ":")
    let out = with-env {PATH: $full_path, SMOLFIRE_FLEET_TIMEOUT_BIN: "", SMOLFIRE_FLEET_ENABLE: "1", SMOLFIRE_WORKER_DEAD_TICKS: "10", SMOLFIRE_MAX_INFLIGHT_FLEET: "0"} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        ^$nu_bin --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --root $tmp
    }

    let st = read-state $state_abs
    assert equal ($st.workers | get "fleet" | get dead) true "stale fleet worker marked dead"
    assert ($out | str contains "worker_marked_dead") "dead event emitted"
    assert (not ("t-flt" in ($st.inflight | columns))) "reaped task released"
    assert ("t-vm" in ($st.inflight | columns)) "live worker inflight untouched"
    assert ((open --raw $spool_abs | str contains "deadreap") ) "synthetic fail queued"
    assert ((open --raw $spool_abs | str contains 'task_id = "t-flt"')) "reaped identity preserved"
    assert equal ($st.attempt_counts | get -o "t-flt" | default 0) 0 "reap burns no budget"
    assert (not (([$tmp, "var", "mail", "HALT.t-flt"] | path join) | path exists)) "reap never halts"
    assert equal ($st.workers | get "vm" | get dead) false "live worker stays alive"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 8: fleet round trip resurrects the dead worker"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    write-spool $spool_abs (make-msg "fleet-agent@smolfire.local" "coordinator@smolfire.local" "<reply.cp8@host>" "task_id = \"t-fr\"\nverdict = \"pass\"")
    write-state $state_abs ((base-state)
        | update task_executors {"t-fr": {executor: "fleet", network: false, request_id: "<req.cp8@host>"}}
        | update workers {"fleet": {last_seen_tick: 2, consecutive_failures: 4, dead: true}})

    let r = run-tick $tmp $stub_dir --fleet
    assert equal $r.exit_code 0 "tick exits 0"
    let st = read-state $state_abs
    assert equal ($st.workers | get "fleet" | get dead) false "success clears dead"
    assert equal ($st.workers | get "fleet" | get consecutive_failures) 0 "success resets failures"
    assert ($r.stdout | str contains "worker_resurrected") "resurrection event emitted"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 9: legacy scalar state backfills the slot and resumes waiting"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    # Pre-slot state file: no pending_slots key at all.
    write-state $state_abs {
        version:            "1"
        tick_count:         10
        fsm_state:          "waiting"
        seen_ids:           ["<other.cp9@host>"]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: "<disp.cp9@host>"
        pending_task_id:    "t-legacy"
        pending_to_addr:    "builder@smolfire.local"
        dispatched_at:      "2026-09-28T00:00:00Z"
        attempt_counts:     {"t-legacy": 1}
        halted_tasks:       []
        task_executors:     {"t-legacy": {executor: "vm", network: false, request_id: "<req.cp9@host>"}}
        inflight:           {"t-legacy": {executor: "vm", since_tick: 10}}
    }

    let r1 = run-tick $tmp $stub_dir
    assert equal $r1.exit_code 0 "tick1 exits 0"
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting" "legacy wait resumes as waiting"
    assert equal (slot-of $st1 "vm" | get task_id) "t-legacy" "legacy triple backfilled into the vm slot"
    assert equal (slot-of $st1 "vm" | get request_id) "<disp.cp9@host>" "same dispatch id, no re-dispatch"
    assert equal (count-coord-dispatches $spool_abs) 0 "migration appends nothing"

    # The resumed dispatch drains normally: a pass reply harvests to idle.
    mkdir ([$tmp, "var", "mail"] | path join)
    let reply = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.cp9@host>" "task_id = \"t-legacy\"\nverdict = \"pass\"" --in-reply-to "<disp.cp9@host>"
    $reply | save --append $spool_abs
    let r2 = run-tick $tmp $stub_dir
    assert equal $r2.exit_code 0 "tick2 exits 0"
    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle" "resumed dispatch drains to idle"
    assert equal (slot-of $st2 "vm" | get task_id) "" "slot freed on harvest"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 10: SMOLFIRE_CONCURRENT=0 restores sequential drain"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let spool_abs = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    write-spool $spool_abs ((make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp10.vm@host>" 'task_id = "t-s1"') + (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.cp10.fleet@host>" "task_id = \"t-s2\"\nexecutor = \"fleet\""))
    write-state $state_abs (base-state)

    let r1 = run-tick $tmp $stub_dir --fleet --sequential
    assert equal $r1.exit_code 0 "tick1 exits 0"
    assert equal (count-coord-dispatches $spool_abs) 1 "kill-switch dispatches exactly one"
    let st1 = read-state $state_abs
    assert equal (slot-of $st1 "vm" | get task_id) "t-s1" "first request fills its slot"
    assert equal (slot-of $st1 "fleet" | get task_id) "" "second request waits"
    assert (not ("<req.cp10.fleet@host>" in $st1.seen_ids)) "second request stays unseen"

    let r2 = run-tick $tmp $stub_dir --fleet --sequential
    assert equal $r2.exit_code 0 "tick2 exits 0"
    assert equal (count-coord-dispatches $spool_abs) 1 "occupied slot blocks refill"

    # Drain the first dispatch, then the second flows in the same run.
    let reply = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.cp10.s1@host>" "task_id = \"t-s1\"\nverdict = \"pass\"" --in-reply-to (slot-of (read-state $state_abs) "vm" | get request_id)
    $reply | save --append $spool_abs
    let r3 = run-tick $tmp $stub_dir --fleet --sequential
    assert equal $r3.exit_code 0 "tick3 exits 0"
    let st3 = read-state $state_abs
    assert equal (slot-of $st3 "vm" | get task_id) "" "first slot drained"
    assert equal (slot-of $st3 "fleet" | get task_id) "t-s2" "second dispatch flows after drain"
    assert equal (count-coord-dispatches $spool_abs) 2 "sequential second dispatch"
    assert equal $st3.fsm_state "waiting" "ends waiting on the second dispatch"

    ^rm -rf $tmp
    print "  ok"
}

print "pendings 11: fresh state carries one empty slot per known executor"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "stubbin"] | path join)
    let stub_dir = [$tmp, "stubbin"] | path join
    let _ = write-ssh-stub $stub_dir
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join

    let r = run-tick $tmp $stub_dir
    assert equal $r.exit_code 0 "tick exits 0"
    let st = read-state $state_abs
    assert equal ($st.pending_slots | columns | sort) ["fleet" "jail" "vm"] "one slot per known executor"
    assert equal (slot-of $st "vm" | get task_id) "" "vm slot starts empty"
    assert equal (slot-of $st "jail" | get task_id) "" "jail slot starts empty"
    assert equal (slot-of $st "fleet" | get task_id) "" "fleet slot starts empty"

    ^rm -rf $tmp
    print "  ok"
}

print "all concurrent-pendings tests passed"
