#!/bin/bash
#
# Sourceable Developer ID and notarization helpers for Tools/release-beta.sh.
#
# They live in their own file so their failure paths can be tested with a stub
# xcrun, without signing, building, or contacting Apple. See
# Tools/tests/release-notarize-test.sh.

# Hardened runtime and a secure timestamp are required for notarization. An
# ad-hoc signature cannot carry either: a hardened, ad-hoc signed process
# refuses to map an ad-hoc signed framework ("different Team IDs"), so the app
# would not load Sparkle. Ad-hoc dry runs therefore keep a plain signature.
# Prints one argument per line, for use with a read loop or mapfile.
release_codesign_options() {
    local identity="$1"
    if [[ "$identity" == "-" ]]; then
        printf '%s\n' --timestamp=none
    else
        printf '%s\n' --options runtime --timestamp
    fi
}

# A Developer ID Team ID is exactly ten uppercase letters or digits.
is_team_id() {
    [[ "${1:-}" =~ ^[A-Z0-9]{10}$ ]]
}

# The designated requirement every distributed BetterTile must satisfy: the
# BetterTile bundle identifier, signed by a Developer ID Application
# certificate that Apple issued to the pinned team. Pinning the Team ID, not
# the Keychain name, means another certificate with the same name never passes.
developer_id_requirement() {
    local identifier="$1" team_id="$2"
    printf '%s' "anchor apple generic and identifier \"$identifier\"" \
        " and certificate 1[field.1.2.840.113635.100.6.2.6]" \
        " and certificate leaf[field.1.2.840.113635.100.6.1.13]" \
        " and certificate leaf[subject.OU] = \"$team_id\""
}

# The same Developer ID and team check for nested code with its own identifier,
# such as Sparkle's helpers.
developer_id_team_requirement() {
    local team_id="$1"
    printf '%s' "anchor apple generic" \
        " and certificate 1[field.1.2.840.113635.100.6.2.6]" \
        " and certificate leaf[field.1.2.840.113635.100.6.1.13]" \
        " and certificate leaf[subject.OU] = \"$team_id\""
}

# Fail early, before the long build, when the stored notary credentials are
# missing or rejected. Apple's own message is shown.
check_notary_profile() {
    local profile="$1" err_path="$2"
    xcrun notarytool history --keychain-profile "$profile" --output-format json \
        >/dev/null 2>"$err_path" || {
        echo "notarytool could not use the Keychain profile \"$profile\": $(cat "$err_path")" >&2
        echo "Store it with: xcrun notarytool store-credentials \"$profile\"" >&2
        return 1
    }
}

# Print one top-level string field from notarytool's flat JSON result, or
# nothing. sed keeps this portable to the Linux CI job that tests it.
notary_json_field() {
    local field="$1" item="$2"
    [[ -f "$item" ]] || return 0
    tr -d '\n' < "$item" | sed -n -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p"
}

# notarize_submission PATH PROFILE LOG_PREFIX
#
# Submit PATH (a .zip, .dmg, or .pkg) and wait for Apple's verdict, for at most
# BETTERTILE_NOTARY_TIMEOUT (default 45m). notarytool's JSON result is kept in
# LOG_PREFIX.json and Apple's detailed log in LOG_PREFIX-log.json.
#
# notarytool can exit 0 after an Invalid verdict, so the status is read from
# the JSON rather than trusted from the exit code. When the wait times out it
# exits 124 and writes its JSON to stderr instead of stdout, so both streams
# are read.
notarize_submission() {
    local item="$1" profile="$2" log_prefix="$3"
    local result="$log_prefix.json" errors="$log_prefix.err" submit_status=0 status id
    local timeout="${BETTERTILE_NOTARY_TIMEOUT:-45m}"
    echo "Submitting $(basename "$item") for notarization (waiting up to $timeout)..."
    xcrun notarytool submit "$item" --keychain-profile "$profile" --wait \
        --timeout "$timeout" --output-format json >"$result" 2>"$errors" || submit_status=$?
    if [[ -z "$(notary_json_field id "$result")" && -n "$(notary_json_field id "$errors")" ]]; then
        cp "$errors" "$result"
    fi
    status="$(notary_json_field status "$result")"
    id="$(notary_json_field id "$result")"
    if [[ -n "$status" && -n "$id" ]]; then
        # The log also lists warnings on an accepted submission. Keep it.
        xcrun notarytool log "$id" --keychain-profile "$profile" "$log_prefix-log.json" \
            >/dev/null 2>&1 || true
    fi
    if [[ "$status" == "Accepted" ]]; then
        echo "Notarization accepted: $(basename "$item") (submission $id)."
        return 0
    fi
    if [[ -z "$status" && -n "$id" ]]; then
        echo "Apple had not finished notarizing $(basename "$item") within $timeout." >&2
        echo "Submission $id is still processing. Check it with:" >&2
        echo "  xcrun notarytool info $id --keychain-profile \"$profile\"" >&2
        echo "Then rerun the release; set BETTERTILE_NOTARY_TIMEOUT to wait longer." >&2
        return 1
    fi
    echo "Apple did not accept $(basename "$item") for notarization." >&2
    echo "Status: ${status:-unknown}; submission: ${id:-none}; notarytool exit: $submit_status." >&2
    if [[ -s "$log_prefix-log.json" ]]; then
        echo "Apple's log: $log_prefix-log.json" >&2
    elif [[ -s "$result" ]]; then
        cat "$result" >&2
    elif [[ -s "$errors" ]]; then
        cat "$errors" >&2
    fi
    return 1
}

# Attach the notarization ticket so Gatekeeper can verify the item offline,
# then confirm the stapled ticket is valid.
staple_ticket() {
    local item="$1"
    xcrun stapler staple "$item" >/dev/null || {
        echo "Could not staple the notarization ticket to $(basename "$item")." >&2
        return 1
    }
    xcrun stapler validate "$item" >/dev/null || {
        echo "The stapled ticket on $(basename "$item") does not validate." >&2
        return 1
    }
}

# gatekeeper_accepts TYPE PATH
#
# Ask Gatekeeper's own assessment for the verdict a downloaded copy gets.
# TYPE is "exec" for an application or "open" for the disk image.
gatekeeper_accepts() {
    local type="$1" item="$2" output
    local args=(--assess -vv --type "$type")
    if [[ "$type" == "open" ]]; then
        args+=(--context context:primary-signature)
    fi
    output="$(spctl "${args[@]}" "$item" 2>&1)" || {
        echo "Gatekeeper rejects $(basename "$item"): $output" >&2
        return 1
    }
    [[ "$output" == *"source=Notarized Developer ID"* ]] || {
        echo "Gatekeeper accepts $(basename "$item") but not as notarized Developer ID: $output" >&2
        return 1
    }
}
