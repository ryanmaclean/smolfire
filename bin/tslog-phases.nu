#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/tslog-phases.nu — turn SMOLFIRE-TSLOG serial captures into a boot
# phase table (docs/BOOT-TIME-ROADMAP.md §1/§3).
#
# Input: a directory holding the smolfire.yml tslog=true artifacts —
#   tslog-runN.log    serial capture of a SMOLFIRE-TSLOG boot: gate markers,
#                     TIME_TO_READY=<ms> (wall clock, expect), and the dump
#                     between SMOLFIRE_TSLOG_{META,BEGIN,END,USER_BEGIN,USER_END}
#   release-runN.log  serial capture of a release SMOLFIRE boot (wall only)
#
# Clock model: debug.tslog stamps are guest TSC cycles; KVM starts a vCPU's
# TSC at 0 on creation, so tsc/tsc_freq is "ms since vCPU creation". The
# expect wall clock starts at VMM exec, hence
#   VMM exec → vCPU TSC 0  =  wall(READY) − tsc(READY)
# where tsc(READY) is the exit stamp of the /rescue/echo that printed
# SMOLFIRE_READY (debug.tslog_user). The epoch assumption is checked: if the
# first kernel record is later than the wall-clock READY, the pre-kernel
# split is reported as null instead of a wrong number.
#
# Kernel phase boundaries (TSLOG ENTER/EXIT records):
#   first record (hammer_time) → mi_startup → start_init{ vfs_mountroot } →
#   start_init EXIT (exec /sbin/init) → READY
#
# Output (AX-first): JSON {schema: "smolfire.tslog-phases/v1", ...} on stdout;
# --md prints the markdown tables used in the roadmap instead.
# Not a port of cperciva/freebsd-boot-profiling (unlicensed; its flame
# chart script derives from CDDL FlameGraph) — independent aggregator.
#
# Usage: nu bin/tslog-phases.nu --dir docs/boot-time/2026-09-22 [--md]

const REC_RE = '^(?P<td>0x[0-9a-f]+) (?P<tsc>[0-9]+) (?P<type>ENTER|EXIT|THREAD|EVENT) (?P<rest>.*)$'
const USER_RE = '^(?P<pid>[0-9]+) (?P<ppid>[0-9]+) (?P<fork>[0-9]+) (?P<exit>[0-9]+) "(?P<exec>[^"]*)" "(?P<namei>[^"]*)"$'

def median [xs: list] {
    let s = $xs | sort
    let n = $s | length
    if $n == 0 { return null }
    if ($n mod 2) == 1 { $s | get ($n // 2) } else { (($s | get ($n // 2 - 1)) + ($s | get ($n // 2))) / 2 }
}

def r1 [x] { if $x == null { null } else { $x | math round -p 1 } }

# Lines strictly between two marker lines (serial adds \r; kernel console
# messages may interleave — callers regex-filter).
def section [lines: list<string>, begin: string, end: string] {
    let b = $lines | enumerate | where item == $begin | get 0?.index
    let e = $lines | enumerate | where item == $end | get 0?.index
    if $b == null or $e == null { return [] }
    $lines | skip ($b + 1) | first ($e - $b - 1)
}

# ENTER/EXIT pairing per thread → frames with inclusive/self cycles.
def frames [recs: list] {
    mut stacks = {}      # td -> list of open {name, tsc, child}
    mut out = []
    for r in $recs {
        if $r.type == "ENTER" {
            let st = $stacks | get -o $r.td | default []
            $stacks = ($stacks | upsert $r.td ($st | append {name: $r.name, tsc: $r.tsc, child: 0}))
        } else if $r.type == "EXIT" {
            let st = $stacks | get -o $r.td | default []
            # pop to the matching frame (tolerate unbalanced records)
            let idx = $st | enumerate | where {|x| $x.item.name == $r.name } | last | get -o index
            if $idx != null {
                let fr = $st | get $idx
                let incl = $r.tsc - $fr.tsc
                let depth = $idx
                let parent = if $idx > 0 { ($st | get ($idx - 1)).name } else { "" }
                $out = ($out | append {td: $r.td, name: $fr.name, parent: $parent, depth: $depth,
                                       enter: $fr.tsc, incl: $incl, self: ($incl - $fr.child)})
                mut nst = $st | first $idx
                if $idx > 0 {
                    let p = $nst | last
                    $nst = ($nst | drop 1 | append ($p | upsert child ($p.child + $incl)))
                }
                $stacks = ($stacks | upsert $r.td $nst)
            }
        }
    }
    $out
}

def analyze-run [path: string] {
    # Serial lines end "\r\r\n" (tty onlcr on top of the console's CR) and
    # `sysctl -b` leaves its string NUL just before the END marker.
    let lines = open --raw $path | decode utf-8 | lines | each {|l| $l | str replace -a -r '[\r\x00]' "" | str trim -r }
    let wall = $lines | parse -r 'TIME_TO_READY=(?P<ms>[0-9]+)ms' | get 0?.ms | default null
    let meta = $lines | parse -r '^SMOLFIRE_TSLOG_META tsc_freq=(?P<freq>[0-9]+)' | get 0?.freq
    if $meta == null { error make {msg: $"($path): no SMOLFIRE_TSLOG_META line — not a TSLOG capture"} }
    let freq = $meta | into int
    let ms = {|tsc| $tsc * 1000.0 / $freq }

    let raw = section $lines "SMOLFIRE_TSLOG_BEGIN" "SMOLFIRE_TSLOG_END"
    let recs = $raw | parse -r $REC_RE | each {|r|
        let parts = $r.rest | split row " "
        {td: $r.td, tsc: ($r.tsc | into int), type: $r.type,
         f: ($parts | first), s: ($parts | skip 1 | str join " ")}
    } | each {|r| $r | insert name (if $r.s == "" { $r.f } else { $"($r.f) ($r.s)" }) }
    let rejected = ($raw | length) - ($recs | length)
    let users = section $lines "SMOLFIRE_TSLOG_USER_BEGIN" "SMOLFIRE_TSLOG_USER_END"
        | parse -r $USER_RE
        | each {|u| {pid: ($u.pid | into int), ppid: ($u.ppid | into int), fork: ($u.fork | into int),
                     exit: ($u.exit | into int), exec: $u.exec, namei: $u.namei} }

    let find = {|type, name| $recs | where type == $type and name == $name | get 0?.tsc }
    let t_first = $recs | get tsc | math min
    let t_mi = do $find "ENTER" "mi_startup"
    let t_si = do $find "ENTER" "start_init"
    let t_se = do $find "EXIT" "start_init"
    let t_mr = do $find "ENTER" "vfs_mountroot"
    let t_mre = do $find "EXIT" "vfs_mountroot"
    if $t_se == null {
        error make {msg: $"($path): no 'EXIT start_init' record — TSLOG buffer overflow (raise TSLOGSIZE) or truncated capture"}
    }
    let echo = $users | where {|u| $u.exec | str ends-with "/echo" } | last
    let t_ready = if $echo != null { if $echo.exit > 0 { $echo.exit } else { $echo.fork } } else { null }
    if $t_ready == null { error make {msg: $"($path): no /rescue/echo in debug.tslog_user — READY anchor missing"} }

    let ready_ms = do $ms $t_ready
    let first_ms = do $ms $t_first
    let epoch_ok = $wall != null and $first_ms < ($wall | into int)
    let wall_ms = if $wall == null { null } else { $wall | into int }
    let d = {|a, b| if $a == null or $b == null { null } else { (do $ms $b) - (do $ms $a) } }
    let mount_ms = do $d $t_mr $t_mre
    let phases = {
        vmm_to_vcpu:      (if $epoch_ok { $wall_ms - $ready_ms } else { null })
        vcpu_to_kernel:   (if $epoch_ok { $first_ms } else { null })
        early_kernel:     (do $d $t_first $t_mi)
        sysinit_devices:  (do $d $t_mi $t_si)
        root_mount:       $mount_ms
        start_init_other: (let si = (do $d $t_si $t_se); if $si == null { null } else { $si - ($mount_ms | default 0) })
        init_rc_to_ready: (do $d $t_se $t_ready)
        wall_to_ready:    $wall_ms
        kernel_first_to_ready: (do $d $t_first $t_ready)
    } | transpose k v | each {|x| {k: $x.k, v: (r1 $x.v)} } | transpose -r -d

    let fr = frames $recs
    let sysinits = $fr | where {|f| $f.name | str starts-with "SYSINIT " }
        | each {|f| {name: ($f.name | str replace "SYSINIT " ""), incl_ms: (r1 ($f.incl * 1000.0 / $freq)), self_ms: (r1 ($f.self * 1000.0 / $freq))} }
        | sort-by incl_ms -r
    let funcs = $fr | where {|f| not ($f.name | str starts-with "SYSINIT ") }
        | each {|f| {name: $f.name, parent: $f.parent, incl_ms: (r1 ($f.incl * 1000.0 / $freq)), self_ms: (r1 ($f.self * 1000.0 / $freq))} }
        | sort-by self_ms -r
    # Same frames summed by name: repeated small costs (uart probes, printf
    # to the 9600-baud console) rank by their total, not their largest call.
    let self_sum = $fr | group-by name | items {|k, v|
        {name: $k, calls: ($v | length), self_ms: (r1 (($v | get self | math sum) * 1000.0 / $freq)),
         incl_ms: (r1 (($v | get incl | math sum) * 1000.0 / $freq))}
    } | sort-by self_ms -r
    let procs = $users | where fork > 0 | sort-by fork | each {|u|
        {pid: $u.pid, ppid: $u.ppid, exec: $u.exec,
         start_ms: (r1 (do $ms $u.fork)),
         dur_ms: (if $u.exit > 0 { r1 ((do $ms $u.exit) - (do $ms $u.fork)) } else { null })}
    }
    {
        file: ($path | path basename)
        tsc_freq: $freq
        records: ($recs | length), rejected_lines: $rejected
        epoch_vm_relative: $epoch_ok
        phases_ms: $phases
        top_sysinit: ($sysinits | first 12)
        top_self: ($funcs | first 12)
        top_self_by_name: ($self_sum | first 15)
        user_procs: $procs
    }
}

def stats [xs: list] {
    let v = $xs | compact
    if ($v | is-empty) { return {n: 0, median: null, min: null, max: null} }
    {n: ($v | length), median: (r1 (median $v)), min: (r1 ($v | math min)), max: (r1 ($v | math max))}
}

def main [
    --dir: string       # directory with tslog-runN.log / release-runN.log
    --md                # print markdown tables instead of JSON
] {
    let tfiles = glob $"($dir)/tslog-run*.log" | sort
    let rfiles = glob $"($dir)/release-run*.log" | sort
    if ($tfiles | is-empty) { error make {msg: $"no tslog-run*.log in ($dir)"} }
    let runs = $tfiles | each {|f| analyze-run $f }
    let release_wall = $rfiles | each {|f|
        open --raw $f | decode utf-8 | parse -r 'TIME_TO_READY=(?P<ms>[0-9]+)ms' | get 0?.ms
    } | compact | each {|x| $x | into int }
    let keys = $runs | first | get phases_ms | columns
    let phase_stats = $keys | each {|k| {phase: $k} | merge (stats ($runs | get phases_ms | get $k)) }
    # SYSINIT medians across runs (by name)
    let si_names = $runs | get top_sysinit | flatten | get name | uniq
    let si = $si_names | each {|n|
        let xs = $runs | each {|r| $r.top_sysinit | where name == $n | get 0?.incl_ms } | compact
        {name: $n, runs: ($xs | length), median_incl_ms: (r1 (median $xs))}
    } | sort-by median_incl_ms -r | first 10
    let doc = {
        schema: "smolfire.tslog-phases/v1"
        method: "TSLOG (kernel debug.tslog + debug.tslog_user) + expect wall clock"
        release_wall_to_ready_ms: (stats $release_wall | insert values $release_wall)
        phases: $phase_stats
        top_sysinit_median: $si
        runs: $runs
    }
    if not $md { return ($doc | to json) }
    print "Phases (TSLOG kernel, ms; median / min / max over runs):"
    print ($phase_stats | to md)
    print $"Release SMOLFIRE wall clock exec→READY: ($doc.release_wall_to_ready_ms | reject values | to nuon) values=($release_wall | to nuon)"
    print "Top SYSINITs (median inclusive ms):"
    print ($si | to md)
    print "Top self-time frames (run 1):"
    print ($runs | first | get top_self | to md)
    print "Self time summed by frame name (run 1):"
    print ($runs | first | get top_self_by_name | to md)
    print "Userland processes (run 1):"
    print ($runs | first | get user_procs | to md)
}
