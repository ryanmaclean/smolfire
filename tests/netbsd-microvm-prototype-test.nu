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

print "netbsd-microvm-prototype-test: ok"
