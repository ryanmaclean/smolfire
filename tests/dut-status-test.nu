#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/dut-status-test.nu — tests for bin/dut-status.nu (no hardware needed).
#
# Mocks the hps/harness.c transport via a PATH shim: a fake `harness`
# executable that echoes canned PING/READ outputs. A state file counts PINGs
# so consecutive polls see an error-appearance transition (poll 1 clean, poll
# 2+ ERROR bit 0x4 + advanced watermarks) and PING starts failing once the
# count reaches $FAKE_DUT_FAIL_AT (link-loss scenario).

def fail [msg: string] {
    print $"dut-status-test: FAIL — ($msg)"
    exit 1
}

def fake-harness []: nothing -> string {
    r#'
#!/bin/sh
if [ "${1:-}" = "-t" ]; then shift 2; fi
STATE="${FAKE_DUT_STATE:-/tmp/fake-dut-state}"
FAIL_AT="${FAKE_DUT_FAIL_AT:-999999}"
if [ "${1:-}" = "ping" ]; then
    n=$(cat "$STATE" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" > "$STATE"
    if [ "$n" -ge "$FAIL_AT" ]; then
        echo "harness: PING failed" >&2; exit 1
    fi
    echo "harness: PONG version=1"; exit 0
elif [ "${1:-}" = "read" ]; then
    n=$(cat "$STATE" 2>/dev/null || echo 1)
    case "$2" in
        0x0c|0x10) if [ "$n" -le 1 ]; then v=100; else v=110; fi ;;
        0x48|0x4c) v=0 ;;
        0x18) if [ "$n" -le 1 ]; then v=0; else v=4; fi ;;
        0x28) v=4 ;;
        0x20) v=7 ;;
        0x58) v=1 ;;
        0x54) v=1146442288 ;;
        *) echo "fake-harness: bad addr $2" >&2; exit 1 ;;
    esac
    printf 'harness: READ %s = 0x%08x\n' "$2" "$v"; exit 0
else
    echo "fake-harness: unexpected args: $*" >&2; exit 2
fi
'#
}

def run-dashboard [shim: string, state: string, fail_at: string, args: list<string>]: nothing -> record {
    rm -f $state
    with-env {PATH: ([$shim] ++ $env.PATH), FAKE_DUT_STATE: $state, FAKE_DUT_FAIL_AT: $fail_at} {
        do { ^$nu.current-exe bin/dut-status.nu ...$args } | complete
    }
}

def check [cond: bool, msg: string] {
    if not $cond {
        fail $msg
    }
}

let work = (^mktemp -d | str trim)
let shim = ($work | path join "shim")
mkdir $shim
fake-harness | save -f ($shim | path join "harness")
^chmod +x ($shim | path join "harness")
let state = ($work | path join "dut-state")

# 1. --once renders a single snapshot line, exit 0.
let once = run-dashboard $shim $state "999999" [--once --interval 0]
check ($once.exit_code == 0) $"--once exited ($once.exit_code): ($once.stderr)"
for needle in ["durable=100" "visible=100" "err=0x0" "rst=7" "ver=1" "link=ok" "magic=0x44555230"] {
    check ($once.stdout | str contains $needle) $"--once missing: ($needle)\n($once.stdout)"
}
check (($once.stdout | lines | where {|l| ($l | str trim | str length) > 0 } | length) == 1) "--once should print exactly one line"

# 2. --once --json emits one JSON record, exit 0.
let oj = run-dashboard $shim $state "999999" [--once --json --interval 0]
check ($oj.exit_code == 0) $"--once --json exited ($oj.exit_code): ($oj.stderr)"
let rec = ($oj.stdout | str trim | from json)
check ($rec.link == true) $"--once --json link not true: ($oj.stdout)"
check ($rec.durable == 100 and $rec.visible == 100) $"--once --json watermarks wrong: ($oj.stdout)"
check ($rec.error == 0 and $rec.reset_cnt == 7 and $rec.version == 1) $"--once --json regs wrong: ($oj.stdout)"
check ($rec.magic == 1146442288) $"--once --json magic wrong: ($oj.stdout)"

# 3. Two polls: watermark advance + newly-appeared ERROR bits -> ALERT, exit 0.
let two = run-dashboard $shim $state "999999" [--count 2 --interval 0]
check ($two.exit_code == 0) $"--count 2 exited ($two.exit_code): ($two.stderr)"
for needle in ["durable=110" "rate=" "ops/s" "ALERT new ERROR bits" "0x4"] {
    check ($two.stdout | str contains $needle) $"--count 2 missing: ($needle)\n($two.stdout)"
}

# 4. Two polls in --json: second record carries rate + new-error alert.
let tj = run-dashboard $shim $state "999999" [--count 2 --interval 0 --json]
check ($tj.exit_code == 0) $"--count 2 --json exited ($tj.exit_code): ($tj.stderr)"
let rows = ($tj.stdout | lines | where {|l| ($l | str trim | str length) > 0 } | each {|l| $l | from json })
check (($rows | length) == 2) $"--count 2 --json should emit 2 records, got (($rows | length))"
check (($rows | get 1 | get durable) == 110) "--count 2 --json second durable != 110"
check (($rows | get 1 | get new_error_bits) == 4) "--count 2 --json second new_error_bits != 4"
check ((($rows | get 1 | get alerts) | length) > 0) "--count 2 --json second record should carry alerts"

# 5. Link loss mid-run: PING fails from poll 3, --retries 2 -> ALERT + exit != 0.
let down = run-dashboard $shim $state "3" [--count 5 --interval 0 --retries 2]
check ($down.exit_code != 0) $"link-loss should exit non-zero, got ($down.exit_code)"
check ($down.stdout | str contains "ALERT link down") $"link-loss missing ALERT:\n($down.stdout)"

# 6. --once against a dead link: retries exhausted -> ALERT + exit != 0.
let dead = run-dashboard $shim $state "1" [--once --interval 0 --retries 2]
check ($dead.exit_code != 0) $"dead-link --once should exit non-zero, got ($dead.exit_code)"
check ($dead.stdout | str contains "ALERT link down") $"dead-link --once missing ALERT:\n($dead.stdout)"

rm -rf $work
print "dut-status-test: ok"
