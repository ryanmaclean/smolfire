#!/bin/sh
set -e
PASS=0
FAIL=0
SKIP=0
PYTHON3=""
PY_OK=""
PY_SKIP_REASON="python3 >= 3.10 required"
if command -v python3 >/dev/null 2>&1; then
    PYTHON3=$(command -v python3)
    PY_VERSION=$("$PYTHON3" --version 2>&1)
    if "$PYTHON3" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
        PY_OK=1
    else
        PY_SKIP_REASON="python3 >= 3.10 required (found $PY_VERSION at $PYTHON3)"
    fi
else
    PY_SKIP_REASON="python3 >= 3.10 required (python3 not found)"
fi
# Roster: every tests/*-test.nu and tests/*-test.py, plus gates whose names
# predate those patterns.
for f in tests/*-test.nu tests/*-test.py tests/coord-fsm-tests.nu; do
    [ -e "$f" ] || continue
    printf "running %s ... " "$f"
    case "$f" in
        *.py)
            if [ -z "$PY_OK" ]; then
                echo "skip ($PY_SKIP_REASON)"
                SKIP=$((SKIP + 1))
                continue
            fi
            output=$("$PYTHON3" "$f" 2>&1)
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
