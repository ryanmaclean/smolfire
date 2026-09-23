#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
# Roster: every tests/*-test.nu, plus gates whose names predate that pattern.
for f in tests/*-test.nu tests/coord-fsm-tests.nu; do
    printf "running %s ... " "$f"
    output=$(nu "$f" 2>&1) || { echo "FAILED"; FAIL=$((FAIL + 1)); continue; }
    if printf '%s\n' "$output" | grep -q ': SKIP —'; then
        echo "skip"
        SKIP=$((SKIP + 1))
    else
        echo "ok"
        PASS=$((PASS + 1))
    fi
done
echo ""
echo "results: $PASS passed, $SKIP skipped, $FAIL failed"
[ $FAIL -eq 0 ]
