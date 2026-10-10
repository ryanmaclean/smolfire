# SPDX-License-Identifier: Apache-2.0
# coord-heartbeat-test.nu — worker heartbeat + dead-worker detection (gastown parity)
#
# Design under test (see bin/coord-tick.nu "Worker heartbeat" section):
#   - `workers: {<executor>: {last_seen_tick, consecutive_failures, dead}}`
#     lives in the crash-atomic state file.
#   - Heartbeats are observations of REAL worker traffic (piggyback, no pings):
#       * state-waiting reply-received (a dispatch round trip completed), and
#       * state-harvesting accept (pass verdict).
#     Dispatch SEND does NOT heartbeat: a coordinator-side spool append is not
#     worker liveness, and heartbeating on send would resurrect a dead worker
#     in the same tick its reaped tasks redispatch (dead-marking could never
#     stick). Harvested fail/blocked/malformed verdicts bump
#     consecutive_failures without touching last_seen_tick.
#   - A worker with inflight tasks and no successful round trip for
#     SMOLFIRE_WORKER_DEAD_TICKS (default 20) is marked dead (edge-triggered
#     `worker_marked_dead` diagnostic); its eligible inflight tasks are
#     reaped to the REAL retry path via synthetic fail replies (attempts
#     increment through the D2 table, never dropped, budget never bypassed).
#   - Reaping releases the slot AND queues the retry atomically in the same
#     tick (single save-state), so dead-worker tasks occupy slots until the
#     reap tick — never double-dispatched, never leaked.
#   - Already-dead workers' new inflight is silently re-reaped each tick
#     (`worker_tasks_reaped`, no repeat `worker_marked_dead` — no storms).
#   - Halt-skipped (S-002) dispatches never touch heartbeat state.

def "assert equal" [left: any, right: any, msg: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

def make-temp-dir [] {
    ^mktemp -d | str trim
}

def write-state [path: string, state: record] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $state | to toml | save --force $path
}

def read-state [path: string] {
    open --raw $path | from toml
}

def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

def tick-raw [root: string, state_rel: string, spool_rel: string] {
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        ^$nu_bin --no-config-file bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $root
    }
}

def run-tick [root: string, state_rel: string, spool_rel: string] {
    tick-raw $root $state_rel $spool_rel | ignore
}

def make-msg [
    from_addr:  string
    to_addr:    string
    message_id: string
    body:       string
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

def issued-dispatch [task: string, dispatch_id: string, --to: string = "agent@smolfire.local", --executor: string = "vm"] {
    make-msg "coordinator@smolfire.local" $to $dispatch_id $"task_id = \"($task)\"\naction = \"dispatch\"\nexecutor = \"($executor)\""
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

def get-workers [state: record] {
    $state | get -o workers | default {}
}

# ── Tests ─────────────────────────────────────────────────────────────────────

print "heartbeat 1: full dispatch round trip records a heartbeat"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.hb1@host>" 'task_id = "t-hb1"')
    write-state $state_abs (base-state)

    run-tick $tmp $state_rel $spool_rel
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting" "round trip starts with a dispatch"
    # Dispatch SEND is coordinator-side traffic, not worker liveness: no
    # heartbeat yet (anti-false-alive — see file header).
    assert ((get-workers $st1 | columns | is-empty)) "dispatch send alone must not heartbeat"

    let reply = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.hb1@host>" "task_id = \"t-hb1\"\nverdict = \"pass\"" --in-reply-to $st1.pending_request_id
    $reply | save --append $spool_abs
    let out = tick-raw $tmp $state_rel $spool_rel

    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle" "pass reply harvests to idle"
    let w = get-workers $st2 | get "vm"
    assert equal $w.last_seen_tick $st2.tick_count "heartbeat stamps the completing tick"
    assert equal $w.consecutive_failures 0 "success resets failures"
    assert equal ($w | get -o dead | default false) false "worker alive"

    ^rm -rf $tmp
}

print "heartbeat 2: harvest accept heartbeats the task's recorded executor"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let dispatch_id = "<dispatch.hb2@host>"
    write-spool $spool_abs ((issued-dispatch "t-hb2" $dispatch_id --executor "jail") + (make-msg "agent@smolfire.local" "coordinator@smolfire.local" "<reply.hb2@host>" "task_id = \"t-hb2\"\nverdict = \"pass\"" --in-reply-to $dispatch_id))
    write-state $state_abs ((base-state) | update seen_ids [$dispatch_id] | update task_executors {"t-hb2": {executor: "jail", network: false, request_id: "<req.hb2@host>", current_dispatch_id: $dispatch_id}})

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal (get-workers $state | get "jail" | get last_seen_tick) $state.tick_count "harvest heartbeats jail executor"

    ^rm -rf $tmp
}

print "heartbeat 3: harvested fail bumps consecutive_failures without refreshing last_seen"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let dispatch_id = "<dispatch.hb3@host>"
    write-spool $spool_abs ((issued-dispatch "t-hb3" $dispatch_id) + (make-msg "agent@smolfire.local" "coordinator@smolfire.local" "<fail.hb3@host>" "verdict = \"fail\"\ntask_id = \"t-hb3\"" --in-reply-to $dispatch_id))
    write-state $state_abs ((base-state)
        | update seen_ids [$dispatch_id]
        | update task_executors {"t-hb3": {executor: "vm", network: false, request_id: "<req.hb3@host>", current_dispatch_id: $dispatch_id}}
        | update workers {"vm": {last_seen_tick: 10, consecutive_failures: 0, dead: false}})

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    let w = get-workers $state | get "vm"
    assert equal $w.consecutive_failures 1 "fail verdict increments failures"
    assert equal $w.last_seen_tick 10 "failure is not liveness: last_seen untouched"
    assert equal $state.fsm_state "waiting" "fail still enters the retry path"

    ^rm -rf $tmp
}

print "heartbeat 4: worker with stale heartbeat and inflight tasks is marked dead"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Seeded waiting on an unrelated task: the FSM stays in waiting, so the
    # reap mechanics below are isolated from harvest-redispatch in this tick.
    let dispatch_id = "<dispatch.hb4.d1@host>"
    write-spool $spool_abs ((issued-dispatch "t-d1" $dispatch_id) + (make-msg "user@smolfire.local" "builder@smolfire.local" "<other.hb4@host>" 'task_id = "other"' --in-reply-to "<seed@host>"))
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update fsm_state "waiting"
        | update seen_ids [$dispatch_id]
        | update pending_request_id "<req.hb4.pending@host>"
        | update pending_task_id "t-other"
        | update pending_to_addr "builder@smolfire.local"
        | update inflight {
            "t-d1": {executor: "vm", since_tick: 95}
            "t-other": {executor: "vm", since_tick: 99}
          }
        | update task_executors {"t-d1": {executor: "vm", network: false, request_id: "<req.hb4.d1@host>", current_dispatch_id: $dispatch_id}}
        | update workers {"vm": {last_seen_tick: 70, consecutive_failures: 2, dead: false}})

    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal (get-workers $state | get "vm" | get dead) true "stale worker marked dead"
    assert ($out | str contains "worker_marked_dead") "must emit worker_marked_dead"
    assert ($out | str contains "t-d1") "event names the reaped task"
    # Reap: slot released AND synthetic fail queued (requeue), task NOT dropped...
    assert (not ("t-d1" in ($state.inflight | columns))) "reaped task slot released"
    assert ((open --raw $spool_abs | str contains "deadreap") ) "synthetic fail reply queued in spool"
    assert ((open --raw $spool_abs | str contains 'task_id = "t-d1"')) "reaped task identity preserved"
    # ...NOT auto-escalated: no HALT, attempts untouched (increment happens
    # through the real retry path on a later harvest, never here).
    assert (not (([$tmp, "var", "mail", "HALT.t-d1"] | path join) | path exists)) "reap must not HALT"
    assert equal ($state.attempt_counts | get -o "t-d1" | default 0) 0 "reap itself does not burn budget"
    # The pending task is owned by state-waiting: exempt from the reap.
    assert ("t-other" in ($state.inflight | columns)) "pending task exempt from reap"

    ^rm -rf $tmp
}

print "heartbeat 5: reaped task re-enters the real retry path with attempts incremented"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Idle tick: entry sweep reaps, then the same tick's FSM harvests the
    # synthetic fail and redispatches through the D2 table.
    let dispatch_id = "<dispatch.hb5.r@host>"
    write-spool $spool_abs (issued-dispatch "t-r" $dispatch_id)
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update seen_ids [$dispatch_id]
        | update task_executors {"t-r": {executor: "vm", network: false, request_id: "<req.r@host>", current_dispatch_id: $dispatch_id}}
        | update inflight {"t-r": {executor: "vm", since_tick: 90}}
        | update workers {"vm": {last_seen_tick: 70, consecutive_failures: 0, dead: false}})

    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal (get-workers $state | get "vm" | get dead) true "worker marked dead"
    assert ($out | str contains "worker_marked_dead") "dead event emitted"
    assert equal $state.fsm_state "waiting" "reaped task redispatched in the same tick"
    assert equal $state.pending_task_id "t-r" "redispatched task is the reaped one"
    assert equal ($state.attempt_counts | get "t-r") 1 "attempts incremented once via the retry path"
    let halt_path = [$tmp, "var", "mail", "HALT.t-r"] | path join
    assert (not ($halt_path | path exists)) "no escalation inside budget"

    ^rm -rf $tmp
}

print "heartbeat 6: reap at the budget edge increments to 3 without escalating"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let dispatch_id = "<dispatch.hb6.e@host>"
    write-spool $spool_abs (issued-dispatch "t-e" $dispatch_id)
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update seen_ids [$dispatch_id]
        | update attempt_counts {"t-e": 2}
        | update task_executors {"t-e": {executor: "vm", network: false, request_id: "<req.e@host>", current_dispatch_id: $dispatch_id}}
        | update inflight {"t-e": {executor: "vm", since_tick: 90}}
        | update workers {"vm": {last_seen_tick: 70, consecutive_failures: 0, dead: false}})

    with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        run-tick $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal ($state.attempt_counts | get "t-e") 3 "third attempt dispatched, budget respected"
    assert equal $state.fsm_state "waiting" "still dispatchable at exactly 3"
    assert (not (([$tmp, "var", "mail", "HALT.t-e"] | path join) | path exists)) "reap never escalates past budget by itself"

    ^rm -rf $tmp
}

print "heartbeat 7: any successful round trip resurrects a dead worker"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let dispatch_id = "<dispatch.hb7@host>"
    write-spool $spool_abs ((issued-dispatch "t-hb7" $dispatch_id) + (make-msg "agent@smolfire.local" "coordinator@smolfire.local" "<reply.hb7@host>" "task_id = \"t-hb7\"\nverdict = \"pass\"" --in-reply-to $dispatch_id))
    write-state $state_abs ((base-state)
        | update seen_ids [$dispatch_id]
        | update task_executors {"t-hb7": {executor: "vm", network: false, request_id: "<req.hb7@host>", current_dispatch_id: $dispatch_id}}
        | update workers {"vm": {last_seen_tick: 2, consecutive_failures: 4, dead: true}})

    let out = tick-raw $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal (get-workers $state | get "vm" | get dead) false "success clears dead status"
    assert equal (get-workers $state | get "vm" | get consecutive_failures) 0 "success resets failures"
    assert ($out | str contains "worker_resurrected") "must emit worker_resurrected"

    # Second tick: nothing new — no repeat resurrection event (no flapping storm).
    let out2 = tick-raw $tmp $state_rel $spool_rel
    assert (not ($out2 | str contains "worker_resurrected")) "resurrection is edge-triggered"

    ^rm -rf $tmp
}

print "heartbeat 8: dead marking is edge-triggered — no repeat storms"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<other.hb8@host>" 'task_id = "other"' --in-reply-to "<seed@host>")
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update fsm_state "waiting"
        | update pending_request_id "<req.hb8.pending@host>"
        | update pending_task_id "t-other"
        | update pending_to_addr "builder@smolfire.local"
        | update inflight {"t-other": {executor: "vm", since_tick: 99}}
        | update workers {"vm": {last_seen_tick: 70, consecutive_failures: 0, dead: false}})

    let out1 = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }
    assert ($out1 | str contains "worker_marked_dead") "first tick marks dead"

    # t-other is pending-exempt, so nothing eligible remains: second tick is silent.
    let out2 = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }
    assert (not ($out2 | str contains "worker_marked_dead")) "no repeat dead event"

    ^rm -rf $tmp
}

print "heartbeat 9: already-dead workers are silently re-reaped without new dead events"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let dispatch_id = "<dispatch.hb9.x@host>"
    write-spool $spool_abs (issued-dispatch "t-x" $dispatch_id)
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update seen_ids [$dispatch_id]
        | update task_executors {"t-x": {executor: "vm", network: false, request_id: "<req.x@host>", current_dispatch_id: $dispatch_id}}
        | update inflight {"t-x": {executor: "vm", since_tick: 99}}
        | update workers {"vm": {last_seen_tick: 50, consecutive_failures: 0, dead: true}})

    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }

    assert (not ($out | str contains "worker_marked_dead")) "no repeat dead event for an already-dead worker"
    assert ($out | str contains "worker_tasks_reaped") "silent re-reap is still observable"
    let state = read-state $state_abs
    assert equal $state.pending_task_id "t-x" "re-reaped task re-enters retry promptly"
    assert equal ($state.attempt_counts | get "t-x") 1 "attempts increment through the retry path"

    ^rm -rf $tmp
}

print "heartbeat 10: idle workers without inflight are never marked dead"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs ""
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update workers {"vm": {last_seen_tick: 10, consecutive_failures: 0, dead: false}})

    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        tick-raw $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal (get-workers $state | get "vm" | get dead) false "idle worker stays alive"
    assert (not ($out | str contains "worker_marked_dead")) "no dead event without outstanding work"

    ^rm -rf $tmp
}

print "heartbeat 11: env override sets the threshold; garbage falls back to the default"
do {
    # 11a: tight override trips early.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join
    write-spool $spool_abs ""
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update inflight {"t-11a": {executor: "vm", since_tick: 99}}
        | update workers {"vm": {last_seen_tick: 97, consecutive_failures: 0, dead: false}})
    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "2"} {
        tick-raw $tmp $state_rel $spool_rel
    }
    assert equal (get-workers (read-state $state_abs) | get "vm" | get dead) true "override threshold trips at age 3 >= 2"
    assert ($out | str contains "worker_marked_dead") "override dead event"
    ^rm -rf $tmp

    # 11b: garbage override falls back to the default (20): age 5 stays alive.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join
    write-spool $spool_abs ""
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update inflight {"t-11b": {executor: "vm", since_tick: 99}}
        | update workers {"vm": {last_seen_tick: 95, consecutive_failures: 0, dead: false}})
    let out = with-env {SMOLFIRE_WORKER_DEAD_TICKS: "banana"} {
        tick-raw $tmp $state_rel $spool_rel
    }
    assert equal (get-workers (read-state $state_abs) | get "vm" | get dead) false "garbage falls back to default 20"
    assert (not ($out | str contains "worker_marked_dead")) "no dead event under fallback"
    ^rm -rf $tmp
}

print "heartbeat 12: halt-skipped dispatches never touch heartbeat state"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.hb12@host>" 'task_id = "t-hb12"')
    write-state $state_abs ((base-state) | update halted_tasks ["t-hb12"])

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle" "halted task stays idle"
    assert ((get-workers $state | columns | is-empty)) "halt-skipped tick creates no heartbeat"

    ^rm -rf $tmp
}

print "heartbeat 13: legacy state files without a workers key keep working"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.hb13@host>" 'task_id = "t-hb13"')
    # No `workers` key: pre-heartbeat state file.
    write-state $state_abs {
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
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "waiting" "old file still dispatches"
    assert ((get-workers $state | columns | is-empty)) "no heartbeat on send, key backfilled silently"

    ^rm -rf $tmp
}

print "heartbeat 14: heartbeat and reap paths spawn no extra processes"
do {
    let tmp = make-temp-dir
    let stub_dir = [$tmp, "bin"] | path join
    mkdir $stub_dir
    let ssh_stub = [$stub_dir, "ssh"] | path join
    let ssh_log = [$stub_dir, "ssh.log"] | path join
    $"#!/bin/sh\necho \"$@\" >> \"($ssh_log)\"\nexit 0\n" | save --force $ssh_stub
    ^chmod +x $ssh_stub

    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # A full dead-detect + reap + redispatch cycle with a counting ssh stub
    # first on PATH: coord-tick must never invoke ssh (heartbeats are
    # observations of spool traffic, not probes).
    write-spool $spool_abs ""
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update task_executors {"t-ssh": {executor: "vm", network: false, request_id: "<req.ssh@host>"}}
        | update inflight {"t-ssh": {executor: "vm", since_tick: 90}}
        | update workers {"vm": {last_seen_tick: 70, consecutive_failures: 0, dead: false}})

    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: ([$stub_dir] | append ($hermetic_path | split row ":" | where {|d| $d != "" }) | str join ":"), SMOLFIRE_WORKER_DEAD_TICKS: "10"} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        ^$nu_bin --no-config-file bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $tmp | ignore
    }
    assert (not ($ssh_log | path exists)) "coord-tick (dispatch, sweep, reap) must never invoke ssh"

    # Baseline guard on the fleet dispatch path itself: stub ssh sees exactly
    # 1 preflight + N command invocations — the heartbeat change adds none.
    use ../bin/coord-fleet-dispatch.nu [run-fleet-task]
    mkdir ([$tmp, "w"] | path join)
    with-env {PATH: ([$stub_dir] | append ($env.PATH | split row ":" | where {|d| $d != "" }) | str join ":"), SMOLFIRE_FLEET_TIMEOUT_BIN: ""} {
        let res = run-fleet-task "t-base" ["echo hi", "uname -a"] --target "studio@10.0.2.42" --root ([$tmp, "w"] | path join)
        assert equal $res.verdict "pass" "baseline fleet dispatch still passes"
    }
    let calls = open --raw $ssh_log | lines | where {|l| ($l | str trim | str length) > 0 } | length
    assert equal $calls 3 "fleet baseline unchanged: 1 preflight + 2 commands, no heartbeat probes"

    ^rm -rf $tmp
}

print "all heartbeat tests passed"
