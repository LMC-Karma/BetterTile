#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
release_script="$script_dir/../release-beta.sh"
scratch="$(mktemp -d /private/tmp/release-signing-policy-test.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT

notes="$scratch/notes.md"
printf '# Signing policy test\n' > "$notes"

spy_log="$scratch/commands.log"
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$0" >> "$BETTERTILE_POLICY_SPY_LOG"\nexit 99\n' > "$scratch/spy"
chmod +x "$scratch/spy"
for command in git swift xcodebuild hdiutil shasum ditto curl gh codesign; do
    ln -s "$scratch/spy" "$fake_bin/$command"
done

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

expect_rejection() {
    local description="$1"
    local identity="$2"

    : > "$spy_log"
    local output
    if output="$(
        (
            export PATH="$fake_bin:/usr/bin:/bin"
            export BETTERTILE_POLICY_SPY_LOG="$spy_log"
            if [[ "$identity" == unset ]]; then
                unset BETTERTILE_SIGNING_IDENTITY
            else
                export BETTERTILE_SIGNING_IDENTITY="$identity"
            fi
            "$release_script" 999.999.999 "$notes"
        ) 2>&1
    )"; then
        fail "$description"
    elif [[ "$output" == *"Public beta publication requires BETTERTILE_SIGNING_IDENTITY to select the stable BetterTile Beta identity."* ]]; then
        pass "$description"
    else
        printf '%s\n' "$output" >&2
        fail "$description"
    fi
    if [[ -s "$spy_log" ]]; then
        printf 'Unexpected command: %s\n' "$(head -1 "$spy_log")" >&2
        fail "$description stops before release tools run"
    else
        pass "$description stops before release tools run"
    fi
}

echo "release publication requires the stable signing identity"
expect_rejection "rejects a missing signing identity" unset
expect_rejection "rejects the ad-hoc signing identity" -

echo "release tools explain a missing Sparkle signing key"
# Run the exact key lookup from the release tool with a generate_keys that
# fails as Sparkle's does when the login Keychain has no key.
key_lookup="$(awk '/^public_key="\$\("\$generate_keys" -p\)" \|\| \{$/ { found = 1 } found { print } found && /^}$/ { exit }' "$release_script")"
if [[ "$key_lookup" != *'No Sparkle signing key was found'* ]]; then
    fail "the Sparkle key lookup was not found"
else
    missing_key_tool="$(mktemp /private/tmp/bettertile-generate-keys.XXXXXX)"
    printf '#!/bin/bash\necho "ERROR: No existing signing key found!"\nexit 1\n' > "$missing_key_tool"
    chmod +x "$missing_key_tool"
    key_status=0
    key_output="$(generate_keys="$missing_key_tool"; eval "$key_lookup" 2>&1)" || key_status=$?
    rm -f "$missing_key_tool"
    if [[ "$key_status" -eq 1 && "$key_output" == *"No Sparkle signing key was found in this Mac's login Keychain."* ]]; then
        pass "a missing Sparkle key stops with an explanation"
    else
        fail "a missing Sparkle key did not explain itself (status $key_status: $key_output)"
    fi
fi

if [[ "$failures" -eq 0 ]]; then
    echo "release signing policy tests passed"
else
    echo "release signing policy tests failed: $failures" >&2
    exit 1
fi
