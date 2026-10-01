#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/reassemble-plan.nu — "reassemble" mode for the hosted image build.
#
# WHY: a release-conf-only change (release/tools/smolfire-qemu*.conf) only
# affects the final image assembly (cloudware-release, ~5 min), yet the hosted
# pipeline pays buildworld+buildkernel (~30 min) every time. Reassemble mode
# lets a later run reuse the *package repository* a previous green run built.
#
# WHAT is reusable (verified against releng/15.0 release/Makefile{,.vm} and
# Makefile.inc1, see docs/BUILDING.md "Reassemble mode"):
#   cloudware-release -> cw-smolfire-ufs-qcow2 -> pkgbase-repo-dir -> pkgbase-repo
#   `pkgbase-repo` is a prerequisite-less target (`make packages REPODIR=...`),
#   so make treats an existing directory as up to date; the image is then
#   assembled by pkg-installing from that repo into the chroot (no installworld,
#   no obj tree). The kernel is one of the packages (FreeBSD-kernel-*), built
#   from KERNCONF. So the minimal product set is, relative to the objtop
#   (<obj>/usr/src/<arch>.<march>/):
#     release/pkgbase-repo/          the packages (the bulk; already compressed)
#     release/pkgbase-repo-dir/      FreeBSD-base.conf (file:// url, absolute path)
#     worldstage/usr/bin/uname       PKG_ABI_FILE (ABI probe if make re-derives it)
#   Everything else under /usr/obj (15-40 GiB of objects) is NOT needed.
#
# SAFETY NET: reassembly is only sound if nothing that feeds the packages
# changed. The manifest therefore pins arch, KERNCONF, the hash of the kernconf
# (+ its same-directory includes) and of /etc/src.conf as written by the build
# script's setup stage. unpack refuses on any mismatch (=> run a full build),
# and build-smolfire-vm.nu additionally runs `make -n cloudware-release` and
# aborts if the dry run would rebuild packages (check-dryrun) so a make
# up-to-date surprise fails in seconds instead of silently rebuilding world.
#
# CLI (all logic lives in the exported functions; tests/reassemble-plan-test.nu):
#   nu bin/reassemble-plan.nu plan --reassemble-from-run 123 --arch amd64 --kernconf SMOLFIRE-VM
#   nu bin/reassemble-plan.nu validate-source --run run.json --artifacts arts.json --arch amd64 --kernconf SMOLFIRE-VM
#   nu bin/reassemble-plan.nu pack   --obj /usr/obj --src /usr/src --arch amd64 --kernconf K --out-dir D
#   nu bin/reassemble-plan.nu unpack --obj /usr/obj --src /usr/src --arch amd64 --kernconf K --from-dir D
#   nu bin/reassemble-plan.nu check-dryrun make-n.out

const SCHEMA = 1
const SOURCE_WORKFLOW = "Build smolfire qcow2 compatibility image"
# Conservative cap on the uploaded artifact. GitHub's per-artifact limit is far
# higher but account storage quota (500 MiB on Free) is the real constraint;
# the upstream FreeBSD:15:amd64 base repo is ~1.2 GiB with -dbg/-tests/lib32,
# ~450 MiB without them (measured from pkg.freebsd.org packagesite, 161 pkgs);
# our WITHOUT_* trims land at or below that. 2 GiB = alarm threshold.
const DEFAULT_MAX_BYTES = 2147483648

# ---------------------------------------------------------------- arch helpers

export def arch-info [arch: string]: nothing -> record {
    match $arch {
        "amd64"   => { arch: "amd64",   freebsd: "amd64", march: "amd64" },
        "aarch64" => { arch: "aarch64", freebsd: "arm64", march: "aarch64" },
        "riscv64" => { arch: "riscv64", freebsd: "riscv", march: "riscv64" },
        _ => { error make {msg: $"reassemble: unknown arch '($arch)' [amd64, aarch64, riscv64]"} }
    }
}

export def artifact-name [arch: string, kernconf: string]: nothing -> string {
    $"smolfire-reassemble-($arch)-($kernconf)"
}

def check-kernconf-name [kernconf: string] {
    if ($kernconf | parse --regex '^[A-Za-z0-9_-]+$' | is-empty) {
        error make {msg: $"reassemble: bad kernconf '($kernconf)'"}
    }
}

# ------------------------------------------------------------------------ plan

# Decide which pipeline stages run. Inputs absent (reassemble_from_run == ""
# and emit == false) MUST yield exactly the legacy full pipeline.
export def plan-reassemble [
    --reassemble-from-run: string = ""
    --emit
    --kernel-only
    --arch: string = "amd64"
    --kernconf: string = "SMOLFIRE-VM"
]: nothing -> record {
    let a = (arch-info $arch)
    check-kernconf-name $kernconf
    let rid = ($reassemble_from_run | str trim)
    let reassemble = ($rid != "")
    if $reassemble and ($rid | parse --regex '^[0-9]{1,20}$' | is-empty) {
        error make {msg: $"reassemble: reassemble_from_run must be a numeric run id, got '($rid)'"}
    }
    if $kernel_only and $reassemble {
        error make {msg: "reassemble: kernel_only and reassemble_from_run are mutually exclusive (kernel_only builds no image)"}
    }
    if $kernel_only and $emit {
        error make {msg: "reassemble: kernel_only builds no pkgbase repo, nothing to emit"}
    }
    if $reassemble and $emit {
        error make {msg: "reassemble: emit_reassemble and reassemble_from_run are mutually exclusive (a reassembled run has no new packages to publish)"}
    }
    let mode = if $kernel_only { "kernel-only" } else if $reassemble { "reassemble" } else { "full" }
    {
        mode: $mode
        arch: $a.arch
        kernconf: $kernconf
        build_world: ($mode == "full")
        build_kernel: ($mode == "full" or $mode == "kernel-only")
        build_image: ($mode == "full" or $mode == "reassemble")
        gates: ($mode == "full" or $mode == "reassemble")
        emit: $emit
        source_run: $rid
        artifact_name: (artifact-name $a.arch $kernconf)
        # extra args for `nu bin/build-smolfire-vm.nu`; empty => byte-identical legacy command
        build_flags: (if $reassemble { "--reassemble-from /var/tmp/reassemble" } else { "" })
    }
}

# ------------------------------------------------------------ source-run check

# run: parsed `gh run view <id> --json status,conclusion,workflowName,databaseId`
# artifacts: parsed `gh api repos/<r>/actions/runs/<id>/artifacts` (.artifacts[])
export def validate-source [
    run: record
    artifacts: record
    --arch: string
    --kernconf: string
    --this-run: string = ""
    --max-bytes: int = 2147483648
]: nothing -> record {
    let a = (arch-info $arch)
    check-kernconf-name $kernconf
    let rid = ($run.databaseId? | default "" | into string)
    if $this_run != "" and $rid == $this_run {
        error make {msg: "reassemble: source run is this run"}
    }
    if ($run.status? | default "") != "completed" {
        error make {msg: $"reassemble: source run ($rid) is not completed [status=($run.status? | default 'unknown')]"}
    }
    if ($run.conclusion? | default "") != "success" {
        error make {msg: $"reassemble: source run ($rid) is not green [conclusion=($run.conclusion? | default 'unknown')] — only a successful run is a valid source"}
    }
    if ($run.workflowName? | default "") != $SOURCE_WORKFLOW {
        error make {msg: $"reassemble: source run ($rid) belongs to workflow '($run.workflowName? | default '?')', expected '($SOURCE_WORKFLOW)'"}
    }
    let want = (artifact-name $a.arch $kernconf)
    let hits = ($artifacts.artifacts? | default [] | where name == $want)
    if ($hits | is-empty) {
        let have = ($artifacts.artifacts? | default [] | get name | str join ", ")
        error make {msg: $"reassemble: source run ($rid) has no artifact '($want)' [have: ($have)]. It was built for another arch/kernconf, or without emit_reassemble."}
    }
    let art = ($hits | first)
    if ($art.expired? | default false) {
        error make {msg: $"reassemble: artifact '($want)' of run ($rid) has expired — run a full build with emit_reassemble"}
    }
    let sz = ($art.size_in_bytes? | default 0)
    if $sz > $max_bytes {
        error make {msg: $"reassemble: artifact '($want)' is ($sz) bytes, over the ($max_bytes) cap"}
    }
    { run_id: $rid, artifact: $want, artifact_id: ($art.id? | default null), size_in_bytes: $sz }
}

# ------------------------------------------------------------- input hashing

def sha256-file [path: string]: nothing -> string {
    open --raw $path | hash sha256
}

# Hash of a kernconf plus every `include "x"` it pulls from the same conf dir
# (recursively). *-TSLOG kernconfs include their base; a change there changes
# the kernel package, so it must invalidate reassembly.
export def kernconf-closure-hash [conf_dir: string, kernconf: string]: nothing -> string {
    mut seen = []
    mut todo = [$kernconf]
    while ($todo | is-not-empty) {
        let cur = ($todo | first)
        $todo = ($todo | skip 1)
        if $cur in $seen { continue }
        let p = ($conf_dir | path join $cur)
        if not ($p | path exists) { continue }
        $seen = ($seen | append $cur)
        let incs = (open --raw $p | lines
            | parse --regex '^\s*include\s+"?([^"\s]+)"?'
            | get capture0)
        for i in $incs {
            if not ($i | str contains "/") { $todo = ($todo | append $i) }
        }
    }
    if ($seen | is-empty) {
        error make {msg: $"reassemble: kernconf '($kernconf)' not found in ($conf_dir)"}
    }
    let parts = ($seen | sort | each {|f| $"($f)=(sha256-file ($conf_dir | path join $f))" })
    $parts | str join "\n" | hash sha256
}

def release-objtop [obj: string, arch: string]: nothing -> record {
    let a = (arch-info $arch)
    let rel = $"usr/src/($a.freebsd).($a.march)"
    let top = ($obj | path join $rel)
    { rel: $rel, top: $top }
}

# ------------------------------------------------------------------------ pack

export def pack-products [
    --obj: string
    --src: string
    --arch: string
    --kernconf: string
    --out-dir: string
    --src-conf: string = "/etc/src.conf"
    --src-commit: string = ""
    --smolfire-sha: string = ""
    --max-bytes: int = 2147483648
]: nothing -> record {
    check-kernconf-name $kernconf
    let a = (arch-info $arch)
    let o = (release-objtop $obj $arch)
    let repo = ($o.top | path join "release" "pkgbase-repo")
    let repodir = ($o.top | path join "release" "pkgbase-repo-dir")
    if not ($repo | path exists) {
        let seen = (glob $"($obj)/usr/src/*/release/pkgbase-repo" | str join ", ")
        error make {msg: $"reassemble pack: ($repo) missing [found: ($seen)] — did cloudware-release run?"}
    }
    if not ($"($repodir)/FreeBSD-base.conf" | path exists) {
        error make {msg: $"reassemble pack: ($repodir)/FreeBSD-base.conf missing"}
    }
    let pkgs = (glob $"($repo)/**/*.pkg")
    if ($pkgs | is-empty) {
        error make {msg: $"reassemble pack: no *.pkg under ($repo)"}
    }
    let latest = (glob $"($repo)/*/latest")
    if ($latest | is-empty) {
        error make {msg: $"reassemble pack: no <ABI>/latest in ($repo)"}
    }
    let kernel_pkgs = ($pkgs | each {|p| $p | path basename } | where {|n| $n | str contains "kernel" })
    let uname = ($o.top | path join "worldstage" "usr" "bin" "uname")
    let have_uname = ($uname | path exists)
    mut members = [ "release/pkgbase-repo" "release/pkgbase-repo-dir" ]
    if $have_uname { $members = ($members | append "worldstage/usr/bin/uname") }

    mkdir $out_dir
    let tar_final = ($out_dir | path join "reassemble-products.tar")
    let tar_tmp = $"($tar_final).tmp"
    let mem = $members
    let r = (do { ^tar -cf $tar_tmp -C $o.top ...$mem } | complete)
    if $r.exit_code != 0 {
        rm -f $tar_tmp
        error make {msg: $"reassemble pack: tar failed: ($r.stderr)"}
    }
    let tar_bytes = (ls -l $tar_tmp | get size | first | into int)
    if $tar_bytes > $max_bytes {
        rm -f $tar_tmp
        error make {msg: $"reassemble pack: products are ($tar_bytes) bytes, over the ($max_bytes) cap — not uploading"}
    }
    let tar_sha = (sha256-file $tar_tmp)
    mv -f $tar_tmp $tar_final
    let manifest = {
        schema: $SCHEMA
        arch: $a.arch
        kernconf: $kernconf
        objtop_rel: $o.rel
        members: $members
        pkg_count: ($pkgs | length)
        kernel_pkgs: $kernel_pkgs
        tar: "reassemble-products.tar"
        tar_bytes: $tar_bytes
        tar_sha256: $tar_sha
        src_conf_sha256: (sha256-file $src_conf)
        kernconf_sha256: (kernconf-closure-hash ($src | path join "sys" $a.freebsd "conf") $kernconf)
        src_commit: $src_commit
        smolfire_sha: $smolfire_sha
        created: (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    }
    $manifest | to json | save -f ($out_dir | path join "manifest.json")
    $manifest
}

# ---------------------------------------------------------------------- unpack

# Pure validation of a manifest against the current build inputs.
# Returns the list of problems (empty = ok).
export def check-inputs [
    manifest: record
    --arch: string
    --kernconf: string
    --src-conf-sha256: string
    --kernconf-sha256: string
]: nothing -> list<string> {
    mut p = []
    if ($manifest.schema? | default 0) != $SCHEMA {
        $p = ($p | append $"manifest schema ($manifest.schema? | default 'none') != ($SCHEMA)")
    }
    if ($manifest.arch? | default "") != $arch {
        $p = ($p | append $"arch mismatch: products are ($manifest.arch? | default '?'), requested ($arch)")
    }
    if ($manifest.kernconf? | default "") != $kernconf {
        $p = ($p | append $"kernconf mismatch: products are ($manifest.kernconf? | default '?'), requested ($kernconf)")
    }
    if ($manifest.src_conf_sha256? | default "") != $src_conf_sha256 {
        $p = ($p | append "/etc/src.conf differs from the source run (world knobs changed) — a full build is required")
    }
    if ($manifest.kernconf_sha256? | default "") != $kernconf_sha256 {
        $p = ($p | append "kernconf (or an included conf) differs from the source run — a full build is required")
    }
    let rel = ($manifest.objtop_rel? | default "")
    if ($rel | parse --regex '^usr/src/[A-Za-z0-9_]+\.[A-Za-z0-9_]+$' | is-empty) {
        $p = ($p | append $"unsafe objtop_rel '($rel)'")
    }
    for m in ($manifest.members? | default []) {
        if ($m | str contains "..") or ($m | str starts-with "/") {
            $p = ($p | append $"unsafe member path '($m)'")
        }
    }
    $p
}

export def unpack-products [
    --obj: string
    --src: string
    --arch: string
    --kernconf: string
    --from-dir: string
    --src-conf: string = "/etc/src.conf"
]: nothing -> record {
    check-kernconf-name $kernconf
    let a = (arch-info $arch)
    let mpath = ($from_dir | path join "manifest.json")
    if not ($mpath | path exists) { error make {msg: $"reassemble unpack: ($mpath) missing"} }
    let m = (open --raw $mpath | from json)
    if ($m.arch? | default "") != $a.arch or ($m.kernconf? | default "") != $kernconf {
        # cheap identity check first: the hashes below only make sense for the same arch/kernconf
        let early = (check-inputs $m --arch $a.arch --kernconf $kernconf --src-conf-sha256 "" --kernconf-sha256 "")
        error make {msg: $"reassemble unpack refused:\n  - ($early | first 2 | str join "\n  - ")"}
    }
    let problems = (check-inputs $m --arch $a.arch --kernconf $kernconf
        --src-conf-sha256 (sha256-file $src_conf)
        --kernconf-sha256 (kernconf-closure-hash ($src | path join "sys" $a.freebsd "conf") $kernconf))
    if ($problems | is-not-empty) {
        error make {msg: $"reassemble unpack refused:\n  - ($problems | str join "\n  - ")"}
    }
    let tar = ($from_dir | path join $m.tar)
    if not ($tar | path exists) { error make {msg: $"reassemble unpack: ($tar) missing"} }
    let bytes = (ls -l $tar | get size | first | into int)
    if $bytes != $m.tar_bytes {
        error make {msg: $"reassemble unpack: tar is ($bytes) bytes, manifest says ($m.tar_bytes) — truncated transfer?"}
    }
    if (sha256-file $tar) != $m.tar_sha256 {
        error make {msg: "reassemble unpack: tar sha256 mismatch"}
    }
    let top = ($obj | path join $m.objtop_rel)
    if ($top | path join "release" "pkgbase-repo" | path exists) {
        error make {msg: $"reassemble unpack: ($top)/release/pkgbase-repo already exists — expected a fresh /usr/obj"}
    }
    mkdir $top
    let r = (do { ^tar -xpf $tar -C $top } | complete)
    if $r.exit_code != 0 { error make {msg: $"reassemble unpack: tar -x failed: ($r.stderr)"} }
    # make's up-to-date test: pkgbase-repo-dir must not be older than its
    # prerequisite pkgbase-repo, or make would re-run `make packages` /
    # re-derive PKG_ABI. Touch the repo first, then the dir.
    ^touch ($top | path join "release" "pkgbase-repo")
    ^touch ($top | path join "release" "pkgbase-repo-dir")
    { objtop: $top, pkg_count: $m.pkg_count, tar_bytes: $bytes, src_commit: ($m.src_commit? | default "") }
}

# ------------------------------------------------------------------- dry-run

# `make -n cloudware-release ...` output must not contain any step that would
# rebuild the world/kernel/packages. Returns the offending lines.
export def dryrun-guard [text: string]: nothing -> list<string> {
    let pat = '(-C\s+\S+\s+packages(\s|$))|INCLUDE_PKG_IN_PKGBASE_REPO|\b(buildworld|buildkernel|installworld|installkernel|stageworld|stage-packages|create-packages)\b'
    $text | lines | where {|l| $l =~ $pat }
}

# ------------------------------------------------------------------------- CLI

def main [] {
    print "usage: reassemble-plan.nu plan|validate-source|pack|unpack|check-dryrun (see header)"
}

# Emits key=value lines suitable for >> $GITHUB_OUTPUT
def "main plan" [
    --reassemble-from-run: string = ""
    --emit
    --kernel-only
    --arch: string = "amd64"
    --kernconf: string = "SMOLFIRE-VM"
] {
    let p = (plan-reassemble --reassemble-from-run $reassemble_from_run --emit=$emit --kernel-only=$kernel_only --arch $arch --kernconf $kernconf)
    for kv in ($p | transpose k v) { print $"($kv.k)=($kv.v)" }
}

def "main validate-source" [
    --run: string            # path to `gh run view --json ...` output
    --artifacts: string      # path to `gh api .../artifacts` output
    --arch: string = "amd64"
    --kernconf: string = "SMOLFIRE-VM"
    --this-run: string = ""
    --max-bytes: int = 2147483648
] {
    let r = (validate-source (open --raw $run | from json) (open --raw $artifacts | from json)
        --arch $arch --kernconf $kernconf --this-run $this_run --max-bytes $max_bytes)
    for kv in ($r | transpose k v) { print $"($kv.k)=($kv.v)" }
}

def "main pack" [
    --obj: string = "/usr/obj"
    --src: string = "/usr/src"
    --arch: string = "amd64"
    --kernconf: string = "SMOLFIRE-VM"
    --out-dir: string = "/var/tmp/reassemble-out"
    --src-conf: string = "/etc/src.conf"
    --src-commit: string = ""
    --smolfire-sha: string = ""
    --max-bytes: int = 2147483648
] {
    let m = (pack-products --obj $obj --src $src --arch $arch --kernconf $kernconf --out-dir $out_dir
        --src-conf $src_conf --src-commit $src_commit --smolfire-sha $smolfire_sha --max-bytes $max_bytes)
    print $"reassemble pack: ($m.pkg_count) packages, ($m.tar_bytes) bytes, sha256 ($m.tar_sha256)"
}

def "main unpack" [
    --obj: string = "/usr/obj"
    --src: string = "/usr/src"
    --arch: string = "amd64"
    --kernconf: string = "SMOLFIRE-VM"
    --from-dir: string = "/var/tmp/reassemble"
    --src-conf: string = "/etc/src.conf"
] {
    let r = (unpack-products --obj $obj --src $src --arch $arch --kernconf $kernconf --from-dir $from_dir --src-conf $src_conf)
    print $"reassemble unpack: restored ($r.pkg_count) packages into ($r.objtop) [source src commit: ($r.src_commit)]"
}

def "main check-dryrun" [file: string] {
    let bad = (dryrun-guard (open --raw $file))
    if ($bad | is-not-empty) {
        print "reassemble: dry run would rebuild packages/world — refusing:"
        for l in $bad { print $"  ($l)" }
        error make {msg: "reassemble: make -n cloudware-release is not a pure image assembly (pkgbase-repo not seen as up to date)"}
    }
    print "reassemble: dry run clean (no packages/world/kernel rebuild)"
}
