# SPDX-License-Identifier: Apache-2.0
# coord-state-atomic-test.nu — crash-safe state persistence invariant
#
# Regression coverage for the atomic-save + fail-closed-load guard in
# bin/coord-tick.nu (save-state / load-state):
#
# HOLE (pre-fix): save-state overwrote the state file in place with
# `save --force`, and load-state failed OPEN to default-state on any parse
# error. A crash mid-write (SIGKILL, OOM-kill, host restart, power loss)
# leaves a truncated/corrupt/empty state file; the next tick then ran with
# TOTAL AMNESIA — seen_ids=[], attempt_counts={}, halted_tasks=[] — which
# re-harvests every message, resets D2 retry budgets (unbounded billed
# retries), and re-dispatches tasks the operator explicitly halted.
#
# GUARD (post-fix): save-state writes a temp file in the same directory
# and renames it over the target (POSIX atomic rename: readers see the old
# intact file or the new complete file, never a torn prefix), and
# load-state fails CLOSED on a present-but-unparseable state file:
# quarantine the corrupt file to <path>.corrupt-<ts> and exit non-zero
# BEFORE any tick side effect (no dispatch, no spool append, no HALT
# write, no state overwrite).
#
# Each test is hermetic: temp dir + real `nu bin/coord-tick.nu` subprocess
# invocations (same discipline as coord-double-dispatch-test.nu §12).

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
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

def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

# Run one tick, capturing the exit code (fail-closed load exits non-zero).
def run-tick-captured [root: string, state_rel: string, spool_rel: string] {
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_IRC_HOST
        ^$nu_bin --no-config-file bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $root | complete
    }
}

def full-state [] {
    {
        version:            "1"
        tick_count:         7
        fsm_state:          "idle"
        seen_ids:           ["<old.reply@host>"]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
        dispatched_at:      ""
        attempt_counts:     {"t-hold": 3}
        halted_tasks:       ["t-hold"]
        task_executors:     {}
    }
}

print "test 1: torn state file (simulated crash mid-write) fails closed — no amnesiac tick"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Operator halted t-hold after 3 attempts; a dispatchable request for
    # the SAME task sits in the spool (would re-dispatch under amnesia).
    write-state $state_abs (full-state)
    let req = make-msg "user@smolfire.local" "builder@smolfire.local" "<req.hold@host>" 'task_id = "t-hold"'
    write-spool $spool_abs $req
    let spool_before = open --raw $spool_abs

    # Simulate a crash torn write: keep only a byte prefix of the TOML.
    let full_raw = open --raw $state_abs
    ($full_raw | str substring ..40) | save --force $state_abs

    let r = run-tick-captured $tmp $state_rel $spool_rel

    # Fail closed: non-zero exit, spool byte-identical (halted task NOT
    # re-dispatched), corrupt file quarantined (not overwritten in place).
    assert ($r.exit_code != 0) $"torn state file must refuse to tick \(exit=($r.exit_code)\)"
    assert equal (open --raw $spool_abs) $spool_before
    let quarantined = glob $"($state_abs).corrupt-*"
    assert (($quarantined | length) == 1) "corrupt state file must be quarantined, not silently replaced"
    # Quarantined copy preserves the torn bytes as forensic evidence.
    assert (($quarantined | first | path exists)) "quarantine path must exist"

    ^rm -rf $tmp
    print "  ok"
}

print "test 2: empty state file (truncate-to-zero torn write) fails closed, not fresh-init"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-state $state_abs (full-state)
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.e@host>" 'task_id = "t-e"')
    let spool_before = open --raw $spool_abs

    # 0-byte file: truncate() ran, write() never did.
    "" | save --force $state_abs

    let r = run-tick-captured $tmp $state_rel $spool_rel

    assert ($r.exit_code != 0) $"empty state file must refuse to tick \(exit=($r.exit_code)\)"
    assert equal (open --raw $spool_abs) $spool_before
    assert ((glob $"($state_abs).corrupt-*" | length) == 1) "empty state file must be quarantined"

    ^rm -rf $tmp
    print "  ok"
}

print "test 3: absent state file still fresh-inits (unchanged path)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-spool $spool_abs (make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<r3@host>" 'task_id = "t3"
verdict = "pass"')

    let r = run-tick-captured $tmp $state_rel $spool_rel

    assert ($r.exit_code == 0) $"fresh init must exit 0 \(exit=($r.exit_code)\)"
    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert ("<r3@host>" in $state.seen_ids)

    ^rm -rf $tmp
    print "  ok"
}

print "test 4: successful save leaves valid TOML and no tmp debris (atomic rename)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-state $state_abs (full-state | update halted_tasks [] | update attempt_counts {})
    write-spool $spool_abs (make-msg "user@smolfire.local" "builder@smolfire.local" "<req.t4@host>" 'task_id = "t4"')

    let r = run-tick-captured $tmp $state_rel $spool_rel
    assert ($r.exit_code == 0) $"normal tick must exit 0 \(exit=($r.exit_code)\)"

    # State file parses (never a torn prefix) and carries the tick forward.
    let state = read-state $state_abs
    assert ($state.tick_count > 7) "tick_count must advance"
    assert equal $state.fsm_state "waiting"
    # No temp-file debris from the atomic writer.
    assert ((glob $"($state_abs).tmp.*" | length) == 0) "no *.tmp.* debris may remain after save"

    ^rm -rf $tmp
    print "  ok"
}

print "test 5: stale tmp from a crashed writer is cleaned, tick proceeds on intact state"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    write-state $state_abs (full-state | update halted_tasks [] | update attempt_counts {})
    write-spool $spool_abs (make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<r5@host>" 'task_id = "t5"
verdict = "pass"')
    # Leftover of a writer killed between temp-write and rename.
    "tick_count = 9999\nFSM_STATE = GARBAGE" | save --force $"($state_abs).tmp.99999"

    let r = run-tick-captured $tmp $state_rel $spool_rel
    assert ($r.exit_code == 0) $"tick must proceed on intact state \(exit=($r.exit_code)\)"
    let state = read-state $state_abs
    assert ("<r5@host>" in $state.seen_ids) "intact state file must be the one ticked from"
    assert (($state.tick_count | default 9999) != 9999) "stale tmp must never be loaded as state"
    assert ((glob $"($state_abs).tmp.*" | length) == 0) "stale tmp must be cleaned"

    ^rm -rf $tmp
    print "  ok"
}

print "all tests passed"
