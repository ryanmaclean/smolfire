#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/boot-phases.nu — serial-timestamp boot phase measurement (QEMU aarch64).
#
# Boots a disk image N times under QEMU (HVF on Apple Silicon), polls the
# serial file every --poll-ms, stamps each serial line with ms since QEMU
# exec, and derives phase boundaries from well-known console markers:
#
#   exec ──firmware──▶ loader ──loader──▶ kernel ──kernel──▶ root mount
#        ──mount→rc──▶ first rc line ──rc──▶ login:
#
# Resolution is --poll-ms (default 10 ms) plus QEMU's own buffering; this is
# the wall-clock "serial-timestamp" method of docs/BOOT-TIME-ROADMAP.md, not
# TSLOG (bin/tslog-phases.nu is the kernel-internal counterpart).
#
# Output (AX-first): one JSON document on stdout —
#   {schema: "smolfire.boot-phases/v1", env, image, runs: [...], summary: {...}}
# plus raw timestamped logs "<out-dir>/<label>-runN.log" ("+NNNNNms <line>").
# The image is opened snapshot=on: never modified.
#
# Usage:
#   nu bin/boot-phases.nu --image build/FreeBSD-15-aarch64-smolbsd.qcow2 \
#       --out-dir docs/boot-time/2026-09-22 --label aarch64-hvf --runs 3

# Phase markers: first serial line matching each regex (in order; each must
# come after the previous one). Tuned to FreeBSD 15 arm64 EFI + rc output.
const MARKERS = [
    [name        regex];
    [loader      '(?i)FreeBSD/arm64 EFI loader|^Consoles:|FreeBSD EFI boot block']
    [kernel      '---<<BOOT>>---|^Copyright \(c\) 1992']
    [root_mount  '^Trying to mount root|^Mounting from ']
    [rc          '^Setting hostuuid|^Setting hostid|^Starting file system checks|^ELF ldconfig|^Loading kernel modules']
    [login       'login:']
]

def median [xs: list<int>] {
    let s = $xs | sort
    let n = $s | length
    if $n == 0 { return null }
    if ($n mod 2) == 1 { $s | get ($n // 2) } else { (($s | get ($n // 2 - 1)) + ($s | get ($n // 2))) // 2 }
}

def now-ms [] { (date now | into int) // 1_000_000 }

# One boot: returns {run, lines: [{ms, line}], markers: {name: ms}}.
def boot-once [qemu: string, bios: string, image: string, mem: string, cpus: int,
               accel: string, nic: string, extra: list<string>, poll_ms: int, timeout_s: int, workdir: string, run: int] {
    let raw = $"($workdir)/serial-run($run).raw"
    let pidf = $"($workdir)/qemu-run($run).pid"
    rm -f $raw $pidf
    let t0 = now-ms
    ^$qemu -machine $"virt,accel=($accel)" -cpu host -bios $bios -m $mem -smp ($cpus | into string) -drive $"file=($image),format=qcow2,if=virtio,snapshot=on" -nic $nic -display none -monitor none -serial $"file:($raw)" -daemonize -pidfile $pidf ...$extra
    mut stamped = []      # [{ms, line}] for completed segments
    mut done = false
    let deadline = $t0 + $timeout_s * 1000
    while not $done {
        let now = now-ms
        if ($raw | path exists) {
            let text = open --raw $raw | decode utf-8 | ansi strip
            # Complete segments end in \n or \r; the tail may be partial.
            let segs = $text | split row -r '\r\n|\n|\r'
            let complete = ($segs | length) - 1
            let have = $stamped | length
            if $complete > $have {
                let fresh = $segs | skip $have | first ($complete - $have) | each {|l| {ms: ($now - $t0), line: $l} }
                $stamped = ($stamped | append $fresh)
            }
            if ($text | str contains "login:") {
                let tail = $segs | last
                if ($tail | str contains "login:") { $stamped = ($stamped | append {ms: ($now - $t0), line: $tail}) }
                $done = true
            }
        }
        if $now > $deadline { $done = true }
        if not $done { sleep ($poll_ms * 1ms) }
    }
    if ($pidf | path exists) { ^kill (open --raw $pidf | str trim) }
    sleep 500ms
    let lines = $stamped | where {|r| ($r.line | str trim) != "" }
    # Walk markers in order; each search starts after the previous hit.
    mut markers = {first_byte: ($lines | get 0?.ms)}
    mut from = 0
    for m in $MARKERS {
        let hit = $lines | enumerate | skip $from | where {|r| $r.item.line =~ $m.regex } | get 0?
        if $hit != null {
            $markers = ($markers | insert $m.name $hit.item.ms)
            $from = $hit.index + 1
        } else {
            $markers = ($markers | insert $m.name null)
        }
    }
    {run: $run, lines: $lines, markers: $markers, timed_out: ($markers.login == null)}
}

def main [
    --image: string                 # disk image (qcow2), opened snapshot=on
    --runs: int = 3
    --out-dir: string = "."         # where <label>-runN.log raw logs go
    --label: string = "aarch64-hvf"
    --qemu: string = "/opt/homebrew/bin/qemu-system-aarch64"
    --bios: string = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    --accel: string = "hvf"
    --mem: string = "256M"
    --cpus: int = 2
    --nic: string = "user,model=virtio-net-pci"   # "none" = control run without a NIC
    --qemu-extra: string = ""       # space-separated extra QEMU argv, e.g. "-boot menu=on,splash-time=0"
    --poll-ms: int = 10
    --timeout: int = 120            # seconds per boot
] {
    if $image == null or not ($image | path exists) { error make {msg: $"--image not found: ($image)"} }
    mkdir $out_dir
    let workdir = (^mktemp -d | str trim)
    let extra = if ($qemu_extra | str trim) == "" { [] } else { $qemu_extra | str trim | split row -r '\s+' }
    let load_before = (^sysctl -n vm.loadavg | str trim)
    let results = 1..$runs | each {|i|
        let r = boot-once $qemu $bios $image $mem $cpus $accel $nic $extra $poll_ms $timeout $workdir $i
        $r.lines | each {|l| $"+($l.ms | fill -a r -w 6 -c '0')ms ($l.line)" } | str join "\n" | save -f $"($out_dir)/($label)-run($i).log"
        {run: $i, timed_out: $r.timed_out, markers: $r.markers}
    }
    rm -rf $workdir
    # Phase durations per run (null when a boundary is missing).
    let bounds = [[phase from to];
        [firmware   exec        loader]
        [loader     loader      kernel]
        [kernel     kernel      root_mount]
        [mount_to_rc root_mount rc]
        [rc_to_login rc         login]
        [total      exec        login]]
    let per_run = $results | each {|r|
        let m = $r.markers | insert exec 0
        let ph = $bounds | reduce -f {} {|b, acc|
            let a = $m | get $b.from
            let z = $m | get $b.to
            $acc | insert $b.phase (if $a != null and $z != null { $z - $a } else { null })
        }
        {run: $r.run, timed_out: $r.timed_out, markers_ms: $r.markers, phases_ms: $ph}
    }
    let summary = $bounds | each {|b|
        let xs = $per_run | get phases_ms | get $b.phase | compact
        {phase: $b.phase, n: ($xs | length), median_ms: (median $xs),
         min_ms: ($xs | math min), max_ms: ($xs | math max)}
    }
    let qv = (^$qemu --version | lines | first)
    let env_rec = {
        host: (^sysctl -n hw.model | str trim)
        cpu: (^sysctl -n machdep.cpu.brand_string | str trim)
        macos: (^sw_vers -productVersion | str trim)
        qemu: $qv, accel: $accel, mem: $mem, cpus: $cpus, nic: $nic, qemu_extra: $qemu_extra, poll_ms: $poll_ms
        loadavg_before: $load_before, loadavg_after: (^sysctl -n vm.loadavg | str trim)
        date: (date now | format date "%Y-%m-%dT%H:%M:%S%z")
    }
    {
        schema: "smolfire.boot-phases/v1"
        method: "serial-timestamp"
        env: $env_rec
        image: {path: $image, sha256: (^shasum -a 256 $image | split row " " | first)}
        runs: $per_run
        summary: $summary
    } | to json
}
