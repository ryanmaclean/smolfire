# SPDX-License-Identifier: Apache-2.0
# release-plan-test.nu — offline tests for bin/release-plan.nu using fixture
# JSON shaped like GitHub REST responses (tests/fixtures/release-plan/).
#
#   nu tests/release-plan-test.nu

use ../bin/release-plan.nu [tag-problems run-problems artifact-problems asset-name kernel-asset-name checksums-text digest-change notes-text]

def "assert equal" [left: any, right: any, msg?: string] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg | default '')\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assert failed: ($msg)"} }
}

let root = ($env.FILE_PWD | path dirname)
let fx = (open ($root | path join "tests/fixtures/release-plan/gh-api.json"))

print "test: tag validation"
assert equal (tag-problems "v0.6.0") [] "v0.6.0"
assert equal (tag-problems "0.6.0-rc.1") [] "rc"
assert (not (tag-problems "30407544832" | is-empty)) "bare run id rejected"
assert (not (tag-problems "latest" | is-empty)) "latest rejected"

print "test: run validation"
assert equal (run-problems $fx.runs.ok $fx.compare.ancestor "amd64") [] "ok+ancestor"
assert equal (run-problems $fx.runs.ok $fx.compare.identical "amd64") [] "ok+identical"
let failed = (run-problems $fx.runs.failed $fx.compare.ancestor "amd64")
assert (($failed | length) == 1 and ($failed.0 | str contains "not success")) "failed conclusion refused"
let inprog = (run-problems $fx.runs.in_progress $fx.compare.ancestor "amd64")
assert (($inprog | length) == 2) "in-progress: status and conclusion both reported"
let div = (run-problems $fx.runs.branch $fx.compare.diverged "aarch64")
assert (($div | length) == 1 and ($div.0 | str contains "not an ancestor of main")) "diverged refused"
let ahd = (run-problems $fx.runs.branch $fx.compare.ahead "aarch64")
assert (($ahd | length) == 1) "ahead-of-main (unmerged) refused"
assert equal (run-problems {status: "completed", conclusion: "success"} $fx.compare.ancestor "x" | length) 1 "missing head_sha"

print "test: artifact presence"
assert equal (artifact-problems $fx.artifacts.amd64 "smolfire-amd64" "amd64") [] "present"
assert (not (artifact-problems $fx.artifacts.expired "smolfire-amd64" "amd64" | is-empty)) "expired refused"
assert (not (artifact-problems $fx.artifacts.amd64 "smolfire-aarch64" "aarch64" | is-empty)) "missing refused"

print "test: asset names"
assert equal (asset-name "v0.6.0" "amd64") "smolfire-amd64-v0.6.0.qcow2"
assert equal (kernel-asset-name "v0.6.0") "smolfire-kernel-v0.6.0"

print "test: checksums + notes against a temp dir"
let tmp = (mktemp -d)
"abc" | save ($tmp | path join "smolfire-amd64-v0.6.0.qcow2")
"hello" | save ($tmp | path join "smolfire-kernel-v0.6.0")
let files = (ls $tmp | get name)
let sums = (checksums-text $files)
# sha256("abc") is a well-known vector.
assert ($sums | str contains "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  smolfire-amd64-v0.6.0.qcow2") "abc vector"
assert ($sums | str contains "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  smolfire-kernel-v0.6.0") "hello vector"
assert equal ($sums | lines | length) 2 "two lines"
assert ($sums | str ends-with "\n") "trailing newline"

let n = (notes-text "v0.6.0" $tmp {amd64: "111", aarch64: "222", kernel: "333"} "Custom body." true)
assert ($n | str starts-with "Custom body.") "body first"
assert ($n | str contains "smolfire-amd64-v0.6.0.qcow2") "amd64 row"
assert ($n | str contains "smolfire-kernel-v0.6.0") "kernel row"
assert (not ($n | str contains "smolfire-aarch64-v0.6.0.qcow2")) "absent aarch64 file -> no row"
assert ($n | str contains "pre-release") "prerelease flagged"
assert ($n | str contains "gh attestation verify") "verify hint"
rm -rf $tmp

print "test: replace-mode digest assertion"
let ch = (digest-change $fx.release_assets_before $fx.release_assets_after_changed "smolfire-aarch64-v0.5.0.qcow2")
assert $ch.changed "changed digest detected"
let same = (digest-change $fx.release_assets_before $fx.release_assets_before "smolfire-aarch64-v0.5.0.qcow2")
assert (not $same.changed) "identical digest => not changed"
let missing = (digest-change $fx.release_assets_before $fx.release_assets_after_changed "nope")
assert (not $missing.changed) "unknown asset => not changed"

print "test: CLI exit codes"
let fxd = ($root | path join "tests/fixtures/release-plan")
let tmpj = (mktemp -d)
$fx.runs.ok | to json | save ($tmpj | path join "run.json")
$fx.runs.failed | to json | save ($tmpj | path join "bad.json")
$fx.compare.ancestor | to json | save ($tmpj | path join "cmp.json")
let rp = ($root | path join "bin/release-plan.nu")
let good = (do { ^nu $rp validate-run --run ($tmpj | path join "run.json") --compare ($tmpj | path join "cmp.json") } | complete)
assert equal $good.exit_code 0 "validate-run good"
assert ($good.stdout | str contains "894bb72") "emits head_sha"
let bad = (do { ^nu $rp validate-run --run ($tmpj | path join "bad.json") --compare ($tmpj | path join "cmp.json") } | complete)
assert equal $bad.exit_code 1 "validate-run refuses failed run"
assert ($bad.stderr | str contains "REFUSE") "refusal message"
let badtag = (do { ^nu $rp validate-tag 12345 } | complete)
assert equal $badtag.exit_code 1 "bad tag refused"
$fx.release_assets_before | to json | save ($tmpj | path join "b.json")
let dc = (do { ^nu $rp digest-changed --before ($tmpj | path join "b.json") --after ($tmpj | path join "b.json") --name "smolfire-aarch64-v0.5.0.qcow2" } | complete)
assert equal $dc.exit_code 1 "digest-changed refuses unchanged"
rm -rf $tmpj

print "release-plan-test: all passed"
