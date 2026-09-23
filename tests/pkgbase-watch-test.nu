#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/pkgbase-watch-test.nu — unit tests for bin/pkgbase-watch.nu
#
# Offline: drives the watch in --fixtures mode against
# tests/fixtures/pkgbase/*.txt (verbatim excerpts of the upstream sources as
# fetched 2026-09-22 — status index, 2026Q1/Q2 reports, ports-mgmt/pkg
# Makefile, src Makefile.inc1 + release/Makefile, Handbook ch. 27.8), then
# mutates copies of the fixtures to exercise every verdict path.
# Run from the repo root: nu tests/pkgbase-watch-test.nu

const FX = "tests/fixtures/pkgbase"

def fail [msg: string] {
    print $"pkgbase-watch-test: FAIL — ($msg)"
    exit 1
}

def --wrapped pw [...args] {
    ^$nu.current-exe bin/pkgbase-watch.nu ...$args | complete
}

def --wrapped pw-json [dir: string, ...extra] {
    let res = (pw --json --fixtures $dir ...$extra)
    {exit: $res.exit_code, out: ($res.stdout | from json), stderr: $res.stderr}
}

# Fresh writable copy of the fixture dir.
def scratch [] {
    let d = (mktemp -d)
    ls $FX | each {|f| cp $f.name $d }
    $d
}

# --- 1. baseline: the recorded 2026-09-22 upstream state -------------------
let base = (pw-json $FX)
if $base.exit != 0 { fail $"fixture run exited ($base.exit): ($base.stderr)" }
let r = $base.out
if $r.schema_version != "v1" { fail "schema_version != v1" }
if $r.pkg_version != "2.8.4" { fail $"pkg_version = ($r.pkg_version), want 2.8.4" }
if $r.pkg_ge_2_7 != true { fail "pkg_ge_2_7 should be true for 2.8.4" }
if $r.custom_kernel_pkgbase.status != "knob" { fail $"status = ($r.custom_kernel_pkgbase.status), want knob" }
if $r.verdict != "keep-source-built" { fail $"verdict = ($r.verdict), want keep-source-built" }
if $r.latest_report != "2026Q2" { fail $"latest_report = ($r.latest_report)" }
if $r.reports_checked != ["2026Q2" "2026Q1"] { fail $"reports_checked = ($r.reports_checked)" }
if not ($r.errors | is-empty) { fail $"unexpected errors: ($r.errors)" }
if $r.provenance.mode != "fixtures" { fail "provenance.mode != fixtures" }
if ($r.provenance.sources | any {|s| $s.sha256 == null }) { fail "a source is missing its sha256" }
if not ($r.checked_at =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { fail "checked_at not RFC3339 UTC" }

let ev = ($r.custom_kernel_pkgbase.evidence | reduce -f {} {|e, acc| $acc | insert $e.check $e.found })
for want in [
    [kernconf_named_kernel_package true]
    [extra_kernconfs_packaged true]
    [standalone_kernel_package_target false]
    [pkg_abi_needs_staged_world true]
    [installkernel_blocked_on_pkgbase true]
    [release_builds_local_pkgbase_repo true]
    [handbook_documents_custom_kernel_pkgbase false]
] {
    if ($ev | get -o $want.0) != $want.1 { fail $"evidence ($want.0) = ($ev | get -o $want.0), want ($want.1)" }
}

# Status-report hits: the 2026Q1 pkgbasify + pkgdist entries and the 2026Q2
# SBOM/pkgbase aside; none is about kernel packages. The 2026Q1 "FreeBSD
# Foundation" team entry is deliberately NOT a hit: it only links to the
# pkgbasify/pkgdist entries (in-page <a href="#..."> cross-references),
# which the parser strips so each project is reported once, by its own entry.
let hits = $r.status_report_hits
let titles = ($hits | get title | sort)
let want_titles = (["More robust pkgbase conversion" "Kernel Benchmark, MAINTAINERS, and pkgdist" "FreeBSD, CRA, EuroBSDCon, and Security Team"] | sort)
if $titles != $want_titles { fail $"status-report hit titles = ($titles | to nuon), want ($want_titles | to nuon)" }
if ("FreeBSD Foundation" in $titles) { fail "cross-reference-only entry (FreeBSD Foundation) must not be a hit" }
let pkgbasify = ($hits | where title == "More robust pkgbase conversion" | first)
if $pkgbasify.terms != ["pkgbase" "pkgbasify"] { fail $"pkgbasify terms = ($pkgbasify.terms)" }
if $pkgbasify.url != "https://www.freebsd.org/status/report-2026-01-2026-03/#_more_robust_pkgbase_conversion" { fail $"hit url = ($pkgbasify.url)" }
if not ($pkgbasify.excerpt =~ 'pkgbasify') { fail "excerpt does not contain the matched term" }
if ($hits | any {|h| $h.kernel_related }) { fail "no baseline hit should be kernel_related" }

# --markdown for humans
let md = (pw --markdown --fixtures $FX)
if $md.exit_code != 0 { fail "--markdown exited non-zero" }
if not ($md.stdout =~ 'verdict: `keep-source-built`') { fail "markdown missing verdict line" }
if not ($md.stdout =~ '\| `standalone_kernel_package_target` \| false \|') { fail "markdown missing evidence table" }

# --from re-renders a saved result without fetching
let saved = (mktemp)
(pw --json --fixtures $FX).stdout | save --force $saved
let rr = (pw --from $saved --markdown)
if $rr.exit_code != 0 { fail $"--from exited ($rr.exit_code): ($rr.stderr)" }
if not ($rr.stdout =~ 'verdict: `keep-source-built`') { fail "--from --markdown did not render the saved verdict" }
rm $saved

# --reports limits the scan
let one = (pw-json $FX --reports 1)
if $one.out.reports_checked != ["2026Q2"] { fail $"--reports 1 checked ($one.out.reports_checked)" }
if ($one.out.status_report_hits | any {|h| $h.quarter != "2026Q2" }) { fail "--reports 1 leaked older hits" }

# --- 2. upstream adds a standalone kernel-package target -> supported -------
let d1 = (scratch)
"\nkernel-packages: .PHONY\n\t${_+_}${MAKE} create-packages-kernel\n" | save --append ($d1 | path join Makefile.inc1.txt)
let s1 = (pw-json $d1).out
if $s1.custom_kernel_pkgbase.status != "supported" { fail $"standalone target: status ($s1.custom_kernel_pkgbase.status)" }
if $s1.verdict != "reevaluate" { fail "standalone target should flip verdict to reevaluate" }

# --- 3. Handbook 27.8 starts documenting KERNCONF -> supported ---------------
let d2 = (scratch)
let hb = ($d2 | path join handbook-cutting-edge.txt)
open --raw $hb | str replace '27.8.3. Manually building pkgbase' '27.8.3. Build a custom kernel package with make packages KERNCONF=MYKERNEL. Manually building pkgbase' | save --force $hb
let s2 = (pw-json $d2).out
if $s2.custom_kernel_pkgbase.status != "supported" { fail $"handbook doc: status ($s2.custom_kernel_pkgbase.status)" }
if $s2.verdict != "reevaluate" { fail "handbook doc should flip verdict to reevaluate" }

# --- 4. a status report talks about custom kernel packages -> reevaluate ----
let d3 = (scratch)
'<h3 id="_pkgbase_kernels">pkgbase custom kernels</h3><p>pkgbase now builds FreeBSD-kernel-&lt;conf&gt; packages for any KERNCONF.</p>' | save --append ($d3 | path join report-2026-04-2026-06.txt)
let s3 = (pw-json $d3).out
if $s3.custom_kernel_pkgbase.status != "knob" { fail "report hit must not change the source-derived status" }
if $s3.verdict != "reevaluate" { fail "kernel-related report hit should flip verdict to reevaluate" }
if not ($s3.status_report_hits | any {|h| $h.kernel_related and $h.title == "pkgbase custom kernels" }) { fail "kernel-related hit not flagged" }

# --- 4b. in-page cross-links alone never make a hit; prose does -----------
let d6 = (scratch)
'<h3 id="_xref_only">Team report</h3><ul><li><p><a href="#_pkgbase_kernels">pkgbase custom kernel packages</a></p></li></ul><h3 id="_prose">Prose entry</h3><p>We shipped pkgdist.</p><p><a href="https://example.org/pkgbase">external pkgbase link</a></p>' | save --append ($d6 | path join report-2026-04-2026-06.txt)
let s6 = (pw-json $d6).out
let t6 = ($s6.status_report_hits | get title)
if ("Team report" in $t6) { fail "entry with only in-page cross-links became a hit" }
if not ("Prose entry" in $t6) { fail "entry mentioning pkgdist in prose was not a hit" }
if $s6.verdict != "keep-source-built" { fail "cross-link text mentioning kernel packages must not trigger reevaluate" }
rm -rf $d6

# --- 5. KERNCONF-named kernel package disappears -> unsupported -------------
let d4 = (scratch)
let inc = ($d4 | path join Makefile.inc1.txt)
open --raw $inc | str replace -a 'PKGNAME "kernel-${INSTALLKERNEL:tl}${flavor}"' 'PKGNAME "kernel${flavor}"' | save --force $inc
let s4 = (pw-json $d4).out
if $s4.custom_kernel_pkgbase.status != "unsupported" { fail $"no named pkg: status ($s4.custom_kernel_pkgbase.status)" }
if $s4.verdict != "keep-source-built" { fail "unsupported should keep-source-built" }

# --- 6. pkg version comparison ---------------------------------------------
for c in [["2.6.2" false] ["2.7" true] ["2.7.0" true] ["2.10.1" true] ["3.0.0" true] ["1.99" false]] {
    let d = (scratch)
    let mk = ($d | path join pkg-Makefile.txt)
    open --raw $mk | str replace -r '(?m)^DISTVERSION=\s*\S+' $"DISTVERSION=\t($c.0)" | save --force $mk
    let o = (pw-json $d).out
    if $o.pkg_version != $c.0 { fail $"pkg_version parse: ($o.pkg_version) != ($c.0)" }
    if $o.pkg_ge_2_7 != $c.1 { fail $"pkg ($c.0) >= 2.7 should be ($c.1)" }
    rm -rf $d
}

# --- 7. a missing source -> exit 2, errors populated, status unknown --------
let d5 = (scratch)
rm ($d5 | path join Makefile.inc1.txt)
let s5 = (pw-json $d5)
if $s5.exit != 2 { fail $"missing source should exit 2, got ($s5.exit)" }
if ($s5.out.errors | is-empty) { fail "missing source not reported in errors" }
if $s5.out.custom_kernel_pkgbase.status != "unknown" { fail "missing Makefile.inc1 should give status unknown" }
if $s5.out.verdict != "keep-source-built" { fail "unknown status must not trigger reevaluate" }

for d in [$d1 $d2 $d3 $d4 $d5] { rm -rf $d }
print "pkgbase-watch-test: ok"
