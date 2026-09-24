#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/lineage-sequencer-sim.nu — software-first transaction sequencer model for
# issue #73. It simulates a lock-free descriptor ring that can later map to an
# FPGA/SmartNIC/NVMe-backed sequencer, while keeping crash-consistency fences in
# software.

def kib-ceil [length: int] {
    (($length | into float) / 1024.0 | math ceil | into int)
}

def default-costs [] {
    {
        persist_fence_ns: 3000
        cpu_order_ns: 80
        cpu_timestamp_ns: 25
        cpu_append_ns: 95
        cpu_lineage_ns: 45
        cpu_hash_ns_per_kib: 72
        sequencer_setup_ns: 1560
        sequencer_ring_enqueue_ns: 65
        sequencer_dma_append_ns: 70
        sequencer_completion_ns: 35
        sequencer_sw_consistency_ns: 75
        sequencer_hash_ns_per_kib: 20
    }
}

def make-mutation [i: int, length: int] {
    {
        object: (1000 + $i)
        parent: (if $i == 0 { 0 } else { 999 + $i })
        run: 42
        op: (if ($i mod 2) == 0 { 1 } else { 2 })
        address: (4096 * ($i + 1))
        length: $length
    }
}

def make-batch [count: int] {
    let lengths = [1024 2048 4096 8192]
    0..<$count | each {|i|
        make-mutation $i ($lengths | get ($i mod ($lengths | length)))
    }
}

def cpu-cost-ns [mutations: list<any>, costs: record] {
    (
        $mutations
        | each {|m|
            let kib = kib-ceil $m.length
            $costs.cpu_order_ns +
            $costs.cpu_timestamp_ns +
            $costs.cpu_append_ns +
            $costs.cpu_lineage_ns +
            ($kib * $costs.cpu_hash_ns_per_kib)
        }
        | math sum
    ) + $costs.persist_fence_ns
}

def sequencer-cost-ns [mutations: list<any>, costs: record] {
    $costs.sequencer_setup_ns + (
        $mutations
        | each {|m|
            let kib = kib-ceil $m.length
            $costs.sequencer_ring_enqueue_ns +
            $costs.sequencer_dma_append_ns +
            $costs.sequencer_completion_ns +
            $costs.sequencer_sw_consistency_ns +
            ($kib * $costs.sequencer_hash_ns_per_kib)
        }
        | math sum
    ) + $costs.persist_fence_ns
}

def score-batch [count: int, costs: record] {
    let mutations = make-batch $count
    let bytes = ($mutations | get length | math sum)
    let cpu_ns = cpu-cost-ns $mutations $costs
    let sequencer_ns = sequencer-cost-ns $mutations $costs
    let delta_ns = $sequencer_ns - $cpu_ns

    {
        batch: $count
        bytes: $bytes
        cpu_ns: $cpu_ns
        sequencer_ns: $sequencer_ns
        delta_ns: $delta_ns
        winner: (if $delta_ns <= 0 { "sequencer" } else { "cpu" })
    }
}

def main [
    --max-batch: int = 256   # largest batch size to score (powers of two up to this value)
    --format: string = "table"  # table | json
] {
    if $max_batch < 1 {
        error make {msg: "--max-batch must be >= 1"}
    }

    let costs = default-costs
    let candidates = [1 2 4 8 16 32 64 128 256 512 1024] | where {|n| $n <= $max_batch }
    let rows = $candidates | each {|n| score-batch $n $costs }
    let break_even = ($rows | where {|r| $r.winner == "sequencer" } | get -o 0)

    let doc = {
        schema: "smolfire.lineage-sequencer-sim/v1"
        model: "software-ring-to-hardware-sequencer"
        break_even_batch: ($break_even | get batch? | default null)
        break_even_bytes: ($break_even | get bytes? | default null)
        decision: (if $break_even == null {
            "stay-cpu-only"
        } else {
            "prototype-lock-free-ring-first"
        })
        common_software_responsibilities: [
            "transaction durability fence (fs journal/NVMe flush or FUA)"
            "commit record assembly and replay rules"
            "crash recovery policy for partially published lineage"
            "OpenLineage/event export from committed TIDs only"
        ]
        assumptions: $costs
        rows: $rows
    }

    if $format == "json" {
        $doc | to json --indent 2
    } else if $format == "table" {
        print $"schema: ($doc.schema)"
        print $"decision: ($doc.decision)"
        print $"break-even batch: ($doc.break_even_batch | default 'none')"
        print $"break-even bytes: ($doc.break_even_bytes | default 'none')"
        print ""
        print ($rows)
    } else {
        error make {msg: "--format must be table or json"}
    }
}
