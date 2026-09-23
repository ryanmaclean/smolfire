#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
PARTIAL=0
# Roster: every tests/*-test.nu, plus gates whose names predate that pattern.
for f in tests/*-test.nu tests/coord-fsm-tests.nu; do
    printf "running %s ... " "$f"
    output=$(nu "$f" 2>&1) || { echo "FAILED"; FAIL=$((FAIL + 1)); continue; }
    if printf '%s\n' "$output" | grep -q ': SKIP —'; then
        echo "skip"
        SKIP=$((SKIP + 1))
    else
        # A file can pass while skipping individual cases (they print
        # "(skipped: ...)" / "(skipped as root)"). Surface those so a case that
        # never ran is not indistinguishable from one that passed.
        partial=$(printf '%s\n' "$output" | grep -c '^[[:space:]]*(skipped' || true)
        if [ "$partial" -gt 0 ]; then
            echo "ok ($partial case(s) skipped)"
            PARTIAL=$((PARTIAL + partial))
        else
            echo "ok"
        fi
        PASS=$((PASS + 1))
    fi
done
echo ""
echo "results: $PASS passed, $SKIP skipped, $FAIL failed ($PARTIAL case(s) skipped inside passing files)"
[ $FAIL -eq 0 ]
