#!/bin/bash
# Exercise only the release tool's Layout Wheel shader check against fixture
# directories. Never execute the release entrypoint, build, sign, or publish.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
release_script="$script_dir/../release-beta.sh"
check="$(awk '/^# The Layout Wheel.s liquid renderer needs its compiled shader/ { found = 1 } found { print } found && /^}$/ { exit }' "$release_script")"
[[ "$check" == *'default.metallib'* && "$check" == *'exit 1'* ]] || {
    echo "The shader check was not found." >&2
    exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/bettertile-shader-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
app_path="$fixture/BetterTile.app"
resources="$app_path/Contents/Resources/BetterTile_BetterTileMacOS.bundle/Contents/Resources"
mkdir -p "$resources"

failures=0
# expect PASS|FAIL DESCRIPTION
expect() {
    local output status=0
    output="$(app_path="$app_path"; eval "$check" 2>&1)" || status=$?
    if [[ "$1" == PASS && "$status" -eq 0 ]] || [[ "$1" == FAIL && "$status" -ne 0 && "$output" == *"default.metallib"* ]]; then
        echo "ok: $2"
    else
        echo "not ok: $2 (status $status: $output)" >&2
        failures=$((failures + 1))
    fi
}

expect FAIL "rejects an application without the shader"
: > "$resources/default.metallib"
expect FAIL "rejects an empty shader"
printf 'MTLB' > "$resources/default.metallib"
expect PASS "accepts an application with the shader"

[[ "$failures" -eq 0 ]]
