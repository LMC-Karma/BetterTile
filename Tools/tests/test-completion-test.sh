#!/bin/bash
# Exercise completion checks and runner exit propagation without launching AppKit.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
tools="$script_dir/.."
work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT
cat > "$work/complete" <<'LOG'
◇ Test run started.
✔ Test run with 10 tests in 1 suite passed after 0.100 seconds.
◇ Test run started.
━ Test run with 20 tests in 2 suites passed after 1.100 seconds with 1 known issue.
◇ Test run started.
✔ Test run with 30 tests in 3 suites passed after 2.100 seconds.
LOG
"$tools/check-test-log.sh" "$work/complete"
printf '%s\n' '◇ Test run started.' '✔ Test run with 1 test passed after 0.010 seconds.' > "$work/single"
"$tools/check-test-log.sh" "$work/single" 1
reject() {
    if "$tools/check-test-log.sh" "$1"; then
        echo "Accepted invalid log: $1" >&2
        exit 1
    fi
}
sed '$d' "$work/complete" > "$work/truncated"
reject "$work/truncated"
# The last product finishing cannot hide an earlier product exiting silently.
sed '2d' "$work/complete" > "$work/missing-middle"
reject "$work/missing-middle"
sed 's/20 tests/0 tests/' "$work/complete" > "$work/empty"
reject "$work/empty"
sed 's/passed after/failed after/' "$work/complete" > "$work/failed"
reject "$work/failed"
cat "$work/complete" "$work/complete" > "$work/duplicate"
reject "$work/duplicate"
mkdir "$work/bin"
cat > "$work/bin/swift" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_COMPLETION_ARGUMENTS"
cat "$TEST_COMPLETION_FIXTURE"
exit "${TEST_COMPLETION_EXIT:-0}"
STUB
chmod +x "$work/bin/swift"
export PATH="$work/bin:$PATH" TEST_COMPLETION_FIXTURE="$work/complete" TEST_COMPLETION_ARGUMENTS="$work/arguments"
"$tools/test.sh" "$work/output" > /dev/null
cmp "$work/complete" "$work/output"
printf '%s\n' test --build-system swiftbuild > "$work/expected-arguments"
cmp "$work/expected-arguments" "$work/arguments"
"$tools/test.sh" "$work/output" --release --filter Example > /dev/null
printf '%s\n' test --build-system swiftbuild -c release -Xswiftc -enable-testing -Xswiftc -DBETTERTILE_TEST_HOOKS --filter Example > "$work/expected-arguments"
cmp "$work/expected-arguments" "$work/arguments"
cmp "$work/complete" "$work/output"
TEST_COMPLETION_FIXTURE="$work/single" "$tools/test.sh" "$work/output" --expected-runs 1 --release --filter Example > /dev/null
cmp "$work/expected-arguments" "$work/arguments"
export TEST_COMPLETION_FIXTURE="$work/truncated"
if "$tools/test.sh" "$work/output" --release > /dev/null; then
    echo 'Runner accepted a truncated successful exit.' >&2; exit 1
fi
export TEST_COMPLETION_FIXTURE="$work/complete" TEST_COMPLETION_EXIT=7
if "$tools/test.sh" "$work/output" --release > /dev/null; then
    echo 'Runner ignored a failing helper exit.' >&2; exit 1
else
    [[ $? == 7 ]] || { echo 'Runner changed the failing exit status.' >&2; exit 1; }
fi
echo 'test completion checks passed'
