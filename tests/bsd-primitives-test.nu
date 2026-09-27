#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Native contract tests: execute only on a BSD host with the compiled binary.
def main [binary: path] {
    if $nu.os-info.name != "freebsd" { error make {msg: "native FreeBSD test required"} }
    let exe = ($binary | path expand)
    mut passed = 0
    for mode in [poll kqueue] {
        for backing in [anon file] {
            let result = (^$exe $mode $backing 2000 100 20260927 | complete)
            if $result.exit_code != 0 { error make {msg: $"($mode)/($backing): ($result.stderr)"} }
            let r = ($result.stdout | from json)
            if ($r.schema != "smolfire.bsd-primitives/v1" or $r.mode != $mode or $r.backing != $backing or
                $r.iterations != 2000 or $r.validated != 2000 or $r.warmup != 100 or $r.seed != 20260927 or
                $r.payload_bytes != 64 or $r.processes != 2 or $r.outstanding != 1 or not $r.lock_free or
                $r.os != "FreeBSD" or $r.elapsed_ns <= 0 or $r.roundtrips_per_second <= 0) {
                error make {msg: $"invalid measurement contract: ($r | to nuon)"}
            }
            let l = $r.latency_ns
            if not ($l.min <= $l.p50 and $l.p50 <= $l.p95 and $l.p95 <= $l.p99 and $l.p99 <= $l.max) {
                error make {msg: "latency percentiles are not ordered"}
            }
            $passed += 1
            # Corrupt the last payload byte after warmup. Actual consumer must
            # reject it; a timing-only or first-word-only benchmark fails here.
            let broken = (^$exe $mode $backing 200 10 20260927 73 | complete)
            if ($broken.exit_code != 3 or ($broken.stdout | str trim | is-not-empty) or
                not ($broken.stderr | str contains "integrity_error=1")) {
                error make {msg: $"corruption not rejected by ($mode)/($backing): ($broken | to nuon)"}
            }
            $passed += 1
            let unordered = (^$exe $mode $backing 200 10 20260927 73 future | complete)
            if ($unordered.exit_code != 3 or ($unordered.stdout | str trim | is-not-empty) or
                not ($unordered.stderr | str contains "integrity_error=2")) {
                error make {msg: $"future sequence not rejected by ($mode)/($backing): ($unordered | to nuon)"}
            }
            $passed += 1
        }
    }
    for args in [[poll anon 0 0 1] [unknown anon 1 0 1] [poll anon -1 0 1]] {
        let invalid = (^$exe ...$args | complete)
        if $invalid.exit_code != 2 or ($invalid.stdout | str trim | is-not-empty) {
            error make {msg: $"invalid arguments accepted: ($args | to nuon)"}
        }
        $passed += 1
    }
    {schema: "smolfire.bsd-primitives-tests/v1", passed: $passed, failed: 0} | to json
}
