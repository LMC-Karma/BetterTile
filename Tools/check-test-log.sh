#!/bin/bash
# Require one completed Swift Testing run for each expected test product.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ! ${2:-3} =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 LOG [EXPECTED_RUNS (default: 3)]" >&2
    exit 2
fi
awk -v expected="${2:-3}" '
    /Test run started\./ {
        if (active) {
            print "An earlier test product has no completion summary." > "/dev/stderr"
            bad = 1
        }
        active = 1
        starts++
    }
    /Test run with [0-9]+ tests?.* (passed|failed) after [0-9.]+ seconds/ {
        if (!active || $0 ~ /Test run with 0 tests/ || $0 ~ / failed after /) bad = 1
        active = 0
        finishes++
    }
    END {
        if (active || starts != expected || finishes != expected || bad) {
            printf "Incomplete or failed tests: %d starts, %d summaries; expected %d complete passing products.\n", starts, finishes, expected > "/dev/stderr"
            exit 1
        }
        printf "Verified %d complete passing test products.\n", finishes
    }
' "$1"
