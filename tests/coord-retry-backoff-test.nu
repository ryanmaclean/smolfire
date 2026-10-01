# SPDX-License-Identifier: Apache-2.0
# coord-retry-backoff-test.nu — spec §12 retry scheduling + retry payload
#
# Subprocess-level coverage (same style as coord-double-dispatch-test.nu) for:
#   - Fibonacci backoff [60, 60, 120]: a retry is SCHEDULED (not_before
#     persisted in the crash-atomic state slot), never slept inside a tick, and
#     only sent once due (idle/waiting wake into dispatching, "retry-due");
#   - retry payload fields (prior_attempt_msgid, prior_attempt_count,
#     format_violation) in the retry dispatch envelope;
#   - SMOLFIRE_RETRY_BACKOFF=0 kill-switch keeps immediate dispatch.
#
# Hermetic: SMOLFIRE_SPAWN_SUBAGENT is never set, agent CLIs are stripped from
# PATH. No network, no hardware.

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

# One tick; returns {stdout, exit_code}. backoff=false sets the kill-switch.
def run-tick [root: string, --no-backoff] {
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_RETRY_BACKOFF
        hide-env -i SMOLFIRE_IRC_HOST
        if $no_backoff {
            with-env {SMOLFIRE_RETRY_BACKOFF: "0"} {
                (^$nu_bin --no-config-file bin/coord-tick.nu --state-file var/run/coord-state.toml --spool var/mail/spool --root $root) | complete
            }
        } else {
            (^$nu_bin --no-config-file bin/coord-tick.nu --state-file var/run/coord-state.toml --spool var/mail/spool --root $root) | complete
        }
    }
}

# State waiting on a vm dispatch <disp1@host> for t1 with `attempts` made.
def waiting-state [attempts: int] {
    {
        version:            "1"
        tick_count:         1
        fsm_state:          "waiting"
        seen_ids:           ["<req1@host>", "<disp1@host>"]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: "<disp1@host>"
        pending_task_id:    "t1"
        pending_to_addr:    "t1@smolfire.local"
        dispatched_at:      "2099-01-01T00:00:00Z"
        attempt_counts:     {t1: $attempts}
        halted_tasks:       []
        task_executors:     {t1: {executor: "vm", network: false, request_id: "<req1@host>"}}
        inflight:           {t1: {executor: "vm", since_tick: 1}}
    }
}

def base-spool [reply_body: string] {
    let req  = make-msg "user@smolfire.local" "t1@smolfire.local" "<req1@host>" 'task_id = "t1"'
    let disp = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp1@host>" "task_id = \"t1\"\naction = \"dispatch\"\nexecutor = \"vm\"" --in-reply-to "<req1@host>"
    let rep  = make-msg "t1@smolfire.local" "coordinator@smolfire.local" "<reply1@host>" $reply_body --in-reply-to "<disp1@host>"
    $req + $disp + $rep
}

def vm-slot [state: record] { $state.pending_slots.vm | first }

def count-dispatches [spool: string] {
    (open --raw $spool | split row "\n" | where {|l| $l == "action = \"dispatch\"" } | length)
}

def setup [reply_body: string, attempts: int] {
    let tmp = make-temp-dir
    write-spool ([$tmp, "var", "mail", "spool"] | path join) (base-spool $reply_body)
    write-state ([$tmp, "var", "run", "coord-state.toml"] | path join) (waiting-state $attempts)
    $tmp
}

print "backoff 1: fail reply schedules a retry 60s out; nothing sent, no sleep"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 1
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    let before = count-dispatches $spool

    let t0 = date now
    let r = run-tick $tmp
    let elapsed = (date now) - $t0
    assert equal $r.exit_code 0 "tick exits 0"
    assert ($elapsed < 30sec) "tick did not sleep through the backoff"

    let st = read-state $state_abs
    assert equal (count-dispatches $spool) $before "no retry dispatch sent yet"
    assert equal $st.fsm_state "idle" "parked idle while backoff runs"
    let sl = vm-slot $st
    assert equal $sl.task_id "t1" "slot still reserved for the retry"
    assert equal $sl.dispatched_at "" "slot not sent"
    assert equal $sl.prior_attempt_msgid "<reply1@host>" "prior_attempt_msgid = failed reply id"
    assert equal $sl.prior_attempt_count 1 "prior_attempt_count"
    let nb = $sl.not_before | into datetime --timezone UTC
    let delta = ($nb - (date now)) | into int
    assert ($delta > 40_000_000_000 and $delta <= 61_000_000_000) $"not_before ~60s out [delta ns=($delta)]"
    assert ($r.stdout | str contains "reason = \"retry-backoff\"") "retry-backoff transition emitted"

    # Held across another tick (state reloaded from disk): still nothing sent.
    let r2 = run-tick $tmp
    assert equal $r2.exit_code 0
    assert equal (count-dispatches $spool) $before "still held on the next tick"
    assert equal (vm-slot (read-state $state_abs)).not_before $sl.not_before "schedule unchanged by reload"

    ^rm -rf $tmp
    print "  ok"
}

print "backoff 2: due retry is sent with the retry payload (X-Attempt 2)"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 1
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    let before = count-dispatches $spool
    run-tick $tmp | ignore

    # Time passes: make the persisted not_before due.
    let st = read-state $state_abs
    let slots = $st.pending_slots | upsert vm ($st.pending_slots.vm | each {|s| if $s.task_id == "t1" { $s | upsert not_before "2020-01-01T00:00:00Z" } else { $s } })
    write-state $state_abs ($st | upsert pending_slots $slots)

    let r = run-tick $tmp
    assert equal $r.exit_code 0
    assert ($r.stdout | str contains "reason = \"retry-due\"") "retry-due transition emitted"
    assert equal (count-dispatches $spool) ($before + 1) "exactly one retry dispatch"
    let raw = open --raw $spool
    assert ($raw | str contains "X-Attempt: 2") "second attempt header"
    assert ($raw | str contains "prior_attempt_msgid = \"<reply1@host>\"") "prior_attempt_msgid in envelope"
    assert ($raw | str contains "prior_attempt_count = 1") "prior_attempt_count in envelope"
    assert (not ($raw | str contains "format_violation")) "no format_violation for plain fail"

    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "waiting"
    let sl = vm-slot $st2
    assert equal $sl.not_before "" "schedule cleared once sent"
    assert equal $sl.prior_attempt_msgid "" "retry payload cleared once sent"
    assert equal $st2.attempt_counts.t1 2

    # Immediate re-tick must not double-dispatch.
    run-tick $tmp | ignore
    assert equal (count-dispatches $spool) ($before + 1) "no double dispatch"

    ^rm -rf $tmp
    print "  ok"
}

print "backoff 3: malformed reply carries format_violation"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"pass\"\nattestation_required = true" 1
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    run-tick $tmp | ignore
    let st = read-state $state_abs
    assert ((vm-slot $st).format_violation | str contains "no [[claims]]") "violation recorded in slot"
    let slots = $st.pending_slots | upsert vm ($st.pending_slots.vm | each {|s| if $s.task_id == "t1" { $s | upsert not_before "2020-01-01T00:00:00Z" } else { $s } })
    write-state $state_abs ($st | upsert pending_slots $slots)
    run-tick $tmp | ignore
    assert ((open --raw $spool) | str contains "format_violation = \"attestation_required=true but no [[claims]] block present\"") "violation in envelope"
    # The envelope must still be valid TOML for the worker.
    ^rm -rf $tmp
    print "  ok"
}

print "backoff 4: second retry also waits 60s (Fibonacci [60,60,120], index by attempts)"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 2
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    run-tick $tmp | ignore
    let sl = vm-slot (read-state $state_abs)
    assert equal $sl.prior_attempt_count 2
    let delta = (($sl.not_before | into datetime --timezone UTC) - (date now)) | into int
    assert ($delta > 40_000_000_000 and $delta <= 61_000_000_000) $"not_before ~60s out [delta ns=($delta)]"
    ^rm -rf $tmp
    print "  ok"
}

print "backoff 5: exhausted budget still halts immediately (no backoff on escalation)"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 3
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let before = count-dispatches $spool
    run-tick $tmp | ignore
    assert (([$tmp, "var", "mail", "HALT.t1"] | path join) | path exists) "HALT marker written"
    assert equal (count-dispatches $spool) $before "no dispatch"
    ^rm -rf $tmp
    print "  ok"
}

print "backoff 6: SMOLFIRE_RETRY_BACKOFF=0 keeps immediate retry dispatch"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 1
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let before = count-dispatches $spool
    run-tick $tmp --no-backoff | ignore
    assert equal (count-dispatches $spool) ($before + 1) "dispatched in the same tick"
    assert ((open --raw $spool) | str contains "prior_attempt_count = 1") "payload present on immediate retry too"
    ^rm -rf $tmp
    print "  ok"
}

print "backoff 7: unparseable not_before fails open (never wedges a task)"
do {
    let tmp = setup "task_id = \"t1\"\nverdict = \"fail\"" 1
    let spool = [$tmp, "var", "mail", "spool"] | path join
    let state_abs = [$tmp, "var", "run", "coord-state.toml"] | path join
    let before = count-dispatches $spool
    run-tick $tmp | ignore
    let st = read-state $state_abs
    let slots = $st.pending_slots | upsert vm ($st.pending_slots.vm | each {|s| if $s.task_id == "t1" { $s | upsert not_before "garbage" } else { $s } })
    write-state $state_abs ($st | upsert pending_slots $slots)
    run-tick $tmp | ignore
    assert equal (count-dispatches $spool) ($before + 1) "sent despite garbage not_before"
    ^rm -rf $tmp
    print "  ok"
}

print "all tests passed"
