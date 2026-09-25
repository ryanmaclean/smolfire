#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/durable-tid-model.nu — bounded explicit-state model check for issue #89:
# "Can we delete TID allocation from hardware?"
#
# Compares two semantic models of the durable-TID completion gate under the
# fault model in docs/FORMAL-DURABLE-TID-PLAN.md (crash/reset after every
# boundary, lost and delayed acknowledgements, duplicate submission):
#
#   A  hardware allocates   submit(request)      -> hardware allocates tid
#      A0 = allocator only; A1 = allocator + request-identity dedup index
#   B  caller supplies      submit(seq, request) -> hardware only enforces
#                                                   durable ordered visibility
#
# Every reachable state (within the bounds) is explored breadth-first and
# checked against the RFC 0005 / scaffolds/durable-tid/docs/FORMAL.md safety
# invariants, so a violation comes with a shortest counterexample trace.
# This is the "model before RTL" step. It is a bounded check, not a proof,
# and it does not check liveness. The TLA+ spec is the next step on the ladder.
#
# Output schema: smolfire.durable-tid-model/v1 (--format json).

const SCHEMA = "smolfire.durable-tid-model/v1"

# ── state ────────────────────────────────────────────────────────────────────
# Field order is fixed because states are deduplicated by their JSON encoding.
#   epoch        reset counter
#   alloc        A: last allocated TID; B: last accepted caller sequence
#   durable_seq  trusted register: last TID proven persistent
#   visible_seq  trusted register: last TID published as complete
#   log          durable media: committed records {tid, req}; survives reset
#   inflight     the single outstanding operation {tid, req, stage} or null
#   net          completions published but not yet seen by the caller
#   cur          honest caller: index of its current logical operation
#   done         completions the caller has received
#   crashes/lost fault budget used
def initial-state []: nothing -> record {
    {
        epoch: 0
        alloc: 0
        durable_seq: 0
        visible_seq: 0
        log: []
        inflight: null
        net: []
        cur: 0
        done: []
        crashes: 0
        lost: 0
    }
}

def concat-all []: list<list<any>> -> list<any> {
    reduce -f [] {|it, acc| $acc ++ $it }
}

# Set semantics for completion lists: unique, ordered, so equal sets encode equally.
def norm-set [xs: list<any>]: nothing -> list<any> {
    if ($xs | is-empty) { [] } else { $xs | uniq | sort-by tid req }
}

# ── transitions ──────────────────────────────────────────────────────────────
def allocate [s: record, cfg: record, req: string]: nothing -> list<record> {
    if $s.alloc >= $cfg.tid_bound { return [] }
    let tid = $s.alloc + 1
    [{
        action: $"submit ($req) -> allocate tid=($tid)"
        next: ($s | upsert alloc $tid | upsert inflight {tid: $tid, req: $req, stage: "allocated"})
    }]
}

def re-ack [s: record, tid: int, req: string, why: string]: nothing -> list<record> {
    [{
        action: $"submit ($req) -> ($why) re-ack tid=($tid)"
        next: ($s | upsert net (norm-set ($s.net | append {tid: $tid, req: $req})))
    }]
}

# What the hardware does with one submission. Rejections change no state and
# therefore produce no successor.
def hw-submit [s: record, cfg: record, req: string, seq: int]: nothing -> list<record> {
    match $cfg.model {
        "A0" => { allocate $s $cfg $req }
        "A1" => {
            let hit = ($s.log | where {|r| $r.req == $req })
            if ($hit | is-not-empty) {
                re-ack $s ($hit | first | get tid) $req "dedup-index"
            } else {
                allocate $s $cfg $req
            }
        }
        "B" => {
            if $seq <= $s.durable_seq {
                # Already committed: idempotent re-ack only if it is the same
                # operation; a different payload under a used seq is rejected.
                let rec = ($s.log | where {|r| $r.tid == $seq })
                if ($rec | is-empty) {
                    []
                } else if ($rec | first | get req) == $req {
                    re-ack $s $seq $req "seq<=durable"
                } else {
                    []
                }
            } else if $seq == ($s.durable_seq + 1) {
                [{
                    action: $"submit seq=($seq) ($req) -> accepted"
                    next: ($s | upsert alloc $seq | upsert inflight {tid: $seq, req: $req, stage: "allocated"})
                }]
            } else {
                []
            }
        }
        _ => { error make {msg: $"unknown model ($cfg.model)"} }
    }
}

# Caller submissions. Honest: resubmit the current operation (a retry after a
# timeout, i.e. a delayed or lost acknowledgement) until its completion
# arrives. Adversarial: any payload under any sequence number.
def submit-steps [s: record, cfg: record]: nothing -> list<record> {
    if $s.inflight != null { return [] }  # single outstanding: busy -> reject
    let cands = if $cfg.caller == "honest" {
        if $s.cur >= $cfg.n { [] } else { [{req: ($cfg.reqs | get $s.cur), seq: ($s.cur + 1)}] }
    } else {
        $cfg.reqs | each {|r| 1..($cfg.n + 1) | each {|q| {req: $r, seq: $q} } } | concat-all
    }
    let cands = if ($cfg.model | str starts-with "A") and ($cands | is-not-empty) {
        $cands | uniq-by req  # A ignores caller sequence numbers
    } else {
        $cands
    }
    $cands | each {|c| hw-submit $s $cfg $c.req $c.seq } | concat-all
}

# The completion pipeline; each step is a fault boundary (reset may follow any).
def pipeline-steps [s: record]: nothing -> list<record> {
    let f = $s.inflight
    if $f == null { return [] }
    match $f.stage {
        "allocated" => [{
            action: $"write tid=($f.tid)"
            next: ($s | upsert inflight ($f | upsert stage "written"))
        }]
        "written" => [{
            action: $"flush tid=($f.tid)"
            next: ($s | upsert log ($s.log | append {tid: $f.tid, req: $f.req}) | upsert inflight ($f | upsert stage "flushed"))
        }]
        "flushed" => [{
            action: $"durable-ack tid=($f.tid)"
            next: ($s | upsert durable_seq $f.tid | upsert inflight ($f | upsert stage "acked"))
        }]
        "acked" => [{
            action: $"publish tid=($f.tid)"
            next: ($s | upsert visible_seq $f.tid | upsert net (norm-set ($s.net | append {tid: $f.tid, req: $f.req})) | upsert inflight null)
        }]
        _ => []
    }
}

# Deliver or lose each in-flight completion.
def net-steps [s: record, cfg: record]: nothing -> list<record> {
    $s.net | each {|ack|
        let rest = ($s.net | where {|x| $x != $ack })
        let advance = ($cfg.caller == "honest") and ($s.cur < $cfg.n) and ($ack.req == ($cfg.reqs | get ([$s.cur ($cfg.n - 1)] | math min)))
        let deliver = [{
            action: $"deliver tid=($ack.tid) ($ack.req)"
            next: ($s | upsert net $rest | upsert done (norm-set ($s.done | append $ack)) | upsert cur (if $advance { $s.cur + 1 } else { $s.cur }))
        }]
        let lose = if $s.lost < $cfg.max_lost {
            [{
                action: $"lose-ack tid=($ack.tid) ($ack.req)"
                next: ($s | upsert net $rest | upsert lost ($s.lost + 1))
            }]
        } else { [] }
        $deliver ++ $lose
    } | concat-all
}

# Reset: volatile state (the in-flight operation, the allocator register) is
# lost; recovery rebuilds the trusted registers from durable media only.
# Completions already in flight to the caller are not recalled.
def crash-steps [s: record, cfg: record]: nothing -> list<record> {
    if $s.crashes >= $cfg.max_crashes { return [] }
    let recovered = ($s.log | length)
    [{
        action: "reset+recover"
        next: ($s
            | upsert epoch ($s.epoch + 1)
            | upsert alloc $recovered
            | upsert durable_seq $recovered
            | upsert visible_seq $recovered
            | upsert inflight null
            | upsert crashes ($s.crashes + 1))
    }]
}

def successors [s: record, cfg: record]: nothing -> list<record> {
    (submit-steps $s $cfg) ++ (pipeline-steps $s) ++ (net-steps $s $cfg) ++ (crash-steps $s $cfg)
}

# ── invariants ───────────────────────────────────────────────────────────────
# State invariants (RFC 0005 / durable-tid FORMAL.md names where they exist).
def check-state [s: record, cfg: record]: nothing -> list<string> {
    let tids = ($s.log | each {|r| $r.tid })
    let reqs = ($s.log | each {|r| $r.req })
    let n = ($tids | length)
    let completions = ($s.net ++ $s.done)
    # Operation identity: A carries a request id; B's identity is the caller
    # sequence number. An honest B caller maps one payload to one seq, so the
    # payload must also commit at most once there.
    let identity_dupes = if ($cfg.model == "B") and ($cfg.caller == "adversarial") {
        ($tids | uniq | length) != $n
    } else {
        ($reqs | uniq | length) != $n
    }
    [
        (if ($tids | uniq | length) != $n { "NoDuplicateCommittedTid" })
        (if ($tids | enumerate | any {|e| $e.item != ($e.index + 1) }) { "GapFreeOrderedLog" })
        (if $identity_dupes { "DuplicateRequestCommitsAtMostOnce" })
        (if ($completions | any {|c| ($s.log | where {|r| $r.tid == $c.tid and $r.req == $c.req } | is-empty) }) { "CompletionImpliesDurable" })
        (if $s.visible_seq > $s.durable_seq { "UncommittedNeverVisible" })
        (if $s.durable_seq > $n { "RecoveryDoesNotCreateCommit" })
        (if $s.durable_seq > $s.alloc { "CommittedNeverExceedsAllocated" })
    ] | compact
}

# Transition invariants.
def check-transition [s: record, t: record]: nothing -> list<string> {
    let old_n = ($s.log | length)
    let mutated = if $old_n == 0 {
        false
    } else if ($t.log | length) < $old_n {
        true
    } else {
        ($t.log | first $old_n) != $s.log
    }
    [
        (if $t.durable_seq < $s.durable_seq { "MonotonicCommittedTid" })
        (if $t.visible_seq < $s.visible_seq { "MonotonicVisibleTid" })
        (if $mutated { "CommittedRecordNeverMutates" })
    ] | compact
}

# ── exploration ──────────────────────────────────────────────────────────────
def explore [cfg: record]: nothing -> record {
    let init = (initial-state)
    mut seen = [($init | to json -r)]
    mut frontier = [{state: $init, trace: []}]
    mut violations = (check-state $init $cfg | each {|i| {invariant: $i, trace: []} })
    mut transitions = 0
    mut depth = 0
    while ($frontier | is-not-empty) {
        let current = $frontier
        let expanded = ($current | each {|item|
            successors $item.state $cfg | each {|t|
                {
                    key: ($t.next | to json -r)
                    state: $t.next
                    trace: ($item.trace | append $t.action)
                    bad: ((check-transition $item.state $t.next) ++ (check-state $t.next $cfg))
                }
            }
        } | concat-all)
        $transitions += ($expanded | length)
        let found = ($expanded
            | where {|r| $r.bad | is-not-empty }
            | each {|r| $r.bad | each {|i| {invariant: $i, trace: $r.trace} } }
            | concat-all)
        $violations = ($violations ++ $found)
        let seen_now = $seen
        let fresh = ($expanded | where {|r| ($r.bad | is-empty) and not ($r.key in $seen_now) })
        let fresh = if ($fresh | is-empty) { [] } else { $fresh | uniq-by key }
        $seen = ($seen ++ ($fresh | each {|r| $r.key }))
        $frontier = ($fresh | each {|r| {state: $r.state, trace: $r.trace} })
        if ($fresh | is-not-empty) { $depth += 1 }
    }
    # BFS order: the first trace kept per invariant is a shortest counterexample.
    let violations = if ($violations | is-empty) { [] } else { $violations | uniq-by invariant }
    {
        model: $cfg.model
        caller: $cfg.caller
        states: ($seen | length)
        transitions: $transitions
        depth: $depth
        violations: $violations
    }
}

# ── trusted state inventory (design data, not synthesis results) ────────────
def trusted-state [model: string]: nothing -> record {
    let base = [
        {register: "epoch", bits: 32, why: "reset generation; tags completions"}
        {register: "durable_seq", bits: 64, why: "last TID proven persistent"}
        {register: "visible_seq", bits: 64, why: "last TID published complete; never passes durable_seq"}
        {register: "fsm_state", bits: 3, why: "idle/allocated/written/flushed/acked"}
    ]
    let extra = match $model {
        "A0" => [
            {register: "next_tid", bits: 64, why: "hardware TID allocator"}
        ]
        "A1" => [
            {register: "next_tid", bits: 64, why: "hardware TID allocator"}
            {register: "dedup_index[W]", bits: 0, bits_per_entry: 192, why: "request_id(128) -> tid(64) for every request that may still be retried (W = retry window); must survive reset, so it is a media-backed index or CAM, not a register"}
        ]
        "B" => []
        _ => []
    }
    let regs = ($base ++ $extra)
    {
        registers: $regs
        fixed_bits: ($regs | each {|r| $r.bits } | math sum)
        per_retry_window_entry_bits: ($regs | each {|r| $r.bits_per_entry? | default 0 } | math sum)
        allocator: ($model != "B")
        request_identity_in_hardware: ($model == "A1")
    }
}

def main [
    --requests: int = 2      # distinct logical operations per run
    --max-crashes: int = 1   # reset budget per trace
    --max-lost: int = 1      # lost-acknowledgement budget per trace
    --format: string = "table"  # table | json
] {
    if $requests < 1 { error make {msg: "--requests must be >= 1"} }
    if $max_crashes < 0 or $max_lost < 0 { error make {msg: "fault budgets must be >= 0"} }
    let reqs = (1..$requests | each {|i| $"r($i)" })
    let runs = [
        [model caller];
        [A0 honest]
        [A0 adversarial]
        [A1 honest]
        [A1 adversarial]
        [B honest]
        [B adversarial]
    ] | each {|r|
        explore {
            model: $r.model
            caller: $r.caller
            n: $requests
            reqs: $reqs
            max_crashes: $max_crashes
            max_lost: $max_lost
            tid_bound: ($requests + $max_crashes + $max_lost + 1)
        }
    }

    let clean = {|m| $runs | where model == $m | all {|r| $r.violations | is-empty } }
    let b_safe = (do $clean "B")
    let a1_safe = (do $clean "A1")
    let a0_dupes = ($runs | where model == "A0" | any {|r| $r.violations | any {|v| $v.invariant == "DuplicateRequestCommitsAtMostOnce" } })
    let ts = {A0: (trusted-state "A0"), A1: (trusted-state "A1"), B: (trusted-state "B")}
    let b_smaller = ($ts.B.fixed_bits < $ts.A1.fixed_bits) and ($ts.B.per_retry_window_entry_bits < $ts.A1.per_retry_window_entry_bits)
    let states = {|m| $runs | where model == $m | each {|r| $r.states } | math sum }

    let decision = if $b_safe and $b_smaller {
        "remove-allocator-from-v0"
    } else if not $b_safe {
        "keep-allocator"
    } else {
        "inconclusive"
    }

    let doc = {
        schema: $SCHEMA
        issue: 89
        question: "Can we delete TID allocation from hardware?"
        kill_criterion: "If caller-supplied sequence preserves the required trust/invariants with materially less hardware complexity, remove the allocator from v0."
        method: "bounded breadth-first explicit-state exploration; every reachable state and transition checked; shortest counterexample per violated invariant"
        bounds: {
            requests: $requests
            max_crashes: $max_crashes
            max_lost_acks: $max_lost
            outstanding: 1
            tid_bound: ($requests + $max_crashes + $max_lost + 1)
        }
        faults_modeled: [
            "reset after every boundary (allocate/write/flush/durable-ack/publish)"
            "lost acknowledgement"
            "delayed acknowledgement (caller retries before the completion arrives)"
            "duplicate submission"
            "adversarial caller: any payload under any sequence number"
        ]
        not_modeled: [
            "liveness (no fairness assumptions are checked)"
            "more than one outstanding operation"
            "stale-epoch descriptors that reach hardware after reset"
            "malformed descriptors, torn or corrupted durable records"
            "RTL timing, resource use, or synthesis"
        ]
        invariants: {
            state: [NoDuplicateCommittedTid GapFreeOrderedLog DuplicateRequestCommitsAtMostOnce CompletionImpliesDurable UncommittedNeverVisible RecoveryDoesNotCreateCommit CommittedNeverExceedsAllocated]
            transition: [MonotonicCommittedTid MonotonicVisibleTid CommittedRecordNeverMutates]
        }
        runs: $runs
        trusted_state: $ts
        state_space: {A0: (do $states "A0"), A1: (do $states "A1"), B: (do $states "B")}
        findings: {
            a0_allocator_alone_duplicates_commits: $a0_dupes
            a1_allocator_plus_dedup_safe: $a1_safe
            b_caller_sequence_safe: $b_safe
            b_needs_less_trusted_state: $b_smaller
        }
        decision: $decision
        host_obligations_under_b: [
            "one sequence source per stream (ordering has one source)"
            "a retry reuses the operation's sequence number (retries reuse logical operation identity)"
            "persist the next sequence number with the caller's own durable state (e.g. the BOP run record)"
        ]
    }

    if $format == "json" {
        $doc | to json --indent 2
    } else if $format == "table" {
        print $"schema: ($doc.schema)"
        print $"decision: ($doc.decision)"
        print $"bounds: ($doc.bounds | to nuon)"
        print ""
        print ($runs | each {|r| {
            model: $r.model
            caller: $r.caller
            states: $r.states
            transitions: $r.transitions
            depth: $r.depth
            violations: ($r.violations | each {|v| $v.invariant } | str join ", ")
        } })
        for r in ($runs | where {|r| $r.violations | is-not-empty }) {
            for v in $r.violations {
                print $"($r.model)/($r.caller) ($v.invariant): ($v.trace | str join ' ; ')"
            }
        }
    } else {
        error make {msg: "--format must be table or json"}
    }
}
