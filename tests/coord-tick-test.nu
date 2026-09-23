# SPDX-License-Identifier: Apache-2.0
# coord-tick-test.nu — integration tests for bin/coord-tick.nu FSM

# Inline assert helpers — avoids std library version sensitivity.
def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool] {
    if not $cond { error make {msg: "assert failed"} }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a fresh temporary directory.
def make-temp-dir [] {
    ^mktemp -d | str trim
}

# Write a TOML state file at the given absolute path.
def write-state [path: string, state: record] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $state | to toml | save --force $path
}

# Read back the TOML state file.
def read-state [path: string] {
    open --raw $path | from toml
}

# Write raw mbox content to an absolute spool path.
def write-spool [path: string, content: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) { mkdir $dir }
    $content | save --force $path
}

# Run one coordinator tick.
# --state-file and --spool are relative paths joined to --root inside coord-tick.nu.
def run-tick [
    root:      string
    state_rel: string   # relative to root
    spool_rel: string   # relative to root
] {
    ^nu bin/coord-tick.nu --state-file $state_rel --spool $spool_rel --root $root | ignore
}

# Build a minimal mbox message string.
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

# ── Tests ─────────────────────────────────────────────────────────────────────

print "test 1: idle — no spool"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert equal $state.tick_count 1

    ^rm -rf $tmp
}

print "test 2: idle — spool exists but message already in seen_ids"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<already.seen@host>"
    let msg = make-msg "sender@host" "recipient@host" $msg_id 'task_id = "t0"'
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         1
        fsm_state:          "idle"
        seen_ids:           [$msg_id]
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert equal $state.tick_count 2

    ^rm -rf $tmp
}

print "test 3: idle → harvesting → idle (reply message, pass verdict)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<reply.pass.001@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t1\""
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert ($msg_id in $state.seen_ids)

    ^rm -rf $tmp
}

print "test 4: idle → harvesting → dispatching → waiting (request message)"
do {
    # An unseen request (not addressed to coordinator, no In-Reply-To) triggers:
    # idle → harvesting → dispatching → waiting
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<request.t2.001@host>"
    let body = "task_id = \"t2\""
    let msg = make-msg "coordinator@smolfire.local" "agent@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # After harvesting a request: dispatching appends to spool and transitions to waiting.
    assert equal $state.fsm_state "waiting"
    assert (($state.pending_request_id | str length) > 0)

    ^rm -rf $tmp
}

print "test 5: waiting → waiting (no matching reply in spool)"
do {
    # state-waiting checks for In-Reply-To matching pending_request_id.
    # No such message in spool → stays in waiting.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<unrelated.001@host>"
    let body = "task_id = \"other\""
    let msg = make-msg "sender@host" "recipient@host" $msg_id $body
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         3
        fsm_state:          "waiting"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: "<req.123@host>"
        pending_task_id:    "t2"
        pending_to_addr:    "agent@smolfire.local"
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "waiting"

    ^rm -rf $tmp
}

print "test 6: waiting → harvesting (reply found — In-Reply-To matches)"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let pending_id = "<req.123@host>"
    let reply_id   = "<reply.for.req123@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t2\""
    let msg = (make-msg "agent@smolfire.local" "coordinator@smolfire.local" $reply_id $body
               --in-reply-to $pending_id)
    write-spool $spool_abs $msg

    write-state $state_abs {
        version:            "1"
        tick_count:         2
        fsm_state:          "waiting"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: $pending_id
        pending_task_id:    "t2"
        pending_to_addr:    "agent@smolfire.local"
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # waiting detects reply → transitions to harvesting → processes reply → idle.
    assert ($reply_id in $state.seen_ids)
    assert (($state.fsm_state == "idle") or ($state.fsm_state == "harvesting"))

    ^rm -rf $tmp
}

print "test 7: HALT file present → halted"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"

    let halt_dir = [$tmp, "var", "mail"] | path join
    mkdir $halt_dir
    "" | save --force ([$halt_dir, "HALT"] | path join)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "halted"

    ^rm -rf $tmp
}

print "test 8: verdict fail on first attempt → retry dispatched, no global HALT"
do {
    # On the first fail (attempt_n = 0 < 3) the coordinator must retry:
    # it should transition dispatching → waiting and increment the attempt count.
    # A global var/mail/HALT file must NOT be created on the first failure.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<reply.fail.t3@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t3\""
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # Retry should have been dispatched → waiting
    assert equal $state.fsm_state "waiting"
    # Attempt count for t3 should have been incremented
    assert equal ($state.attempt_counts | get "t3"? | default 0) 1
    # No global HALT file should exist on the first failure
    let halt_path = [$tmp, "var", "mail", "HALT"] | path join
    assert (not ($halt_path | path exists))

    ^rm -rf $tmp
}

print "test 9: attempt counter increments on fail"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<fail.1@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t-retry\""
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # attempt_counts should have an entry for t-retry (value >= 1)
    assert (($state.attempt_counts | get "t-retry"? | default 0) >= 1)
    # retry should have been dispatched → waiting
    assert equal $state.fsm_state "waiting"

    ^rm -rf $tmp
}

print "test 10: retry exhausted → HALT file created"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Seed spool dir so HALT can be written
    let spool_dir = [$tmp, "var", "mail"] | path join
    mkdir $spool_dir

    # Manually write state with attempt_counts = {t-exhaust: 3}
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir
    (
        "version = \"1\"\n" +
        "tick_count = 0\n" +
        "fsm_state = \"idle\"\n" +
        "seen_ids = []\n" +
        "last_tick_at = \"2026-01-01T00:00:00Z\"\n" +
        "pending_request_id = \"\"\n" +
        "pending_task_id = \"\"\n" +
        "pending_to_addr = \"\"\n\n" +
        "[attempt_counts]\n" +
        "t-exhaust = 3\n"
    ) | save --force $state_abs

    let msg_id = "<fail.exhaust@host>"
    let body = "verdict = \"fail\"\ntask_id = \"t-exhaust\""
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    # Accept either per-task HALT or bare HALT
    let halt1 = [$tmp, "var", "mail", "HALT.t-exhaust"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"] | path join
    assert (($halt1 | path exists) or ($halt2 | path exists))

    ^rm -rf $tmp
}

print "test 11: capability mismatch → message skipped, no dispatch"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<cap.mismatch.t-cap@host>"
    let body = "task_id = \"t-cap\"\nagent_type = \"reviewer\"\ntools_required = [\"Write\", \"Bash\"]"
    # outbound request (not to coordinator)
    let msg = make-msg "coordinator@smolfire.local" "reviewer@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # reviewer lacks Write/Bash → skipped, no dispatch → idle
    assert equal $state.fsm_state "idle"
    assert ($msg_id in $state.seen_ids)

    ^rm -rf $tmp
}

print "test 12: attestation fail → treated as retry"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<attest.fail.t-attest@host>"
    let body = "verdict = \"pass\"\ntask_id = \"t-attest\"\nattestation_required = true"
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # pass without claims → MALFORMED → retry → waiting
    assert equal $state.fsm_state "waiting"
    assert (($state.attempt_counts | get "t-attest"? | default 0) >= 1)

    ^rm -rf $tmp
}

print "test 12b: request-level attestation requirement enforced on reply"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req_id = "<req.attest.t-attest-req@host>"
    let req_body = "task_id = \"t-attest-req\"\nattestation_required = true"
    # Mark this as a historical request context message (non-dispatchable via in-reply-to).
    let req_msg = make-msg "coordinator@smolfire.local" "builder@smolfire.local" $req_id $req_body --in-reply-to "<seed@host>"

    let reply_id = "<reply.attest.t-attest-req@host>"
    let reply_body = "verdict = \"pass\"\ntask_id = \"t-attest-req\""
    let reply_msg = make-msg "builder@smolfire.local" "coordinator@smolfire.local" $reply_id $reply_body --in-reply-to $req_id

    write-spool $spool_abs ($req_msg + "\n" + $reply_msg)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # request required attestation + reply has no claims -> MALFORMED -> retry -> waiting
    assert equal $state.fsm_state "waiting"
    assert (($state.attempt_counts | get "t-attest-req"? | default 0) >= 1)

    ^rm -rf $tmp
}

print "test 12c: request-level attestation satisfied by claims in reply"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let req_id = "<req.attest.t-attest-ok@host>"
    let req_body = "task_id = \"t-attest-ok\"\nattestation_required = true"
    let req_msg = make-msg "coordinator@smolfire.local" "builder@smolfire.local" $req_id $req_body --in-reply-to "<seed@host>"

    let reply_id = "<reply.attest.t-attest-ok@host>"
    let reply_body = "verdict = \"pass\"\ntask_id = \"t-attest-ok\"\n\n[[claims]]\nsubject = \"proof\"\nverdict = \"pass\""
    let reply_msg = make-msg "builder@smolfire.local" "coordinator@smolfire.local" $reply_id $reply_body --in-reply-to $req_id

    write-spool $spool_abs ($req_msg + "\n" + $reply_msg)

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    assert equal $state.fsm_state "idle"
    assert ($reply_id in $state.seen_ids)

    ^rm -rf $tmp
}

print "test 12d: attestation required on original request is enforced for replies to dispatched message"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Tick 1: original request requires attestation, coordinator dispatches and enters waiting.
    let req_id = "<req.attest.dispatch.chain@host>"
    let req_body = "task_id = \"t-attest-chain\"\nattestation_required = true"
    let req_msg = make-msg "user@smolfire.local" "builder@smolfire.local" $req_id $req_body
    write-spool $spool_abs $req_msg
    run-tick $tmp $state_rel $spool_rel

    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting"
    let dispatch_id = $st1.pending_request_id

    # Tick 2: agent replies to coordinator dispatch without claims.
    # Coordinator must follow In-Reply-To chain to enforce original requirement.
    let reply_id = "<reply.attest.dispatch.chain@host>"
    let reply_body = "verdict = \"pass\"\ntask_id = \"t-attest-chain\""
    let reply_msg = make-msg "builder@smolfire.local" "coordinator@smolfire.local" $reply_id $reply_body --in-reply-to $dispatch_id
    $reply_msg | save --append $spool_abs
    run-tick $tmp $state_rel $spool_rel

    let st2 = read-state $state_abs
    # pass without claims should be treated as malformed/retry, not accepted.
    assert equal $st2.fsm_state "waiting"
    assert (($st2.attempt_counts | get "t-attest-chain"? | default 0) >= 2)

    ^rm -rf $tmp
}

print "test 13: blocked+no-unblocker → immediate HALT, no retry"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let msg_id = "<blocked.no-unblocker.t-block@host>"
    let body = "verdict = \"blocked\"\ntask_id = \"t-block\""
    let msg = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    run-tick $tmp $state_rel $spool_rel

    # HALT file must exist
    let halt1 = [$tmp, "var", "mail", "HALT.t-block"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"] | path join
    assert (($halt1 | path exists) or ($halt2 | path exists))

    # No retry should have been attempted (attempt_counts for t-block == 0 or absent)
    let state = read-state $state_abs
    let attempt = $state.attempt_counts | get "t-block"? | default 0
    assert equal $attempt 0

    ^rm -rf $tmp
}

print "test 14: dispatch → reply round-trip (pending_request_id fix)"
do {
    # Validates that after dispatching, pending_request_id is set to the coordinator's
    # outgoing <coord.N.rM.TS@...> message ID, enabling state-waiting to match replies.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Tick 1: seed spool with an outbound request (not to coordinator, no In-Reply-To).
    let req_msg = make-msg "user@smolfire.local" "builder@smolfire.local" "<orig.req.14@host>" (
        "task_id = \"t14\""
    )
    write-spool $spool_abs $req_msg

    run-tick $tmp $state_rel $spool_rel

    # After tick 1: idle → harvesting → dispatching → waiting.
    let st1 = read-state $state_abs
    assert equal $st1.fsm_state "waiting"
    # pending_request_id must now be the coordinator's outgoing message ID.
    assert ($st1.pending_request_id | str starts-with "<coord.")

    let coord_msg_id = $st1.pending_request_id

    # Tick 2: append a reply addressed to coordinator with In-Reply-To = coord_msg_id.
    let reply_msg = (make-msg "builder@smolfire.local" "coordinator@smolfire.local" "<reply.14@host>"
        "task_id = \"t14\"\nverdict = \"pass\""
        --in-reply-to $coord_msg_id)
    $reply_msg | save --append $spool_abs

    run-tick $tmp $state_rel $spool_rel

    # After tick 2: waiting → harvesting → idle; reply is in seen_ids.
    let st2 = read-state $state_abs
    assert equal $st2.fsm_state "idle"
    assert ("<reply.14@host>" in $st2.seen_ids)

    ^rm -rf $tmp
}

print "test 15: resume action — retry clears halted task"
do {
    # Validates that state-halted processes a retry resume message:
    # removes the task from halted_tasks and deletes var/mail/HALT.<task_id>.
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Write state with t15 in halted_tasks.
    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir
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
        "halted_tasks = [\"t15\"]\n\n" +
        "[attempt_counts]\n"
    ) | save --force $state_abs

    # Create HALT (global) and per-task HALT.t15 markers.
    "" | save --force ([$mail_dir, "HALT"] | path join)
    (
        "task_id = \"t15\"\n" +
        "reason = \"retry-exhausted\"\n"
    ) | save --force ([$mail_dir, "HALT.t15"] | path join)

    # Seed spool with a resume message using action = retry.
    let resume_msg = (make-msg "user@smolfire.local" "coordinator@smolfire.local" "<resume.t15@host>"
        "task_id = \"t15\"\naction = \"retry\"")
    # Add X-Resume-Tag and X-Resume-Action headers manually via raw string.
    let resume_raw = (
        "From user@smolfire.local Mon Jan  1 00:00:00 2026\n" +
        "From: user@smolfire.local\n" +
        "To: coordinator@smolfire.local\n" +
        "Message-ID: <resume.t15@host>\n" +
        "X-Resume-Tag: resume-t15\n" +
        "X-Resume-Action: retry\n" +
        "Content-Type: text/toml; charset=utf-8\n" +
        "\n" +
        "task_id = \"t15\"\n" +
        "action = \"retry\"\n"
    )
    write-spool $spool_abs $resume_raw

    run-tick $tmp $state_rel $spool_rel

    let st = read-state $state_abs
    # halted_tasks must no longer contain t15 after retry resume.
    let halted = $st.halted_tasks
    assert (not ("t15" in $halted))
    # Per-task HALT file must have been removed.
    let halt_task_path = [$tmp, "var", "mail", "HALT.t15"] | path join
    assert (not ($halt_task_path | path exists))

    ^rm -rf $tmp
}

print "test 16: abort resume keeps task halted"
do {
    # Validates that state-halted with action=abort logs and leaves the task halted
    # (does not re-dispatch; state is consistent without error).
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir
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
        "halted_tasks = [\"t15\"]\n\n" +
        "[attempt_counts]\n"
    ) | save --force $state_abs

    "" | save --force ([$mail_dir, "HALT"] | path join)
    (
        "task_id = \"t15\"\n" +
        "reason = \"retry-exhausted\"\n"
    ) | save --force ([$mail_dir, "HALT.t15"] | path join)

    # Seed spool with an abort resume message.
    let abort_raw = (
        "From user@smolfire.local Mon Jan  1 00:00:00 2026\n" +
        "From: user@smolfire.local\n" +
        "To: coordinator@smolfire.local\n" +
        "Message-ID: <abort.t15@host>\n" +
        "X-Resume-Tag: resume-t15\n" +
        "X-Resume-Action: abort\n" +
        "Content-Type: text/toml; charset=utf-8\n" +
        "\n" +
        "task_id = \"t15\"\n" +
        "action = \"abort\"\n"
    )
    write-spool $spool_abs $abort_raw

    run-tick $tmp $state_rel $spool_rel

    # Tick must complete without error; state file must be readable.
    let st = read-state $state_abs
    # abort does not re-dispatch: fsm_state must not be "waiting".
    assert ($st.fsm_state != "waiting")
    # Task remains halted (still in halted_tasks or state is halted).
    let halted = $st.halted_tasks
    let task_still_halted = ("t15" in $halted) or ($st.fsm_state == "halted")
    assert $task_still_halted

    ^rm -rf $tmp
}

print "test 16b: retry resume clears per-task halt without global HALT marker"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir

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
        "halted_tasks = [\"t16b\"]\n\n" +
        "[attempt_counts]\n"
    ) | save --force $state_abs

    # Per-task marker exists; no global HALT marker.
    (
        "task_id = \"t16b\"\n" +
        "reason = \"retry-exhausted\"\n"
    ) | save --force ([$mail_dir, "HALT.t16b"] | path join)

    let resume_raw = (
        "From user@smolfire.local Mon Jan  1 00:00:00 2026\n" +
        "From: user@smolfire.local\n" +
        "To: coordinator@smolfire.local\n" +
        "Message-ID: <resume.t16b@host>\n" +
        "X-Resume-Tag: resume-t16b\n" +
        "X-Resume-Action: retry\n" +
        "Content-Type: text/toml; charset=utf-8\n" +
        "\n" +
        "task_id = \"t16b\"\n" +
        "action = \"retry\"\n"
    )
    write-spool $spool_abs $resume_raw

    run-tick $tmp $state_rel $spool_rel

    let st = read-state $state_abs
    assert (not ("t16b" in $st.halted_tasks))
    assert (not (([$tmp, "var", "mail", "HALT.t16b"] | path join) | path exists))
    assert ($st.fsm_state != "halted")

    ^rm -rf $tmp
}

print "test 16c: retry-as-role clears per-task halt"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir
    let state_dir = [$tmp, "var", "run"] | path join
    mkdir $state_dir

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
        "halted_tasks = [\"t16c\"]\n\n" +
        "[attempt_counts]\n"
    ) | save --force $state_abs

    (
        "task_id = \"t16c\"\n" +
        "reason = \"retry-exhausted\"\n"
    ) | save --force ([$mail_dir, "HALT.t16c"] | path join)

    let resume_raw = (
        "From user@smolfire.local Mon Jan  1 00:00:00 2026\n" +
        "From: user@smolfire.local\n" +
        "To: coordinator@smolfire.local\n" +
        "Message-ID: <resume.t16c@host>\n" +
        "X-Resume-Tag: resume-t16c\n" +
        "X-Resume-Action: retry-as-builder\n" +
        "Content-Type: text/toml; charset=utf-8\n" +
        "\n" +
        "task_id = \"t16c\"\n"
    )
    write-spool $spool_abs $resume_raw

    run-tick $tmp $state_rel $spool_rel

    let st = read-state $state_abs
    assert (not ("t16c" in $st.halted_tasks))
    assert (not (([$tmp, "var", "mail", "HALT.t16c"] | path join) | path exists))
    assert ($st.fsm_state != "halted")

    ^rm -rf $tmp
}

print "test 17: IRC fallback — coordinator halts cleanly when IRC is unreachable"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    # Create required directories
    let mail_dir  = [$tmp, "var", "mail"] | path join
    let state_dir = [$tmp, "var", "run"]  | path join
    mkdir $mail_dir
    mkdir $state_dir

    # Seed state with attempt_counts = {t17: 3} — already at MAX_ATTEMPTS
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
        "halted_tasks = []\n\n" +
        "[attempt_counts]\n" +
        "t17 = 3\n"
    ) | save --force $state_abs

    # Seed a fail reply for t17 into the spool
    let msg_id = "<t17.fail.agent@smolfire.local>"
    let body   = "verdict = \"fail\"\ntask_id = \"t17\""
    let msg    = make-msg "agent@smolfire.local" "coordinator@smolfire.local" $msg_id $body
    write-spool $spool_abs $msg

    # Run coord-tick — must exit 0 even though IRC host is unreachable
    let exit_code = try { run-tick $tmp $state_rel $spool_rel; 0 } catch { 1 }
    assert equal $exit_code 0

    # HALT marker must have been written
    let halt1 = [$tmp, "var", "mail", "HALT.t17"] | path join
    let halt2 = [$tmp, "var", "mail", "HALT"]      | path join
    assert (($halt1 | path exists) or ($halt2 | path exists))

    # If task-specific HALT file exists, verify fallback_fired = true
    if ($halt1 | path exists) {
        let hinfo = open --raw $halt1 | from toml
        assert equal $hinfo.fallback_fired true
    }

    ^rm -rf $tmp
}

print "test 18: HALT message with X-Resume-Tag must NOT auto-resume on next tick"
do {
    let tmp = make-temp-dir
    let state_rel = "var/run/coord-state.toml"
    let state_abs = [$tmp, $state_rel] | path join
    let spool_rel = "var/mail/spool"
    let spool_abs = [$tmp, $spool_rel] | path join

    let mail_dir = [$tmp, "var", "mail"] | path join
    mkdir $mail_dir

    # Write HALT.t18 marker
    let halt_path = [$mail_dir, "HALT.t18"] | path join
    "task_id = \"t18\"\nreason = \"retry-exhausted\"" | save --force $halt_path

    # Write the coordinator's HALT message to spool (has X-Resume-Tag)
    let halt_msg = ("From coordinator@smolfire.local 20260101T000000\n" +
                    "From: coordinator@smolfire.local\n" +
                    "To: user@smolfire.local\n" +
                    "Subject: [HALT] t18 — retry-exhausted\n" +
                    "Message-ID: <halt-t18.coord@smolfire.local>\n" +
                    "X-Halt-Reason: retry-exhausted\n" +
                    "X-Resume-Tag: resume-t18\n" +
                    "Content-Type: text/toml; charset=utf-8\n\n" +
                    "task_id = \"t18\"\n" +
                    "reason = \"retry-exhausted\"\n")
    write-spool $spool_abs $halt_msg

    write-state $state_abs {
        version:            "1"
        tick_count:         5
        fsm_state:          "halted"
        seen_ids:           []
        last_tick_at:       "2026-01-01T00:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
        halted_tasks:       ["t18"]
    }

    run-tick $tmp $state_rel $spool_rel

    let state = read-state $state_abs
    # BUG: t18 was being auto-resumed by the coordinator's own HALT message.
    # FIXED: process-resume-actions now skips messages with Subject: [HALT]
    assert equal ($state.halted_tasks | length) 1
    assert equal ($state.halted_tasks | first) "t18"
    assert equal $state.fsm_state "halted"

    # The HALT message should be in seen_ids (consumed, not re-processed)
    assert equal ($state.seen_ids | length) 1
    assert equal ($state.seen_ids | first) "<halt-t18.coord@smolfire.local>"

    ^rm -rf $tmp
}

print "all tests passed"
