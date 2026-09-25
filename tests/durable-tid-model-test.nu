#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/durable-tid-model-test.nu — pins the issue #89 result produced by
# bin/durable-tid-model.nu: the caller-supplied-sequence model (B) keeps every
# safety invariant under the modeled faults, the allocator alone (A0) commits
# duplicates, and B needs less trusted state than a safe allocator (A1).

def fail [msg: string] { print $"durable-tid-model-test: FAIL — ($msg)"; exit 1 }

let res = (^$nu.current-exe bin/durable-tid-model.nu --format json | complete)
if $res.exit_code != 0 { fail $"model exited ($res.exit_code): ($res.stderr)" }

let doc = ($res.stdout | from json)
if $doc.schema != "smolfire.durable-tid-model/v1" { fail $"schema ($doc.schema)" }
if ($doc.runs | length) != 6 { fail $"expected 6 runs, got ($doc.runs | length)" }

for r in $doc.runs {
    if $r.states < 2 { fail $"($r.model)/($r.caller) explored only ($r.states) states" }
    if $r.depth < 4 { fail $"($r.model)/($r.caller) depth ($r.depth) too shallow to reach publish" }
}

let b_runs = ($doc.runs | where model == "B")
for r in $b_runs {
    if ($r.violations | is-not-empty) {
        fail $"B/($r.caller) violated ($r.violations | each {|v| $v.invariant } | str join ', ')"
    }
}
for r in ($doc.runs | where model == "A1") {
    if ($r.violations | is-not-empty) {
        fail $"A1/($r.caller) violated ($r.violations | each {|v| $v.invariant } | str join ', ')"
    }
}

let a0 = ($doc.runs | where model == "A0" and caller == "honest" | first)
let dup = ($a0.violations | where invariant == "DuplicateRequestCommitsAtMostOnce")
if ($dup | is-empty) { fail "A0/honest should commit a retried request twice" }
let trace = ($dup | first | get trace)
if ($trace | length) < 5 { fail $"A0 counterexample too short: ($trace | str join ' ; ')" }
if ($trace | where {|a| $a | str starts-with "submit r1" } | length) < 2 { fail "A0 counterexample should resubmit r1" }

let ts = $doc.trusted_state
if $ts.B.allocator { fail "B must not have an allocator" }
if not ($ts.B.fixed_bits < $ts.A1.fixed_bits) { fail $"B fixed bits ($ts.B.fixed_bits) !< A1 ($ts.A1.fixed_bits)" }
if $ts.B.per_retry_window_entry_bits != 0 { fail "B should need no per-retry-window state" }

if not $doc.findings.b_caller_sequence_safe { fail "finding b_caller_sequence_safe" }
if not $doc.findings.a0_allocator_alone_duplicates_commits { fail "finding a0_allocator_alone_duplicates_commits" }
if $doc.decision != "remove-allocator-from-v0" { fail $"decision ($doc.decision)" }

print "durable-tid-model-test: ok"
