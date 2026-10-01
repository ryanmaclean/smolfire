#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/reassemble-plan-test.nu — fixture tests for bin/reassemble-plan.nu and
# the reassemble plumbing in bin/build-smolfire-vm.nu / build-image-hosted.yml.
# Nothing here needs FreeBSD: the obj tree is a synthetic fixture. What can NOT
# be proven locally (make treating pkgbase-repo as up to date, the real repo
# size) is covered by the in-VM `check-dryrun` guard and a CI run — see
# docs/BUILDING.md "Reassemble mode".
# Run from the repo root: nu tests/reassemble-plan-test.nu

use ../bin/reassemble-plan.nu *

cd ($env.FILE_PWD | path dirname)

def fail [msg: string] {
    print $"reassemble-plan-test: FAIL — ($msg)"
    exit 1
}

# Run a closure expecting an error whose message contains `needle`.
def expect-err [label: string, needle: string, body: closure] {
    let r = (try { do $body; "no-error" } catch {|e| $e.msg })
    if $r == "no-error" { fail $"($label): expected an error containing '($needle)'" }
    if not ($r | str contains $needle) { fail $"($label): error '($r)' lacks '($needle)'" }
}

# --- 1. plan: defaults reproduce the legacy full pipeline exactly -----------
let d = (plan-reassemble)
if $d.mode != "full" { fail "default mode must be full" }
if not ($d.build_world and $d.build_kernel and $d.build_image and $d.gates) { fail "default must run every stage" }
if $d.build_flags != "" { fail "default build_flags must be empty (legacy command byte-identical)" }
if $d.emit { fail "emit must default off" }

let k = (plan-reassemble --kernel-only --kernconf SMOLFIRE-VM-TSLOG --arch aarch64)
if $k.mode != "kernel-only" or $k.build_world or $k.build_image or $k.gates or not $k.build_kernel { fail "kernel-only stage set wrong" }

let e = (plan-reassemble --emit --arch aarch64)
if $e.mode != "full" or not $e.emit { fail "emit keeps the full pipeline" }
if $e.artifact_name != "smolfire-reassemble-aarch64-SMOLFIRE-VM" { fail $"artifact name ($e.artifact_name)" }

let r = (plan-reassemble --reassemble-from-run 123456789)
if $r.mode != "reassemble" or $r.build_world or $r.build_kernel or not $r.build_image or not $r.gates { fail "reassemble stage set wrong" }
if $r.build_flags != "--reassemble-from /var/tmp/reassemble" { fail "reassemble build_flags" }
if $r.source_run != "123456789" { fail "source_run" }

expect-err "non-numeric run" "numeric run id" { plan-reassemble --reassemble-from-run "abc; rm -rf /" }
expect-err "kernel_only+reassemble" "mutually exclusive" { plan-reassemble --kernel-only --reassemble-from-run 1 }
expect-err "kernel_only+emit" "nothing to emit" { plan-reassemble --kernel-only --emit }
expect-err "emit+reassemble" "mutually exclusive" { plan-reassemble --emit --reassemble-from-run 1 }
expect-err "bad arch" "unknown arch" { plan-reassemble --arch sparc }
expect-err "bad kernconf" "bad kernconf" { plan-reassemble --kernconf 'X;y' }

# --- 2. validate-source ------------------------------------------------------
let name = "smolfire-reassemble-amd64-SMOLFIRE-VM"
let good_run = {databaseId: 111, status: "completed", conclusion: "success", workflowName: "Build smolfire qcow2 compatibility image"}
let arts = {artifacts: [
    {id: 1, name: "smolfire-amd64", size_in_bytes: 27000000, expired: false}
    {id: 2, name: $name, size_in_bytes: 400000000, expired: false}
]}
let v = (validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM --this-run 222)
if $v.artifact != $name or $v.artifact_id != 2 { fail "validate-source happy path" }
expect-err "red run" "not green" { validate-source ($good_run | merge {conclusion: "failure"}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "running" "not completed" { validate-source ($good_run | merge {status: "in_progress", conclusion: ""}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "wrong workflow" "belongs to workflow" { validate-source ($good_run | merge {workflowName: "CI"}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "arch mismatch" "no artifact" { validate-source $good_run $arts --arch aarch64 --kernconf SMOLFIRE-VM }
expect-err "kernconf mismatch" "no artifact" { validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM-TSLOG }
expect-err "expired" "expired" { validate-source $good_run {artifacts: [{id: 2, name: $name, size_in_bytes: 5, expired: true}]} --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "oversize" "cap" { validate-source $good_run {artifacts: [{id: 2, name: $name, size_in_bytes: 99, expired: false}]} --arch amd64 --kernconf SMOLFIRE-VM --max-bytes 10 }
expect-err "self" "this run" { validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM --this-run 111 }

# --- 3. pack -> unpack round trip on a synthetic obj tree -------------------
let root = (mktemp -d)
let src = ($root | path join "src")
let conf_dir = ($src | path join "sys" "amd64" "conf")
mkdir $conf_dir
"include \"SMOLFIRE-BASE\"\nident SMOLFIRE-VM\n" | save ($conf_dir | path join "SMOLFIRE-VM")
"cpu HAMMER\n" | save ($conf_dir | path join "SMOLFIRE-BASE")
let src_conf = ($root | path join "src.conf")
"WITHOUT_SENDMAIL=yes\n" | save $src_conf

def make-obj [obj: string, with_pkgs: bool] {
    let top = ($obj | path join "usr" "src" "amd64.amd64")
    mkdir ($top | path join "release" "pkgbase-repo" "FreeBSD:15:amd64" "latest")
    mkdir ($top | path join "release" "pkgbase-repo-dir")
    mkdir ($top | path join "worldstage" "usr" "bin")
    "x" | save ($top | path join "worldstage" "usr" "bin" "uname")
    "FreeBSD-base: { url: \"file:///x\" }" | save ($top | path join "release" "pkgbase-repo-dir" "FreeBSD-base.conf")
    if $with_pkgs {
        "pkg" | save ($top | path join "release" "pkgbase-repo" "FreeBSD:15:amd64" "latest" "FreeBSD-runtime-15.0.pkg")
        "pkg" | save ($top | path join "release" "pkgbase-repo" "FreeBSD:15:amd64" "latest" "FreeBSD-kernel-smolfire-15.0.pkg")
    }
    # unrelated bulk that must NOT travel
    mkdir ($top | path join "tmp")
    "junk" | save ($top | path join "tmp" "world.o")
}
let obj1 = ($root | path join "obj1")
make-obj $obj1 true
let out = ($root | path join "out")
let m = (pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir $out --src-conf $src_conf --src-commit abc123)
if $m.pkg_count != 2 { fail $"pkg_count ($m.pkg_count)" }
if ($m.kernel_pkgs | length) != 1 { fail "kernel pkg not detected" }
if not ($out | path join "manifest.json" | path exists) { fail "manifest.json not written" }
let listing = (^tar -tf ($out | path join "reassemble-products.tar") | lines | str join "\n")
if ($listing | str contains "world.o") { fail "unrelated obj content leaked into the products tar" }
if not ($listing | str contains "worldstage/usr/bin/uname") { fail "uname missing from tar" }

let obj2 = ($root | path join "obj2")
mkdir $obj2
let u = (unpack-products --obj $obj2 --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf)
if $u.pkg_count != 2 or $u.src_commit != "abc123" { fail "unpack result" }
let restored = ($obj2 | path join "usr" "src" "amd64.amd64" "release")
if not ($restored | path join "pkgbase-repo" "FreeBSD:15:amd64" "latest" "FreeBSD-runtime-15.0.pkg" | path exists) { fail "pkg not restored" }
if ($obj2 | path join "usr" "src" "amd64.amd64" "tmp" | path exists) { fail "junk restored" }
let t_repo = (ls -D ($restored | path join "pkgbase-repo") | get modified | first)
let t_dir = (ls -D ($restored | path join "pkgbase-repo-dir") | get modified | first)
if $t_dir < $t_repo { fail "pkgbase-repo-dir must not be older than pkgbase-repo (make would rebuild)" }

# refuses a non-fresh obj
expect-err "non-fresh obj" "already exists" { unpack-products --obj $obj2 --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf }

# --- 4. unpack refusals ------------------------------------------------------
def fresh [] { let o = (mktemp -d); $o }

expect-err "arch" "arch mismatch" { unpack-products --obj (fresh) --src $src --arch aarch64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf }
expect-err "kernconf name" "kernconf mismatch" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM-TSLOG --from-dir $out --src-conf $src_conf }

let src_conf2 = ($root | path join "src2.conf")
"WITHOUT_SENDMAIL=yes\nWITHOUT_ZFS=yes\n" | save $src_conf2
expect-err "src.conf changed" "src.conf differs" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf2 }

# a change to an *included* conf must invalidate too
"cpu OTHER\n" | save -f ($conf_dir | path join "SMOLFIRE-BASE")
expect-err "included kernconf changed" "kernconf (or an included conf) differs" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf }
"cpu HAMMER\n" | save -f ($conf_dir | path join "SMOLFIRE-BASE")

# truncated / corrupted transfer
let bad = ($root | path join "bad")
cp -r $out $bad
"garbage" | save --append ($bad | path join "reassemble-products.tar")
expect-err "truncated" "manifest says" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $bad --src-conf $src_conf }

# tampered manifest path traversal
let evil = ($root | path join "evil")
cp -r $out $evil
open --raw ($evil | path join "manifest.json") | from json | upsert objtop_rel "usr/src/../../etc" | to json | save -f ($evil | path join "manifest.json")
expect-err "traversal" "unsafe objtop_rel" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $evil --src-conf $src_conf }

# --- 5. pack refusals --------------------------------------------------------
let empty_obj = ($root | path join "obj-empty")
make-obj $empty_obj false
expect-err "no pkgs" "no *.pkg" { pack-products --obj $empty_obj --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o2") --src-conf $src_conf }
expect-err "no obj" "missing" { pack-products --obj ($root | path join "nonexistent") --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o3") --src-conf $src_conf }
expect-err "over cap" "over the" { pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o4") --src-conf $src_conf --max-bytes 10 }
if ($root | path join "o4" "reassemble-products.tar.tmp" | path exists) { fail "oversize tmp tar left behind" }

# --- 6. dry-run guard --------------------------------------------------------
let clean = "mkdir -p /usr/obj/usr/src/amd64.amd64/release/cw-smolfire-ufs-qcow2\nsh /usr/src/release/scripts/mk-vmimage.sh -C /usr/src/release/tools/vmimage.subr -S /usr/src -c /usr/src/release/tools/smolfire-qemu.conf PKGBASE_REPO_DIR=/usr/obj/usr/src/amd64.amd64/release/pkgbase-repo-dir\ntouch cw-smolfire-ufs-qcow2"
if (dryrun-guard $clean | is-not-empty) { fail "clean dry run flagged" }
let dirty = ($clean + "\nmkdir -p pkgbase-repo\n( make -f Makefile.inc1 -C /usr/src packages REPODIR=/x/pkgbase-repo INCLUDE_PKG_IN_PKGBASE_REPO=YES BOOTSTRAP_PKG_FROM_PORTS=YES )")
if (dryrun-guard $dirty | length) < 1 { fail "packages rebuild not caught by dry-run guard" }
if (dryrun-guard "make -C /usr/src buildworld" | is-empty) { fail "buildworld not caught" }
let cli = (^nu bin/reassemble-plan.nu check-dryrun /dev/null | complete)
if $cli.exit_code != 0 { fail $"check-dryrun CLI on empty input: ($cli.stderr)" }

# --- 7. static wiring: build script + workflow -------------------------------
let bs = (open --raw bin/build-smolfire-vm.nu)
if not ($bs | str contains "--reassemble-from") { fail "build-smolfire-vm.nu lacks --reassemble-from" }
if not (nu-check ($env.PWD | path join "bin" "build-smolfire-vm.nu")) { fail "build-smolfire-vm.nu does not parse" }
if not (nu-check ($env.PWD | path join "bin" "reassemble-plan.nu")) { fail "reassemble-plan.nu does not parse" }

let wf = (open .github/workflows/build-image-hosted.yml)
let ins = $wf.on.workflow_dispatch.inputs
if $ins.reassemble_from_run.default != "" { fail "reassemble_from_run must default to empty" }
if $ins.emit_reassemble.default != false { fail "emit_reassemble must default false" }
# every reassemble-specific step must be gated so default runs skip it
let steps = $wf.jobs.build.steps
let gated = ($steps | where {|s| ($s.name? | default "" | str starts-with "Reassemble —") })
if ($gated | length) < 4 { fail $"expected >=4 'Reassemble —' steps, got ($gated | length)" }
for s in $gated {
    let c = ($s.if? | default "")
    if not (($c | str contains "reassemble_from_run") or ($c | str contains "emit_reassemble")) {
        fail $"step '($s.name)' is not gated on a reassemble input"
    }
}
let bstep = ($steps | where {|s| ($s.name? | default "") == "Build (world + kernel + cloudware-release) inside VM" } | first)
if not ($bstep.run | str contains "$REASSEMBLE_FLAGS") { fail "build step does not take REASSEMBLE_FLAGS" }

rm -rf $root
print "reassemble-plan-test: ok"
