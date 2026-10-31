#!/bin/bash
# Save the full output and reject successful exits from unfinished test products.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 LOG [--expected-runs N] [--release] [swift test arguments...]" >&2
    exit 2
fi
# Exporting every UI snapshot blocks the main actor long enough to invalidate
# timing tests. Capture separately with a filter selecting snapshot suites only.
if [[ ${BT_SNAPSHOT_DIR+x} ]]; then
    echo "Snapshot export is separate from suite validation. Unset BT_SNAPSHOT_DIR and retry; use swift test --filter '<SnapshotTests suite>' for captures." >&2
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
# Testability and hooks belong to this lane only. Keep Release product behaviour.
if [[ ${1:-} == --release ]]; then
    shift
    set -- -c release -Xswiftc -enable-testing -Xswiftc -DBETTERTILE_TEST_HOOKS "$@"
fi
# Keep pipefail: a helper failure, build failure, or tee failure must fail this command.
swift test "$@" 2>&1 | tee "$log"
"$script_dir/check-test-log.sh" "$log" "$expected"
