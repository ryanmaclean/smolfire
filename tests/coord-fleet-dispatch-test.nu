# SPDX-License-Identifier: Apache-2.0
# coord-fleet-dispatch-test.nu — coverage for bin/coord-fleet-dispatch.nu and
# the fleet hook in bin/coord-dispatch.nu.
#
# No live hosts: `ssh` (and `timeout`) are stubbed via a PATH shim directory,
# the same pattern as tests/spawn-subagent-test.nu. The stub records argv so
# tests can assert BatchMode=yes is always present (key-auth only, never
# passwords) and simulate pass / fail / timeout exit codes.
#
# The one live test runs only when SMOLFIRE_FLEET_LIVE=1, exercising
# studio@10.0.2.42 (7950x4090pop) end to end. Otherwise it prints
# "(skipped: ...)" — never ": SKIP —", so run-all.sh still counts this file
# as passed.

use ../bin/coord-fleet-dispatch.nu [
    fleet-enabled, resolve-target, capabilities-for, missing-capabilities,
    network-wanted, clamp-timeout, remaining-sec, sh-quote, ssh-base-args,
    resolve-timeout-bin, exec-argv, result-record, attach-warnings,
    reply-envelope, mbox-append-prefix, halt-marker-path, root-for-spool,
    task-halted?, preflight-target, run-fleet-task, result-exit,
]
use ../bin/mbox-parse.nu [parse-mbox, extract-toml, msg-id]

def "assert equal" [left: any, right: any, msg: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($msg)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, msg: string = "assert failed"] {
    if not $cond { error make {msg: $msg} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

# Write stub `ssh` + stub `timeout` into $dir. Stub ssh appends argv to
# $dir/ssh.log, exits 0 (echoing a marker) unless the payload mentions
# fail-cmd (exit 1) or timeout-cmd (exit 124). Stub timeout drops `-k 5 N`
# and execs the rest, so the wrapper path is exercised for real.
def write-ssh-stub [dir: string] {
    let log = [$dir, "ssh.log"] | path join
    let ssh_stub = [$dir, "ssh"] | path join
    $"#!/bin/sh\nlog=\"($log)\"\necho \"$@\" >> \"$log\"\nlast=\"\"\nfor a in \"$@\"; do last=\"$a\"; done\ncase \"$last\" in\n  *fail-cmd*) echo \"stub stderr msg\" >&2; exit 1 ;;\n  *timeout-cmd*) echo \"stub timed out\" >&2; exit 124 ;;\nesac\necho \"stub-stdout for: $last\"\nexit 0\n" | save --force $ssh_stub
    ^chmod +x $ssh_stub
    let timeout_stub = [$dir, "timeout"] | path join
    "#!/bin/sh\nif [ \"$1\" = \"-k\" ]; then shift 2; fi\nshift\nexec \"$@\"\n" | save --force $timeout_stub
    ^chmod +x $timeout_stub
    $log
}

# PATH shim with stub ssh/timeout first, but `nu` still reachable for
# subprocess `nu` invocations.
def with-stub-path [stub_dir: string, body: closure] {
    with-env {PATH: ([$stub_dir] | append ($env.PATH | split row ":" | where {|d| $d != "" }) | str join ":")} { do $body }
}

# ── pure: target resolution ───────────────────────────────────────────────────

print "test: resolve-target accepts user@host"
assert equal (resolve-target "studio@10.0.2.42" | get error) "" "user@host"
assert equal (resolve-target "studio@10.0.2.42" | get target) "studio@10.0.2.42" "target echo"

print "test: resolve-target accepts bare host with --user"
let r = resolve-target "10.0.2.42" --user "studio"
assert equal $r.error "" "bare host error"
assert equal $r.target "studio@10.0.2.42" "bare host join"

print "test: resolve-target refuses empty input"
assert ((resolve-target "" | get error) | str starts-with "no fleet target") "empty target"

print "test: resolve-target refuses the MiSTer gaming box"
let m1 = resolve-target "root@10.0.2.61"
assert ($m1.error | str contains "MiSTer") "mister user@host"
let m2 = resolve-target "10.0.2.61" --user "root"
assert ($m2.error | str contains "MiSTer") "mister bare host"

print "test: resolve-target refuses unsafe characters"
assert ((resolve-target 'a;rm -rf@h' | get error) != "") "bad user"
assert ((resolve-target 'u@h$evil' | get error) != "") "bad host"

# ── pure: capabilities (S-004) ────────────────────────────────────────────────

print "test: known compute host declares Network; unknown hosts do not"
assert ("Network" in (capabilities-for "10.0.2.42")) "known has Network"
assert (not ("Network" in (capabilities-for "10.0.9.9"))) "unknown lacks Network"
assert equal (missing-capabilities "10.0.2.42" ["Bash", "Network"]) [] "known satisfies"
assert equal (missing-capabilities "10.0.9.9" ["Bash", "Network"]) ["Network"] "unknown refuses Network"
assert (network-wanted ["Bash", "Network"]) "network-wanted"
assert (not (network-wanted ["Bash"])) "no network-wanted"

print "test: fleet-enabled gate defaults OFF"
do {
    hide-env -i SMOLFIRE_FLEET_ENABLE
    assert (not (fleet-enabled)) "default off"
}
do {
    with-env {SMOLFIRE_FLEET_ENABLE: "1"} { assert (fleet-enabled) "opt-in on" }
}

# ── pure: timeout / quoting / argv ────────────────────────────────────────────

print "test: clamp-timeout bounds into [1, 270]"
assert equal (clamp-timeout 240) 240 "in range"
assert equal (clamp-timeout 0) 1 "floor"
assert equal (clamp-timeout 9999) 270 "ceiling"

print "test: remaining-sec never negative"
assert equal (remaining-sec 100 90) 0 "ns math floor"
assert ((remaining-sec 200_000_000_000 0) > 100) "positive budget"

print "test: sh-quote single-quotes safely"
assert equal (sh-quote "echo hi") "'echo hi'" "simple"
assert equal (sh-quote "echo 'hi'") "'echo '\\''hi'\\'''" "embedded quote"

print "test: ssh-base-args is key-auth only"
let base = ssh-base-args
assert ("BatchMode=yes" in $base) "BatchMode"
assert ($base | any {|a| $a | str starts-with "ConnectTimeout=" }) "ConnectTimeout"
assert (not ($base | any {|a| ($a | str contains "PasswordAuthentication") or ($a | str contains "sshpass") })) "no password knobs"

print "test: exec-argv wraps with timeout when given, skips when empty"
let wrapped = exec-argv "studio@10.0.2.42" "echo hi" 240 --timeout-bin "timeout" --ssh "ssh"
assert equal ($wrapped | first) "timeout" "wrapper first"
assert ("BatchMode=yes" in $wrapped) "wrapper keeps BatchMode"
assert ("studio@10.0.2.42" in $wrapped) "wrapper keeps target"
let bare = exec-argv "studio@10.0.2.42" "echo hi" 240 --timeout-bin "" --ssh "ssh"
assert equal ($bare | first) "ssh" "no wrapper"

# ── pure: records / envelope (S-001) ──────────────────────────────────────────

print "test: result-record has vm/jail parity keys"
let rec = result-record "pass" 3 [{cmd: "c", stdout: "o", stderr: "e", exit_code: 0}]
assert equal ($rec | columns | sort) ["boot_sec", "outputs", "verdict"] "parity keys"
assert equal ((result-record "fail" 0 [] "boom" | get error)) "boom" "error key"

print "test: attach-warnings only adds the key when non-empty"
assert (not ("warnings" in (attach-warnings $rec []))) "no empty warnings"
assert equal (attach-warnings $rec ["w"] | get warnings) ["w"] "warnings kept"

print "test: reply-envelope carries X-Executor and a command_executed claim"
let env_out = reply-envelope "task-1" "<dispatch.1@host>" ($rec | insert target "studio@10.0.2.42") --now "20260101"
assert ($env_out | str contains "X-Executor: fleet") "executor header"
assert ($env_out | str contains "In-Reply-To: <dispatch.1@host>") "threading"
assert ($env_out | str contains 'kind      = "command_executed"') "claims kind"
let env_msgs = parse-mbox $env_out
assert equal ($env_msgs | length) 1 "one message"
let env_payload = extract-toml ($env_msgs | first)
assert equal ($env_payload | get verdict) "pass" "verdict survives"
assert equal (($env_payload | get claims | first | get kind)) "command_executed" "claim kind survives"
assert equal (($env_payload | get claims | first | get task_id)) "task-1" "claim task survives"

print "test: mbox-append-prefix keeps strict mbox separation"
assert equal (mbox-append-prefix "") "" "empty"
assert equal (mbox-append-prefix "x\n\n") "" "already blank"
assert equal (mbox-append-prefix "x\n") "\n" "one newline"
assert equal (mbox-append-prefix "x") "\n\n" "no newline"

print "test: root-for-spool and halt marker paths"
assert equal (root-for-spool "/r/var/mail/spool") "/r" "root derived"
assert equal (root-for-spool "/tmp/spool") "." "fallback"
assert equal (halt-marker-path "/r" "t-1") (["/r" "var" "mail" "HALT.t-1"] | path join) "marker path"

print "test: result-exit distinguishes pass / fail / refused"
assert equal (result-exit (result-record "pass" 0 [])) 0 "pass"
assert equal (result-exit (result-record "fail" 0 [{cmd: "c", stdout: "", stderr: "", exit_code: 1}] "boom")) 1 "fail"
assert equal (result-exit (result-record "fail" 0 [] "no fleet target: x")) 2 "refused target"
assert equal (result-exit (result-record "fail" 0 [] "fleet preflight failed for h: x")) 2 "refused preflight"
assert equal (result-exit (result-record "fail" 0 [] "task t is halted (./var/mail/HALT.t present); refusing to dispatch")) 2 "refused halted"

# ── stub-ssh: preflight + run ─────────────────────────────────────────────────

print "test: preflight-target succeeds against the stub"
do {
    let tmp = make-temp-dir
    let log = write-ssh-stub (do { mkdir ([$tmp, "bin"] | path join); [$tmp, "bin"] | path join })
    let stub_dir = [$tmp, "bin"] | path join
    with-stub-path $stub_dir {
        let pf = preflight-target "studio@10.0.2.42" --ssh ([$stub_dir, "ssh"] | path join)
        assert $pf.ok "preflight ok"
    }
    ^rm -rf $tmp
}

print "test: run-fleet-task passes via stub ssh with real stdout/exit codes"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "bin"] | path join)
    let stub_dir = [$tmp, "bin"] | path join
    let log = write-ssh-stub $stub_dir
    with-stub-path $stub_dir {
        let res = run-fleet-task "t-pass" ["echo hi", "uname -a"] --target "studio@10.0.2.42" --skip-preflight --timeout-bin "" --root $tmp
        assert equal $res.verdict "pass" "verdict"
        assert equal ($res.outputs | length) 2 "two outputs"
        assert equal ($res.outputs | get exit_code) [0, 0] "exit codes"
        assert (($res.outputs | first | get stdout) | str contains "stub-stdout") "stdout captured"
        assert equal $res.target "studio@10.0.2.42" "target recorded"
    }
    let logged = open --raw $log
    assert ($logged | str contains "BatchMode=yes") "BatchMode on the wire"
    assert (not ($logged | str contains "sshpass")) "no sshpass"
    ^rm -rf $tmp
}

print "test: run-fleet-task reports remote failure with exit codes (verdict fail)"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "bin"] | path join)
    let stub_dir = [$tmp, "bin"] | path join
    write-ssh-stub $stub_dir | ignore
    with-stub-path $stub_dir {
        let res = run-fleet-task "t-fail" ["run fail-cmd now"] --target "studio@10.0.2.42" --skip-preflight --timeout-bin "" --root $tmp
        assert equal $res.verdict "fail" "verdict"
        assert equal ($res.outputs | first | get exit_code) 1 "exit code"
        assert (($res.outputs | first | get stderr) | str contains "stub stderr") "stderr captured"
    }
    ^rm -rf $tmp
}

print "test: run-fleet-task goes through the timeout wrapper when present"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "bin"] | path join)
    let stub_dir = [$tmp, "bin"] | path join
    let log = write-ssh-stub $stub_dir
    with-stub-path $stub_dir {
        # timeout-bin UNSET => resolve-timeout-bin finds the stub `timeout` on PATH.
        hide-env -i SMOLFIRE_FLEET_TIMEOUT_BIN
        let res = run-fleet-task "t-wrap" ["echo hi"] --target "studio@10.0.2.42" --skip-preflight --root $tmp
        assert equal $res.verdict "pass" "wrapped verdict"
    }
    ^rm -rf $tmp
}

print "test: run-fleet-task refuses Network on unknown hosts (S-004)"
do {
    let tmp = make-temp-dir
    let res = run-fleet-task "t-net" ["echo hi"] --target "owner@10.0.9.9" --tools-required ["Bash", "Network"] --skip-preflight --timeout-bin "" --root $tmp
    assert equal $res.verdict "fail" "verdict"
    assert (($res | get error) | str contains "does not declare") "capability refusal"
    assert equal (result-exit $res) 2 "refused exit"
    ^rm -rf $tmp
}

print "test: a halted task must not dispatch"
do {
    let tmp = make-temp-dir
    mkdir ([$tmp, "bin"] | path join)
    let stub_dir = [$tmp, "bin"] | path join
    let log = write-ssh-stub $stub_dir
    mkdir ([$tmp, "var", "mail"] | path join)
    "task_id = \"t-halt\"\n" | save --force (halt-marker-path $tmp "t-halt")
    assert (task-halted? $tmp "t-halt") "halted detected"
    assert (not (task-halted? $tmp "t-other")) "other not halted"
    with-stub-path $stub_dir {
        let res = run-fleet-task "t-halt" ["echo hi"] --target "studio@10.0.2.42" --skip-preflight --timeout-bin "" --root $tmp
        assert equal $res.verdict "fail" "verdict"
        assert (($res | get error) | str contains "halted") "halt refusal"
    }
    # Stub ssh log must not exist: no probe, no exec ran.
    assert (not ($log | path exists)) "ssh never invoked for halted task"
    ^rm -rf $tmp
}

# ── coord-dispatch.nu hook ────────────────────────────────────────────────────

print "test: dispatch-subagent fleet role is a no-op by default (default OFF)"
do {
    use ../bin/coord-dispatch.nu [dispatch-subagent]
    let tmp = make-temp-dir
    let spool = [$tmp, "spool"] | path join
    "" | save --force $spool
    let result = with-env {} {
        hide-env -i SMOLFIRE_FLEET_ENABLE
        hide-env -i SMOLFIRE_FLEET_HOST
        dispatch-subagent "t-fleet-off" "fleet-worker" "task_id = \"t-fleet-off\"\n[commands]\nrun = [\"echo hi\"]" $spool
    }
    assert equal $result.launched false "not launched"
    assert (($result | get error) | str contains "disabled by default") "gate message"
    ^rm -rf $tmp
}

print "test: dispatch-subagent fleet role dispatches via stub ssh when enabled"
do {
    use ../bin/coord-dispatch.nu [dispatch-subagent]
    let tmp = make-temp-dir
    mkdir ([$tmp, "bin"] | path join)
    let stub_dir = [$tmp, "bin"] | path join
    write-ssh-stub $stub_dir | ignore
    let spool = [$tmp, "spool"] | path join
    "" | save --force $spool
    let brief = "task_id = \"t-fleet-on\"\n[commands]\nrun = [\"echo hi\"]\n[context_pointers]\nfleet_target = \"studio@10.0.2.42\""
    with-stub-path $stub_dir {
        with-env {SMOLFIRE_FLEET_ENABLE: "1", SMOLFIRE_FLEET_TIMEOUT_BIN: ""} {
            let result = dispatch-subagent "t-fleet-on" "fleet-worker" $brief $spool
            assert equal $result.launched true "launched"
            assert equal $result.mode "fleet-direct" "mode"
            assert equal $result.verdict "pass" "verdict"
        }
    }
    let msgs = parse-mbox (open --raw $spool)
    assert equal ($msgs | length) 1 "one reply appended"
    assert (($msgs | first | get headers | get "X-Executor" | default "") == "fleet") "fleet header"
    ^rm -rf $tmp
}

# ── live test (guarded) ───────────────────────────────────────────────────────

print "test: live end-to-end on 7950x4090pop (guarded by SMOLFIRE_FLEET_LIVE=1)"
do {
    if (($env | get SMOLFIRE_FLEET_LIVE? | default "") != "1") {
        print "  (skipped: set SMOLFIRE_FLEET_LIVE=1 to run against studio@10.0.2.42)"
    } else {
        let pf = preflight-target "studio@10.0.2.42"
        assert $pf.ok $"live preflight failed: ($pf.error)"
        let res = run-fleet-task "t-live" ["uname -a"] --target "studio@10.0.2.42" --root "."
        assert equal $res.verdict "pass" $"live verdict: ($res | to nuon)"
        assert (($res.outputs | first | get stdout) | str contains "Linux") "live stdout is Linux"
        print $"  live ok: (($res.outputs | first | get stdout | str trim))"
    }
}

print "all tests passed"
