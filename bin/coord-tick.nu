# SPDX-License-Identifier: Apache-2.0
# coord-tick.nu — smolfire coordinator tick (actor model, tail-recursive FSM)
#
# Each invocation of `main` is ONE tick of the coordinator actor.
# State is loaded from --state-file at startup and saved back at exit.
# No global mutable state; every transition is a `tick` call with a new record.
#
# FSM states (per spec §12):
#   idle         — no work in progress; scan spool for new messages
#   dispatching  — writing a request into the spool and queuing a subagent launch
#   waiting      — request dispatched, polling spool for matching reply
#   harvesting   — new replies present; cross-check claims
#   halted       — global var/mail/HALT present OR all tasks failed; clears per-task on resume
#
# HALT check: one `stat var/mail/HALT` per tick entry — O(1) per spec §13.

use ./mbox-parse.nu [parse-mbox, extract-toml, msg-id]

# "Network" is a coordinator-level capability, not a Claude tool: it is the only
# tools_required entry that grants the jail executor a network stack (see
# docs/JAIL-EXECUTOR.md). The vm executor ignores it (QEMU user-net always has
# SLIRP egress).
const AGENT_CAPABILITIES = {
    "general-purpose":          ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "WebFetch", "WebSearch", "Network"]
    "feature-dev:code-architect": ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"]
    "architect":                ["Read", "Glob", "Grep", "WebFetch", "TodoWrite"]
    "researcher":               ["Read", "Glob", "Grep", "WebFetch", "WebSearch"]
    "security":                 ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
    "ops":                      ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "Network"]
    "builder":                  ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "Network"]
    "reviewer":                 ["Read", "Glob", "Grep", "WebFetch"]
}

const STATE_VERSION = "1"

# Task executors. `vm` (default) keeps today's dispatch path unchanged;
# `jail` (experimental, FreeBSD hosts only) runs the request's commands in an
# ephemeral jail via bin/jail-execute.nu. Selected per request by a TOML
# `executor = "vm"|"jail"` field, else SMOLFIRE_EXECUTOR, else "vm".
const EXECUTORS = ["vm", "jail"]
const DEFAULT_EXECUTOR = "vm"
const JAIL_EXECUTOR_SCRIPT = path self jail-execute.nu

# Default state for a fresh coordinator with no prior history.
def default-state [] {
    {
        version:            $STATE_VERSION
        tick_count:         0
        fsm_state:          "idle"
        seen_ids:           []
        last_tick_at:       (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        pending_request_id: ""
        pending_task_id:    ""
        pending_to_addr:    ""
        dispatched_at:      ""
        attempt_counts:     {}   # record keyed by task_id → int attempt count
        halted_tasks:       []
        task_executors:     {}   # task_id → {executor, network, request_id}; reused on retry
    }
}

# Load state from TOML file, or return the default if file absent / parse fails.
# Missing keys are filled in from default-state so old state files remain compatible.
def load-state [path: string] {
    if not ($path | path exists) {
        log-event "state_init" {path: $path, reason: "file absent"}
        return (default-state)
    }
    try {
        let loaded = open --raw $path | from toml
        (default-state) | merge $loaded
    } catch {|err|
        log-event "state_load_error" {path: $path, error: ($err | get msg? | default "parse error")}
        default-state
    }
}

# Persist state back to disk as TOML.
def save-state [state: record, path: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) {
        mkdir $dir
    }
    $state | to toml | save --force $path
}

# Emit a structured TOML log line to stdout.
# Every coordinator action is observable via stdout — pipe to `tee` if needed.
#
# log-event is for free-form DIAGNOSTIC events (payload shape varies per event).
# FSM state transitions and reply verdicts MUST NOT go through log-event — use
# log-transition / log-verdict below, which emit the fixed telemetry schema.
def log-event [event: string, payload: record] {
    let ts  = date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, event: $event} | merge $payload
    $row | to toml | print
    print "---"
}

# ── Deterministic telemetry (schema v1) ───────────────────────────────────────
#
# Every FSM step emits exactly one `state_transition` event; every reply the
# harvester classifies emits exactly one `verdict` event. Both kinds share ONE
# record shape, built in exactly one place (telemetry-record), so field names
# and key order are identical across every code path and every run.
#
# Wire format: same as log-event — a TOML document on stdout followed by a
# `---` separator line. Field order (schema_version = "v1"):
#
#   schema_version  string  always "v1"
#   ts              string  RFC 3339 UTC, second resolution
#   event           string  "state_transition" | "verdict"
#   state_from      string  idle | harvesting | dispatching | waiting | halted
#                           | unknown — "unknown" is emitted ONLY by the
#                           corrupt-state recovery step (event state_transition,
#                           reason "unknown-state") when the persisted fsm_state
#                           is not a known state; the raw value is in the
#                           preceding `unknown_state` diagnostic event
#   state_to        string  idle | harvesting | dispatching | waiting | halted
#                           (never "unknown")
#   task_id         string  "" = null (no task context)
#   verdict         string  "" = null | pass | fail | blocked | malformed | unknown
#   attempt         int     -1 = null; else dispatch attempts recorded for task_id
#   reason          string  non-empty, from TELEMETRY_TRANSITION_REASONS or
#                           TELEMETRY_VERDICT_REASONS
#   message_id      string  "" = null; Message-ID the event is about
#
# TOML has no null, so nullable fields use a fixed-type sentinel ("" / -1)
# instead of being omitted — omission would change the column set.
const TELEMETRY_SCHEMA_VERSION = "v1"
const TELEMETRY_VERDICTS = ["pass", "fail", "blocked", "malformed", "unknown"]
const TELEMETRY_TRANSITION_REASONS = [
    "spool-absent", "no-new-messages", "new-messages",
    "new-request", "retry", "task-halted", "harvest-complete",
    "reply-received", "no-reply", "reply-timeout",
    "dispatch-sent",
    "halt-marker-present", "awaiting-resume", "resume-action",
    "unknown-state",
]
const TELEMETRY_VERDICT_REASONS = [
    "accepted", "retry", "retry-exhausted", "no-unblocker",
    "parse-error", "unrecognized-verdict",
]

# The single constructor for telemetry records. Do not build these elsewhere.
def telemetry-record [
    event: string
    state_from: string
    state_to: string
    task_id: string
    verdict: string
    attempt: int
    reason: string
    message_id: string
] {
    {
        schema_version: $TELEMETRY_SCHEMA_VERSION
        ts:             (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        event:          $event
        state_from:     $state_from
        state_to:       $state_to
        task_id:        $task_id
        verdict:        $verdict
        attempt:        $attempt
        reason:         $reason
        message_id:     $message_id
    }
}

def emit-telemetry [row: record] {
    $row | to toml | print
    print "---"
}

# Emit one `state_transition` event. Call exactly once per FSM step.
def log-transition [
    state_from: string
    state_to: string
    reason: string
    --task-id: string = ""
    --verdict: string = ""
    --attempt: int = -1
    --message-id: string = ""
] {
    emit-telemetry (telemetry-record "state_transition" $state_from $state_to $task_id $verdict $attempt $reason $message_id)
}

# Emit one `verdict` event for a harvested reply. `verdict` is normalized to the
# closed TELEMETRY_VERDICTS enum (anything else becomes "unknown").
def log-verdict [
    verdict: string
    reason: string
    state_to: string          # FSM state this verdict routes the coordinator to
    --task-id: string = ""
    --attempt: int = -1
    --message-id: string = ""
] {
    let v = if $verdict in $TELEMETRY_VERDICTS { $verdict } else { "unknown" }
    emit-telemetry (telemetry-record "verdict" "harvesting" $state_to $task_id $v $attempt $reason $message_id)
}

# Check whether the HALT marker exists.
# Per spec §13: one stat per tick — do not call this in a loop.
def halt-present [root: string] {
    let halt_path = [$root, "var", "mail", "HALT"] | path join
    $halt_path | path exists
}

# Write a per-task HALT marker. Returns the path written.
def write-halt-marker [root: string, task_id: string, reason: string, verdict: string, message_id: string, attempts: int] {
    let halt_path = [$root, "var", "mail", $"HALT.($task_id)"] | path join
    let halt_dir  = $halt_path | path dirname
    if not ($halt_dir | path exists) { mkdir $halt_dir }
    {
        task_id:    $task_id
        verdict:    $verdict
        message_id: $message_id
        halted_at:  (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        reason:     $reason
        attempts:   $attempts
        halt_msgid: $"<halt-($task_id).coord@smolfire.local>"
        resume_tag: $"resume-($task_id)"
    } | to toml | save --force $halt_path
    $halt_path
}

# Append a spec-compliant HALT mbox message to the spool.
def append-halt-message [spool: string, task_id: string, reason: string, verdict: string, attempts: int, proposed_actions: list<string>] {
    let ts        = date now | format date "%Y%m%d%H%M%S"
    let halt_msgid = $"<halt-($task_id).coord@smolfire.local>"
    let resume_tag = $"resume-($task_id)"
    let x_halt_reason = match $reason {
        "retry-exhausted"  => "retry-exhausted"
        "no-unblocker"     => "claim-verification-failed"
        _                  => $reason
    }
    let mbox_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: user@smolfire.local
Subject: [HALT] ($task_id) — ($reason)
Message-ID: ($halt_msgid)
X-Halt-Reason: ($x_halt_reason)
X-Resume-Tag: ($resume_tag)
Content-Type: text/toml; charset=utf-8

task_id           = \"($task_id)\"
halt_msgid        = \"($halt_msgid)\"
resume_tag        = \"($resume_tag)\"
reason            = \"($reason)\"
last_verdict      = \"($verdict)\"
attempts          = ($attempts)
proposed_actions  = [($proposed_actions | each {|a| ('"' + $a + '"')} | str join ', ')]
"
    $mbox_msg | save --append $spool
}

# Best-effort IRC DM to operator per spec §13.
# Walk the In-Reply-To chain from in_reply_to_id upward (up to 8 hops) and
# return true if ANY message in the thread declared attestation_required = true.
# This handles chains where a coordinator dispatch wraps an original user request
# that carried the attestation requirement.
def request-thread-attestation-required [messages: list, in_reply_to_id: string] {
    mut current_id = $in_reply_to_id
    mut hops = 0
    loop {
        if $current_id == "" or $hops >= 8 { break }
        let found = $messages | where {|m| (msg-id $m) == $current_id} | first 1
        if ($found | length) == 0 { break }
        let msg = $found | first
        let payload = extract-toml $msg
        if ($payload | get "attestation_required"? | default false) { return true }
        # Follow the chain one more hop
        $current_id = $msg.headers | get "In-Reply-To"? | default ""
        $hops = $hops + 1
    }
    false
}

# One TLS attempt on 6697, one plain fallback on 6667, then give up.
# Result is logged but never fatal — HALT proceeds regardless.
def try-irc-dm [task_id: string, reason: string, root: string] {
    let msg = $"HALT ($task_id): ($reason)"
    # IRC host is internal infrastructure — never hardcoded in the repo.
    # Unset => fallback is inert ("no-route"), which the design tolerates.
    let irc_host = $env.SMOLFIRE_IRC_HOST? | default ""
    let halt_path = [$root, "var", "mail", $"HALT.($task_id)"] | path join

    let result = if $irc_host == "" {
        "no-route"
    } else { try {
        # TLS attempt on 6697 — pipe IRC NICK/USER/PRIVMSG/QUIT sequence
        let irc_cmds = $"NICK coord-bot\r\nUSER coord-bot 0 * :smolfire coord\r\nPRIVMSG ryan :($msg)\r\nQUIT\r\n"
        # out+err> /dev/null: suppress both stdout (s_client banner) and stderr (error msgs)
        let out = $irc_cmds | ^openssl s_client -connect $"($irc_host):6697" -quiet -timeout 10 out+err> /dev/null
        "tls-ok"
    } catch {
        # Plain fallback on 6667
        try {
            let irc_cmds = $"NICK coord-bot\r\nUSER coord-bot 0 * :smolfire coord\r\nPRIVMSG ryan :($msg)\r\nQUIT\r\n"
            let out = $irc_cmds | ^nc -w 5 $irc_host 6667 err> /dev/null
            "plain-ok"
        } catch {
            "no-route"
        }
    } }

    # Record outcome in the HALT marker file
    try {
        let existing = try { open --raw $halt_path | from toml } catch { {} }
        ($existing | insert fallback_fired true | insert fallback_status $result) | to toml | save --force $halt_path
    } catch {}

    log-event "irc_fallback" {task_id: $task_id, status: $result}
}

# Resolve the executor for a request. Precedence: request TOML `executor` field,
# then SMOLFIRE_EXECUTOR, then "vm". Returns {executor, source, error}; a
# non-empty error means refuse dispatch (never silently fall back — an explicit
# request for isolation must not be downgraded).
def resolve-executor [payload: record, host_os: string] {
    let from_payload = $payload | get -o executor | default ""
    let from_env     = $env.SMOLFIRE_EXECUTOR? | default ""
    let pick = if $from_payload != "" {
        {executor: $from_payload, source: "request"}
    } else if $from_env != "" {
        {executor: $from_env, source: "env"}
    } else {
        {executor: $DEFAULT_EXECUTOR, source: "default"}
    }
    if not ($pick.executor in $EXECUTORS) {
        return ($pick | insert error $"unknown executor '($pick.executor)' \(from ($pick.source)\); expected one of ($EXECUTORS | str join ', ')")
    }
    if $pick.executor == "jail" and $host_os != "freebsd" {
        return ($pick | insert error $"jail executor requires a FreeBSD host; this host is ($host_os)")
    }
    $pick | insert error ""
}

# Launch bin/jail-execute.nu detached for a dispatched task (executor = jail).
# Values reach the child as positional argv, never interpolated into the sh
# script, so task ids / Message-IDs cannot inject shell.
def spawn-jail-executor [task_id: string, dispatch_id: string, request_id: string, spool_path: string, root: string] {
    let spawn_dir = [$root, "var", "run", "spawned"] | path join
    if not ($spawn_dir | path exists) { mkdir $spawn_dir }
    let log_file = [$spawn_dir, $"($task_id).jail.log"] | path join
    with-env {SMOLFIRE_JAIL_LOG: $log_file} {
        ^sh -c '"$0" "$@" >"$SMOLFIRE_JAIL_LOG" 2>&1 &' $nu.current-exe $JAIL_EXECUTOR_SCRIPT dispatch --task-id $task_id --dispatch-id $dispatch_id --request-id $request_id --spool $spool_path
    }
    log-event "subagent_spawned" {
        task_id:    $task_id
        agent_type: "jail-agent"
        executor:   "jail"
        log_file:   $log_file
    }
}

# Check whether the originating request for a reply required attestation.
# Spawn a subagent (claude CLI) in the background to execute a dispatched task.
# Non-blocking: writes a prompt file and launches `claude -p` via `sh -c ... &`.
#
# Billed-subprocess guard (two independent layers — see docs/UR-BSD.md and
# tests/spawn-subagent-test.nu):
#   1. Opt-in kill switch: spawning a real subagent costs real money
#      (--max-budget-usd) and outlives this process (detached `&`), so it is
#      OFF by default. Every coord-tick.nu run — including every test and CI
#      invocation — must explicitly set SMOLFIRE_SPAWN_SUBAGENT=1 to allow it.
#      A test that merely forgets to sanitize PATH can no longer bill.
#   2. SMOLFIRE_SUBAGENT_CMD overrides which binary name is resolved and
#      launched (default "claude"), so tests can point this at a stub without
#      relying solely on PATH ordering/stripping.
# If the resolved CLI is not on PATH (or spawning is disabled), logs
# `subagent_spawn_skipped` and returns — the operator must launch manually.
def spawn-subagent [agent_type: string, task_id: string, spool_path: string, root: string] {
    let spawn_enabled = (($env | get SMOLFIRE_SPAWN_SUBAGENT? | default "") == "1")
    if not $spawn_enabled {
        log-event "subagent_spawn_skipped" {
            task_id:    $task_id
            agent_type: $agent_type
            reason:     "subagent spawning disabled by default (set SMOLFIRE_SPAWN_SUBAGENT=1 to enable)"
        }
        return
    }

    let claude_bin = $env | get SMOLFIRE_SUBAGENT_CMD? | default "claude"
    let claude_found = (which $claude_bin | length) > 0
    if not $claude_found {
        log-event "subagent_spawn_skipped" {
            task_id:    $task_id
            agent_type: $agent_type
            reason:     $"($claude_bin) CLI not installed"
        }
        return
    }

    let spawn_dir = [$root, "var", "run", "spawned"] | path join
    if not ($spawn_dir | path exists) { mkdir $spawn_dir }
    let prompt_file = [$spawn_dir, $"($task_id).prompt.txt"] | path join
    let log_file    = [$spawn_dir, $"($task_id).log"]        | path join

    let prompt = $"You are a smolfire subagent of type ($agent_type) handling task ($task_id).

1. Read the mbox spool at: ($spool_path)
2. Find the message whose Message-ID contains \"<($task_id).\" — that is your task envelope.
3. Parse its TOML body and execute the value of the `command` field as a shell command.
4. Append a reply to the spool (($spool_path)) with these headers:
   - From: ($agent_type)@smolfire.local
   - To: coordinator@smolfire.local
   - In-Reply-To: <the original Message-ID>
   - X-Verdict: pass | fail   \(pass iff exit_code == 0\)
   - Content-Type: text/toml; charset=utf-8
5. The TOML body MUST contain:
   - task_id      = \"($task_id)\"
   - verdict      = \"pass\" | \"fail\"
   - exit_code    = <int>
   - stdout       = <captured stdout, truncated to 4 KiB>
   - one [[claims]] block with at minimum: kind = \"command_executed\", task_id = \"($task_id)\", exit_code = <int>

Do not modify any other messages in the spool. Append only.
"
    $prompt | save --force $prompt_file

    # override with SMOLFIRE_CLAUDE_MODEL env var
    let model = $env | get SMOLFIRE_CLAUDE_MODEL? | default "claude-sonnet-5"
    # Launch claude as a truly-detached process (survives coord-tick.nu exit).
    # Prompt is passed via stdin redirect to avoid shell quoting fragility.
    let sh_cmd = $"($claude_bin) --print --bare --allowedTools 'Write,Bash,Read,Glob,Grep' --max-budget-usd 1.0 --model ($model) < '($prompt_file)' >'($log_file)' 2>&1 &"
    ^sh -c $sh_cmd

    log-event "subagent_spawned" {
        task_id:      $task_id
        agent_type:   $agent_type
        prompt_file:  $prompt_file
        log_file:     $log_file
    }
}

# Process X-Resume-* messages and clear matching per-task HALTs.
# Returns updated state; retry/edit resumes remove the task from halted_tasks.
def process-resume-actions [state: record, root: string, spool: string, event_prefix: string] {
    if (($state.halted_tasks | length) == 0) { return $state }
    if not ($spool | path exists) { return $state }

    let content  = open --raw $spool
    let messages = parse-mbox $content
    mut next_state = $state

    for msg in $messages {
        let id = msg-id $msg
        if $id != "" and ($id in $next_state.seen_ids) { continue }

        let resume_tag = $msg.headers | get "X-Resume-Tag"? | default ""
        if $resume_tag == "" { continue }

        let subject = $msg.headers | get "Subject"? | default ""
        if ($subject | str starts-with "[HALT]") {
            # Skip coordinator HALT messages as resume actions, but mark as seen
            if $id != "" {
                $next_state = ($next_state | update seen_ids ($next_state.seen_ids | append $id))
            }
            continue
        }

        let matched = $next_state.halted_tasks | where {|t| $"resume-($t)" == $resume_tag }
        if (($matched | length) == 0) { continue }

        let task = $matched | first
        let action_hdr = (($msg.headers | get "X-Resume-Action"? | default "retry") | str lowercase)
        let is_retry_as = ($action_hdr | str starts-with "retry-as-")
        log-event $"($event_prefix)_resume_action" {task_id: $task, resume_tag: $resume_tag, action: $action_hdr}

        if $action_hdr == "retry" or $action_hdr == "edit" or $is_retry_as {
            let per_halt = [$root, "var", "mail", $"HALT.($task)"] | path join
            if ($per_halt | path exists) { rm $per_halt }
            log-transition $next_state.fsm_state "idle" "resume-action" --task-id $task --message-id $id
            $next_state = ($next_state
                | update halted_tasks ($next_state.halted_tasks | where {|t| $t != $task})
                | update fsm_state "idle")
        } else {
            log-event $"($event_prefix)_abort" {task_id: $task}
        }

        if $id != "" {
            $next_state = ($next_state | update seen_ids ($next_state.seen_ids | append $id))
        }
    }

    $next_state
}

# ── FSM states ────────────────────────────────────────────────────────────────

# idle: scan spool for new messages not in seen_ids.
# If unseen replies are found, transition to harvesting.
# If no new messages, remain idle and finish this tick.
def state-idle [state: record, spool: string, root: string, remaining: int] {
    if not ($spool | path exists) {
        log-event "spool_absent" {spool: $spool}
        log-transition "idle" "idle" "spool-absent"
        return ($state | update fsm_state "idle")
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    let new_msgs = (
        $messages
        | where {|m|
            let id = msg-id $m
            $id != "" and not ($id in $state.seen_ids)
        }
    )

    if ($new_msgs | length) == 0 {
        log-event "idle_no_new_messages" {spool: $spool, total_msgs: ($messages | length)}
        log-transition "idle" "idle" "no-new-messages"
        return ($state | update fsm_state "idle")
    }

    log-event "idle_new_messages_found" {count: ($new_msgs | length)}
    log-transition "idle" "harvesting" "new-messages"
    # Transition to harvesting — process the unseen messages.
    tick ($state | update fsm_state "harvesting") $spool $root ($remaining - 1)
}

# harvesting: process each unseen message; update seen_ids.
# If an unmatched outbound request is found, set pending fields and transition to dispatching.
# Implements D2 retry table: fail/blocked retries up to 3 attempts, then HALT.
def state-harvesting [state: record, spool: string, root: string, remaining: int] {
    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut new_seen       = $state.seen_ids
    mut dispatch_state = $state   # overwritten when a dispatch target is found
    mut has_dispatch   = false
    mut current_state  = $state
    # Telemetry context for the harvesting→dispatching transition.
    mut dispatch_reason  = ""
    mut dispatch_verdict = ""
    mut dispatch_attempt = -1
    mut dispatch_task    = ""
    mut dispatch_msgid   = ""

    for msg in $messages {
        # Stop processing once we've identified a dispatch target.
        if $has_dispatch { break }

        let id = msg-id $msg
        if $id == "" or ($id in $new_seen) { continue }

        let payload = extract-toml $msg

        if "_parse_error" in $payload {
            log-event "harvest_malformed" {
                message_id:  $id
                from_line:   $msg.from_line
                parse_error: ($payload._parse_error)
            }
            log-verdict "malformed" "parse-error" "harvesting" --message-id $id
        } else {
            let to_addr   = $msg.headers | get "To"? | default "unknown"
            let from_addr = $msg.headers | get "From"? | default "unknown"
            let subject   = $msg.headers | get "Subject"? | default ""
            let verdict   = $payload | get "verdict"? | default "none"
            let task_id   = $payload | get "task_id"? | default "unknown"

            # Determine whether this is a coord→agent request or agent→coord reply.
            let direction = if $to_addr == "coordinator@smolfire.local" { "reply" } else { "request" }

            log-event "harvest_message" {
                message_id: $id
                direction:  $direction
                task_id:    $task_id
                from:       $from_addr
                to:         $to_addr
                subject:    $subject
                verdict:    $verdict
            }

            if $direction == "reply" {
                # Get current attempt count for this task
                let attempt_n = $current_state.attempt_counts | get -o $task_id | default 0

                # Classify the reply into one telemetry verdict category plus a
                # decision. retry → dispatching; halt → idle; accept/ignore → keep harvesting.
                let category = if $verdict == "pass" {
                    # Check attestation requirement from both reply and originating request.
                    # Agents may omit attestation_required in replies; coordinator must enforce
                    # the requirement declared in the request envelope.
                    let in_reply_to = $msg.headers | get "In-Reply-To"? | default ""
                    let request_attestation_required = if $in_reply_to != "" { request-thread-attestation-required $messages $in_reply_to } else { false }
                    let reply_attestation_required = $payload | get "attestation_required"? | default false
                    let attestation_required = $request_attestation_required or $reply_attestation_required
                    let claims = $payload | get "claims"? | default []
                    if $attestation_required and (($claims | length) == 0) { "malformed" } else { "pass" }
                } else if $verdict in ["fail", "blocked"] {
                    $verdict
                } else {
                    "unknown"
                }

                if $category == "malformed" {
                    log-event "harvest_malformed" {
                        message_id:  $id
                        task_id:     $task_id
                        reason:      "attestation_required=true but no [[claims]] block present"
                    }
                }

                # D2 retry table.
                #   pass (verified)            → accept
                #   malformed / fail           → retry while attempts < 3, else HALT retry-exhausted
                #   blocked + blocked_by       → retry while attempts < 3, else HALT retry-exhausted
                #   blocked, no blocked_by     → immediate HALT no-unblocker
                #   anything else              → ignored (unrecognized verdict)
                let blocked_by = $payload | get "blocked_by"? | default ""
                let decision = match $category {
                    "pass"    => "accepted"
                    "unknown" => "unrecognized-verdict"
                    "blocked" if ($blocked_by | str length) == 0 => "no-unblocker"
                    _ => (if $attempt_n < 3 { "retry" } else { "retry-exhausted" })
                }

                match $decision {
                    "accepted" => {
                        log-verdict $category $decision "harvesting" --task-id $task_id --attempt $attempt_n --message-id $id
                        let cleared_counts = if $task_id in $current_state.attempt_counts { $current_state.attempt_counts | reject $task_id } else { $current_state.attempt_counts }
                        let cleared_execs  = if $task_id in $current_state.task_executors { $current_state.task_executors | reject $task_id } else { $current_state.task_executors }
                        $new_seen = $new_seen | append $id
                        $current_state = ($current_state | update seen_ids $new_seen | update attempt_counts $cleared_counts | update task_executors $cleared_execs)
                        continue
                    }
                    "unrecognized-verdict" => {
                        log-verdict $category $decision "harvesting" --task-id $task_id --attempt $attempt_n --message-id $id
                    }
                    "retry" => {
                        log-verdict $category $decision "dispatching" --task-id $task_id --attempt $attempt_n --message-id $id
                        $new_seen = $new_seen | append $id
                        $dispatch_state = ($current_state
                            | update seen_ids           $new_seen
                            | update pending_request_id $id
                            | update pending_task_id    $task_id
                            | update pending_to_addr    $from_addr
                            | update fsm_state          "dispatching")
                        $has_dispatch     = true
                        $dispatch_reason  = "retry"
                        $dispatch_verdict = $category
                        $dispatch_attempt = $attempt_n
                        $dispatch_task    = $task_id
                        $dispatch_msgid   = $id
                    }
                    _ => {
                        # HALT: retry-exhausted | no-unblocker
                        let proposed = if $decision == "no-unblocker" { ["abort", "edit"] } else { ["retry", "abort"] }
                        let _ = write-halt-marker $root $task_id $decision $verdict $id $attempt_n
                        append-halt-message $spool $task_id $decision $verdict $attempt_n $proposed
                        try-irc-dm $task_id $decision $root
                        log-verdict $category $decision "idle" --task-id $task_id --attempt $attempt_n --message-id $id
                        log-transition "harvesting" "idle" "task-halted" --task-id $task_id --verdict $category --attempt $attempt_n --message-id $id
                        $current_state = ($current_state | update halted_tasks ($current_state.halted_tasks | append $task_id))
                        $new_seen = $new_seen | append $id
                        return ($current_state | update seen_ids $new_seen | update fsm_state "idle")
                    }
                }
            }

            # If this is an unmatched outbound request, dispatch it (first one wins).
            if $direction == "request" {
                # Skip tasks that are already halted.
                if $task_id in $current_state.halted_tasks {
                    log-event "dispatch_skipped_halted" {task_id: $task_id, message_id: $id}
                    $new_seen = $new_seen | append $id
                    continue
                }

                # §17: check tools_required against known agent capabilities
                let tools_required = $payload | get "tools_required"? | default []
                let agent_type     = $payload | get "agent_type"?     | default "general-purpose"
                let capabilities   = $AGENT_CAPABILITIES | get -o $agent_type | default ["Read", "Write", "Edit", "Bash", "Glob", "Grep"]
                let missing_tools  = $tools_required | where {|t| not ($t in $capabilities)}

                if ($missing_tools | length) > 0 {
                    log-event "dispatch_capability_mismatch" {
                        task_id:       $task_id
                        agent_type:    $agent_type
                        tools_required: ($tools_required | str join ", ")
                        missing_tools:  ($missing_tools | str join ", ")
                        message_id:    $id
                    }
                    $new_seen = $new_seen | append $id
                    # Skip dispatch — mark seen so we don't retry this message
                    continue
                }

                # Executor selection (docs/JAIL-EXECUTOR.md). Refusal is a
                # coordinator-level rejection like §17, not a retry.
                let exec_pick = resolve-executor $payload $nu.os-info.name
                if $exec_pick.error != "" {
                    log-event "dispatch_executor_refused" {
                        task_id:    $task_id
                        executor:   $exec_pick.executor
                        source:     $exec_pick.source
                        reason:     $exec_pick.error
                        message_id: $id
                    }
                    $new_seen = $new_seen | append $id
                    continue
                }
                let network = "Network" in $tools_required

                let in_reply_to = $msg.headers | get "In-Reply-To"? | default ""
                if $in_reply_to == "" {
                    log-event "would_dispatch" {
                        task_id:    $task_id
                        to_role:    $to_addr
                        message_id: $id
                    }
                    $new_seen = $new_seen | append $id
                    $dispatch_state = ($current_state
                        | update seen_ids           $new_seen
                        | update pending_request_id $id
                        | update pending_task_id    $task_id
                        | update pending_to_addr    $to_addr
                        | update task_executors     ($current_state.task_executors | upsert $task_id {executor: $exec_pick.executor, network: $network, request_id: $id})
                        | update fsm_state          "dispatching")
                    $has_dispatch     = true
                    $dispatch_reason  = "new-request"
                    $dispatch_verdict = ""
                    $dispatch_attempt = ($current_state.attempt_counts | get -o $task_id | default 0)
                    $dispatch_task    = $task_id
                    $dispatch_msgid   = $id
                    # break is implicit: has_dispatch will stop outer loop
                }
            }
        }

        if not $has_dispatch {
            $new_seen = $new_seen | append $id
        }
    }

    if $has_dispatch {
        log-transition "harvesting" "dispatching" $dispatch_reason --task-id $dispatch_task --verdict $dispatch_verdict --attempt $dispatch_attempt --message-id $dispatch_msgid
        tick $dispatch_state $spool $root ($remaining - 1)
    } else {
        log-transition "harvesting" "idle" "harvest-complete"
        $current_state
        | update seen_ids $new_seen
        | update fsm_state "idle"
    }
}

# waiting: a request has been dispatched; poll the spool for a matching reply.
# Transitions to harvesting if a reply is found; stays in waiting otherwise.
def state-waiting [state: record, spool: string, root: string, remaining: int] {
    if not ($spool | path exists) {
        log-event "waiting_no_reply" {pending_request_id: $state.pending_request_id, reason: "spool absent"}
        log-transition "waiting" "waiting" "spool-absent" --task-id $state.pending_task_id --message-id $state.pending_request_id
        return $state
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    let reply = (
        $messages
        | where {|m|
            let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
            $in_reply_to == $state.pending_request_id
        }
        | first 1
    )

    if ($reply | length) > 0 {
        log-event "waiting_reply_received" {
            pending_request_id: $state.pending_request_id
            pending_task_id:    $state.pending_task_id
        }
        log-transition "waiting" "harvesting" "reply-received" --task-id $state.pending_task_id --attempt ($state.attempt_counts | get -o $state.pending_task_id | default 0) --message-id (msg-id ($reply | first))
        let next_state = $state
            | update pending_request_id ""
            | update pending_task_id    ""
            | update pending_to_addr    ""
            | update dispatched_at      ""
            | update fsm_state          "harvesting"
        tick $next_state $spool $root ($remaining - 1)
    } else {
        log-event "waiting_no_reply" {pending_request_id: $state.pending_request_id}

        # Timeout: treat no-reply > 300s as a fail (triggers D2 retry table on next harvest)
        if $state.dispatched_at != "" {
            let elapsed = (date now) - ($state.dispatched_at | into datetime --timezone UTC)
            if ($elapsed | into int) > 300_000_000_000 {   # 300s in nanoseconds
                log-event "waiting_timeout" {
                    pending_request_id: $state.pending_request_id
                    pending_task_id:    $state.pending_task_id
                    dispatched_at:      $state.dispatched_at
                }
                # Inject a synthetic fail reply into the spool so the next harvest triggers retry
                let ts = date now | format date "%Y%m%d%H%M%S"
                let synth_id = $"<timeout.($state.pending_task_id).($ts)@smolfire.local>"
                let synth_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($synth_id)
In-Reply-To: ($state.pending_request_id)
Content-Type: text/toml; charset=utf-8

task_id = \"($state.pending_task_id)\"
verdict = \"fail\"
failure_reason = \"timeout: no reply within 300s\"
"
                $synth_msg | save --append $spool
                log-transition "waiting" "idle" "reply-timeout" --task-id $state.pending_task_id --attempt ($state.attempt_counts | get -o $state.pending_task_id | default 0) --message-id $state.pending_request_id
                return ($state | update fsm_state "idle" | update dispatched_at "")
            }
        }

        log-transition "waiting" "waiting" "no-reply" --task-id $state.pending_task_id --attempt ($state.attempt_counts | get -o $state.pending_task_id | default 0) --message-id $state.pending_request_id
        $state
    }
}

# §12 no-double-dispatch invariant: find a coordinator-authored dispatch
# already threaded to $pending_request_id that has not yet received an
# agent reply. Returns the dispatch message record, or null if none exists
# (the normal case: first dispatch attempt for this request).
#
# Why this is needed: `tick` recurses through several FSM transitions
# in-memory per invocation, but `save-state` runs exactly once, at the very
# end (see coord-tick.nu header + main). state-dispatching's spool append
# and subagent spawn are real, immediate side effects; if the process is
# killed anywhere between that append and the final save-state — a crash,
# OOM-kill, or host restart — the on-disk state file still reflects
# whatever it was BEFORE this dispatch. On the next invocation, seen_ids on
# disk does not include the triggering request/retry-reply message either
# (same reason), so state-harvesting rediscovers it and re-derives the
# IDENTICAL pending_request_id, and would otherwise send a second dispatch
# message and spawn a second real, billed subagent for work already in
# flight. This guard makes re-entering "dispatching" with an
# already-outstanding request idempotent: resume waiting on the existing
# dispatch instead of sending a new one.
def find-inflight-dispatch [spool: string, pending_request_id: string] {
    if $pending_request_id == "" or not ($spool | path exists) {
        return null
    }
    let content  = open --raw $spool
    let messages = parse-mbox $content

    let dispatches = $messages | where {|m|
        let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
        let from_addr   = $m.headers | get "From"? | default ""
        $in_reply_to == $pending_request_id and $from_addr == "coordinator@smolfire.local"
    }
    if ($dispatches | length) == 0 {
        return null
    }

    # Already answered? (a genuine agent reply, not the coordinator's own
    # dispatch, threaded to the same pending_request_id — matches the
    # predicate state-waiting itself uses to detect a reply, narrowed by
    # direction so the coordinator's own dispatch can never count as its
    # own answer.)
    let has_reply = ($messages | any {|m|
        let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
        let to_addr     = $m.headers | get "To"? | default ""
        $in_reply_to == $pending_request_id and $to_addr == "coordinator@smolfire.local"
    })

    if $has_reply {
        null
    } else {
        $dispatches | first
    }
}

# dispatching: compose and append an outbound mbox message to the spool,
# then transition to waiting. Tracks attempt counts with retry-aware headers.
def state-dispatching [state: record, spool: string, root: string, remaining: int] {
    let inflight = find-inflight-dispatch $spool $state.pending_request_id
    if $inflight != null {
        let inflight_id = msg-id $inflight
        log-event "dispatch_skipped_inflight" {
            task_id:             ($state | get pending_task_id? | default "unknown")
            pending_request_id:  $state.pending_request_id
            existing_message_id: $inflight_id
        }
        log-transition "dispatching" "waiting" "resume-inflight-dispatch" --task-id ($state | get pending_task_id? | default "unknown") --message-id $inflight_id
        return (tick ($state
            | update fsm_state          "waiting"
            | update pending_request_id $inflight_id
            | update dispatched_at      (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        ) $spool $root ($remaining - 1))
    }

    let task_id      = $state | get pending_task_id? | default "unknown"
    let attempt_n    = $state.attempt_counts | get -o $task_id | default 0
    let next_attempt = $attempt_n + 1
    let ts           = date now | format date "%Y%m%d%H%M%S"
    let msg_id       = $"<coord.($state.tick_count).r($next_attempt).($ts)@smolfire.local>"
    let to_addr      = if $state.pending_to_addr != "" { $state.pending_to_addr } else { $"($task_id)@smolfire.local" }
    let from_addr    = "coordinator@smolfire.local"
    let exec_info    = $state.task_executors | get -o $task_id | default {executor: $DEFAULT_EXECUTOR, network: false, request_id: $state.pending_request_id}

    let mbox_msg = $"From ($from_addr) ($ts)
From: ($from_addr)
To: ($to_addr)
Message-ID: ($msg_id)
X-Attempt: ($next_attempt)
Content-Type: text/toml; charset=utf-8
In-Reply-To: ($state.pending_request_id)

task_id = \"($task_id)\"
action = \"dispatch\"
executor = \"($exec_info.executor)\"
"

    # Append the message to the spool file.
    $mbox_msg | save --append $spool

    log-event "dispatch_sent" {
        message_id: $msg_id
        task_id:    $task_id
        to:         $to_addr
        attempt:    $next_attempt
        executor:   $exec_info.executor
    }

    if $exec_info.executor == "jail" {
        # Jail executor: run the ORIGINAL request's commands in an ephemeral
        # jail; the reply's In-Reply-To is this dispatch's Message-ID.
        spawn-jail-executor $task_id $msg_id $exec_info.request_id $spool $root
    } else {
        # vm (default): unchanged. Auto-spawn a subagent (Phase II); agent_type
        # is derived from the local-part of the recipient address.
        let agent_type = ($to_addr | split row "@" | first | default "general-purpose")
        spawn-subagent $agent_type $task_id $spool $root
    }

    log-transition "dispatching" "waiting" "dispatch-sent" --task-id $task_id --attempt $next_attempt --message-id $msg_id

    let updated_counts = $state.attempt_counts | upsert $task_id $next_attempt
    tick ($state
        | update fsm_state          "waiting"
        | update attempt_counts     $updated_counts
        | update pending_request_id $msg_id
        | update dispatched_at      (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
    ) $spool $root ($remaining - 1)
}

# halted: global HALT marker is present or all tasks failed.
# Per spec §13: wait for user to rm var/mail/HALT and post a resume message.
# We return here; the next cron/manual invocation will re-check.
# `reason` is the telemetry reason for staying/entering halted:
#   halt-marker-present — global var/mail/HALT exists
#   awaiting-resume     — fsm_state was persisted as halted, no global marker
def state-halted [state: record, root: string, spool: string, reason: string] {
    let halt_path = [$root, "var", "mail", "HALT"] | path join
    let halt_info = try { open --raw $halt_path | from toml } catch { {} }
    log-event "halted" {
        halt_file:    $halt_path
        info:         ($halt_info | to nuon)
        halted_tasks: ($state.halted_tasks | str join ", ")
        note:         "coordinator paused; rm var/mail/HALT + append resume message to unblock"
    }

    let resumed_state = process-resume-actions $state $root $spool "halted"
    if $resumed_state != $state {
        # process-resume-actions already emitted the resume-action transition.
        return $resumed_state
    }

    log-transition $state.fsm_state "halted" $reason
    $state | update fsm_state "halted"
}

# ── Tail-recursive dispatch core ──────────────────────────────────────────────

# The coordinator FSM.  Each call is one state transition.
# Recursion terminates when:
#   - remaining hits 0  (tick budget exhausted)
#   - the idle state finds no new work  (natural quiescence)
#   - halted state is entered  (HALT marker present)
def tick [state: record, spool: string, root: string, remaining: int] {
    if $remaining <= 0 {
        log-event "tick_budget_exhausted" {tick_count: $state.tick_count}
        return $state
    }

    # Process per-task resumes on every tick so HALT.<task_id> can be cleared
    # without requiring a global HALT marker.
    let resumed_state = process-resume-actions $state $root $spool "tick"

    # O(1) HALT check before every state dispatch — spec §13.
    if (halt-present $root) {
        return (state-halted $resumed_state $root $spool "halt-marker-present")
    }

    let next_count = $resumed_state.tick_count + 1
    let stamped = $resumed_state
        | update tick_count $next_count
        | update last_tick_at (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")

    log-event "tick_enter" {tick: $next_count, fsm_state: $stamped.fsm_state, remaining: $remaining}

    match $stamped.fsm_state {
        "idle"        => { state-idle        $stamped $spool $root $remaining }
        "dispatching" => { state-dispatching $stamped $spool $root $remaining }
        "waiting"     => { state-waiting     $stamped $spool $root $remaining }
        "harvesting"  => { state-harvesting  $stamped $spool $root $remaining }
        "halted"      => { state-halted      $stamped $root $spool "awaiting-resume" }
        _             => {
            log-event "unknown_state" {fsm_state: $stamped.fsm_state}
            log-transition "unknown" "idle" "unknown-state"
            $stamped | update fsm_state "idle"
        }
    }
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Run one coordinator tick.
#
# --state-file  path to the persistent TOML state file (created if absent)
# --spool       path to the mbox spool file
# --max-ticks   maximum FSM transitions in this invocation (budget guard)
# --root        project root directory (default: current working directory)
export def main [
    --state-file: string = "var/run/coord-state.toml"
    --spool:      string = "var/mail/spool"
    --max-ticks:  int    = 100
    --root:       string = "."
] {
    # Resolve all paths relative to --root so the binary works from any cwd.
    let abs_root       = $root | path expand
    let abs_state_file = [$abs_root, $state_file] | path join
    let abs_spool      = [$abs_root, $spool]      | path join

    log-event "coord_tick_start" {
        state_file: $abs_state_file
        spool:      $abs_spool
        max_ticks:  $max_ticks
        root:       $abs_root
    }

    let initial_state = load-state $abs_state_file
    let final_state   = tick $initial_state $abs_spool $abs_root $max_ticks

    save-state $final_state $abs_state_file

    log-event "coord_tick_done" {
        tick_count: $final_state.tick_count
        fsm_state:  $final_state.fsm_state
        seen_ids:   ($final_state.seen_ids | length)
    }
}
