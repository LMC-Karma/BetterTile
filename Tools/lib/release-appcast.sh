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

appcast_builds() {
    sed -n \
        -e 's/.*sparkle:version="\([0-9][0-9]*\)".*/\1/p' \
        -e 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' \
        "$1"
}

appcast_versions() {
    sed -n \
        -e 's/.*sparkle:shortVersionString="\([0-9][0-9.]*\)".*/\1/p' \
        -e 's#.*<sparkle:shortVersionString>\([0-9][0-9.]*\)</sparkle:shortVersionString>.*#\1#p' \
        "$1"
}

appcast_contains_build() {
    local build
    while IFS= read -r build; do
        [[ "$build" == "$2" ]] && return 0
    done < <(appcast_builds "$1")
    return 1
}

appcast_contains_version() {
    local version
    while IFS= read -r version; do
        [[ "$version" == "$2" ]] && return 0
    done < <(appcast_versions "$1")
    return 1
}

# Sparkle orders updates by CFBundleVersion. The marketing version is a
# unique display label and need not sort numerically after older labels.
validate_appcast_release() {
    local appcast="$1" version="$2" project_build="$3"
    local newest_feed_build
    newest_feed_build="$(appcast_builds "$appcast" | sort -n | tail -1)"
    if [[ -n "$newest_feed_build" && "$project_build" -le "$newest_feed_build" ]]; then
        echo "Project build $project_build must be newer than appcast build $newest_feed_build." >&2
        return 1
    fi
    if appcast_contains_version "$appcast" "$version"; then
        echo "Version $version already exists in the appcast." >&2
        return 1
    fi
    return 0
}
