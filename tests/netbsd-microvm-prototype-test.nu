# SPDX-License-Identifier: Apache-2.0
# netbsd-microvm-prototype-test.nu — Nushell port of the retired
# tests/netbsd-microvm-prototype-test.py, covering
# bin/netbsd-microvm-prototype.nu's --dry-run and --parse-log paths.

const SCRIPT_REL = "../bin/netbsd-microvm-prototype.nu"
const FIXTURE_REL = "fixtures/netbsd-microvm-sample.log"

def "assert equal" [left: any, right: any, label: string] {
    if $left != $right {
        error make {msg: $"assert equal failed \(($label)\)\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}
def assert [cond: bool, label: string] {
    if not $cond { error make {msg: $"assert failed: ($label)"} }
}

def script-path []: nothing -> string {
    $env.FILE_PWD | path join $SCRIPT_REL | path expand
}

def fixture-path []: nothing -> string {
    $env.FILE_PWD | path join $FIXTURE_REL | path expand
}

def run-json [args: list]: nothing -> record {
    let result = (^nu (script-path) ...$args | complete)
    if $result.exit_code != 0 {
        error make {msg: $"script exited ($result.exit_code): ($result.stderr)"}
    }
    ($result.stdout | from json)
}

print "test: dry-run and parse-log (Nushell port parity)"
do {
    let tmp = (mktemp -d)
    let kernel = ([$tmp, "netbsd-MICROVM"] | path join)
    let rootfs = ([$tmp, "rootfs.fs"] | path join)
    let state = ([$tmp, "state.img"] | path join)
    (0..<4096 | each {|_| "K" } | str join) | save --force $kernel
    (0..<2048 | each {|_| "R" } | str join) | save --force $rootfs
    (0..<8192 | each {|_| "S" } | str join) | save --force $state

    let dry = (run-json [
        "--kernel", $kernel,
        "--rootfs", $rootfs,
        "--state-image", $state,
        "--state-fs", "lfs",
        "--accel", "tcg",
        "--append", "bootverbose=1",
        "--dry-run",
    ])
    let cmd = $dry.qemu_command
    let joined = ($cmd | str join " ")
    assert ($cmd.0 | str contains "qemu-system-x86_64") "dry-run command did not default to qemu-system-x86_64"
    for needle in [
        "-M microvm,rtc=on,acpi=off,pic=off",
        "-initrd",
        "virtio-blk-device,drive=state0",
        "virtio-mmio.force-legacy=false",
        "console=com",
        "root=md0a",
        "smolfire.state_dev=ld0a",
        "smolfire.state_fs=lfs",
        "bootverbose=1",
    ] {
        assert ($joined | str contains $needle) $"dry-run command missing ($needle)"
    }
    assert equal $dry.artifacts.total_bytes 14336 "artifact byte accounting"
    assert equal $dry.config.memory_mib 256 "default memory_mib should be 256"

    let parsed = (run-json [
        "--kernel", $kernel,
        "--rootfs", $rootfs,
        "--state-image", $state,
        "--state-fs", "lfs",
        "--accel", "tcg",
        "--parse-log", (fixture-path),
    ])
    let result = $parsed.result
    assert equal $result.time_to_ready_ms 73 "TIME_TO_READY parser did not recover 73ms"
    assert equal $result.state.dev "ld0a" "state marker dev field"
    assert equal $result.state.mount "/state" "state marker mount field"
    assert equal $result.workload.verdict "pass" "workload marker verdict field"
    assert equal $result.workload.fs "lfs" "workload marker fs field"
    assert equal $result.workload.ops 128 "workload numeric field ops"
    assert equal $result.workload.fsync_p50_ms 1.7 "workload numeric field fsync_p50_ms"
    for key in [
        "boots_under_qemu_microvm_pvh",
        "stable_ready_marker",
        "mounts_one_writable_state_volume",
        "runs_common_filesystem_state_workload",
        "reports_artifact_size_boot_time_ram_and_fs_metrics",
    ] {
        assert (($result.acceptance | get $key) == true) $"acceptance flag ($key) was not satisfied"
    }

    let incomplete = ([$tmp, "incomplete.log"] | path join)
    [
        "[   1.0000000] NetBSD 11.0 (MICROVM)",
        "SMOLFIRE_NETBSD_READY",
        "SMOLFIRE_NETBSD_STATE_OK dev=ld0a mount=/state fs=lfs mode=rw",
        "TIME_TO_READY=41ms",
    ] | str join "\n" | save --force $incomplete

    let negative = (run-json [
        "--kernel", $kernel,
        "--rootfs", $rootfs,
        "--state-image", $state,
        "--state-fs", "lfs",
        "--accel", "tcg",
        "--parse-log", $incomplete,
    ])
    let neg_result = $negative.result
    assert ($neg_result.workload == null) "incomplete log should not parse a workload marker"
    assert (($neg_result.acceptance.runs_common_filesystem_state_workload) == false) "missing workload marker should fail workload acceptance"
    assert (($neg_result.acceptance.reports_artifact_size_boot_time_ram_and_fs_metrics) == false) "missing workload marker should fail metrics acceptance"

    rm -rf $tmp
}

print "test: root image, SLIRP networking, STATS samples, append limit"
do {
    let tmp = (mktemp -d)
    let kernel = ([$tmp, "netbsd-MICROVM"] | path join)
    let root = ([$tmp, "root.img"] | path join)
    let state = ([$tmp, "state.img"] | path join)
    (0..<4096 | each {|_| "K" } | str join) | save --force $kernel
    (0..<1024 | each {|_| "R" } | str join) | save --force $root
    (0..<8192 | each {|_| "S" } | str join) | save --force $state

    let base = [
        "--kernel", $kernel,
        "--root-image", $root,
        "--root-device", "ld0a",
        "--state-image", $state,
        "--state-device", "ld1a",
        "--state-fs", "ffs-wapbl",
        "--accel", "tcg",
    ]
    let dry = (run-json ($base | append ["--net", "slirp", "--hostfwd", "tcp:127.0.0.1:2252-:22", "--dry-run"]))
    let cmd = $dry.qemu_command
    let joined = ($cmd | str join " ")
    for needle in [
        "if=none,file=($root),format=raw,id=root0,readonly=on",
        "virtio-blk-device,drive=root0",
        "user,id=net0,hostfwd=tcp:127.0.0.1:2252-:22",
        "virtio-net-device,netdev=net0",
        "root=ld0a",
        "smolfire.state_dev=ld1a",
    ] {
        let n = ($needle | str replace "($root)" $root)
        assert ($joined | str contains $n) $"dry-run command missing ($n)"
    }
    assert (not ($joined | str contains "-initrd")) "root image must not be passed as -initrd"
    let root_idx = ($cmd | enumerate | where item == "virtio-blk-device,drive=root0" | get index | first)
    let state_idx = ($cmd | enumerate | where item == "virtio-blk-device,drive=state0" | get index | first)
    assert ($root_idx < $state_idx) "root disk must be attached before the state disk (ld0 vs ld1)"
    assert equal $dry.artifacts.root_image.bytes 1024 "root image byte accounting"
    assert equal $dry.artifacts.total_bytes 13312 "total bytes include the root image"
    assert equal $dry.config.net.mode "slirp" "net mode in config"
    assert equal $dry.config.append_truncated_by_netbsd true "default append exceeds NetBSD's 255-byte limit"

    # no network unless asked: the legacy command shape is unchanged
    let plain = (run-json ($base | append ["--dry-run"]))
    assert (not (($plain.qemu_command | str join " ") | str contains "netdev")) "no netdev without --net slirp"
    assert (($plain.config | get -o net) == null) "no net config without --net slirp"

    let bad = (^nu (script-path) ...($base | append ["--hostfwd", "tcp:127.0.0.1:1-:22", "--dry-run"]) | complete)
    assert ($bad.exit_code != 0) "--hostfwd without --net slirp must fail"

    let log = ([$tmp, "agent.log"] | path join)
    [
        "[   1.1146703] kernel boot time: 382ms",
        "SMOLFIRE_NETBSD_READY kernel=11.0 host=smolfire-netbsd-pop",
        "SMOLFIRE_NETBSD_STATE_OK dev=ld1a mount=/state fs=ffs-wapbl mode=rw",
        "SMOLFIRE_NETBSD_WORKLOAD verdict=pass workload=dd-agent-rs pid=120 binary_bytes=10809672",
        "SMOLFIRE_NETBSD_STATS t=0 pid=120 rss_kb=9800 vsz_kb=39000 cpu_pct=1.5 cputime=0:00.10",
        "SMOLFIRE_NETBSD_STATS t=30 pid=120 rss_kb=11420 vsz_kb=41544 cpu_pct=0.2 cputime=0:00.25",
        "SMOLFIRE_NETBSD_STATS t=60 pid=120 rss_kb=11400 vsz_kb=41544 cpu_pct=0.1 cputime=0:00.40",
        "TIME_TO_READY=1793ms",
    ] | str join "\n" | save --force $log
    let parsed = (run-json ($base | append ["--parse-log", $log]))
    let st = $parsed.result.stats
    assert equal $st.samples 3 "STATS sample count"
    assert equal $st.rss_kb.max 11420 "rss max"
    assert equal $st.rss_kb.last 11400 "rss last"
    assert equal $st.window_s 60 "stats window"
    assert equal $st.avg_cpu_pct_over_window 0.5 "avg cpu from cputime delta (0.3 s over 60 s)"
    assert equal $parsed.result.workload.binary_bytes 10809672 "workload numeric field"
    assert ($parsed.result.acceptance.mounts_one_writable_state_volume) "ffs-wapbl state mounted rw"

    rm -rf $tmp
}

print "netbsd-microvm-prototype-test: ok"
