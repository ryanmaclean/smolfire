#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/lineage-sequencer-test.nu — verifies the deterministic break-even model
# used by bin/lineage-sequencer-sim.nu for issue #73.

def fail [msg: string] { print $"lineage-sequencer-test: FAIL — ($msg)"; exit 1 }

let res = (^$nu.current-exe bin/lineage-sequencer-sim.nu --format json | complete)
if $res.exit_code != 0 { fail $"simulator exited ($res.exit_code): ($res.stderr)" }

let doc = ($res.stdout | from json)
if $doc.schema != "smolfire.lineage-sequencer-sim/v1" { fail $"schema ($doc.schema)" }
if $doc.model != "software-ring-to-hardware-sequencer" { fail $"model ($doc.model)" }
if $doc.decision != "prototype-lock-free-ring-first" { fail $"decision ($doc.decision)" }
if $doc.break_even_batch != 8 { fail $"break-even batch ($doc.break_even_batch)" }
if $doc.break_even_bytes != 30720 { fail $"break-even bytes ($doc.break_even_bytes)" }
if (($doc.common_software_responsibilities | length) < 4) { fail "expected software responsibilities list" }

let rows = $doc.rows | reduce -f {} {|r, acc| $acc | insert ($r.batch | into string) $r }
if ($rows | get "4" | get winner) != "cpu" { fail "batch 4 should still favor CPU-only path" }
if ($rows | get "8" | get winner) != "sequencer" { fail "batch 8 should be first sequencer win" }
if ($rows | get "16" | get delta_ns) >= 0 { fail "batch 16 should remain on sequencer side of break-even" }

print "lineage-sequencer-test: ok"
