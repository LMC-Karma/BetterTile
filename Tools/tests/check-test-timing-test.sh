#!/bin/bash
# Exercise the guard against source fixtures; never compile or run Swift.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/Tools/ci" "$work_dir/Tests/Nested"
cp "$script_dir/../ci/check-test-timing.sh" "$work_dir/Tools/ci/"
guard="$work_dir/Tools/ci/check-test-timing.sh"
fixture="$work_dir/Tests/Nested/Example.swift"
baseline="$work_dir/Tools/ci/test-timing-baseline.txt"
checks=0
expect_pass() {
    if ! "$guard" "$@" > "$work_dir/output" 2>&1; then
        cat "$work_dir/output" >&2
        echo "Expected guard to pass: $*" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
expect_fail() {
    if "$guard" "$@" > "$work_dir/output" 2>&1; then
        echo "Expected guard to fail: $*" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
require_output() {
    grep -F "$1" "$work_dir/output" > /dev/null || {
        cat "$work_dir/output" >&2
        echo "Missing diagnostic: $1" >&2
        exit 1
    }
}

cat > "$fixture" <<'SWIFT'
let fixedDate = Date(timeIntervalSince1970: 0)
let instant: ContinuousClock.Instant
try await clock.sleep(for: .seconds(1))
func sleep(for duration: Duration) {}
@Test(.enabled(if: environmentAllowsTest)) func example() {}
// Task.sleep(for: .seconds(1))
/* Nested /* Task.sleep(for: .seconds(1)) */ Date() */
let description = "Task.sleep and Date() are examples, not calls"
let raw = #""Date()" and Task.sleep(for: .seconds(1))"#
let multiline = """
Date() and Task.sleep(for: .seconds(1))
"""
SWIFT
expect_pass
expect_pass --update-baseline

echo 'try await Task.sleep(for: .seconds(1))' >> "$fixture"
expect_fail
require_output 'Tests/Nested/Example.swift:13: Task.sleep count 1 exceeds baseline 0.'
require_output 'Use the injected clock or add // real-time: <reason>'
cp "$baseline" "$work_dir/before"
expect_fail --update-baseline
require_output 'Refusing increases without --allow-increase'
cmp "$baseline" "$work_dir/before"

cat > "$fixture" <<'SWIFT'
try await Task.sleep(for: .seconds(1)) // real-time: measures a system timer
SWIFT
expect_pass
echo 'try await Task.sleep(for: .seconds(1)) // real-time:   ' > "$fixture"
expect_fail
echo 'try await Task.sleep(for: .seconds(1)); let text = "// real-time: not a comment"' > "$fixture"
expect_fail

echo 'try await Task.sleep(for: .seconds(1))' > "$fixture"
expect_pass --update-baseline --allow-increase
expect_pass
# Unrelated edits must not consume an allowance or change its location.
printf '\n\ntry await Task.sleep(for: .seconds(1))\n' > "$fixture"
expect_pass
echo 'try await Task.sleep(for: .seconds(1)); try await Task.sleep(for: .seconds(1))' > "$fixture"
expect_fail
require_output 'count 2 exceeds baseline 1'
: > "$fixture"
expect_pass
require_output 'hint: Task.sleep count fell from 1 to 0'
expect_pass --update-baseline
if grep -F 'Task.sleep' "$baseline"; then
    echo 'Removed calls must disappear from the baseline.' >&2
    exit 1
fi

# Every supported spelling is rejected without an allowance.
while IFS= read -r call; do
    printf '%s\n' "$call" > "$fixture"
    expect_fail
done <<'SWIFT'
try await Task.sleep(for: .seconds(1))
try await Task<Never, Never>.sleep(nanoseconds: 1)
usleep(1)
Thread.sleep(forTimeInterval: 1)
sleep(1)
Darwin.sleep(1)
Glibc.sleep(1)
let date = Date()
let date = Date.now
let now = CFAbsoluteTimeGetCurrent()
let now = ProcessInfo.processInfo.systemUptime
let now = DispatchTime.now()
let now = ContinuousClock.now
let clock = ContinuousClock()
let clock = ContinuousClock.init()
let now = SuspendingClock.now
let clock = SuspendingClock()
let clock = SuspendingClock.init()
SWIFT
cat > "$fixture" <<'SWIFT'
try await Task
    .sleep(
        for: .seconds(1))
SWIFT
expect_fail
require_output 'Tests/Nested/Example.swift:1:'

echo '@Test(.disabled("temporarily flaky")) func example() {}' > "$fixture"
expect_fail
require_output 'Use .disabled("quarantine: #<number> <reason>").'
echo '@Test(.disabled("quarantine: #42 ")) func example() {}' > "$fixture"
expect_fail
echo '@Test(.disabled("quarantine: #42 tracks a system timer race")) func example() {}' > "$fixture"
expect_pass
cat > "$fixture" <<'SWIFT'
@Test(.disabled(
    "quarantine: #42 tracks a system timer race"
)) func example() {}
SWIFT
expect_pass
# Timing annotations cannot bypass quarantine rules.
echo '@Test(.disabled()) // real-time: system integration' > "$fixture"
expect_fail
expect_pass --update-baseline --allow-increase
expect_pass
echo '@Test(.enabled(if: environmentAllowsTest)) func example() {}' > "$fixture"
expect_pass --update-baseline
require_output 'hint: quarantine count fell from 1 to 0'
expect_fail --allow-increase
expect_fail --unknown
printf 'malformed\n' > "$baseline"
expect_fail
require_output 'Invalid timing baseline row'

echo "check-test-timing tests passed ($checks cases)"
