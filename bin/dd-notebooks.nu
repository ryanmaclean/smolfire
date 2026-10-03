#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/dd-notebooks.nu — READ-ONLY inspection of Datadog Notebooks via the
# `pup` CLI (DataDog/pup, pinned v1.24.0). See docs/DATADOG-PUP.md.
#
#   nu bin/dd-notebooks.nu status
#   nu bin/dd-notebooks.nu list [--filter <substr>] [--limit <n>]
#   nu bin/dd-notebooks.nu get <id>
#   nu bin/dd-notebooks.nu audit [--committed <f>] [--proposed <f>] [--filter <s>] [--strict]
#   nu bin/dd-notebooks.nu pup <read-only pup args...>   # allowlisted passthrough
#
# Safety contract (enforced in `validate-argv`, the ONLY gate before the one
# and only external `pup` invocation in `run-pup`):
#   * pup may only be run as: --version | auth status | notebooks search|list
#     | notebooks get <numeric-id>, with a fixed per-command flag allowlist.
#     Everything else (create/update/edit/delete/auth login/--file/--yes/...)
#     is refused with exit 2 BEFORE any process is spawned.
#   * No DD_* value or token is ever printed. Status reports booleans only;
#     all pup stderr is redacted (env values + token-shaped strings).
#   * Nothing is installed or downloaded. Nothing is written to Datadog.
#
# Exit codes: 0 ok | 1 audit --strict found drift/absence | 2 usage, refusal
# or pup missing | 3 credentials unusable / pup call failed.

const PINNED_VERSION = "1.24.0"
const DEFAULT_FILTER = "smolfire"
const GLOBAL_FLAGS = ["--no-agent" "--output" "json"]

# Per-command allowlist. `flags` are value flags; `positional` is the number
# of required positional args (validated numeric for notebooks get).
const ALLOWED = [
    {path: ["auth" "status"], flags: [], positional: 0}
    {path: ["notebooks" "search"], flags: ["--query" "--limit" "--filter" "--sort"], positional: 0}
    {path: ["notebooks" "list"], flags: ["--query" "--limit" "--filter" "--sort"], positional: 0}
    {path: ["notebooks" "get"], flags: [], positional: 1}
]

def install-help []: nothing -> string {
    let v = $PINNED_VERSION
    let base = $"https://github.com/DataDog/pup/releases/download/v($v)"
    [
        $"pup is not installed. This script never auto-installs it. Install pinned v($v) yourself:"
        ""
        $"  curl -fsSLO ($base)/pup_($v)_Linux_x86_64.tar.gz"
        $"  curl -fsSLO ($base)/pup_($v)_checksums.txt"
        $"  grep ' pup_($v)_Linux_x86_64.tar.gz$' pup_($v)_checksums.txt | sha256sum -c -   # must print OK"
        $"  tar -xzf pup_($v)_Linux_x86_64.tar.gz pup && install -m 0755 pup ~/.local/bin/pup"
        ""
        "Then re-run, or point PUP_BIN at the binary. Other platforms: replace Linux_x86_64 with"
        "Linux_arm64, Darwin_arm64 or Darwin_x86_64 (names are listed in the checksums file)."
    ] | str join "\n"
}

# ── redaction ────────────────────────────────────────────────────────────────

def redact [s: string]: nothing -> string {
    mut out = $s
    # 1. literal values of every DD_* environment variable
    let vals = ($env | transpose k v
        | where {|r| ($r.k | str starts-with "DD_") and (($r.v | describe) == "string") and (($r.v | str length) >= 3) }
        | get v | uniq)
    for v in $vals { $out = ($out | str replace --all $v "[REDACTED]") }
    # 2. token-shaped strings that never came from our env
    $out = ($out | str replace --all --regex '(?i)bearer\s+[A-Za-z0-9._~+/=-]+' "Bearer [REDACTED]")
    $out = ($out | str replace --all --regex 'eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+){0,2}' "[REDACTED]")
    $out = ($out | str replace --all --regex '\b[0-9a-fA-F]{32}\b' "[REDACTED]")
    $out = ($out | str replace --all --regex '\b[0-9a-fA-F]{40}\b' "[REDACTED]")
    $out = ($out | str replace --all --regex r#'(?i)((?:dd[-_ ]?)?(?:api|app|application|access)[-_ ]?(?:key|token)[\x22\x27]?\s*[:=]\s*[\x22\x27]?)[^\s\x22\x27,}]+'# "${1}[REDACTED]")
    $out
}

def short [s: string, n: int = 400]: nothing -> string {
    let r = (redact $s | str trim)
    if ($r | str length) > $n { $"($r | str substring 0..<$n)..." } else { $r }
}

def fail [code: int, msg: string]: nothing -> nothing {
    print -e (redact $msg)
    exit $code
}

# ── the allowlist gate ───────────────────────────────────────────────────────

# Returns {ok: bool, reason: string}. Pure: spawns nothing.
def validate-argv [args: list<string>]: nothing -> record {
    if ($args | is-empty) { return {ok: false, reason: "empty pup argument list"} }
    if $args == ["--version"] { return {ok: true, reason: ""} }
    if ($args | length) < 2 {
        return {ok: false, reason: $"refused: '($args | str join ' ')' is not in the read-only allowlist"}
    }
    let head = ($args | first 2)
    let spec = ($ALLOWED | where {|a| $a.path == $head } | get 0? )
    if $spec == null {
        let allowed = ($ALLOWED | each {|a| $a.path | str join " " } | str join ", ")
        return {ok: false, reason: $"refused: 'pup ($head | str join ' ')' is not in the read-only allowlist \(allowed: --version, ($allowed)\)"}
    }
    let rest = ($args | skip 2)
    mut i = 0
    mut positional = []
    while $i < ($rest | length) {
        let tok = ($rest | get $i)
        if ($tok | str starts-with "--") {
            let parts = ($tok | split row --number 2 "=")
            let name = ($parts | first)
            if $name not-in $spec.flags {
                return {ok: false, reason: $"refused: flag '($name)' is not allowed for 'pup ($head | str join ' ')'"}
            }
            mut val = ""
            if ($parts | length) == 2 {
                $val = ($parts | get 1)
            } else {
                $i = $i + 1
                if $i >= ($rest | length) { return {ok: false, reason: $"refused: flag '($name)' needs a value"} }
                $val = ($rest | get $i)
                if ($val | str starts-with "--") {
                    return {ok: false, reason: $"refused: value for '($name)' looks like a flag"}
                }
            }
            if $name == "--limit" {
                if not ($val =~ '^[0-9]{1,4}$') or ($val | into int) < 1 or ($val | into int) > 1000 {
                    return {ok: false, reason: "refused: --limit must be an integer 1..1000"}
                }
            }
        } else {
            $positional = ($positional | append $tok)
        }
        $i = $i + 1
    }
    if ($positional | length) != $spec.positional {
        return {ok: false, reason: $"refused: 'pup ($head | str join ' ')' takes exactly ($spec.positional) positional argument\(s\)"}
    }
    if $head == ["notebooks" "get"] and not (($positional | first) =~ '^[0-9]{1,18}$') {
        return {ok: false, reason: "refused: notebook id must be numeric"}
    }
    {ok: true, reason: ""}
}

def resolve-pup []: nothing -> record {
    let envbin = ($env.PUP_BIN? | default "")
    if $envbin != "" {
        if ($envbin | path type) == "file" { return {ok: true, path: $envbin, via: "PUP_BIN"} }
        return {ok: false, path: null, via: "PUP_BIN", reason: "PUP_BIN is set but does not point to an existing file"}
    }
    let found = (which pup | where type == "external")
    if ($found | is-empty) { return {ok: false, path: null, via: "PATH", reason: "pup not found on PATH"} }
    {ok: true, path: ($found | first | get path), via: "PATH"}
}

# The ONLY place pup is executed. Returns {ok, code, stdout, stderr} with
# stderr already redacted. Refusals exit 2 here, before any spawn.
def run-pup [args: list<string>]: nothing -> record {
    let v = (validate-argv $args)
    if not $v.ok { fail 2 $v.reason }
    let bin = (resolve-pup)
    if not $bin.ok { fail 2 $"($bin.reason)\n\n(install-help)" }
    let full = if $args == ["--version"] { $args } else { $GLOBAL_FLAGS | append $args }
    let path = $bin.path
    let r = ("" | do { ^$path ...$full } | complete)
    {ok: ($r.exit_code == 0), code: $r.exit_code, stdout: $r.stdout, stderr: (short $r.stderr 600)}
}

# Strip the optional agent-mode envelope {status, data, metadata}.
def unwrap-envelope [v: any]: nothing -> any {
    if ($v | describe | str starts-with "record") and ($v.status? == "success") and ($v.data? != null) and ($v.metadata? != null) {
        $v.data
    } else { $v }
}

def parse-json [r: record, what: string]: nothing -> any {
    if not $r.ok {
        let hint = if ($r.stderr =~ '(?i)authentication required|401|403|unauthor|forbidden') { " (credentials unusable; see docs/DATADOG-PUP.md)" } else { "" }
        fail 3 $"pup ($what) failed with exit ($r.code)($hint): ($r.stderr)"
    }
    try { $r.stdout | from json | unwrap-envelope $in } catch {
        fail 3 $"pup ($what) returned non-JSON output: (short $r.stdout 200)"
    }
}

# ── shape tolerance ─────────────────────────────────────────────────────────
# The search response shape is "not published" (pup --help says so); the code
# reads data[] items as JSON:API-ish records and tolerates id/name at either
# the top level or under .attributes. Items it cannot read are COUNTED, never
# silently dropped, so "absent" cannot be a parsing artefact unnoticed.

def search-items [payload: any]: nothing -> list<any> {
    if (($payload | describe) =~ "^(list|table)") { return $payload }
    let d = ($payload.data? | default [])
    if (($d | describe) =~ "^(list|table)") { $d } else { [] }
}

def item-summary [it: any]: nothing -> record {
    if not ($it | describe | str starts-with "record") {
        return {id: null, name: null, modified_at: null, author: null}
    }
    let a = ($it.attributes? | default {})
    {
        id: ($it.id? | default ($a.id? | default null))
        name: ($a.name? | default ($it.name? | default null))
        modified_at: ($a.modified_at? | default ($a.modified? | default ($it.modified_at? | default null)))
        author: ($a.author?.handle? | default ($a.author?.name? | default ($it.author?.handle? | default null)))
    }
}

def norm-name [s: string]: nothing -> string {
    $s | str lowercase | str replace --all --regex '\s+' ' ' | str trim
}

def live-search [filter: string, limit: int]: nothing -> record {
    mut args = ["notebooks" "search" $"--limit=($limit)" "--sort=name"]
    if $filter != "" { $args = ($args | append $"--query=($filter)") }
    let payload = (parse-json (run-pup $args) "notebooks search")
    let raw = (search-items $payload)
    let rows = ($raw | each {|it| item-summary $it })
    let unreadable = ($rows | where name == null | length)
    let total = ($payload.meta?.total? | default null)
    {rows: $rows, raw_count: ($raw | length), unreadable: $unreadable, total: $total}
}

def ensure-credentials []: nothing -> nothing {
    let s = (cred-state)
    if not $s.usable {
        fail 3 $"no usable Datadog credentials: ($s.hint). Supply DD_API_KEY + DD_APP_KEY \(+ DD_SITE\) or DD_ACCESS_TOKEN via the environment; see docs/DATADOG-PUP.md."
    }
}

# Environment-only view (booleans; never values).
def env-creds []: nothing -> record {
    let tok = (($env.DD_ACCESS_TOKEN? | default "") != "")
    let api = (($env.DD_API_KEY? | default "") != "")
    let app = (($env.DD_APP_KEY? | default "") != "")
    let site = (($env.DD_SITE? | default "") != "")
    let method = if $tok { "access_token" } else if $api and $app { "api_keys" } else { "none" }
    let hint = if $method != "none" { "" } else if $api and not $app { "DD_APP_KEY is missing" } else if $app and not $api { "DD_API_KEY is missing" } else { "no DD_ACCESS_TOKEN or DD_API_KEY+DD_APP_KEY in the environment" }
    {DD_ACCESS_TOKEN: $tok, DD_API_KEY: $api, DD_APP_KEY: $app, DD_SITE: $site, env_method: $method, env_hint: $hint}
}

# Credentials as the audit sees them: env vars, or (when pup is present) a
# stored OAuth session reported by `pup auth status`.
def cred-state []: nothing -> record {
    let e = (env-creds)
    mut usable = ($e.env_method != "none")
    mut method = $e.env_method
    mut hint = $e.env_hint
    mut pup_status: any = null
    if (resolve-pup).ok {
        let r = (run-pup ["auth" "status"])
        if $r.ok {
            let j = (try { $r.stdout | from json | unwrap-envelope $in } catch { null })
            if $j != null and ($j | describe | str starts-with "record") {
                $pup_status = {authenticated: ($j.authenticated? | default false), auth_method: ($j.auth_method? | default null), status: ($j.status? | default null)}
                if ($j.authenticated? | default false) and not $usable {
                    $usable = true
                    $method = ($j.auth_method? | default "pup_session")
                    $hint = ""
                }
            }
        }
    }
    {usable: $usable, method: $method, hint: $hint, env: $e, pup_auth_status: $pup_status}
}

# ── local payloads ──────────────────────────────────────────────────────────

def load-local [path: string]: nothing -> record {
    if not ($path | path exists) { fail 2 $"payload file not found: ($path)" }
    let raw = (open --raw $path)
    let d = (try { $raw | from json } catch { fail 2 $"payload is not valid JSON: ($path)" })
    let a = ($d.data?.attributes? | default null)
    if $a == null or ($a.name? == null) or ($a.cells? == null) {
        fail 2 $"payload lacks data.attributes.name / cells: ($path)"
    }
    {
        file: $path
        sha256: ($raw | hash sha256)
        name: $a.name
        status: ($a.status? | default null)
        live_span: ($a.time?.live_span? | default null)
        cells: ($a.cells | each {|c| {type: ($c.attributes?.definition?.type? | default null), text: ($c.attributes?.definition?.text? | default null)} })
    }
}

def lines-of [s: any]: nothing -> list<string> {
    if $s == null { [] } else { $s | str replace --all "\r" "" | lines | each {|l| $l | str trim --right } }
}

def cap-lines [ls: list<string>]: nothing -> list<string> {
    $ls | first 20 | each {|l| if ($l | str length) > 400 { $"($l | str substring 0..<400)..." } else { $l } }
}

# Compare a local payload record against a live (v1 NotebookResponse-shaped) get.
def diff-against-live [local: record, live: any]: nothing -> list<record> {
    let a = ($live.data?.attributes? | default {})
    mut diffs = []
    if ($a.name? | default "" | norm-name $in) != (norm-name $local.name) {
        $diffs = ($diffs | append {field: "name", local: $local.name, live: ($a.name? | default null)})
    }
    if ($a.status? | default null) != $local.status {
        $diffs = ($diffs | append {field: "status", local: $local.status, live: ($a.status? | default null)})
    }
    if ($a.time?.live_span? | default null) != $local.live_span {
        $diffs = ($diffs | append {field: "time.live_span", local: $local.live_span, live: ($a.time?.live_span? | default null)})
    }
    let lcells = ($a.cells? | default [])
    if ($lcells | length) != ($local.cells | length) {
        $diffs = ($diffs | append {field: "cells.count", local: ($local.cells | length), live: ($lcells | length)})
    }
    for i in 0..<([($lcells | length) ($local.cells | length)] | math max) {
        let lc = ($local.cells | get --optional $i)
        let vc = ($lcells | get --optional $i)
        if $lc == null or $vc == null { continue }
        let vtype = ($vc.attributes?.definition?.type? | default null)
        if $vtype != $lc.type {
            $diffs = ($diffs | append {field: $"cells.($i).type", local: $lc.type, live: $vtype})
        }
        let lt = (lines-of $lc.text)
        let vt = (lines-of ($vc.attributes?.definition?.text? | default null))
        if $lt != $vt {
            $diffs = ($diffs | append {
                field: $"cells.($i).text"
                only_in_local: (cap-lines ($lt | where {|l| $l not-in $vt }))
                only_in_live: (cap-lines ($vt | where {|l| $l not-in $lt }))
            })
        }
    }
    $diffs
}

def diff-local-local [a: record, b: record]: nothing -> record {
    let at = (lines-of ($a.cells | get text | str join "\n"))
    let bt = (lines-of ($b.cells | get text | str join "\n"))
    {
        a: $a.file
        b: $b.file
        same_name: ((norm-name $a.name) == (norm-name $b.name))
        identical_text: ($at == $bt)
        lines_only_in_a: ($at | where {|l| $l not-in $bt } | length)
        lines_only_in_b: ($bt | where {|l| $l not-in $at } | length)
    }
}

def print-json [v: any]: nothing -> nothing { print ($v | to json --indent 2) }

def root-dir []: nothing -> string { $env.FILE_PWD | path dirname }

# ── subcommands ─────────────────────────────────────────────────────────────

def main [] {
    print "usage: nu bin/dd-notebooks.nu <status|list|get|audit|pup> ...   (read-only; see docs/DATADOG-PUP.md)"
}

# pup version + whether auth is usable. Prints booleans only, never values.
def "main status" [] {
    let bin = (resolve-pup)
    mut out: any = {
        pup: {found: $bin.ok, resolved_via: $bin.via, pinned_version: $PINNED_VERSION, version: null, version_matches_pin: null}
        credentials: (env-creds)
        usable: false
    }
    if not $bin.ok {
        print-json ($out | insert reason $bin.reason | insert install (install-help))
        exit 2
    }
    let vr = (run-pup ["--version"])
    let ver = if $vr.ok { $vr.stdout | str trim | str replace --regex '^pup\s+' '' } else { null }
    $out = ($out | update pup.version $ver | update pup.version_matches_pin ($ver == $PINNED_VERSION))
    let cs = (cred-state)
    $out = ($out | update usable $cs.usable | insert method $cs.method | insert pup_auth_status $cs.pup_auth_status)
    if not $cs.usable { $out = ($out | insert hint $cs.hint) }
    print-json $out
    if not $cs.usable { exit 3 }
}

# List notebooks whose NAME contains --filter (default "smolfire", case-insensitive).
def "main list" [
    --filter: string = $DEFAULT_FILTER  # name substring; pass "" for all fetched
    --limit: int = 100                  # pup page size, 1..1000
] {
    ensure-credentials
    let s = (live-search $filter $limit)
    let needle = ($filter | str lowercase)
    let hits = ($s.rows | where {|r| $r.name != null and ($needle == "" or (($r.name | str lowercase) | str contains $needle)) })
    print-json {
        filter: $filter
        notebooks: $hits
        meta: {
            fetched: $s.raw_count
            name_matches: ($hits | length)
            content_only_matches: (($s.rows | where {|r| $r.name != null } | length) - ($hits | length))
            unreadable_items: $s.unreadable
            server_total: $s.total
            truncated: ($s.total != null and $s.raw_count < $s.total)
        }
    }
}

# Fetch one notebook by numeric id and print pup's JSON.
def "main get" [id: string] {
    let v = (validate-argv ["notebooks" "get" $id])
    if not $v.ok { fail 2 $v.reason }
    ensure-credentials
    print-json (parse-json (run-pup ["notebooks" "get" $id]) "notebooks get")
}

# Compare committed/proposed payloads with any live notebook of the same name.
def "main audit" [
    --committed: string = ""   # default docs/datadog/smolfire-lower-bound-runtime-notebook.json
    --proposed: string = ""    # default ...notebook.proposed.json when present
    --filter: string = $DEFAULT_FILTER
    --strict                   # exit 1 unless overall == in-sync
] {
    let root = (root-dir)
    let cpath = if $committed != "" { $committed } else { $root | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.json" }
    let ppath = if $proposed != "" { $proposed } else { $root | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.proposed.json" }
    let locals = ([(load-local $cpath)] | append (if ($ppath | path exists) { [(load-local $ppath)] } else { [] }))
    let offline = if ($locals | length) == 2 { diff-local-local ($locals | get 0) ($locals | get 1) } else { null }
    let summary = ($locals | each {|l| {file: $l.file, sha256: $l.sha256, name: $l.name, cells: ($l.cells | length)} })

    let bin = (resolve-pup)
    if not $bin.ok {
        print-json {overall: "unverifiable", reason: $bin.reason, local: $summary, committed_vs_proposed: $offline, install: (install-help)}
        exit 2
    }
    let cs = (cred-state)
    if not $cs.usable {
        print-json {overall: "unverifiable", reason: $"no usable Datadog credentials: ($cs.hint)", local: $summary, committed_vs_proposed: $offline}
        exit 3
    }

    let s = (live-search $filter 200)
    let named = ($s.rows | where name != null)
    mut results = []
    for l in $locals {
        let matches = ($named | where {|r| (norm-name $r.name) == (norm-name $l.name) })
        if ($matches | is-empty) {
            $results = ($results | append {file: $l.file, state: "absent", live: []})
            continue
        }
        mut live = []
        for m in $matches {
            if $m.id == null { $live = ($live | append {id: null, differences: [{field: "id", note: "search result had no readable id"}]}); continue }
            let g = (parse-json (run-pup ["notebooks" "get" ($m.id | into string)]) "notebooks get")
            $live = ($live | append {id: $m.id, differences: (diff-against-live $l $g)})
        }
        let drifted = ($live | any {|x| not ($x.differences | is-empty) })
        let state = if ($live | length) > 1 { "ambiguous" } else if $drifted { "drift" } else { "in-sync" }
        $results = ($results | append {file: $l.file, state: $state, live: $live})
    }

    let c = ($results | first)
    let overall = if $s.unreadable > 0 and $c.state == "absent" { "unverifiable" } else { $c.state }
    print-json {
        overall: $overall
        basis: "committed payload (first file); proposed is informational"
        filter: $filter
        pup_version_pinned: $PINNED_VERSION
        local: $summary
        committed_vs_proposed: $offline
        results: $results
        live_search: {
            fetched: $s.raw_count
            unreadable_items: $s.unreadable
            server_total: $s.total
            truncated: ($s.total != null and $s.raw_count < $s.total)
            same_filter_other_names: ($named | where {|r| not ($locals | any {|l| (norm-name $r.name) == (norm-name $l.name) }) } | select id name)
        }
        note: (if $s.unreadable > 0 { "some search items had no readable name; search response shape is unconfirmed, so absence is not proven" } else { null })
    }
    if $strict and $overall != "in-sync" { exit 1 }
}

# Read-only passthrough to pup. Anything outside the allowlist is refused (exit 2).
def --wrapped "main pup" [...args: string] {
    let r = (run-pup $args)
    if not $r.ok { fail 3 $"pup exited ($r.code): ($r.stderr)" }
    print $r.stdout
}
