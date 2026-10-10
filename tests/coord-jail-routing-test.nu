# SPDX-License-Identifier: Apache-2.0
# Coordinator routing only. The fake claude command prevents billed spawn.

def "assert equal" [left: any, right: any, what: string = ""] {
    if $left != $right { error make {msg: $"assert equal failed ($what)"} }
}
def assert [condition: bool, what: string = ""] {
    if not $condition { error make {msg: $"assert failed: ($what)"} }
}
def make-msg [body: string] {
    ([
        "From coordinator@smolfire.local Wed Jan  1 00:00:00 2026"
        "From: coordinator@smolfire.local"
        "To: builder@smolfire.local"
        "Message-ID: <req.exec.001@host>"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}
def coord-tick-run [tmp: string, body: string, extra: record] {
    let spool = [$tmp "var" "mail" "spool"] | path join
    mkdir ($spool | path dirname)
    make-msg $body | save --force $spool
    let stub = [$tmp "stub-bin"] | path join
    mkdir $stub
    let claude = [$stub "claude"] | path join
    $"#!/bin/sh\necho invoked >> ($tmp)/claude-invoked\nexit 0\n" | save --force $claude
    ^chmod +x $claude
    let env_rec = {PATH: ($env.PATH | prepend $stub)} | merge $extra
    let out = with-env $env_rec {
        ^$nu.current-exe bin/coord-tick.nu --state-file var/run/coord-state.toml --spool var/mail/spool --root $tmp | complete
    }
    let state = open --raw ([$tmp "var" "run" "coord-state.toml"] | path join) | from toml
    {out: $out.stdout, state: $state, spool: (open --raw $spool)}
}

print "routing: default remains vm and tagged"
do {
    let tmp = (^mktemp -d | str trim)
    let r = coord-tick-run $tmp "task_id = \"t-vm\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: ""}
    assert equal $r.state.fsm_state "waiting"
    assert ($r.spool | str contains "executor = \"vm\"")
    assert equal ($r.state.task_executors | get "t-vm" | get executor) "vm"
    ^rm -rf $tmp
}

print "routing: unknown executor refuses without fallback"
do {
    let tmp = (^mktemp -d | str trim)
    let r = coord-tick-run $tmp "task_id = \"t-bad\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: "docker"}
    assert ($r.out | str contains "dispatch_executor_refused")
    assert equal $r.state.fsm_state "idle"
    assert (not ($r.spool | str contains "action = \"dispatch\""))
    ^rm -rf $tmp
}

print "routing: explicit jail refuses off FreeBSD"
do {
    if $nu.os-info.name != "freebsd" {
        let tmp = (^mktemp -d | str trim)
        let r = coord-tick-run $tmp "task_id = \"t-jail\"\nexecutor = \"jail\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: "vm"}
        assert ($r.out | str contains "dispatch_executor_refused")
        assert ($r.out | str contains "requires a FreeBSD host")
        assert equal $r.state.fsm_state "idle"
        ^rm -rf $tmp
    }
}

print "routing: Network capability is checked before dispatch"
do {
    let tmp = (^mktemp -d | str trim)
    let r = coord-tick-run $tmp "task_id = \"t-net\"\nagent_type = \"reviewer\"\ntools_required = [\"Network\"]" {}
    assert ($r.out | str contains "dispatch_capability_mismatch")
    assert (not ([$tmp "claude-invoked"] | path join | path exists))
    ^rm -rf $tmp
}
