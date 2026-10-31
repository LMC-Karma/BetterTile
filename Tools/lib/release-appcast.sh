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

# Sparkle 2.9.5 infers this from the executable. Fail closed if generation or
# reuse of an existing item ever loses the requirement for this exact build.
validate_arm64_appcast() {
    local appcast="$1" build="$2" count
    [[ "$build" =~ ^[1-9][0-9]*$ ]] || return 1
    local ns="(namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle' or namespace-uri()='https://sparkle-project.org/xml-namespaces/sparkle')"
    local item="/rss/channel/item[*[local-name()='version' and $ns and text()='$build'] or enclosure/@*[local-name()='version' and $ns and .='$build']]"
    count="$(xmllint --nonet --xpath "count($item)" "$appcast")" || return 1
    [[ "$count" == 1 ]] || {
        echo "Appcast must contain exactly one item for build $build." >&2
        return 1
    }
    local requirement="$item/*[(local-name()='hardwareRequirements' and namespace-uri()='http://www.andymatuschak.org/xml-namespaces/sparkle') or name()='sparkle:hardwareRequirements']"
    count="$(xmllint --nonet --xpath "count($requirement)" "$appcast")" || return 1
    local hardware
    hardware="$(xmllint --nonet --xpath "normalize-space($requirement)" "$appcast")" || return 1
    [[ "$count" == 1 && "$hardware" == arm64 ]] || {
        echo "Appcast build $build must require arm64 hardware." >&2
        return 1
    }
}

# Validate published ordering in both modes. Dry runs sign with a disposable
# key, so their generated feed must not merge production entries.
prepare_appcast_input() {
    local feed_url="$1" version="$2" build="$3" dry_run="$4"
    local existing_path="$5" input_path="$6"
    fetch_existing_appcast "$feed_url" "$existing_path" || return 1
    if [[ -f "$existing_path" ]]; then
        validate_appcast_release "$existing_path" "$version" "$build" || return 1
        if [[ "$dry_run" == false ]]; then
            cp "$existing_path" "$input_path" || return 1
        fi
    fi
}
