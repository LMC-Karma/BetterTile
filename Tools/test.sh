#!/bin/bash
# Save the full output and reject successful exits from unfinished test products.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 LOG [--expected-runs N] [--release] [swift test arguments...]" >&2
    exit 2
fi
log="$1"
shift
expected=3
if [[ ${1:-} == --expected-runs ]]; then
    expected="${2:-}"
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || { echo "Expected a positive run count." >&2; exit 2; }
    shift 2
fi
# Testability belongs to this lane only. Keep Release product behaviour.
if [[ ${1:-} == --release ]]; then
    shift
    set -- -c release -Xswiftc -enable-testing "$@"
fi
# Keep pipefail: a helper failure, build failure, or tee failure must fail this command.
swift test "$@" 2>&1 | tee "$log"
"$script_dir/check-test-log.sh" "$log" "$expected"
