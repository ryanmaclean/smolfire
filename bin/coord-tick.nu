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
# ephemeral jail via bin/jail-execute.nu. `fleet` (opt-in, only when
# SMOLFIRE_FLEET_ENABLE=1) runs them on a remote fleet worker via
# bin/coord-fleet-dispatch.nu. Selected per request by a TOML
# `executor = "vm"|"jail"|"fleet"` field, else SMOLFIRE_EXECUTOR, else the
# recipient role (`fleet-*` → fleet when enabled), else "vm".
const EXECUTORS = ["vm", "jail"]
const DEFAULT_EXECUTOR = "vm"
const JAIL_EXECUTOR_SCRIPT = path self jail-execute.nu
const FLEET_EXECUTOR_SCRIPT = path self coord-fleet-dispatch.nu

# Max-inflight caps (gastown parity; Jev 0.88 decision: in-flight work is
# counted in the crash-atomic state file — token-bucket rejected as a
# duplicate mechanism for the same invariant).
#
# Latency justification (worker latency drives the numbers — slow, billed,
# contention-prone executors get the smallest caps):
#   vm    = 4  local QEMU boot + SSH runs in seconds; host can overlap a few
#   jail  = 2  shares the host kernel; privileged + noisy, keep it narrow
#   fleet = 2  remote SSH workers, minutes of latency each; most contended
#   global = 8 bounds total concurrent billed work below the S-003 retry
#              blast radius (3 attempts x 8 tasks), not above it
#
# `fleet` is selected at tick level by resolve-executor below (explicit
# `executor = "fleet"` or a `fleet-*` recipient role, both gated on
# SMOLFIRE_FLEET_ENABLE=1) and travels the same detached-spawn path as jail.
# The entry reserves the accounting so role-routed fleet work is capped —
# counting is keyed by executor string, so no code change is needed here.
# Unknown executors fall back to the global cap only (see cap-for-executor).
const MAX_INFLIGHT_GLOBAL = 8
const MAX_INFLIGHT_PER_EXECUTOR = {vm: 4, jail: 2, fleet: 2}
# Crash-orphan horizon, in ticks: an inflight entry for a task the FSM is
# NOT waiting on that survives this many ticks without harvest or retry
# is reclaimed (see prune-inflight). Well above the S-003 budget (3
# attempts, one dispatch per tick) so healthy work never trips it.
const INFLIGHT_STALE_AFTER_TICKS = 50

# Slot constructors. Slot counts equal the per-executor inflight caps by
# construction (slots==caps invariant): fleet 2, jail 2, vm 4.
def empty-slot [] {
    {task_id: "", request_id: "", to_addr: "", dispatched_at: ""}
}

def slot-count [executor: string] {
    $MAX_INFLIGHT_PER_EXECUTOR | get -o $executor | default 1
}

def empty-slot-list [executor: string] {
    1..(slot-count $executor) | each {|_| empty-slot }
}

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
        pending_slots:      {
            fleet: (empty-slot-list "fleet")
            jail:  (empty-slot-list "jail")
            vm:    (empty-slot-list "vm")
        }
        attempt_counts:     {}   # record keyed by task_id → int attempt count
        halted_tasks:       []
        task_executors:     {}   # task_id → {executor, network, request_id}; reused on retry
        inflight:           {}   # task_id → {executor, since_tick}; one slot held
                                 # from dispatch until harvest (accept or S-003
                                 # escalation). Covered by atomic save/load.
        workers:            {}   # executor → {last_seen_tick, consecutive_failures,
                                 # dead}; piggyback heartbeat, see the Worker
                                 # heartbeat section. Covered by atomic save/load.
    }
}

# ── Per-executor pending slot lists (concurrent pendings) ─────────────────────
#
# N slots per known executor, N == that executor's inflight cap (slots==caps
# invariant: fleet 2, jail 2, vm 4; see docs/CONCURRENT-PENDINGS-DESIGN.md
# §6 follow-up). A slot is occupied when task_id != "". dispatched_at == ""
# means stamped-but-unsent (harvest stamped it, dispatching has not sent it
# yet). Slots live in the same crash-atomic state record as inflight, so the
# S-006 one-save-per-tick atomicity covers them with no new mechanism.
#
# The legacy scalar pending_* keys are kept as read-compat MIRRORS of the
# primary slot (lowest-executor-name occupied slot; blank when none). They
# are derived, never authoritative: every slot mutation ends with
# sync-legacy-mirror. (Deviation from the design doc's "save writes slots
# only": dropping the keys breaks every existing scalar reader and test, so
# the write-clean removal is deferred to a follow-up.)
const SLOT_ORDER = ["fleet", "jail", "vm"]

# Kill-switch: SMOLFIRE_CONCURRENT=0 restores single-pending (sequential
# drain: single target per tick, no refill while ANY slot is occupied).
# Default ON. Exists for one release, then is removed with the legacy keys.
def concurrent-enabled [] {
    ($env.SMOLFIRE_CONCURRENT? | default "1") != "0"
}

def now-str [] {
    date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
}

# Normalize one slot value to the full shape; non-records become empty.
def normalize-slot [s: any] {
    if ($s | describe | str starts-with "record") {
        {
            task_id: ($s | get -o task_id | default "")
            request_id: ($s | get -o request_id | default "")
            to_addr: ($s | get -o to_addr | default "")
            dispatched_at: ($s | get -o dispatched_at | default "")
        }
    } else {
        empty-slot
    }
}

# Read the slot table defensively (same posture as get-inflight): missing,
# partial, or legacy single-record tables normalize to per-executor slot
# LISTS rather than crashing the tick. Legacy single-record slots upgrade to
# 1-lists (record becomes element 0, padded with empties to the cap count);
# short lists pad with empties, over-long lists keep every occupied slot so
# no outstanding task is ever dropped by normalization.
def get-pending-slots [state: record] {
    let raw = $state | get -o pending_slots | default {}
    let base = if ($raw | describe | str starts-with "record") { $raw } else { {} }
    mut out = {}
    for ex in $SLOT_ORDER {
        let v = try { $base | get $ex } catch { null }
        let vd = $v | describe
        mut lst = if ($vd | str starts-with "record") {
            [(normalize-slot $v)]
        } else if ($vd | str starts-with "list") or ($vd | str starts-with "table") {
            ($v | each {|s| normalize-slot $s })
        } else {
            []
        }
        while ($lst | length) < (slot-count $ex) { $lst = $lst | append (empty-slot) }
        $out = $out | upsert $ex $lst
    }
    $out
}

def set-pending-slots [state: record, slots: record] {
    if "pending_slots" in ($state | columns) {
        $state | update pending_slots $slots
    } else {
        $state | insert pending_slots $slots
    }
}

# Every slot as {executor, index, slot} in canonical order
# (SLOT_ORDER, then index) — the single iteration order for waiting,
# dispatching recovery, and timeout scans.
def slot-entries [slots: record] {
    mut out = []
    for ex in $SLOT_ORDER {
        let lst = $slots | get $ex
        if ($lst | length) > 0 {
            for i in 0..((($lst | length)) - 1) {
                $out = $out | append {executor: $ex, index: $i, slot: ($lst | get $i)}
            }
        }
    }
    $out
}

# Task ids held by occupied slots (canonical order).
def pending-slot-tasks [slots: record] {
    slot-entries $slots | each {|e| $e.slot | get task_id } | where {|t| $t != "" }
}

def occupied-slot-count [slots: record] {
    (pending-slot-tasks $slots | length)
}

# Lowest-executor-name occupied slot first (fleet < jail < vm, then index);
# null when none.
def primary-slot [slots: record] {
    for e in (slot-entries $slots) {
        if ($e.slot | get task_id) != "" {
            return $e
        }
    }
    null
}

# First free index in the executor's list, or null when the list is full.
def free-slot-index [slots: record, executor: string] {
    mut i = 0
    for s in ($slots | get $executor) {
        if ($s | get task_id) == "" { return $i }
        $i = $i + 1
    }
    null
}

def set-slot [slots: record, executor: string, idx: int, slot: record] {
    $slots | upsert $executor (($slots | get $executor) | upsert $idx $slot)
}

def clear-slot [slots: record, executor: string, idx: int] {
    set-slot $slots $executor $idx (empty-slot)
}

# Clear every slot (any executor, any index) holding this task.
def clear-slots-by-task [slots: record, task_id: string] {
    mut out = $slots
    for e in (slot-entries $slots) {
        if ($e.slot.task_id == $task_id) {
            $out = clear-slot $out $e.executor $e.index
        }
    }
    $out
}

def update-slot-field [slots: record, executor: string, idx: int, field: string, value: string] {
    set-slot $slots $executor $idx ((($slots | get $executor) | get $idx) | upsert $field $value)
}

def sync-legacy-mirror [state: record] {
    let slots = get-pending-slots $state
    let prim = primary-slot $slots
    mut next = set-pending-slots $state $slots
    if $prim == null {
        $next = ($next
            | upsert pending_request_id ""
            | upsert pending_task_id ""
            | upsert pending_to_addr ""
            | upsert dispatched_at "")
    } else {
        $next = ($next
            | upsert pending_request_id $prim.slot.request_id
            | upsert pending_task_id $prim.slot.task_id
            | upsert pending_to_addr $prim.slot.to_addr
            | upsert dispatched_at $prim.slot.dispatched_at)
    }
    $next
}

# Load state from TOML file, or return the default if file absent.
# Missing keys are filled in from default-state so old state files remain compatible.
#
# Fail-CLOSED crash-safety invariant (§12 companion): a state file that is
# present but empty or unparseable is NEVER treated as "no history".
# Treating it as fresh default-state would be total amnesia — seen_ids,
# attempt_counts, and halted_tasks all forgotten — causing re-harvest of
# every message, reset D2 retry budgets (unbounded billed retries), and
# re-dispatch of operator-halted tasks. Instead the corrupt file is
# quarantined to <path>.corrupt-<ts> as forensic evidence and the process
# exits non-zero BEFORE any tick side effect (no dispatch, no spool
# append, no HALT write, no state overwrite).
def load-state [path: string] {
    if not ($path | path exists) {
        log-event "state_init" {path: $path, reason: "file absent"}
        return (default-state)
    }
    let raw = try {
        open --raw $path
    } catch {|err|
        log-event "state_load_error" {path: $path, error: ($err | get msg? | default "read error")}
        log-event "state_quarantined" {path: $path, reason: "unreadable"}
        exit 1
    }
    if ($raw | str trim | is-empty) {
        let ts = date now | format date "%Y%m%d%H%M%S"
        let quarantine = $"($path).corrupt-($ts)"
        try { mv $path $quarantine } catch {}
        log-event "state_load_error" {path: $path, error: "empty state file (possible torn write)"}
        log-event "state_quarantined" {path: $path, quarantine: $quarantine}
        exit 1
    }
    try {
        let loaded = $raw | from toml
        mut merged = (default-state) | merge $loaded
        # Normalize partial slot tables (hand-edited files), then backfill
        # legacy single-pending state: if the file predates pending_slots and
        # carries a live scalar triple, map it onto the slot of the task's
        # recorded executor (else vm). Old state files resume waiting on the
        # same dispatch — no re-dispatch, no S-012 violation. Idempotent:
        # re-running on slotted state is a no-op.
        $merged = set-pending-slots $merged (get-pending-slots $merged)
        if ("pending_slots" in ($loaded | columns)) {
            # Single-record slot tables (one slot per executor) upgrade to
            # 1-lists via get-pending-slots above; log the upgrade per slot.
            let raw_slots = try { $loaded | get pending_slots } catch { {} }
            if ($raw_slots | describe | str starts-with "record") {
                for ex in $SLOT_ORDER {
                    let v = try { $raw_slots | get $ex } catch { null }
                    if ($v | describe | str starts-with "record") {
                        log-event "state_migrated_slot_record" {executor: $ex, task_id: ($v | get -o task_id | default "")}
                    }
                }
            }
        }
        if not ("pending_slots" in ($loaded | columns)) {
            let legacy_task = $loaded | get -o pending_task_id | default ""
            if $legacy_task != "" {
                let exec_of = try { $merged.task_executors | get $legacy_task | get executor } catch { "" }
                let want_exec = if $exec_of != "" { $exec_of } else { $DEFAULT_EXECUTOR }
                let target_exec = if $want_exec in $SLOT_ORDER { $want_exec } else { $DEFAULT_EXECUTOR }
                mut slots = get-pending-slots $merged
                let free_idx = free-slot-index $slots $target_exec
                if $free_idx != null {
                    $slots = set-slot $slots $target_exec $free_idx {
                        task_id: $legacy_task
                        request_id: ($loaded | get -o pending_request_id | default "")
                        to_addr: ($loaded | get -o pending_to_addr | default "")
                        dispatched_at: ($loaded | get -o dispatched_at | default "")
                    }
                    $merged = set-pending-slots $merged $slots
                    log-event "state_migrated_legacy_pending" {task_id: $legacy_task, executor: $target_exec, index: $free_idx}
                } else {
                    log-event "state_migration_slot_full" {task_id: $legacy_task, executor: $target_exec}
                }
            }
        }
        sync-legacy-mirror $merged
    } catch {|err|
        let ts = date now | format date "%Y%m%d%H%M%S"
        let quarantine = $"($path).corrupt-($ts)"
        try { mv $path $quarantine } catch {}
        log-event "state_load_error" {path: $path, error: ($err | get msg? | default "parse error")}
        log-event "state_quarantined" {path: $path, quarantine: $quarantine}
        exit 1
    }
}

# Persist state back to disk as TOML, atomically.
#
# Crash-safe atomic persist (§12 companion invariant): the record is
# written to a temp file in the SAME directory and renamed over the
# target. Same-directory rename(2) is atomic — concurrent/crash readers
# see the old intact file or the new complete file, never a torn prefix.
# A crash between temp-write and rename leaves only an orphan
# <path>.tmp.* file (swept on the next save); the state file itself is
# never torn, so load-state's fail-closed path stays a backstop for
# operator/disk corruption rather than a routine crash outcome.
#
# The inflight slot table lives in this record, so atomicity is what makes
# the caps crash-safe: a torn state file would lose slot accounting and let
# the next tick over-dispatch past the caps (pattern from 8a95eb2 / S-006).
def save-state [state: record, path: string] {
    let dir = $path | path dirname
    if not ($dir | path exists) {
        mkdir $dir
    }
    # Sweep orphan tmp files from writers killed before rename.
    for stale in (try { glob $"($path).tmp.*" } catch { [] }) {
        try { rm $stale } catch {}
    }
    let ts = date now | format date "%Y%m%d%H%M%S"
    let tmp = $"($path).tmp.($nu.pid).($ts)"
    $state | to toml | save --force $tmp
    mv $tmp $path
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
    "backpressure-deferred",
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
# then SMOLFIRE_EXECUTOR, then the recipient role (`fleet-*` → fleet, but ONLY
# when SMOLFIRE_FLEET_ENABLE=1), then "vm". Returns {executor, source, error};
# a non-empty error means refuse dispatch (never silently fall back — an
# explicit request for isolation must not be downgraded).
#
# Fleet is default-off: when SMOLFIRE_FLEET_ENABLE != 1 this behaves exactly
# as the old vm|jail-only resolution — an explicit `fleet` is refused as
# unknown and `fleet-*` roles fall through to the default (vm) path.
def resolve-executor [payload: record, host_os: string, --role: string = ""] {
    let fleet_enabled = (($env | get SMOLFIRE_FLEET_ENABLE? | default "") == "1")
    let allowed = if $fleet_enabled { $EXECUTORS | append "fleet" } else { $EXECUTORS }
    let from_payload = $payload | get -o executor | default ""
    let from_env     = $env.SMOLFIRE_EXECUTOR? | default ""
    let role_local = ($role | split row "@" | first | default "")
    let pick = if $from_payload != "" {
        {executor: $from_payload, source: "request"}
    } else if $from_env != "" {
        {executor: $from_env, source: "env"}
    } else if $fleet_enabled and ($role_local | str starts-with "fleet-") {
        {executor: "fleet", source: "role"}
    } else {
        {executor: $DEFAULT_EXECUTOR, source: "default"}
    }
    if not ($pick.executor in $allowed) {
        return ($pick | insert error $"unknown executor '($pick.executor)' \(from ($pick.source)\); expected one of ($allowed | str join ', ')")
    }
    if $pick.executor == "jail" and $host_os != "freebsd" {
        return ($pick | insert error $"jail executor requires a FreeBSD host; this host is ($host_os)")
    }
    $pick | insert error ""
}

# ── Max-inflight backpressure (gastown parity) ───────────────────────────────
#
# Slots live in the state record (`inflight: {task_id: {executor,
# since_tick}}`), so they are covered by the atomic save/load above: a crash
# between dispatch and harvest loses no accounting, and a restarted
# coordinator sees exactly the slots outstanding before the crash.
#
# No config files: every knob has an env override (parsed defensively — a
# typo falls back to the const, never crashes the tick):
#   SMOLFIRE_MAX_INFLIGHT          global cap (default MAX_INFLIGHT_GLOBAL)
#   SMOLFIRE_MAX_INFLIGHT_<EXEC>   per-executor cap, e.g.
#                                  SMOLFIRE_MAX_INFLIGHT_FLEET (default from
#                                  MAX_INFLIGHT_PER_EXECUTOR, else global)
#   SMOLFIRE_MAX_INFLIGHT_STALE_TICKS  orphan horizon (default
#                                  INFLIGHT_STALE_AFTER_TICKS)
def env-int-or [key: string, fallback: int] {
    let raw = try { $env | get $key } catch { null }
    if $raw == null {
        return $fallback
    }
    try { $raw | into int } catch { $fallback }
}

def cap-global [] {
    env-int-or "SMOLFIRE_MAX_INFLIGHT" $MAX_INFLIGHT_GLOBAL
}

def cap-for-executor [executor: string] {
    let key = $"SMOLFIRE_MAX_INFLIGHT_($executor | str uppercase)"
    let fallback = $MAX_INFLIGHT_PER_EXECUTOR | get -o $executor | default $MAX_INFLIGHT_GLOBAL
    env-int-or $key $fallback
}

def stale-after-ticks [] {
    env-int-or "SMOLFIRE_MAX_INFLIGHT_STALE_TICKS" $INFLIGHT_STALE_AFTER_TICKS
}

# Read the slot table defensively: a hand-edited state file with a non-record
# inflight counts as empty rather than crashing the tick. Old state files
# without the key get {} from load-state's merge with default-state.
def get-inflight [state: record] {
    let raw = $state | get -o inflight | default {}
    if ($raw | describe | str starts-with "record") { $raw } else { {} }
}

def set-inflight [state: record, table: record] {
    if "inflight" in $state {
        $state | update inflight $table
    } else {
        $state | insert inflight $table
    }
}

# Count slots. Returns {global: int, per_executor: record}.
def inflight-counts [inflight: any] {
    if not ($inflight | describe | str starts-with "record") {
        return {global: 0, per_executor: {}}
    }
    let execs = $inflight | values | each {|e| $e | get -o executor | default $DEFAULT_EXECUTOR }
    mut per = {}
    for k in ($execs | uniq) {
        $per = $per | upsert $k ($execs | where {|x| $x == $k } | length)
    }
    {global: ($execs | length), per_executor: $per}
}

# Gate check for one executor. Returns {at_cap, global, global_cap,
# for_executor, exec_cap} — the counts travel with the verdict so the
# deferral event logs the exact reason (per-executor vs global).
def inflight-status [inflight: any, executor: string] {
    let counts = inflight-counts $inflight
    let gcap = cap-global
    let ecap = cap-for-executor $executor
    let ecount = $counts.per_executor | get -o $executor | default 0
    {
        at_cap: ($counts.global >= $gcap or $ecount >= $ecap)
        global: $counts.global
        global_cap: $gcap
        for_executor: $ecount
        exec_cap: $ecap
    }
}

# S-005-shaped backpressure signal: one diagnostic `dispatch_deferred_backpressure`
# event per refused candidate (telemetry conventions — fixed event name, the
# counts that explain the refusal), plus one fixed-schema harvesting→idle
# transition per tick (reason "backpressure-deferred").
def log-backpressure [task_id: string, executor: string, decision: string, message_id: string, gate: record] {
    log-event "dispatch_deferred_backpressure" {
        task_id:             $task_id
        executor:            $executor
        decision:            $decision
        inflight_global:     $gate.global
        global_cap:          $gate.global_cap
        inflight_executor:   $gate.for_executor
        executor_cap:        $gate.exec_cap
        message_id:          $message_id
    }
}

# Release slots that can never drain through harvest — the no-orphan-slot
# guarantee. A slot is reclaimed when its task:
#   - is in halted_tasks (S-002: operator-halted work is never re-dispatched
#     until resume, and resume re-dispatch re-registers the slot), or
#   - exhausted the S-003 budget (attempts >= 3: escalation owns the task;
#     harvest already released or will never re-dispatch), or
#   - is stale: (tick_count - since_tick) beyond the horizon — crash orphans
#     whose reply was lost age out instead of occupying a slot forever.
# Tasks held in ANY occupied pending slot are EXEMPT: their slots are owned
# by state-waiting/harvesting and released on harvest, so the sweep never
# prematurely reclaims genuinely outstanding work.
# Every release logs `inflight_slot_reclaimed`. Runs once per tick entry so
# the sweep fires in every FSM state.
def prune-inflight [state: record] {
    let table = get-inflight $state
    if ($table | columns | is-empty) {
        return (set-inflight $state $table)
    }
    let horizon = stale-after-ticks
    let pending_tasks = pending-slot-tasks (get-pending-slots $state)
    mut kept = {}
    for tid in ($table | columns) {
        if $tid in $pending_tasks {
            $kept = $kept | upsert $tid ($table | get $tid)
            continue
        }
        let entry = $table | get $tid
        let since = try { $entry | get since_tick | into int } catch { $state.tick_count }
        let age = $state.tick_count - $since
        let age = if $age < 0 { 0 } else { $age }
        let attempts = $state.attempt_counts | get -o $tid | default 0
        let reason = if $tid in $state.halted_tasks {
            "halted"
        } else if $attempts >= 3 {
            "budget-exhausted"
        } else if $age > $horizon {
            "stale"
        } else {
            ""
        }
        if $reason == "" {
            $kept = $kept | upsert $tid $entry
        } else {
            log-event "inflight_slot_reclaimed" {task_id: $tid, reason: $reason, age_ticks: $age, attempts: $attempts}
        }
    }
    set-inflight $state $kept
}

# ── Worker heartbeat + dead-worker detection (gastown parity) ─────────────────
#
# `workers: {<executor>: {last_seen_tick, consecutive_failures, dead}}` lives
# in the crash-atomic state record, so it gets the same torn-write protection
# as the inflight slot table: readers see the old or the new table, never a
# half-written one.
#
# Heartbeats are OBSERVATIONS of real spool traffic (piggyback — no pings, no
# extra SSH/process round trips):
#   - state-waiting reply-received: a dispatch round trip completed (a reply
#     arrived for the pending dispatch, any verdict — liveness, not quality);
#   - state-harvesting accept: a pass verdict was classified.
# Harvested fail/blocked/malformed verdicts bump consecutive_failures WITHOUT
# touching last_seen_tick (failure is not liveness); successes reset it to 0.
#
# Deliberately NOT a heartbeat site: state-dispatching send. A coordinator
# spool append proves nothing about the worker, and heartbeating on send
# would resurrect a dead worker in the same tick its reaped tasks redispatch
# — dead-marking could never stick. Dispatch alone leaves workers untouched.
#
# Dead detection: a worker that still owns inflight work but saw no
# successful round trip for SMOLFIRE_WORKER_DEAD_TICKS (default
# WORKER_DEAD_AFTER_TICKS, garbage falls back via env-int-or) is marked dead
# with one edge-triggered `worker_marked_dead` diagnostic (S-005 shape:
# fixed event name via log-event, like dispatch_deferred_backpressure — NOT
# a state_transition/verdict, whose schema and value enums are closed).
# Its eligible inflight tasks are reaped to the REAL retry path: the slot is
# released and a synthetic fail reply is appended in the same tick (single
# save-state — atomic release+requeue, no double-dispatch, no leak), so the
# next harvest routes them through the D2 table: attempts increment, the
# budget still applies, nothing is dropped, and reap itself never HALTs.
# Eligible = owned by the worker, not halted (S-002 owns those), and not
# held in any occupied pending slot (state-waiting and the per-slot 300 s
# timeout path own those instead — including slots of dead workers, whose
# tasks drain through the timeout → retry path rather than being reaped
# twice in the same invocation).
# A live worker with no inflight is idle, never dead.
#
# Resurrection: any later successful round trip clears dead with one
# edge-triggered `worker_resurrected` event. Already-dead workers with fresh
# inflight are silently re-reaped every tick (`worker_tasks_reaped`, no
# repeat dead event) so retried tasks keep moving instead of hanging.
#
# Rate-limit interplay: dead-worker tasks occupy slots until the reap tick —
# release and requeue happen atomically together, so counting is never
# momentarily wrong in either direction.
const WORKER_DEAD_AFTER_TICKS = 20

def dead-after-ticks [] {
    env-int-or "SMOLFIRE_WORKER_DEAD_TICKS" $WORKER_DEAD_AFTER_TICKS
}

# Read the worker table defensively (same posture as get-inflight).
def get-workers [state: record] {
    let raw = $state | get -o workers | default {}
    if ($raw | describe | str starts-with "record") { $raw } else { {} }
}

def set-workers [state: record, table: record] {
    if "workers" in $state {
        $state | update workers $table
    } else {
        $state | insert workers $table
    }
}

# Attribute traffic to a worker: recorded executor for the task, else its
# inflight slot, else the default executor (same fallback chain the harvest
# retry path uses).
def resolve-task-executor [state: record, task_id: string] {
    let via_map = try { $state.task_executors | get $task_id | get executor } catch { "" }
    if $via_map != "" { return $via_map }
    let via_slot = try { get-inflight $state | get $task_id | get executor } catch { "" }
    if $via_slot != "" { return $via_slot }
    $DEFAULT_EXECUTOR
}

# Record a successful round trip: stamp liveness, clear failures and dead.
# Edge-triggered resurrection event — only on true → false.
def record-heartbeat [state: record, executor: string, tick: int] {
    let table = get-workers $state
    let raw = $table | get -o $executor | default {}
    let prev = if ($raw | describe | str starts-with "record") { $raw } else { {} }
    if (($prev | get -o dead | default false) == true) {
        log-event "worker_resurrected" {worker: $executor, last_seen_tick: $tick}
    }
    set-workers $state ($table | upsert $executor {last_seen_tick: $tick, consecutive_failures: 0, dead: false})
}

# Record an observed failure: bump the counter, preserve liveness and dead.
# A never-before-seen worker starts at last_seen_tick 0 (never observed
# alive); the dead-mark gate additionally requires owned inflight work, so a
# stray failure alone can never mark anything dead.
def record-worker-failure [state: record, executor: string] {
    let table = get-workers $state
    let raw = $table | get -o $executor | default {}
    let prev = if ($raw | describe | str starts-with "record") { $raw } else { {} }
    let fails = (try { $prev | get consecutive_failures | into int } catch { 0 }) + 1
    let next = {
        last_seen_tick: ($prev | get -o last_seen_tick | default 0)
        consecutive_failures: $fails
        dead: ($prev | get -o dead | default false)
    }
    set-workers $state ($table | upsert $executor $next)
}

# Queue one reaped task back into the retry path as a synthetic fail reply.
# Same shape as state-waiting's timeout injection: harvest classifies it via
# the D2 table (retry while attempts < 3, else the standard escalation —
# the budget owns the outcome, never the reap). X-Dead-Worker-Reap marks the
# provenance for operators grepping the spool.
def append-dead-reap-fail [spool: string, task_id: string, worker: string, age: int, threshold: int, tick: int] {
    let dir = $spool | path dirname
    if not ($dir | path exists) { mkdir $dir }
    let ts = date now | format date "%Y%m%d%H%M%S"
    let synth_id = $"<deadreap.($task_id).t($tick).($ts)@smolfire.local>"
    let synth_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($synth_id)
X-Dead-Worker-Reap: ($worker)
Content-Type: text/toml; charset=utf-8

task_id = \"($task_id)\"
verdict = \"fail\"
failure_reason = \"dead worker ($worker): no successful round trip for ($age) ticks; threshold ($threshold) ticks\"
"
    $synth_msg | save --append $spool
}

# Mark silent workers dead and reap their tasks. Runs at tick entry (every
# FSM state, before the HALT check — same placement as prune-inflight, which
# runs first so halted / budget-exhausted / stale slots are already owned
# elsewhere and never reach the reap).
def sweep-dead-workers [state: record, spool: string] {
    let table = get-workers $state
    if ($table | columns | is-empty) {
        return $state
    }
    let threshold = dead-after-ticks
    let slots_now = get-pending-slots $state
    # Any task held in an occupied pending slot is exempt: the slot drains
    # through state-waiting/harvesting (or the per-slot timeout), never the
    # sweep — this also gives a just-redispatched task its grace, because
    # the sweep re-runs on every recursive tick transition within the same
    # invocation, after dispatching has re-occupied the slot.
    let exempt_slot_tasks = pending-slot-tasks $slots_now
    mut next_table = $table
    mut next_slots = get-inflight $state
    mut next_pend = $slots_now
    mut next_state = $state
    for worker in ($table | columns) {
        let raw_entry = try { $table | get $worker } catch { {} }
        let entry = if ($raw_entry | describe | str starts-with "record") { $raw_entry } else { {} }
        let last = try { $entry | get last_seen_tick | into int } catch { 0 }
        let is_dead = ($entry | get -o dead | default false) == true
        let age = $state.tick_count - $last
        let age = if $age < 0 { 0 } else { $age }
        let owned = $next_slots | columns | where {|t|
            (try { $next_slots | get $t | get executor } catch { "" }) == $worker
        }
        let eligible = $owned | where {|t| not ($t in $exempt_slot_tasks) and not ($t in $next_state.halted_tasks) }
        if $is_dead {
            # Already dead: no repeat event, but still reap promptly.
            if ($eligible | is-empty) { continue }
            for t in $eligible {
                $next_slots = if $t in ($next_slots | columns) { $next_slots | reject $t } else { $next_slots }
                $next_pend = clear-slots-by-task $next_pend $t
                append-dead-reap-fail $spool $t $worker $age $threshold $state.tick_count
            }
            log-event "worker_tasks_reaped" {worker: $worker, tasks: $eligible}
            continue
        }
        # Idle workers (no owned inflight) are never dead.
        if ($owned | is-empty) { continue }
        if $age < $threshold { continue }
        $next_table = $next_table | upsert $worker ($entry
            | upsert last_seen_tick $last
            | upsert consecutive_failures (try { $entry | get consecutive_failures | into int } catch { 0 })
            | upsert dead true)
        for t in $eligible {
            $next_slots = if $t in ($next_slots | columns) { $next_slots | reject $t } else { $next_slots }
            $next_pend = clear-slots-by-task $next_pend $t
            append-dead-reap-fail $spool $t $worker $age $threshold $state.tick_count
        }
        log-event "worker_marked_dead" {
            worker: $worker
            last_seen_tick: $last
            age_ticks: $age
            threshold_ticks: $threshold
            reaped_tasks: $eligible
        }
    }
    $next_state = set-inflight $next_state $next_slots
    $next_state = sync-legacy-mirror (set-pending-slots $next_state $next_pend)
    set-workers $next_state $next_table
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

# Launch bin/coord-fleet-dispatch.nu detached for a dispatched task
# (executor = fleet). Same shape as spawn-jail-executor: values reach the
# child as positional argv, never interpolated into the sh script, so task
# ids / Message-IDs cannot inject shell. The child's reply threads to
# dispatch_id (the coordinator dispatch Message-ID state-waiting matches on)
# and carries the executor-agnostic result shape, so harvest, the D2 retry
# table, and telemetry stay identical to the vm/jail paths.
def spawn-fleet-executor [task_id: string, dispatch_id: string, request_id: string, spool_path: string, root: string] {
    let spawn_dir = [$root, "var", "run", "spawned"] | path join
    if not ($spawn_dir | path exists) { mkdir $spawn_dir }
    let log_file = [$spawn_dir, $"($task_id).fleet.log"] | path join
    with-env {SMOLFIRE_FLEET_LOG: $log_file} {
        ^sh -c '"$0" "$@" >"$SMOLFIRE_FLEET_LOG" 2>&1 &' $nu.current-exe $FLEET_EXECUTOR_SCRIPT dispatch --task-id $task_id --dispatch-id $dispatch_id --request-id $request_id --spool $spool_path
    }
    log-event "subagent_spawned" {
        task_id:    $task_id
        agent_type: "fleet-agent"
        executor:   "fleet"
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
# Dispatch targets are stamped into per-executor pending slots (one per free
# slot per tick while SMOLFIRE_CONCURRENT != 0; exactly one total per tick
# with the kill-switch off) and sent by state-dispatching later this tick.
# Implements D2 retry table: fail/blocked retries up to 3 attempts, then HALT.
def state-harvesting [state: record, spool: string, root: string, remaining: int] {
    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut new_seen       = $state.seen_ids
    mut current_state  = sync-legacy-mirror $state
    mut targets        = []   # dispatch targets stamped this scan, spool order
    # Backpressure context: candidates refused by max-inflight caps stay
    # UNSEEN (no seen_ids append) so the next tick rediscovers them — deferral
    # is level-triggered, never a drop. Only the last refused candidate feeds
    # the harvesting→idle transition below. Non-cap deferrals (occupied slot,
    # duplicate task, sequential kill-switch drain) share the same unseen
    # mechanics and the same closed-enum transition reason; the diagnostic
    # log-events carry the specific cause.
    mut deferred_count = 0
    mut deferred_task  = ""
    mut deferred_msgid = ""
    mut halted_any     = false
    let concurrent = concurrent-enabled

    for msg in $messages {
        # Single-pending kill-switch: first stamped target wins (the old
        # `if $has_dispatch { break }` gate, `:1004`). Concurrent mode scans
        # the whole spool every tick.
        if (not $concurrent) and ($targets | length) > 0 { break }

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

                # Worker heartbeat attribution (best effort): recorded
                # executor, else inflight slot, else default. Fail-family
                # verdicts are quality failures, not liveness — bump the
                # counter, leave last_seen_tick alone.
                let reply_exec = resolve-task-executor $current_state $task_id
                if $category in ["fail", "blocked", "malformed"] {
                    $current_state = record-worker-failure $current_state $reply_exec
                }

                match $decision {
                    "accepted" => {
                        log-verdict $category $decision "harvesting" --task-id $task_id --attempt $attempt_n --message-id $id
                        let cleared_counts = if $task_id in $current_state.attempt_counts { $current_state.attempt_counts | reject $task_id } else { $current_state.attempt_counts }
                        let cleared_execs  = if $task_id in $current_state.task_executors { $current_state.task_executors | reject $task_id } else { $current_state.task_executors }
                        # Harvest releases the inflight slot — completion path
                        # of the no-leak guarantee (dispatch→harvest→0) — and
                        # the pending slot that carried the dispatch (slot
                        # lookup by task, never the legacy scalars).
                        let table = get-inflight $current_state
                        let cleared_slots = if $task_id in $table { $table | reject $task_id } else { $table }
                        let pend = clear-slots-by-task (get-pending-slots $current_state) $task_id
                        $new_seen = $new_seen | append $id
                        $current_state = record-heartbeat (sync-legacy-mirror (set-pending-slots (set-inflight $current_state $cleared_slots) $pend | update seen_ids $new_seen | update attempt_counts $cleared_counts | update task_executors $cleared_execs)) $reply_exec ($current_state.tick_count)
                        continue
                    }
                    "unrecognized-verdict" => {
                        log-verdict $category $decision "harvesting" --task-id $task_id --attempt $attempt_n --message-id $id
                    }
                    "retry" => {
                        # Retries re-enter the dispatch path, so they take a
                        # slot like new requests. At cap the retry is DEFERRED:
                        # no verdict (the decision is postponed, not made), no
                        # seen_ids append — the reply is re-harvested next tick.
                        let retry_exec = $current_state.task_executors | get -o $task_id | get -o executor | default $DEFAULT_EXECUTOR
                        let retry_exec = if $retry_exec in $SLOT_ORDER { $retry_exec } else { $DEFAULT_EXECUTOR }
                        let gate = inflight-status (get-inflight $current_state) $retry_exec
                        if $gate.at_cap {
                            log-backpressure $task_id $retry_exec "retry" $id $gate
                            $deferred_count = $deferred_count + 1
                            $deferred_task  = $task_id
                            $deferred_msgid = $id
                            continue
                        }
                        # Same-task-never-twice: refuse to hold one task in
                        # two slots. The trigger stays unseen (deferred like
                        # backpressure), never dropped.
                        if $task_id in (pending-slot-tasks (get-pending-slots $current_state)) {
                            log-event "dispatch_skipped_duplicate_task" {task_id: $task_id, message_id: $id}
                            $deferred_count = $deferred_count + 1
                            $deferred_task  = $task_id
                            $deferred_msgid = $id
                            continue
                        }
                        # Sequential kill-switch: extra slots drain without
                        # refill — stamp only when no slot is occupied and no
                        # target was stamped yet this scan.
                        if (not $concurrent) and ((occupied-slot-count (get-pending-slots $current_state)) > 0 or ($targets | length) > 0) {
                            log-event "dispatch_deferred_sequential" {task_id: $task_id, executor: $retry_exec, decision: "retry", message_id: $id}
                            $deferred_count = $deferred_count + 1
                            $deferred_task  = $task_id
                            $deferred_msgid = $id
                            continue
                        }
                        # Retry dispatch takes a FREE slot of the reply's
                        # recorded executor; a full list defers.
                        let free_idx = free-slot-index (get-pending-slots $current_state) $retry_exec
                        if $free_idx == null {
                            log-event "dispatch_deferred_slot_occupied" {task_id: $task_id, executor: $retry_exec, decision: "retry", message_id: $id}
                            $deferred_count = $deferred_count + 1
                            $deferred_task  = $task_id
                            $deferred_msgid = $id
                            continue
                        }
                        log-verdict $category $decision "dispatching" --task-id $task_id --attempt $attempt_n --message-id $id
                        $new_seen = $new_seen | append $id
                        $current_state = sync-legacy-mirror (set-pending-slots $current_state (set-slot (get-pending-slots $current_state) $retry_exec $free_idx {task_id: $task_id, request_id: $id, to_addr: $from_addr, dispatched_at: ""})
                            | update seen_ids $new_seen)
                        $targets = $targets | append {task_id: $task_id, trigger_id: $id, to_addr: $from_addr, executor: $retry_exec, reason: "retry", verdict: $category, attempt: $attempt_n}
                        continue
                    }
                    _ => {
                        # HALT: retry-exhausted | no-unblocker. Halt is
                        # per-task: it clears only this task's pending slot
                        # and the scan CONTINUES so other slots keep draining
                        # in the same run.
                        let proposed = if $decision == "no-unblocker" { ["abort", "edit"] } else { ["retry", "abort"] }
                        let _ = write-halt-marker $root $task_id $decision $verdict $id $attempt_n
                        append-halt-message $spool $task_id $decision $verdict $attempt_n $proposed
                        try-irc-dm $task_id $decision $root
                        log-verdict $category $decision "idle" --task-id $task_id --attempt $attempt_n --message-id $id
                        log-transition "harvesting" "idle" "task-halted" --task-id $task_id --verdict $category --attempt $attempt_n --message-id $id
                        # S-003 escalation releases the inflight slot: an
                        # exhausted task never re-dispatches, so holding its
                        # slot would leak it permanently.
                        let table = get-inflight $current_state
                        let cleared_slots = if $task_id in $table { $table | reject $task_id } else { $table }
                        let pend = clear-slots-by-task (get-pending-slots $current_state) $task_id
                        $current_state = sync-legacy-mirror (set-pending-slots (set-inflight $current_state $cleared_slots
                            | update halted_tasks ($current_state.halted_tasks | append $task_id)) $pend)
                        $new_seen = $new_seen | append $id
                        $current_state = $current_state | update seen_ids $new_seen
                        $halted_any = true
                        continue
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

                # Executor selection (docs/JAIL-EXECUTOR.md, docs/FLEET-DISPATCH.md).
                # Refusal is a coordinator-level rejection like §17, not a retry.
                # The recipient role travels along so `fleet-*` roles resolve
                # to the fleet executor when SMOLFIRE_FLEET_ENABLE=1.
                let exec_pick = resolve-executor $payload $nu.os-info.name --role $to_addr
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
                    # Max-inflight gate: refuse with a logged backpressure
                    # event before any dispatch side effect. Halt-skipped,
                    # capability-mismatched, and executor-refused messages
                    # never reach here, so they never occupy slots.
                    let gate = inflight-status (get-inflight $current_state) $exec_pick.executor
                    if $gate.at_cap {
                        log-backpressure $task_id $exec_pick.executor "new-request" $id $gate
                        $deferred_count = $deferred_count + 1
                        $deferred_task  = $task_id
                        $deferred_msgid = $id
                        # No seen_ids append: the request is rediscovered next
                        # tick (level-triggered backpressure, not a drop).
                        continue
                    }
                    # Same-task-never-twice: no OTHER occupied slot may hold
                    # this task_id. Refused like backpressure deferral: the
                    # trigger stays unseen.
                    if $task_id in (pending-slot-tasks (get-pending-slots $current_state)) {
                        log-event "dispatch_skipped_duplicate_task" {task_id: $task_id, message_id: $id}
                        $deferred_count = $deferred_count + 1
                        $deferred_task  = $task_id
                        $deferred_msgid = $id
                        continue
                    }
                    # Sequential kill-switch: extra slots drain without
                    # refill — stamp only when no slot is occupied and no
                    # target was stamped yet this scan.
                    if (not $concurrent) and ((occupied-slot-count (get-pending-slots $current_state)) > 0 or ($targets | length) > 0) {
                        log-event "dispatch_deferred_sequential" {task_id: $task_id, executor: $exec_pick.executor, decision: "new-request", message_id: $id}
                        $deferred_count = $deferred_count + 1
                        $deferred_task  = $task_id
                        $deferred_msgid = $id
                        continue
                    }
                    # New-request dispatch fills a FREE slot of the
                    # resolved executor; a full list defers.
                    let free_idx = free-slot-index (get-pending-slots $current_state) $exec_pick.executor
                    if $free_idx == null {
                        log-event "dispatch_deferred_slot_occupied" {task_id: $task_id, executor: $exec_pick.executor, decision: "new-request", message_id: $id}
                        $deferred_count = $deferred_count + 1
                        $deferred_task  = $task_id
                        $deferred_msgid = $id
                        continue
                    }
                    log-event "would_dispatch" {
                        task_id:    $task_id
                        to_role:    $to_addr
                        message_id: $id
                    }
                    $new_seen = $new_seen | append $id
                    $current_state = sync-legacy-mirror (set-pending-slots $current_state (set-slot (get-pending-slots $current_state) $exec_pick.executor $free_idx {task_id: $task_id, request_id: $id, to_addr: $to_addr, dispatched_at: ""})
                        | update seen_ids           $new_seen
                        | update task_executors     ($current_state.task_executors | upsert $task_id {executor: $exec_pick.executor, network: $network, request_id: $id}))
                    $targets = $targets | append {task_id: $task_id, trigger_id: $id, to_addr: $to_addr, executor: $exec_pick.executor, reason: "new-request", verdict: "", attempt: ($current_state.attempt_counts | get -o $task_id | default 0)}
                    continue
                }
            }
        }

        if $id != "" and not ($id in $new_seen) {
            $new_seen = $new_seen | append $id
        }
    }

    if ($targets | length) > 0 {
        for t in $targets {
            log-transition "harvesting" "dispatching" $t.reason --task-id $t.task_id --verdict $t.verdict --attempt $t.attempt --message-id $t.trigger_id
        }
        tick ($current_state | update seen_ids $new_seen | update fsm_state "dispatching") $spool $root ($remaining - 1)
    } else if $deferred_count > 0 {
        log-transition "harvesting" "idle" "backpressure-deferred" --task-id $deferred_task --message-id $deferred_msgid
        $current_state
        | update seen_ids $new_seen
        | update fsm_state "idle"
    } else if $halted_any {
        # Single-HALT shape preserved: the per-HALT task-halted transition
        # above is the only transition (no trailing harvest-complete), so
        # the escalate sequences are unchanged.
        $current_state
        | update seen_ids $new_seen
        | update fsm_state "idle"
    } else {
        log-transition "harvesting" "idle" "harvest-complete"
        $current_state
        | update seen_ids $new_seen
        | update fsm_state "idle"
    }
}

# waiting: pending slot lists have been dispatched; poll the spool for
# matching replies. Iterates occupied slots in canonical order (fleet, jail,
# vm, then index): the first slot with a matching reply
# (In-Reply-To == slot.request_id) clears THAT slot and routes to harvesting
# with the slot's task context. Timeout injection is per-slot (each slot
# carries its own dispatched_at). With the SMOLFIRE_CONCURRENT=0 kill-switch
# the same order means the lowest-executor-name occupied slot is always
# matched first.
def state-waiting [state: record, spool: string, root: string, remaining: int] {
    mut cur = sync-legacy-mirror $state
    let slots = get-pending-slots $cur
    let occupied = (slot-entries $slots) | where {|e| ($e.slot | get task_id) != "" }

    if ($occupied | is-empty) {
        # Defensive: waiting with nothing outstanding (unreachable through
        # dispatching — it routes idle when no slot was sent). Park in idle.
        log-event "waiting_no_reply" {pending_request_id: "", reason: "no occupied slots"}
        log-transition "waiting" "idle" "no-reply"
        return ($cur | update fsm_state "idle")
    }

    if not ($spool | path exists) {
        log-event "waiting_no_reply" {pending_request_id: $cur.pending_request_id, reason: "spool absent"}
        log-transition "waiting" "waiting" "spool-absent" --task-id $cur.pending_task_id --message-id $cur.pending_request_id
        return $cur
    }

    let content  = open --raw $spool
    let messages = parse-mbox $content

    mut matched_executor = ""
    mut matched_index = -1
    mut matched_slot = empty-slot
    mut matched_reply_id = ""
    for entry in $occupied {
        let hits = $messages | where {|m|
            let in_reply_to = $m.headers | get "In-Reply-To"? | default ""
            $in_reply_to == ($entry.slot | get request_id)
        } | first 1
        if ($hits | length) > 0 {
            $matched_executor = $entry.executor
            $matched_index = $entry.index
            $matched_slot = $entry.slot
            $matched_reply_id = msg-id ($hits | first)
            break
        }
    }

    if $matched_executor != "" {
        log-event "waiting_reply_received" {
            pending_request_id: ($matched_slot | get request_id)
            pending_task_id:    ($matched_slot | get task_id)
        }
        log-transition "waiting" "harvesting" "reply-received" --task-id ($matched_slot | get task_id) --attempt ($cur.attempt_counts | get -o ($matched_slot | get task_id) | default 0) --message-id $matched_reply_id
        # The dispatch round trip completed: the worker answered. That is
        # liveness regardless of verdict (harvest still classifies quality) —
        # piggyback heartbeat on the matched slot's task, no new traffic.
        $cur = record-heartbeat $cur (resolve-task-executor $cur ($matched_slot | get task_id)) ($cur.tick_count)
        let cleared = clear-slot (get-pending-slots $cur) $matched_executor $matched_index
        $cur = sync-legacy-mirror (set-pending-slots $cur $cleared | update fsm_state "harvesting")
        tick $cur $spool $root ($remaining - 1)
    } else {
        log-event "waiting_no_reply" {pending_request_id: $cur.pending_request_id}

        # Per-slot timeout: treat no-reply > 300s as a fail (triggers D2 retry
        # table on next harvest). Timed-out slots keep their task/request so
        # the retry reuses the same slot; dispatched_at is blanked so the
        # injection fires once.
        mut timed_out = []
        mut slots2 = get-pending-slots $cur
        for entry in $occupied {
            let da = $entry.slot | get dispatched_at
            if $da != "" {
                let elapsed = (date now) - ($da | into datetime --timezone UTC)
                if ($elapsed | into int) > 300_000_000_000 {   # 300s in nanoseconds
                    log-event "waiting_timeout" {
                        pending_request_id: ($entry.slot | get request_id)
                        pending_task_id:    ($entry.slot | get task_id)
                        dispatched_at:      $da
                    }
                    # Inject a synthetic fail reply into the spool so the next harvest triggers retry
                    let ts = date now | format date "%Y%m%d%H%M%S"
                    let synth_id = $"<timeout.(($entry.slot | get task_id)).($ts)@smolfire.local>"
                    let synth_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($synth_id)
In-Reply-To: (($entry.slot | get request_id))
Content-Type: text/toml; charset=utf-8

task_id = \"(($entry.slot | get task_id))\"
verdict = \"fail\"
failure_reason = \"timeout: no reply within 300s\"
"
                    $synth_msg | save --append $spool
                    $slots2 = update-slot-field $slots2 $entry.executor $entry.index "dispatched_at" ""
                    $timed_out = $timed_out | append $entry
                }
            }
        }

        if ($timed_out | length) > 0 {
            let first = $timed_out | first
            $cur = sync-legacy-mirror (set-pending-slots $cur $slots2)
            log-transition "waiting" "idle" "reply-timeout" --task-id ($first.slot | get task_id) --attempt ($cur.attempt_counts | get -o ($first.slot | get task_id) | default 0) --message-id ($first.slot | get request_id)
            return ($cur | update fsm_state "idle")
        }

        log-transition "waiting" "waiting" "no-reply" --task-id $cur.pending_task_id --attempt ($cur.attempt_counts | get -o $cur.pending_task_id | default 0) --message-id $cur.pending_request_id
        $cur
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

# dispatching: send every stamped-but-unsent slot (dispatched_at == ""), in
# canonical executor order — one spool append, one inflight entry, and one
# worker spawn per slot-fill, same argv-only convention as before.
# The S-012 guard runs once PER slot-fill with that slot's request_id
# (extended, never removed: N outstanding requests widen the crash window).
def state-dispatching [state: record, spool: string, root: string, remaining: int] {
    mut cur = sync-legacy-mirror $state

    # Recovery: an occupied slot that claims "sent" but has no coordinator
    # dispatch threaded to its request_id never actually sent (crash between
    # stamp and append with a persisted dispatched_at). Requeue it for send;
    # a slot whose dispatch exists-but-is-answered is left alone — waiting
    # routes its reply to harvest.
    for entry in (slot-entries (get-pending-slots $cur)) {
        let sl = $entry.slot
        if ($sl | get task_id) != "" and ($sl | get dispatched_at) != "" {
            let content = try { open --raw $spool } catch { "" }
            let messages = if $content == "" { [] } else { parse-mbox $content }
            let has_disp = ($messages | any {|m|
                ($m.headers | get "In-Reply-To"? | default "") == ($sl | get request_id)
                and ($m.headers | get "From"? | default "") == "coordinator@smolfire.local"
            })
            if not $has_disp {
                $cur = set-pending-slots $cur (update-slot-field (get-pending-slots $cur) $entry.executor $entry.index "dispatched_at" "")
            }
        }
    }

    let unsent = (slot-entries (get-pending-slots $cur)) | where {|e|
        ($e.slot | get task_id) != "" and ($e.slot | get dispatched_at) == ""
    }

    if ($unsent | is-empty) {
        if (occupied-slot-count (get-pending-slots $cur)) > 0 {
            log-transition "dispatching" "waiting" "resume-inflight-dispatch" --task-id $cur.pending_task_id --message-id $cur.pending_request_id
            return (tick ($cur | update fsm_state "waiting") $spool $root ($remaining - 1))
        }
        # Nothing stamped (e.g. legacy dispatching state with blank scalars):
        # never phantom-dispatch an "unknown" task — park in idle.
        log-event "dispatch_skipped_no_slot" {task_id: ($cur | get pending_task_id? | default "unknown")}
        log-transition "dispatching" "idle" "backpressure-deferred" --task-id ($cur | get pending_task_id? | default "") --message-id ($cur | get pending_request_id? | default "")
        return (sync-legacy-mirror ($cur | update fsm_state "idle"))
    }

    mut backstopped = []

    for entry in $unsent {
        let ex = $entry.executor
        let idx = $entry.index
        let sl = $entry.slot
        let task_id = $sl | get task_id
        let slot_request = $sl | get request_id
        let slot_to = $sl | get to_addr

        let inflight = find-inflight-dispatch $spool $slot_request
        if $inflight != null {
            let inflight_id = msg-id $inflight
            log-event "dispatch_skipped_inflight" {
                task_id:             $task_id
                pending_request_id:  $slot_request
                existing_message_id: $inflight_id
            }
            log-transition "dispatching" "waiting" "resume-inflight-dispatch" --task-id $task_id --message-id $inflight_id
            $cur = sync-legacy-mirror (set-pending-slots $cur (set-slot (get-pending-slots $cur) $ex $idx ($sl | upsert request_id $inflight_id | upsert dispatched_at (now-str))))
            continue
        }

        let exec_info = $cur.task_executors | get -o $task_id | default {executor: $DEFAULT_EXECUTOR, network: false, request_id: $slot_request}

        # Backstop: harvesting gates every dispatch it routes, but a persisted
        # `dispatching` state (crash between harvest-save and spool-append) can
        # re-enter here with the caps since filled. Refuse rather than
        # over-dispatch; the trigger was already marked seen at harvest, so
        # un-mark it — the next tick rediscovers the work instead of dropping it.
        let gate = inflight-status (get-inflight $cur) $exec_info.executor
        if $gate.at_cap {
            log-backpressure $task_id $exec_info.executor "dispatch-backstop" $slot_request $gate
            let unseed = $cur.seen_ids | where {|s| $s != $slot_request }
            $cur = sync-legacy-mirror (set-pending-slots $cur (clear-slot (get-pending-slots $cur) $ex $idx) | update seen_ids $unseed)
            $backstopped = $backstopped | append {task_id: $task_id, trigger_id: $slot_request}
            continue
        }

        let attempt_n    = $cur.attempt_counts | get -o $task_id | default 0
        let next_attempt = $attempt_n + 1
        let ts           = date now | format date "%Y%m%d%H%M%S"
        let msg_id       = $"<coord.($cur.tick_count).r($next_attempt).($ts).($ex).($idx)@smolfire.local>"
        let to_addr      = if $slot_to != "" { $slot_to } else { $"($task_id)@smolfire.local" }
        let from_addr    = "coordinator@smolfire.local"

        let mbox_msg = $"From ($from_addr) ($ts)
From: ($from_addr)
To: ($to_addr)
Message-ID: ($msg_id)
X-Attempt: ($next_attempt)
Content-Type: text/toml; charset=utf-8
In-Reply-To: ($slot_request)

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

        # Occupy one inflight slot, counted in the crash-atomic state file.
        # Released on harvest (accept or S-003 escalation) or by prune-inflight.
        let slot_table = (get-inflight $cur) | upsert $task_id {executor: $exec_info.executor, since_tick: $cur.tick_count}

        if $exec_info.executor == "jail" {
            # Jail executor: run the ORIGINAL request's commands in an ephemeral
            # jail; the reply's In-Reply-To is this dispatch's Message-ID.
            spawn-jail-executor $task_id $msg_id $exec_info.request_id $spool $root
        } else if $exec_info.executor == "fleet" {
            # Fleet executor: run the ORIGINAL request's commands on the remote
            # fleet worker via the real fleet backend
            # (bin/coord-fleet-dispatch.nu dispatch — same run-fleet-task +
            # reply-envelope contract as dispatch-fleet in bin/coord-dispatch.nu,
            # threaded to this dispatch's Message-ID). This branch sits BEFORE
            # the spawn-subagent agent-type classification so fleet roles never
            # hit the claude-CLI path.
            spawn-fleet-executor $task_id $msg_id $exec_info.request_id $spool $root
        } else {
            # vm (default): unchanged. Auto-spawn a subagent (Phase II); agent_type
            # is derived from the local-part of the recipient address.
            let agent_type = ($to_addr | split row "@" | first | default "general-purpose")
            spawn-subagent $agent_type $task_id $spool $root
        }

        log-transition "dispatching" "waiting" "dispatch-sent" --task-id $task_id --attempt $next_attempt --message-id $msg_id

        let updated_counts = $cur.attempt_counts | upsert $task_id $next_attempt
        $cur = sync-legacy-mirror (set-inflight $cur $slot_table
            | update attempt_counts     $updated_counts
        )
        $cur = set-pending-slots $cur (set-slot (get-pending-slots $cur) $ex $idx {task_id: $task_id, request_id: $msg_id, to_addr: $to_addr, dispatched_at: (now-str)})
        $cur = sync-legacy-mirror $cur
    }

    if (occupied-slot-count (get-pending-slots $cur)) > 0 {
        tick ($cur | update fsm_state "waiting") $spool $root ($remaining - 1)
    } else {
        let ctx = if ($backstopped | length) > 0 { $backstopped | first } else { {task_id: "", trigger_id: ""} }
        log-transition "dispatching" "idle" "backpressure-deferred" --task-id $ctx.task_id --message-id $ctx.trigger_id
        $cur | update fsm_state "idle"
    }
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

    # Sweep inflight slots that can never drain through harvest (halted,
    # budget-exhausted, stale) — the no-orphan-slot guarantee — then mark
    # silent workers dead and reap their tasks to the retry path. Both run in
    # every FSM state, before the HALT check, so a halted coordinator still
    # reclaims rather than leaking caps across the pause. Prune runs first so
    # halted/exhausted/stale slots are owned elsewhere, never reaped.
    let swept_state = sweep-dead-workers (prune-inflight $resumed_state) $spool

    # O(1) HALT check before every state dispatch — spec §13.
    if (halt-present $root) {
        return (state-halted $swept_state $root $spool "halt-marker-present")
    }

    let next_count = $swept_state.tick_count + 1
    let stamped = $swept_state
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
