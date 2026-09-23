# SPDX-License-Identifier: Apache-2.0
# tests/jail-execute-test.nu — bin/jail-execute.nu + coord-tick executor selection.
#
# Runs on any host. Everything that needs FreeBSD (jail, jexec, rctl, zfs,
# podman, mdo, timeout, sysctl, umount) is replaced by logging stubs on PATH,
# and run-jail-task is told `--os freebsd`. The stubs never touch the real
# system: jexec/podman-exec just run the (test-controlled) command locally.
# What this can NOT prove — real jail(8)/rctl/mac_do semantics — is listed in
# docs/JAIL-EXECUTOR.md "Needs a real FreeBSD host".

use ../bin/jail-execute.nu *
use ../bin/mbox-parse.nu [parse-mbox, extract-toml]

def "assert equal" [left: any, right: any, what: string = ""] {
    if $left != $right {
        error make {msg: $"assert equal failed ($what)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, what: string = ""] {
    if not $cond { error make {msg: $"assert failed: ($what)"} }
}

def make-temp-dir [] { ^mktemp -d | str trim }

# ── Stub FreeBSD toolchain ────────────────────────────────────────────────────

# Write the stub binaries into <tmp>/bin. Every stub appends "<name> <args>"
# to $MOCK_LOG. Behaviour knobs (env): MOCK_JAIL_CREATE_FAIL, MOCK_JAIL_REMOVE_FAIL,
# MOCK_RACCT (value of kern.racct.enable, default 1).
def make-stubs [tmp: string, --no-mdo] {
    let bin = [$tmp "bin"] | path join
    mkdir $bin
    let log = 'echo "$(basename "$0") $*" >> "$MOCK_LOG"'
    let stubs = {
        jail: $"#!/bin/sh
($log)
conf=''; prev=''
for a in \"$@\"; do [ \"$prev\" = '-f' ] && conf=\"$a\"; prev=\"$a\"; done
case \"$1\" in
  -c) [ -n \"$conf\" ] && cp \"$conf\" \"$MOCK_DIR/last.conf\"
      [ -f \"${conf%/*}/resolv.conf\" ] && cp \"${conf%/*}/resolv.conf\" \"$MOCK_DIR/last.resolv.conf\"
      [ \"${MOCK_JAIL_CREATE_FAIL:-0}\" = 1 ] && { echo 'jail: mock create failure' >&2; exit 1; } ;;
  -r) [ \"${MOCK_JAIL_REMOVE_FAIL:-0}\" = 1 ] && { echo 'jail: mock remove failure' >&2; exit 1; } ;;
esac
exit 0
"
        jexec: $"#!/bin/sh
($log)
shift 4
exec \"$@\"
"
        timeout: $"#!/bin/sh
($log)
case \"$*\" in *SIMULATE_HANG*\) echo 'killed' >&2; exit 124 ;; esac
shift 3
exec \"$@\"
"
        podman: $"#!/bin/sh
($log)
case \"$1\" in exec\) shift 2; exec \"$@\" ;; esac
exit 0
"
        sysctl: $"#!/bin/sh
($log)
case \"$2\" in
  kern.racct.enable\) echo \"${MOCK_RACCT:-1}\" ;;
  security.mac.do.enabled\) echo 1 ;;
esac
exit 0
"
        rctl:   $"#!/bin/sh\n($log)\nexit 0\n"
        zfs:    $"#!/bin/sh\n($log)\nexit 0\n"
        umount: $"#!/bin/sh\n($log)\nexit 0\n"
        install: $"#!/bin/sh\n($log)\nexit 0\n"
        mdo:    $"#!/bin/sh\n($log)\n[ \"$1\" = -i ] && shift\nexec \"$@\"\n"
    }
    for kv in ($stubs | transpose name body) {
        if $no_mdo and $kv.name == "mdo" { continue }
        let p = [$bin $kv.name] | path join
        $kv.body | save --force $p
        ^chmod +x $p
    }
    $bin
}

# Run `body` with stubs first on PATH and MOCK_* pointing into tmp.
def with-stubs [tmp: string, bin: string, extra: record, body: closure] {
    let env_rec = {
        PATH: ($env.PATH | prepend $bin)
        MOCK_LOG: ([$tmp "mock.log"] | path join)
        MOCK_DIR: $tmp
    } | merge $extra
    with-env $env_rec { do $body }
}

def mock-log [tmp: string] {
    let p = [$tmp "mock.log"] | path join
    if ($p | path exists) { open --raw $p | lines } else { [] }
}

def lines-starting [log: list<string>, prefix: string] {
    $log | where {|l| $l | str starts-with $prefix}
}

let is_root = (^id -u | str trim) == "0"
let on_freebsd = $nu.os-info.name == "freebsd"

# ── Pure helpers ──────────────────────────────────────────────────────────────

print "test 1: host-check refuses non-FreeBSD, accepts FreeBSD"
do {
    assert ((host-check "freebsd").ok) "freebsd ok"
    assert ((host-check "FreeBSD").ok) "case-insensitive"
    for os in ["macos" "linux" "windows" "netbsd"] {
        let r = host-check $os
        assert (not $r.ok) $"($os) refused"
        assert ($r.error | str contains "requires a FreeBSD host") "clear error"
        assert ($r.error | str contains $os) "names the host"
    }
}

print "test 2: jail name derivation"
do {
    assert equal (derive-jail-name "task-0042" --salt "ab12cd") "sf_task_0042_ab12cd"
    let hostile = derive-jail-name "../x; rm -rf / .jail" --salt "ff00ff"
    assert ($hostile =~ '^[A-Za-z0-9_]+$') $"sanitized: ($hostile)"
    assert (not ($hostile | str contains ".")) "no hierarchy separator"
    assert equal (derive-jail-name "" --salt "abc123") "sf_task_abc123"
    let long = derive-jail-name ("x" | fill -c "y" -w 200) --salt "abc123"
    assert (($long | str length) <= 50) $"bounded length: ($long | str length)"
    let a = derive-jail-name "t"
    let b = derive-jail-name "t"
    assert ($a =~ '^sf_t_[0-9a-f]{6}$') $"random salt shape: ($a)"
    assert ($a != $b) "per-task names are unique across retries"
}

print "test 3: network only via the Network capability"
do {
    assert (not (network-wanted [])) "empty"
    assert (not (network-wanted ["Read" "Bash" "WebFetch" "WebSearch"])) "claude web tools do not open the jail net"
    assert (network-wanted ["Bash" "Network"]) "Network grants"
}

print "test 4: timeout math"
do {
    assert equal (clamp-timeout 0) 1 "min"
    assert equal (clamp-timeout -5) 1 "negative"
    assert equal (clamp-timeout 240) 240 "default passes"
    assert equal (clamp-timeout 10000) ($COORD_REPLY_WINDOW_SEC - $TEARDOWN_RESERVE_SEC) "max"
    assert (($DEFAULT_TIMEOUT_SEC + $TEARDOWN_RESERVE_SEC) <= $COORD_REPLY_WINDOW_SEC) "default fits coord 300s reply window"
    let now = 1_000_000_000_000
    assert equal (remaining-sec ($now + 10_000_000_000) $now) 10
    assert equal (remaining-sec ($now + 9_500_000_000) $now) 9 "floors"
    assert equal (remaining-sec ($now - 1) $now) 0 "never negative"
    assert (timed-out? 124) "timeout(1) expiry"
    assert (timed-out? 137) "kill-after"
    assert (not (timed-out? 1)) "plain failure"
    assert (not (timed-out? 0)) "success"
}

print "test 5: backend resolution and input validation"
do {
    assert ((resolve-backend "" "" "").error | str contains "no rootfs source")
    assert ((resolve-backend "/b" "" "img").error | str contains "mutually exclusive")
    assert equal (resolve-backend "/usr/local/smolfire/base-15.0" "" "").backend "nullfs"
    assert equal (resolve-backend "" "zroot/smolfire/base@clean" "").backend "zfs"
    assert equal (resolve-backend "" "" "ghcr.io/freebsd/freebsd-runtime:15.0").backend "podman"
    for bad in ["relative/dir" "/has space" "/q\"uote" "/a/../etc" "/semi;colon"] {
        assert ((resolve-backend $bad "" "").error | str contains "unsafe --base") $"reject ($bad)"
    }
    assert ((resolve-backend "" "no-snapshot" "").error | str contains "unsafe --zfs-snapshot")
    assert ((resolve-backend "" "" "img;reboot").error | str contains "unsafe --image")
    assert (safe-size? "512m") "size"
    assert (not (safe-size? "512m; reboot")) "bad size"
    assert equal (zfs-clone-dataset "zroot/smolfire/base@clean" "sf_t_ab") "zroot/smolfire/sf_t_ab"
}

print "test 6: jail.conf rendering"
do {
    let conf = render-jail-conf "sf_t_ab12cd" "/var/smolfire/jails/sf_t_ab12cd" --base "/usr/local/smolfire/base" --tmpfs-size "256m"
    assert ($conf | str contains "sf_t_ab12cd {") "block name"
    assert ($conf | str contains 'path = "/var/smolfire/jails/sf_t_ab12cd";') "path"
    assert ($conf | str contains 'host.hostname = "sf-t-ab12cd";') "hostname"
    assert ($conf | str contains 'ip4 = "disable";') "no ipv4 by default"
    assert ($conf | str contains 'ip6 = "disable";') "no ipv6 by default"
    assert (not ($conf | str contains "inherit")) "no inherit without Network"
    assert ($conf | str contains 'mount += "/usr/local/smolfire/base /var/smolfire/jails/sf_t_ab12cd nullfs ro 0 0";') "ro nullfs base"
    assert ($conf | str contains "tmpfs /var/smolfire/jails/sf_t_ab12cd/tmp tmpfs rw,mode=1777,size=256m 0 0") "tmpfs workspace"
    for p in ["persist;" "mount.devfs;" "devfs_ruleset = 4;" "enforce_statfs = 2;" "securelevel = 3;" "children.max = 0;" "allow.noraw_sockets;" "allow.nomount;"] {
        assert ($conf | str contains $p) $"hardening param ($p)"
    }
    assert (not ($conf | str contains "mac.do")) "mac.do only when mac_do is in play"
    assert equal ($conf | split chars | where {|c| $c == "{"} | length) 1 "one block"
    assert equal ($conf | split chars | where {|c| $c == "}"} | length) 1 "closed"

    let net = render-jail-conf "sf_n_1" "/j/sf_n_1" --base "/b" --network --mac-do-disable
    assert ($net | str contains 'ip4 = "inherit";') "Network → inherit"
    assert ($net | str contains 'mac.do = "disable";') "host mac_do rules not inherited"

    let z = render-jail-conf "sf_z_1" "/j/sf_z_1" --backend zfs
    assert (not ($z | str contains "nullfs")) "zfs clone needs no nullfs"
    assert ($z | str contains "tmpfs /j/sf_z_1/tmp") "zfs still gets tmpfs"

    assert (not ($net | str contains "resolv.conf")) "no DNS unless a resolv.conf is passed"
    let dns = render-jail-conf "sf_n_2" "/j/sf_n_2" --base "/b" --network --resolv-conf "/tmp/c/resolv.conf"
    assert ($dns | str contains 'mount += "/tmp/c/resolv.conf /j/sf_n_2/etc/resolv.conf nullfs ro 0 0";') "resolv.conf file mount, read-only"
    let lines = $dns | lines
    let at = {|p| $lines | enumerate | where {|e| $e.item | str contains $p} | first | get index }
    assert ((do $at "/b /j/sf_n_2 nullfs") < (do $at "etc/resolv.conf")) "file mount after the base mount"
    let zdns = render-jail-conf "sf_z_2" "/j/sf_z_2" --backend zfs --network --resolv-conf "/tmp/c/resolv.conf"
    assert (not ($zdns | str contains "resolv.conf")) "zfs copies resolv.conf instead of mounting it"
}

print "test 7: rctl rules, podman/OCI args, exec argv"
do {
    assert equal (rctl-rules "sf_a" "512m" 256 100) ["jail:sf_a:memoryuse:deny=512m" "jail:sf_a:vmemoryuse:deny=512m" "jail:sf_a:maxproc:deny=256" "jail:sf_a:pcpu:deny=100"]
    assert ("jail:sf_a:vmemoryuse:deny=2g" in (rctl-rules "sf_a" "512m" 256 100 --vmemory "2g")) "vmemory override"
    let pa = podman-run-args "sf_a" "img:1" 240
    assert (($pa | take 2) == ["podman" "run"]) "podman run"
    let i = $pa | enumerate | where item == "--network" | get index | first
    assert equal ($pa | get ($i + 1)) "none" "no network by default"
    assert ("ocijail" in $pa) "ocijail runtime"
    assert ("--read-only" in $pa) "read-only rootfs"
    assert equal ($pa | last) "270" "keep-alive = timeout + teardown reserve"
    let pn = podman-run-args "sf_a" "img:1" 240 --network
    assert ("host" in $pn) "Network → host net"
    assert equal (exec-argv nullfs "sf_a" "echo hi" 30) ["timeout" "-k" "5" "30" "jexec" "-l" "-U" "root" "sf_a" "/bin/sh" "-c" "echo hi"]
    assert equal (exec-argv podman "sf_a" "echo hi" 30 | skip 4 | take 3) ["podman" "exec" "sf_a"]
}

print "test 8: privilege hop is mdo(1) only"
do {
    assert equal (priv-prefix 0 false).prefix [] "root needs no hop"
    assert equal (priv-prefix 1001 true).prefix ["mdo" "-i"] "mac_do hop (uid only, keep groups)"
    let r = priv-prefix 1001 false
    assert ($r.error | str contains "mac_do") "explains mac_do"
    assert ($r.error | str contains "uid=1001>uid=0") "gives the rule"
}

print "test 9: result record has exactly the vm-execute.nu fields"
do {
    use ../bin/vm-execute.nu [run-vm-task]
    # Missing image → run-vm-task returns early (no QEMU boot) with its error shape.
    let vm = run-vm-task "t-shape" "/nonexistent/smolfire-test.qcow2" ["true"]
    let jail = run-jail-task "t-shape" ["true"] --base "/b" --os "macos"
    assert equal ($jail | columns) ($vm | columns) "error-shape parity"
    assert equal (result-record "pass" 3 [] | columns) ["verdict" "boot_sec" "outputs"] "pass shape"
    assert equal ($jail.verdict | describe) ($vm.verdict | describe)
    assert equal ($jail.boot_sec | describe) ($vm.boot_sec | describe)
}

print "test 10: reply envelope parses and targets the dispatch Message-ID"
do {
    let res = result-record "fail" 2 [{cmd: "echo \"hi\"", stdout: "hi", stderr: "", exit_code: 0} {cmd: "false", stdout: "", stderr: "", exit_code: 1}] "boom"
    let env_txt = reply-envelope "t-rep" "<coord.1.r1.x@smolfire.local>" $res --now "20260101000000"
    assert ($env_txt | str ends-with "\n\n") "reply ends with a blank line (strict mbox)"
    let msgs = parse-mbox $env_txt
    assert equal ($msgs | length) 1
    let m = $msgs | first
    assert equal ($m.headers | get "In-Reply-To") "<coord.1.r1.x@smolfire.local>"
    assert equal ($m.headers | get "To") "coordinator@smolfire.local"
    assert equal ($m.headers | get "X-Executor") "jail"
    assert equal ($m.headers | get "X-Jail-Error") "boom"
    let body = extract-toml $m
    assert (not ("_parse_error" in $body)) $"TOML parses: ($body | to nuon)"
    assert equal $body.verdict "fail"
    assert equal $body.task_id "t-rep"
    assert equal $body.result.boot_sec 2
    assert equal ($body.result.outputs | get exit_code) [0 1]
    assert equal ($body.claims | length) 1
    assert equal ($body.claims | first | get kind) "command_executed"
}

# ── Non-FreeBSD refusal (real host OS, stubs present but must stay unused) ────

print "test 11: non-FreeBSD host → refusal, nothing executed"
do {
    if $on_freebsd { print "  (n/a on FreeBSD)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-refuse" ["touch /tmp/should-not-exist"] --base "/b" --jail-root ([$tmp "jails"] | path join)
    }
    assert equal $r.verdict "fail"
    assert ($r.error | str contains "requires a FreeBSD host")
    assert equal (mock-log $tmp) [] "no stub (jail/mdo/...) was invoked"
    assert (not ([$tmp "jails"] | path join | path exists)) "no jail dir created"

    # CLI: exit 2 + JSON error
    let cli = with-stubs $tmp $bin {} { ^nu bin/jail-execute.nu run t-cli "true" --base /b | complete }
    assert equal $cli.exit_code 2 "refusal exit code"
    let j = $cli.stdout | from json
    assert ($j.error | str contains "requires a FreeBSD host")
    ^rm -rf $tmp
}

# ── Mocked FreeBSD path ───────────────────────────────────────────────────────

def jr [tmp: string] { [$tmp "jails"] | path join }

print "test 12: nullfs thin jail happy path (setup → limits → exec → teardown)"
do {
    if $is_root { print "  (skipped as root: this case exercises the mdo hop)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "task-0042" ["echo hello" "echo err >&2"] --base "/usr/local/smolfire/base" --jail-root (jr $tmp) --salt "ab12cd" --os freebsd
    }
    assert equal $r.verdict "pass" $"verdict: ($r | to nuon)"
    assert equal ($r | columns) ["verdict" "boot_sec" "outputs"]
    assert equal ($r.outputs | get stdout) ["hello" ""]
    assert equal ($r.outputs | get stderr) ["" "err"]
    assert equal ($r.outputs | get exit_code) [0 0]

    let log = mock-log $tmp
    let name = "sf_task_0042_ab12cd"
    assert ((lines-starting $log "mdo -i mkdir") | is-not-empty) "dir via mdo"
    assert equal (lines-starting $log "jail -c -f" | length) 1 "one create"
    assert ((lines-starting $log "jail -c -f") | first | str ends-with $name) "create by name"
    assert equal (lines-starting $log "rctl -a" | length) 4 "four rctl rules"
    assert equal (lines-starting $log $"rctl -a jail:($name):vmemoryuse:deny=512m" | length) 1 "address-space cap alongside memoryuse"
    assert ((lines-starting $log "rctl -a") | all {|l| $l | str contains $"jail:($name):"}) "rules scoped to jail"
    assert equal (lines-starting $log "jexec" | length) 2 "two execs"
    assert ((lines-starting $log "timeout -k 5") | is-not-empty) "timeout(1) wraps exec"
    assert equal (lines-starting $log "jail -r" | length) 1 "removed"
    assert equal (lines-starting $log $"rctl -r jail:($name)" | length) 1 "limits removed"
    assert ((lines-starting $log "mdo -i rmdir") | is-not-empty) "rmdir, not rm -rf"
    # order: create < exec < remove
    let idx = {|p| $log | enumerate | where {|e| $e.item | str starts-with $p} | first | get index }
    assert ((do $idx "jail -c") < (do $idx "jexec")) "create before exec"
    assert ((do $idx "jexec") < (do $idx "jail -r")) "exec before remove"
    assert (not ([(jr $tmp) $name] | path join | path exists)) "ephemeral dir gone"

    let conf = open --raw ([$tmp "last.conf"] | path join)
    assert ($conf | str contains 'ip4 = "disable";') "no network"
    assert ($conf | str contains 'mac.do = "disable";') "mdo hop → mac.do disabled in jail"
    assert ($conf | str contains "nullfs ro") "read-only base"
    assert (not ($conf | str contains "resolv.conf")) "no DNS without Network"
    assert (not ([$tmp "last.resolv.conf"] | path join | path exists)) "no resolv.conf snapshot without Network"
    ^rm -rf $tmp
}

print "test 13: Network capability → inherit; failing command → fail with teardown"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-net" ["false" "echo after"] --base "/b" --network --jail-root (jr $tmp) --salt "000001" --os freebsd
    }
    assert equal $r.verdict "fail"
    assert equal ($r.outputs | get exit_code) [1 0] "later commands still run after a non-timeout failure (vm parity)"
    let conf = open --raw ([$tmp "last.conf"] | path join)
    assert ($conf | str contains 'ip4 = "inherit";')
    assert (not ($conf | str contains "resolv.conf")) "no placeholder in the base → warn, no mount"
    assert equal (lines-starting (mock-log $tmp) "jail -r" | length) 1
    ^rm -rf $tmp
}

print "test 14: timeout(1) expiry stops the task and still tears down"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-hang" ["echo SIMULATE_HANG" "echo never"] --base "/b" --jail-root (jr $tmp) --salt "000002" --os freebsd
    }
    assert equal $r.verdict "fail"
    assert equal ($r.outputs | length) 1 "stopped after the hung command"
    assert equal ($r.outputs | first | get exit_code) 124
    assert ($r.error | str contains "task timeout") $"error: ($r.error)"
    assert equal (lines-starting (mock-log $tmp) "jail -r" | length) 1 "destroyed on timeout"
    ^rm -rf $tmp
}

print "test 15: whole-task deadline skips remaining commands"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-deadline" ["sleep 2.2" "echo never"] --base "/b" --timeout 2 --jail-root (jr $tmp) --salt "000003" --os freebsd
    }
    assert equal $r.verdict "fail"
    # the deadline covers setup too, so a slow setup may skip even the first command
    assert (($r.outputs | length) <= 1) "at most the sleeping command ran"
    assert ($r.error | str contains "budget exhausted") $"error: ($r.error)"
    assert (not ((mock-log $tmp) | any {|l| $l | str contains "echo never"})) "second command never ran"
    assert equal (lines-starting (mock-log $tmp) "jail -r" | length) 1
    ^rm -rf $tmp
}

print "test 16: jail -c failure → fail, no exec, dir cleaned, no jail -r"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {MOCK_JAIL_CREATE_FAIL: "1"} {
        run-jail-task "t-cfail" ["echo x"] --base "/b" --jail-root (jr $tmp) --salt "000004" --os freebsd
    }
    assert equal $r.verdict "fail"
    assert ($r.error | str contains "jail -c failed")
    let log = mock-log $tmp
    assert equal (lines-starting $log "jexec" | length) 0
    assert equal (lines-starting $log "jail -r" | length) 0
    assert (not ([(jr $tmp) "sf_t_cfail_000004"] | path join | path exists))
    ^rm -rf $tmp
}

print "test 17: rctl unavailable → warn and run; --require-limits → refuse + teardown"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {MOCK_RACCT: "0"} {
        run-jail-task "t-norctl" ["echo ok"] --base "/b" --jail-root (jr $tmp) --salt "000005" --os freebsd
    }
    assert equal $r.verdict "pass"
    assert equal (lines-starting (mock-log $tmp) "rctl" | length) 0 "no rctl calls"
    ^rm -rf $tmp

    let tmp2 = make-temp-dir
    let bin2 = make-stubs $tmp2
    let r2 = with-stubs $tmp2 $bin2 {MOCK_RACCT: "0"} {
        run-jail-task "t-req" ["echo ok"] --base "/b" --require-limits --jail-root (jr $tmp2) --salt "000006" --os freebsd
    }
    assert equal $r2.verdict "fail"
    assert ($r2.error | str contains "kern.racct.enable")
    let log2 = mock-log $tmp2
    assert equal (lines-starting $log2 "jexec" | length) 0 "nothing ran unlimited"
    assert equal (lines-starting $log2 "jail -r" | length) 1 "created jail destroyed"
    ^rm -rf $tmp2
}

print "test 18: failed teardown turns a passing run into fail (fail loud)"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {MOCK_JAIL_REMOVE_FAIL: "1"} {
        run-jail-task "t-leak" ["echo ok"] --base "/b" --jail-root (jr $tmp) --salt "000007" --os freebsd
    }
    assert equal $r.verdict "fail"
    assert ($r.error | str contains "jail -r failed")
    assert equal (lines-starting (mock-log $tmp) "umount -f" | length) 3 "force-unmount dev, tmp, base"
    ^rm -rf $tmp
}

print "test 19: zfs clone backend"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-zfs" ["echo z"] --zfs-snapshot "zroot/smolfire/base@clean" --jail-root (jr $tmp) --salt "000008" --os freebsd
    }
    assert equal $r.verdict "pass"
    let log = mock-log $tmp
    let clone = lines-starting $log "zfs clone" | first
    assert ($clone | str contains $"mountpoint=(jr $tmp)/sf_t_zfs_000008") "mounted at jail path"
    assert ($clone | str ends-with "zroot/smolfire/base@clean zroot/smolfire/sf_t_zfs_000008") "clone target"
    assert equal (lines-starting $log "zfs destroy -f zroot/smolfire/sf_t_zfs_000008" | length) 1 "ephemeral dataset destroyed"
    assert (not ((open --raw ([$tmp "last.conf"] | path join)) | str contains "nullfs"))
    assert equal (lines-starting $log "install" | length) 0 "no resolv.conf without Network"
    ^rm -rf $tmp
}

print "test 20: OCI backend via podman + ocijail"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-oci" ["echo oci"] --image "ghcr.io/freebsd/freebsd-runtime:15.0" --salt "000009" --os freebsd
    }
    assert equal $r.verdict "pass"
    assert equal ($r.outputs | first | get stdout) "oci"
    let log = mock-log $tmp
    let run = lines-starting $log "podman run" | first
    assert ($run | str contains "--runtime ocijail --network none --read-only") $"run: ($run)"
    assert equal (lines-starting $log "podman exec sf_t_oci_000009" | length) 1
    assert equal (lines-starting $log "podman rm --force --time 0 sf_t_oci_000009" | length) 1 "container removed"
    assert equal (lines-starting $log "jail " | length) 0 "no jail(8) calls on OCI path"
    ^rm -rf $tmp
}

print "test 21: non-root without mdo(1) → refuse before touching anything"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp --no-mdo
    if ((with-stubs $tmp $bin {} { which mdo }) | is-not-empty) { print "  (skipped: a real mdo is on PATH)"; ^rm -rf $tmp; return }
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-nomdo" ["echo x"] --base "/b" --jail-root (jr $tmp) --os freebsd
    }
    assert equal $r.verdict "fail"
    assert ($r.error | str contains "mac_do")
    assert equal (mock-log $tmp) []
    ^rm -rf $tmp
}

# ── coord-tick.nu executor selection ──────────────────────────────────────────

def make-msg [from_addr: string, to_addr: string, message_id: string, body: string] {
    ([
        $"From ($from_addr) Wed Jan  1 00:00:00 2026"
        $"From: ($from_addr)"
        $"To: ($to_addr)"
        $"Message-ID: ($message_id)"
        "Content-Type: text/toml; charset=utf-8"
    ] | str join "\n") + "\n\n" + $body + "\n"
}

# Run one coord tick with a stub `claude` (never the real CLI) and `extra` env.
def coord-tick-run [tmp: string, body: string, extra: record] {
    let spool = [$tmp "var" "mail" "spool"] | path join
    mkdir ($spool | path dirname)
    make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.exec.001@host>" $body | save --force $spool
    let stub = [$tmp "stub-bin"] | path join
    mkdir $stub
    let claude = [$stub "claude"] | path join
    $"#!/bin/sh\necho invoked >> ($tmp)/claude-invoked\nexit 0\n" | save --force $claude
    ^chmod +x $claude
    let env_rec = {PATH: ($env.PATH | prepend $stub)} | merge $extra
    let out = with-env $env_rec {
        ^nu bin/coord-tick.nu --state-file var/run/coord-state.toml --spool var/mail/spool --root $tmp | complete
    }
    let state = open --raw ([$tmp "var" "run" "coord-state.toml"] | path join) | from toml
    {out: $out.stdout, state: $state, spool: (open --raw $spool)}
}

print "test 22: coord-tick default executor is vm (dispatch unchanged + tagged)"
do {
    let tmp = make-temp-dir
    let r = coord-tick-run $tmp "task_id = \"t-vm\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: ""}
    assert equal $r.state.fsm_state "waiting"
    assert ($r.spool | str contains "executor = \"vm\"") "dispatch envelope names executor"
    assert equal ($r.state.task_executors | get "t-vm" | get executor) "vm"
    assert ($r.out | str contains "executor = \"vm\"") "dispatch_sent carries executor"
    assert (not ($r.out | str contains "dispatch_executor_refused"))
    ^rm -rf $tmp
}

print "test 23: coord-tick refuses an unknown SMOLFIRE_EXECUTOR (no silent fallback)"
do {
    let tmp = make-temp-dir
    let r = coord-tick-run $tmp "task_id = \"t-bad\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: "docker"}
    assert ($r.out | str contains "dispatch_executor_refused")
    assert ($r.out | str contains "unknown executor 'docker'")
    assert equal $r.state.fsm_state "idle"
    assert ("<req.exec.001@host>" in $r.state.seen_ids) "marked seen, not retried"
    assert (not ($r.spool | str contains "action = \"dispatch\"")) "nothing dispatched"
    ^rm -rf $tmp
}

print "test 24: coord-tick refuses executor = \"jail\" on a non-FreeBSD host"
do {
    if $on_freebsd { print "  (n/a on FreeBSD)"; return }
    let tmp = make-temp-dir
    # request field beats env
    let r = coord-tick-run $tmp "task_id = \"t-jail\"\nexecutor = \"jail\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: "vm"}
    assert ($r.out | str contains "dispatch_executor_refused")
    assert ($r.out | str contains "requires a FreeBSD host")
    assert ($r.out | str contains "source = \"request\"")
    assert equal $r.state.fsm_state "idle"
    assert (not ([$tmp "claude-invoked"] | path join | path exists)) "no subagent spawned"
    ^rm -rf $tmp

    let tmp2 = make-temp-dir
    let r2 = coord-tick-run $tmp2 "task_id = \"t-jail2\"\ncommand = \"echo hi\"" {SMOLFIRE_EXECUTOR: "jail"}
    assert ($r2.out | str contains "source = \"env\"")
    assert equal $r2.state.fsm_state "idle"
    ^rm -rf $tmp2
}

print "test 25: Network capability is gated by §17 like any tool"
do {
    let tmp = make-temp-dir
    # This currently stops at dispatch_capability_mismatch before ever
    # reaching spawn-subagent, but a regression in the §17 capability gate
    # would otherwise fall through to a real, billed subagent spawn. Route
    # through coord-tick-run (stub `claude` on PATH, never the real CLI)
    # instead of a raw coord-tick.nu invocation with the inherited PATH, so
    # this stays safe even if that gate regresses.
    let r = coord-tick-run $tmp "task_id = \"t-net\"\nagent_type = \"reviewer\"\ntools_required = [\"Network\"]" {}
    assert ($r.out | str contains "dispatch_capability_mismatch") "reviewer lacks Network"
    ^rm -rf $tmp
}

print "test 26: `dispatch` subcommand replies (fail + reason) instead of hanging on non-FreeBSD"
do {
    if $on_freebsd { print "  (n/a on FreeBSD)"; return }
    let tmp = make-temp-dir
    let spool = [$tmp "spool"] | path join
    make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.d.001@host>" "task_id = \"t-d\"\ncommand = \"echo hi\"" | save --force $spool
    let out = ^nu bin/jail-execute.nu dispatch --task-id t-d --dispatch-id "<coord.1.r1.d@smolfire.local>" --request-id "<req.d.001@host>" --spool $spool | complete
    assert equal $out.exit_code 2
    let msgs = parse-mbox (open --raw $spool)
    assert equal ($msgs | length) 2 "reply appended"
    assert ((open --raw $spool) | str contains "\n\nFrom jail-agent@smolfire.local ") "blank line before the reply's From line"
    let reply = $msgs | last
    assert equal ($reply.headers | get "In-Reply-To") "<coord.1.r1.d@smolfire.local>"
    assert equal (extract-toml $reply | get verdict) "fail"
    assert (($reply.headers | get "X-Jail-Error") | str contains "requires a FreeBSD host")
    ^rm -rf $tmp
}

print "test 27: mbox append separator"
do {
    assert equal (mbox-append-prefix "") "" "empty spool"
    assert equal (mbox-append-prefix "body\n\n") "" "already separated"
    assert equal (mbox-append-prefix "body\n") "\n" "one newline → add the blank line"
    assert equal (mbox-append-prefix "body") "\n\n" "no trailing newline"
    let res = result-record "pass" 0 [{cmd: "true", stdout: "", stderr: "", exit_code: 0}]
    let first = make-msg "coordinator@smolfire.local" "builder@smolfire.local" "<req.1@host>" "task_id = \"t\""
    let spool = $first + (mbox-append-prefix $first) + (reply-envelope "t" "<coord.1@smolfire.local>" $res)
    assert ($spool | str contains "\n\nFrom jail-agent@smolfire.local ") "strict mbox"
    assert equal (parse-mbox $spool | length) 2
}

print "test 28: resolv.conf plan (Network DNS)"
do {
    let tmp = make-temp-dir
    let src = [$tmp "host-resolv.conf"] | path join
    "nameserver 192.0.2.53\n" | save --force $src
    let empty = [$tmp "empty-resolv.conf"] | path join
    "" | save --force $empty
    let base = [$tmp "base"] | path join
    mkdir ([$base "etc"] | path join)
    assert ((resolv-plan nullfs $base $src).error | str contains "placeholder") "nullfs needs a placeholder"
    "" | save --force ([$base "etc" "resolv.conf"] | path join)
    assert equal (resolv-plan nullfs $base $src).error "" "placeholder present"
    assert equal (resolv-plan zfs "" $src).error "" "zfs clone is writable"
    assert ((resolv-plan nullfs $base ([$tmp "nope"] | path join)).error | str contains "not found") "missing source"
    assert ((resolv-plan nullfs $base $empty).error | str contains "empty") "empty source"
    assert ((resolv-plan podman "" $src).error | str contains "podman") "podman handles its own"
    let lbase = [$tmp "lbase"] | path join
    mkdir ([$lbase "etc"] | path join)
    ^ln -s /etc/hosts ([$lbase "etc" "resolv.conf"] | path join)
    assert ((resolv-plan nullfs $lbase $src).error | str contains "placeholder") "symlinked placeholder refused"
    ^rm -rf $tmp
}

print "test 29: Network task gets a resolv.conf snapshot; nullfs mounts it, zfs installs it"
do {
    if $is_root { print "  (skipped as root)"; return }
    let tmp = make-temp-dir
    let bin = make-stubs $tmp
    let src = [$tmp "host-resolv.conf"] | path join
    "nameserver 192.0.2.53\n" | save --force $src
    let base = [$tmp "base"] | path join
    mkdir ([$base "etc"] | path join)
    "" | save --force ([$base "etc" "resolv.conf"] | path join)
    let r = with-stubs $tmp $bin {} {
        run-jail-task "t-dns" ["echo x"] --base $base --network --resolv-conf $src --jail-root (jr $tmp) --salt "00000a" --os freebsd
    }
    assert equal $r.verdict "pass" $"verdict: ($r | to nuon)"
    let conf = open --raw ([$tmp "last.conf"] | path join)
    let path = [(jr $tmp) "sf_t_dns_00000a"] | path join
    assert ($conf | str contains $"/resolv.conf ($path)/etc/resolv.conf nullfs ro 0 0") $"resolv mount: ($conf)"
    assert equal (open --raw ([$tmp "last.resolv.conf"] | path join)) "nameserver 192.0.2.53\n" "snapshot of the host file"
    ^rm -rf $tmp

    let tmp2 = make-temp-dir
    let bin2 = make-stubs $tmp2
    let src2 = [$tmp2 "host-resolv.conf"] | path join
    "nameserver 192.0.2.53\n" | save --force $src2
    let r2 = with-stubs $tmp2 $bin2 {} {
        run-jail-task "t-zdns" ["echo z"] --zfs-snapshot "zroot/smolfire/base@clean" --network --resolv-conf $src2 --jail-root (jr $tmp2) --salt "00000b" --os freebsd
    }
    assert equal $r2.verdict "pass"
    let log2 = mock-log $tmp2
    let inst = lines-starting $log2 "install -m 0644"
    assert equal ($inst | length) 1 "one install into the clone"
    assert ($inst | first | str ends-with $"(jr $tmp2)/sf_t_zdns_00000b/etc/resolv.conf") "target is the clone's /etc"
    let idx = {|p| $log2 | enumerate | where {|e| $e.item | str starts-with $p} | first | get index }
    assert ((do $idx "zfs clone") < (do $idx "install")) "after the clone"
    assert ((do $idx "install") < (do $idx "jail -c")) "before the jail starts"
    assert (not ((open --raw ([$tmp2 "last.conf"] | path join)) | str contains "resolv.conf")) "no mount for zfs"
    ^rm -rf $tmp2
}

print "all tests passed"
