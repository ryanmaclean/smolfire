# SPDX-License-Identifier: Apache-2.0
# release-plan-test.nu — offline tests for bin/release-plan.nu using fixture
# JSON shaped like GitHub REST responses (tests/fixtures/release-plan/).
#
#   nu tests/release-plan-test.nu

use ../bin/release-plan.nu [tag-problems run-problems artifact-problems asset-name kernel-asset-name checksums-text digest-change notes-text notes-file-problems fetch-list missing-assets]

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

print "test: notes_file path validation"
assert equal (notes-file-problems "") [] "empty ok"
assert equal (notes-file-problems "docs/notes/v0.6.0.md") [] "relative ok"
assert (not (notes-file-problems "/etc/passwd" | is-empty)) "absolute refused"
assert (not (notes-file-problems "../secret" | is-empty)) ".. refused"
assert (not (notes-file-problems "a/../../b" | is-empty)) "nested .. refused"
assert (not (notes-file-problems "-rf" | is-empty)) "leading dash refused"
assert equal (notes-file-problems "a..b/c") [] "dots inside a name are fine"
let nf = (do { ^nu $rp validate-notes-file "/etc/passwd" } | complete)
assert equal $nf.exit_code 1 "CLI refuses absolute notes_file"

print "test: replace-mode fetch list / completeness (fail closed)"
let rel = [{name: "smolfire-amd64-v1.qcow2"} {name: "smolfire-aarch64-v1.qcow2"} {name: "smolfire-kernel-v1"} {name: "SHA256SUMS"} {name: "smolfire-amd64-v1.qcow2.sha256"}]
assert equal (fetch-list $rel ["smolfire-aarch64-v1.qcow2"]) ["smolfire-amd64-v1.qcow2" "smolfire-kernel-v1"] "fetch all but staged and derived"
assert equal (missing-assets $rel ["smolfire-amd64-v1.qcow2" "smolfire-kernel-v1"]) ["smolfire-aarch64-v1.qcow2"] "missing detected"
assert equal (missing-assets $rel ["smolfire-amd64-v1.qcow2" "smolfire-aarch64-v1.qcow2" "smolfire-kernel-v1"]) [] "complete"
let cd = (mktemp -d)
let ad = (mktemp -d)
$rel | to json | save ($ad | path join "a.json")
"x" | save ($cd | path join "smolfire-amd64-v1.qcow2")
let inc = (do { ^nu $rp release-complete --assets ($ad | path join "a.json") --dir $cd } | complete)
assert equal $inc.exit_code 1 "CLI release-complete refuses incomplete set"
let fl = (do { ^nu $rp release-fetch --assets ($ad | path join "a.json") --staged-dir $cd } | complete)
assert equal $fl.exit_code 0 "release-fetch ok"
assert equal ($fl.stdout | lines) ["smolfire-aarch64-v1.qcow2" "smolfire-kernel-v1"] "release-fetch names"
rm -rf $cd $ad

print "test: CLI names / checksums / notes / validate-run --artifacts"
assert equal ((^nu $rp names --tag v0.6.0 --arch aarch64) | str trim) "smolfire-aarch64-v0.6.0.qcow2" "names arch"
assert equal ((^nu $rp names --tag v0.6.0 --kernel) | str trim) "smolfire-kernel-v0.6.0" "names kernel"
let okt = (do { ^nu $rp validate-tag v0.6.0 } | complete)
assert equal $okt.exit_code 0 "valid tag accepted"
let wd = (mktemp -d)
"abc" | save ($wd | path join "smolfire-amd64-v0.6.0.qcow2")
"hello" | save ($wd | path join "smolfire-kernel-v0.6.0")
let ck = (do { ^nu $rp checksums --dir $wd } | complete)
assert equal $ck.exit_code 0 "checksums CLI"
let sc = (do { cd $wd; ^sha256sum -c SHA256SUMS } | complete)
assert equal $sc.exit_code 0 $"sha256sum -c: ($sc.stdout) ($sc.stderr)"
let sc2 = (do { cd $wd; ^sha256sum -c smolfire-amd64-v0.6.0.qcow2.sha256 } | complete)
assert equal $sc2.exit_code 0 "per-file .sha256 verifies"
let emptyd = (mktemp -d)
let ce = (do { ^nu $rp checksums --dir $emptyd } | complete)
assert equal $ce.exit_code 1 "checksums on empty dir refuses"
"body text" | save ($wd | path join "body.md")
let nt = (do { ^nu $rp notes --tag v0.6.0 --dir $wd --body-file ($wd | path join "body.md") --amd64-run 11 --kernel-run 33 --prerelease } | complete)
assert equal $nt.exit_code 0 "notes CLI"
assert ($nt.stdout | str starts-with "body text") "notes body"
assert ($nt.stdout | str contains "qemu-system-x86_64 -M q35") "boot command present"
assert ($nt.stdout | str contains "file=smolfire-amd64-v0.6.0.qcow2") "boot line names the qcow2"
assert ($nt.stdout | str contains "512 MiB") "size target present"
let nt2 = (do { ^nu $rp notes --tag v0.6.0 --dir $emptyd } | complete)
assert (not ($nt2.stdout | str contains "qemu-system-x86_64")) "no boot line without amd64 asset"
$fx.runs.ok | to json | save ($wd | path join "run.json")
$fx.compare.ancestor | to json | save ($wd | path join "cmp.json")
$fx.artifacts.amd64 | to json | save ($wd | path join "art.json")
$fx.artifacts.expired | to json | save ($wd | path join "exp.json")
let va = (do { ^nu $rp validate-run --run ($wd | path join "run.json") --compare ($wd | path join "cmp.json") --artifacts ($wd | path join "art.json") --artifact-name smolfire-amd64 } | complete)
assert equal $va.exit_code 0 "artifacts present"
let vb = (do { ^nu $rp validate-run --run ($wd | path join "run.json") --compare ($wd | path join "cmp.json") --artifacts ($wd | path join "exp.json") --artifact-name smolfire-amd64 } | complete)
assert equal $vb.exit_code 1 "expired artifact refused via CLI"
rm -rf $wd $emptyd

print "test: workflow structure (release-flow invariants)"
let wf_path = ($root | path join ".github/workflows/release-image.yml")
let wf = (open $wf_path)
let steps = ($wf.jobs.release.steps)
let idx = {|needle| $steps | enumerate | where {|r| (($r.item | get -o name | default "") | str contains $needle) } | get -o 0.index }
assert (($steps | get 0.run) | str contains "refs/heads/main") "first step guards ref == main"
assert (($steps | get 1.with.ref) == "main") "checkout pins main"
let i_att = (do $idx "Attest")
let i_create = (do $idx "Create release")
let i_repl = (do $idx "Replace assets")
assert ($i_att < $i_create and $i_att < $i_repl) "attest runs before release is created/modified"
let raw = (open --raw $wf_path)
assert (not ($raw | str contains "|| true")) "no || true swallowing in release workflow"
assert ($raw | str contains 'cp -- "$NOTES_FILE"') "cp uses -- for notes file"
assert (($steps | where {|s| ($s | get -o uses | default "") | str contains "attest-build-provenance" } | get 0.with.subject-path | str trim) == "assets/*") "attest subject is assets/* (all staged files)"

print "release-plan-test: all passed"
