#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
PY_OK=""
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
        PY_OK=1
    fi
fi
# Roster: every tests/*-test.nu and tests/*-test.py, plus gates whose names
# predate those patterns.
for f in tests/*-test.nu tests/*-test.py tests/coord-fsm-tests.nu; do
    [ -e "$f" ] || continue
    printf "running %s ... " "$f"
    case "$f" in
        *.py)
            if [ -z "$PY_OK" ]; then
                output="$(basename "$f" .py): SKIP — python3 >= 3.10 required"
            else
                output=$(python3 "$f" 2>&1)
            fi
            ;;
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
