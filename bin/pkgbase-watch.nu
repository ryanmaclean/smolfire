#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/pkgbase-watch.nu — issue #39 item 5: can a custom (non-GENERIC)
# kernel such as SMOLFIRE-VM be shipped as a first-class pkgbase package yet?
#
# Replaces the manual "re-check each quarterly status report" watch with a
# structured check. Three upstream sources are read (all public, no creds):
#   1. FreeBSD quarterly status reports  https://www.freebsd.org/status/
#      -> entries mentioning pkgbase / pkgbasify / pkgdist
#   2. ports-mgmt/pkg Makefile (DISTVERSION)  -> pkg version, >= 2.7?
#   3. src Makefile.inc1 + release/Makefile + Handbook ch. 27.8 (pkgbase)
#      -> how a KERNCONF becomes a FreeBSD-kernel-<conf> package, and
#         whether that is documented
#
# Output (default --json): schema v1, see docs/PKGBASE-WATCH.md
#   {schema_version, checked_at, pkg_version, pkg_ge_2_7,
#    custom_kernel_pkgbase: {status, rule, evidence}, status_report_hits,
#    verdict, verdict_reasons, provenance, errors}
#   status  : supported | knob | unsupported | unknown
#   verdict : keep-source-built | reevaluate
#
# Usage:
#   nu bin/pkgbase-watch.nu                   # JSON (default)
#   nu bin/pkgbase-watch.nu --json            # JSON (explicit)
#   nu bin/pkgbase-watch.nu --markdown        # human summary
#   nu bin/pkgbase-watch.nu --fixtures tests/fixtures/pkgbase   # offline
#   nu bin/pkgbase-watch.nu --reports 4       # scan the 4 newest reports
#   nu bin/pkgbase-watch.nu --from r.json --markdown   # re-render, no fetch
#
# Exit 0 = all sources read; 2 = at least one source failed (the JSON is
# still printed, with `errors` populated and affected fields "unknown").
#
# Covered by CI: tests/pkgbase-watch-test.nu (fixture mode, no network).
# Scheduled: .github/workflows/pkgbase-watch.yml (quarterly).

const TOOL_VERSION = "1.0.0"
const STATUS_BASE = "https://www.freebsd.org/status/"
const PKG_MAKEFILE_URL = "https://cgit.freebsd.org/ports/plain/ports-mgmt/pkg/Makefile"
const MAKEFILE_INC1_URL = "https://cgit.freebsd.org/src/plain/Makefile.inc1"
const RELEASE_MAKEFILE_URL = "https://cgit.freebsd.org/src/plain/release/Makefile"
const HANDBOOK_URL = "https://docs.freebsd.org/en/books/handbook/cutting-edge/"

# Terms that make a status-report entry a "hit".
const HIT_RE = '(?i)\b(pkgbase|pkgbasify|pkgdist)\b'
# A hit that also matches this is about kernels-as-packages -> reevaluate.
const KERNEL_RE = '(?i)(custom[ -]kernel|KERNCONF|kernel[ -]packages?\b|FreeBSD-kernel-)'

# ---------------------------------------------------------------------------
# Source loading: network, or a fixture directory with the same content.
# Every load returns {ok, url, text, sha256, bytes, fixture, error}.
# ---------------------------------------------------------------------------
def load [url: string, fixture_dir: string, fixture_name: string] {
    if ($fixture_dir | is-not-empty) {
        let p = ($fixture_dir | path join $fixture_name)
        if not ($p | path exists) {
            return {ok: false, url: $url, text: "", sha256: null, bytes: 0, fixture: $p, error: $"fixture missing: ($p)"}
        }
        let t = (open --raw $p | as-text)
        return {ok: true, url: $url, text: $t, sha256: ($t | hash sha256), bytes: ($t | str length), fixture: $p, error: null}
    }
    try {
        let t = (http get --raw --max-time 60sec $url | as-text)
        {ok: true, url: $url, text: $t, sha256: ($t | hash sha256), bytes: ($t | str length), fixture: null, error: null}
    } catch {|e|
        {ok: false, url: $url, text: "", sha256: null, bytes: 0, fixture: null, error: $"fetch failed: ($e.msg)"}
    }
}

# open --raw / http get --raw return binary or string depending on content
# type and nu version; normalise to string.
def as-text [] {
    let v = $in
    if ($v | describe) == "binary" { $v | decode utf-8 } else { $v }
}

def html-to-text [html: string] {
    $html
        | str replace -a -r '(?s)<script.*?</script>' ' '
        | str replace -a -r '<[^>]+>' ' '
        | str replace -a '&amp;' '&'
        | str replace -a '&lt;' '<'
        | str replace -a '&gt;' '>'
        | str replace -a '&quot;' '"'
        | str replace -a '&#8217;' "'"
        | str replace -a '&#8212;' '-'
        | str replace -a '&nbsp;' ' '
        | str replace -a -r '\s+' ' '
        | str trim
}

# ---------------------------------------------------------------------------
# Parsers (pure: text in, structured out) — these are what the test drives.
# ---------------------------------------------------------------------------

# Status index HTML -> report slugs, newest first.
# Slug form: YYYY-MM-YYYY-MM (e.g. 2026-04-2026-06 = 2026Q2).
export def parse-status-index [html: string] {
    $html
        | parse --regex 'href="(?:/status/)?report-(?<slug>\d{4}-\d{2}-\d{4}-\d{2})/?"'
        | get slug
        | uniq
        | sort --reverse
}

export def slug-quarter [slug: string] {
    let p = ($slug | parse '{y}-{m}-{y2}-{m2}' | first)
    let q = (($p.m | into int) - 1) // 3 + 1
    $"($p.y)Q($q)"
}

# Report HTML -> entries ({anchor, title, text}); one per <h3> section.
export def parse-report-entries [html: string] {
    $html
        | split row '<h3 '
        | skip 1
        | each {|chunk|
            let head = ($chunk | parse --regex '^id="(?<anchor>[^"]*)"[^>]*>(?<title>.*?)</h3>' | get -o 0)
            if $head == null { null } else {
                # Body: after this </h3>, up to the next <h2> (section change).
                let body = ($chunk | str replace -r '(?s)^.*?</h3>' '' | split row '<h2 ' | first)
                {anchor: $head.anchor, title: (html-to-text $head.title), text: (html-to-text $body)}
            }
        }
        | compact
}

# Entries of one report -> hits. Title and body both count.
export def report-hits [slug: string, entries: list<any>] {
    $entries
        | each {|e| $e | insert all $"($e.title) ($e.text)" }
        | where {|e| $e.all =~ $HIT_RE }
        | each {|e|
            # Case-insensitive term list without str downcase/lowercase (the
            # name changed in nu 0.114; CI pins 0.112.2).
            let terms = (["pkgbase" "pkgbasify" "pkgdist"] | where {|t| $e.all =~ $"\(?i\)\\b($t)\\b" })
            let idx = ($e.text | parse --regex $"\(?is\)^\(?<pre>.*?\)($HIT_RE)" | get -o 0.pre | default "" | str length -g)
            let start = ([($idx - 120) 0] | math max)
            {
                report: $slug
                quarter: (slug-quarter $slug)
                title: $e.title
                url: $"($STATUS_BASE)report-($slug)/#($e.anchor)"
                terms: $terms
                kernel_related: ($e.all =~ $KERNEL_RE)
                excerpt: ($e.text | str substring -g $start..($start + 280) | str trim)
            }
        }
}

# ports-mgmt/pkg Makefile -> version string (or null).
export def parse-pkg-version [makefile: string] {
    let dv = ($makefile | parse --regex '(?m)^DISTVERSION=\s*(?<v>\S+)' | get -o 0.v)
    if $dv != null { $dv } else {
        $makefile | parse --regex '(?m)^PORTVERSION=\s*(?<v>\S+)' | get -o 0.v
    }
}

export def version-ge [v: string, min: string] {
    let a = ($v | split row '.' | each {|x| $x | str replace -r '\D.*$' '' | if ($in | is-empty) { 0 } else { into int } })
    let b = ($min | split row '.' | each {|x| $x | into int })
    let n = ([($a | length) ($b | length)] | math max)
    let pa = ($a | append (0..<($n - ($a | length)) | each { 0 }))
    let pb = ($b | append (0..<($n - ($b | length)) | each { 0 }))
    let diffs = ($pa | zip $pb | each {|p| $p.0 - $p.1 } | where {|d| $d != 0 })
    ($diffs | is-empty) or (($diffs | first) > 0)
}

# Makefile.inc1 / release/Makefile / Handbook -> evidence rows + status.
# Rule (also emitted as `rule`):
#   supported   = KERNCONF-named kernel package exists AND (a standalone
#                 kernel-package target exists OR Handbook ch.27.8 documents
#                 KERNCONF for pkgbase)
#   knob        = KERNCONF-named kernel package exists, neither of the above
#   unsupported = no KERNCONF-named kernel package in Makefile.inc1
#   unknown     = Makefile.inc1 could not be read
export def classify-custom-kernel [inc1: record, relmk: record, handbook: record] {
    mut ev = []
    if not $inc1.ok {
        return {status: "unknown", evidence: [{source: $MAKEFILE_INC1_URL, check: "read", found: false, detail: $inc1.error}]}
    }
    let t = $inc1.text
    let named = ($t =~ 'PKGNAME\s+"kernel-\$\{INSTALLKERNEL:tl\}')
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "kernconf_named_kernel_package", found: $named,
        detail: "create-kernel-packages names the package kernel-${INSTALLKERNEL:tl}; INSTALLKERNEL = first KERNCONF, so `make packages KERNCONF=SMOLFIRE-VM` emits FreeBSD-kernel-smolfire-vm"})
    let extra = ($t =~ 'PKGNAME\s+"kernel-\$\{_kernel:tl\}')
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "extra_kernconfs_packaged", found: $extra,
        detail: "2nd..Nth KERNCONF entries (INSTALLEXTRAKERNELS) become kernel-<conf> packages installed to /boot/kernel.<conf>"})
    let standalone = ($t =~ '(?m)^(kernel-packages|packages-kernel|package-kernel|kernel-package|update-kernel-packages)\s*:')
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "standalone_kernel_package_target", found: $standalone,
        detail: "a public target that packages a kernel without a full world package build (absent = custom kernel packages only via full `make packages`)"})
    let needs_world = ($t =~ 'PKG_ABI_FILE\?=\s*\$\{WSTAGEDIR\}')
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "pkg_abi_needs_staged_world", found: $needs_world,
        detail: "PKG_ABI is derived from the staged world's /usr/bin/uname, so kernel packages need buildworld + stage"})
    let guard = ($t =~ 'ALLOW_PKGBASE_INSTALLKERNEL')
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "installkernel_blocked_on_pkgbase", found: $guard,
        detail: "installkernel refuses to overwrite a pkg-owned /boot/kernel unless ALLOW_PKGBASE_INSTALLKERNEL or INSTKERNNAME is set"})
    let defaults = ($t | parse --regex '\.for _k in (?<l>\$\{GENERIC_KERNCONF\}[^\n]*)' | get -o 0.l)
    $ev = ($ev | append {source: $MAKEFILE_INC1_URL, check: "package_building_default_kernconfs", found: ($defaults != null),
        detail: $"PKG_KERNCONF \(official package builds\) = ($defaults | default 'n/a' | str trim) — GENERIC/MINIMAL family only"})

    if $relmk.ok {
        let rel = ($relmk.text =~ 'packages REPODIR=')
        $ev = ($ev | append {source: $RELEASE_MAKEFILE_URL, check: "release_builds_local_pkgbase_repo", found: $rel,
            detail: "release pkgbase-repo target runs `make packages`; KERNCONF on the release command line propagates, so VM/cloudware images install the custom kernel package"})
    } else {
        $ev = ($ev | append {source: $RELEASE_MAKEFILE_URL, check: "release_builds_local_pkgbase_repo", found: null, detail: $relmk.error})
    }

    mut documented = false
    if $handbook.ok {
        # Only the pkgbase chapter (27.8, id=pkgbase .. next h2) counts.
        let chap = ($handbook.text | parse --regex '(?s)<h2 id="?pkgbase"?>(?<c>.*?)(?:<h2 |$)' | get -o 0.c | default "")
        $documented = ((html-to-text $chap) =~ 'KERNCONF')
        $ev = ($ev | append {source: $"($HANDBOOK_URL)#pkgbase", check: "handbook_documents_custom_kernel_pkgbase", found: $documented,
            detail: "Handbook 27.8 (Updating FreeBSD with packages / 27.8.3 building pkgbase locally) mentions KERNCONF"})
    } else {
        $ev = ($ev | append {source: $"($HANDBOOK_URL)#pkgbase", check: "handbook_documents_custom_kernel_pkgbase", found: null, detail: $handbook.error})
    }

    let status = if not $named {
        "unsupported"
    } else if $standalone or $documented {
        "supported"
    } else {
        "knob"
    }
    {status: $status, evidence: $ev}
}

export def decide [status: string, hits: list<any>] {
    mut reasons = []
    if $status == "supported" {
        $reasons = ($reasons | append "custom_kernel_pkgbase.status == supported")
    }
    let kh = ($hits | where kernel_related)
    if not ($kh | is-empty) {
        $reasons = ($reasons | append $"status report entries about kernel packages: ($kh | get title | str join '; ')")
    }
    if ($reasons | is-empty) {
        {verdict: "keep-source-built", reasons: [$"custom_kernel_pkgbase.status == ($status); no status-report entry mentions custom/kernel packages"]}
    } else {
        {verdict: "reevaluate", reasons: $reasons}
    }
}

# ---------------------------------------------------------------------------

def to-markdown [r: record] {
    let ck = $r.custom_kernel_pkgbase
    let ev_rows = ($ck.evidence | each {|e| $"| `($e.check)` | ($e.found) | ($e.detail) |" } | str join "\n")
    let hit_rows = if ($r.status_report_hits | is-empty) { "_none_" } else {
        $r.status_report_hits | each {|h| $"- **($h.quarter)** [($h.title)]\(($h.url)\) — terms: ($h.terms | str join ', ')(if $h.kernel_related { ' — **kernel-related**' } else { '' })" } | str join "\n"
    }
    let err = if ($r.errors | is-empty) { "" } else { $"\n**Errors:** ($r.errors | str join '; ')\n" }
    [
        $"## pkgbase custom-kernel watch — verdict: `($r.verdict)`"
        ""
        $"Checked ($r.checked_at) · latest status report ($r.latest_report | default 'unknown') · pkg ($r.pkg_version | default 'unknown') \(>= 2.7: ($r.pkg_ge_2_7)\)"
        ""
        $"**Custom kernel via pkgbase:** `($ck.status)` — ($ck.rule)"
        ""
        "| check | found | detail |"
        "|---|---|---|"
        $ev_rows
        ""
        $"**Status-report hits** \(pkgbase/pkgbasify/pkgdist, reports: ($r.reports_checked | str join ', ')\):"
        ""
        $hit_rows
        ""
        $"**Why:** ($r.verdict_reasons | str join '; ')"
        $err
    ] | str join "\n"
}

def main [
    --json                      # emit JSON (the default)
    --markdown                  # emit a human-readable Markdown summary
    --fixtures: string = ""     # read sources from this dir instead of the network
    --reports: int = 2          # how many newest status reports to scan
    --from: string = ""         # re-render a saved v1 JSON result (no fetching)
] {
    if ($from | is-not-empty) {
        let saved = (open --raw $from | as-text | from json)
        if $saved.schema_version != "v1" { error make {msg: $"($from): unsupported schema_version ($saved.schema_version)"} }
        if $markdown { print (to-markdown $saved) } else { print ($saved | to json --indent 2) }
        return
    }
    let fx = $fixtures
    let idx = (load $STATUS_BASE $fx "status-index.txt")
    let slugs = if $idx.ok { parse-status-index $idx.text | first $reports } else { [] }
    let reps = ($slugs | each {|s| {slug: $s, src: (load $"($STATUS_BASE)report-($s)/" $fx $"report-($s).txt")} })
    let hits = ($reps | where {|r| $r.src.ok } | each {|r| report-hits $r.slug (parse-report-entries $r.src.text) } | flatten)

    let pkgmk = (load $PKG_MAKEFILE_URL $fx "pkg-Makefile.txt")
    let pkgv = if $pkgmk.ok { parse-pkg-version $pkgmk.text } else { null }
    let ge = if $pkgv == null { null } else { version-ge $pkgv "2.7" }

    let inc1 = (load $MAKEFILE_INC1_URL $fx "Makefile.inc1.txt")
    let relmk = (load $RELEASE_MAKEFILE_URL $fx "release-Makefile.txt")
    let hb = (load $HANDBOOK_URL $fx "handbook-cutting-edge.txt")
    let ck = (classify-custom-kernel $inc1 $relmk $hb)
    let d = (decide $ck.status $hits)

    let sources = ([$idx] ++ ($reps | get src) ++ [$pkgmk $inc1 $relmk $hb])
    let errors = ($sources | where {|s| not $s.ok } | each {|s| $"($s.url): ($s.error)" })
    let errors = if $idx.ok and ($slugs | is-empty) { $errors | append "status index parsed but no report links found" } else { $errors }

    let result = {
        schema_version: "v1"
        checked_at: (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
        pkg_version: $pkgv
        pkg_ge_2_7: $ge
        custom_kernel_pkgbase: {
            status: $ck.status
            rule: "supported = KERNCONF-named kernel pkg AND (standalone kernel-package target OR Handbook 27.8 documents KERNCONF); knob = KERNCONF-named kernel pkg only via full `make packages`; unsupported = no KERNCONF-named kernel pkg"
            evidence: $ck.evidence
        }
        status_report_hits: $hits
        latest_report: (if ($slugs | is-empty) { null } else { slug-quarter ($slugs | first) })
        reports_checked: ($slugs | each {|s| slug-quarter $s })
        verdict: $d.verdict
        verdict_reasons: $d.reasons
        provenance: {
            tool: "bin/pkgbase-watch.nu"
            tool_version: $TOOL_VERSION
            mode: (if ($fx | is-empty) { "network" } else { "fixtures" })
            sources: ($sources | each {|s| {url: $s.url, ok: $s.ok, sha256: $s.sha256, bytes: $s.bytes, fixture: $s.fixture} })
        }
        errors: $errors
    }

    if $markdown {
        print (to-markdown $result)
    } else {
        print ($result | to json --indent 2)
    }
    if not ($errors | is-empty) { exit 2 }
}
