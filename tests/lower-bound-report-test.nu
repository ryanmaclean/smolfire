#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0

def fail [msg: string] {
    print $"lower-bound-report-test: FAIL — ($msg)"
    exit 1
}

const REPORT = path self | path dirname | path dirname | path join "bin" "lower-bound-report.nu"
const DOC = path self | path dirname | path dirname | path join "docs" "lower-bound-rump-rumprun.json"

let raw = (^$nu.current-exe $REPORT --from $DOC --json | complete)
if $raw.exit_code != 0 {
    fail $"--json exited ($raw.exit_code): ($raw.stderr)"
}

let doc = ($raw.stdout | from json)
if $doc.schema_version != "v1" { fail "schema_version != v1" }
if $doc.issue != 72 { fail $"issue = ($doc.issue), want 72" }
if $doc.comparison_issue_ids != [63 64] { fail $"comparison_issue_ids = ($doc.comparison_issue_ids | to nuon)" }
if $doc.selected_candidate != "rumprun-hw_virtio-ffs" { fail $"selected_candidate = ($doc.selected_candidate)" }
if $doc.ready_workload_contract.ready_marker != "SMOLFIRE_READY" { fail "READY marker mismatch" }

let rumprun = ($doc.candidates | where id == "rumprun-hw_virtio-ffs" | first)
if $rumprun.filesystem != "ffs" { fail $"filesystem = ($rumprun.filesystem), want ffs" }
if $rumprun.licensing.verdict != "allowed" { fail "licensing verdict != allowed" }
if $rumprun.licensing.disallowed_families != ["GPL" "LGPL" "AGPL"] {
    fail $"unexpected disallowed_families: ($rumprun.licensing.disallowed_families | to nuon)"
}
if not ($rumprun.build.commands | any {|cmd| $cmd =~ 'rumprun-bake hw_virtio' }) {
    fail "build.commands missing rumprun-bake hw_virtio"
}
if $rumprun.build.state_disk_size_bytes != 67108864 {
    fail $"state_disk_size_bytes = ($rumprun.build.state_disk_size_bytes), want 67108864"
}

let md = (^$nu.current-exe $REPORT --from $DOC --markdown | complete)
if $md.exit_code != 0 {
    fail $"--markdown exited ($md.exit_code): ($md.stderr)"
}
for needle in [
    "Compares against: #63, #64"
    "Selected candidate: `rumprun-hw_virtio-ffs`"
    "SMOLFIRE_READY"
    "rumprun-bake hw_virtio worker.bin worker"
] {
    if not ($md.stdout | str contains $needle) {
        fail $"markdown missing: ($needle)"
    }
}

print "lower-bound-report-test: ok"
