# SPDX-License-Identifier: Apache-2.0
# coord-double-dispatch-test.nu — §12 no-double-dispatch invariant
#
# Regression coverage for the crash-recovery guard in state-dispatching
# (bin/coord-tick.nu, find-inflight-dispatch): if the coordinator process
# is killed between appending a dispatch message to the spool (a real,
# immediate side effect) and the once-per-invocation save-state call at
# the very end of `tick`, a restart re-enters "dispatching" with the SAME
# pending_request_id (seen_ids on disk is equally stale, so the triggering
# request/retry-reply is rediscovered and re-derives an identical id).
# Without the guard this sends a second dispatch message and spawns a
# second real, billed subagent for work already in flight.

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool] {
    if not $cond { error make {msg: "assert failed"} }
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

def run-tick [root: string, state_rel: string, spool_rel: string] {
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        (^$nu_bin --no-config-file bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $root) | ignore
    }
}

def base-state [] {
    {
        version:            "1"
        tick_count:         1
        fsm_state:          "dispatching"
        seen_ids:           ["<req1@host>"]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: "<req1@host>"
        pending_task_id:    "t1"
        pending_to_addr:    "t1@smolfire.local"
        dispatched_at:      ""
        attempt_counts:     {}
        halted_tasks:       []
        task_executors:     {"t1": {executor: "vm", network: false, request_id: "<req1@host>"}}
    }
}

print "test 1: normal dispatch — no pre-existing coordinator dispatch, guard is a no-op"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req = make-msg "user@smolfire.local" "t1@smolfire.local" "<req1@host>" 'task_id = "t1"'
    write-spool $spool_abs $req
    write-state $state_abs (base-state)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    let spool_after = open --raw $spool_abs

    assert equal $state.fsm_state "waiting"
    assert ($state.pending_request_id != "<req1@host>")   # reassigned to the NEW dispatch's own id
    assert ("From: coordinator@smolfire.local" in $spool_after)

    ^rm -rf $tmp
    print "  ok"
}

print "test 2: crash recovery — unanswered coordinator dispatch already in spool, guard resumes waiting without re-dispatching"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req  = make-msg "user@smolfire.local" "t1@smolfire.local" "<req1@host>" 'task_id = "t1"'
    let disp = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp1@host>" 'task_id = "t1"
action = "dispatch"
executor = "vm"' --in-reply-to "<req1@host>"
    write-spool $spool_abs ($req + $disp)
    write-state $state_abs (base-state)

    let spool_before = open --raw $spool_abs

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    let spool_after = open --raw $spool_abs

    # No new message appended: the guard must not send a second dispatch.
    assert equal $spool_before $spool_after
    assert equal $state.fsm_state "waiting"
    # Resumed onto the EXISTING dispatch's id, not a freshly generated one.
    assert equal $state.pending_request_id "<disp1@host>"

    ^rm -rf $tmp
    print "  ok"
}

print "test 3: already-answered coordinator dispatch — guard does not block (has_reply short-circuits to a fresh dispatch)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req   = make-msg "user@smolfire.local" "t1@smolfire.local" "<req1@host>" 'task_id = "t1"'
    let disp  = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp1@host>" 'task_id = "t1"
action = "dispatch"' --in-reply-to "<req1@host>"
    let reply = make-msg "t1@smolfire.local" "coordinator@smolfire.local" "<reply1@host>" 'task_id = "t1"
verdict = "pass"' --in-reply-to "<req1@host>"
    write-spool $spool_abs ($req + $disp + $reply)
    write-state $state_abs (base-state)

    let spool_before = open --raw $spool_abs

    run-tick $tmp $state_rel $spool_rel

    let spool_after = open --raw $spool_abs
    # A NEW dispatch message must have been appended (guard correctly
    # treats the request as answered, so it does not block).
    assert ($spool_before != $spool_after)

    ^rm -rf $tmp
    print "  ok"
}

print "all tests passed"
