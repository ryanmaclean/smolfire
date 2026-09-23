#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/smolfire-metrics.nu — parse the SMOLFIRE microVM build/gate metrics.
#
# The microVM build and boot-gate paths emit machine-readable lines:
#   SMOLFIRE_METRIC key=value
#   SMOLFIRE_SECTION .name=value
# This script merges one or more logs into a reproducible before/after report.

def mib [bytes: int] {
    ($bytes / 1048576) | into float | math round --precision 2
}

def find-metric [metrics: table, key: string] {
    $metrics | where key == $key | get -o 0
}

def print-metric [metrics: table, key: string, label: string, unit: string = "bytes"] {
    let row = find-metric $metrics $key
    if $row == null {
        return
    }

    if $unit == "kib" {
        let mib = (($row.value * 1024) / 1048576) | into float | math round --precision 2
        print $"($label): ($row.value) KiB \((($mib)) MiB\)"
    } else {
        print $"($label): ($row.value) bytes \((mib $row.value) MiB\)"
    }
}

def main [
    ...logs: string              # one or more build/gate logs
    --top: int = 12              # ELF sections to print
] {
    let present = $logs | where {|p| $p | path exists}
    if ($present | is-empty) {
        print "smolfire-metrics: SKIP — no log files found"
        exit 0
    }

    let lines = $present | each {|p| open --raw $p | lines } | flatten

    let metrics = ($lines
        | parse --regex '^SMOLFIRE_METRIC (?<key>[^=]+)=(?<value>\d+)$'
        | each {|r| {key: $r.key, value: ($r.value | into int)} })
    let sections = ($lines
        | parse --regex '^SMOLFIRE_SECTION (?<name>\S+)=(?<bytes>\d+)$'
        | each {|r| {name: $r.name, bytes: ($r.bytes | into int)} }
        | sort-by --reverse bytes)

    if ($metrics | is-empty) and ($sections | is-empty) {
        print $"smolfire-metrics: no SMOLFIRE metric lines in ($present | str join ', ')"
        exit 1
    }

    print "SMOLFIRE microVM size report"
    print ""
    print-metric $metrics "mfs.bytes" "embedded MFS image"
    print-metric $metrics "rescue.bytes" "/rescue/rescue"
    print-metric $metrics "kernel.bytes" "kernel ELF"
    print-metric $metrics "kernel.text.bytes" "kernel text"
    print-metric $metrics "kernel.data.bytes" "kernel data"
    print-metric $metrics "kernel.bss.bytes" "kernel bss"
    print-metric $metrics "ready.vm.used.bytes" "post-READY guest used"
    print-metric $metrics "ready.host.rss_kib" "post-READY host RSS" "kib"

    if not ($sections | is-empty) {
        print ""
        print $"== ELF sections, top ($top) by bytes =="
        $sections
            | first $top
            | each {|r| {section: $r.name, bytes: $r.bytes, mib: (mib $r.bytes)} }
            | print
    }
}
