#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/openlineage-export-test.nu — focused tests for bin/openlineage-export.nu
#
# Run from the repo root:
#   nu tests/openlineage-export-test.nu

use ../bin/openlineage-export.nu [infer-event-type, project-record, project-records]

const EXPORTER = (path self | path dirname | path dirname | path join "bin" "openlineage-export.nu")

# ── Inline assert helpers ─────────────────────────────────────────────────────

def fail [msg: string] {
    print $"openlineage-export-test: FAIL — ($msg)"
    exit 1
}

def "assert equal" [left: any, right: any, label: string = ""] {
    if $left != $right {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        fail $"assert equal failed($ctx)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"
    }
}

def assert [cond: bool, label: string = ""] {
    if not $cond {
        let ctx = if ($label | str length) > 0 { $" \(($label)\)" } else { "" }
        fail $"assert failed($ctx)"
    }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def run-export [docs: any, --pretty] {
    let tmp = (^mktemp | str trim)
    $docs | to json --indent 2 | save --force $tmp
    let fmt = if $pretty { ["--pretty"] } else { [] }
    let result = try {
        ^$nu.current-exe --no-config-file $EXPORTER --from $tmp ...$fmt | complete
    } catch {|err|
        rm --force $tmp
        fail $"failed to run exporter: ($err.msg)"
    }
    rm --force $tmp
    $result
}

# ── Test 1: state-edge mapping + parent/dependency/version facets ─────────────
print "test 1: maps compact BOP/filesystem records to OpenLineage START with stable facets"

let start_doc = {
    schema_version: "v1"
    event_time: "2026-09-23T09:15:00Z"
    job: {
        namespace: "smolfire.bop"
        name: "build-image"
        card: "build-image"
        template: "release-image"
    }
    run: {
        run_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        state_from: "pending"
        state_to: "running"
        attempt: 2
        lease_id: "lease-42"
        binding: {
            executor: "jail"
            jail: "smolfire-build-42"
            pid: 4242
        }
    }
    source: {
        bop_run_id: "bop-run-42"
        io_observer: "ktrace"
    }
    parent: {
        run_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        job: {
            namespace: "smolfire.bop"
            name: "coord-root"
        }
        root: {
            run_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
            job: {
                namespace: "smolfire.bop"
                name: "root-card"
            }
        }
    }
    dependencies: [
        {
            job: {
                namespace: "smolfire.bop"
                name: "prepare-rootfs"
            }
            run_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
            dependency_type: "DIRECT_INVOCATION"
            sequence_trigger_rule: "FINISH_TO_START"
            status_trigger_rule: "EXECUTE_ON_SUCCESS"
        }
    ]
    inputs: [
        {
            namespace: "hammer2://tank/ci"
            name: "/workspace/input.txt"
            version: {
                identity: "snapshot@ci.2026-09-23T09:10:00Z"
                filesystem: "HAMMER2"
                kind: "snapshot"
                pfs: "ci"
            }
        }
    ]
    outputs: [
        {
            namespace: "ffs://release"
            path: "/artifacts/smolfire.ufs.qcow2"
            version: {
                identity: "snapshot@wapbl-2026-09-23T09:14:58Z"
                filesystem: "FFS"
                kind: "snapshot"
                wapbl_txg: "184467"
            }
        }
    ]
}

assert equal (infer-event-type $start_doc) "START" "pending->running => START"
let start_event = project-record $start_doc
assert equal $start_event.eventType "START" "eventType"
assert equal $start_event.job.namespace "smolfire.bop" "job namespace"
assert equal $start_event.job.facets.smolfireBop.template "release-image" "job facet template"
assert equal $start_event.run.facets.smolfireBopRun.leaseId "lease-42" "lease id"
assert equal $start_event.run.facets.parent.run.runId "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" "parent run id"
assert equal $start_event.run.facets.parent.root.job.name "root-card" "root job name"
assert equal ($start_event.run.facets.jobDependencies.upstream | length) 1 "dependency count"
assert equal $start_event.run.facets.jobDependencies.upstream.0.run.runId "dddddddd-dddd-4ddd-8ddd-dddddddddddd" "dependency run id"
assert equal $start_event.inputs.0.facets.version.datasetVersion "snapshot@ci.2026-09-23T09:10:00Z" "input dataset version"
assert equal $start_event.inputs.0.facets.smolfireFilesystemVersion.filesystem "HAMMER2" "input filesystem"
assert equal $start_event.outputs.0.name "/artifacts/smolfire.ufs.qcow2" "output path as dataset name"
assert equal $start_event.outputs.0.facets.smolfireFilesystemVersion.details.wapbl_txg "184467" "ffs detail retained"

print "  PASS"

# ── Test 2: absent version identity omits dataset version facets ──────────────
print "test 2: omits dataset version facets when no stable filesystem version was observed"

let no_version_doc = {
    schema_version: "v1"
    event_time: "2026-09-23T09:16:00Z"
    job: {
        namespace: "smolfire.bop"
        name: "harvest-logs"
    }
    run: {
        run_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        state_from: "running"
        state_to: "done"
        attempt: 1
    }
    outputs: [
        {
            namespace: "file:///var/mail"
            path: "/var/mail/spool"
        }
    ]
}

let no_version_event = project-record $no_version_doc
assert equal $no_version_event.eventType "COMPLETE" "running->done => COMPLETE"
assert equal $no_version_event.outputs.0.namespace "file:///var/mail" "output namespace"
assert equal $no_version_event.outputs.0.name "/var/mail/spool" "path fallback"
assert (not ($no_version_event.outputs.0 | columns | any {|c| $c == "facets"})) "no facets when version missing"

print "  PASS"

# ── Test 3: CLI output is deterministic and sorted regardless of input order ──
print "test 3: CLI emits deterministic sorted JSON for multiple records"

let unordered_docs = [
    {
        schema_version: "v1"
        event_time: "2026-09-23T09:18:00Z"
        job: {
            namespace: "smolfire.bop"
            name: "publish-image"
        }
        run: {
            run_id: "ffffffff-ffff-4fff-8fff-ffffffffffff"
            state_from: "running"
            state_to: "failed"
            attempt: 3
        }
    }
    {
        schema_version: "v1"
        event_time: "2026-09-23T09:17:00Z"
        job: {
            namespace: "smolfire.bop"
            name: "publish-image"
        }
        run: {
            run_id: "11111111-1111-4111-8111-111111111111"
            state_from: "pending"
            state_to: "running"
            attempt: 1
        }
    }
]

let expected = project-records $unordered_docs
assert equal ($expected | length) 2 "two projected events"
assert equal $expected.0.eventType "START" "first sorted event"
assert equal $expected.1.eventType "FAIL" "second sorted event"

let cli_a = run-export $unordered_docs --pretty
if $cli_a.exit_code != 0 { fail $"cli run A exited ($cli_a.exit_code): ($cli_a.stderr)" }
let cli_b = run-export $unordered_docs --pretty
if $cli_b.exit_code != 0 { fail $"cli run B exited ($cli_b.exit_code): ($cli_b.stderr)" }
assert equal $cli_a.stdout $cli_b.stdout "deterministic pretty JSON"
assert equal ($cli_a.stdout | from json) $expected "CLI matches library projection"

print "  PASS"

# ── Test 4: unsupported lifecycle edges fail fast ──────────────────────────────
print "test 4: rejects unsupported lifecycle edges instead of inventing lineage state"

let bad_doc = {
    schema_version: "v1"
    event_time: "2026-09-23T09:19:00Z"
    job: {
        namespace: "smolfire.bop"
        name: "publish-image"
    }
    run: {
        run_id: "22222222-2222-4222-8222-222222222222"
        state_from: "queued"
        state_to: "running"
        attempt: 1
    }
}

let lib_err = (try {
    project-record $bad_doc
    null
} catch {|err|
    $err.msg
})
assert equal $lib_err "unsupported BOP lifecycle edge 'queued->running'" "library helper error"

let bad = (run-export [$bad_doc])
if $bad.exit_code == 0 { fail "unsupported lifecycle edge unexpectedly succeeded" }
assert ($bad.stderr | str contains "unsupported BOP lifecycle edge 'queued->running'") "stderr names the unsupported edge"

print "  PASS"
print "openlineage-export-test: ok"
