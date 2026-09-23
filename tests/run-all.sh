#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
# Roster: every tests/*-test.nu and tests/*-test.py, plus gates whose names
# predate those patterns.
for f in tests/*-test.nu tests/*-test.py tests/coord-fsm-tests.nu; do
    [ -e "$f" ] || continue
    printf "running %s ... " "$f"
    case "$f" in
        *.py) output=$(python3 "$f" 2>&1) ;;
        *)    output=$(nu "$f" 2>&1) ;;
    esac || { echo "FAILED"; FAIL=$((FAIL + 1)); continue; }
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
