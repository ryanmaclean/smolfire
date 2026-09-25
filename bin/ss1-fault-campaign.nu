#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/ss1-fault-campaign.nu — smolFire #88 software fault-injection campaign on
# SuperStation One (superstation1), around the #86 durable-commit writer.
#
# The board has no compiler and no nu: the harness is two static armv7
# binaries built on ubrpi502 (hps/durable_commit_bench.c +
# hps/durable_fault_harness.c); this script drives them over ONE shared SSH
# ControlMaster, never retries a failed login, and only touches
# /media/fat/smolfire-bench/f88 on the board.
#
#   nu bin/ss1-fault-campaign.nu build            # static armv7 on ubrpi502
#   nu bin/ss1-fault-campaign.nu preflight        # env capture + update_all/downloader check
#   nu bin/ss1-fault-campaign.nu push             # copy binaries to the board
#   nu bin/ss1-fault-campaign.nu run              # start campaign (nohup) and wait for it
#   nu bin/ss1-fault-campaign.nu fetch --date D   # copy results + write ryanlab.bench.v1 records
#
# Output contract: bench/superstation1/<date>/fault-injection/{raw,records}/ ;
# raw/*.jsonl = one JSON object per injected fault (schema in
# hps/durable_fault_harness.c), raw/*.metrics = SMOLFIRE_METRIC summary,
# records/*.json = ryanlab.bench.v1 via bin/bench-record.nu.

const BOARD_DIR = "/media/fat/smolfire-bench/f88"
const BUILD_DIR = "sf88"
const CFLAGS = "-O2 -Wall -Wextra -Wno-stringop-truncation -march=armv7-a -mtune=cortex-a9 -mfpu=neon -static"

# one ssh invocation; BatchMode so a rejected key fails once instead of prompting
def board [host: string, alias: string, cmd: string] {
    let opts = if ($alias | is-empty) { [] } else { [-o $"HostKeyAlias=($alias)"] }
    let r = (^ssh -o BatchMode=yes -o ConnectTimeout=15 ...$opts $host $cmd | complete)
    if $r.exit_code == 255 and ($r.stderr | str contains "Permission denied") {
        error make {msg: $"ssh auth to ($host) failed — not retrying \(fleet rule\). stderr: ($r.stderr | str trim)"}
    }
    $r
}

def scratch [] { $env.TMPDIR? | default "/tmp" | path join "sf88-campaign" }

# the campaign run on the board (busybox sh, inline — no script file on the board)
def campaign [] {
    let d = $BOARD_DIR
    let h = $"($d)/durable_fault_harness.armv7"
    let w = $"($d)/durable_commit_bench.armv7"
    let crash = {|name, extra| $"($h) crash --writer ($w) --dir ($d)/logs --fs ($name) --jsonl ($d)/out/($name).jsonl ($extra) > ($d)/out/($name).metrics 2> ($d)/out/($name).err; echo ($name) rc=$? >> ($d)/out/progress" }
    let fill = {|name, extra| $"($h) fill --writer ($w) --mnt ($d)/mnt --jsonl ($d)/out/($name).jsonl ($extra) > ($d)/out/($name).metrics 2> ($d)/out/($name).err; echo ($name) rc=$? >> ($d)/out/progress" }
    [
        $"mkdir -p ($d)/logs ($d)/mnt ($d)/backing ($d)/out"
        (do $crash "crash-exfat-64" "--iterations 1200 --seed 880001 --recsize 64 --split 4 --max-ops 16 --rotate 100 --max-delay-us 40000")
        (do $crash "crash-exfat-4096" "--iterations 300 --seed 880002 --recsize 4096 --split 8 --max-ops 8 --rotate 50 --max-delay-us 60000")
        (do $crash "selftest-ack-early" "--iterations 100 --seed 880003 --recsize 64 --split 4 --mutant ack-early")
        (do $crash "selftest-no-repair" "--iterations 100 --seed 880004 --recsize 64 --split 4 --mutant no-repair")
        (do $fill "fill-tmpfs-enospc" "--kind tmpfs-enospc --fs-kb 256 --iterations 30 --seed 880005 --recsizes 64,1000,3000")
        $"if grep -qw vfat /proc/filesystems; then (do $fill 'fill-vfat-enospc' $'--kind vfat-enospc --image ($d)/enospc.img --fs-kb 1024 --iterations 10 --seed 880006 --recsizes 1000,3000,4000'); (do $fill 'fill-vfat-eio' $'--kind vfat-eio --backing ($d)/backing --image ($d)/backing/eio.img --fs-kb 1024 --backing-kb 192 --iterations 30 --seed 880007 --recsizes 64,1000,3000'); else echo 'vfat not in /proc/filesystems: loop scenarios skipped' >> ($d)/out/progress; fi"
        $"date -u +%FT%TZ > ($d)/out/campaign.done"
    ] | str join "\n"
}

def "main build" [--build-host: string = "ubuntu@ubrpi502.local"] {
    ^ssh -o BatchMode=yes $build_host $"mkdir -p ($BUILD_DIR)"
    ^scp -q hps/durable_commit_bench.c hps/durable_fault_harness.c $"($build_host):($BUILD_DIR)/"
    ^ssh -o BatchMode=yes $build_host $"cd ($BUILD_DIR) && for s in durable_commit_bench durable_fault_harness; do arm-linux-gnueabihf-gcc ($CFLAGS) -o $s.armv7 $s.c || exit 1; done; arm-linux-gnueabihf-gcc --version | head -1; sha256sum *.armv7"
    mkdir (scratch)
    ^scp -q $"($build_host):($BUILD_DIR)/durable_commit_bench.armv7" $"($build_host):($BUILD_DIR)/durable_fault_harness.armv7" (scratch)
    print $"binaries in (scratch)"
}

def "main preflight" [--host: string = "root@superstation1.local", --alias: string = "", --wait-min: int = 90] {
    let busy = "ps w | grep -E 'update_all|downloader|update\\.sh' | grep -v grep"
    mut waited = 0
    loop {
        let r = (board $host $alias $busy)
        if ($r.stdout | str trim | is-empty) { break }
        if $waited >= $wait_min { error make {msg: $"update_all/downloader still running after ($wait_min) min:\n($r.stdout)"} }
        print $"waiting for update_all/downloader \(($waited) min\):\n($r.stdout | str trim)"
        sleep 60sec
        $waited = $waited + 1
    }
    let env_cmd = "date -u +date=%FT%TZ; uname -a; hostname; grep -E ' / | /media/fat ' /proc/mounts; cat /sys/block/mmcblk0/queue/write_cache; grep -wE 'vfat|msdos|tmpfs|exfat' /proc/filesystems | tr '\\n' ' '; echo; ls /dev/loop-control; free -k | head -2; uptime; df -k /media/fat | tail -1; ps w | grep -E 'MiSTer|datadog' | grep -v grep | cut -c1-120"
    (board $host $alias $env_cmd).stdout
}

def "main push" [--host: string = "root@superstation1.local", --alias: string = ""] {
    board $host $alias $"mkdir -p ($BOARD_DIR)" | ignore
    let opts = if ($alias | is-empty) { [] } else { [-o $"HostKeyAlias=($alias)"] }
    ^scp -q -o BatchMode=yes ...$opts $"(scratch)/durable_commit_bench.armv7" $"(scratch)/durable_fault_harness.armv7" $"($host):($BOARD_DIR)/"
    (board $host $alias $"cd ($BOARD_DIR) && chmod 755 *.armv7 && sha256sum *.armv7").stdout
}

def "main run" [--host: string = "root@superstation1.local", --alias: string = "", --poll-sec: int = 30] {
    let c = (campaign)
    let started = (board $host $alias $"cd ($BOARD_DIR) && rm -f out/campaign.done && nohup sh -c '($c | str replace --all "'" "'\\''")' > campaign.log 2>&1 < /dev/null & echo started")
    print $started.stdout
    loop {
        sleep ($poll_sec * 1sec)
        let p = (board $host $alias $"cat ($BOARD_DIR)/out/progress 2>/dev/null; test -f ($BOARD_DIR)/out/campaign.done && echo CAMPAIGN_DONE")
        print ($p.stdout | lines | last 3 | str join " | ")
        if ($p.stdout | str contains "CAMPAIGN_DONE") { break }
    }
}

def "main fetch" [--host: string = "root@superstation1.local", --alias: string = "", --date: string] {
    let base = $"bench/superstation1/($date)/fault-injection"
    mkdir $"($base)/raw" $"($base)/records"
    let opts = if ($alias | is-empty) { [] } else { [-o $"HostKeyAlias=($alias)"] }
    ^scp -q -o BatchMode=yes ...$opts $"($host):($BOARD_DIR)/out/*" $"($base)/raw/"
    for m in (ls $"($base)/raw/*.metrics" | get name) {
        let name = ($m | path parse | get stem)
        let fs = if ($name | str contains "exfat") or ($name | str starts-with "selftest") { "exfat" } else if ($name | str contains "tmpfs") { "tmpfs" } else { "vfat-loop" }
        (nu bin/bench-record.nu --workload $"durable-fault-($name)" --runtime superstation1-mister-linux-armv7 --filesystem $fs
            --out $"($base)/records/durable-fault-($name).json"
            --notes $"smolFire #88 software fault injection around the #86 durable-commit writer \(model B, one outstanding op\). superstation1, MiSTer Linux 6.18.38 armv7l \(kernel updated by Update All 2026-09-25; #86 baseline was 5.15.1\), exFAT on microSD rw,sync,dirsync, SD write_cache=write through. Per-fault trace: raw/($name).jsonl. Times in ns. Software faults only \(SIGKILL, errno, ENOSPC, loop EIO\): says nothing about SD-internal buffering under power loss."
            $m)
    }
}

def main [] { print "subcommands: build | preflight | push | run | fetch --date YYYY-MM-DD (see header)" }
