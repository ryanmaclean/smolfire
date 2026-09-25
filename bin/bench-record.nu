#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/bench-record.nu — emit a ryanlab.bench.v1 benchmark record from SMOLFIRE
# build/gate logs (the SMOLFIRE_METRIC / SMOLFIRE_SECTION lines produced by the
# microVM build and boot-gate paths; see bin/smolfire-metrics.nu).
#
# Contract: ryanmaclean/skills schemas/bench.v1.schema.json + docs/BENCHMARKING.md
#   "Measure once, project many times." — this script is the one producer;
#   Datadog/GitHub Actions/OpenLineage projections read the JSON it emits
#   instead of recomputing metrics. Raw measurements are never discarded:
#   every parsed SMOLFIRE_METRIC key is preserved under `metrics` even when a
#   named v1 field (artifact_bytes, boot_ms, ...) is also derived from it.
#
# Usage:
#   nu bin/bench-record.nu --workload one-elf-boot LOG [LOG ...]
#   nu bin/bench-record.nu --workload ffs-baseline --filesystem ffs --out bench.json LOG

def now-rfc3339 [] {
    date now | format date "%Y-%m-%dT%H:%M:%S%:z"
}

def parse-metric-lines [lines: list<string>] {
    $lines
        | parse --regex '^SMOLFIRE_METRIC (?<key>[^=]+)=(?<value>\d+)$'
        | each {|r| {key: $r.key, value: ($r.value | into int)} }
}

def parse-section-lines [lines: list<string>] {
    $lines
        | parse --regex '^SMOLFIRE_SECTION (?<name>\S+)=(?<bytes>\d+)$'
        | each {|r| {key: $"section.($r.name)", value: ($r.bytes | into int)} }
}

def parse-time-to-ready [lines: list<string>] {
    let hit = ($lines | parse --regex '^TIME_TO_READY=(?<ms>\d+)ms$')
    if ($hit | is-empty) { null } else { $hit | get 0.ms | into int }
}

def find [metrics: table, key: string] {
    let hit = ($metrics | where key == $key)
    if ($hit | is-empty) { null } else { $hit | get 0.value }
}

def git-commit [] {
    let r = (^git rev-parse --short HEAD | complete)
    if $r.exit_code == 0 { $r.stdout | str trim } else { null }
}

def main [
    ...logs: string           # SMOLFIRE_METRIC/_SECTION build/gate log paths
    --project: string = "smolfire"       # ryanlab.bench.v1 `project`
    --runtime: string = "smolfire-microvm" # ryanlab.bench.v1 `runtime`
    --filesystem: string = ""            # ryanlab.bench.v1 `filesystem`
    --workload: string                   # required: ryanlab.bench.v1 `workload`
    --commit: string = ""                # defaults to `git rev-parse --short HEAD`
    --notes: string = ""
    --out: string = ""                   # write JSON here instead of stdout
] {
    if ($workload | is-empty) {
        print "bench-record: ERROR — --workload is required"
        exit 1
    }

    let present = $logs | where {|p| $p | path exists}
    if ($present | is-empty) {
        print $"bench-record: ERROR — no log files found among: ($logs | str join ', ')"
        exit 1
    }

    let lines = $present | each {|p| open --raw $p | lines } | flatten

    let raw_metrics = (
        (parse-metric-lines $lines) | append (parse-section-lines $lines)
    )

    if ($raw_metrics | is-empty) {
        print $"bench-record: ERROR — no SMOLFIRE_METRIC/SMOLFIRE_SECTION lines in ($present | str join ', ')"
        exit 1
    }

    # Derive named v1 fields where the raw key maps cleanly; every raw key is
    # ALSO preserved below so nothing measured is ever thrown away.
    let artifact_bytes = (do {
        let k = (find $raw_metrics "kernel.bytes")
        if $k != null { $k } else { find $raw_metrics "mfs.bytes" }
    })
    let rss_bytes = (do {
        let v = (find $raw_metrics "ready.vm.used.bytes")
        if $v != null {
            $v
        } else {
            let kib = (find $raw_metrics "ready.host.rss_kib")
            if $kib != null { $kib * 1024 } else { null }
        }
    })
    let boot_ms = (parse-time-to-ready $lines)

    mut metrics = {}
    if $artifact_bytes != null { $metrics = ($metrics | insert artifact_bytes $artifact_bytes) }
    if $rss_bytes != null { $metrics = ($metrics | insert rss_bytes $rss_bytes) }
    if $boot_ms != null { $metrics = ($metrics | insert boot_ms $boot_ms) }

    # Preserve every raw SMOLFIRE_METRIC/_SECTION key verbatim (dots kept —
    # JSON object keys allow them; schema `metrics.additionalProperties` is
    # true so this never violates ryanlab.bench.v1).
    for row in $raw_metrics {
        $metrics = ($metrics | insert $row.key $row.value)
    }

    let resolved_commit = if not ($commit | is-empty) { $commit } else { git-commit }

    mut record = {
        schema: "ryanlab.bench.v1"
        project: $project
        timestamp: (now-rfc3339)
        runtime: $runtime
        filesystem: (if ($filesystem | is-empty) { null } else { $filesystem })
        workload: $workload
        commit: $resolved_commit
        metrics: $metrics
        tags: {
            project: $project
            runtime: $runtime
            workload: $workload
        }
    }
    if not ($notes | is-empty) { $record = ($record | insert notes $notes) }

    let json = ($record | to json --indent 2)
    if ($out | is-empty) {
        print $json
    } else {
        $json | save --force $out
        print $"bench-record: wrote ($out)"
    }
}
