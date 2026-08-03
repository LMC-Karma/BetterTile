#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: Tools/release-beta.sh [--dry-run] <version> <notes.md>" >&2
    exit 2
}

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
fi
[[ $# -eq 2 ]] || usage

version="$1"
notes_path="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Version must contain three numeric components, for example 0.1.0." >&2
    exit 1
}
[[ -s "$notes_path" ]] || {
    echo "Release notes must be a non-empty Markdown file." >&2
    exit 1
}
[[ "$notes_path" == *.md ]] || {
    echo "Release notes must use the .md extension." >&2
    exit 1
}
[[ $(wc -c < "$notes_path") -le 10240 ]] || {
    echo "Release notes must be concise (10 KiB or less)." >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"
notes_path="$(cd "$(dirname "$notes_path")" && pwd)/$(basename "$notes_path")"

xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
[[ -d "$xcode_developer_dir" ]] || {
    echo "The full Xcode application is required at /Applications/Xcode.app." >&2
    exit 1
}
export DEVELOPER_DIR="$xcode_developer_dir"

repo="LMC-Karma/BetterTile"
tag="v${version}-beta"
dmg_name="BetterTile-${version}-beta.dmg"
checksum_name="${dmg_name}.sha256"
notes_name="${dmg_name%.dmg}.md"
artifact_dir="$repo_root/.build/beta-release/$tag"
feed_url="https://github.com/$repo/releases/latest/download/appcast.xml"
release_url_prefix="https://github.com/$repo/releases/download/$tag/"

# Build the Xcode application and every DMG-packaging artifact outside the
# repository. SwiftPM validation continues to use the checkout's normal .build;
# none of those outputs enters the distributed application or disk image.
#
# A working copy can sit under a file provider or other synchronising storage
# that attaches its own extended attributes to managed files. codesign refuses
# to sign a bundle carrying them:
#
#   resource fork, Finder information, or similar detritus not allowed
#
# Stripping the attributes afterwards races whatever reapplies them, so the
# application and packaging artifacts never acquire them in the first place.
# Only the finished, inspectable release files are copied back into .build.
#
# make_release_workspace and is_release_workspace live in the sourced library so
# the guard on cleanup's `rm -rf` has exactly one definition and can be tested
# without running a release; see Tools/tests/release-workspace-test.sh.
# shellcheck source=lib/release-workspace.sh
source "$script_dir/lib/release-workspace.sh"
# shellcheck source=lib/release-appcast.sh
source "$script_dir/lib/release-appcast.sh"

work_dir="$(make_release_workspace)"
is_release_workspace "$work_dir" || {
    echo "Refusing to continue without a private temporary directory." >&2
    exit 1
}
mount_dir="$work_dir/mount"
derived_data="$work_dir/DerivedData"
debug_derived_data="$work_dir/DerivedDataDebug"
settings_derived_data="$work_dir/DerivedDataSettings"
archive_dir="$work_dir/appcast-input"
stage_dir="$work_dir/dmg-root"
appcast_path="$work_dir/appcast.xml"

trap 'release_cleanup "$work_dir" "$mount_dir"' EXIT

export CLANG_MODULE_CACHE_PATH="$work_dir/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$work_dir/module-cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

for command in git swift xcodebuild hdiutil shasum ditto curl; do
    command -v "$command" >/dev/null || {
        echo "Required command not found: $command" >&2
        exit 1
    }
done

if [[ -e "$artifact_dir" ]]; then
    echo "Artifact directory already exists: $artifact_dir" >&2
    echo "Remove that specific directory before retrying." >&2
    exit 1
fi

if [[ "$dry_run" == false ]]; then
    command -v gh >/dev/null || {
        echo "GitHub CLI (gh) is required to publish." >&2
        exit 1
    }
    [[ "$(git branch --show-current)" == "main" ]] || {
        echo "Publication must run from main." >&2
        exit 1
    }
    [[ -z "$(git status --porcelain)" ]] || {
        echo "Publication requires a clean working tree." >&2
        exit 1
    }
    git fetch origin main --tags
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
        echo "Local main must exactly match origin/main." >&2
        exit 1
    }
    ! git show-ref --verify --quiet "refs/tags/$tag" || {
        echo "Tag already exists locally: $tag" >&2
        exit 1
    }
    [[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || {
        echo "Tag already exists on origin: $tag" >&2
        exit 1
    }
    gh auth status >/dev/null
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
        echo "GitHub release already exists: $tag" >&2
        exit 1
    fi
fi

swift package resolve
generate_keys="$repo_root/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
generate_appcast="$repo_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$generate_keys" && -x "$generate_appcast" ]] || {
    echo "Sparkle release tools were not resolved at the expected path." >&2
    exit 1
}

public_key="$("$generate_keys" -p)"
expected_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/BetterTileApp/Info.plist)"
[[ "$public_key" == "$expected_public_key" ]] || {
    echo "The Keychain signing key does not match Info.plist." >&2
    exit 1
}

# Every xcodebuild invocation here, including -showBuildSettings, is given an
# explicit derived data path inside the workspace. Xcode's shared DerivedData
# would leave release state on the machine after cleanup and could reuse output
# from an unrelated build of this project.
build_settings="$(xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
    -configuration Release -derivedDataPath "$settings_derived_data" -showBuildSettings)"
project_version="$(awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }' <<< "$build_settings")"
project_build="$(awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }' <<< "$build_settings")"
[[ "$project_version" == "$version" ]] || {
    echo "Project marketing version is $project_version, expected $version." >&2
    exit 1
}
[[ "$project_build" =~ ^[1-9][0-9]*$ ]] || {
    echo "Project build must be a positive integer." >&2
    exit 1
}

mkdir -p "$archive_dir"

version_is_greater() {
    local candidate_major candidate_minor candidate_patch
    local existing_major existing_minor existing_patch
    IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$1"
    IFS=. read -r existing_major existing_minor existing_patch <<< "$2"
    (( candidate_major > existing_major )) && return 0
    (( candidate_major < existing_major )) && return 1
    (( candidate_minor > existing_minor )) && return 0
    (( candidate_minor < existing_minor )) && return 1
    (( candidate_patch > existing_patch ))
}

fetch_existing_appcast "$feed_url" "$archive_dir/appcast.xml"
if [[ -f "$archive_dir/appcast.xml" ]]; then
    newest_feed_build="$(sed -n 's/.*sparkle:version="\([0-9][0-9]*\)".*/\1/p' "$archive_dir/appcast.xml" | sort -n | tail -1)"
    if [[ -n "$newest_feed_build" && "$project_build" -le "$newest_feed_build" ]]; then
        echo "Project build $project_build must be newer than appcast build $newest_feed_build." >&2
        exit 1
    fi
    if grep -q "sparkle:shortVersionString=\"$version\"" "$archive_dir/appcast.xml"; then
        echo "Version $version already exists in the appcast." >&2
        exit 1
    fi
    while IFS= read -r feed_version; do
        [[ "$feed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        version_is_greater "$version" "$feed_version" || {
            echo "Version $version must be newer than appcast version $feed_version." >&2
            exit 1
        }
    done < <(sed -n 's/.*sparkle:shortVersionString="\([0-9][0-9.]*\)".*/\1/p' "$archive_dir/appcast.xml")
fi

echo "Running tests and builds..."
swift test
swift build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
    -configuration Debug CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$debug_derived_data" build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
    -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -derivedDataPath "$derived_data" build

app_path="$derived_data/Build/Products/Release/BetterTile.app"
info_path="$app_path/Contents/Info.plist"
[[ -d "$app_path" && -f "$info_path" ]] || {
    echo "Release application bundle was not produced." >&2
    exit 1
}
[[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] || {
    echo "Release bundle does not contain Sparkle.framework." >&2
    exit 1
}

otool -l "$app_path/Contents/MacOS/BetterTile" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" && $2 == "@executable_path/../Frameworks" { found = 1 }
    in_rpath && $1 == "cmd" { in_rpath = 0 }
    END { exit(found ? 0 : 1) }
' || {
    echo "Release executable is missing the Frameworks runpath required to load Sparkle." >&2
    exit 1
}

# The Release build runs with signing disabled, which leaves two defects: the
# bundle has no seal at all, and Xcode's embed step strips Sparkle's Headers and
# Modules without re-signing, so the framework's upstream signature no longer
# validates. An unsealed bundle is not merely untrusted — once quarantined,
# macOS reports it as damaged with no "Open Anyway" path, so the beta would be
# unopenable. Sign inside-out to produce a valid seal.
#
# BETTERTILE_SIGNING_IDENTITY defaults to "-" (ad-hoc). Ad-hoc identities make
# the designated requirement a bare cdhash, so every release is a different app
# to TCC and the Accessibility grant does not survive an update. Setting a
# stable Developer ID identity here is what fixes that; see docs/RELEASING.md.
signing_identity="${BETTERTILE_SIGNING_IDENTITY:--}"
sparkle_versions="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in \
    "$sparkle_versions/XPCServices/Downloader.xpc" \
    "$sparkle_versions/XPCServices/Installer.xpc" \
    "$sparkle_versions/Updater.app" \
    "$sparkle_versions/Autoupdate" \
    "$sparkle_versions"; do
    [[ -e "$nested" ]] || {
        echo "Expected Sparkle component is missing: $nested" >&2
        exit 1
    }
    codesign --force --sign "$signing_identity" "$nested"
done
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
[[ "$(codesign -dvv "$app_path" 2>&1 | sed -n 's/^Identifier=//p')" == "com.lmckarma.BetterTile" ]] || {
    echo "Signed bundle identifier does not match the Accessibility grant identity." >&2
    exit 1
}

read_info() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info_path"
}

[[ "$(read_info CFBundleShortVersionString)" == "$version" ]]
[[ "$(read_info CFBundleVersion)" == "$project_build" ]]
[[ "$(read_info SUPublicEDKey)" == "$expected_public_key" ]]
[[ "$(read_info SUFeedURL)" == "$feed_url" ]]
[[ "$(read_info SUScheduledCheckInterval)" == "86400" ]]
[[ "$(read_info SUEnableAutomaticChecks)" == "YES" ]]
[[ "$(read_info SUAutomaticallyUpdate)" == "false" ]]
[[ "$(read_info SUAllowsAutomaticUpdates)" == "false" ]]
[[ "$(read_info SUEnableSystemProfiling)" == "false" ]]
[[ "$(read_info SUShowReleaseNotes)" == "true" ]]

mkdir -p "$stage_dir"
ditto "$app_path" "$stage_dir/BetterTile.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname "BetterTile $version Beta" -srcfolder "$stage_dir" \
    -ov -format UDZO "$work_dir/$dmg_name"

mkdir -p "$mount_dir"
hdiutil attach "$work_dir/$dmg_name" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
[[ -d "$mount_dir/BetterTile.app" && -L "$mount_dir/Applications" ]]
# The signature must still validate through the disk image, which is what a
# tester actually launches from.
codesign --verify --deep --strict "$mount_dir/BetterTile.app"
hdiutil detach "$mount_dir" >/dev/null
rmdir "$mount_dir"

(
    cd "$work_dir"
    shasum -a 256 "$dmg_name" > "$checksum_name"
)
cp "$work_dir/$dmg_name" "$archive_dir/$dmg_name"
cp "$notes_path" "$archive_dir/$notes_name"
"$generate_appcast" --download-url-prefix "$release_url_prefix" \
    --embed-release-notes --maximum-deltas 0 --maximum-versions 0 \
    --versions "$project_build" "$archive_dir"
cp "$archive_dir/appcast.xml" "$appcast_path"
grep -q "sparkle:edSignature=" "$appcast_path"
grep -q "$release_url_prefix$dmg_name" "$appcast_path"

# Retain only the finished, inspectable artifacts. DerivedData and the disk
# image staging tree stay in the temporary directory and are discarded.
mkdir -p "$artifact_dir"
cp "$work_dir/$dmg_name" "$work_dir/$checksum_name" "$appcast_path" "$artifact_dir/"
cp "$notes_path" "$artifact_dir/$notes_name"

echo "Validated beta artifacts: $artifact_dir"
if [[ "$dry_run" == true ]]; then
    echo "Dry run complete; nothing was published."
    exit 0
fi

gh release create "$tag" "$work_dir/$dmg_name" "$work_dir/$checksum_name" "$appcast_path" \
    --repo "$repo" --target main --latest \
    --title "BetterTile $version Beta" --notes-file "$notes_path"

asset_url="$release_url_prefix$dmg_name"
# --retry alone only covers timeouts and 5xx. A release asset that has not
# finished propagating answers 404, which would abort the run after the release
# is already public, so retry on all errors.
curl --fail --location --head --retry 12 --retry-delay 5 --retry-all-errors "$asset_url" >/dev/null

# The release and its Latest redirect can take a moment to propagate. Poll the
# public feed until it serves the build that was just published.
feed_confirmed=false
for _ in $(seq 1 30); do
    if curl --fail --silent --location --retry 3 --retry-delay 2 --retry-all-errors \
        --header 'Cache-Control: no-cache' "$feed_url" \
        | grep -q "sparkle:version=\"$project_build\""; then
        feed_confirmed=true
        break
    fi
    sleep 10
done
[[ "$feed_confirmed" == true ]] || {
    echo "The release published, but $feed_url still does not serve build $project_build." >&2
    echo "Re-check the release assets before announcing the release." >&2
    exit 1
}
echo "Published $tag with its Sparkle appcast."
