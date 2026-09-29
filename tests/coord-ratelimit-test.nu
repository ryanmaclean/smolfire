# SPDX-License-Identifier: Apache-2.0
# coord-ratelimit-test.nu — max-inflight backpressure caps (gastown parity)
#
# Covers: per-executor cap, global cap, harvest release (no leak), halted
# exemption, stale-slot aging, pending-slot exemption, S-003 escalation
# release, env overrides, atomic save/load round-trip, refusal paths.

# Inline assert helpers — avoids std library version sensitivity.
def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

# ── Helpers (same conventions as tests/coord-tick-test.nu) ───────────────────

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

# Run one coordinator tick, returning its stdout (TOML log events).
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
    }
}

def spool-has-dispatch [spool_abs: string] {
    open --raw $spool_abs | str contains "Message-ID: <coord."
}

# ── Tests ─────────────────────────────────────────────────────────────────────

print "ratelimit 1: over-cap dispatch blocked (per-executor)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req_id = "<req.rl1.new@host>"
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" $req_id 'task_id = "t-new"')
    write-state $state_abs ((base-state) | update inflight {
        "t-a": {executor: "vm", since_tick: 9}
        "t-b": {executor: "vm", since_tick: 10}
    })

    let out = with-env {SMOLFIRE_MAX_INFLIGHT_VM: "2"} {
        tick-raw $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    # Refused: back at idle, no dispatch appended, no slot taken ...
    assert equal $state.fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "over-cap tick must not append a dispatch"
    assert equal ($state.inflight | columns | length) 2
    assert (not ("t-new" in ($state.inflight | columns))) "refused task must not occupy a slot"
    # ... and the request stays UNSEEN so the next tick rediscovers it.
    assert (not ($req_id in $state.seen_ids)) "deferred request must stay unseen for rediscovery"
    assert ($out | str contains "dispatch_deferred_backpressure") "must log dispatch_deferred_backpressure"

    # Second tick is stable: still deferred, still no dispatch (level-triggered).
    with-env {SMOLFIRE_MAX_INFLIGHT_VM: "2"} {
        run-tick $tmp $state_rel $spool_rel
    }
    let state2 = read-state $state_abs
    assert equal $state2.fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "second tick must not dispatch either"

    ^rm -rf $tmp
}

print "ratelimit 2: global cap enforced (fleet entries count)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req_id = "<req.rl2.new@host>"
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" $req_id 'task_id = "t-new"')
    # One vm slot + one fleet slot: fleet entries occupy global capacity even
    # though tick-level selection only routes vm|jail today.
    write-state $state_abs ((base-state) | update inflight {
        "t-a": {executor: "vm", since_tick: 10}
        "t-b": {executor: "fleet", since_tick: 10}
    })

    with-env {SMOLFIRE_MAX_INFLIGHT: "2"} {
        run-tick $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "global-cap tick must not dispatch"
    assert equal ($state.inflight | columns | length) 2

    ^rm -rf $tmp
}

print "ratelimit 3: under-cap dispatch proceeds and takes a slot"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl3@host>" 'task_id = "t-ok"')
    write-state $state_abs ((base-state) | update inflight {
        "t-a": {executor: "vm", since_tick: 10}
    })

    with-env {SMOLFIRE_MAX_INFLIGHT_VM: "2"} {
        run-tick $tmp $state_rel $spool_rel
    }

    let state = read-state $state_abs
    assert equal $state.fsm_state "waiting"
    assert (spool-has-dispatch $spool_abs) "under-cap tick must dispatch"
    assert equal ($state.inflight | columns | length) 2
    assert equal ($state.inflight | get "t-ok" | get executor) "vm"

    ^rm -rf $tmp
}

print "ratelimit 4: harvest releases the slot (dispatch→harvest→0)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl4@host>" 'task_id = "t-h"')
    write-state $state_abs (base-state)

    run-tick $tmp $state_rel $spool_rel
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting"
    assert equal ($st1.inflight | columns) ["t-h"]

    # Agent replies pass to the coordinator dispatch.
    let reply = make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.rl4@host>" "task_id = \"t-h\"\nverdict = \"pass\"" --in-reply-to $st1.pending_request_id
    $reply | save --append $spool_abs
    run-tick $tmp $state_rel $spool_rel

    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle"
    assert (($st2.inflight | columns | is-empty)) "harvest must release the slot (no leak)"

    ^rm -rf $tmp
}

print "ratelimit 5: halted tasks never occupy slots"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl5@host>" 'task_id = "t-halted"')
    write-state $state_abs ((base-state) | update halted_tasks ["t-halted"])

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "halted task must not dispatch"
    assert (($state.inflight | columns | is-empty)) "halt-skipped task must not occupy a slot"

    ^rm -rf $tmp
}

print "ratelimit 6: stale and halted slots age out, fresh slots kept"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # No spool traffic: the prune sweep runs at tick entry regardless.
    write-state $state_abs ((base-state) | update tick_count 100 | update halted_tasks ["t-old-halted"] | update inflight {
        "t-stale": {executor: "vm", since_tick: 0}
        "t-fresh": {executor: "vm", since_tick: 99}
        "t-old-halted": {executor: "vm", since_tick: 99}
    })

    let out = tick-raw $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal ($state.inflight | columns | sort) ["t-fresh"]
    assert ($out | str contains "inflight_slot_reclaimed") "reclaims must be logged"

    ^rm -rf $tmp
}

print "ratelimit 7: pending slot exempt from the sweep while awaiting reply"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Ancient slot, but the FSM is still waiting on this task: harvest owns
    # the release, the sweep must not steal it.
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<other.rl7@host>" 'task_id = "other"' --in-reply-to "<seed@host>")
    write-state $state_abs ((base-state)
        | update tick_count 100
        | update fsm_state "waiting"
        | update pending_request_id "<req.rl7.pending@host>"
        | update pending_task_id "t-wait"
        | update pending_to_addr "builder@smolfire.local"
        | update inflight {"t-wait": {executor: "vm", since_tick: 0}})

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "waiting"
    assert equal ($state.inflight | columns) ["t-wait"]

    ^rm -rf $tmp
}

print "ratelimit 8: retry-budget-exhausted task releases slot on escalation"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir

    # pending_task_id exempts t-e from the entry sweep, isolating the
    # harvest-escalation release path: attempts=3 + fail → HALT + slot gone.
    write-spool $spool_abs (make-msg "agent@smolfire.local" "coordinator@smolfire.local" "<fail.rl8@host>" "verdict = \"fail\"\ntask_id = \"t-e\"")
    write-state $state_abs ((base-state)
        | update pending_task_id "t-e"
        | update attempt_counts {"t-e": 3}
        | update inflight {"t-e": {executor: "vm", since_tick: 10}})

    run-tick $tmp $state_rel $spool_rel

    let halt1 = [$tmp, "var", "mail", "HALT.t-e"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"] | path join
    assert (($halt1 | path exists) or ($halt2 | path exists)) "exhausted task must escalate to HALT"
    let state = read-state $state_abs
    assert (($state.inflight | columns | is-empty)) "escalation must release the slot"

    ^rm -rf $tmp
}

print "ratelimit 9: env overrides (zero cap, per-executor cap, garbage fallback)"
do {
    # 9a: global cap 0 blocks everything.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl9a@host>" 'task_id = "t-9a"')
    write-state $state_abs (base-state)
    with-env {SMOLFIRE_MAX_INFLIGHT: "0"} {
        run-tick $tmp $state_rel $spool_rel
    }
    assert equal (read-state $state_abs).fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "zero global cap must block dispatch"
    ^rm -rf $tmp

    # 9b: per-executor override tighter than the default (vm default 4).
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl9b@host>" 'task_id = "t-9b"')
    write-state $state_abs ((base-state) | update inflight {
        "t-a": {executor: "vm", since_tick: 10}
    })
    with-env {SMOLFIRE_MAX_INFLIGHT_VM: "1"} {
        run-tick $tmp $state_rel $spool_rel
    }
    assert equal (read-state $state_abs).fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "per-executor override must block dispatch"
    ^rm -rf $tmp

    # 9c: garbage override falls back to the const default (dispatch proceeds).
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl9c@host>" 'task_id = "t-9c"')
    write-state $state_abs ((base-state) | update inflight {
        "t-a": {executor: "vm", since_tick: 10}
    })
    with-env {SMOLFIRE_MAX_INFLIGHT: "banana"} {
        run-tick $tmp $state_rel $spool_rel
    }
    assert equal (read-state $state_abs).fsm_state "waiting"
    assert (spool-has-dispatch $spool_abs) "garbage override must fall back to defaults and dispatch"
    ^rm -rf $tmp
}

print "ratelimit 10: inflight survives the atomic save/load round-trip"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"

    write-state $state_abs ((base-state) | update inflight {
        "t-keep": {executor: "jail", since_tick: 7}
    })

    # No spool: idle tick only loads, sweeps (nothing due), and saves.
    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal ($state.inflight | get "t-keep" | get executor) "jail"
    assert equal ($state.inflight | get "t-keep" | get since_tick) 7
    # No torn-write orphans left behind by the atomic save.
    let orphans = try { glob $"($state_abs).tmp.*" } catch { [] }
    assert (($orphans | is-empty)) "atomic save must leave no tmp orphans"

    ^rm -rf $tmp
}

print "ratelimit 11: refusal paths never occupy slots"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let bad_exec = make-msg "user@smolfire.local" "builder@smolfire.local" "<req.rl11a@host>" 'task_id = "t-bad-exec"\nexecutor = "bogus"'
    let bad_caps = make-msg "coordinator@smolfire.local" "reviewer@smolfire.local" "<req.rl11b@host>" 'task_id = "t-bad-caps"\nagent_type = "reviewer"\ntools_required = ["Write", "Bash"]'
    write-spool $spool_abs ($bad_exec + "\n" + $bad_caps)
    write-state $state_abs (base-state)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert (not (spool-has-dispatch $spool_abs)) "refused requests must not dispatch"
    assert (($state.inflight | columns | is-empty)) "refused requests must not occupy slots"

    ^rm -rf $tmp
}

print "all ratelimit tests passed"
