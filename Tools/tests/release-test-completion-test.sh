#!/bin/bash
# Execute the release validation block with stubs. Never build, sign or publish.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
tools="$(cd "$script_dir/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/release-completion-test.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
[[ "$scratch" == "${TMPDIR:-/tmp}"/* ]] || {
    echo "Release completion fixtures must use TMPDIR (or /tmp when unset)." >&2
    exit 1
}
mkdir "$scratch/bin"
cat > "$scratch/bin/swift" <<'STUB'
#!/bin/bash
if [[ "$1" == test ]]; then
    cat "$RELEASE_TEST_FIXTURE"
    exit "${RELEASE_TEST_EXIT:-0}"
fi
touch "$RELEASE_TEST_BUILT"
STUB
cat > "$scratch/bin/xcodebuild" <<'STUB'
#!/bin/bash
touch "$RELEASE_TEST_BUILT"
STUB
chmod +x "$scratch/bin/swift" "$scratch/bin/xcodebuild"
export PATH="$scratch/bin:$PATH" RELEASE_TEST_BUILT="$scratch/built"
export RELEASE_TEST_FIXTURE="$scratch/fixture"
# Select the actual entrypoint block so a raw swift test regression is caught.
validation="$(sed -n '/^echo "Running tests and builds\.\.\."$/,/^app_path=/p' "${RELEASE_COMPLETION_SCRIPT:-$tools/release-beta.sh}" | sed '$d')"
[[ -n "$validation" ]]
run_validation() {
    script_dir="$tools" work_dir="$scratch" debug_derived_data="$scratch/debug" derived_data="$scratch/release" \
        bash -euo pipefail -c "$validation"
}
printf '%s\n' '◇ Test run started.' > "$RELEASE_TEST_FIXTURE"
if run_validation > "$scratch/truncated-output" 2>&1; then
    echo 'Release accepted an incomplete zero-exit test run.' >&2; exit 1
fi
[[ ! -e "$RELEASE_TEST_BUILT" ]] || { echo 'Release built after incomplete tests.' >&2; exit 1; }
for _ in 1 2 3; do
    printf '%s\n' '◇ Test run started.' '✔ Test run with 10 tests passed after 0.100 seconds.'
done > "$RELEASE_TEST_FIXTURE"
run_validation > "$scratch/complete-output" 2>&1
[[ -e "$RELEASE_TEST_BUILT" ]]
[[ -f "$scratch/tests.log" ]]
cmp "$RELEASE_TEST_FIXTURE" "$scratch/tests.log"
rm "$RELEASE_TEST_BUILT"
if RELEASE_TEST_EXIT=7 run_validation > "$scratch/failed-output" 2>&1; then
    echo 'Release accepted a failing test command.' >&2; exit 1
fi
[[ ! -e "$RELEASE_TEST_BUILT" ]]

echo 'release test completion checks passed'
