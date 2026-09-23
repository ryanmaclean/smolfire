#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/smolfire-metrics-test.nu — unit tests for bin/smolfire-metrics.nu

def fail [msg: string] {
    print $"smolfire-metrics-test: FAIL — ($msg)"
    exit 1
}

let report = (^$nu.current-exe bin/smolfire-metrics.nu tests/fixtures/smolfire-metrics-build.log tests/fixtures/smolfire-metrics-gate.log | complete)
if $report.exit_code != 0 { fail $"parser exited ($report.exit_code): ($report.stderr)" }
for needle in [
    "embedded MFS image: 17301504 bytes"
    "/rescue/rescue: 15728640 bytes"
    "kernel ELF: 38797312 bytes"
    "post-READY guest used: 20971520 bytes"
    "post-READY host RSS: 43008 KiB"
    ".text"
    ".rodata"
] {
    if not ($report.stdout | str contains $needle) { fail $"missing output: ($needle)" }
}
if not ($report.stdout =~ '(?s)\.text.*\.rodata') {
    fail "ELF sections not sorted largest-first"
}

let top1 = (^$nu.current-exe bin/smolfire-metrics.nu tests/fixtures/smolfire-metrics-build.log tests/fixtures/smolfire-metrics-gate.log --top 1 | complete)
if $top1.exit_code != 0 { fail $"--top 1 exited ($top1.exit_code): ($top1.stderr)" }
if ($top1.stdout | str contains ".rodata") { fail "--top 1 did not limit ELF section rows" }

let absent = (^$nu.current-exe bin/smolfire-metrics.nu /nonexistent-build.log /nonexistent-gate.log | complete)
if $absent.exit_code != 0 { fail "absent logs should exit 0 with SKIP" }
if not ($absent.stdout | str contains "SKIP") { fail "absent logs did not print SKIP" }

let plain = (^$nu.current-exe bin/smolfire-metrics.nu tests/fixtures/spool-clean.mbox | complete)
if $plain.exit_code != 1 { fail $"uninstrumented log should exit 1, got ($plain.exit_code)" }

print "smolfire-metrics-test: ok"
