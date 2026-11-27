#!/bin/bash
# Exercise the release tool's Developer ID and notarization helpers with stub
# xcrun and spctl commands. Never sign, build, contact Apple, or publish.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
release_script="$script_dir/../release-beta.sh"
# shellcheck source=../lib/release-notarize.sh
source "$script_dir/../lib/release-notarize.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/release-notarize-test.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

echo "signing options"
if [[ "$(release_codesign_options - | tr '\n' ' ')" == "--timestamp=none " ]]; then
    pass "ad-hoc signing has no hardened runtime or timestamp"
else
    fail "ad-hoc signing options"
fi
if [[ "$(release_codesign_options "Developer ID Application: Example (ABCDE12345)" | tr '\n' ' ')" \
      == "--options runtime --timestamp " ]]; then
    pass "Developer ID signing uses the hardened runtime and a secure timestamp"
else
    fail "Developer ID signing options"
fi

echo "team ID and requirements"
is_team_id ABCDE12345 && pass "accepts a ten-character Team ID" || fail "accepts a ten-character Team ID"
for bad in "" abcde12345 ABCDE1234 ABCDE123456 'ABCDE 2345'; do
    if is_team_id "$bad"; then fail "rejects Team ID '$bad'"; else pass "rejects Team ID '$bad'"; fi
done
requirement="$(developer_id_requirement com.lmckarma.BetterTile ABCDE12345)"
if [[ "$requirement" == 'anchor apple generic and identifier "com.lmckarma.BetterTile"'*'certificate leaf[subject.OU] = "ABCDE12345"' \
      && "$requirement" == *"certificate 1[field.1.2.840.113635.100.6.2.6]"* \
      && "$requirement" == *"certificate leaf[field.1.2.840.113635.100.6.1.13]"* ]]; then
    pass "the app requirement pins Apple, Developer ID, the identifier, and the team"
else
    fail "the app requirement: $requirement"
fi
team_requirement="$(developer_id_team_requirement ABCDE12345)"
[[ "$team_requirement" != *identifier* && "$team_requirement" == *'subject.OU] = "ABCDE12345"' ]] \
    && pass "the nested requirement pins the team without an identifier" \
    || fail "the nested requirement: $team_requirement"
if command -v csreq >/dev/null; then
    for candidate in "$requirement" "$team_requirement"; do
        if csreq -r="$candidate" -b "$scratch/requirement.bin" 2>"$scratch/csreq.err"; then
            pass "csreq compiles: ${candidate:0:40}..."
        else
            fail "csreq rejects the requirement: $(cat "$scratch/csreq.err")"
        fi
    done
else
    echo "  skip csreq compilation (macOS only)"
fi

# Stub xcrun. XCRUN_SUBMIT_JSON is written as the submit result, XCRUN_SUBMIT_EXIT
# is its exit status, and XCRUN_FAIL names an xcrun subcommand that fails.
xcrun() {
    local tool="$1" action="${2:-}"
    printf '%s %s\n' "$tool" "$action" >> "$scratch/xcrun.log"
    [[ "${XCRUN_FAIL:-}" != "$tool $action" ]] || { echo "stub $tool $action failed" >&2; return 1; }
    case "$tool $action" in
        "notarytool submit")
            # notarytool writes its JSON to stderr when the wait times out.
            if [[ "${XCRUN_SUBMIT_STREAM:-stdout}" == stderr ]]; then
                printf '%s' "${XCRUN_SUBMIT_JSON:-}" >&2
            else
                printf '%s' "${XCRUN_SUBMIT_JSON:-}"
            fi
            return "${XCRUN_SUBMIT_EXIT:-0}" ;;
        "notarytool log")
            # The output path is the last argument.
            printf '{"issues":null}' > "${*: -1}" ;;
    esac
}

# run_submission JSON EXIT : sets sub_status and sub_output.
run_submission() {
    : > "$scratch/xcrun.log"
    rm -f "$scratch"/sub*.json "$scratch"/sub*.err
    sub_status=0
    sub_output="$(XCRUN_SUBMIT_JSON="$1" XCRUN_SUBMIT_EXIT="$2" \
        notarize_submission "$scratch/BetterTile.zip" BetterTile-Notary "$scratch/sub" 2>&1)" || sub_status=$?
}

echo "notarization submission"
run_submission '{"id":"1111-aaaa","status":"Accepted","message":"Processing complete"}' 0
if [[ "$sub_status" -eq 0 && "$sub_output" == *"Notarization accepted"*"1111-aaaa"* \
      && -s "$scratch/sub-log.json" ]]; then
    pass "an accepted submission passes and keeps Apple's log"
else
    fail "an accepted submission (status $sub_status: $sub_output)"
fi
run_submission $'{\n  "id" : "2222-bbbb",\n  "status" : "Invalid"\n}' 0
if [[ "$sub_status" -ne 0 && "$sub_output" == *"did not accept"* && "$sub_output" == *"Status: Invalid"* \
      && "$sub_output" == *"2222-bbbb"* && "$sub_output" == *"sub-log.json"* ]]; then
    pass "an Invalid verdict fails even when notarytool exits 0, and names the log"
else
    fail "an Invalid verdict (status $sub_status: $sub_output)"
fi
run_submission '' 1
if [[ "$sub_status" -ne 0 && "$sub_output" == *"Status: unknown"* && "$sub_output" == *"notarytool exit: 1"* ]] \
      && ! grep -q "notarytool log" "$scratch/xcrun.log"; then
    pass "a failed upload with no result fails without asking for a log"
else
    fail "a failed upload (status $sub_status: $sub_output)"
fi
run_submission '{"id":"3333-cccc","status":"In Progress"}' 0
[[ "$sub_status" -ne 0 && "$sub_output" == *"Status: In Progress"* ]] \
    && pass "an unfinished status fails" \
    || fail "an unfinished status (status $sub_status: $sub_output)"
# The exact reply notarytool 1.1.4 gives when --timeout expires: exit 124,
# JSON on stderr, and no status.
XCRUN_SUBMIT_STREAM=stderr run_submission \
    '{"message":"Timeout of 2700 second(s) was reached before processing completed.","id":"4444-dddd"}' 124
if [[ "$sub_status" -ne 0 && "$sub_output" == *"had not finished"* && "$sub_output" == *"4444-dddd"* \
      && "$sub_output" == *"notarytool info 4444-dddd"* && "$sub_output" == *"BETTERTILE_NOTARY_TIMEOUT"* ]] \
      && grep -q '"id":"4444-dddd"' "$scratch/sub.json" && ! grep -q "notarytool log" "$scratch/xcrun.log"; then
    pass "a timed-out wait names the submission and how to check it"
else
    fail "a timed-out wait (status $sub_status: $sub_output)"
fi

echo "notary profile"
output="$(XCRUN_FAIL="notarytool history" check_notary_profile BetterTile-Notary "$scratch/profile.err" 2>&1)" \
    && fail "a missing profile fails" \
    || { [[ "$output" == *'"BetterTile-Notary"'* && "$output" == *"stub notarytool history failed"* \
              && "$output" == *"store-credentials"* ]] \
            && pass "a missing profile fails with Apple's message and the fix" \
            || fail "a missing profile message: $output"; }
check_notary_profile BetterTile-Notary "$scratch/profile.err" \
    && pass "a working profile passes" || fail "a working profile passes"

echo "stapling"
output="$(XCRUN_FAIL="stapler staple" staple_ticket "$scratch/BetterTile.dmg" 2>&1)" \
    && fail "a failed staple fails" \
    || { [[ "$output" == *"Could not staple"* ]] && pass "a failed staple fails" || fail "staple message: $output"; }
output="$(XCRUN_FAIL="stapler validate" staple_ticket "$scratch/BetterTile.dmg" 2>&1)" \
    && fail "an invalid stapled ticket fails" \
    || { [[ "$output" == *"does not validate"* ]] && pass "an invalid stapled ticket fails" || fail "validate message: $output"; }
staple_ticket "$scratch/BetterTile.dmg" && pass "a valid staple passes" || fail "a valid staple passes"

echo "Gatekeeper assessment"
spctl() {
    printf '%s\n' "$*" > "$scratch/spctl.args"
    printf '%b' "$SPCTL_OUTPUT"
    return "${SPCTL_EXIT:-0}"
}
SPCTL_OUTPUT='BetterTile.app: accepted\nsource=Notarized Developer ID\n' SPCTL_EXIT=0 \
    gatekeeper_accepts exec "$scratch/BetterTile.app" \
    && pass "accepts a notarized Developer ID app" || fail "accepts a notarized Developer ID app"
output="$(SPCTL_OUTPUT='BetterTile.app: accepted\nsource=Developer ID\n' SPCTL_EXIT=0 \
    gatekeeper_accepts exec "$scratch/BetterTile.app" 2>&1)" \
    && fail "rejects a Developer ID app without notarization" \
    || { [[ "$output" == *"not as notarized"* ]] && pass "rejects a Developer ID app without notarization" \
            || fail "unnotarized message: $output"; }
output="$(SPCTL_OUTPUT='BetterTile.app: rejected\n' SPCTL_EXIT=3 \
    gatekeeper_accepts exec "$scratch/BetterTile.app" 2>&1)" \
    && fail "rejects what Gatekeeper rejects" \
    || { [[ "$output" == *"Gatekeeper rejects"* ]] && pass "rejects what Gatekeeper rejects" \
            || fail "rejection message: $output"; }
SPCTL_OUTPUT='BetterTile.dmg: accepted\nsource=Notarized Developer ID\n' \
    gatekeeper_accepts open "$scratch/BetterTile.dmg" >/dev/null
[[ "$(cat "$scratch/spctl.args")" == *"--type open --context context:primary-signature"* ]] \
    && pass "assesses the disk image's own signature" || fail "disk image arguments: $(cat "$scratch/spctl.args")"

echo "release order"
# first_line PATTERN : the first line number in the release tool matching PATTERN.
first_line() { grep -n -F -- "$1" "$release_script" | head -1 | cut -d: -f1; }
sign_app="$(first_line 'codesign --force "${codesign_options[@]}" --sign "$signing_identity" "$app_path"')"
notarize_app="$(first_line 'notarize_submission "$work_dir/notarization/BetterTile.zip"')"
staple_app="$(first_line 'staple_ticket "$app_path"')"
stage_app="$(first_line 'ditto "$app_path" "$stage_dir/BetterTile.app"')"
create_dmg="$(first_line 'hdiutil create')"
notarize_dmg="$(first_line 'notarize_submission "$work_dir/$dmg_name"')"
staple_dmg="$(first_line 'staple_ticket "$work_dir/$dmg_name"')"
mount_dmg="$(first_line 'hdiutil attach')"
checksum="$(first_line 'shasum -a 256 "$dmg_name"')"
appcast="$(first_line '"$generate_appcast" ${appcast_signing_args')"
for value in sign_app notarize_app staple_app stage_app create_dmg notarize_dmg staple_dmg mount_dmg checksum appcast; do
    [[ -n "${!value}" ]] || fail "release step not found: $value"
done
if [[ "$sign_app" -lt "$notarize_app" && "$notarize_app" -lt "$staple_app" && "$staple_app" -lt "$stage_app" ]]; then
    pass "the app is signed, notarized, and stapled before it is packaged"
else
    fail "app order: sign $sign_app, notarize $notarize_app, staple $staple_app, stage $stage_app"
fi
if [[ "$create_dmg" -lt "$notarize_dmg" && "$notarize_dmg" -lt "$staple_dmg" && "$staple_dmg" -lt "$mount_dmg" \
      && "$staple_dmg" -lt "$checksum" && "$staple_dmg" -lt "$appcast" ]]; then
    pass "the disk image is stapled before it is verified, checksummed, and EdDSA signed"
else
    fail "disk image order: create $create_dmg, notarize $notarize_dmg, staple $staple_dmg, mount $mount_dmg, checksum $checksum, appcast $appcast"
fi

if [[ "$failures" -eq 0 ]]; then
    echo "release notarization tests passed"
else
    echo "release notarization tests failed: $failures" >&2
    exit 1
fi
