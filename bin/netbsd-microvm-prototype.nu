#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
#
# netbsd-microvm-prototype.nu — host-side prototype runner/reporter for a
# NetBSD 11 MICROVM sibling target.
#
# Nushell port of the original bin/netbsd-microvm-prototype.py (see
# docs/NETBSD-MICROVM-PROTOTYPE.md and git history for provenance — ported
# 2026-09-23 per the repo's Nushell-only policy in AGENTS.md).
#
# This script does not build NetBSD artifacts. It launches (or dry-runs) a
# QEMU microvm/PVH command for a caller-supplied MICROVM kernel, immutable
# rootfs/initrd, and one writable state disk, then watches serial output for
# a small marker protocol:
#
#   SMOLFIRE_NETBSD_READY
#   SMOLFIRE_NETBSD_STATE_OK dev=<dev> mount=<path> fs=<name> mode=rw
#   SMOLFIRE_NETBSD_WORKLOAD verdict=pass key=value ...
#
# The resulting JSON report (schema smolfire.netbsd-microvm-prototype/v1)
# captures artifact size, host-measured time to READY, configured RAM/CPUs,
# and any workload/filesystem metrics supplied by the guest. Keys are sorted
# recursively before printing to match the original script's
# `json.dump(..., sort_keys=True)` output byte-for-byte.
#
# Usage:
#   nu bin/netbsd-microvm-prototype.nu --kernel K --state-image S --state-fs lfs --dry-run
#   nu bin/netbsd-microvm-prototype.nu --kernel K --state-image S --state-fs lfs --parse-log LOG

const READY_MARKER = "SMOLFIRE_NETBSD_READY"
const STATE_MARKER = "SMOLFIRE_NETBSD_STATE_OK"
const WORKLOAD_MARKER = "SMOLFIRE_NETBSD_WORKLOAD"
const SCHEMA = "smolfire.netbsd-microvm-prototype/v1"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def detect-accel []: nothing -> string {
    let system = $nu.os-info.name
    if $system == "macos" {
        let result = (do { ^sysctl kern.hv_support } | complete)
        if $result.exit_code == 0 and ($result.stdout | str trim | str ends-with ": 1") {
            "hvf"
        } else {
            "tcg"
        }
    } else if $system == "linux" and ("/dev/kvm" | path exists) {
        "kvm"
    } else {
        "tcg"
    }
}

def cpu-model [accel: string]: nothing -> string {
    if $accel in ["hvf", "kvm"] { "host" } else { "qemu64" }
}

# Mirrors Python's file_size(): null in, null out; otherwise size in bytes.
def file-size [path?: string]: nothing -> any {
    if ($path == null) or ($path | str length) == 0 {
        null
    } else {
        (ls $path).0.size | into int
    }
}

# Mirrors Python's typed_value(): bool, then int (rejecting ambiguous
# leading-zero strings like "007"), then float, else the original string.
def typed-value [value: string]: nothing -> any {
    let lowered = ($value | str lowercase)
    if $lowered == "true" {
        true
    } else if $lowered == "false" {
        false
    } else {
        let leading_zero_bad = (
            ($value | str starts-with "0")
            and ($value != "0")
            and not ($value | str starts-with "0.")
        )
        let looks_int = ($value =~ '^[+-]?[0-9]+$')
        if (not $leading_zero_bad) and $looks_int {
            (try { $value | into int } catch { (try { $value | into float } catch { $value }) })
        } else {
            (try { $value | into float } catch { $value })
        }
    }
}

# Mirrors Python's parse_kv_tail(): whitespace-separated key=value tokens;
# tokens without "=" are ignored.
def parse-kv-tail [tail: string]: nothing -> record {
    mut parsed = {}
    let trimmed = ($tail | str trim)
    if ($trimmed | str length) == 0 {
        return $parsed
    }
    for token in ($trimmed | split row -r '\s+') {
        if ($token | str length) == 0 {
            continue
        }
        if ($token | str contains "=") {
            let idx = ($token | str index-of "=")
            let key = ($token | str substring ..<$idx)
            let val = ($token | str substring ($idx + 1)..)
            $parsed = ($parsed | upsert $key (typed-value $val))
        }
    }
    $parsed
}

# Mirrors Python's build_append().
def build-append [args: record]: nothing -> string {
    mut fields = [
        "console=com",
        $"root=($args.root_device)",
        $"smolfire.state_dev=($args.state_device)",
        $"smolfire.state_fs=($args.state_fs)",
        $"smolfire.ready_marker=($READY_MARKER)",
        $"smolfire.state_marker=($STATE_MARKER)",
        $"smolfire.workload_marker=($WORKLOAD_MARKER)",
    ]
    if ($args.append | str trim | str length) > 0 {
        let extra = ($args.append | split row -r '\s+' | where {|s| ($s | str length) > 0 })
        $fields = ($fields | append $extra)
    }
    $fields | str join " "
}

# Mirrors Python's build_qemu_cmd(). Returns {cmd: [...], accel: string}
# since nu args records are immutable (no _resolved_accel mutation in place).
def build-qemu-cmd [args: record]: nothing -> record {
    let accel = if $args.accel == "auto" { detect-accel } else { $args.accel }
    mut cmd = [
        $args.qemu,
        "-accel", $accel,
        "-M", "microvm,rtc=on,acpi=off,pic=off",
        "-cpu", (cpu-model $accel),
        "-m", ($args.memory_mib | into string),
        "-smp", ($args.cpus | into string),
        "-kernel", $args.kernel,
    ]
    if ($args.rootfs != null) and ($args.rootfs | str length) > 0 {
        $cmd = ($cmd | append ["-initrd", $args.rootfs])
    }
    $cmd = ($cmd | append [
        "-drive", $"if=none,file=($args.state_image),format=($args.state_format),id=state0",
        "-device", "virtio-blk-device,drive=state0",
        "-global", "virtio-mmio.force-legacy=false",
        "-display", "none",
        "-serial", "stdio",
        "-append", (build-append $args),
    ])
    {cmd: $cmd, accel: $accel}
}

# Mirrors Python's empty_report().
def empty-report [args: record, cmd: list, resolved_accel: string]: nothing -> record {
    let kernel_bytes = (file-size $args.kernel)
    let rootfs_bytes = (file-size $args.rootfs)
    let state_bytes = (file-size $args.state_image)
    let sizes = ([$kernel_bytes, $rootfs_bytes, $state_bytes] | where {|x| $x != null})
    let total = (if ($sizes | is-empty) { 0 } else { $sizes | math sum })
    {
        schema: $SCHEMA,
        expected_markers: {
            ready: $READY_MARKER,
            state: $STATE_MARKER,
            workload: $WORKLOAD_MARKER,
        },
        artifacts: {
            kernel: {path: $args.kernel, bytes: $kernel_bytes},
            rootfs: {path: $args.rootfs, bytes: $rootfs_bytes},
            state: {path: $args.state_image, bytes: $state_bytes, format: $args.state_format},
            total_bytes: $total,
        },
        config: {
            memory_mib: $args.memory_mib,
            cpus: $args.cpus,
            state_fs: $args.state_fs,
            root_device: $args.root_device,
            state_device: $args.state_device,
            timeout_s: $args.timeout,
            append: (build-append $args),
            accel: $resolved_accel,
        },
        qemu_command: $cmd,
    }
}

# Mirrors Python's parse_transcript().
def parse-transcript [lines: list, report: record, measured_ready_ms?: any]: nothing -> record {
    mut ready_seen = false
    mut state_info: any = null
    mut workload_info: any = null
    mut time_to_ready_ms: any = $measured_ready_ms

    for line in $lines {
        if $time_to_ready_ms == null {
            let m = ($line | parse --regex 'TIME_TO_READY=(?<ms>\d+)ms')
            if ($m | length) > 0 {
                $time_to_ready_ms = ($m.0.ms | into int)
            }
        }
        if (not $ready_seen) and ($line =~ $READY_MARKER) {
            $ready_seen = true
        }
        let sm = ($line | parse --regex ($STATE_MARKER + '(?<tail>.*)'))
        if ($sm | length) > 0 {
            $state_info = (parse-kv-tail $sm.0.tail)
        }
        let wm = ($line | parse --regex ($WORKLOAD_MARKER + '(?<tail>.*)'))
        if ($wm | length) > 0 {
            $workload_info = (parse-kv-tail $wm.0.tail)
        }
    }

    mut r = ($report | upsert transcript {
        lines: ($lines | length),
        ready_seen: $ready_seen,
        state_seen: ($state_info != null),
        workload_seen: ($workload_info != null),
    })
    let acceptance = {
        boots_under_qemu_microvm_pvh: $ready_seen,
        stable_ready_marker: $ready_seen,
        mounts_one_writable_state_volume: (($state_info != null) and (($state_info | get -o mode) == "rw")),
        runs_common_filesystem_state_workload: (($workload_info != null) and (($workload_info | get -o verdict) == "pass")),
        reports_artifact_size_boot_time_ram_and_fs_metrics: (($time_to_ready_ms != null) and ($workload_info != null)),
    }
    $r = ($r | upsert result {
        time_to_ready_ms: $time_to_ready_ms,
        state: $state_info,
        workload: $workload_info,
        acceptance: $acceptance,
    })
    $r
}

# Best-effort live runner: spawns qemu in the background, tails its combined
# stdout/stderr into a temp file, and polls for the marker protocol. Real
# QEMU/NetBSD-artifact runs are not part of this repo's test suite (no
# NetBSD MICROVM kernel is available in CI); --dry-run and --parse-log are
# the exercised, byte-for-byte-verified paths.
def run-qemu [args: record, cmd: list, resolved_accel: string]: nothing -> record {
    mut report = (empty-report $args $cmd $resolved_accel)
    let tmp_log = (mktemp)
    let start = (date now)
    let timeout_dur = ($args.timeout * 1sec)
    let job_id = (job spawn {
        ^($cmd | first) ...($cmd | skip 1) o+e> $tmp_log
    })

    mut lines_seen = 0
    mut ready_ms: any = null
    mut workload_seen = false
    mut timed_out = false

    loop {
        sleep 250ms
        let elapsed = ((date now) - $start)
        let all_lines = (if ($tmp_log | path exists) { open --raw $tmp_log | lines } else { [] })
        if ($all_lines | length) > $lines_seen {
            for l in ($all_lines | skip $lines_seen) {
                if ($ready_ms == null) and ($l =~ $READY_MARKER) {
                    $ready_ms = ($elapsed / 1ms | math round)
                }
                if ($l =~ $WORKLOAD_MARKER) {
                    $workload_seen = true
                }
            }
            $lines_seen = ($all_lines | length)
        }
        if $workload_seen {
            break
        }
        if $elapsed > $timeout_dur {
            $timed_out = true
            break
        }
    }

    try { job kill $job_id }
    let final_lines = (if ($tmp_log | path exists) { open --raw $tmp_log | lines } else { [] })
    try { rm -f $tmp_log }

    if $timed_out {
        $report = ($report | upsert timeout true)
    }
    $report = ($report | upsert process {returncode: null})
    parse-transcript $final_lines $report $ready_ms
}

# Recursively sort record keys so `to json` matches Python's
# json.dump(..., sort_keys=True) output.
def sort-keys [value: any]: any -> any {
    let t = ($value | describe)
    if ($t | str starts-with "record") {
        mut out = {}
        for k in ($value | columns | sort) {
            $out = ($out | upsert $k (sort-keys ($value | get $k)))
        }
        $out
    } else if ($t | str starts-with "list") or ($t | str starts-with "table") {
        $value | each {|item| sort-keys $item }
    } else {
        $value
    }
}

def to-report-json [report: record]: nothing -> string {
    (sort-keys $report) | to json --indent 2
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main [
    --kernel: string          # NetBSD MICROVM kernel path (required)
    --rootfs: string          # Immutable rootfs/initrd path
    --state-image: string     # Writable state disk path (required)
    --state-format: string = "raw"  # State disk format (default: raw)
    --state-fs: string        # required, one of: lfs, ffs-wapbl, hammer2
    --root-device: string = "md0a"  # Kernel root= device (default: md0a)
    --state-device: string = "ld0a" # Guest state device hint (default: ld0a)
    --memory-mib: int = 256
    --cpus: int = 1
    --timeout: int = 30
    --qemu: string = "qemu-system-x86_64"
    --accel: string = "auto"  # one of: auto, hvf, kvm, tcg
    --append: string = ""     # Extra kernel arguments appended after the prototype defaults
    --serial-log: string      # Save combined serial transcript to this path
    --parse-log: string       # Parse an existing serial log instead of running QEMU
    --dry-run                 # Print JSON report with the generated QEMU command only
] {
    if $kernel == null {
        error make {msg: "--kernel is required"}
    }
    if $state_image == null {
        error make {msg: "--state-image is required"}
    }
    if $state_fs == null {
        error make {msg: "--state-fs is required"}
    }
    if not ($state_fs in ["lfs", "ffs-wapbl", "hammer2"]) {
        error make {msg: $"--state-fs must be one of lfs, ffs-wapbl, hammer2 \(got ($state_fs)\)"}
    }
    if not ($accel in ["auto", "hvf", "kvm", "tcg"]) {
        error make {msg: $"--accel must be one of auto, hvf, kvm, tcg \(got ($accel)\)"}
    }

    let args = {
        kernel: $kernel,
        rootfs: $rootfs,
        state_image: $state_image,
        state_format: $state_format,
        state_fs: $state_fs,
        root_device: $root_device,
        state_device: $state_device,
        memory_mib: $memory_mib,
        cpus: $cpus,
        timeout: $timeout,
        qemu: $qemu,
        accel: $accel,
        append: $append,
        serial_log: $serial_log,
        parse_log: $parse_log,
        dry_run: $dry_run,
    }

    let built = (build-qemu-cmd $args)
    let cmd = $built.cmd
    let resolved_accel = $built.accel

    let report = if $dry_run {
        (empty-report $args $cmd $resolved_accel)
    } else if ($parse_log != null) {
        let base = (empty-report $args $cmd $resolved_accel)
        let lines = (open --raw $parse_log | lines)
        let parsed = (parse-transcript $lines $base null)
        ($parsed | upsert parse_log $parse_log)
    } else {
        (run-qemu $args $cmd $resolved_accel)
    }

    print (to-report-json $report)
}
