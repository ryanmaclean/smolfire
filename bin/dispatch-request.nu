#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/dispatch-request.nu — create, validate and execute workflow-dispatch
# request files for .github/workflows/dispatch.yml (see docs/DISPATCH.md).
#
# The SAME validation functions are used locally (`new`, `validate`) and in
# CI (`prepare`, `run`), so the allowlist is unit-testable
# (tests/dispatch-request-test.nu).
#
# Security model: request values are DATA. They are parsed with `from json`,
# validated against a strict allowlist, and passed to `gh` as argv elements or
# as a JSON body on stdin — never through a shell, never interpolated into
# a command string.
#
# Request file (.github/dispatch/<name>.json):
#   { "workflow": "build-image-hosted.yml",   // allowlisted file name
#     "ref": "claude/my-branch",              // an existing branch
#     "inputs": { "arch": "aarch64" },        // must match target's inputs
#     "watch": true,                          // optional, default false
#     "timeout_minutes": 60,                  // optional, 1..360, watch only
#     "requested_at": "2026-10-01T12:00:00Z"} // optional nonce (changes the file)
#
# Usage:
#   nu bin/dispatch-request.nu new --workflow smolfire.yml --ref claude/x --watch tslog=true
#   nu bin/dispatch-request.nu validate .github/dispatch/foo.json

const ALLOWED_WORKFLOWS = ["build-image-hosted.yml" "smolfire.yml" "tpm-hosted.yml"]
const ALLOWED_KEYS = ["workflow" "ref" "inputs" "watch" "timeout_minutes" "requested_at"]
const MAX_INPUTS = 25
const MAX_TIMEOUT_MIN = 360

def reject [msg: string] {
    error make --unspanned { msg: $"dispatch-request: REJECTED — ($msg)" }
}

# Short, safe rendering of an untrusted value for error messages.
def show [v: any]: nothing -> string {
    let s = ($v | to json -r)
    if ($s | str length) > 60 { $"(($s | str substring 0..60))..." } else { $s }
}

def is-record [v: any]: nothing -> bool { ($v | describe | str starts-with "record") }

def has-key [r: record, k: string]: nothing -> bool { ($r | columns | any {|c| $c == $k }) }

export def allowed-workflows []: nothing -> list<string> { $ALLOWED_WORKFLOWS }

# A branch name: conservative subset of git ref-format rules.
export def validate-ref [ref: any]: nothing -> string {
    if ($ref | describe) != "string" { reject $"ref must be a string, got (show $ref)" }
    if ($ref | str length) == 0 or ($ref | str length) > 200 { reject "ref length must be 1..200" }
    if not ($ref =~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
        reject $"ref has characters outside [A-Za-z0-9._/-] or a bad first char: (show $ref)"
    }
    if ($ref | str starts-with "refs/") { reject "ref must be a branch name, not a full refs/ path" }
    if ($ref | str contains "..") { reject "ref must not contain '..'" }
    if ($ref | str ends-with "/") or ($ref | str ends-with ".") { reject "ref must not end with '/' or '.'" }
    for part in ($ref | split row "/") {
        if ($part | is-empty) { reject "ref has an empty path component" }
        if ($part | str starts-with ".") or ($part | str ends-with ".lock") {
            reject $"ref component (show $part) is not a valid branch component"
        }
    }
    $ref
}

# Value charset for free-form (string) inputs: no whitespace, quotes, shell or
# YAML/JSON metacharacters. Deliberately narrower than what GitHub accepts.
def validate-string-value [name: string, v: string]: nothing -> string {
    if ($v | str length) > 128 { reject $"input ($name): value longer than 128 chars" }
    if not ($v =~ '^[A-Za-z0-9._:/@+=,-]*$') {
        reject $"input ($name): value has disallowed characters: (show $v)"
    }
    $v
}

# Declared workflow_dispatch inputs of <dir>/<workflow>, parsed from YAML.
# Returns {dispatchable: bool, inputs: record}.
export def declared-inputs [workflow: string, workflows_dir: string]: nothing -> record {
    let path = ($workflows_dir | path join $workflow)
    if not ($path | path exists) { reject $"target workflow file not found at ref: ($workflow)" }
    let doc = (try { open --raw $path | from yaml } catch { reject $"cannot parse YAML of ($workflow)" })
    # YAML 1.1 parsers may turn the bare key `on` into boolean true.
    let triggers = if (is-record $doc) {
        if (has-key $doc "on") { $doc | get on } else if (has-key $doc "true") { $doc | get true } else { null }
    } else { null }
    if (is-record $triggers) and (has-key $triggers "workflow_dispatch") {
        let wd = ($triggers | get workflow_dispatch)
        let ins = if (is-record $wd) and (has-key $wd "inputs") { $wd | get inputs } else { {} }
        { dispatchable: true, inputs: (if (is-record $ins) { $ins } else { {} }) }
    } else {
        { dispatchable: false, inputs: {} }
    }
}

# Validate one input value against its declaration; returns the string form.
def validate-input [name: string, decl: record, v: any]: nothing -> string {
    let kind = ($v | describe)
    if $kind not-in ["string" "bool" "int"] { reject $"input ($name): value must be string/bool/int, got ($kind)" }
    let s = ($v | into string)
    let type = (if (has-key $decl "type") { $decl.type } else { "string" })
    match $type {
        "boolean" => {
            if $s not-in ["true" "false"] { reject $"input ($name): must be true or false, got (show $v)" }
            $s
        }
        "choice" => {
            let opts = (if (has-key $decl "options") { $decl.options | each {|o| $o | into string } } else { [] })
            if $s not-in $opts { reject $"input ($name): (show $v) is not one of ($opts | str join ', ')" }
            $s
        }
        "number" => {
            if not ($s =~ '^[0-9]{1,12}$') { reject $"input ($name): must be a non-negative integer, got (show $v)" }
            $s
        }
        "string" => { validate-string-value $name $s }
        _ => { reject $"input ($name): declared type '($type)' is not supported by the dispatcher" }
    }
}

# Validate a parsed request record. Returns the normalized record
# {workflow, ref, inputs (all strings), watch, timeout_minutes, requested_at}.
# $branches: when non-null, ref must be a member (unit tests / offline use).
export def validate-request [req: any, workflows_dir: string, --branches: any = null]: nothing -> record {
    if not (is-record $req) { reject "request must be a JSON object" }
    let keys = ($req | columns)
    for k in $keys {
        if $k not-in $ALLOWED_KEYS { reject $"unknown request key (show $k)" }
    }
    for k in ["workflow" "ref"] {
        if $k not-in $keys { reject $"missing required key '($k)'" }
    }
    let wf = $req.workflow
    if ($wf | describe) != "string" or $wf not-in $ALLOWED_WORKFLOWS {
        reject $"workflow (show $wf) is not allowlisted; allowed: ($ALLOWED_WORKFLOWS | str join ', ')"
    }
    let ref = (validate-ref $req.ref)
    if $branches != null and $ref not-in $branches { reject $"ref (show $ref) is not a branch of this repo" }

    let watch = (if "watch" in $keys { $req.watch } else { false })
    if ($watch | describe) != "bool" { reject "watch must be a boolean" }
    let tmo = (if "timeout_minutes" in $keys { $req.timeout_minutes } else { 60 })
    if ($tmo | describe) != "int" or $tmo < 1 or $tmo > $MAX_TIMEOUT_MIN {
        reject $"timeout_minutes must be an integer 1..($MAX_TIMEOUT_MIN)"
    }
    let at = (if "requested_at" in $keys { $req.requested_at } else { "" })
    if ($at | describe) != "string" or not ($at =~ '^[0-9TZ:.+-]{0,40}$') { reject "requested_at must be a short timestamp string" }

    let given = (if "inputs" in $keys { $req.inputs } else { {} })
    if not (is-record $given) { reject "inputs must be an object" }
    if ($given | columns | length) > $MAX_INPUTS { reject $"more than ($MAX_INPUTS) inputs" }

    let target = (declared-inputs $wf $workflows_dir)
    if not $target.dispatchable { reject $"($wf) has no workflow_dispatch trigger at this ref" }
    let decls = $target.inputs
    let declared_names = ($decls | columns)
    mut out = {}
    for name in ($given | columns) {
        if $name not-in $declared_names {
            reject $"input (show $name) is not declared by ($wf); declared: ($declared_names | str join ', ')"
        }
        $out = ($out | insert $name (validate-input $name ($decls | get $name) ($given | get $name)))
    }
    for name in $declared_names {
        let d = ($decls | get $name)
        let required = (is-record $d) and (has-key $d "required") and $d.required == true
        let has_default = (is-record $d) and (has-key $d "default")
        if $required and not $has_default and $name not-in ($out | columns) {
            reject $"required input '($name)' is missing"
        }
    }
    { workflow: $wf, ref: $ref, inputs: $out, watch: $watch, timeout_minutes: $tmo, requested_at: $at }
}

# The JSON body GitHub's workflow-dispatch REST endpoint expects.
export def dispatch-body [req: record]: nothing -> string {
    { ref: $req.ref, inputs: $req.inputs, return_run_details: true } | to json -r
}

def gh-bin []: nothing -> string { $env | get -o DISPATCH_GH | default "gh" }

def gh-ok [args: list<string>]: nothing -> record { do { ^(gh-bin) ...$args } | complete }

def repo-name []: nothing -> string {
    let r = ($env | get -o GITHUB_REPOSITORY | default "")
    if not ($r =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { reject "GITHUB_REPOSITORY missing or malformed" }
    $r
}

def branch-exists [repo: string, ref: string]: nothing -> bool {
    let r = (gh-ok ["api" $"repos/($repo)/git/ref/heads/($ref)" "--jq" ".ref"])
    $r.exit_code == 0 and ($r.stdout | str trim) == $"refs/heads/($ref)"
}

def read-request [file: string]: nothing -> any {
    if not ($file =~ '^[A-Za-z0-9_./-]+$') { reject "request file path has disallowed characters" }
    try { open --raw $file | from json } catch { reject "request file is not valid JSON" }
}

def emit-output [k: string, v: string] {
    let f = ($env | get -o GITHUB_OUTPUT | default "")
    if ($f | is-not-empty) { $"($k)=($v)\n" | save --append $f }
}

def summary [line: string] {
    print $line
    let f = ($env | get -o GITHUB_STEP_SUMMARY | default "")
    if ($f | is-not-empty) { $"($line)\n\n" | save --append $f }
}

# ── CLI ────────────────────────────────────────────────────────────────────

def main [] {
    print "usage: dispatch-request.nu <new|validate|prepare|run> ... (see docs/DISPATCH.md)"
}

# Create (and validate) a request file.
def "main new" [
    --workflow: string,
    --ref: string = "",
    --watch,
    --timeout: int = 60,
    --name: string = "",
    --workflows-dir: string = ".github/workflows",
    --dir: string = ".github/dispatch",
    ...inputs: string,              # key=value pairs
] {
    let ref = if ($ref | is-empty) { (^git branch --show-current | str trim) } else { $ref }
    mut ins = {}
    for kv in $inputs {
        let p = ($kv | parse --regex '^(?<k>[^=]+)=(?<v>.*)$')
        if ($p | is-empty) { reject $"--input entries must be key=value, got (show $kv)" }
        $ins = ($ins | upsert ($p.0.k) ($p.0.v))
    }
    let now = (date now | format date "%Y-%m-%dT%H:%M:%SZ")
    let raw = { workflow: $workflow, ref: $ref, inputs: $ins, watch: $watch, timeout_minutes: $timeout, requested_at: $now }
    let req = (validate-request $raw $workflows_dir)
    let stem = ($workflow | str replace ".yml" "")
    let fname = if ($name | is-empty) { $"(date now | format date '%Y%m%d-%H%M%S')-($stem)" } else { $name }
    if not ($fname =~ '^[A-Za-z0-9._-]{1,80}$') { reject "--name must match [A-Za-z0-9._-]{1,80}" }
    mkdir $dir
    let path = ($dir | path join $"($fname).json")
    $req | to json | save --force $path
    print $"wrote ($path) — commit and push it on a claude/** branch"
}

# Validate an existing request file offline (no branch-existence check).
def "main validate" [file: string, --workflows-dir: string = ".github/workflows"] {
    let req = (validate-request (read-request $file) $workflows_dir)
    print ($req | to json)
}

# CI phase 1: locate the request (push: the single file in the head commit;
# workflow_dispatch: REQUEST_JSON), check structure + ref + branch existence,
# write the request to --out and expose `ref` as a step output. Schema
# validation against the target's inputs happens in `run`, after the target
# ref has been checked out.
def "main prepare" [--pushed-dir: string = "pushed", --out: string] {
    let ev = ($env | get -o DISPATCH_EVENT | default "")
    let raw = if $ev == "push" {
        let files = (^git -C $pushed_dir diff --name-only --diff-filter=AM HEAD^ HEAD -- .github/dispatch | lines | where {|f| $f =~ '^\.github/dispatch/[A-Za-z0-9._-]+\.json$' })
        if ($files | length) != 1 { reject $"push must add/modify exactly one .github/dispatch/*.json request file (found ($files | length))" }
        read-request ($pushed_dir | path join ($files | first))
    } else if $ev == "workflow_dispatch" {
        try { $env | get -o REQUEST_JSON | default "" | from json } catch { reject "request_json input is not valid JSON" }
    } else { reject "unsupported event" }
    if not (is-record $raw) { reject "request must be a JSON object" }
    for k in ($raw | columns) { if $k not-in $ALLOWED_KEYS { reject $"unknown request key (show $k)" } }
    if not (has-key $raw "ref") { reject "missing required key 'ref'" }
    let ref = (validate-ref $raw.ref)
    if not (branch-exists (repo-name) $ref) { reject $"ref (show $ref) is not a branch of this repo" }
    $raw | to json -r | save --force $out
    emit-output "ref" $ref
    print $"prepared request for ref ($ref)"
}

# CI phase 2: full validation against the target ref's workflow YAML, then
# dispatch, print the run URL, optionally wait.
def "main run" [--file: string, --workflows-dir: string = "target/.github/workflows"] {
    let repo = (repo-name)
    let req = (validate-request (read-request $file) $workflows_dir)
    if not (branch-exists $repo $req.ref) { reject $"ref (show $req.ref) is not a branch of this repo" }
    let wf = $req.workflow
    let res = (dispatch-body $req | do { ^(gh-bin) api --method POST -H "X-GitHub-Api-Version: 2022-11-28" $"repos/($repo)/actions/workflows/($wf)/dispatches" --input - } | complete)
    if $res.exit_code != 0 { reject $"dispatch API call failed: ($res.stderr | str trim)" }
    summary $"Dispatched ($wf) on ($req.ref) with inputs ($req.inputs | to json -r)"
    let receipt = try { $res.stdout | from json } catch { reject "dispatch accepted but returned no run details; outcome unknown" }
    if not (is-record $receipt) { reject "dispatch response is not a run-details object" }
    if not (has-key $receipt "workflow_run_id") { reject "dispatch response has no workflow_run_id" }
    if ($receipt.workflow_run_id | describe) != "int" { reject "dispatch response has invalid workflow_run_id" }
    let run_id = $receipt.workflow_run_id
    if $run_id <= 0 { reject "dispatch response has invalid workflow_run_id" }
    let run_url = $"https://github.com/($repo)/actions/runs/($run_id)"
    summary $"Run URL: ($run_url)"
    emit-output "run_url" $run_url
    emit-output "run_id" ($run_id | into string)
    if $req.watch {
        let deadline = ((date now) + ($req.timeout_minutes * 1min))
        let watch_s = ($env | get -o DISPATCH_WATCH_SECONDS | default "30" | into int)
        loop {
            let v = (gh-ok ["run" "view" ($run_id | into string) "-R" $repo "--json" "status,conclusion"])
            if $v.exit_code == 0 {
                let s = ($v.stdout | from json)
                if $s.status == "completed" {
                    summary $"Run finished: ($s.conclusion)"
                    if $s.conclusion != "success" { reject $"dispatched run concluded ($s.conclusion): ($run_url)" }
                    return
                }
            }
            if (date now) > $deadline {
                summary $"Watch timed out after ($req.timeout_minutes) min; run continues: ($run_url)"
                reject "watch timeout"
            }
            sleep ($watch_s * 1sec)
        }
    }
}
