#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Measure existing software primitives. Compilation is an explicit prior step.
def positive-finite [value: any] {
    (($value | describe) in [int float]) and $value > 0 and $value <= 1.7976931348623157e308
}
def main [binary: path, output: path, --iterations: int = 100000, --warmup: int = 1000, --seed: int = 20260927] {
    if $nu.os-info.name != "freebsd" { error make {msg: "native FreeBSD measurement required"} }
    if $iterations < 1 or $iterations > 10000000 or $warmup < 0 or $warmup > 10000000 {
        error make {msg: "iterations must be 1..10000000; warmup 0..10000000"}
    }
    if ($output | path exists) { error make {msg: "refusing to overwrite existing measurement"} }
    let exe = ($binary | path expand)
    let binary_hash = (open --raw $exe | hash sha256)
    mut environment = {}
    for key in [hw.model hw.ncpu kern.vm_guest] {
        let value = (^sysctl -n $key | complete)
        if $value.exit_code != 0 { error make {msg: $"cannot capture environment ($key)"} }
        $environment = ($environment | insert $key ($value.stdout | str trim))
    }
    let started = (date now | format date "%Y-%m-%dT%H:%M:%S%z")
    mut measurements = []
    for mode in [poll kqueue] {
        for backing in [anon file] {
            let result = (^$exe $mode $backing $iterations $warmup $seed | complete)
            if $result.exit_code != 0 { error make {msg: $"($mode)/($backing) failed: ($result.stderr)"} }
            let record = ($result.stdout | from json)
            if ($record.schema != "smolfire.bsd-primitives/v1" or $record.validated != $iterations or
                $record.mode != $mode or $record.backing != $backing or $record.iterations != $iterations or
                $record.warmup != $warmup or $record.seed != $seed or $record.os != "FreeBSD" or
                $record.lock_free != true or $record.processes != 2 or $record.outstanding != 1 or
                $record.payload_bytes != 64 or not (positive-finite $record.elapsed_ns) or
                not (positive-finite $record.roundtrips_per_second)) {
                error make {msg: "incomplete or unexpected benchmark result"}
            }
            $measurements = ($measurements | append $record)
        }
    }
    if (open --raw $exe | hash sha256) != $binary_hash {
        error make {msg: "benchmark executable changed during measurement"}
    }
    let record = {schema: "smolfire.bsd-primitives-run/v1", started: $started,
        finished: (date now | format date "%Y-%m-%dT%H:%M:%S%z"),
        binary_sha256: $binary_hash, environment: $environment, measurements: $measurements,
        limits: ["unbound processes; scheduler and host load affect latency",
                 "file mapping is shared-memory visibility, not persistent-media durability",
                 "kqueue observes pipe notification; data remains in the shared mapping",
                 "device mapping, bus_dma, HPS DMA and ACP are not measured"]}
    $record | to json | save $output
    $record
}
