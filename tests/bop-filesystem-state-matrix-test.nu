#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/bop-filesystem-state-matrix-test.nu — schema checks for the filesystem matrix deliverable.

const MATRIX = "docs/BOP-FILESYSTEM-STATE-MATRIX.toml"


def fail [msg: string] {
    print $"bop-filesystem-state-matrix-test: FAIL — ($msg)"
    exit 1
}

let raw = (open --raw $MATRIX)
let doc = ($raw | from toml)

if $doc.schema_version != "v1" { fail $"schema_version = ($doc.schema_version)" }
if $doc.issue != 63 { fail $"issue = ($doc.issue)" }
if $doc.measured != false { fail "matrix must declare measured = false until benchmarks exist" }
if ($doc.workload | length) != 8 { fail "workload must contain the 8 issue steps" }
if ($doc.metrics | length) != 9 { fail "metrics must contain the 9 issue measurements" }
if ($doc.required_primitives | length) < 6 { fail "required_primitives unexpectedly short" }

let ids = ($doc.candidates | get id | sort)
let want_ids = (["hammer1" "hammer2" "netbsd_ffs_wapbl_fss" "netbsd_lfs"] | sort)
if $ids != $want_ids { fail $"candidate ids = ($ids | to nuon), want ($want_ids | to nuon)" }

if ($doc.candidates | where history_without_extra_db == true | length) < 3 {
    fail "expected at least three candidates to expose history without a second DB"
}

let primary = ($doc.candidates | where id == $doc.recommendation | first)
if $primary.name != "NetBSD FFS + WAPBL + persistent fss" {
    fail $"primary recommendation resolved to unexpected candidate: ($primary.name)"
}
if $primary.recommendation_rank != 1 { fail "primary recommendation must have rank 1" }
if $primary.history_model != "scheduled_snapshots" { fail "FFS baseline should be scheduled_snapshots" }
if not ($primary.primitive_set | any {|p| $p == "persistent_fss_snapshot" }) {
    fail "FFS baseline must require persistent_fss_snapshot"
}

let lfs = ($doc.candidates | where id == "netbsd_lfs" | first)
if $lfs.history_without_extra_db != false { fail "NetBSD LFS should not claim history_without_extra_db" }
if $lfs.recommendation_rank != 4 { fail "NetBSD LFS should rank last in this matrix" }

print "bop-filesystem-state-matrix-test: ok"
