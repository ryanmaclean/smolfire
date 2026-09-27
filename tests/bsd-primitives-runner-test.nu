#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Synthetic records exercise only runner rejection, never benchmark evidence.
def main [] {
    if $nu.os-info.name != "freebsd" { error make {msg: "native FreeBSD test required"} }
    let runner = ($env.FILE_PWD | path join ../bin/bsd-primitives.nu | path expand)
    let root = (^mktemp -d /tmp/smolfire-runner-test.XXXXXX | str trim)
    let fake = ($root | path join fixture.nu)
    let source = '#!/usr/bin/env nu
def main [mode: string, backing: string, iterations: int, warmup: int, seed: int] {
    mut r = {schema: "smolfire.bsd-primitives/v1", mode: $mode, backing: $backing,
        iterations: $iterations, warmup: $warmup, seed: $seed, validated: $iterations,
        os: "FreeBSD", lock_free: true, processes: 2, outstanding: 1, payload_bytes: 64,
        elapsed_ns: 100, roundtrips_per_second: 100.0}
    let field = $env.SMOLFIRE_RUNNER_BAD_FIELD
    if $field == "mutate" {
        "\n# fixture mutation\n" | save --append ($env.FILE_PWD | path join fixture.nu)
    } else if $field != "valid" {
        let old = ($r | get $field)
        let bad = match ($old | describe) {
            "string" => "wrong",
            "bool" => false,
            "float" => 0.0,
            _ => 0
        }
        $r = ($r | update $field $bad)
    }
    $r | to json
}
'
    $source | save $fake
    ^chmod 700 $fake
    mut passed = 0
    for field in [mode backing iterations warmup seed validated os lock_free processes outstanding payload_bytes elapsed_ns roundtrips_per_second mutate] {
        let output = ($root | path join $"($field).json")
        let result = (with-env {SMOLFIRE_RUNNER_BAD_FIELD: $field} {
            ^$nu.current-exe $runner $fake $output --iterations 12 --warmup 3 --seed 7 | complete
        })
        if $result.exit_code == 0 or ($output | path exists) {
            error make {msg: $"runner accepted bad ($field); fixtures retained at ($root)"}
        }
        let reason = if $field == "mutate" { "benchmark executable changed" } else { "incomplete or unexpected benchmark result" }
        if not ($result.stderr | str contains $reason) {
            error make {msg: $"wrong rejection for ($field): ($result.stderr)"}
        }
        $passed += 1
    }
    # A correctly labeled synthetic record must pass the validator. Keep it in
    # temporary test space and remove it; it is not real measurement evidence.
    let output = ($root | path join valid.json)
    let valid = (with-env {SMOLFIRE_RUNNER_BAD_FIELD: valid} {
        ^$nu.current-exe $runner $fake $output --iterations 12 --warmup 3 --seed 7 | complete
    })
    if $valid.exit_code != 0 or not ($output | path exists) { error make {msg: $valid.stderr} }
    let before = (open --raw $output | hash sha256)
    let existing = (with-env {SMOLFIRE_RUNNER_BAD_FIELD: valid} {
        ^$nu.current-exe $runner $fake $output --iterations 12 --warmup 3 --seed 7 | complete
    })
    if $existing.exit_code == 0 or (open --raw $output | hash sha256) != $before {
        error make {msg: "runner overwrote existing evidence"}
    }
    $passed += 2
    rm -r $root
    {schema: "smolfire.bsd-primitives-runner-tests/v1", synthetic_contract_cases: $passed, failed: 0} | to json
}
