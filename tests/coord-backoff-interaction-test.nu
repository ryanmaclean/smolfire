# SPDX-License-Identifier: Apache-2.0
# coord-backoff-interaction-test.nu — §12 retry backoff x the rest of the FSM
#
# Subprocess-level coverage (style of coord-double-dispatch-test.nu and
# coord-retry-backoff-test.nu) of how the §12 retry backoff (a retry holds a
# slot: stamped, dispatched_at empty, future not_before) interacts with:
#   - the max-inflight backpressure caps (a retry never counts against
#     itself; a held retry RESERVES its inflight entry so newcomers cannot
#     starve it during the backoff window);
#   - OTHER tasks' dispatch (a held slot never blocks a different task, and
#     state-dispatching counts SENT slots, so sent + held ends in waiting);
#   - the worker-heartbeat dead-worker reap (reap-to-retry follows the SAME
#     backoff schedule as any other failed attempt);
#   - the §12 no-double-dispatch crash-recovery guard on attempt >= 2;
#   - the SMOLFIRE_RETRY_BACKOFF switch (unset == ON; only exactly "0" is off).
#
# Hermetic: SMOLFIRE_SPAWN_SUBAGENT is never set, agent CLIs are stripped from
# PATH, SMOLFIRE_FLEET_ENABLE is cleared. No network, no hardware.
#
# Test files are imported as modules by tests/run-tests.nu in some contexts:
# env setup uses export-env only, never a top-level `$env.X = ...`.

export-env { hide-env -i SMOLFIRE_SPAWN_SUBAGENT }

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
    --attempt: int = 0
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
    if $attempt > 0 {
        $header_lines = $header_lines | append $"X-Attempt: ($attempt)"
    }
    ($header_lines | str join "\n") + "\n\n" + $body + "\n"
}

def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

# One tick with an explicit environment: `vars` is a record of variables to
# set; SMOLFIRE_RETRY_BACKOFF and every cap/executor knob are cleared first so
# the test controls exactly what the coordinator sees (unset == default).
def run-tick [root: string, vars: record = {}] {
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        hide-env -i SMOLFIRE_RETRY_BACKOFF
        hide-env -i SMOLFIRE_IRC_HOST
        hide-env -i SMOLFIRE_FLEET_ENABLE
        hide-env -i SMOLFIRE_EXECUTOR
        hide-env -i SMOLFIRE_CONCURRENT
        hide-env -i SMOLFIRE_MAX_INFLIGHT
        hide-env -i SMOLFIRE_MAX_INFLIGHT_VM
        hide-env -i SMOLFIRE_MAX_INFLIGHT_JAIL
        hide-env -i SMOLFIRE_MAX_INFLIGHT_FLEET
        hide-env -i SMOLFIRE_WORKER_DEAD_TICKS
        with-env $vars {
            (^$nu_bin --no-config-file bin/coord-tick.nu --state-file var/run/coord-state.toml --spool var/mail/spool --root $root) | complete
        }
    }
}

def spool-path [tmp: string] { [$tmp, "var", "mail", "spool"] | path join }
def state-path [tmp: string] { [$tmp, "var", "run", "coord-state.toml"] | path join }

def count-dispatches [spool: string] {
    (open --raw $spool | split row "\n" | where {|l| $l == "action = \"dispatch\"" } | length)
}

def slot-for [state: record, executor: string, task: string] {
    let hits = $state.pending_slots | get $executor | where task_id == $task
    if ($hits | is-empty) { null } else { $hits | first }
}

def make-due [state_abs: string, executor: string, task: string] {
    let st = read-state $state_abs
    let slots = $st.pending_slots | upsert $executor ($st.pending_slots | get $executor | each {|s| if $s.task_id == $task { $s | upsert not_before "2020-01-01T00:00:00Z" } else { $s } })
    write-state $state_abs ($st | upsert pending_slots $slots)
}

# Legacy-scalar waiting state (migrates to slots on load), one task t1 whose
# dispatch <disp1@host> is answered in the spool. `extra_inflight` adds other
# running tasks (inflight entries only) for cap scenarios.
def waiting-state [attempts: int, executor: string = "vm", extra_inflight: record = {}] {
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
        task_executors:     {t1: {executor: $executor, network: false, request_id: "<req1@host>"}}
        inflight:           ({t1: {executor: $executor, since_tick: 1}} | merge $extra_inflight)
    }
}

def base-spool [reply_body: string, executor: string = "vm"] {
    let req  = make-msg "user@smolfire.local" "t1@smolfire.local" "<req1@host>" 'task_id = "t1"'
    let disp = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp1@host>" $"task_id = \"t1\"\naction = \"dispatch\"\nexecutor = \"($executor)\"" --in-reply-to "<req1@host>"
    let rep  = make-msg "t1@smolfire.local" "coordinator@smolfire.local" "<reply1@host>" $reply_body --in-reply-to "<disp1@host>"
    $req + $disp + $rep
}

const FAIL_BODY = "task_id = \"t1\"\nverdict = \"fail\""

def setup [state: record, spool: string] {
    let tmp = make-temp-dir
    write-spool (spool-path $tmp) $spool
    write-state (state-path $tmp) $state
    $tmp
}

def new-request [task: string, id: string] {
    make-msg "user@smolfire.local" $"($task)@smolfire.local" $id $"task_id = \"($task)\""
}

# ── 1. retry vs max-inflight caps ─────────────────────────────────────────────

print "interaction 1: retry is not blocked by its OWN inflight entry (cap 1)"
do {
    # SMOLFIRE_MAX_INFLIGHT_VM=1 with exactly one running task: the failing
    # task's retry must still be admitted (it replaces itself). Before the
    # fix the gate counted the retrying task's own entry (1 >= 1), deferred
    # the retry forever and re-harvested the same reply every tick.
    let tmp = setup (waiting-state 1) (base-spool $FAIL_BODY)
    let spool = spool-path $tmp
    let state_abs = state-path $tmp
    let r = run-tick $tmp {SMOLFIRE_MAX_INFLIGHT_VM: "1"}
    assert equal $r.exit_code 0 "tick exits 0"
    assert (not ($r.stdout | str contains "backpressure")) "no backpressure deferral of the retry"
    let sl = slot-for (read-state $state_abs) "vm" "t1"
    assert ($sl != null) "retry slot stamped"
    assert equal $sl.dispatched_at "" "held, not sent"
    assert ($sl.not_before != "") "held by the 60 s backoff"

    # Backoff elapses: the due retry must actually be SENT (the dispatch-time
    # backstop must not re-gate it against its own entry either).
    make-due $state_abs "vm" "t1"
    let r2 = run-tick $tmp {SMOLFIRE_MAX_INFLIGHT_VM: "1"}
    assert equal $r2.exit_code 0
    assert equal (count-dispatches $spool) 2 "due retry sent (original + retry)"
    assert (not ($r2.stdout | str contains "dispatch-backstop")) "backstop did not refuse the retry"
    assert equal (read-state $state_abs).fsm_state "waiting" "waiting on the retry dispatch"
    ^rm -rf $tmp
    print "  ok"
}

print "interaction 2: a held retry still counts for OTHER tasks (reserves its capacity)"
do {
    # cap 2: t1 is in backoff (its inflight entry is its reservation), x1 is
    # running. A newcomer t2 must be deferred by backpressure, not slip into
    # t1's reserved capacity; it stays UNSEEN (rediscovered, never dropped).
    let spool = (base-spool $FAIL_BODY) + (new-request "t2" "<req2@host>")
    let tmp = setup (waiting-state 1 "vm" {x1: {executor: "vm", since_tick: 1}}) $spool
    let state_abs = state-path $tmp
    let r = run-tick $tmp {SMOLFIRE_MAX_INFLIGHT_VM: "2"}
    assert equal $r.exit_code 0
    let st = read-state $state_abs
    assert ($r.stdout | str contains "backpressure") "t2 deferred at cap"
    assert (not ("<req2@host>" in $st.seen_ids)) "t2 stays unseen for rediscovery"
    assert ((slot-for $st "vm" "t2") == null) "t2 holds no slot"
    assert ((slot-for $st "vm" "t1") != null) "t1's reservation intact"
    ^rm -rf $tmp
    print "  ok"
}

# ── 2. backoff-held slot vs other tasks ───────────────────────────────────────

print "interaction 3: a held slot never blocks another task (sent + held ends waiting)"
do {
    # t1 fails -> held 60 s. t2 arrives in the same spool: it is dispatched
    # immediately, the FSM ends in waiting (sent count > 0), and t1 stays
    # held. Default caps (vm 4).
    let content = (base-spool $FAIL_BODY) + (new-request "t2" "<req2@host>")
    let tmp = setup (waiting-state 1) $content
    let state_abs = state-path $tmp
    let r = run-tick $tmp
    assert equal $r.exit_code 0
    let st = read-state $state_abs
    assert equal (count-dispatches (spool-path $tmp)) 2 "original t1 dispatch + the new t2 dispatch; t1 retry not sent"
    let s2 = slot-for $st "vm" "t2"
    assert ($s2 != null and $s2.dispatched_at != "") "t2 sent"
    let s1 = slot-for $st "vm" "t1"
    assert equal $s1.dispatched_at "" "t1 still held"
    assert ($s1.not_before != "") "t1 backoff schedule kept"
    assert equal $st.fsm_state "waiting" "sent slot present, so waiting (not idle)"

    # Held slot is not re-sent on later ticks while t2 waits.
    let r2 = run-tick $tmp
    assert equal $r2.exit_code 0
    assert equal (count-dispatches (spool-path $tmp)) 2 "no spurious dispatch on the next tick"
    assert equal (slot-for (read-state $state_abs) "vm" "t1").not_before $s1.not_before "schedule unchanged"
    ^rm -rf $tmp
    print "  ok"
}

print "interaction 4: crash-resumed dispatching state with sent + held slots goes to waiting"
do {
    # Persisted fsm_state = dispatching with t2 already sent (its dispatch is
    # in the spool, unanswered) and t1 held: nothing is unsent+due, sent > 0,
    # so the FSM resumes waiting - it must not park idle and must not resend.
    let req2 = new-request "t2" "<req2@host>"
    let disp2 = make-msg "coordinator@smolfire.local" "t2@smolfire.local" "<disp2@host>" "task_id = \"t2\"\naction = \"dispatch\"\nexecutor = \"vm\"" --in-reply-to "<req2@host>"
    let spool = (base-spool "task_id = \"t1\"\nverdict = \"pass\"") + $req2 + $disp2
    let blank = {task_id: "", request_id: "", to_addr: "", dispatched_at: "", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
    let tmp = make-temp-dir
    write-spool (spool-path $tmp) $spool
    write-state (state-path $tmp) {
        version: "1", tick_count: 5, fsm_state: "dispatching"
        seen_ids: ["<req1@host>", "<disp1@host>", "<reply1@host>", "<req2@host>", "<disp2@host>"]
        last_tick_at: "2026-01-01T00:00:00Z"
        pending_request_id: "", pending_task_id: "", pending_to_addr: "", dispatched_at: ""
        attempt_counts: {t1: 1, t2: 1}, halted_tasks: []
        task_executors: {t1: {executor: "vm", network: false, request_id: "<req1@host>"}, t2: {executor: "vm", network: false, request_id: "<req2@host>"}}
        inflight: {t1: {executor: "vm", since_tick: 1}, t2: {executor: "vm", since_tick: 5}}
        pending_slots: {
            fleet: [$blank, $blank]
            jail: [$blank, $blank]
            vm: [
                {task_id: "t1", request_id: "<reply1@host>", to_addr: "t1@smolfire.local", dispatched_at: "", not_before: "2099-01-01T00:00:00Z", prior_attempt_msgid: "<reply1@host>", prior_attempt_count: 1, format_violation: ""}
                {task_id: "t2", request_id: "<disp2@host>", to_addr: "t2@smolfire.local", dispatched_at: "2099-01-01T00:00:00Z", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
                $blank
                $blank
            ]
        }
    }
    let before = open --raw (spool-path $tmp)
    let r = run-tick $tmp
    assert equal $r.exit_code 0 $r.stderr
    assert equal (open --raw (spool-path $tmp)) $before "nothing appended"
    let st = read-state (state-path $tmp)
    assert equal $st.fsm_state "waiting" "sent slot present -> waiting"
    assert equal (slot-for $st "vm" "t1").dispatched_at "" "t1 still held"
    ^rm -rf $tmp
    print "  ok"
}

print "interaction 4b: a RUNNING (sent) slot is never re-dispatched when another task's retry reaches dispatching"
do {
    # t1 and t2 are both in flight (sent slots). t1 fails; its retry enters
    # dispatching while t2 is still running. Before the fix the dispatching
    # recovery looked for a coordinator message threaded to t2's request_id,
    # but a SENT slot's request_id is the dispatch's own Message-ID, so it
    # concluded the dispatch never happened and sent t2 again.
    for mode in ["backoff", "off"] {
        let req2 = new-request "t2" "<req2@host>"
        let disp2 = make-msg "coordinator@smolfire.local" "t2@smolfire.local" "<disp2@host>" "task_id = \"t2\"\naction = \"dispatch\"\nexecutor = \"vm\"" --in-reply-to "<req2@host>"
        let blank = {task_id: "", request_id: "", to_addr: "", dispatched_at: "", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
        let tmp = make-temp-dir
        write-spool (spool-path $tmp) ((base-spool $FAIL_BODY) + $req2 + $disp2)
        write-state (state-path $tmp) {
            version: "1", tick_count: 5, fsm_state: "waiting"
            seen_ids: ["<req1@host>", "<disp1@host>", "<req2@host>", "<disp2@host>"]
            last_tick_at: "2026-01-01T00:00:00Z"
            pending_request_id: "", pending_task_id: "", pending_to_addr: "", dispatched_at: ""
            attempt_counts: {t1: 1, t2: 1}, halted_tasks: []
            task_executors: {t1: {executor: "vm", network: false, request_id: "<req1@host>"}, t2: {executor: "vm", network: false, request_id: "<req2@host>"}}
            inflight: {t1: {executor: "vm", since_tick: 1}, t2: {executor: "vm", since_tick: 2}}
            pending_slots: {
                fleet: [$blank, $blank]
                jail: [$blank, $blank]
                vm: [
                    {task_id: "t1", request_id: "<disp1@host>", to_addr: "t1@smolfire.local", dispatched_at: "2099-01-01T00:00:00Z", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
                    {task_id: "t2", request_id: "<disp2@host>", to_addr: "t2@smolfire.local", dispatched_at: "2099-01-01T00:00:00Z", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
                    $blank
                    $blank
                ]
            }
        }
        let vars = if $mode == "off" { {SMOLFIRE_RETRY_BACKOFF: "0"} } else { {} }
        let r = run-tick $tmp $vars
        assert equal $r.exit_code 0 $r.stderr
        let st = read-state (state-path $tmp)
        let raw = open --raw (spool-path $tmp)
        assert equal ($raw | split row "In-Reply-To: <disp2@host>" | length) 1 $"($mode): nothing is threaded to the t2 dispatch"
        let expected = if $mode == "off" { 3 } else { 2 }
        assert equal (count-dispatches (spool-path $tmp)) $expected $"($mode): only t1's retry may be added"
        let s2 = slot-for $st "vm" "t2"
        assert equal $s2.request_id "<disp2@host>" $"($mode): t2 slot untouched"
        assert equal $st.attempt_counts.t2 1 $"($mode): t2 attempts untouched"
        ^rm -rf $tmp
    }
    print "  ok"
}

# ── 3. heartbeat dead-worker reap -> retry ────────────────────────────────────

print "interaction 5: dead-worker reap-to-retry follows the SAME backoff schedule"
do {
    # Semantic (documented in CLAUDE.md / bin/coord-tick.nu): a reap appends a
    # synthetic fail reply, which the harvest treats like any failed attempt,
    # so the retry waits the §12 backoff. The worker was already silent for
    # the dead-after horizon; giving it 60 s more before the re-send is the
    # point of the schedule, and one uniform rule keeps the kill switch
    # (SMOLFIRE_RETRY_BACKOFF=0 -> immediate) meaningful for reaps too.
    for mode in ["default", "off"] {
        let tmp = make-temp-dir
        write-spool (spool-path $tmp) ""
        # Inflight entry owned by a silent worker (no pending slot), dead
        # threshold 2 ticks. Same shape as tests/coord-heartbeat-test.nu 5.
        write-state (state-path $tmp) {
            version: "1", tick_count: 20, fsm_state: "idle"
            seen_ids: ["<req1@host>", "<disp1@host>"]
            last_tick_at: "2026-01-01T00:00:00Z"
            pending_request_id: "", pending_task_id: "", pending_to_addr: "", dispatched_at: ""
            attempt_counts: {}, halted_tasks: []
            task_executors: {t1: {executor: "vm", network: false, request_id: "<req1@host>"}}
            inflight: {t1: {executor: "vm", since_tick: 1}}
            workers: {vm: {last_seen_tick: 1, consecutive_failures: 0, dead: false}}
        }
        let vars = if $mode == "off" { {SMOLFIRE_WORKER_DEAD_TICKS: "2", SMOLFIRE_RETRY_BACKOFF: "0"} } else { {SMOLFIRE_WORKER_DEAD_TICKS: "2"} }
        let r = run-tick $tmp $vars
        assert equal $r.exit_code 0 $"($mode): tick exits 0"
        assert ($r.stdout | str contains "worker_marked_dead") $"($mode): worker marked dead"
        let st = read-state (state-path $tmp)
        if $mode == "default" {
            assert equal (count-dispatches (spool-path $tmp)) 0 "default: reap retry NOT sent inside the backoff window"
            let sl = slot-for $st "vm" "t1"
            assert ($sl != null) "default: retry slot held"
            assert equal $sl.dispatched_at "" "default: held, unsent"
            let delta = (($sl.not_before | into datetime --timezone UTC) - (date now)) | into int
            assert ($delta > 40_000_000_000 and $delta <= 61_000_000_000) $"default: not_before ~60s out [ns=($delta)]"
            assert ($sl.prior_attempt_msgid | str contains "deadreap") "default: retry payload names the synthetic reap reply"
            # Backoff elapses -> sent as attempt 2.
            make-due (state-path $tmp) "vm" "t1"
            let r2 = run-tick $tmp {SMOLFIRE_WORKER_DEAD_TICKS: "2"}
            assert equal (count-dispatches (spool-path $tmp)) 1 "default: due reap retry sent"
            assert ((open --raw (spool-path $tmp)) | str contains "X-Attempt: 1") "default: attempt 1 (reap itself burns no budget)"
        } else {
            assert equal (count-dispatches (spool-path $tmp)) 1 "off: reap retry sent immediately (kill switch)"
        }
        ^rm -rf $tmp
    }
    print "  ok"
}

# ── 4. s12 no-double-dispatch guard on attempt >= 2 ───────────────────────────

print "interaction 6: crash after the retry append - guard resumes, appends zero bytes (attempt 2, backoff on)"
do {
    # Crash window: the retry dispatch (In-Reply-To the failed reply) was
    # appended to the spool, but the pre-send state (retry slot stamped,
    # dispatched_at empty, not_before already due) is what survived on disk.
    let disp2 = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp2@host>" "task_id = \"t1\"\naction = \"dispatch\"\nexecutor = \"vm\"\nprior_attempt_msgid = \"<reply1@host>\"\nprior_attempt_count = 1" --in-reply-to "<reply1@host>" --attempt 2
    let spool = (base-spool $FAIL_BODY) + $disp2
    let blank = {task_id: "", request_id: "", to_addr: "", dispatched_at: "", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
    let tmp = make-temp-dir
    write-spool (spool-path $tmp) $spool
    write-state (state-path $tmp) {
        version: "1", tick_count: 5, fsm_state: "idle"
        seen_ids: ["<req1@host>", "<disp1@host>", "<reply1@host>"]
        last_tick_at: "2026-01-01T00:00:00Z"
        pending_request_id: "", pending_task_id: "", pending_to_addr: "", dispatched_at: ""
        attempt_counts: {t1: 1}, halted_tasks: []
        task_executors: {t1: {executor: "vm", network: false, request_id: "<req1@host>"}}
        inflight: {t1: {executor: "vm", since_tick: 1}}
        pending_slots: {
            fleet: [$blank, $blank]
            jail: [$blank, $blank]
            vm: [
                {task_id: "t1", request_id: "<reply1@host>", to_addr: "t1@smolfire.local", dispatched_at: "", not_before: "2020-01-01T00:00:00Z", prior_attempt_msgid: "<reply1@host>", prior_attempt_count: 1, format_violation: ""}
                $blank
                $blank
                $blank
            ]
        }
    }
    let before = open --raw (spool-path $tmp)
    let r = run-tick $tmp
    assert equal $r.exit_code 0
    assert equal (open --raw (spool-path $tmp)) $before "zero bytes appended: no double dispatch of attempt 2"
    assert ($r.stdout | str contains "dispatch_skipped_inflight") "guard fired"
    let st = read-state (state-path $tmp)
    assert equal $st.fsm_state "waiting" "resumed waiting"
    let sl = slot-for $st "vm" "t1"
    assert equal $sl.request_id "<disp2@host>" "slot adopts the existing retry dispatch id"
    assert ($sl.dispatched_at != "") "slot marked sent"
    assert ("t1" in ($st.inflight | columns)) "inflight reservation kept"
    ^rm -rf $tmp
    print "  ok"
}

print "interaction 7: guard does not resume an ANSWERED attempt-2 dispatch (fresh retry is sent)"
do {
    # The retry dispatch exists and was answered with another fail: the guard
    # (keyed by the slot's request_id = the id the dispatch answered) must not
    # treat attempt 2 as in flight for the attempt-3 retry whose request_id is
    # the NEW failed reply.
    let disp2 = make-msg "coordinator@smolfire.local" "t1@smolfire.local" "<disp2@host>" "task_id = \"t1\"\naction = \"dispatch\"\nexecutor = \"vm\"" --in-reply-to "<reply1@host>" --attempt 2
    let rep2 = make-msg "t1@smolfire.local" "coordinator@smolfire.local" "<reply2@host>" $FAIL_BODY --in-reply-to "<disp2@host>"
    let spool = (base-spool $FAIL_BODY) + $disp2 + $rep2
    let blank = {task_id: "", request_id: "", to_addr: "", dispatched_at: "", not_before: "", prior_attempt_msgid: "", prior_attempt_count: 0, format_violation: ""}
    let tmp = make-temp-dir
    write-spool (spool-path $tmp) $spool
    write-state (state-path $tmp) {
        version: "1", tick_count: 9, fsm_state: "idle"
        seen_ids: ["<req1@host>", "<disp1@host>", "<reply1@host>", "<disp2@host>", "<reply2@host>"]
        last_tick_at: "2026-01-01T00:00:00Z"
        pending_request_id: "", pending_task_id: "", pending_to_addr: "", dispatched_at: ""
        attempt_counts: {t1: 2}, halted_tasks: []
        task_executors: {t1: {executor: "vm", network: false, request_id: "<req1@host>"}}
        inflight: {t1: {executor: "vm", since_tick: 1}}
        pending_slots: {
            fleet: [$blank, $blank]
            jail: [$blank, $blank]
            vm: [
                {task_id: "t1", request_id: "<reply2@host>", to_addr: "t1@smolfire.local", dispatched_at: "", not_before: "2020-01-01T00:00:00Z", prior_attempt_msgid: "<reply2@host>", prior_attempt_count: 2, format_violation: ""}
                $blank
                $blank
                $blank
            ]
        }
    }
    let r = run-tick $tmp
    assert equal $r.exit_code 0
    assert equal (count-dispatches (spool-path $tmp)) 3 "attempt 3 sent exactly once"
    assert ((open --raw (spool-path $tmp)) | str contains "X-Attempt: 3") "X-Attempt 3"
    assert (not ($r.stdout | str contains "dispatch_skipped_inflight")) "guard did not misfire"
    ^rm -rf $tmp
    print "  ok"
}

# ── 5. default behaviour / kill switch ────────────────────────────────────────

print "interaction 8: SMOLFIRE_RETRY_BACKOFF unset == ON for every executor; only exactly 0 disables"
do {
    for executor in ["vm", "jail", "fleet"] {
        let tmp = setup (waiting-state 1 $executor) (base-spool $FAIL_BODY $executor)
        let r = run-tick $tmp
        assert equal $r.exit_code 0 $"($executor): exits 0"
        assert equal (count-dispatches (spool-path $tmp)) 1 $"($executor): unset -> retry held, not sent"
        let sl = slot-for (read-state (state-path $tmp)) $executor "t1"
        assert ($sl != null and $sl.not_before != "" and $sl.dispatched_at == "") $"($executor): held with not_before"
        ^rm -rf $tmp
    }
    # "1" is ON; unrecognised spellings are NOT the kill switch.
    for val in ["1", "false", "off", ""] {
        let tmp = setup (waiting-state 1) (base-spool $FAIL_BODY)
        let r = run-tick $tmp {SMOLFIRE_RETRY_BACKOFF: $val}
        assert equal (count-dispatches (spool-path $tmp)) 1 $"RETRY_BACKOFF='($val)' still backs off"
        ^rm -rf $tmp
    }
    let tmp = setup (waiting-state 1) (base-spool $FAIL_BODY)
    let r = run-tick $tmp {SMOLFIRE_RETRY_BACKOFF: "0"}
    assert equal (count-dispatches (spool-path $tmp)) 2 "RETRY_BACKOFF=0 retries immediately"
    ^rm -rf $tmp
    print "  ok"
}

print "all tests passed"
