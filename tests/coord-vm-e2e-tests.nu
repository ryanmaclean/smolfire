#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/coord-vm-e2e-tests.nu — end-to-end test: coord dispatches to real VM and harvests reply
#
# This suite boots a real smolfire VM, submits a task through the coordinator
# FSM, and asserts that the reply is correctly harvested back into state.
#
# Prerequisites (all checked at runtime; suite skips gracefully if absent):
#   - build/FreeBSD-15-aarch64-smolfire.qcow2   — smolfire boot image
#   - bin/vm-execute.nu                         — VM execution driver (parallel work)
#   - sshpass OR expect                         — for unattended SSH
#
# Runtime: ~30–60 s (real VM boot via HVF).  Run with:
#   nu --no-config-file tests/run-tests.nu --suite e2e-coord

use ../bin/mbox-parse.nu [parse-mbox, msg-id]

# Drop every PATH directory that contains an executable named after a known
# billed-agent CLI (binary-existence check, not a directory-name string
# match — see tests/spawn-subagent-test.nu for why that's the wrong check).
def strip-agent-bins [path: list<string>] {
    let agent_bins = [claude codex opencode ollama]
    $path | where {|dir| $agent_bins | all {|bin| not ($dir | path join $bin | path exists) } }
}

# ── Prerequisite checks ────────────────────────────────────────────────────────

# Return a skip record if a prerequisite is absent, null otherwise.
def check-prereqs [] {
    let qcow2      = "build/FreeBSD-15-aarch64-smolfire.qcow2"
    let vm_execute = "bin/vm-execute.nu"

    if not ($qcow2 | path exists) {
        return {
            name:   "coord-vm-e2e"
            status: "skip"
            detail: $"qcow2 not present: ($qcow2)"
        }
    }

    if not ($vm_execute | path exists) {
        return {
            name:   "coord-vm-e2e"
            status: "skip"
            detail: "bin/vm-execute.nu not yet implemented — skipping e2e suite"
        }
    }

    # Need at least one mechanism for passwordless SSH to the VM.
    let has_sshpass = (^which sshpass | complete | get exit_code) == 0
    let has_expect  = (^which expect  | complete | get exit_code) == 0
    if not $has_sshpass and not $has_expect {
        return {
            name:   "coord-vm-e2e"
            status: "skip"
            detail: "neither sshpass nor expect found — cannot drive SSH to VM"
        }
    }

    null   # all prerequisites satisfied
}

# ── Temp-directory scaffolding ────────────────────────────────────────────────

# Create an isolated temp root with the subdirectory layout coord-tick expects.
# Returns the absolute path string.
def make-e2e-root [] {
    let tmp = ^mktemp -d -t smolfire-e2e | str trim
    mkdir ($tmp | path join "var" "mail")
    mkdir ($tmp | path join "var" "run")
    mkdir ($tmp | path join "var" "run" "dispatch-logs")
    $tmp
}

def cleanup-e2e-root [root: string] {
    if ($root | path exists) {
        rm -rf $root
    }
}

# ── Spool helpers ─────────────────────────────────────────────────────────────

# Count the number of "From " separator lines in an mbox file.
def count-from-lines [spool_path: string] {
    if not ($spool_path | path exists) { return 0 }
    open --raw $spool_path
    | lines
    | where { |l| $l | str starts-with "From " }
    | length
}

# ── coord-tick helpers ───────────────────────────────────────────────────────

# Run coord-tick once and return the state record regardless of exit code.
# Absorbs any error from the subprocess (including job-spawn propagation when
# the claude CLI is absent from coord-dispatch.nu).
#
# Billed-subprocess guard: this e2e suite drives real dispatch transitions
# against a real VM, but must never trigger a real `claude`/codex spawn.
# SMOLFIRE_SPAWN_SUBAGENT is left unset (spawn-subagent's default-off gate)
# and PATH is hardened by stripping any directory that resolves a real
# claude/codex/opencode/ollama binary, as defense-in-depth. nu itself is
# invoked by absolute path so stripping PATH can't take out the interpreter
# running the child.
def safe-tick-and-read-state [root: string, spool_abs: string, state_abs: string] {
    let spool_rel = $spool_abs | str replace $"($root)/" ""
    let state_rel = $state_abs | str replace $"($root)/" ""
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH
    # The inner nu process is captured via complete; any further Nushell job error
    # is absorbed by the outer try.
    let _ignored = try {
        with-env {PATH: $hermetic_path} {
            hide-env -i SMOLFIRE_SPAWN_SUBAGENT
            (^$nu_bin --no-config-file bin/coord-tick.nu --root $root --spool $spool_rel --state-file $state_rel --max-ticks 8) | complete
        }
    } catch {
        null  # absorb — we read state file below regardless
    }
    if ($state_abs | path exists) {
        try { open --raw $state_abs | from toml } catch { {} }
    } else { {} }
}

# Run coord-tick once with explicit absolute spool + state paths.
# Returns the complete record from `| complete`.
#
# Billed-subprocess guard: same hermetic-PATH + default-off-spawn treatment
# as safe-tick-and-read-state above.
def run-tick [root: string, spool_abs: string, state_abs: string, max_ticks: int = 10] {
    # coord-tick resolves spool and state-file relative to --root.
    # We pass them as absolute paths; coord-tick path-joins root+rel so we
    # must supply the root as "/" and the already-absolute path as "relative"
    # — OR we pass --root $root and bare filenames that live under it.
    # Simplest: pass --root as the tmpdir and relative paths as "var/..." names
    # which we derived from the absolute paths.
    let spool_rel = $spool_abs | str replace $"($root)/" ""
    let state_rel = $state_abs | str replace $"($root)/" ""
    let nu_bin = $nu.current-exe
    let hermetic_path = strip-agent-bins $env.PATH

    with-env {PATH: $hermetic_path} {
        hide-env -i SMOLFIRE_SPAWN_SUBAGENT
        (^$nu_bin --no-config-file bin/coord-tick.nu --root $root --spool $spool_rel --state-file $state_rel --max-ticks $max_ticks) | complete
    }
}

# ── Individual test cases ─────────────────────────────────────────────────────

# Test A: coord-submit writes a vm-builder task into the spool.
def test-submit-vm-task [root: string, spool_abs: string] {
    let name      = "e2e: coord-submit writes vm-builder task to spool"
    let task_id   = "task-e2e-001"
    let task_body = $"task_id = \"($task_id)\"\nrole    = \"vm-builder\"\n\n[brief]\nobjective = \"Boot smolfire and capture identity\"\n\n[commands]\nrun = [\"uname -a\", \"echo SMOLFIRE_E2E_OK\"]\n\n[context_pointers]\nimage_path = \"build/FreeBSD-15-aarch64-smolfire.qcow2\"\narch       = \"arm64\"\n"

    let result = (^nu --no-config-file bin/coord-submit.nu --task-id $task_id --role "vm-builder" --subject "E2E test boot" --body $task_body --spool $spool_abs) | complete

    let submitted   = $result.exit_code == 0
    let from_count  = count-from-lines $spool_abs
    let has_task_id = if ($spool_abs | path exists) {
        open --raw $spool_abs | str contains $task_id
    } else { false }

    let ok = $submitted and $from_count >= 1 and $has_task_id

    if $ok {
        {name: $name, status: "pass", detail: $"submitted ($task_id); spool from_lines=($from_count)"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($result.exit_code) from_lines=($from_count) has_task_id=($has_task_id) stderr=($result.stderr | str substring ..300)"}
    }
}

# Test B: seed pending_dispatch in state, run tick-1, assert FSM dispatched the task.
#
# coord-submit writes the request envelope to the spool but does NOT seed
# pending_dispatch — that record is what tells state-dispatching to fire.
# We write it here so that tick-1 enters dispatching -> launches vm-execute.nu
# (via dispatch-subagent) -> moves to waiting.
def test-tick1-dispatches [root: string, spool_abs: string, state_abs: string] {
    let name    = "e2e: tick-1 dispatches vm-builder task (waiting state)"
    let task_id = "task-e2e-001"

    # Read current state (written by tick-0 harvesting) and inject pending_dispatch.
    let cur_state = if ($state_abs | path exists) {
        try { open --raw $state_abs | from toml } catch { {} }
    } else { {} }

    let task_body = $"task_id = \"($task_id)\"\nrole    = \"vm-builder\"\n\n[brief]\nobjective = \"Boot smolfire and capture identity\"\n\n[commands]\nrun = [\"uname -a\", \"echo SMOLFIRE_E2E_OK\"]\n\n[context_pointers]\nimage_path = \"build/FreeBSD-15-aarch64-smolfire.qcow2\"\narch       = \"arm64\"\n"

    # Seed the current state-dispatching contract: pending_task_id / pending_to_addr /
    # pending_request_id. The original Message-ID is the request envelope coord-submit
    # wrote to the spool in test A; we look it up by scanning the spool for an
    # envelope whose task_id matches.
    let initial_req_id = if ($spool_abs | path exists) {
        let raw  = open --raw $spool_abs
        let msgs = parse-mbox $raw
        let match = $msgs | where {|m|
            let mid = $m.headers | get "Message-ID"? | default ""
            ($mid | str contains $task_id) and (($m.headers | get "In-Reply-To"? | default "") == "")
        } | first 1
        if ($match | length) > 0 {
            $match | first | get headers | get "Message-ID"
        } else {
            $"<($task_id).initial@smolfire.local>"
        }
    } else {
        $"<($task_id).initial@smolfire.local>"
    }

    let seeded = $cur_state
        | upsert fsm_state          "dispatching"
        | upsert pending_task_id    $task_id
        | upsert pending_to_addr    "vm-builder@smolfire.local"
        | upsert pending_request_id $initial_req_id
        | upsert dispatched_at      ""

    let state_dir = $state_abs | path dirname
    if not ($state_dir | path exists) { mkdir $state_dir }
    $seeded | to toml | save --force $state_abs

    # Tick-1: should enter dispatching -> write envelope -> launch subagent -> waiting.
    let result = run-tick $root $spool_abs $state_abs 8

    let state = if ($state_abs | path exists) {
        try { open --raw $state_abs | from toml } catch { {} }
    } else { {} }

    let fsm        = $state | get fsm_state? | default "?"
    # coord-tick.nu logs the actual events as 'dispatch_sent' and 'subagent_spawned'.
    let dispatched = $result.stdout | str contains "dispatch_sent"
    let launched   = $result.stdout | str contains "subagent_spawned"

    # After dispatch the FSM moves to "waiting"; if the background subagent
    # finished synchronously and the coord ran more ticks it may be "idle".
    let fsm_ok = $fsm == "waiting" or $fsm == "idle"
    let ok     = $result.exit_code == 0 and $fsm_ok and $dispatched

    if $ok {
        {name: $name, status: "pass", detail: $"exit=0 fsm_state=($fsm) dispatched=true launched=($launched)"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($result.exit_code) fsm=($fsm) dispatched=($dispatched) stdout=($result.stdout | str substring ..500)"}
    }
}

# Test C: poll coord-tick until a reply appears in the spool (VM has finished).
# Maximum wall-clock: 90 s (aarch64 HVF boots in ~11 s; command + reply write ~5 s).
def test-tick2-harvests-reply [root: string, spool_abs: string, state_abs: string] {
    let name           = "e2e: tick-2+ harvests VM reply into state"
    let deadline_ticks = 6   # up to 6 extra coord-ticks before giving up
    let sleep_secs     = 15  # pause between polls

    mut final_state   = {}
    mut reply_present = false
    mut tick_num      = 0

    loop {
        $tick_num = $tick_num + 1

        # safe-tick: runs coord-tick and absorbs any error (including job-spawn
        # propagation from coord-dispatch when claude CLI is absent).
        $final_state = (safe-tick-and-read-state $root $spool_abs $state_abs)

        # A reply is present if there are ≥2 From-lines AND the spool contains
        # the FreeBSD uname string or our echo marker.
        let from_count    = count-from-lines $spool_abs
        let spool_content = if ($spool_abs | path exists) { open --raw $spool_abs } else { "" }
        let has_reply_content = ($spool_content | str contains "FreeBSD") or ($spool_content | str contains "SMOLFIRE_E2E_OK")

        if $from_count >= 2 and $has_reply_content {
            $reply_present = true
            break
        }

        if $tick_num >= $deadline_ticks {
            break
        }

        # Wait before next poll so we don't busy-spin while the VM boots.
        sleep ($sleep_secs * 1sec)
    }

    let seen_count = $final_state | get seen_ids? | default [] | length
    let fsm        = $final_state | get fsm_state? | default "?"

    let ok = $reply_present and $seen_count >= 2 and $fsm == "idle"

    if $ok {
        {name: $name, status: "pass", detail: $"reply harvested after ($tick_num) extra tick(s); seen_ids=($seen_count)"}
    } else {
        {name: $name, status: "fail", detail: $"reply_present=($reply_present) seen_ids=($seen_count) fsm=($fsm) after ($tick_num) poll(s)"}
    }
}

# Test D: spool contains FreeBSD identity string in the reply.
def test-reply-contains-freebsd [spool_abs: string] {
    let name          = "e2e: reply contains FreeBSD identity (uname -a)"
    let spool_content = if ($spool_abs | path exists) { open --raw $spool_abs } else { "" }
    let has_freebsd   = $spool_content | str contains "FreeBSD"

    if $has_freebsd {
        {name: $name, status: "pass", detail: "FreeBSD string found in spool reply body"}
    } else {
        # Degrade to skip if the VM hasn't replied yet (earlier test already failed).
        {name: $name, status: "fail", detail: "FreeBSD not found in spool — uname output missing"}
    }
}

# Test E: spool contains the echo marker proving our command ran.
def test-reply-contains-marker [spool_abs: string] {
    let name          = "e2e: reply contains SMOLFIRE_E2E_OK echo marker"
    let spool_content = if ($spool_abs | path exists) { open --raw $spool_abs } else { "" }
    let has_marker    = $spool_content | str contains "SMOLFIRE_E2E_OK"

    if $has_marker {
        {name: $name, status: "pass", detail: "SMOLFIRE_E2E_OK marker found in spool"}
    } else {
        {name: $name, status: "fail", detail: "SMOLFIRE_E2E_OK not found — echo command did not appear in reply"}
    }
}

# Test F: state.seen_ids contains at least 2 entries (request + reply).
def test-state-seen-ids [state_abs: string] {
    let name  = "e2e: state.seen_ids includes both request and reply Message-IDs"
    let state = if ($state_abs | path exists) {
        try { open --raw $state_abs | from toml } catch { {} }
    } else { {} }

    let seen_count = $state | get seen_ids? | default [] | length

    if $seen_count >= 2 {
        {name: $name, status: "pass", detail: $"seen_ids count = ($seen_count) (>= 2)"}
    } else {
        {name: $name, status: "fail", detail: $"seen_ids count = ($seen_count) — expected >= 2"}
    }
}

# ── Public entry point ─────────────────────────────────────────────────────────

# Run the full coordinator → VM → reply → harvest e2e suite.
# Returns a list of {name, status, detail} records compatible with run-tests.nu.
export def run-coord-vm-e2e-tests [] {
    # --- prerequisite gate ---
    let prereq_skip = check-prereqs
    if $prereq_skip != null {
        return [$prereq_skip]
    }

    # --- temp scaffolding ---
    let root      = make-e2e-root
    let spool_abs = $root | path join "var" "mail" "spool"
    let state_abs = $root | path join "var" "run" "coord-state.toml"

    # Ensure an empty spool file exists before submit.
    "" | save $spool_abs

    # Run all tests; collect results; cleanup regardless of outcome.
    let results = run-e2e-suite $root $spool_abs $state_abs

    cleanup-e2e-root $root
    $results
}

# Inner helper — runs the suite steps without mutation-in-closure issues.
def run-e2e-suite [root: string, spool_abs: string, state_abs: string] {
    # A: submit the task
    let ra = try { test-submit-vm-task $root $spool_abs } catch {|e| {name: "e2e: coord-submit writes vm-builder task to spool", status: "fail", detail: $"exception: ($e.msg)"}}

    if $ra.status == "fail" {
        return [
            $ra
            {name: "e2e: tick-1 dispatches vm-builder task (waiting state)",               status: "skip", detail: "skipped — submit failed"}
            {name: "e2e: tick-2+ harvests VM reply into state",                            status: "skip", detail: "skipped — submit failed"}
            {name: "e2e: reply contains FreeBSD identity (uname -a)",                      status: "skip", detail: "skipped — submit failed"}
            {name: "e2e: reply contains SMOLFIRE_E2E_OK echo marker",                       status: "skip", detail: "skipped — submit failed"}
            {name: "e2e: state.seen_ids includes both request and reply Message-IDs",      status: "skip", detail: "skipped — submit failed"}
        ]
    }

    # B: first tick — dispatch
    let rb = try { test-tick1-dispatches $root $spool_abs $state_abs } catch {|e| {name: "e2e: tick-1 dispatches vm-builder task (waiting state)", status: "fail", detail: $"exception: ($e.msg)"}}

    # C: poll for reply
    let rc = try { test-tick2-harvests-reply $root $spool_abs $state_abs } catch {|e| {name: "e2e: tick-2+ harvests VM reply into state", status: "fail", detail: $"exception: ($e.msg)"}}

    # D–F: assertions on spool + state content
    let rd = try { test-reply-contains-freebsd $spool_abs } catch {|e| {name: "e2e: reply contains FreeBSD identity (uname -a)",    status: "fail", detail: $"exception: ($e.msg)"}}
    let re = try { test-reply-contains-marker   $spool_abs } catch {|e| {name: "e2e: reply contains SMOLFIRE_E2E_OK echo marker",     status: "fail", detail: $"exception: ($e.msg)"}}
    let rf = try { test-state-seen-ids           $state_abs } catch {|e| {name: "e2e: state.seen_ids includes both request and reply Message-IDs", status: "fail", detail: $"exception: ($e.msg)"}}

    [$ra $rb $rc $rd $re $rf]
}
