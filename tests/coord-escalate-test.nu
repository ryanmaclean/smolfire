#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/coord-escalate-test.nu — hermetic unit tests for bin/coord-escalate.nu
#
# Tests the D3 escalation entry point per spec §13.
# Each test is hermetic: it creates a temp directory, invokes coord-escalate.nu
# as a subprocess, inspects the produced files, and cleans up.
#
# Run standalone:
#   nu tests/coord-escalate-test.nu
#
# Auto-discovered by tests/run-all.sh (glob *-test.nu).
# Wired into tests/run-tests.nu --suite unit as run-coord-escalate-tests.

# ── Helpers ────────────────────────────────────────────────────────────────────

def make-temp-root [] {
    let tmp = ^mktemp -d | str trim
    mkdir ($tmp | path join "var" "mail")
    mkdir ($tmp | path join "var" "run")
    $tmp
}

def cleanup [root: string] {
    if ($root | path exists) { rm -rf $root }
}

# Run coord-escalate.nu once as a subprocess.
# Returns {stdout, stderr, exit_code}.
def run-escalate [
    root:     string
    task_id:  string
    reason:   string
    verdict:  string = ""
    attempts: int    = 0
    spool:    string = "var/mail/spool"
] {
    # Ensure a spool file exists so --append can work.
    let spool_abs = [$root, $spool] | path join
    if not ($spool_abs | path exists) {
        "" | save $spool_abs
    }

    # Build arg list conditionally — an empty --verdict "" causes Nushell to
    # misparse the next flag as a positional argument.
    let verdict_args = if ($verdict | str length) > 0 { ["--verdict", $verdict] } else { [] }
    let result = (^nu --no-config-file bin/coord-escalate.nu
        --root    $root
        --spool   $spool
        --task-id $task_id
        --reason  $reason
        --attempts $attempts
        ...$verdict_args
    ) | complete

    {
        stdout:    $result.stdout
        stderr:    $result.stderr
        exit_code: $result.exit_code
    }
}

# ── Test 1: HALT marker is created with required TOML fields ──────────────────

def test-halt-marker-created [] {
    let name = "escalate: HALT marker written with required fields"
    let root = make-temp-root

    let r = run-escalate $root "t42" "retry-exhausted" "fail" 3

    let halt_path = [$root, "var", "mail", "HALT.t42"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code) stderr=($r.stderr | str substring ..300)"}
        }
        if not ($halt_path | path exists) {
            cleanup $root
            return {name: $name, status: "fail", detail: "HALT.t42 not created"}
        }
        let halt = open --raw $halt_path | from toml
        let task_ok    = ($halt | get task_id?   | default "") == "t42"
        let reason_ok  = ($halt | get reason?    | default "") == "retry-exhausted"
        let verdict_ok = ($halt | get verdict?   | default "") == "fail"
        # attempts is an int — allow either int or string representation
        let att_raw    = $halt | get attempts? | default 0
        let att_ok     = ($att_raw | into string) == "3"
        # escalated_at must be present and non-empty
        let esc_at_ok  = ($halt | get escalated_at? | default "" | str length) > 0

        $task_ok and $reason_ok and $verdict_ok and $att_ok and $esc_at_ok
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "HALT.t42 written; task_id, reason, verdict, attempts, escalated_at all present"}
    } else {
        {name: $name, status: "fail", detail: "one or more required TOML fields missing or incorrect"}
    }
}

# ── Test 2: HALT mbox message appended to spool with required headers ─────────

def test-halt-mbox-message-headers [] {
    let name = "escalate: HALT mbox message has required headers"
    let root = make-temp-root

    let r = run-escalate $root "t99" "no-unblocker" "blocked" 1

    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code) stderr=($r.stderr | str substring ..300)"}
        }
        let raw = open --raw $spool_path
        # Must contain the task_id in the Subject line.
        let has_subject_task = $raw | str contains "t99"
        # Must have X-Halt-Reason header.
        let has_halt_reason  = $raw | str contains "X-Halt-Reason: no-unblocker"
        # Must have a Message-ID header.
        let has_msg_id       = $raw | str contains "Message-ID:"
        # Message-ID must reference the task_id.
        let has_task_in_id   = $raw | str contains "escalate.t99."

        $has_subject_task and $has_halt_reason and $has_msg_id and $has_task_in_id
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "X-Halt-Reason, Message-ID, Subject(task_id) all present in spool"}
    } else {
        {name: $name, status: "fail", detail: "one or more required mbox headers missing"}
    }
}

# ── Test 3a: reason field propagates — retry-exhausted ───────────────────────

def test-reason-retry-exhausted [] {
    let name = "escalate: reason=retry-exhausted propagated to HALT marker and spool"
    let root = make-temp-root

    let r = run-escalate $root "task-re" "retry-exhausted" "fail" 3

    let halt_path  = [$root, "var", "mail", "HALT.task-re"] | path join
    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let halt   = open --raw $halt_path | from toml
        let spool  = open --raw $spool_path
        let hlt_ok  = ($halt | get reason? | default "") == "retry-exhausted"
        let spl_ok  = $spool | str contains "retry-exhausted"
        $hlt_ok and $spl_ok
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "reason=retry-exhausted in HALT marker and spool"}
    } else {
        {name: $name, status: "fail", detail: "reason not propagated correctly for retry-exhausted"}
    }
}

# ── Test 3b: reason field propagates — no-unblocker ──────────────────────────

def test-reason-no-unblocker [] {
    let name = "escalate: reason=no-unblocker propagated to HALT marker and spool"
    let root = make-temp-root

    let r = run-escalate $root "task-nb" "no-unblocker" "blocked" 2

    let halt_path  = [$root, "var", "mail", "HALT.task-nb"] | path join
    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let halt   = open --raw $halt_path | from toml
        let spool  = open --raw $spool_path
        let hlt_ok = ($halt | get reason? | default "") == "no-unblocker"
        let spl_ok = $spool | str contains "no-unblocker"
        $hlt_ok and $spl_ok
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "reason=no-unblocker in HALT marker and spool"}
    } else {
        {name: $name, status: "fail", detail: "reason not propagated correctly for no-unblocker"}
    }
}

# ── Test 3c: reason field propagates — arbitrary custom string ────────────────

def test-reason-custom-string [] {
    let name = "escalate: arbitrary reason string propagated correctly"
    let root = make-temp-root

    let r = run-escalate $root "task-cs" "probe-disagreement-v2" "" 1

    let halt_path  = [$root, "var", "mail", "HALT.task-cs"] | path join
    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let halt  = open --raw $halt_path | from toml
        let spool = open --raw $spool_path
        let hlt_ok = ($halt | get reason? | default "") == "probe-disagreement-v2"
        let spl_ok = $spool | str contains "probe-disagreement-v2"
        $hlt_ok and $spl_ok
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "custom reason 'probe-disagreement-v2' propagated to both files"}
    } else {
        {name: $name, status: "fail", detail: "custom reason not propagated correctly"}
    }
}

# ── Test 4: proposed_actions is a TOML array (not a bare string) ──────────────

def test-proposed-actions-toml-array [] {
    let name = "escalate: proposed_actions is a TOML array in spool body"
    let root = make-temp-root

    let r = run-escalate $root "task-pa" "retry-exhausted" "fail" 3

    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let raw = open --raw $spool_path

        # Extract the TOML body from the spool message.
        # The body starts after the blank line following the headers.
        # Look for the proposed_actions line and verify it's array syntax.
        let lines = $raw | lines
        let pa_lines = $lines | where {|l| $l | str contains "proposed_actions"}
        if ($pa_lines | length) == 0 {
            return false
        }
        let pa_line = $pa_lines | first

        # Must be TOML array syntax: proposed_actions = ["retry", "abort", "edit"]
        # i.e. contains "[" and "]" and at least one quoted element
        let has_array_brackets = ($pa_line | str contains "[") and ($pa_line | str contains "]")
        let has_quoted_element = ($pa_line | str contains "\"retry\"") or ($pa_line | str contains "\"abort\"")

        # Must NOT be a plain string (no proposed_actions = "retry abort edit" form)
        let not_plain_string = not ($pa_line | parse --regex 'proposed_actions\s*=\s*"[^"]*"' | length | into bool)

        $has_array_brackets and $has_quoted_element and $not_plain_string
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "proposed_actions is TOML array with quoted elements"}
    } else {
        {name: $name, status: "fail", detail: "proposed_actions is not a valid TOML array in spool body"}
    }
}

# ── Test 5: IRC fallback — HALT marker written even when IRC unreachable ───────
#
# Spec §13 says coord-escalate writes fallback_fired and fallback_status to the
# HALT marker after attempting the IRC DM.  The current implementation does NOT
# yet contain IRC DM code — the test captures the current behaviour and will
# start failing the fallback_fired/fallback_status assertions when that code
# lands, acting as a regression guard.
#
# NOTE: When IRC fallback IS implemented the test body should pass an explicit
# --irc-host "127.0.0.1:1" flag so no real LAN connection is attempted.

def test-irc-fallback-file-written [] {
    let name = "escalate: HALT marker written even when IRC fallback not available"
    let root = make-temp-root

    # Hermetic: never let an ambient SMOLFIRE_IRC_HOST reach a real network.
    hide-env -i SMOLFIRE_IRC_HOST
    let r = run-escalate $root "task-irc" "retry-exhausted" "fail" 3

    let halt_path = [$root, "var", "mail", "HALT.task-irc"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code) stderr=($r.stderr | str substring ..300)"}
        }
        # Primary requirement: HALT marker file exists (filesystem-local path
        # always succeeds even when IRC is not reachable).
        ($halt_path | path exists)
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    # Spec §13: fallback_fired / fallback_status are MANDATORY in the marker
    # (parity with coord-tick.nu's try-irc-dm; the old known gap is closed).
    # SMOLFIRE_IRC_HOST is unset in this hermetic run => inert "no-route".
    let halt = try { open --raw $halt_path | from toml } catch { {} }
    let has_fallback_fields = ($halt | get fallback_fired? | default null) == true and ($halt | get fallback_status? | default "") == "no-route"

    cleanup $root
    if $ok and $has_fallback_fields {
        {name: $name, status: "pass", detail: "HALT marker present; fallback_fired=true, fallback_status=no-route"}
    } else if $ok {
        {name: $name, status: "fail", detail: "HALT marker lacks spec §13 fallback_fired/fallback_status"}
    } else {
        {name: $name, status: "fail", detail: "HALT marker not written"}
    }
}

# ── Test 6: global HALT marker (var/mail/HALT without suffix) ─────────────────
#
# Spec §13: the global HALT file is written by the operator manually, NOT by
# coord-escalate.nu.  coord-escalate only writes per-task HALT.<task_id> files.
# This test documents that intentional boundary and verifies that invoking
# coord-escalate does NOT create var/mail/HALT (no suffix).

def test-no-global-halt-written [] {
    let name = "escalate: coord-escalate does NOT write global HALT marker"
    let root = make-temp-root

    let r = run-escalate $root "task-gh" "retry-exhausted" "fail" 3

    let global_halt_path  = [$root, "var", "mail", "HALT"] | path join
    let per_task_halt_path = [$root, "var", "mail", "HALT.task-gh"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        # Per-task HALT must exist; global HALT must NOT exist.
        ($per_task_halt_path | path exists) and (not ($global_halt_path | path exists))
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "HALT.task-gh written; global var/mail/HALT absent (operator writes this per §13)"}
    } else {
        {name: $name, status: "fail", detail: "global HALT marker unexpectedly present, or per-task HALT absent"}
    }
}

# ── Test 7: spool is appended to — existing messages are preserved ─────────────

def test-spool-append-preserves-existing [] {
    let name = "escalate: escalation appends to spool without destroying existing messages"
    let root = make-temp-root

    let spool_path = [$root, "var", "mail", "spool"] | path join

    # Pre-seed the spool with a prior message.
    let prior_msg = "From prior@smolfire.local Mon May  4 10:00:00 2026
From: prior@smolfire.local
To: coordinator@smolfire.local
Subject: existing task
Message-ID: <prior.task@smolfire.local>
Content-Type: text/toml; charset=utf-8

task_id = \"existing\"
verdict  = \"pass\"
"
    $prior_msg | save $spool_path

    let r = run-escalate $root "task-app" "retry-exhausted" "fail" 3

    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let raw = open --raw $spool_path
        # Both the original message and the new escalation message must be present.
        let has_prior = $raw | str contains "prior.task@smolfire.local"
        let has_new   = $raw | str contains "task-app"
        let has_hdr   = $raw | str contains "X-Halt-Reason: retry-exhausted"
        $has_prior and $has_new and $has_hdr
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "prior message preserved; escalation appended"}
    } else {
        {name: $name, status: "fail", detail: "spool overwritten or escalation message missing"}
    }
}

# ── Test 8: --task-id validation guard is present in source ───────────────────
# We verify the guard textually because `| complete` error-capture has unstable
# behaviour in Nu 0.111 module context.  The positive-path tests above already
# confirm that a successful invocation with --task-id writes the expected files.

def test-task-id-guard-present [] {
    let name = "escalate: --task-id guard is present in source"
    let src = open --raw bin/coord-escalate.nu
    let has_guard = ($src | str contains "--task-id is required")
    if $has_guard {
        {name: $name, status: "pass", detail: "--task-id validation guard found in source"}
    } else {
        {name: $name, status: "fail", detail: "--task-id guard missing from bin/coord-escalate.nu"}
    }
}

# ── Test 9: --reason validation guard is present in source ────────────────────

def test-reason-guard-present [] {
    let name = "escalate: --reason guard is present in source"
    let src = open --raw bin/coord-escalate.nu
    let has_guard = ($src | str contains "--reason is required")
    if $has_guard {
        {name: $name, status: "pass", detail: "--reason validation guard found in source"}
    } else {
        {name: $name, status: "fail", detail: "--reason guard missing from bin/coord-escalate.nu"}
    }
}

# ── Test 10: Message-ID in spool matches task_id ──────────────────────────────

def test-message-id-contains-task-id [] {
    let name = "escalate: Message-ID in spool encodes task_id"
    let root = make-temp-root

    let r = run-escalate $root "task-mid" "retry-exhausted" "fail" 2

    let spool_path = [$root, "var", "mail", "spool"] | path join
    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        let raw = open --raw $spool_path
        # Format: <escalate.{task_id}.{ts}@smolfire.local>
        $raw | str contains "escalate.task-mid."
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "Message-ID contains 'escalate.task-mid.'"}
    } else {
        {name: $name, status: "fail", detail: "Message-ID does not encode task_id in expected format"}
    }
}

# ── Test 11: stdout logs escalation steps ─────────────────────────────────────

def test-stdout-logs-steps [] {
    let name = "escalate: stdout contains structured log steps"
    let root = make-temp-root

    let r = run-escalate $root "task-log" "retry-exhausted" "fail" 3

    let ok = try {
        if $r.exit_code != 0 {
            cleanup $root
            return {name: $name, status: "fail", detail: $"exit=($r.exit_code)"}
        }
        # Three steps must be logged: escalate-spool, escalate-halt, escalate-done
        let spool_logged = $r.stdout | str contains "escalate-spool"
        let halt_logged  = $r.stdout | str contains "escalate-halt"
        let done_logged  = $r.stdout | str contains "escalate-done"
        $spool_logged and $halt_logged and $done_logged
    } catch {|e|
        cleanup $root
        return {name: $name, status: "fail", detail: $"exception: ($e.msg)"}
    }

    cleanup $root
    if $ok {
        {name: $name, status: "pass", detail: "escalate-spool, escalate-halt, escalate-done all in stdout"}
    } else {
        {name: $name, status: "fail", detail: $"stdout missing step logs: ($r.stdout | str substring ..400)"}
    }
}

# ── Test 12: HALT marker parity with coord-tick.nu write-halt-marker ──────────

def test-halt-marker-parity [] {
    let name = "escalate: HALT marker has every coord-tick write-halt-marker field + fallback fields"
    let root = make-temp-root
    hide-env -i SMOLFIRE_IRC_HOST
    let r = run-escalate $root "t-par" "retry-exhausted" "fail" 3
    let halt = try { open --raw ([$root, "var", "mail", "HALT.t-par"] | path join) | from toml } catch { {} }
    cleanup $root
    let want = [task_id verdict message_id halted_at reason attempts halt_msgid resume_tag fallback_fired fallback_status]
    let missing = $want | where {|k| not ($k in ($halt | columns)) }
    if $r.exit_code != 0 or ($missing | length) > 0 {
        return {name: $name, status: "fail", detail: $"exit=($r.exit_code) missing=($missing | str join ',')"}
    }
    let vals_ok = ($halt.halt_msgid == "<halt-t-par.coord@smolfire.local>") and ($halt.resume_tag == "resume-t-par") and ($halt.message_id | str starts-with "<escalate.t-par.") and ($halt.halted_at =~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
    if $vals_ok {
        {name: $name, status: "pass", detail: "all parity fields present with coord-tick-compatible values"}
    } else {
        {name: $name, status: "fail", detail: $"bad values: ($halt | to nuon)"}
    }
}

# ── Test 13: triple failure -> panic JSON on stderr, exit 78 (EX_CONFIG) ───────
#
# Spool path is a directory (append fails), IRC is inert (no route), and the
# per-task HALT path is a directory (marker write fails). Running as root
# defeats permission-based fixtures, so directory-in-the-way is used instead.

def test-triple-failure-exit-78 [] {
    let name = "escalate: triple failure exits 78 with structured panic JSON on stderr"
    let root = make-temp-root
    hide-env -i SMOLFIRE_IRC_HOST
    mkdir ([$root, "var", "mail", "spoolasdir"] | path join)
    mkdir ([$root, "var", "mail", "HALT.t-tf"] | path join)
    let r = (^nu --no-config-file bin/coord-escalate.nu --root $root --spool "var/mail/spoolasdir" --task-id t-tf --reason retry-exhausted --attempts 3) | complete
    cleanup $root
    if $r.exit_code != 78 {
        return {name: $name, status: "fail", detail: $"exit=($r.exit_code) stderr=($r.stderr | str substring ..300)"}
    }
    let line = $r.stderr | lines | where {|l| $l | str contains "smolbsd-coord-panic" } | first
    let j = try { $line | from json } catch { return {name: $name, status: "fail", detail: $"panic line not JSON: ($line)"} }
    let ok = ($j.event == "smolbsd-coord-panic") and ($j.task_id == "t-tf") and ($j.spool_writable == false) and ($j.irc_reachable == false) and ($j.halt_writable == false) and (($j.ts | str length) > 0)
    if $ok {
        {name: $name, status: "pass", detail: "exit 78 + panic JSON with all spec fields"}
    } else {
        {name: $name, status: "fail", detail: $"panic JSON wrong: ($j | to nuon)"}
    }
}

# ── Test 14: partial failure is NOT the panic path ────────────────────────────

def test-partial-failure-not-78 [] {
    let name = "escalate: HALT write failure alone exits 1, not 78, with no panic JSON"
    let root = make-temp-root
    hide-env -i SMOLFIRE_IRC_HOST
    "" | save ([$root, "var", "mail", "spool"] | path join)
    mkdir ([$root, "var", "mail", "HALT.t-pf"] | path join)
    let r = run-escalate $root "t-pf" "retry-exhausted" "fail" 3
    let spool_raw = open --raw ([$root, "var", "mail", "spool"] | path join)
    cleanup $root
    let ok = ($r.exit_code == 1) and (not ($r.stderr | str contains "smolbsd-coord-panic")) and ($spool_raw | str contains "[ESCALATE] t-pf")
    if $ok {
        {name: $name, status: "pass", detail: "exit 1; spool message still appended; no panic JSON"}
    } else {
        {name: $name, status: "fail", detail: $"exit=($r.exit_code) stderr=($r.stderr | str substring ..200)"}
    }
}

# ── Public entry point ─────────────────────────────────────────────────────────

# Run all escalation unit tests. Returns a list of {name, status, detail}.
export def run-coord-escalate-tests [] {
    mut results = []

    $results = $results | append (try { test-halt-marker-created }            catch {|e| {name: "escalate: HALT marker written with required fields",                           status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-halt-mbox-message-headers }      catch {|e| {name: "escalate: HALT mbox message has required headers",                           status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-reason-retry-exhausted }         catch {|e| {name: "escalate: reason=retry-exhausted propagated to HALT marker and spool",       status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-reason-no-unblocker }            catch {|e| {name: "escalate: reason=no-unblocker propagated to HALT marker and spool",          status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-reason-custom-string }           catch {|e| {name: "escalate: arbitrary reason string propagated correctly",                     status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-proposed-actions-toml-array }    catch {|e| {name: "escalate: proposed_actions is a TOML array in spool body",                  status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-irc-fallback-file-written }      catch {|e| {name: "escalate: HALT marker written even when IRC fallback not available",         status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-no-global-halt-written }         catch {|e| {name: "escalate: coord-escalate does NOT write global HALT marker",                 status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-spool-append-preserves-existing } catch {|e| {name: "escalate: escalation appends to spool without destroying existing messages", status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-task-id-guard-present }          catch {|e| {name: "escalate: --task-id guard is present in source",                         status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-reason-guard-present }           catch {|e| {name: "escalate: --reason guard is present in source",                            status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-message-id-contains-task-id }    catch {|e| {name: "escalate: Message-ID in spool encodes task_id",                             status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-stdout-logs-steps }              catch {|e| {name: "escalate: stdout contains structured log steps",                             status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-halt-marker-parity }              catch {|e| {name: "escalate: HALT marker has every coord-tick write-halt-marker field + fallback fields", status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-triple-failure-exit-78 }          catch {|e| {name: "escalate: triple failure exits 78 with structured panic JSON on stderr",    status: "fail", detail: $"exception: ($e.msg)"}})
    $results = $results | append (try { test-partial-failure-not-78 }          catch {|e| {name: "escalate: HALT write failure alone exits 1, not 78, with no panic JSON",     status: "fail", detail: $"exception: ($e.msg)"}})

    $results
}

# ── Standalone runner ──────────────────────────────────────────────────────────
# When invoked directly (`nu tests/coord-escalate-test.nu`) print results and
# exit non-zero if any test fails — matches the contract expected by run-all.sh.

def main [] {
    let results = run-coord-escalate-tests

    let passed  = $results | where status == "pass" | length
    let failed  = $results | where status == "fail" | length
    let skipped = $results | where status == "skip" | length

    $results | each {|r|
        let s = $r.status
        print $"  [($s)] ($r.name): ($r.detail)"
    }

    print $"\n=== coord-escalate tests: ($passed) pass / ($failed) fail / ($skipped) skip ==="

    if $failed > 0 { exit 1 }
}
