#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/tslog-phases-test.nu — bin/tslog-phases.nu against a synthetic
# SMOLFIRE-TSLOG capture (tests/fixtures/tslog/, tsc_freq = 1 GHz so
# 1 ms = 1e6 cycles). Run from the repo root.

def fail [msg: string] { print $"tslog-phases-test: FAIL — ($msg)"; exit 1 }

let doc = (nu bin/tslog-phases.nu --dir tests/fixtures/tslog | from json)
if $doc.schema != "smolfire.tslog-phases/v1" { fail $"schema ($doc.schema)" }
let p = $doc.phases | reduce -f {} {|r, acc| $acc | insert $r.phase $r.median }
let want = {vmm_to_vcpu: 100.0, vcpu_to_kernel: 100.0, early_kernel: 70.0,
            sysinit_devices: 160.0, root_mount: 40.0, start_init_other: 30.0,
            init_rc_to_ready: 100.0, wall_to_ready: 600.0}
for k in ($want | columns) {
    if ($p | get $k) != ($want | get $k) { fail $"($k): got ($p | get $k), want ($want | get $k)" }
}
# The pre-kernel split + kernel phases must add up to the wall clock.
let parts = [vmm_to_vcpu vcpu_to_kernel early_kernel sysinit_devices root_mount start_init_other init_rc_to_ready]
let sum = $parts | each {|k| $p | get $k } | math sum
if $sum != 600.0 { fail $"phases sum to ($sum), not wall 600" }
if $doc.release_wall_to_ready_ms.median != 550.0 { fail "release wall median" }
let run = $doc.runs | first
if $run.rejected_lines != 1 { fail $"interleaved console line should be rejected once, got ($run.rejected_lines)" }
if ($run.top_sysinit | first | get name) != "configure1" { fail "top SYSINIT should be configure1" }
if not ($run.top_self | any {|f| $f.name == "device_attach vtnet0" and $f.self_ms == 40.0 }) { fail "device_attach vtnet0 self 40ms" }

# Overflow symptom: no EXIT start_init → loud error, not a silent table.
let tmp = (^mktemp -d | str trim)
open --raw tests/fixtures/tslog/tslog-run1.log | lines | where {|l| not ($l | str contains "EXIT start_init") } | str join "\n" | save $"($tmp)/tslog-run1.log"
let r = (do { nu bin/tslog-phases.nu --dir $tmp } | complete)
if $r.exit_code == 0 { fail "missing EXIT start_init must fail" }
if not ($r.stderr | str contains "TSLOGSIZE") { fail "overflow error should name TSLOGSIZE" }
^rm -rf $tmp
print "tslog-phases-test: ok"
