#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/lower-bound-report.nu — render the rump/rumprun lower-bound prototype record
#
# Usage:
#   nu bin/lower-bound-report.nu                  # JSON (default)
#   nu bin/lower-bound-report.nu --markdown       # human summary
#   nu bin/lower-bound-report.nu --from path.json

def load-doc [path: string] {
    open --raw $path | from json
}

def require-field [doc: record, field: string] {
    if not ($field in ($doc | columns)) {
        error make {msg: $"missing required field: ($field)"}
    }
}

def validate-doc [doc: record] {
    for field in ["schema_version" "issue" "comparison_issue_ids" "selected_candidate" "ready_workload_contract" "candidates"] {
        require-field $doc $field
    }

    if $doc.schema_version != "v1" {
        error make {msg: $"unsupported schema_version: ($doc.schema_version)"}
    }

    let selected = ($doc.candidates | where id == $doc.selected_candidate)
    if ($selected | length) != 1 {
        error make {msg: $"selected_candidate must match exactly one candidate: ($doc.selected_candidate)"}
    }

    let contract = $doc.ready_workload_contract
    for field in ["ready_marker" "operations"] {
        require-field $contract $field
    }

    if $contract.ready_marker != "SMOLFIRE_READY" {
        error make {msg: $"unexpected ready marker: ($contract.ready_marker)"}
    }

    if ($contract.operations | length) < 6 {
        error make {msg: "ready_workload_contract.operations is unexpectedly short"}
    }

    $doc
}

def fmt-metric [value?: any] {
    let v = ($value | default null)
    if $v == null { "n/a" } else { $v | into string }
}

def summarize-candidate [c: record] {
    let artifact = fmt-metric ($c.metrics | get artifact_bytes?)
    let ready_ms = fmt-metric ($c.metrics | get boot_to_ready_ms?)
    let license = ($c.licensing | get verdict? | default "unknown")
    $"| ($c.id) | ($c.status) | ($c.filesystem) | ($artifact) | ($ready_ms) | ($license) |"
}

def to-markdown [doc: record] {
    let compare = ($doc.comparison_issue_ids | each {|n| $"#($n)"} | str join ", ")
    let selected = ($doc.candidates | where id == $doc.selected_candidate | first)
    let ops = (
        $doc.ready_workload_contract.operations
        | each {|op| $"- ($op)"}
        | str join "\n"
    )
    let candidate_rows = (
        $doc.candidates
        | each {|c| summarize-candidate $c }
        | str join "\n"
    )

    [
        $"# ($doc.title)"
        ""
        $"Issue: #($doc.issue)"
        $"Compares against: ($compare)"
        $"Selected candidate: `($selected.id)`"
        ""
        "## READY/workload contract"
        $"- READY marker: `($doc.ready_workload_contract.ready_marker)`"
        $"- Writable state disk: `($doc.ready_workload_contract.writable_state_disk)`"
        $"- Crash recovery: `($doc.ready_workload_contract.crash_recovery)`"
        $"- Filesystem-native identity: `($doc.ready_workload_contract.filesystem_native_identity)`"
        ""
        $ops
        ""
        "## Candidate matrix"
        "| id | status | filesystem | artifact_bytes | boot_to_ready_ms | licensing |"
        "|---|---|---|---:|---:|---|"
        $candidate_rows
        ""
        "## Prototype build commands"
        (
            $selected.build.commands
            | each {|cmd| $"- `($cmd)`"}
            | str join "\n"
        )
    ] | str join "\n"
}

def main [
    --from: string = "docs/lower-bound-rump-rumprun.json",
    --markdown,
    --json,
] {
    let doc = (validate-doc (load-doc $from))

    if $markdown {
        print (to-markdown $doc)
    } else {
        print ($doc | to json --indent 2)
    }
}
