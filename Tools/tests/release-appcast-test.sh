#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/release-appcast.sh
source "$script_dir/../lib/release-appcast.sh"

scratch="$(mktemp -d /private/tmp/release-appcast-test.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

curl_status=200
curl_exit=0
curl_body='<rss>existing appcast</rss>'
curl_output="$scratch/appcast.xml"
curl() {
    printf '%s\n' "$curl_body" > "$curl_output"
    printf '%s' "$curl_status"
    return "$curl_exit"
}

echo "fetch_existing_appcast preserves a successful feed"
if fetch_existing_appcast "https://example.invalid/appcast.xml" "$curl_output" \
    && grep -q 'existing appcast' "$curl_output"; then
    pass "keeps the downloaded appcast after HTTP 200"
else
    fail "keeps the downloaded appcast after HTTP 200"
fi

echo "fetch_existing_appcast accepts a missing first-release feed"
curl_status=404
curl_body='not found'
if fetch_existing_appcast "https://example.invalid/appcast.xml" "$curl_output" \
    && [[ ! -e "$curl_output" ]]; then
    pass "removes the HTTP 404 response body"
else
    fail "removes the HTTP 404 response body"
fi

echo "fetch_existing_appcast rejects transport failures"
curl_status=000
curl_exit=7
curl_body='partial response'
if fetch_existing_appcast "https://example.invalid/appcast.xml" "$curl_output"; then
    fail "returns failure when curl cannot complete"
else
    pass "returns failure when curl cannot complete"
fi

echo "fetch_existing_appcast rejects unexpected HTTP statuses"
curl_status=500
curl_exit=0
curl_body='server error'
if error="$(fetch_existing_appcast "https://example.invalid/appcast.xml" "$curl_output" 2>&1)"; then
    fail "reports and rejects HTTP 500"
elif [[ "$error" == *"Unexpected HTTP 500"* ]]; then
    pass "reports and rejects HTTP 500"
else
    fail "reports and rejects HTTP 500"
fi

current_format="$scratch/current-format.xml"
printf '%s\n' '<rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel><item><sparkle:version>6</sparkle:version><sparkle:shortVersionString>0.4.1</sparkle:shortVersionString></item></channel></rss>' > "$current_format"

echo "appcast parsing reads Sparkle child elements"
if [[ "$(appcast_builds "$current_format")" == "6" ]] \
    && [[ "$(appcast_versions "$current_format")" == "0.4.1" ]] \
    && appcast_contains_build "$current_format" 6 \
    && appcast_contains_version "$current_format" 0.4.1; then
    pass "reads the format emitted by Sparkle 2.9.5"
else
    fail "reads the format emitted by Sparkle 2.9.5"
fi

legacy_format="$scratch/legacy-format.xml"
printf '%s\n' '<item sparkle:version="5" sparkle:shortVersionString="0.4.0" />' > "$legacy_format"

echo "appcast parsing retains attribute compatibility"
if [[ "$(appcast_builds "$legacy_format")" == "5" ]] \
    && [[ "$(appcast_versions "$legacy_format")" == "0.4.0" ]] \
    && appcast_contains_build "$legacy_format" 5 \
    && appcast_contains_version "$legacy_format" 0.4.0; then
    pass "reads legacy version attributes"
else
    fail "reads legacy version attributes"
fi

if [[ "$failures" -eq 0 ]]; then
    echo "release appcast tests passed"
else
    echo "release appcast tests failed: $failures" >&2
    exit 1
fi
