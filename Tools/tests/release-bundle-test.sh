#!/bin/bash
# Exercise only the release tool's bundled-license check against fixture
# directories. Never execute the release entrypoint, build, sign, or publish.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
release_script="$script_dir/../release-beta.sh"
check="$(awk '/^# The license and third-party notices ship/ { found = 1 } found { print } found && /^done$/ { exit }' "$release_script")"
[[ "$check" == *'cmp -s'* && "$check" == *'done' ]] || {
    echo "The bundled-license check was not found." >&2
    exit 1
}

fixture="$(mktemp -d /private/tmp/bettertile-bundle-test.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
repo_root="$fixture/repo"
app_path="$fixture/BetterTile.app"
mkdir -p "$repo_root" "$app_path/Contents/Resources"
printf 'license\n' > "$repo_root/LICENSE"
printf 'notices\n' > "$repo_root/THIRD_PARTY_NOTICES.md"

failures=0
# expect PASS|FAIL DESCRIPTION [EXPECTED_MESSAGE]
expect() {
    local output status=0
    output="$(repo_root="$repo_root" app_path="$app_path"; eval "$check" 2>&1)" || status=$?
    if [[ "$1" == PASS && "$status" -eq 0 ]] || [[ "$1" == FAIL && "$status" -ne 0 && "$output" == *"$3"* ]]; then
        echo "ok: $2"
    else
        echo "not ok: $2 (status $status: $output)" >&2
        failures=$((failures + 1))
    fi
}

cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/"
expect PASS "accepts bundled copies that match the repository"

printf 'stale notices\n' > "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
expect FAIL "rejects stale bundled notices" "does not contain the current THIRD_PARTY_NOTICES.md"

rm "$app_path/Contents/Resources/LICENSE"
expect FAIL "rejects a missing bundled license" "does not contain the current LICENSE"

if [[ "$failures" -eq 0 ]]; then
    echo "release bundle tests passed"
else
    echo "release bundle tests failed: $failures" >&2
    exit 1
fi
