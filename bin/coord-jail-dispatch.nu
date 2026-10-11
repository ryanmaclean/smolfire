#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# smolfire owns dispatch identity and mbox translation; agent-jail owns lifecycle.
# This file deliberately contains no jail(8), rctl(8), zfs(8), or podman calls.

use ./mbox-parse.nu [parse-mbox, extract-toml, msg-id]

const CONTRACT_SCHEMA = "agent-jail.executor.contract.v1"
const DEFAULT_TIMEOUT_SEC = 240
const DEFAULT_JAIL_ROOT = "/var/smolfire/jails"

export def result-record [verdict: string, boot_sec: int, outputs: list, error: string = ""] {
    let r = {verdict: $verdict, boot_sec: $boot_sec, outputs: $outputs}
    if $error == "" { $r } else { $r | insert error $error }
}

# Preserve the former dispatch exit convention for FreeBSD/patch-floor refusal.
export def result-exit [result: record] {
    let err = $result | get -o error | default ""
    if $result.verdict == "pass" { 0
    } else if ($err | str starts-with "jail executor requires a FreeBSD host") or ($err | str starts-with "jail executor requires a patched FreeBSD host") { 2
    } else { 1 }
}

export def network-wanted [tools_required: list<string>] {
    "Network" in $tools_required
}

export def mbox-append-prefix [existing: string] {
    if $existing == "" or ($existing | str ends-with "\n\n") {
        ""
    } else if ($existing | str ends-with "\n") {
        "\n"
    } else {
        "\n\n"
    }
}

# Preserve the existing jail reply envelope and coordinator's claim shape.
export def reply-envelope [task_id: string, dispatch_id: string, result: record, --now: string = "", --nonce: string = ""] {
    let stamp  = if $now == "" { date now | format date "%Y%m%d%H%M%S" } else { $now }
    let dstamp = date now | format date "%a %b %e %H:%M:%S %Y"
    let task_key = $task_id | hash sha256
    let dispatch_key = $dispatch_id | hash sha256
    let unique_key = (if $nonce == "" { random uuid } else { $nonce }) | hash sha256
    let outputs_toml = $result.outputs | each {|o|
        $"  {cmd = ($o.cmd | to json), stdout = ($o.stdout | to json), stderr = ($o.stderr | to json), exit_code = ($o.exit_code)}"
    } | str join ",\n"
    let err = $result | get -o error | default ""
    let error_line = if $err != "" { $"\nX-Jail-Error: ($err | str replace --all "\n" " ")" } else { "" }
    let exit_codes = $result.outputs | get -o exit_code | default [] | each {|c| $c | into string} | str join ","
    let claim_subject = if $result.verdict == "pass" { "jail executed all commands" } else { "jail execution failed or incomplete" }
    $"From jail-agent@smolfire.local ($dstamp)
From: jail-agent@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [($task_id)] jail execution result
Message-ID: <jail.($task_key).($dispatch_key).($stamp).($unique_key)@smolfire.local>
In-Reply-To: ($dispatch_id)
X-Project: smolfire
X-Executor: jail
X-Verdict: ($result.verdict)($error_line)
Content-Type: text/toml; charset=utf-8

task_id = ($task_id | to json)
verdict = ($result.verdict | to json)

[result]
boot_sec = ($result.boot_sec)
outputs = [
($outputs_toml)
]

[[claims]]
kind      = \"command_executed\"
task_id   = ($task_id | to json)
subject   = ($claim_subject | to json)
expected  = \"all commands exit 0\"
evidence  = ($"($result.outputs | length) commands run; exit codes [($exit_codes)]" | to json)
verdict   = ($result.verdict | to json)

"
}

def diag [event: string, payload: record] {
    let row = {ts: (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"), event: $event} | merge $payload
    print -e ($row | to toml)
    print -e "---"
}

# A pin is mandatory. There is deliberately no default path, download, clone,
# checkout search, or fallback to the smolfire lifecycle implementation.
export def verify-executor-pin [script: string, expected_sha256: string] {
    if not ($script | str starts-with "/") {
        return {ok: false, error: "AGENT_JAIL_EXECUTOR_PATH must be an absolute installed path"}
    }
    if not ($expected_sha256 =~ '^[0-9a-fA-F]{64}$') {
        return {ok: false, error: "AGENT_JAIL_EXECUTOR_SHA256 must be a 64-digit pinned digest"}
    }
    if not ($script | path exists) {
        return {ok: false, error: "pinned agent-jail executable is missing"}
    }
    let actual = try { open --raw $script | hash sha256 } catch { "" }
    if ($actual | str lowercase) != ($expected_sha256 | str lowercase) {
        return {ok: false, error: "pinned agent-jail executable digest mismatch"}
    }
    {ok: true, error: ""}
}

# Pure validation of the machine-readable contract printed by agent-jail.
export def valid-contract [value: any] {
    try {
        ($value.schema == $CONTRACT_SCHEMA) and ($value.canonical_repo == "ryanmaclean/agent-jail") and ($value.executor == "jail") and ($value.executor_schema == "v1")
    } catch { false }
}

export def normalize-run-result [stdout: string, exit_code: int, commands: list<string>] {
    let value = try { $stdout | from json } catch {
        return (result-record "fail" 0 [] "agent-jail returned non-JSON result")
    }
    let shape_ok = try {
        let verdict = $value.verdict
        let boot_sec = $value.boot_sec
        let outputs = $value.outputs
        let collection_ok = ($outputs | describe | str starts-with "list") or ($outputs | describe | str starts-with "table")
        let items_ok = ($outputs | each {|o|
            (($o.cmd | describe) == "string") and (($o.stdout | describe) == "string") and (($o.stderr | describe) == "string") and (($o.exit_code | describe) == "int")
        } | all {|x| $x})
        ($verdict in ["pass" "fail"]) and (($boot_sec | describe) == "int") and $collection_ok and $items_ok
    } catch { false }
    if not $shape_ok {
        return (result-record "fail" 0 [] "agent-jail returned invalid result shape")
    }
    if (($exit_code == 0 and $value.verdict != "pass") or ($exit_code != 0 and $value.verdict == "pass") or not ($exit_code in [0 1 2])) {
        return (result-record "fail" 0 [] "agent-jail exit code and result disagree")
    }
    if $value.verdict == "pass" {
        let reported_commands = $value.outputs | each {|o| $o.cmd}
        let nonzero_output = $value.outputs | any {|o| $o.exit_code != 0}
        if (($commands | is-empty) or ($reported_commands != $commands) or $nonzero_output) {
            return (result-record "fail" 0 [] "agent-jail success does not match requested commands")
        }
    }
    $value
}

# Return a flat argv list. Options precede -- so command strings cannot be
# interpreted as a new option by the agent-jail script argument parser.
export def run-args [
    task_id: string
    commands: list<string>
    base: string
    zsnap: string
    image: string
    network: bool
    timeout: int
    jail_root: string
    allow_unpatched: bool
] {
    mut args = ["run" $task_id]
    if $base != "" { $args = [...$args "--base" $base] }
    if $zsnap != "" { $args = [...$args "--zfs-snapshot" $zsnap] }
    if $image != "" { $args = [...$args "--image" $image] }
    if $network { $args = [...$args "--network"] }
    $args = [...$args "--timeout" ($timeout | into string) "--jail-root" $jail_root]
    if $allow_unpatched { $args = [...$args "--allow-unpatched"] }
    [...$args "--" ...$commands]
}

def call-agent [script: string, args: list<string>] {
    try {
        ^$nu.current-exe $script ...$args | complete
    } catch {|e|
        {stdout: "", stderr: ($e | get -o msg | default "agent-jail spawn failed"), exit_code: 127}
    }
}

def run-request [task_id: string, payload: record] {
    let script = $env.AGENT_JAIL_EXECUTOR_PATH? | default ""
    let pin = $env.AGENT_JAIL_EXECUTOR_SHA256? | default ""
    let verified = verify-executor-pin $script $pin
    if not $verified.ok { return (result-record "fail" 0 [] $verified.error) }

    let contract_out = call-agent $script ["contract"]
    if $contract_out.exit_code != 0 {
        return (result-record "fail" 0 [] "pinned agent-jail contract command failed")
    }
    let contract = try { $contract_out.stdout | from json } catch { {} }
    if not (valid-contract $contract) {
        return (result-record "fail" 0 [] "pinned agent-jail contract is incompatible")
    }

    let commands = if ($payload | get -o commands.run | default [] | is-not-empty) {
        $payload | get commands.run
    } else if ($payload | get -o command | default "") != "" {
        [$payload.command]
    } else { [] }
    let cp = $payload | get -o context_pointers | default {}
    let base  = $cp | get -o jail_base         | default ($env.SMOLFIRE_JAIL_BASE? | default "")
    let zsnap = $cp | get -o jail_zfs_snapshot | default ($env.SMOLFIRE_JAIL_ZFS_SNAPSHOT? | default "")
    let image = $cp | get -o jail_image        | default ($env.SMOLFIRE_JAIL_IMAGE? | default "")
    let tools = $payload | get -o tools_required | default []
    let timeout = try {
        $payload | get -o timeout_sec | default ($env.SMOLFIRE_JAIL_TIMEOUT? | default $DEFAULT_TIMEOUT_SEC) | into int
    } catch { return (result-record "fail" 0 [] "invalid jail timeout") }
    let jail_root = $env.SMOLFIRE_JAIL_ROOT? | default $DEFAULT_JAIL_ROOT
    let allow_unpatched = ($env.SMOLFIRE_JAIL_ALLOW_UNPATCHED? | default "") in ["1" "true" "yes"]
    let args = run-args $task_id $commands $base $zsnap $image (network-wanted $tools) $timeout $jail_root $allow_unpatched
    let outcome = call-agent $script $args
    normalize-run-result $outcome.stdout $outcome.exit_code $commands
}

def "main dispatch" [
    --task-id: string
    --dispatch-id: string
    --request-id: string
    --spool: string
] {
    # Keep one result path and one append site. For a readable/writable spool,
    # all caught setup, pin, contract, and run failures become one fail reply.
    let result = try {
        let msgs = parse-mbox (open --raw $spool)
        let req = $msgs | where {|m| (msg-id $m) == $request_id }
        if ($req | is-empty) {
            result-record "fail" 0 [] $"request ($request_id) not found in spool"
        } else if ($req | length) != 1 {
            result-record "fail" 0 [] $"request ($request_id) is not unique in spool"
        } else {
            let payload = extract-toml ($req | first)
            if "_parse_error" in $payload {
                result-record "fail" 0 [] "original jail request has invalid TOML"
            } else if (($task_id == "") or (($payload | get -o task_id | default "") != $task_id)) {
                result-record "fail" 0 [] "original jail request task_id does not match dispatch"
            } else {
                run-request $task_id $payload
            }
        }
    } catch {|e|
        result-record "fail" 0 [] $"jail dispatch setup failed: ($e | get -o msg | default 'unknown error')"
    }
    let existing = if ($spool | path exists) { open --raw $spool } else { "" }
    (mbox-append-prefix $existing) + (reply-envelope $task_id $dispatch_id $result) | save --append $spool
    diag "jail_dispatch_done" {task_id: $task_id, verdict: $result.verdict, boot_sec: $result.boot_sec, error: ($result | get -o error | default "")}
    exit (result-exit $result)
}

def main [] {
    print "coord-jail-dispatch.nu — smolfire mbox adapter for a pinned agent-jail executor"
}
