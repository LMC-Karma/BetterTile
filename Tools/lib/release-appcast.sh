#!/bin/bash

fetch_existing_appcast() {
    local feed_url="$1"
    local output_path="$2"
    local appcast_status

    if ! appcast_status="$(curl --silent --show-error --location \
        --output "$output_path" --write-out '%{http_code}' "$feed_url")"; then
        echo "Unable to read the existing appcast at $feed_url." >&2
        return 1
    fi
    case "$appcast_status" in
        200) ;;
        404) rm -f "$output_path" ;;
        *)
            echo "Unexpected HTTP $appcast_status while reading $feed_url." >&2
            return 1
            ;;
    esac
}
