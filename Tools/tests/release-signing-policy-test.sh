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

echo "release tools explain a failed Sparkle key lookup"
# Run the exact key lookup from the release tool with a generate_keys that
# fails, first as Sparkle's does when the login Keychain has no key, then
# for another reason.
key_lookup="$(awk '/^public_key="\$\("\$generate_keys" -p 2>/ { found = 1 } found { print } found && /^}$/ { exit }' "$release_script")"
# run_key_lookup MESSAGE STREAM : stub generate_keys fails, printing MESSAGE
# to stdout or stderr; sets key_status and key_output.
run_key_lookup() {
    local stub key_work
    stub="$(mktemp /private/tmp/bettertile-generate-keys.XXXXXX)"
    key_work="$(mktemp -d /private/tmp/bettertile-key-test.XXXXXX)"
    if [[ "$2" == stderr ]]; then
        printf '#!/bin/bash\necho "%s" >&2\nexit 1\n' "$1" > "$stub"
    else
        printf '#!/bin/bash\necho "%s"\nexit 1\n' "$1" > "$stub"
    fi
    chmod +x "$stub"
    key_status=0
    key_output="$(generate_keys="$stub"; work_dir="$key_work"; eval "$key_lookup" 2>&1)" || key_status=$?
    rm -rf "$stub" "$key_work"
}
if [[ "$key_lookup" != *'could not read the signing key'* ]]; then
    fail "the Sparkle key lookup was not found"
else
    run_key_lookup "ERROR: No existing signing key found!" stdout
    if [[ "$key_status" -eq 1 && "$key_output" == *"No existing signing key found"* \
          && "$key_output" == *"has no Sparkle signing key"* ]]; then
        pass "a missing Sparkle key stops with its cause and where to release"
    else
        fail "a missing Sparkle key did not explain itself (status $key_status: $key_output)"
    fi
    run_key_lookup "User interaction is not allowed." stderr
    if [[ "$key_status" -eq 1 && "$key_output" == *"User interaction is not allowed."* \
          && "$key_output" != *"has no Sparkle signing key"* ]]; then
        pass "another key failure shows Sparkle's own message, not a missing key"
    else
        fail "another key failure was misreported (status $key_status: $key_output)"
    fi
fi

if [[ "$failures" -eq 0 ]]; then
    echo "release signing policy tests passed"
else
    echo "release signing policy tests failed: $failures" >&2
    exit 1
fi
