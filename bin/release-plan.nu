#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/release-plan.nu — pure logic for .github/workflows/release-image.yml.
#
# Everything here is offline-testable: it consumes JSON that the workflow
# fetched with `gh api` (saved to files) and local files, never the network.
# See docs/RELEASING.md and tests/release-plan-test.nu.
#
# Subcommands (all print JSON/text on stdout; non-zero exit = refuse):
#   validate-tag    <tag>
#   validate-run    --run run.json --compare compare.json [--artifacts a.json --artifact-name N]
#   names           --tag T --arch amd64|aarch64 | --kernel
#   checksums       --dir D            (writes SHA256SUMS + <asset>.sha256 in D)
#   notes           --tag T --dir D [--amd64-run N] [--aarch64-run N] [--kernel-run N]
#                   [--body-file F] [--prerelease]
#   digest-changed  --before before.json --after after.json --name ASSET
#   validate-notes-file <path>   (repo-relative, no .. / absolute / leading -)
#   release-fetch   --assets assets.json --staged-dir D   (names to download, one per line)
#   release-complete --assets assets.json --dir D         (refuse if any release asset is absent from D)
#
# `compare.json` is `gh api repos/O/R/compare/main...<head_sha>`: head_sha is
# an ancestor of (or equal to) main iff status is "behind" or "identical".

# ---- pure helpers ----------------------------------------------------------

export def tag-problems [tag: string]: nothing -> list<string> {
    if ($tag =~ '^v?[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$') { [] } else {
        [$"tag '($tag)' is not a version tag like v0.6.0 or 0.6.0-rc.1"]
    }
}

# Returns a list of refusal reasons; empty list = run is acceptable.
export def run-problems [run: record, compare: record, label: string]: nothing -> list<string> {
    mut errs = []
    let status = ($run | get -o status | default "")
    let concl = ($run | get -o conclusion)
    if $status != "completed" {
        $errs = ($errs | append $"($label): run ($run | get -o id | default '?') status is '($status)', not completed")
    }
    if $concl != "success" {
        $errs = ($errs | append $"($label): run ($run | get -o id | default '?') conclusion is '($concl | default 'null')', not success")
    }
    let sha = ($run | get -o head_sha | default "")
    if ($sha | is-empty) {
        $errs = ($errs | append $"($label): run has no head_sha")
    }
    let cstat = ($compare | get -o status | default "")
    if $cstat not-in ["behind" "identical"] {
        $errs = ($errs | append $"($label): head_sha ($sha) is not an ancestor of main \(compare status '($cstat)'\); GITHUB_TOKEN cannot tag non-main workflow commits — merge first, release a main-built run")
    }
    $errs
}

# notes_file is read from the runner checkout and published: it must stay
# inside the repo and must not be parsed as an option.
export def notes-file-problems [path: string]: nothing -> list<string> {
    mut errs = []
    if ($path | is-empty) { return [] }
    if ($path | str starts-with "-") { $errs = ($errs | append $"notes_file '($path)' starts with '-'") }
    if ($path | str starts-with "/") or ($path =~ '^[A-Za-z]:') { $errs = ($errs | append $"notes_file '($path)' is absolute; use a repo-relative path") }
    if ($path | split row "/" | any {|c| $c == ".." }) { $errs = ($errs | append $"notes_file '($path)' contains '..'") }
    $errs
}

# Release asset names that are checksum products, regenerated every run.
def is-derived [n: string]: nothing -> bool {
    $n == "SHA256SUMS" or ($n | str ends-with ".sha256")
}

# Replace mode: names of existing release assets that must be downloaded
# (everything except derived checksum files and the staged replacements).
export def fetch-list [assets: list, staged: list<string>]: nothing -> list<string> {
    $assets | get name | where {|n| not (is-derived $n) and ($n not-in $staged) }
}

# Replace mode: release assets (minus derived files) missing from `present`.
export def missing-assets [assets: list, present: list<string>]: nothing -> list<string> {
    $assets | get name | where {|n| not (is-derived $n) and ($n not-in $present) }
}

export def artifact-problems [artifacts: record, name: string, label: string]: nothing -> list<string> {
    let hit = ($artifacts | get -o artifacts | default [] | where {|a| $a.name == $name and (($a.expired? | default false) == false)})
    if ($hit | is-empty) {
        [$"($label): no live artifact named '($name)' \(missing or expired\)"]
    } else { [] }
}

export def asset-name [tag: string, arch: string]: nothing -> string {
    $"smolfire-($arch)-($tag).qcow2"
}

export def kernel-asset-name [tag: string]: nothing -> string {
    $"smolfire-kernel-($tag)"
}

# `sha256sum`-format line: "<hex>  <basename>"
export def checksum-line [file: string]: nothing -> string {
    let h = (open --raw $file | hash sha256)
    $"($h)  ($file | path basename)"
}

# Content of the combined SHA256SUMS for the given files (sorted by name).
export def checksums-text [files: list<string>]: nothing -> string {
    let lines = ($files | sort | each {|f| checksum-line $f })
    ($lines | str join "\n") + "\n"
}

# Replace-mode assertion: the asset's digest must differ before vs after.
export def digest-change [before: list, after: list, name: string]: nothing -> record {
    let b = ($before | where name == $name | get -o 0.digest)
    let a = ($after | where name == $name | get -o 0.digest)
    {name: $name, before: $b, after: $a, changed: ($b != null and $a != null and $b != $a)}
}

def mib [f: string]: nothing -> int {
    (ls $f | get 0.size | into int) // 1048576
}

export def notes-text [
    tag: string, dir: string, runs: record, body: string, prerelease: bool,
]: nothing -> string {
    mut out = []
    if ($body | str trim | is-not-empty) { $out = ($out | append [($body | str trim) ""]) }
    $out = ($out | append $"smolfire ($tag)(if $prerelease { ' (pre-release)' } else { '' }) — built from validated hosted-pipeline runs.")
    $out = ($out | append "")
    $out = ($out | append "| Asset | Size | Source run |")
    $out = ($out | append "|---|---|---|")
    for a in [["amd64" ($runs | get -o amd64)] ["aarch64" ($runs | get -o aarch64)]] {
        let f = ($dir | path join (asset-name $tag $a.0))
        if ($f | path exists) {
            $out = ($out | append $"| `(asset-name $tag $a.0)` | (mib $f) MiB | ($a.1) |")
        }
    }
    let k = ($dir | path join (kernel-asset-name $tag))
    if ($k | path exists) {
        $out = ($out | append $"| `(kernel-asset-name $tag)` | (mib $k) MiB | ($runs | get -o kernel) |")
    }
    $out = ($out | append "")
    if ($dir | path join (asset-name $tag "amd64") | path exists) {
        $out = ($out | append "- Download size: compressed qcow2 — boots as-is in any qemu; raw-size target: <= 512 MiB")
        $out = ($out | append $"- Boot \(amd64\): `qemu-system-x86_64 -M q35 -accel kvm -cpu host -m 512M -drive file=(asset-name $tag 'amd64'),format=qcow2,if=virtio -nic user,model=virtio-net-pci -nographic`")
    }
    $out = ($out | append "- Verify checksums: `sha256sum -c SHA256SUMS`")
    $out = ($out | append $"- Verify provenance: `gh attestation verify <asset> --repo <owner>/<repo>` \(see docs/RELEASING.md\)")
    $out = ($out | append "- Login: root / smolfire — **dev image**: change the password on first login; never expose it beyond QEMU user-mode networking.")
    ($out | str join "\n") + "\n"
}

# ---- CLI -------------------------------------------------------------------

def refuse [errs: list<string>] {
    for e in $errs { print -e $"REFUSE: ($e)" }
    exit 1
}

def "main validate-tag" [tag: string] {
    let p = (tag-problems $tag)
    if ($p | is-not-empty) { refuse $p }
    print "ok"
}

def "main validate-run" [
    --run: string, --compare: string, --label: string = "run",
    --artifacts: string, --artifact-name: string,
] {
    let r = (open --raw $run | from json)
    let c = (open --raw $compare | from json)
    mut p = (run-problems $r $c $label)
    if $artifacts != null and $artifact_name != null {
        $p = ($p | append (artifact-problems (open --raw $artifacts | from json) $artifact_name $label))
    }
    if ($p | is-not-empty) { refuse $p }
    {id: $r.id, head_sha: $r.head_sha} | to json -r | print
}

def "main names" [--tag: string, --arch: string, --kernel] {
    if $kernel { print (kernel-asset-name $tag) } else { print (asset-name $tag $arch) }
}

def "main checksums" [--dir: string] {
    let files = (ls $dir | where type == file | get name
        | where {|f| let b = ($f | path basename); $b != "SHA256SUMS" and not ($b | str ends-with ".sha256") })
    if ($files | is-empty) { refuse [$"no assets in ($dir)"] }
    for f in $files { (checksum-line $f) + "\n" | save -f $"($f).sha256" }
    checksums-text $files | save -f ($dir | path join "SHA256SUMS")
    open --raw ($dir | path join "SHA256SUMS") | print -n
}

def "main notes" [
    --tag: string, --dir: string, --amd64-run: string, --aarch64-run: string,
    --kernel-run: string, --body-file: string, --prerelease,
] {
    let body = if $body_file != null { open --raw $body_file } else { "" }
    let runs = {amd64: $amd64_run, aarch64: $aarch64_run, kernel: $kernel_run}
    notes-text $tag $dir $runs $body $prerelease | print -n
}

def "main digest-changed" [--before: string, --after: string, --name: string] {
    let r = (digest-change (open --raw $before | from json) (open --raw $after | from json) $name)
    $r | to json -r | print
    if not $r.changed { refuse [$"asset ($name) digest did not change \(before ($r.before), after ($r.after)\)"] }
}

def "main validate-notes-file" [path: string] {
    let p = (notes-file-problems $path)
    if ($p | is-not-empty) { refuse $p }
    print "ok"
}

def "main release-fetch" [--assets: string, --staged-dir: string] {
    let staged = (ls $staged_dir | get name | each {|f| $f | path basename })
    for n in (fetch-list (open --raw $assets | from json) $staged) { print $n }
}

def "main release-complete" [--assets: string, --dir: string] {
    let present = (ls $dir | get name | each {|f| $f | path basename })
    let m = (missing-assets (open --raw $assets | from json) $present)
    if ($m | is-not-empty) { refuse ($m | each {|n| $"release asset '($n)' missing from checksum set" }) }
    print "ok"
}

def main [] {
    print "usage: nu bin/release-plan.nu <validate-tag|validate-run|names|checksums|notes|digest-changed> ..."
}
