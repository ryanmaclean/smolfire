#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/bench-record-test.nu — unit tests for bin/bench-record.nu
#
# Validates the emitted record against the shape of ryanmaclean/skills
# schemas/bench.v1.schema.json (required: schema, project, timestamp,
# workload, metrics) without vendoring a JSON-schema validator — the
# canonical schema lives in that repo, this is a structural smoke test.

def fail [msg: string] {
    print $"bench-record-test: FAIL — ($msg)"
    exit 1
}

let raw = (^$nu.current-exe bin/bench-record.nu --workload one-elf-boot --filesystem ffs tests/fixtures/smolfire-metrics-build.log tests/fixtures/smolfire-metrics-gate.log | complete)
if $raw.exit_code != 0 { fail $"exited ($raw.exit_code): ($raw.stderr)" }

let doc = ($raw.stdout | from json)
if $doc.schema != "ryanlab.bench.v1" { fail $"schema = ($doc.schema)" }
if $doc.project != "smolfire" { fail $"project = ($doc.project)" }
if ($doc.timestamp | is-empty) { fail "timestamp missing" }
if $doc.workload != "one-elf-boot" { fail $"workload = ($doc.workload)" }
if $doc.filesystem != "ffs" { fail $"filesystem = ($doc.filesystem)" }
if $doc.metrics.artifact_bytes != 38797312 { fail $"artifact_bytes = ($doc.metrics.artifact_bytes)" }
if $doc.metrics.rss_bytes != 20971520 { fail $"rss_bytes = ($doc.metrics.rss_bytes)" }
if $doc.metrics.boot_ms != 511 { fail $"boot_ms = ($doc.metrics.boot_ms)" }
# raw SMOLFIRE_METRIC/_SECTION keys must survive verbatim (never discard
# raw measurements per docs/BENCHMARKING.md)
if $doc.metrics."kernel.bytes" != 38797312 { fail "raw kernel.bytes not preserved" }
if $doc.metrics."section..text" != 22118400 { fail "raw section..text not preserved" }
if $doc.tags.workload != "one-elf-boot" { fail "tags.workload missing" }

# --out writes the file and prints a confirmation instead of the JSON
let tmp = $"/tmp/bench-record-test-($nu.pid).json"
let out = (^$nu.current-exe bin/bench-record.nu --workload one-elf-boot --out $tmp tests/fixtures/smolfire-metrics-build.log | complete)
if $out.exit_code != 0 { fail $"--out exited ($out.exit_code): ($out.stderr)" }
if not ($tmp | path exists) { fail "--out did not write a file" }
let written = (open $tmp)
if $written.schema != "ryanlab.bench.v1" { fail "--out file missing schema field" }
rm $tmp

# missing --workload is a usage error
let no_workload = (^$nu.current-exe bin/bench-record.nu tests/fixtures/smolfire-metrics-build.log | complete)
if $no_workload.exit_code != 1 { fail $"missing --workload should exit 1, got ($no_workload.exit_code)" }

# absent log files is an error (no silent empty record)
let absent = (^$nu.current-exe bin/bench-record.nu --workload x /nonexistent-build.log | complete)
if $absent.exit_code != 1 { fail $"absent logs should exit 1, got ($absent.exit_code)" }

# a log with no SMOLFIRE_METRIC/_SECTION lines is an error, not an empty record
let plain = (^$nu.current-exe bin/bench-record.nu --workload x tests/fixtures/spool-clean.mbox | complete)
if $plain.exit_code != 1 { fail $"uninstrumented log should exit 1, got ($plain.exit_code)" }

print "bench-record-test: ok"
