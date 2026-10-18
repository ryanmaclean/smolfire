#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# coord-escalate.nu — D3 escalation entry point for the smolfire coordinator
#
# Appends a structured ESCALATE message to the spool and writes a per-task
# HALT marker.  Called by coord-tick when the D2 retry table is exhausted or
# a credential-fingerprint mismatch forces an immediate escalation.
#
# Spec §13 behaviour:
#   - HALT marker carries the same fields as coord-tick.nu's write-halt-marker
#     (task_id, verdict, message_id, halted_at, reason, attempts, halt_msgid,
#     resume_tag) plus fallback_fired / fallback_status from the one-shot IRC
#     fallback (SMOLFIRE_IRC_HOST unset => inert, status "no-route"), and the
#     legacy escalated_at.
#   - Triple-failure path: if the spool write, the IRC fallback AND the HALT
#     marker write all fail, a structured panic JSON is printed to stderr and
#     the process exits 78 (EX_CONFIG).  A single/double failure never exits
#     78: it is reported and exits 1 (the escalation was only partly recorded).
#
# Usage:
#   nu bin/coord-escalate.nu --task-id t42 --reason retry-exhausted --attempts 3
#   nu bin/coord-escalate.nu --task-id t7  --reason credential-fingerprint-mismatch --verdict fail

def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# One TLS attempt on 6697, one plain fallback on 6667, then give up (spec §13).
# Mirrors try-irc-dm in bin/coord-tick.nu (that file is a script, not an
# importable module); the IRC host is never hardcoded — unset => "no-route".
# Returns "tls-ok" | "plain-ok" | "no-route".  Never fatal.
def try-irc-dm [task_id: string, reason: string] {
    let msg = $"HALT ($task_id): ($reason)"
    let irc_host = $env.SMOLFIRE_IRC_HOST? | default ""
    if $irc_host == "" { return "no-route" }
    try {
        let irc_cmds = $"NICK coord-bot\r\nUSER coord-bot 0 * :smolfire coord\r\nPRIVMSG ryan :($msg)\r\nQUIT\r\n"
        $irc_cmds | ^openssl s_client -connect $"($irc_host):6697" -quiet -timeout 10 out+err> /dev/null
        "tls-ok"
    } catch {
        try {
            let irc_cmds = $"NICK coord-bot\r\nUSER coord-bot 0 * :smolfire coord\r\nPRIVMSG ryan :($msg)\r\nQUIT\r\n"
            $irc_cmds | ^nc -w 5 $irc_host 6667 err> /dev/null
            "plain-ok"
        } catch {
            "no-route"
        }
    }
}

def main [
    --task-id:  string              # task being escalated (required)
    --reason:   string              # e.g. retry-exhausted, credential-fingerprint-mismatch, probe-disagreement
    --verdict:  string = ""         # last verdict ("fail", "blocked", etc.)
    --attempts: int    = 0          # number of attempts made
    --spool:    string = "var/mail/spool"
    --root:     string = "."
] {
    if $task_id == null or $task_id == "" {
        error make {msg: "--task-id is required"}
    }
    if $reason == null or $reason == "" {
        error make {msg: "--reason is required"}
    }

    let abs_root  = $root | path expand
    let abs_spool = [$abs_root, $spool] | path join
    let mail_dir  = $abs_spool | path dirname

    try { if not ($mail_dir | path exists) { mkdir $mail_dir } } catch {}

    let ts      = date now | date to-timezone utc | format date "%Y%m%d%H%M%S"
    let ts_iso  = date now | date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"
    let msg_id  = $"<escalate.($task_id).($ts)@smolfire.local>"
    let subject = $"[ESCALATE] ($task_id): ($reason)"
    let ask     = $"Human review required: ($reason) after ($attempts) attempts. Check var/mail/HALT.($task_id) for details."

    let body = [
        $"task_id  = \"($task_id)\""
        $"category = \"escalation\""
        $"reason   = \"($reason)\""
        $"verdict  = \"($verdict)\""
        $"attempts = ($attempts)"
        "proposed_actions = [\"retry\", \"abort\", \"edit\"]"
        $"ask      = \"($ask)\""
    ] | str join "\n"

    let mbox_msg = $"From coordinator@smolfire.local ($ts)
From: coordinator@smolfire.local
To: operator@smolfire.local
Subject: ($subject)
Message-ID: ($msg_id)
X-Halt-Reason: ($reason)
Content-Type: text/toml; charset=utf-8

($body)
"

    # 1. Primary channel: in-spool message.
    let spool_ok = try { $mbox_msg | save --append $abs_spool; true } catch { false }
    if $spool_ok {
        log-step "escalate-spool" "escalation message appended to spool" {
            task_id:    $task_id
            reason:     $reason
            message_id: $msg_id
            spool:      $abs_spool
        }
    } else {
        log-step "escalate-spool-failed" "spool append failed" {task_id: $task_id, spool: $abs_spool}
    }

    # 2. One-shot IRC fallback, outcome recorded in the HALT marker.
    let irc_status = try-irc-dm $task_id $reason
    let irc_ok = $irc_status in ["tls-ok", "plain-ok"]
    log-step "escalate-irc" "IRC fallback attempted" {task_id: $task_id, status: $irc_status}

    # 3. Per-task HALT marker — written unconditionally (one filesystem op),
    # field-for-field the same record coord-tick.nu's write-halt-marker emits
    # plus fallback_fired / fallback_status (spec §13) and legacy escalated_at.
    let halt_path = [$abs_root, "var", "mail", $"HALT.($task_id)"] | path join
    let halt_ok = try {
        let halt_dir = $halt_path | path dirname
        if not ($halt_dir | path exists) { mkdir $halt_dir }
        {
            task_id:         $task_id
            verdict:         $verdict
            message_id:      $msg_id
            halted_at:       $ts_iso
            reason:          $reason
            attempts:        $attempts
            halt_msgid:      $"<halt-($task_id).coord@smolfire.local>"
            resume_tag:      $"resume-($task_id)"
            fallback_fired:  true
            fallback_status: $irc_status
            escalated_at:    $ts_iso
        } | to toml | save --force $halt_path
        true
    } catch { false }
    if $halt_ok {
        log-step "escalate-halt" "HALT marker written" {
            task_id:   $task_id
            halt_path: $halt_path
        }
    } else {
        log-step "escalate-halt-failed" "HALT marker write failed" {task_id: $task_id, halt_path: $halt_path}
    }

    # Triple-failure path (§13): substrate-integrity event, not task-level.
    if (not $spool_ok) and (not $irc_ok) and (not $halt_ok) {
        {
            event:          "smolbsd-coord-panic"
            task_id:        $task_id
            spool_writable: false
            irc_reachable:  false
            halt_writable:  false
            ts:             $ts_iso
        } | to json --raw | print -e
        exit 78
    }

    if (not $spool_ok) or (not $halt_ok) {
        # Partially recorded: surface it to the caller (non-zero) without
        # claiming the panic condition.
        print -e $"coord-escalate: escalation only partly recorded [spool_ok=($spool_ok) halt_ok=($halt_ok) irc_ok=($irc_ok)]"
        exit 1
    }

    log-step "escalate-done" "D3 escalation complete — awaiting operator action" {
        task_id:    $task_id
        reason:     $reason
        message_id: $msg_id
    }
}
