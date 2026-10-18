#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Offline reply-attempt fixture. It seeds state/spool and never starts a jail.
use ../bin/mbox-parse.nu [parse-mbox, extract-toml]

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def envelope [from_addr: string, to_addr: string, id: string, body: string, --in-reply-to: string = ""] {
    let irt = if $in_reply_to == "" { "" } else { $"In-Reply-To: ($in_reply_to)\n" }
    $"From ($from_addr) Wed Jan  1 00:00:00 2026
From: ($from_addr)
To: ($to_addr)
Message-ID: ($id)
($irt)Content-Type: text/toml; charset=utf-8

($body)

"
}
def dispatch [id: string, attempt: int, --to: string = "jail-agent@smolfire.local", --executor: string = "jail"] {
    envelope "coordinator@smolfire.local" $to $id $"task_id = \"t-attempt\"\naction = \"dispatch\"\nexecutor = \"($executor)\"\nattempt = ($attempt)"
}
def reply [id: string, dispatch_id: string, verdict: string, --task: string = "t-attempt"] {
    envelope "jail-agent@smolfire.local" "coordinator@smolfire.local" $id $"task_id = \"($task)\"\nverdict = \"($verdict)\"" --in-reply-to $dispatch_id
}
def waiting-state [dispatch_id: string, attempt: int] {
    let sent = date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    {
        version: "1"
        tick_count: 10
        fsm_state: "waiting"
        seen_ids: ["<D1@smolfire.local>" "<D2@smolfire.local>"]
        last_tick_at: $sent
        pending_request_id: $dispatch_id
        pending_task_id: "t-attempt"
        pending_to_addr: "jail-agent@smolfire.local"
        dispatched_at: $sent
        pending_slots: {jail: [{task_id: "t-attempt", request_id: $dispatch_id, to_addr: "jail-agent@smolfire.local", dispatched_at: $sent}]}
        attempt_counts: {"t-attempt": $attempt}
        halted_tasks: []
        task_executors: {"t-attempt": {executor: "jail", network: false, request_id: "<original@smolfire.local>", current_dispatch_id: $dispatch_id}}
        inflight: {"t-attempt": {executor: "jail", since_tick: 10}}
        workers: {}
    }
}
def resume [id: string] {
    $"From user@smolfire.local Wed Jan  1 00:00:00 2026
From: user@smolfire.local
To: coordinator@smolfire.local
Message-ID: ($id)
X-Resume-Tag: resume-t-attempt
X-Resume-Action: retry
Content-Type: text/toml; charset=utf-8

task_id = \"t-attempt\"
action = \"resume\"

"
}
def run-one [spool: string, state: record, --steps: int = 1, --max-ticks: int = 100, --jail-cap: int = 2, --vm-cap: int = 4, --append-after-first: string = ""] {
    let root = (($env.TMPDIR? | default "/tmp") | path join $"coord-mailbox-(random uuid)")
    require (not ($root | path exists)) "fixture temp path already exists"
    mkdir $root
    let spool_path = [$root "var" "mail" "spool"] | path join
    let state_path = [$root "var" "run" "coord-state.toml"] | path join
    let halt_path = [$root "var" "mail" "HALT.t-attempt"] | path join
    mkdir ($spool_path | path dirname)
    mkdir ($state_path | path dirname)
    $spool | save --raw $spool_path
    $state | to toml | save --raw $state_path
    mut result = {exit_code: -1, stdout: "", stderr: ""}
    for step in 1..$steps {
        $result = do {
            hide-env -i SMOLFIRE_IRC_HOST
            with-env {SMOLFIRE_MAX_INFLIGHT_JAIL: ($jail_cap | into string), SMOLFIRE_MAX_INFLIGHT_VM: ($vm_cap | into string), SMOLFIRE_SPAWN_SUBAGENT: "0"} {
                ^$nu.current-exe --no-config-file bin/coord-tick.nu --state-file "var/run/coord-state.toml" --spool "var/mail/spool" --max-ticks $max_ticks --root $root | complete
            }
        }
        if $result.exit_code != 0 { break }
        if $step == 1 and $append_after_first != "" {
            let intermediate = open --raw $state_path | from toml
            require ("t-attempt" in $intermediate.halted_tasks) "first tick did not create an actual HALT before resume"
            require ($halt_path | path exists) "first tick did not create the per-task HALT marker"
            $append_after_first | save --append $spool_path
        }
    }
    let after = open --raw $state_path | from toml
    let final_spool = open --raw $spool_path
    let halt_marker = if ($halt_path | path exists) { open --raw $halt_path } else { "" }
    require (($halt_path | path dirname) == ($spool_path | path dirname)) "HALT cleanup escaped fixture mail directory"
    if ($halt_path | path exists) { rm $halt_path }
    rm $spool_path
    rm $state_path
    rm ($spool_path | path dirname)
    rm ($state_path | path dirname)
    rm ($root | path join "var")
    rm $root
    {run: $result, state: $after, spool: $final_spool, halt_marker: $halt_marker}
}

export def run-mailbox-attempt-tests [] {
    let d1 = "<D1@smolfire.local>"
    let d2 = "<D2@smolfire.local>"
    let issued = (dispatch $d1 1) + (dispatch $d2 3)
    for order in [[1 2] [2 1]] {
        let late = reply "<late-D1@smolfire.local>" $d1 "pass"
        let current = reply "<current-D2@smolfire.local>" $d2 "fail"
        let tail = if $order == [1 2] { $late + $current } else { $current + $late }
        let result = run-one ($issued + $tail) (waiting-state $d2 3)
        require ($result.run.exit_code == 0) $"attempt fixture tick failed: ($result.run.stderr)"
        require ("t-attempt" in $result.state.halted_tasks) "late pass cleared active attempt instead of current fail HALT"
        require (($result.state.attempt_counts | get -o "t-attempt" | default 0) == 3) "late reply altered retry count"
        require ("<late-D1@smolfire.local>" in $result.state.seen_ids) "late reply was not recorded as stale"
        require ($result.run.stdout | str contains "harvest_stale_reply") "stale reply diagnostic missing"
        require ($result.run.stdout | str contains "retry-exhausted") "current D2 fail did not drive decision"
        require ((parse-mbox $result.spool | where {|m| ((extract-toml $m) | get -o action | default "") == "dispatch"} | length) == 2) "unexpected retry dispatch"
    }

    for bad in [
        (reply "<missing-irt@smolfire.local>" "" "pass")
        (reply "<unknown-irt@smolfire.local>" "<unknown@smolfire.local>" "pass")
        (reply "<wrong-task@smolfire.local>" $d2 "pass" --task "other-task")
    ] {
        let result = run-one ($issued + $bad) (waiting-state $d2 2)
        require ($result.run.exit_code == 0) "invalid reply tick failed"
        require ($result.state.fsm_state == "waiting") "invalid reply consumed active slot"
        require (($result.state.pending_slots.jail | first).request_id == $d2) "invalid reply cleared D2"
        require (($result.state.attempt_counts | get "t-attempt") == 2) "invalid reply altered attempt count"
    }

    let duplicate_id = "<collision@smolfire.local>"
    let colliding = (reply $duplicate_id $d1 "pass") + (reply $duplicate_id $d2 "pass")
    let duplicate_result = run-one ($issued + $colliding) (waiting-state $d2 2)
    require ($duplicate_result.run.exit_code == 0) "duplicate-ID tick failed"
    require ($duplicate_result.state.fsm_state == "waiting") "duplicate-ID reply consumed active slot"
    require (($duplicate_result.state.pending_slots.jail | first).request_id == $d2) "duplicate-ID reply cleared D2"

    let halted = (waiting-state $d2 3) | upsert fsm_state "idle" | upsert halted_tasks ["t-attempt"] | upsert pending_slots {} | upsert inflight {}
    let after_halt = run-one ($issued + (reply "<after-halt@smolfire.local>" $d2 "pass")) $halted
    require ($after_halt.run.exit_code == 0) "post-HALT tick failed"
    require ("t-attempt" in $after_halt.state.halted_tasks) "post-HALT reply resumed task"
    require ($after_halt.run.stdout | str contains "harvest_stale_reply") "post-HALT reply not rejected"

    # A timeout must release its own pending/inflight capacity before retry.
    # The jail-cap case stops at the stamped dispatching state, before any
    # jail adapter could be launched by the next transition.
    let overdue = "2020-01-01T00:00:00Z"
    let timed_base = waiting-state $d1 1
    let old_slot = ($timed_base.pending_slots.jail | first) | upsert dispatched_at $overdue
    let timed = $timed_base | upsert pending_slots {jail: [$old_slot]} | upsert dispatched_at $overdue
    let capped = run-one (dispatch $d1 1) $timed --steps 2 --max-ticks 2 --jail-cap 1
    require ($capped.run.exit_code == 0) "cap-one timeout retry tick failed"
    require ($capped.state.fsm_state == "dispatching") "timeout retry was not stamped at jail cap one"
    require ((($capped.state.pending_slots.jail | first).request_id | str starts-with "<timeout.")) "timeout reply did not own the new slot"
    require (not ("t-attempt" in ($capped.state.inflight | columns))) "completed attempt still consumed jail cap"
    require (($capped.state.pending_slots.jail | first).to_addr == "jail-agent@smolfire.local") "timeout retry targeted coordinator"

    # VM uses the same cap transition with default-disabled subagent spawn,
    # so this branch can inspect the newly issued D2 without launching work.
    let vm_slot = $old_slot | upsert to_addr "vm-agent@smolfire.local"
    let vm_state = ($timed
        | upsert pending_slots {vm: [$vm_slot]}
        | upsert pending_to_addr "vm-agent@smolfire.local"
        | upsert task_executors {"t-attempt": {executor: "vm", network: false, request_id: "<original@smolfire.local>", current_dispatch_id: $d1}}
        | upsert inflight {"t-attempt": {executor: "vm", since_tick: 10}})
    let vm_seed = dispatch $d1 1 --to "vm-agent@smolfire.local" --executor "vm"
    let vm_retry = run-one $vm_seed $vm_state --steps 3 --max-ticks 2 --vm-cap 1
    require ($vm_retry.run.exit_code == 0) "VM cap-one timeout retry tick failed"
    let vm_dispatches = parse-mbox $vm_retry.spool | where {|m| ((extract-toml $m) | get -o action | default "") == "dispatch"}
    require (($vm_dispatches | length) == 2) "timeout retry did not issue exactly one D2 dispatch"
    require ((($vm_dispatches | last).headers | get "To") == "vm-agent@smolfire.local") "synthetic retry was sent to coordinator"
    require (($vm_retry.state.attempt_counts | get "t-attempt") == 2) "timeout retry attempt count did not advance"

    # A resume revokes even a pre-upgrade HALT state whose old D2 identity
    # was accidentally retained. The late D2 pass must not settle the task.
    let resumed = run-one ($issued + (resume "<resume@smolfire.local>") + (reply "<late-after-resume@smolfire.local>" $d2 "pass")) $halted
    require ($resumed.run.exit_code == 0) "resume/late-reply tick failed"
    require (not ("t-attempt" in $resumed.state.halted_tasks)) "resume action was not applied"
    require (($resumed.state.task_executors | get "t-attempt" | get current_dispatch_id) == "") "resume retained the pre-HALT dispatch"
    require (($resumed.state.attempt_counts | get "t-attempt") == 3) "late pre-HALT pass settled resumed task"
    require ($resumed.run.stdout | str contains "harvest_stale_reply") "late pre-HALT pass was not rejected after resume"

    let actual_halt = run-one ($issued + (reply "<fail-D2@smolfire.local>" $d2 "fail")) (waiting-state $d2 3) --steps 2 --append-after-first ((resume "<live-resume@smolfire.local>") + (reply "<late-live-D2@smolfire.local>" $d2 "pass"))
    require ($actual_halt.run.exit_code == 0) "actual HALT/resume tick failed"
    require (not ("t-attempt" in $actual_halt.state.halted_tasks)) "actual HALT did not resume"
    require (($actual_halt.state.task_executors | get "t-attempt" | get current_dispatch_id) == "") "actual HALT/resume retained D2"
    require (($actual_halt.state.attempt_counts | get "t-attempt") == 3) "late D2 pass settled actual resumed HALT"
    require ($actual_halt.run.stdout | str contains "harvest_stale_reply") "actual HALT/resume late pass was not rejected"

    # Legacy/corrupt state with a dead worker and no issued dispatch must
    # release its capacity into an operator-visible per-task HALT once.
    let orphan = ((waiting-state $d1 1)
        | upsert fsm_state "idle"
        | upsert pending_slots {}
        | upsert task_executors {"t-attempt": {executor: "jail", network: false, request_id: "<original@smolfire.local>", current_dispatch_id: ""}}
        | upsert workers {jail: {last_seen_tick: 0, consecutive_failures: 0, dead: true}})
    let quarantined = run-one $issued $orphan
    require ($quarantined.run.exit_code == 0) "uncorrelated dead-worker tick failed"
    require ("t-attempt" in $quarantined.state.halted_tasks) "uncorrelated task was not quarantined"
    require (not ("t-attempt" in ($quarantined.state.inflight | columns))) "uncorrelated task retained inflight capacity"
    require ($quarantined.halt_marker | str contains "worker-reap-uncorrelated") "uncorrelated task lacked an operator HALT marker"
    require ($quarantined.run.stdout | str contains "worker_reap_uncorrelated") "uncorrelated quarantine was not logged"
    print "coord-mailbox-attempt-test: source fixture complete"
}
