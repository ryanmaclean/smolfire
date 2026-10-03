#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/dd-notebooks-test.nu — offline subprocess tests for bin/dd-notebooks.nu
#
# Every test runs the script as a child `nu` process against STUB `pup`
# executables written to a temp dir. NO Datadog org, key or network is
# touched; the stub output shapes are modelled on pup 1.24.0 --help and
# source (src/commands/notebooks.rs) and are NOT confirmed against a live
# org (see docs/DATADOG-PUP.md "What is not confirmed").
#
#   nu tests/dd-notebooks-test.nu </dev/null
#
# Auto-discovered by tests/run-all.sh (tests/*-test.nu glob).

def "assert equal" [left: any, right: any, msg?: string] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg | default ''): left=($left | to nuon) right=($right | to nuon)"}
    }
}

def assert [cond: bool, msg?: string] {
    if not $cond { error make {msg: ($msg | default "assert failed")} }
}

let root = ($env.FILE_PWD | path dirname)
let script = ($root | path join "bin" "dd-notebooks.nu")
let committed = ($root | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.json")
let proposed = ($root | path join "docs" "datadog" "smolfire-lower-bound-runtime-notebook.proposed.json")

const SECRET_API = "sekrit-api-0123456789abcdefAAAA"
const SECRET_APP = "sekrit-app-0123456789abcdefBBBB"
const SECRET_SITE = "site.example-redact.test"
const HEX32 = "0123456789abcdef0123456789abcdef"

# Stub pup: logs argv (one line per call) to $STUB_LOG and answers from files
# in $STUB_DIR. STUB_ERR makes every data call fail with that stderr.
const STUB = '#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$*" in
  *--version*) echo "pup 1.24.0"; exit 0 ;;
esac
if [ -n "$STUB_ERR" ]; then echo "$STUB_ERR" >&2; exit 1; fi
case "$*" in
  *"auth status"*) cat "$STUB_DIR/auth.json"; exit 0 ;;
  *"notebooks search"*|*"notebooks list"*) cat "$STUB_DIR/search.json"; exit 0 ;;
  *"notebooks get "*) id=$(echo "$*" | sed "s/.*notebooks get //; s/ .*//"); cat "$STUB_DIR/get-$id.json"; exit 0 ;;
esac
echo "stub: unexpected: $*" >&2
exit 9
'

def mk-sandbox [] {
    let d = (^mktemp -d | str trim)
    $STUB | save --force ($d | path join "pup")
    ^chmod +x ($d | path join "pup")
    '{"authenticated": false, "status": "no token", "site": "datadoghq.com"}' | save --force ($d | path join "auth.json")
    '{"data": [], "meta": {"total": 0}}' | save --force ($d | path join "search.json")
    "" | save --force ($d | path join "log")
    $d
}

def stub-log [d: string]: nothing -> list<string> {
    open --raw ($d | path join "log") | lines | where {|l| $l != "" }
}

# Run the script as a subprocess. `extra` is merged over a clean DD_* env.
def run-dd [d: string, args: list<string>, extra: record = {}] {
    let base = {
        PUP_BIN: ($d | path join "pup")
        STUB_DIR: $d
        STUB_LOG: ($d | path join "log")
        STUB_ERR: ""
        DD_API_KEY: ""
        DD_APP_KEY: ""
        DD_ACCESS_TOKEN: ""
        DD_SITE: ""
    }
    let env_rec = ($base | merge $extra)
    let nu_exe = $nu.current-exe
    let script_path = $script
    with-env $env_rec { "" | do { ^$nu_exe $script_path ...$args } | complete }
}

let creds = {DD_API_KEY: $SECRET_API, DD_APP_KEY: $SECRET_APP, DD_SITE: $SECRET_SITE}

# live notebook fixtures ------------------------------------------------------
def live-get [payload_path: string, id: int]: nothing -> string {
    # v1 NotebookResponse shape: same data.attributes as the create payload plus id.
    let p = (open --raw $payload_path | from json)
    $p | update data ($p.data | insert id $id) | to json
}

def search-one [name: string, id: int]: nothing -> string {
    {data: [{id: ($id | into string), type: "notebooks", attributes: {name: $name, modified_at: "2026-10-01T00:00:00Z", author: {handle: "owner@example.test"}}}], meta: {total: 1}} | to json
}

let committed_name = (open --raw $committed | from json | get data.attributes.name)

# ── 1. pup missing: clear, pinned, checksum-verified install help, no auto-install
print "test: pup missing -> exit 2 with pinned URL + checksum instructions"
do {
    let d = (mk-sandbox)
    let empty = (^mktemp -d | str trim)
    let r = (run-dd $d ["status"] {PUP_BIN: "", PATH: $empty})
    assert equal $r.exit_code 2 "exit"
    for needle in [
        "https://github.com/DataDog/pup/releases/download/v1.24.0/pup_1.24.0_Linux_x86_64.tar.gz"
        "pup_1.24.0_checksums.txt"
        "sha256sum -c"
        "never auto-installs"
    ] { assert ($r.stdout | str contains $needle) $"missing in output: ($needle)" }
    assert equal (stub-log $d | length) 0 "nothing executed"
    let r2 = (run-dd $d ["status"] {PUP_BIN: ($d | path join "nope")})
    assert equal $r2.exit_code 2 "bad PUP_BIN"
    assert ($r2.stdout | str contains "PUP_BIN")
}

# ── 2. read-only allowlist: refusals spawn NOTHING ──────────────────────────
print "test: write/destructive/auth verbs are refused before any spawn"
do {
    let d = (mk-sandbox)
    let bad = [
        ["notebooks" "create" "--file" "x.json"]
        ["notebooks" "update" "1" "--file" "x.json"]
        ["notebooks" "edit" "1" "--file" "x.json"]
        ["notebooks" "delete" "1"]
        ["notebooks" "diff" "1" "x.json"]
        ["notebooks" "annotations" "create" "--file" "x"]
        ["notebooks" "images" "upload" "a.png"]
        ["auth" "login"]
        ["auth" "logout"]
        ["auth" "token"]
        ["monitors" "list"]
        ["notebooks" "get" "1" "--markdown"]
        ["notebooks" "get" "abc"]
        ["notebooks" "get" "1" "2"]
        ["notebooks" "get"]
        ["notebooks" "search" "--yes"]
        ["notebooks" "search" "--file=x.json"]
        ["notebooks" "search" "--limit" "0"]
        ["notebooks" "search" "--limit" "5000"]
        ["notebooks" "search" "--query" "--yes"]
        ["notebooks"]
        ["notebooks" "search" "stray-positional"]
    ]
    for b in $bad {
        let r = (run-dd $d (["pup"] | append $b) $creds)
        assert equal $r.exit_code 2 $"exit for ($b | str join ' ')"
        assert ($r.stderr | str contains "refused") $"no refusal text for ($b | str join ' '): ($r.stderr)"
    }
    assert equal (stub-log $d | length) 0 "stub must never be invoked by a refused command"
}

# ── 3. allowlisted calls reach pup, with safe global flags ──────────────────
print "test: allowlisted read-only calls pass through"
do {
    let d = (mk-sandbox)
    let r = (run-dd $d ["pup" "--version"] $creds)
    assert equal $r.exit_code 0
    assert ($r.stdout | str contains "pup 1.24.0")
    let r2 = (run-dd $d ["pup" "notebooks" "search" "--query" "smolfire" "--limit=5"] $creds)
    assert equal $r2.exit_code 0 $r2.stderr
    let r3 = (run-dd $d ["pup" "notebooks" "get" "42"] $creds)
    assert equal (stub-log $d | length) 3
    assert equal (stub-log $d | get 1) "--no-agent --output json notebooks search --query smolfire --limit=5"
    assert equal (stub-log $d | get 2) "--no-agent --output json notebooks get 42"
}

# ── 3b. mutation proof: without the gate the same refused call DOES execute ─
print "test: mutation — remove the allowlist gate and the refusal test must fail"
do {
    let d = (mk-sandbox)
    let mutated = ($d | path join "dd-mutated.nu")
    let src = (open --raw $script)
    let gate = "    if not $v.ok { fail 2 $v.reason }\n    let bin = (resolve-pup)"
    assert ($src | str contains $gate) "gate anchor not found; update the mutation test"
    $src | str replace $gate "    let bin = (resolve-pup)" | save --force $mutated
    let nu_exe = $nu.current-exe
    let r = (with-env {PUP_BIN: ($d | path join "pup"), STUB_DIR: $d, STUB_LOG: ($d | path join "log"), STUB_ERR: ""} {
        "" | do { ^$nu_exe $mutated pup notebooks delete 1 } | complete
    })
    # the stub answers "unexpected" (exit 9) but the point is that it WAS spawned
    assert equal (stub-log $d | length) 1 "mutated script should have spawned the delete"
    assert ((stub-log $d | first) | str contains "notebooks delete 1")
}

# ── 3c. static: exactly one external pup invocation site ────────────────────
print "test: static — single spawn site, no write verbs invoked"
do {
    let src = (open --raw $script)
    assert equal ($src | split row '^$path ...$full' | length) 2 "exactly one pup spawn site"
    assert equal ($src | split row '^$' | length) 2 "no other dynamic external call"
}

# ── 4. status never prints secrets ──────────────────────────────────────────
print "test: status — booleans only; no secret/site values; exit codes"
do {
    let d = (mk-sandbox)
    let r0 = (run-dd $d ["status"])
    assert equal $r0.exit_code 3 "no creds -> 3"
    let j0 = ($r0.stdout | from json)
    assert equal $j0.usable false
    assert equal $j0.pup.version "1.24.0"
    assert equal $j0.pup.version_matches_pin true
    let r1 = (run-dd $d ["status"] {DD_API_KEY: $SECRET_API})
    assert equal $r1.exit_code 3 "api key without app key"
    assert ($r1.stdout | str contains "DD_APP_KEY is missing")
    let r2 = (run-dd $d ["status"] $creds)
    assert equal $r2.exit_code 0
    let j2 = ($r2.stdout | from json)
    assert equal $j2.usable true
    assert equal $j2.method "api_keys"
    assert equal $j2.credentials.DD_API_KEY true
    for s in [$SECRET_API $SECRET_APP $SECRET_SITE] {
        assert (not ($r2.stdout | str contains $s)) "secret leaked on stdout"
        assert (not ($r2.stderr | str contains $s)) "secret leaked on stderr"
    }
    # OAuth session known only to pup
    '{"authenticated": true, "auth_method": "oauth", "status": "valid", "site": "datadoghq.com"}' | save --force ($d | path join "auth.json")
    let r3 = (run-dd $d ["status"])
    assert equal $r3.exit_code 0
    assert equal ($r3.stdout | from json | get method) "oauth"
    let r4 = (run-dd $d ["status"] {DD_ACCESS_TOKEN: "tok-abcdefghijklmnop"})
    assert equal ($r4.stdout | from json | get credentials.DD_ACCESS_TOKEN) true
    assert (not ($r4.stdout | str contains "tok-abcdefghijklmnop"))
}

# ── 5. error output is redacted ─────────────────────────────────────────────
print "test: pup errors are redacted (env values + token shapes)"
do {
    let d = (mk-sandbox)
    let err = $"HTTP 403 key=($SECRET_API) app ($SECRET_APP) host ($SECRET_SITE) Authorization: Bearer abc.def-ghi_123 id ($HEX32) DD_API_KEY=zzzzzzzzzz {\"api_key\": \"qqqqqqqq1\"}"
    let r = (run-dd $d ["list"] ($creds | insert STUB_ERR $err))
    assert equal $r.exit_code 3
    for s in [$SECRET_API $SECRET_APP $SECRET_SITE "abc.def-ghi_123" $HEX32 "zzzzzzzzzz" "qqqqqqqq1"] {
        assert (not ($r.stderr | str contains $s)) $"leaked ($s): ($r.stderr)"
        assert (not ($r.stdout | str contains $s)) $"leaked on stdout ($s)"
    }
    assert ($r.stderr | str contains "[REDACTED]") "expected redaction marker"
    assert ($r.stderr | str contains "credentials unusable") "auth hint for 403"
}

# ── 6. list ─────────────────────────────────────────────────────────────────
print "test: list filters by name, counts unreadable and content-only hits"
do {
    let d = (mk-sandbox)
    {data: [
        {id: "11", type: "notebooks", attributes: {name: "smolFire — runtime", modified_at: "2026-10-01T00:00:00Z"}}
        {id: "12", type: "notebooks", attributes: {name: "other notebook (cell text mentions the term)"}}
        {id: "13", attributes: {title_only: "x"}}
        {id: 14, name: "SMOLFIRE flat shape"}
    ], meta: {total: 9}} | to json | save --force ($d | path join "search.json")
    let r = (run-dd $d ["list"] $creds)
    assert equal $r.exit_code 0 $r.stderr
    let j = ($r.stdout | from json)
    assert equal ($j.notebooks | get name) ["smolFire — runtime" "SMOLFIRE flat shape"]
    assert equal $j.meta.content_only_matches 1
    assert equal $j.meta.unreadable_items 1
    assert equal $j.meta.truncated true
    assert ((stub-log $d | last) | str contains "--query=smolfire") "default filter smolfire"
    let r2 = (run-dd $d ["list" "--filter" "flat"] $creds)
    assert equal ($r2.stdout | from json | get notebooks | length) 1
    let before = (stub-log $d | where {|l| $l | str contains "notebooks search" } | length)
    let r3 = (run-dd $d ["list"])
    assert equal $r3.exit_code 3 "list without creds"
    assert equal (stub-log $d | where {|l| $l | str contains "notebooks search" } | length) $before "no search without creds"
}

# ── 7. get ──────────────────────────────────────────────────────────────────
print "test: get validates id and prints pup JSON"
do {
    let d = (mk-sandbox)
    live-get $committed 77 | save --force ($d | path join "get-77.json")
    let r = (run-dd $d ["get" "77"] $creds)
    assert equal $r.exit_code 0 $r.stderr
    assert equal ($r.stdout | from json | get data.id) 77
    let r2 = (run-dd $d ["get" "77; rm -rf"] $creds)
    assert equal $r2.exit_code 2
    let r3 = (run-dd $d ["get" "../etc"] $creds)
    assert equal $r3.exit_code 2
}

# ── 8. audit ────────────────────────────────────────────────────────────────
print "test: audit — absent / drift / in-sync / ambiguous / no-creds"
do {
    let d = (mk-sandbox)
    # no credentials: offline comparison still reported, nothing queried
    let r0 = (run-dd $d ["audit"])
    assert equal $r0.exit_code 3
    let j0 = ($r0.stdout | from json)
    assert equal $j0.overall "unverifiable"
    assert equal $j0.committed_vs_proposed.same_name true
    assert equal $j0.committed_vs_proposed.identical_text false
    assert equal ($j0.local | length) 2
    assert equal (stub-log $d | where {|l| $l | str contains "notebooks" } | length) 0

    # absent (the documented real-world state: never published, issue #76)
    let r1 = (run-dd $d ["audit"] $creds)
    assert equal $r1.exit_code 0 $r1.stderr
    let j1 = ($r1.stdout | from json)
    assert equal $j1.overall "absent"
    assert equal ($j1.results | get state) ["absent" "absent"]
    let r1s = (run-dd $d ["audit" "--strict"] $creds)
    assert equal $r1s.exit_code 1 "--strict on absent"

    # live == proposed refresh: committed is stale (drift), proposed is in sync
    search-one $committed_name 5150 | save --force ($d | path join "search.json")
    live-get $proposed 5150 | save --force ($d | path join "get-5150.json")
    let r2 = (run-dd $d ["audit"] $creds)
    assert equal $r2.exit_code 0 $r2.stderr
    let j2 = ($r2.stdout | from json)
    assert equal $j2.overall "drift"
    assert equal ($j2.results | get state) ["drift" "in-sync"]
    let txt = ($j2.results | first | get live | first | get differences | where field == "cells.0.text" | first)
    assert ($txt.only_in_live | any {|l| $l | str contains "240 ms" }) "live (proposed) carries the 240 ms fact"
    assert ($txt.only_in_live | any {|l| $l | str contains "Shipped release reference" }) "0.5.0 image facts only in live"
    assert ($txt.only_in_local | any {|l| $l | str contains "Canonical source" }) "committed line differs"
    let r2s = (run-dd $d ["audit" "--strict"] $creds)
    assert equal $r2s.exit_code 1 "--strict on drift"

    # live == committed
    live-get $committed 5150 | save --force ($d | path join "get-5150.json")
    let r3 = (run-dd $d ["audit" "--strict"] $creds)
    assert equal $r3.exit_code 0
    assert equal ($r3.stdout | from json | get results | get state) ["in-sync" "drift"]

    # two live notebooks with the same name
    {data: [
        {id: "5150", attributes: {name: $committed_name}}
        {id: "5151", attributes: {name: ($committed_name | str uppercase)}}
    ], meta: {total: 2}} | to json | save --force ($d | path join "search.json")
    live-get $committed 5151 | save --force ($d | path join "get-5151.json")
    let r4 = (run-dd $d ["audit"] $creds)
    assert equal ($r4.stdout | from json | get results | first | get state) "ambiguous"

    # unreadable search shape must not be reported as proof of absence
    {data: [{id: "1", attributes: {weird: true}}], meta: {total: 1}} | to json | save --force ($d | path join "search.json")
    let r5 = (run-dd $d ["audit"] $creds)
    assert equal ($r5.stdout | from json | get overall) "unverifiable"

    # audit performed only read-only calls
    for l in (stub-log $d) {
        assert ($l =~ '^--no-agent --output json (auth status|notebooks (search|get))|^--version') $"non-read-only call: ($l)"
    }
}

print "\nall dd-notebooks tests passed"
