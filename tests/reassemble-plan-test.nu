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
if $v.artifact != $name or $v.artifact_id != "2" { fail "validate-source happy path" }
expect-err "red run" "not green" { validate-source ($good_run | merge {conclusion: "failure"}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "running" "not completed" { validate-source ($good_run | merge {status: "in_progress", conclusion: ""}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "wrong workflow" "belongs to workflow" { validate-source ($good_run | merge {workflowName: "CI"}) $arts --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "arch mismatch" "no artifact" { validate-source $good_run $arts --arch aarch64 --kernconf SMOLFIRE-VM }
expect-err "kernconf mismatch" "no artifact" { validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM-TSLOG }
expect-err "expired" "expired" { validate-source $good_run {artifacts: [{id: 2, name: $name, size_in_bytes: 5, expired: true}]} --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "oversize" "cap" { validate-source $good_run {artifacts: [{id: 2, name: $name, size_in_bytes: 99, expired: false}]} --arch amd64 --kernconf SMOLFIRE-VM --max-bytes 10 }
# exact selection (finding: `first` of same-named artifacts)
let dup = {artifacts: [
    {id: 7, name: $name, size_in_bytes: 5, expired: false}
    {id: 8, name: $name, size_in_bytes: 5, expired: false}
]}
expect-err "ambiguous names" "ambiguous" { validate-source $good_run $dup --arch amd64 --kernconf SMOLFIRE-VM }
# an expired duplicate does not make it ambiguous; the live one is chosen by id
let dup2 = {artifacts: [
    {id: 7, name: $name, size_in_bytes: 99999999999, expired: true}
    {id: 8, name: $name, size_in_bytes: 5, expired: false}
]}
let v2 = (validate-source $good_run $dup2 --arch amd64 --kernconf SMOLFIRE-VM)
if $v2.artifact_id != "8" or $v2.size_in_bytes != 5 { fail $"expired duplicate must be skipped, got ($v2)" }
# pinned id must match
expect-err "pinned id mismatch" "does not match" { validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM --artifact-id 99 }
let v3 = (validate-source $good_run $arts --arch amd64 --kernconf SMOLFIRE-VM --artifact-id 2)
if $v3.artifact_id != "2" { fail "pinned id happy path" }
# an artifact that belongs to another run is not a candidate
let other = {artifacts: [{id: 9, name: $name, size_in_bytes: 5, expired: false, workflow_run: {id: 999}}]}
expect-err "artifact of another run" "no artifact" { validate-source $good_run $other --arch amd64 --kernconf SMOLFIRE-VM }
expect-err "no id" "no id" { validate-source $good_run {artifacts: [{name: $name, size_in_bytes: 5, expired: false}]} --arch amd64 --kernconf SMOLFIRE-VM }
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

# smolfire repo overlay fixture (sys/*/conf/SMOLFIRE*, release/tools)
let repo = ($root | path join "repo")
mkdir ($repo | path join "sys" "amd64" "conf")
mkdir ($repo | path join "release" "tools")
"ident SMOLFIRE-VM\n" | save ($repo | path join "sys" "amd64" "conf" "SMOLFIRE-VM")
"image conf v1\n" | save ($repo | path join "release" "tools" "smolfire-qemu.conf")
"subr v1\n" | save ($repo | path join "release" "tools" "vmimage-extra.subr")
let mvf = ($root | path join "make-vars.json")
let make_args = ["KERNCONF=SMOLFIRE-VM" "WITH_CLOUDWARE=yes" "CLOUDWARE=smolfire" "SMOLFIRECONF=/x/smolfire-qemu.conf" "SMOLFIRE_FORMAT=qcow2" "SMOLFIRE_FSLIST=ufs" "VMSIZE=2g" "SWAPSIZE=128m"]
$make_args | to json | save $mvf
const COMMIT = "0123456789abcdef0123456789abcdef01234567"

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
let m = (pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo --make-vars-file $mvf)
if $m.pkg_count != 2 { fail $"pkg_count ($m.pkg_count)" }
if ($m.kernel_pkgs | length) != 1 { fail "kernel pkg not detected" }
if not ($out | path join "manifest.json" | path exists) { fail "manifest.json not written" }
let listing = (^tar -tf ($out | path join "reassemble-products.tar") | lines | str join "\n")
if ($listing | str contains "world.o") { fail "unrelated obj content leaked into the products tar" }
if not ($listing | str contains "worldstage/usr/bin/uname") { fail "uname missing from tar" }

let obj2 = ($root | path join "obj2")
mkdir $obj2
let u = (unpack-products --obj $obj2 --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo)
if $u.pkg_count != 2 or $u.src_commit != $COMMIT { fail "unpack result" }
let restored = ($obj2 | path join "usr" "src" "amd64.amd64" "release")
if not ($restored | path join "pkgbase-repo" "FreeBSD:15:amd64" "latest" "FreeBSD-runtime-15.0.pkg" | path exists) { fail "pkg not restored" }
if ($obj2 | path join "usr" "src" "amd64.amd64" "tmp" | path exists) { fail "junk restored" }
let t_repo = (ls -D ($restored | path join "pkgbase-repo") | get modified | first)
let t_dir = (ls -D ($restored | path join "pkgbase-repo-dir") | get modified | first)
if $t_dir < $t_repo { fail "pkgbase-repo-dir must not be older than pkgbase-repo (make would rebuild)" }

# refuses a non-fresh obj
expect-err "non-fresh obj" "already exists" { unpack-products --obj $obj2 --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }

# --- 4. unpack refusals ------------------------------------------------------
def fresh [] { let o = (mktemp -d); $o }

expect-err "arch" "arch mismatch" { unpack-products --obj (fresh) --src $src --arch aarch64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }
expect-err "kernconf name" "kernconf mismatch" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM-TSLOG --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }

let src_conf2 = ($root | path join "src2.conf")
"WITHOUT_SENDMAIL=yes\nWITHOUT_ZFS=yes\n" | save $src_conf2
expect-err "src.conf changed" "src.conf differs" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf2 --src-commit $COMMIT --repo $repo }

# a change to an *included* conf must invalidate too
"cpu OTHER\n" | save -f ($conf_dir | path join "SMOLFIRE-BASE")
expect-err "included kernconf changed" "kernconf (or an included conf) differs" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }
"cpu HAMMER\n" | save -f ($conf_dir | path join "SMOLFIRE-BASE")

# truncated / corrupted transfer
let bad = ($root | path join "bad")
cp -r $out $bad
"garbage" | save --append ($bad | path join "reassemble-products.tar")
expect-err "truncated" "manifest says" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $bad --src-conf $src_conf --src-commit $COMMIT --repo $repo }

# tampered manifest path traversal
let evil = ($root | path join "evil")
cp -r $out $evil
open --raw ($evil | path join "manifest.json") | from json | upsert objtop_rel "usr/src/../../etc" | to json | save -f ($evil | path join "manifest.json")
expect-err "traversal" "unsafe objtop_rel" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $evil --src-conf $src_conf --src-commit $COMMIT --repo $repo }

# --- 5. pack refusals --------------------------------------------------------
let empty_obj = ($root | path join "obj-empty")
make-obj $empty_obj false
expect-err "no pkgs" "no *.pkg" { pack-products --obj $empty_obj --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o2") --src-conf $src_conf --src-commit $COMMIT --repo $repo --make-vars-file $mvf }
expect-err "no obj" "missing" { pack-products --obj ($root | path join "nonexistent") --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o3") --src-conf $src_conf --src-commit $COMMIT --repo $repo --make-vars-file $mvf }
expect-err "over cap" "over the" { pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o4") --src-conf $src_conf --src-commit $COMMIT --repo $repo --make-vars-file $mvf --max-bytes 10 }
if ($root | path join "o4" "reassemble-products.tar.tmp" | path exists) { fail "oversize tmp tar left behind" }

# --- 5b. manifest pins (src commit, overlay, make vars) ------------------------
let mm = (open --raw ($out | path join "manifest.json") | from json)
if $mm.src_commit != $COMMIT { fail "manifest src_commit" }
if ($mm.overlay_sha256 | str length) != 64 { fail "manifest overlay_sha256 missing" }
if ("SMOLFIRECONF=/x/smolfire-qemu.conf" in $mm.make_vars) or ("VMSIZE=2g" in $mm.make_vars) { fail "image-only make vars must not be pinned" }
if "KERNCONF=SMOLFIRE-VM" not-in $mm.make_vars { fail "KERNCONF make var not pinned" }

# src commit mismatch / unknown
expect-err "src commit mismatch" "full build is required" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit "fedcba9876543210fedcba9876543210fedcba98" --repo $repo }
expect-err "src commit unknown" "/usr/src is at ''" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --repo $repo }
# pack refuses an unpinnable commit and a missing make-vars record
expect-err "pack no commit" "not a hex sha" { pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o5") --src-conf $src_conf --repo $repo --make-vars-file $mvf }
expect-err "pack no make vars" "make variables" { pack-products --obj $obj1 --src $src --arch amd64 --kernconf SMOLFIRE-VM --out-dir ($root | path join "o6") --src-conf $src_conf --src-commit $COMMIT --repo $repo --make-vars-file ($root | path join "nope.json") }

# overlay: a kernconf overlay change (or any non-smolfire-*.conf release/tools file) refuses ...
"ident SMOLFIRE-VM-CHANGED\n" | save -f ($repo | path join "sys" "amd64" "conf" "SMOLFIRE-VM")
expect-err "overlay kernconf changed" "overlay" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }
"ident SMOLFIRE-VM\n" | save -f ($repo | path join "sys" "amd64" "conf" "SMOLFIRE-VM")
"subr v2\n" | save -f ($repo | path join "release" "tools" "vmimage-extra.subr")
expect-err "overlay release/tools changed" "overlay" { unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo }
"subr v1\n" | save -f ($repo | path join "release" "tools" "vmimage-extra.subr")
# ... but the whole point: an image-conf-only edit is still allowed
"image conf v2 (trim list edit)\n" | save -f ($repo | path join "release" "tools" "smolfire-qemu.conf")
let u2 = (unpack-products --obj (fresh) --src $src --arch amd64 --kernconf SMOLFIRE-VM --from-dir $out --src-conf $src_conf --src-commit $COMMIT --repo $repo)
if $u2.pkg_count != 2 { fail "release-conf-only edit must still reassemble" }

# make variables: image-only vars may change, package-affecting ones may not
if (check-make-vars $mm $make_args | is-not-empty) { fail "same make vars flagged" }
let img_only = ($make_args | each {|a| if ($a | str starts-with "VMSIZE=") { "VMSIZE=4g" } else { $a } })
if (check-make-vars $mm $img_only | is-not-empty) { fail "VMSIZE change must be allowed" }
# image profile is image-assembly-only: a dev source run may be reassembled as prod (and vice versa)
let prof_dev  = ($make_args | append "SMOLFIRE_PROFILE=dev")
let prof_prod = ($make_args | append ["SMOLFIRE_PROFILE=prod" "SMOLFIRE_AUTHORIZED_KEYS=/home/x/id_ed25519.pub"])
if (check-make-vars $mm $prof_dev | is-not-empty) { fail "SMOLFIRE_PROFILE=dev must not be pinned" }
if (check-make-vars $mm $prof_prod | is-not-empty) { fail "dev->prod profile switch must be allowed on reassemble" }
if (pkg-make-vars $prof_prod) != (pkg-make-vars $make_args) { fail "profile vars leaked into the recorded package make vars" }
let pk_changed = ($make_args | append "TARGET=arm64")
if (check-make-vars $mm $pk_changed | is-empty) { fail "extra package-affecting make var not caught" }
let pk_changed2 = ($make_args | each {|a| if $a == "KERNCONF=SMOLFIRE-VM" { "KERNCONF=OTHER" } else { $a } })
if (check-make-vars $mm $pk_changed2 | is-empty) { fail "changed KERNCONF make var not caught" }
if (check-make-vars ($mm | reject make_vars) $make_args | is-empty) { fail "manifest without make_vars must be refused" }

# --- 6. dry-run guard --------------------------------------------------------
let clean = "mkdir -p /usr/obj/usr/src/amd64.amd64/release/cw-smolfire-ufs-qcow2\nsh /usr/src/release/scripts/mk-vmimage.sh -C /usr/src/release/tools/vmimage.subr -S /usr/src -c /usr/src/release/tools/smolfire-qemu.conf PKGBASE_REPO_DIR=/usr/obj/usr/src/amd64.amd64/release/pkgbase-repo-dir\ntouch cw-smolfire-ufs-qcow2"
if (dryrun-guard $clean | is-not-empty) { fail "clean dry run flagged" }
let dirty = ($clean + "\nmkdir -p pkgbase-repo\n( make -f Makefile.inc1 -C /usr/src packages REPODIR=/x/pkgbase-repo INCLUDE_PKG_IN_PKGBASE_REPO=YES BOOTSTRAP_PKG_FROM_PORTS=YES )")
if (dryrun-guard $dirty | length) < 1 { fail "packages rebuild not caught by dry-run guard" }
if (dryrun-guard "make -C /usr/src buildworld" | is-empty) { fail "buildworld not caught" }
# fail closed (finding: empty / failed dry run used to pass vacuously)
if (dryrun-verdict $clean 0 | is-not-empty) { fail $"clean dry run refused: (dryrun-verdict $clean 0)" }
if (dryrun-verdict $clean 2 | is-empty) { fail "nonzero make -n exit must be refused" }
if (dryrun-verdict "" 0 | is-empty) { fail "empty dry run must be refused" }
if (dryrun-verdict "\n  \n" 0 | is-empty) { fail "blank dry run must be refused" }
if (dryrun-verdict "make: don't know how to make cloudware-release. Stop\n" 0 | is-empty) { fail "make error text must be refused" }
if (dryrun-verdict "some unrelated\noutput here\n" 0 | is-empty) { fail "unparseable output (no image-assembly marker) must be refused" }
if (dryrun-verdict $dirty 0 | is-empty) { fail "rebuild in dry run must be refused" }
let dfile = ($root | path join "dry.out")
def cli-dry [file: string, --exit-code: int = -1] { if $exit_code == -1 { ^nu bin/reassemble-plan.nu check-dryrun $file | complete } else { ^nu bin/reassemble-plan.nu check-dryrun $file --exit-code $exit_code | complete } }
"" | save -f $dfile
if (cli-dry $dfile --exit-code 0).exit_code == 0 { fail "CLI: empty output accepted" }
if (cli-dry /dev/null --exit-code 0).exit_code == 0 { fail "CLI: /dev/null accepted" }
if (cli-dry ($root | path join "does-not-exist") --exit-code 0).exit_code == 0 { fail "CLI: missing file accepted" }
$clean | save -f $dfile
if (cli-dry $dfile --exit-code 1).exit_code == 0 { fail "CLI: nonzero exit accepted" }
if (cli-dry $dfile).exit_code == 0 { fail "CLI: missing --exit-code accepted" }
"garbage that is not make output\nat all\n" | save -f $dfile
if (cli-dry $dfile --exit-code 0).exit_code == 0 { fail "CLI: unparseable output accepted" }
$dirty | save -f $dfile
if (cli-dry $dfile --exit-code 0).exit_code == 0 { fail "CLI: rebuild accepted" }
$clean | save -f $dfile
let okc = (cli-dry $dfile --exit-code 0)
if $okc.exit_code != 0 { fail $"CLI: clean dry run refused: ($okc.stdout) ($okc.stderr)" }

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

if not ($bs | str contains "--exit-code $dry.exit_code") { fail "build script must pass make -n exit code to check-dryrun" }
if not ($bs | str contains "check-make-vars") { fail "build script must run check-make-vars in reassemble mode" }
let dl = ($steps | where {|s| ($s.name? | default "") == "Reassemble — download source run products" } | first)
if not ($dl.with | get -o artifact-ids | default "" | str contains "artifact_id") { fail "download must select the artifact by exact id" }
if ($dl.with | get -o name) != null { fail "download must not select by name" }
let ship = ($steps | where {|s| ($s.name? | default "") == "Reassemble — ship products into the VM" } | first)
if ($ship.run | str contains "::warning::could not pin") { fail "src pin failure must be fatal" }

rm -rf $root
print "reassemble-plan-test: ok"
