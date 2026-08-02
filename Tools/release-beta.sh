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
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/release-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/release-cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

repo="LMC-Karma/BetterTile"
tag="v${version}-beta"
dmg_name="BetterTile-${version}-beta.dmg"
checksum_name="${dmg_name}.sha256"
artifact_dir="$repo_root/.build/beta-release/$tag"
derived_data="$artifact_dir/DerivedData"
archive_dir="$artifact_dir/appcast-input"
appcast_path="$artifact_dir/appcast.xml"
feed_url="https://raw.githubusercontent.com/$repo/updates/appcast.xml"
release_url_prefix="https://github.com/$repo/releases/download/$tag/"

for command in git swift xcodebuild hdiutil shasum ditto; do
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

build_settings="$(xcodebuild -project BetterTile.xcodeproj -scheme BetterTile -configuration Release -showBuildSettings)"
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

if git ls-remote --exit-code --heads origin updates >/dev/null 2>&1; then
    git fetch origin updates
    git show origin/updates:appcast.xml > "$archive_dir/appcast.xml"
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
    -configuration Debug CODE_SIGNING_ALLOWED=NO build
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

stage_dir="$artifact_dir/dmg-root"
mkdir -p "$stage_dir"
ditto "$app_path" "$stage_dir/BetterTile.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname "BetterTile $version Beta" -srcfolder "$stage_dir" \
    -ov -format UDZO "$artifact_dir/$dmg_name"

mount_dir="$artifact_dir/mount"
mkdir -p "$mount_dir"
hdiutil attach "$artifact_dir/$dmg_name" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
trap 'hdiutil detach "$mount_dir" >/dev/null 2>&1 || true' EXIT
[[ -d "$mount_dir/BetterTile.app" && -L "$mount_dir/Applications" ]]
hdiutil detach "$mount_dir" >/dev/null
trap - EXIT
rmdir "$mount_dir"

(
    cd "$artifact_dir"
    shasum -a 256 "$dmg_name" > "$checksum_name"
)
cp "$artifact_dir/$dmg_name" "$archive_dir/$dmg_name"
cp "$notes_path" "$archive_dir/${dmg_name%.dmg}.md"
"$generate_appcast" --download-url-prefix "$release_url_prefix" \
    --embed-release-notes --maximum-deltas 0 --maximum-versions 0 \
    --versions "$project_build" "$archive_dir"
cp "$archive_dir/appcast.xml" "$appcast_path"
grep -q "sparkle:edSignature=" "$appcast_path"
grep -q "$release_url_prefix$dmg_name" "$appcast_path"

echo "Validated beta artifacts: $artifact_dir"
if [[ "$dry_run" == true ]]; then
    echo "Dry run complete; nothing was published."
    exit 0
fi

gh release create "$tag" "$artifact_dir/$dmg_name" "$artifact_dir/$checksum_name" \
    --repo "$repo" --target main --prerelease \
    --title "BetterTile $version Beta" --notes-file "$notes_path"

asset_url="$release_url_prefix$dmg_name"
# --retry alone only covers timeouts and 5xx. A release asset that has not
# finished propagating answers 404, which would abort the run after the release
# is already public, so retry on all errors.
curl --fail --location --head --retry 12 --retry-delay 5 --retry-all-errors "$asset_url" >/dev/null

feed_repo="$artifact_dir/updates-repository"
mkdir -p "$feed_repo"
git -C "$feed_repo" init
git -C "$feed_repo" remote add origin "$(git remote get-url origin)"
if git ls-remote --exit-code --heads origin updates >/dev/null 2>&1; then
    git -C "$feed_repo" fetch origin updates
    git -C "$feed_repo" switch -c updates --track origin/updates
else
    git -C "$feed_repo" switch --orphan updates
fi
cp "$appcast_path" "$feed_repo/appcast.xml"
git -C "$feed_repo" add appcast.xml
git -C "$feed_repo" commit -m "Publish BetterTile $version beta appcast"
git -C "$feed_repo" push origin updates

# raw.githubusercontent.com serves a cached copy for several minutes, so a
# successful request can still return the previous appcast. Retrying the request
# is not enough; poll until the published build actually appears.
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
    echo "This is usually GitHub's raw cache. Re-check before announcing the release." >&2
    exit 1
}
echo "Published $tag and updated the Sparkle appcast."
