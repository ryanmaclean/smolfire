# SPDX-License-Identifier: Apache-2.0
# tests/coord-fsm-tests.nu — integration tests for the coord-tick.nu FSM
#
# Each test is hermetic: it creates a temp directory, exercises the FSM
# via `nu bin/coord-tick.nu`, reads back the state file, then cleans up.
#
# All tests return {name, status, detail} and are collected by run-coord-fsm-tests.
#
# Run standalone (CI gate — exits 1 if any test fails):
#   nu tests/coord-fsm-tests.nu
# Also wired into tests/run-all.sh, prd.json qualityChecks, and
# tests/run-tests.nu --suite unit (via run-coord-fsm-tests).
#
# Tests 6–9 are the S-005 telemetry gate: they parse every `state_transition`
# and `verdict` event emitted by bin/coord-tick.nu across several fixture
# scenarios and assert a fixed schema (names + key order), closed value
# enumerations, expected transition sequences, and run-to-run determinism.

use ../bin/mbox-parse.nu [parse-mbox, msg-id]

const COORD_TICK = path self | path dirname | path dirname | path join "bin" "coord-tick.nu"

# ── Telemetry contract (schema v1) ─────────────────────────────────────────────
# Deliberately an independent copy of the contract documented in
# bin/coord-tick.nu: if the emitter drifts, these tests fail.
const TELEMETRY_FIELDS_V1 = [
    schema_version ts event state_from state_to task_id verdict attempt reason message_id
]
const TELEMETRY_KINDS   = [state_transition verdict]
const FSM_STATES        = [idle harvesting dispatching waiting halted]
const VERDICT_VALUES    = [pass fail blocked malformed unknown]
const TRANSITION_REASONS = [
    spool-absent no-new-messages new-messages
    new-request retry task-halted harvest-complete
    reply-received no-reply reply-timeout
    dispatch-sent
    halt-marker-present awaiting-resume resume-action
    unknown-state
]
const VERDICT_REASONS = [accepted retry retry-exhausted no-unblocker parse-error unrecognized-verdict]

# ── Helper: run coord-tick in a subprocess ─────────────────────────────────────

# Run coord-tick.nu once with the given temp root directory.
# spool and state paths are passed as relative paths (they get joined to root inside coord-tick).
# Returns {stdout, exit_code, state} where state is the parsed TOML state record (or {}).
#
# Hermetic: the child runs with every PATH directory that contains a `claude`
# executable removed (so state-dispatching never launches a real subagent —
# it logs subagent_spawn_skipped instead) and with SMOLFIRE_IRC_HOST unset (so
# the HALT IRC fallback is inert). nu itself is invoked by absolute path.
def run-coord [
    root:      string        # temp root directory
    spool_rel: string        # spool path relative to root (e.g. "var/mail/spool")
    state_rel: string        # state-file path relative to root (e.g. "var/run/coord-state.toml")
    max_ticks: int = 5
] {
    let nu_bin = $nu.current-exe
    let hermetic_path = $env.PATH | where {|d| not ($d | path join "claude" | path exists) }
    let result = with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_IRC_HOST
        (^$nu_bin --no-config-file $COORD_TICK
            --root $root
            --spool $spool_rel
            --state-file $state_rel
            --max-ticks $max_ticks
        ) | complete
    }

    let state_path = [$root, $state_rel] | path join
    let state = if ($state_path | path exists) {
        try { open --raw $state_path | from toml } catch { {} }
    } else {
        {}
    }

    {
        stdout:    $result.stdout
        exit_code: $result.exit_code
        state:     $state
    }
}

# Create a minimal temp root with the required sub-directories.
# Returns the temp root path string.
def make-temp-root [] {
    let tmp = ^mktemp -d | str trim
    mkdir ($tmp | path join "var" "mail")
    mkdir ($tmp | path join "var" "run")
    $tmp
}

# Remove the temp root directory.
def cleanup [root: string] {
    if ($root | path exists) {
        rm -rf $root
    }
}

# Build a minimal mbox reply envelope (agent→coordinator).
def make-reply-msg [
    msg_id:     string   # e.g. "<task-0001.tester@smolfire.local>"
    in_reply_to: string  # e.g. "<task-0001.coord@smolfire.local>"  (empty string for fresh messages)
] {
    let dstamp = "Mon May  4 10:00:00 2026"
    let ts     = "Mon, 4 May 2026 10:00:00 -0000"
    let irt_header = if ($in_reply_to | str length) > 0 {
        $"In-Reply-To: ($in_reply_to)\n"
    } else {
        ""
    }

    $"From agent@smolfire.local ($dstamp)\nFrom: agent@smolfire.local\nTo: coordinator@smolfire.local\nSubject: reply to task\nDate: ($ts)\nMessage-ID: ($msg_id)\n($irt_header)Content-Type: text/toml; charset=utf-8\n\ntask_id = \"test-task\"\nverdict  = \"pass\"\n"
}

# ── Test 1: idle → no-op when spool is empty ──────────────────────────────────

def test-idle-empty-spool [] {
    let name = "FSM: idle stays idle on empty spool"
    let root = make-temp-root

    # Create an empty spool file.
    "" | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 3

    let state = $r.state

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "idle"
        and ($state | get seen_ids? | default [] | length) == 0
        and ($state | get tick_count? | default 0) >= 1
        and ([$root, "var/run/coord-state.toml"] | path join | path exists)
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"exit=($r.exit_code) fsm_state=idle seen_ids=0"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) state=($state | to nuon)"}
    }
}

# ── Test 2: idle → harvesting → idle on one inbound reply message ─────────────

def test-idle-to-harvesting-to-idle [] {
    let name = "FSM: idle->harvesting->idle on new message"
    let root = make-temp-root

    let msg_id = "<task-0001.tester@smolfire.local>"
    let envelope = make-reply-msg $msg_id ""

    $envelope | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state = $r.state
    let seen  = $state | get seen_ids? | default []

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "idle"
        and ($seen | length) == 1
        and ($seen | any {|id| $id == $msg_id})
        and ($r.stdout | str contains "harvest_message")
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"seen_ids=($seen | to nuon) harvest_message logged"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) state=($state | to nuon) stdout_snippet=($r.stdout | str substring ..300)"}
    }
}

# ── Test 3: dispatching → waiting → idle cycle ────────────────────────────────

def test-dispatching-to-waiting-to-idle [] {
    let name = "FSM: dispatching->waiting->idle cycle"
    let root = make-temp-root

    let task_id   = "task-0002"
    let spool_path = $root | path join "var" "mail" "spool"

    # Seed state: FSM in "dispatching" with pending request fields populated
    # to match the current state-dispatching contract in coord-tick.nu.
    let initial_req_id = $"<task-0002.initial@smolfire.local>"
    let seed_state = {
        version:            "1"
        tick_count:         0
        fsm_state:          "dispatching"
        seen_ids:           [$initial_req_id]
        last_tick_at:       "2026-05-04T10:00:00Z"
        pending_request_id: $initial_req_id
        pending_task_id:    $task_id
        pending_to_addr:    "builder@smolfire.local"
        dispatched_at:      ""
        attempt_counts:     {}
        halted_tasks:       []
    }

    let state_path = $root | path join "var" "run" "coord-state.toml"
    $seed_state | to toml | save $state_path

    # Start with empty spool.
    "" | save $spool_path

    # First tick: dispatching → writes envelope → moves to waiting.
    let r1 = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 3

    let state1        = $r1.state
    let spool_content = open --raw $spool_path
    let spool_msgs    = parse-mbox $spool_content

    let dispatched_ok = (
        $r1.exit_code == 0
        and ($state1 | get fsm_state? | default "") == "waiting"
        and ($spool_msgs | length) > 0
        and ($r1.stdout | str contains "dispatch_sent")
    )

    if not $dispatched_ok {
        cleanup $root
        return {
            name: $name
            status: "fail"
            detail: $"tick1: exit=($r1.exit_code) fsm=($state1.fsm_state? | default '?') spool_msgs=($spool_msgs | length) stdout=($r1.stdout | str substring ..300)"
        }
    }

    # Extract the actual dispatched Message-ID from the spool (state-dispatching
    # generates IDs like <coord.N.rN.TS@smolfire.local>) and reference it.
    let dispatched_id = $spool_msgs | last | get headers | get "Message-ID"
    let reply_id  = "<task-0002.reply@smolfire.local>"
    let reply_env = make-reply-msg $reply_id $dispatched_id
    $reply_env | save --append $spool_path

    # Second tick: waiting → reply found → harvesting → idle.
    let r2     = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5
    let state2 = $r2.state
    let seen2  = $state2 | get seen_ids? | default []

    let ok = (
        $r2.exit_code == 0
        and ($state2 | get fsm_state? | default "") == "idle"
        and ($seen2 | any {|id| $id == $reply_id})
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: $"dispatch->waiting->idle complete; reply_id in seen_ids"}
    } else {
        {name: $name, status: "fail", detail: $"tick2: exit=($r2.exit_code) fsm=($state2 | get fsm_state? | default '?') seen=($seen2 | to nuon) stdout=($r2.stdout | str substring ..300)"}
    }
}

# ── Test 4: HALT detection ────────────────────────────────────────────────────

def test-halt-detection [] {
    let name = "FSM: HALT marker stops FSM immediately"
    let root = make-temp-root

    # Write the HALT marker at var/mail/HALT (relative to root, per halt-present).
    let halt_path = $root | path join "var" "mail" "HALT"
    "reason = \"test halt\"\n" | save $halt_path

    # Empty spool (no messages should be written).
    "" | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state          = $r.state
    let spool_after    = open --raw ($root | path join "var" "mail" "spool")
    let spool_msgs     = parse-mbox $spool_after

    let ok = (
        $r.exit_code == 0
        and ($state | get fsm_state? | default "") == "halted"
        and ($spool_msgs | length) == 0
        and ($r.stdout | str contains "halted")
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: "fsm_state=halted, spool untouched, 'halted' in stdout"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) fsm=($state | get fsm_state? | default '?') spool_msgs=($spool_msgs | length) stdout=($r.stdout | str substring ..300)"}
    }
}

# ── Test 5: malformed message body ────────────────────────────────────────────

def test-malformed-message [] {
    let name = "FSM: malformed message body does not crash FSM"
    let root = make-temp-root

    # A valid mbox envelope but with a non-TOML body.
    let msg_id  = "<task-0003.malformed@smolfire.local>"
    let dstamp  = "Mon May  4 10:00:00 2026"
    let ts      = "Mon, 4 May 2026 10:00:00 -0000"
    let envelope = $"From agent@smolfire.local ($dstamp)\nFrom: agent@smolfire.local\nTo: coordinator@smolfire.local\nSubject: malformed body test\nDate: ($ts)\nMessage-ID: ($msg_id)\nContent-Type: text/toml; charset=utf-8\n\nThis is NOT valid TOML @@@@\n= broken [\n"

    $envelope | save ($root | path join "var" "mail" "spool")

    let r = run-coord $root "var/mail/spool" "var/run/coord-state.toml" 5

    let state = $r.state

    let verdicts = parse-telemetry $r.stdout | where event == "verdict"
    let ok = (
        $r.exit_code == 0
        and ($r.stdout | str contains "harvest_malformed")
        and ($verdicts | length) == 1
        and ($verdicts | first | get verdict) == "malformed"
        and ($verdicts | first | get reason) == "parse-error"
        and ($verdicts | first | get message_id) == $msg_id
    )

    cleanup $root

    if $ok {
        {name: $name, status: "pass", detail: "exit=0, harvest_malformed logged, verdict=malformed/parse-error emitted"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) stdout=($r.stdout | str substring ..400)"}
    }
}

# ── Telemetry helpers (S-005) ─────────────────────────────────────────────────

const SPOOL_REL = "var/mail/spool"
const STATE_REL = "var/run/coord-state.toml"

# Split coord-tick stdout into its TOML documents (separated by `---` lines).
# A chunk that is not valid TOML becomes {event: "_unparseable", raw: <chunk>}
# so the schema test can fail loudly instead of silently dropping it.
def parse-log-docs [stdout: string] {
    $stdout
    | split row --regex '(?m)^---$'
    | each {|chunk|
        let c = $chunk | str trim
        if $c == "" {
            null
        } else {
            try { $c | from toml } catch { {event: "_unparseable", raw: $c} }
        }
    }
    | compact
}

# Only the schema-governed telemetry events (state_transition + verdict).
def parse-telemetry [stdout: string] {
    parse-log-docs $stdout | where {|d| ($d | get event? | default "") in $TELEMETRY_KINDS }
}

# A full coordinator state record (TOML-serialisable) with optional overrides.
def seed-state [overrides: record] {
    {
        version:            "1"
        tick_count:         0
        fsm_state:          "idle"
        seen_ids:           []
        last_tick_at:       "2026-05-04T10:00:00Z"
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
        dispatched_at:      ""
        attempt_counts:     {}
        halted_tasks:       []
    } | merge $overrides
}

# Build one mbox message with a TOML body.
def mbox-msg [
    from_addr: string
    to_addr:   string
    msg_id:    string
    body:      string
    --in-reply-to: string = ""
] {
    let irt = if $in_reply_to != "" { $"In-Reply-To: ($in_reply_to)\n" } else { "" }
    $"From ($from_addr) Mon May  4 10:00:00 2026\nFrom: ($from_addr)\nTo: ($to_addr)\nSubject: s005 fixture\nMessage-ID: ($msg_id)\n($irt)Content-Type: text/toml; charset=utf-8\n\n($body)\n\n"
}

def spool-path [root: string] { [$root, $SPOOL_REL] | path join }

# Collapse a list of run-coord results into one scenario record.
def scenario-result [name: string, runs: list] {
    {
        name:       $name
        exit_codes: ($runs | get exit_code)
        docs:       ($runs | each {|r| parse-log-docs $r.stdout } | flatten)
        events:     ($runs | each {|r| parse-telemetry $r.stdout } | flatten)
    }
}

# Scenario: idle → harvesting → dispatching → waiting → harvesting → idle (→ idle).
def scenario-full-cycle [] {
    let root  = make-temp-root
    let spool = spool-path $root
    mbox-msg "user@smolfire.local" "builder@smolfire.local" "<s5-full.req@smolfire.local>" 'task_id = "s5-full"' | save $spool
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    let pending = $r1.state | get pending_request_id? | default ""
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-full.reply@smolfire.local>" "task_id = \"s5-full\"\nverdict = \"pass\"" --in-reply-to $pending | save --append $spool
    let r2 = run-coord $root $SPOOL_REL $STATE_REL 10
    let r3 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "full-cycle" [$r1 $r2 $r3]
}

# Scenario: global HALT marker present for two consecutive invocations.
def scenario-halt [] {
    let root = make-temp-root
    "reason = \"s005 test halt\"\n" | save ([$root, "var", "mail", "HALT"] | path join)
    "" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 5
    let r2 = run-coord $root $SPOOL_REL $STATE_REL 5
    cleanup $root
    scenario-result "halt" [$r1 $r2]
}

# Scenario: fail reply → retry dispatch (attempt 1) → second fail → retry (attempt 2).
def scenario-fail-retry [] {
    let root  = make-temp-root
    let spool = spool-path $root
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-retry.r0@smolfire.local>" "task_id = \"s5-retry\"\nverdict = \"fail\"" | save $spool
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    let pending = $r1.state | get pending_request_id? | default ""
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-retry.r1@smolfire.local>" "task_id = \"s5-retry\"\nverdict = \"fail\"" --in-reply-to $pending | save --append $spool
    let r2 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "fail-retry" [$r1 $r2]
}

# Scenario: fail reply with attempts already at 3 → HALT retry-exhausted (escalate).
# Single tick only: on origin/main a second tick treats the coordinator's own
# HALT message (it carries X-Resume-Tag) as an operator resume and un-halts the
# task — a separate S-002 bug; this scenario covers only the escalate emission.
def scenario-escalate-exhausted [] {
    let root = make-temp-root
    seed-state {attempt_counts: {"s5-esc": 3}} | to toml | save ([$root, $STATE_REL] | path join)
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-esc.r3@smolfire.local>" "task_id = \"s5-esc\"\nverdict = \"fail\"" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "escalate-exhausted" [$r1]
}

# Scenario: blocked reply with no blocked_by → immediate HALT no-unblocker.
def scenario-escalate-no-unblocker [] {
    let root = make-temp-root
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-blk.r0@smolfire.local>" "task_id = \"s5-blk\"\nverdict = \"blocked\"" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "escalate-no-unblocker" [$r1]
}

# Scenario: non-TOML body → verdict malformed/parse-error.
def scenario-malformed [] {
    let root = make-temp-root
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-bad.r0@smolfire.local>" "This is NOT valid TOML @@@@\n= broken [" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "malformed" [$r1]
}

# Scenario: pass reply that required attestation but carries no [[claims]] → malformed + retry.
def scenario-attestation-malformed [] {
    let root = make-temp-root
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-att.r0@smolfire.local>" "task_id = \"s5-att\"\nverdict = \"pass\"\nattestation_required = true" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "attestation-malformed" [$r1]
}

# Scenario: verdict outside the protocol enum → verdict=unknown, no state change.
def scenario-unknown-verdict [] {
    let root = make-temp-root
    mbox-msg "builder@smolfire.local" "coordinator@smolfire.local" "<s5-unk.r0@smolfire.local>" "task_id = \"s5-unk\"\nverdict = \"maybe\"" | save (spool-path $root)
    let r1 = run-coord $root $SPOOL_REL $STATE_REL 10
    cleanup $root
    scenario-result "unknown-verdict" [$r1]
}

def run-telemetry-scenarios [] {
    [
        (scenario-full-cycle)
        (scenario-halt)
        (scenario-fail-retry)
        (scenario-escalate-exhausted)
        (scenario-escalate-no-unblocker)
        (scenario-malformed)
        (scenario-attestation-malformed)
        (scenario-unknown-verdict)
    ]
}

# Expected telemetry per scenario.
#   transitions: "state_from>state_to:reason"
#   verdicts:    "verdict:reason>state_to"
const EXPECTED_SEQUENCES = {
    "full-cycle": {
        transitions: [
            "idle>harvesting:new-messages"
            "harvesting>dispatching:new-request"
            "dispatching>waiting:dispatch-sent"
            "waiting>waiting:no-reply"
            "waiting>harvesting:reply-received"
            "harvesting>idle:harvest-complete"
            "idle>idle:no-new-messages"
        ]
        verdicts: ["pass:accepted>harvesting"]
    }
    "halt": {
        transitions: ["idle>halted:halt-marker-present", "halted>halted:halt-marker-present"]
        verdicts: []
    }
    "fail-retry": {
        transitions: [
            "idle>harvesting:new-messages"
            "harvesting>dispatching:retry"
            "dispatching>waiting:dispatch-sent"
            "waiting>waiting:no-reply"
            "waiting>harvesting:reply-received"
            "harvesting>dispatching:retry"
            "dispatching>waiting:dispatch-sent"
            "waiting>waiting:no-reply"
        ]
        verdicts: ["fail:retry>dispatching", "fail:retry>dispatching"]
    }
    "escalate-exhausted": {
        transitions: [
            "idle>harvesting:new-messages"
            "harvesting>idle:task-halted"
        ]
        verdicts: ["fail:retry-exhausted>idle"]
    }
    "escalate-no-unblocker": {
        transitions: ["idle>harvesting:new-messages", "harvesting>idle:task-halted"]
        verdicts: ["blocked:no-unblocker>idle"]
    }
    "malformed": {
        transitions: ["idle>harvesting:new-messages", "harvesting>idle:harvest-complete"]
        verdicts: ["malformed:parse-error>harvesting"]
    }
    "attestation-malformed": {
        transitions: [
            "idle>harvesting:new-messages"
            "harvesting>dispatching:retry"
            "dispatching>waiting:dispatch-sent"
            "waiting>waiting:no-reply"
        ]
        verdicts: ["malformed:retry>dispatching"]
    }
    "unknown-verdict": {
        transitions: ["idle>harvesting:new-messages", "harvesting>idle:harvest-complete"]
        verdicts: ["unknown:unrecognized-verdict>harvesting"]
    }
}

# ── Test 6: fixed schema — identical ordered column names for every event ─────

def test-telemetry-schema [scenarios: list] {
    let name = "telemetry: every state_transition/verdict event has schema v1 columns in fixed order"
    let docs   = $scenarios | get docs | flatten
    let events = $scenarios | get events | flatten
    mut problems = []

    let unparseable = $docs | where {|d| ($d | get event? | default "") == "_unparseable" }
    if ($unparseable | length) > 0 {
        $problems = $problems | append $"($unparseable | length) unparseable log chunk\(s\)"
    }

    let bad_exit = $scenarios | where {|s| ($s.exit_codes | any {|c| $c != 0 }) } | get name
    if ($bad_exit | length) > 0 { $problems = $problems | append $"non-zero exit in: ($bad_exit | str join ', ')" }

    for kind in $TELEMETRY_KINDS {
        let of_kind = $events | where event == $kind
        if ($of_kind | length) == 0 {
            $problems = $problems | append $"no ($kind) events emitted"
            continue
        }
        let shapes = $of_kind | each {|e| $e | columns } | uniq
        if ($shapes | length) != 1 {
            $problems = $problems | append $"($kind): ($shapes | length) distinct column orders: ($shapes | to nuon)"
        } else if ($shapes | first) != $TELEMETRY_FIELDS_V1 {
            $problems = $problems | append $"($kind): columns ($shapes | first | to nuon) != schema ($TELEMETRY_FIELDS_V1 | to nuon)"
        }
    }

    let bad_version = $events | where {|e| ($e | get schema_version? | default "") != "v1" }
    if ($bad_version | length) > 0 { $problems = $problems | append $"($bad_version | length) events with schema_version != v1" }

    let bad_types = $events | where {|e|
        let str_fields = $TELEMETRY_FIELDS_V1 | where {|f| $f != "attempt" }
        (($e | get attempt? | describe) != "int") or ($str_fields | any {|f| ($e | get -o $f | describe) != "string" })
    }
    if ($bad_types | length) > 0 { $problems = $problems | append $"($bad_types | length) events with wrong field types, e.g. ($bad_types | first | to nuon)" }

    if ($problems | length) == 0 {
        let n_t = $events | where event == "state_transition" | length
        let n_v = $events | where event == "verdict" | length
        {name: $name, status: "pass", detail: $"($n_t) state_transition + ($n_v) verdict events across ($scenarios | length) scenario runs; columns == ($TELEMETRY_FIELDS_V1 | str join ',')"}
    } else {
        {name: $name, status: "fail", detail: ($problems | str join "; ")}
    }
}

# ── Test 7: closed enumerations ────────────────────────────────────────────────

def test-telemetry-enums [scenarios: list] {
    let name = "telemetry: state_from/state_to/verdict/reason values drawn from fixed enumerations"
    let events = $scenarios | get events | flatten
    let transitions = $events | where event == "state_transition"
    let verdicts    = $events | where event == "verdict"
    mut problems = []

    let bad_from = $events | where {|e| not ($e.state_from in $FSM_STATES) } | get state_from | uniq
    let bad_to   = $events | where {|e| not ($e.state_to in $FSM_STATES) }   | get state_to   | uniq
    if ($bad_from | length) > 0 { $problems = $problems | append $"state_from outside enum: ($bad_from | to nuon)" }
    if ($bad_to | length) > 0   { $problems = $problems | append $"state_to outside enum: ($bad_to | to nuon)" }

    let bad_tv = $transitions | where {|e| not ($e.verdict in ([""] | append $VERDICT_VALUES)) } | get verdict | uniq
    if ($bad_tv | length) > 0 { $problems = $problems | append $"transition verdict outside enum: ($bad_tv | to nuon)" }
    let bad_vv = $verdicts | where {|e| not ($e.verdict in $VERDICT_VALUES) } | get verdict | uniq
    if ($bad_vv | length) > 0 { $problems = $problems | append $"verdict event verdict outside enum (or null): ($bad_vv | to nuon)" }

    let bad_tr = $transitions | where {|e| not ($e.reason in $TRANSITION_REASONS) } | get reason | uniq
    if ($bad_tr | length) > 0 { $problems = $problems | append $"transition reason outside enum: ($bad_tr | to nuon)" }
    let bad_vr = $verdicts | where {|e| not ($e.reason in $VERDICT_REASONS) } | get reason | uniq
    if ($bad_vr | length) > 0 { $problems = $problems | append $"verdict reason outside enum: ($bad_vr | to nuon)" }

    let bad_vfrom = $verdicts | where {|e| $e.state_from != "harvesting" }
    if ($bad_vfrom | length) > 0 { $problems = $problems | append "verdict event with state_from != harvesting" }

    let bad_ts = $events | where {|e| not ($e.ts =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') }
    if ($bad_ts | length) > 0 { $problems = $problems | append $"($bad_ts | length) events with non-RFC3339-UTC ts" }

    let bad_attempt = $events | where {|e| $e.attempt < -1 }
    if ($bad_attempt | length) > 0 { $problems = $problems | append "attempt < -1 (only -1 is the null sentinel)" }

    if ($problems | length) == 0 {
        let seen = $events | each {|e| [$e.state_from $e.state_to] } | flatten | uniq | sort
        {name: $name, status: "pass", detail: $"states seen ($seen | str join ',') ; verdicts seen ($verdicts | get verdict | uniq | sort | str join ',')"}
    } else {
        {name: $name, status: "fail", detail: ($problems | str join "; ")}
    }
}

# ── Test 8: expected transition/verdict sequences per scenario ────────────────

def test-telemetry-sequences [scenarios: list] {
    let name = "telemetry: full/halt/retry/escalate/malformed runs emit the expected ordered transitions and verdicts"
    mut problems = []

    for s in $scenarios {
        let expected = $EXPECTED_SEQUENCES | get $s.name
        let ts = $s.events | where event == "state_transition"
        let vs = $s.events | where event == "verdict"
        let got_t = $ts | each {|e| $"($e.state_from)>($e.state_to):($e.reason)" }
        let got_v = $vs | each {|e| $"($e.verdict):($e.reason)>($e.state_to)" }
        if $got_t != $expected.transitions {
            $problems = $problems | append $"($s.name) transitions ($got_t | to nuon) != ($expected.transitions | to nuon)"
        }
        if $got_v != $expected.verdicts {
            $problems = $problems | append $"($s.name) verdicts ($got_v | to nuon) != ($expected.verdicts | to nuon)"
        }
        # Chain continuity: each transition starts where the previous one ended,
        # including across process restarts (state is persisted to TOML).
        let n = $ts | length
        if $n > 1 {
            let breaks = 1..($n - 1) | where {|i| ($ts | get ($i - 1) | get state_to) != ($ts | get $i | get state_from) }
            if ($breaks | length) > 0 { $problems = $problems | append $"($s.name) transition chain broken at index ($breaks | to nuon)" }
        }
    }

    # Attempt accounting on the retry path: dispatch-sent carries 1, then 2.
    let retry = $scenarios | where name == "fail-retry" | first
    let sent_attempts = $retry.events | where {|e| $e.event == "state_transition" and $e.reason == "dispatch-sent" } | get attempt
    if $sent_attempts != [1 2] { $problems = $problems | append $"fail-retry dispatch-sent attempts ($sent_attempts | to nuon) != [1, 2]" }
    let esc = $scenarios | where name == "escalate-exhausted" | first
    let esc_v = $esc.events | where event == "verdict" | get -o 0
    if ($esc_v == null) or ($esc_v.attempt != 3) or ($esc_v.task_id != "s5-esc") {
        $problems = $problems | append $"escalate-exhausted verdict attempt/task_id wrong: ($esc_v | to nuon)"
    }

    if ($problems | length) == 0 {
        {name: $name, status: "pass", detail: $"($scenarios | length) scenarios match expected sequences; chains continuous; retry attempts [1,2]"}
    } else {
        {name: $name, status: "fail", detail: ($problems | str join "; ")}
    }
}

# ── Test 9: determinism — identical fixtures → identical events ───────────────

# Mask the only legitimately run-dependent parts: ts, and the timestamp segment
# of coordinator-generated Message-IDs (<coord.N.rN.YYYYmmddHHMMSS@...>).
def normalize-event [e: record] {
    $e
    | update ts "<ts>"
    | update message_id ($e.message_id | str replace --regex '\.\d{14}@' '.<ts>@')
}

def test-telemetry-determinism [run_a: list, run_b: list] {
    let name = "telemetry: two runs with identical fixtures emit identical events (modulo ts / message-id timestamps)"
    mut problems = []
    for pair in ($run_a | zip $run_b) {
        let a = $pair.0
        let b = $pair.1
        # to nuon preserves key order, so this compares names, order, and values.
        let na = $a.events | each {|e| normalize-event $e | to nuon }
        let nb = $b.events | each {|e| normalize-event $e | to nuon }
        if ($na | length) != ($nb | length) {
            $problems = $problems | append $"($a.name): ($na | length) vs ($nb | length) events"
        } else if $na != $nb {
            let idx = 0..(($na | length) - 1) | where {|i| ($na | get $i) != ($nb | get $i) } | first
            $problems = $problems | append $"($a.name): first diff at #($idx): ($na | get $idx) vs ($nb | get $idx)"
        }
    }
    if ($problems | length) == 0 {
        {name: $name, status: "pass", detail: $"($run_a | get events | flatten | length) events identical across 2 runs of ($run_a | length) scenarios"}
    } else {
        {name: $name, status: "fail", detail: ($problems | str join "; ")}
    }
}

# ── Public entry point ────────────────────────────────────────────────────────

# Run all FSM integration tests and return a list of {name, status, detail}.
export def run-coord-fsm-tests [] {
    mut results = []

    $results = $results | append (try { test-idle-empty-spool }            catch {|e| {name: "FSM: idle stays idle on empty spool",            status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-idle-to-harvesting-to-idle }  catch {|e| {name: "FSM: idle->harvesting->idle on new message",      status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-dispatching-to-waiting-to-idle } catch {|e| {name: "FSM: dispatching->waiting->idle cycle",        status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-halt-detection }               catch {|e| {name: "FSM: HALT marker stops FSM immediately",         status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-malformed-message }            catch {|e| {name: "FSM: malformed message body does not crash FSM", status: "fail", detail: $"exception: ($e.msg)"}})

    # S-005 telemetry gate: run every scenario twice (second run feeds the
    # determinism check; both runs feed the schema/enum checks).
    let telemetry = try {
        {ok: true, a: (run-telemetry-scenarios), b: (run-telemetry-scenarios)}
    } catch {|e|
        {ok: false, err: $e.msg}
    }
    if $telemetry.ok {
        let both = $telemetry.a | append $telemetry.b
        $results = $results | append (try { test-telemetry-schema $both }      catch {|e| {name: "telemetry: schema", status: "fail", detail: $"exception: ($e.msg)"}})
        $results = $results | append (try { test-telemetry-enums $both }       catch {|e| {name: "telemetry: enums", status: "fail", detail: $"exception: ($e.msg)"}})
        $results = $results | append (try { test-telemetry-sequences $telemetry.a } catch {|e| {name: "telemetry: sequences", status: "fail", detail: $"exception: ($e.msg)"}})
        $results = $results | append (try { test-telemetry-determinism $telemetry.a $telemetry.b } catch {|e| {name: "telemetry: determinism", status: "fail", detail: $"exception: ($e.msg)"}})
    } else {
        for n in ["telemetry: schema", "telemetry: enums", "telemetry: sequences", "telemetry: determinism"] {
            $results = $results | append {name: $n, status: "fail", detail: $"scenario run exception: ($telemetry.err)"}
        }
    }

    $results
}

# ── Standalone runner ─────────────────────────────────────────────────────────
# `nu tests/coord-fsm-tests.nu` prints the results table and exits 1 if any
# test status is not "pass" — this is the contract run-all.sh and CI rely on.
def main [] {
    let results = run-coord-fsm-tests
    print ($results | table --expand --width 200)

    let passed = $results | where status == "pass" | length
    let total  = $results | length
    print $"=== coord-fsm tests: ($passed)/($total) pass ==="

    if $passed != $total { exit 1 }
}
