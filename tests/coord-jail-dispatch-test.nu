# SPDX-License-Identifier: Apache-2.0
# Offline adapter tests: fake agent-jail CLI, no FreeBSD jail/ZFS/host contact.

use ../bin/coord-jail-dispatch.nu [
    network-wanted, verify-executor-pin, valid-contract, normalize-run-result,
    run-args, reply-envelope, mbox-append-prefix, result-record
]
use ../bin/mbox-parse.nu [parse-mbox, extract-toml]
const FIXTURE = path self fixtures/fake-agent-jail.nu

def "assert equal" [left: any, right: any, what: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($what)\nleft: ($left | to nuon)\nright: ($right | to nuon)"}
    }
}
def assert [condition: bool, what: string = ""] {
    if not $condition { error make {msg: $"assert failed: ($what)"} }
}
def make-msg [id: string, body: string] {
    ([
        "From coordinator@smolfire.local Wed Jan  1 00:00:00 2026"
        "From: coordinator@smolfire.local"
        "To: builder@smolfire.local"
        $"Message-ID: ($id)"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}
def run-adapter [spool: string, request_id: string, task_id: string, settings: record] {
    with-env $settings {
        ^$nu.current-exe bin/coord-jail-dispatch.nu dispatch --task-id $task_id --dispatch-id "<coord.1.r1@smolfire.local>" --request-id $request_id --spool $spool | complete
    }
}
def reply [spool: string] {
    let msgs = parse-mbox (open --raw $spool)
    assert equal ($msgs | length) 2 "one request, exactly one reply"
    let last = $msgs | last
    assert equal ($last.headers | get "In-Reply-To") "<coord.1.r1@smolfire.local>"
    assert equal ($last.headers | get "X-Executor") "jail"
    extract-toml $last
}

print "adapter: pure contract, result, network, and argv"
do {
    assert (not (network-wanted []))
    assert (not (network-wanted ["Read" "WebFetch"]))
    assert (network-wanted ["Read" "Network"])
    assert (valid-contract {schema: "agent-jail.executor.contract.v1", canonical_repo: "ryanmaclean/agent-jail", executor: "jail", executor_schema: "v1"})
    assert (not (valid-contract {schema: "wrong"}))
    assert equal (normalize-run-result '{"verdict":"fail","boot_sec":0,"outputs":[],"error":"refused"}' 2 | get verdict) "fail"
    assert equal (normalize-run-result "not JSON" 1 | get verdict) "fail"
    assert equal (normalize-run-result '{"verdict":"pass","boot_sec":0,"outputs":[]}' 1 | get verdict) "fail"
    let args = run-args "t-argv" ["echo hello world" "--looks-like-option"] "/fixture/base" "" "" false 240 "/fixture/root" false
    assert equal ($args | last 3) ["--" "echo hello world" "--looks-like-option"]
    assert (not ("--network" in $args))
    let net_args = run-args "t-argv" ["true"] "/fixture/base" "" "" true 240 "/fixture/root" false
    assert ("--network" in $net_args)
    assert equal (mbox-append-prefix "body\n") "\n"
    let envelope = reply-envelope "t" "<coord.1.r1@smolfire.local>" (result-record "fail" 0 [] "failure") --now "20260101000000"
    assert equal (parse-mbox $envelope | length) 1
    let same_second_a = reply-envelope "t" "<coord.1.r1@smolfire.local>" (result-record "pass" 0 []) --now "20260101000000" --nonce "fixed-for-dispatch-comparison"
    let same_second_b = reply-envelope "t" "<coord.2.r2@smolfire.local>" (result-record "pass" 0 []) --now "20260101000000" --nonce "fixed-for-dispatch-comparison"
    let same_dispatch_retry = reply-envelope "t" "<coord.1.r1@smolfire.local>" (result-record "pass" 0 []) --now "20260101000000" --nonce "another-invocation"
    let id_a = ((parse-mbox $same_second_a | first).headers | get "Message-ID")
    let id_b = ((parse-mbox $same_second_b | first).headers | get "Message-ID")
    let id_retry = ((parse-mbox $same_dispatch_retry | first).headers | get "Message-ID")
    assert ($id_a != $id_b) "same-task same-second distinct dispatches need distinct Message-IDs"
    assert ($id_a != $id_retry) "same dispatch repeated invocation needs distinct Message-IDs"
    assert equal ((parse-mbox $same_second_b | first).headers | get "In-Reply-To") "<coord.2.r2@smolfire.local>"
    let generated_a = reply-envelope "t" "<coord.1.r1@smolfire.local>" (result-record "pass" 0 []) --now "20260101000000"
    let generated_b = reply-envelope "t" "<coord.1.r1@smolfire.local>" (result-record "pass" 0 []) --now "20260101000000"
    assert (((parse-mbox $generated_a | first).headers | get "Message-ID") != ((parse-mbox $generated_b | first).headers | get "Message-ID")) "runtime nonce repeats"
}

let temp = (^mktemp -d | str trim)
let fixture = $FIXTURE
let digest = (open --raw $fixture | hash sha256)
assert (verify-executor-pin $fixture $digest | get ok) "fake fixture pin accepted"
assert (not (verify-executor-pin $fixture "0000000000000000000000000000000000000000000000000000000000000000" | get ok)) "mismatched digest refused"
assert (not (verify-executor-pin "" "" | get ok)) "no installed artifact refused"

print "adapter: missing pin produces exactly one fail reply"
do {
    let spool = [$temp "missing.spool"] | path join
    make-msg "<req.missing@host>" 'task_id = "t-missing"
command = "echo hello"' | save --force $spool
    let run = run-adapter $spool "<req.missing@host>" "t-missing" {AGENT_JAIL_EXECUTOR_PATH: "", AGENT_JAIL_EXECUTOR_SHA256: ""}
    assert equal $run.exit_code 1
    let body = reply $spool
    assert equal $body.verdict "fail"
    assert equal ($body.claims | first | get subject) "jail execution failed or incomplete"
    assert (($body | get -o result.outputs | default []) | is-empty)
    assert ((open --raw $spool) | str contains "\n\nFrom jail-agent@smolfire.local ") "strict mbox separator"
}

print "adapter: pinned fake CLI receives command and explicit network grant"
do {
    let spool = [$temp "success.spool"] | path join
    let log = [$temp "fake-run.json"] | path join
    make-msg "<req.success@host>" 'task_id = "t-success"
tools_required = ["Network"]
[commands]
run = ["echo hello world"]
[context_pointers]
jail_base = "/fixture/base"' | save --force $spool
    let run = run-adapter $spool "<req.success@host>" "t-success" {AGENT_JAIL_EXECUTOR_PATH: $fixture, AGENT_JAIL_EXECUTOR_SHA256: $digest, FAKE_AGENT_LOG: $log, FAKE_AGENT_MODE: ""}
    assert equal $run.exit_code 0 $run.stderr
    let body = reply $spool
    assert equal $body.verdict "pass"
    let seen = open --raw $log | from json
    assert equal $seen.commands ["echo hello world"]
    assert equal $seen.base "/fixture/base"
    assert $seen.network "Network capability forwarded"
}

print "adapter: no Network capability keeps jail networking disabled"
do {
    let spool = [$temp "no-network.spool"] | path join
    let log = [$temp "no-network.json"] | path join
    make-msg "<req.no-network@host>" 'task_id = "t-no-network"
tools_required = ["Read"]
command = "true"
[context_pointers]
jail_base = "/fixture/base"' | save --force $spool
    let run = run-adapter $spool "<req.no-network@host>" "t-no-network" {AGENT_JAIL_EXECUTOR_PATH: $fixture, AGENT_JAIL_EXECUTOR_SHA256: $digest, FAKE_AGENT_LOG: $log, FAKE_AGENT_MODE: ""}
    assert equal $run.exit_code 0 $run.stderr
    assert equal (reply $spool | get verdict) "pass"
    assert (not (open --raw $log | from json | get network)) "network remains off"
}

print "adapter: incompatible contract and malformed run each produce one fail reply"
for mode in ["bad-contract" "bad-json" "fail"] {
    let spool = [$temp $"($mode).spool"] | path join
    make-msg $"<req.($mode)@host>" 'task_id = "t-error"
command = "true"' | save --force $spool
    let run = run-adapter $spool $"<req.($mode)@host>" "t-error" {AGENT_JAIL_EXECUTOR_PATH: $fixture, AGENT_JAIL_EXECUTOR_SHA256: $digest, FAKE_AGENT_MODE: $mode}
    assert equal $run.exit_code 1
    assert equal (reply $spool | get verdict) "fail"
}

print "adapter: missing original request produces one fail reply without invoking agent-jail"
do {
    let spool = [$temp "missing-request.spool"] | path join
    make-msg "<req.other@host>" 'task_id = "t-other"' | save --force $spool
    let run = run-adapter $spool "<req.absent@host>" "t-absent" {AGENT_JAIL_EXECUTOR_PATH: $fixture, AGENT_JAIL_EXECUTOR_SHA256: $digest}
    assert equal $run.exit_code 1
    assert equal (reply $spool | get verdict) "fail"
}

print "adapter: malformed original request fails before invoking agent-jail"
do {
    let spool = [$temp "invalid-request.spool"] | path join
    let log = [$temp "invalid-request-run.json"] | path join
    make-msg "<req.invalid@host>" 'task_id = [' | save --force $spool
    let run = run-adapter $spool "<req.invalid@host>" "t-invalid" {AGENT_JAIL_EXECUTOR_PATH: $fixture, AGENT_JAIL_EXECUTOR_SHA256: $digest, FAKE_AGENT_LOG: $log}
    assert equal $run.exit_code 1
    assert equal (reply $spool | get verdict) "fail"
    assert (not ($log | path exists)) "agent-jail run was not called"
}

^rm -rf $temp
print "coord-jail-dispatch-test: source fixture complete"
