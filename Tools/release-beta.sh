#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: Tools/release-beta.sh [--dry-run [--notarize]] <version> <notes.md>" >&2
    exit 2
}

# Publication always notarizes. A dry run notarizes only with --notarize; its
# artifacts are still never published.
dry_run=false
notarize=true
dry_run_notarize=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true; shift ;;
        --notarize) dry_run_notarize=true; shift ;;
        -*) usage ;;
        *) break ;;
    esac
done
[[ $# -eq 2 ]] || usage
if [[ "$dry_run" == true ]]; then
    notarize="$dry_run_notarize"
elif [[ "$dry_run_notarize" == true ]]; then
    echo "--notarize applies only to --dry-run; publication always notarizes." >&2
    exit 2
fi

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

signing_identity="${BETTERTILE_SIGNING_IDENTITY:--}"
notary_profile="${BETTERTILE_NOTARY_PROFILE:-BetterTile-Notary}"
if [[ "$notarize" == true && "$signing_identity" == "-" ]]; then
    echo "Notarization requires BETTERTILE_SIGNING_IDENTITY to select the Developer ID Application identity." >&2
    echo "Ad-hoc signing remains available only for dry runs without --notarize." >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"
# shellcheck source=lib/release-notarize.sh
source "$script_dir/lib/release-notarize.sh"

# The Apple Developer Program team whose Developer ID Application certificate
# signs every distributed BetterTile. Gatekeeper, notarization, and the
# Accessibility grant all follow this team, so it is pinned here rather than
# read from the environment.
expected_team_id="2BZVM9DDGQ"
if [[ "$signing_identity" != "-" ]]; then
    is_team_id "$expected_team_id" || {
        echo "The Developer ID Team ID is not pinned in Tools/release-beta.sh (expected_team_id)." >&2
        exit 1
    }
fi
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
# The website and README link to releases/latest/download/BetterTile.dmg.
# GitHub resolves that URL to the newest release, so the Download button
# never names an old version. Sparkle keeps the versioned asset.
stable_dmg_name="BetterTile.dmg"
stable_checksum_name="${stable_dmg_name}.sha256"
notes_name="${dmg_name%.dmg}.md"
artifact_dir="$repo_root/.build/beta-release/$tag"
feed_url="https://github.com/$repo/releases/latest/download/appcast.xml"
release_url_prefix="https://github.com/$repo/releases/download/$tag/"
expected_signing_requirement="$(developer_id_requirement com.lmckarma.BetterTile "$expected_team_id")"
nested_signing_requirement="$(developer_id_team_requirement "$expected_team_id")"

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
published_appcast_path="$work_dir/published-appcast.xml"

trap 'release_cleanup "$work_dir" "$mount_dir"' EXIT

export CLANG_MODULE_CACHE_PATH="$work_dir/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$work_dir/module-cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

for command in git swift xcodebuild hdiutil shasum ditto curl lipo dwarfdump xmllint; do
    command -v "$command" >/dev/null || {
        echo "Required command not found: $command" >&2
        exit 1
    }
done

# Check the signing identity and notary credentials before the long build, so a
# missing certificate or expired credential fails in seconds, not minutes.
if [[ "$signing_identity" != "-" ]]; then
    identities="$(security find-identity -v -p codesigning)"
    grep -F "$signing_identity" <<< "$identities" | grep '"Developer ID Application: ' >/dev/null || {
        echo "No valid Developer ID Application identity matches BETTERTILE_SIGNING_IDENTITY." >&2
        exit 1
    }
fi
if [[ "$notarize" == true ]]; then
    check_notary_profile "$notary_profile" "$work_dir/notary-profile.err"
fi

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
    release_commit="$(git rev-parse HEAD)"
    [[ "$release_commit" == "$(git rev-parse origin/main)" ]] || {
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

expected_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/BetterTileApp/Info.plist)"
appcast_signing_args=()
if [[ "$dry_run" == true ]]; then
    # Never access the release Keychain during validation. This disposable seed
    # and its public key are used only by the temporary dry-run application.
    public_key="$(swift "$script_dir/lib/release-dry-run-key.swift" "$work_dir/dry-run-key")"
    appcast_signing_args=(--ed-key-file "$work_dir/dry-run-key")
else
    # set -e would otherwise end the script without a reason when generate_keys
    # fails. Its own message is shown; a missing key also says where to release.
    public_key="$("$generate_keys" -p 2>"$work_dir/generate_keys.err")" || {
        key_error="$(cat "$work_dir/generate_keys.err") $public_key"
        echo "Sparkle's generate_keys could not read the signing key: $key_error" >&2
        if [[ "$key_error" == *"No existing signing key found"* ]]; then
            echo "This Mac's login Keychain has no Sparkle signing key. Release from the" >&2
            echo "Mac that holds it, or import it with generate_keys -f first." >&2
        fi
        exit 1
    }
    [[ "$public_key" == "$expected_public_key" ]] || {
        echo "The configured release signing key does not match Info.plist." >&2
        exit 1
    }
fi

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

prepare_appcast_input "$feed_url" "$version" "$project_build" "$dry_run" \
    "$published_appcast_path" "$archive_dir/appcast.xml"

echo "Running tests and builds..."
"$script_dir/test.sh" "$work_dir/tests.log"
swift build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
    -configuration Debug CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$debug_derived_data" build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
    -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -derivedDataPath "$derived_data" build

app_path="$derived_data/Build/Products/Release/BetterTile.app"
info_path="$app_path/Contents/Info.plist"
dsym_path="$derived_data/Build/Products/Release/BetterTile.app.dSYM"
[[ -d "$app_path" && -f "$info_path" ]] || {
    echo "Release application bundle was not produced." >&2
    exit 1
}
[[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] || {
    echo "Release bundle does not contain Sparkle.framework." >&2
    exit 1
}

[[ "$(lipo -archs "$app_path/Contents/MacOS/BetterTile")" == arm64 ]] || {
    echo "Release executable must contain only arm64." >&2
    exit 1
}
[[ -d "$dsym_path" ]] || {
    echo "Release dSYM was not produced." >&2
    exit 1
}
binary_uuid="$(dwarfdump --uuid "$app_path/Contents/MacOS/BetterTile" | awk '{print $2, $3}')"
dsym_uuid="$(dwarfdump --uuid "$dsym_path" | awk '{print $2, $3}')"
[[ -n "$binary_uuid" && "$binary_uuid" == "$dsym_uuid" ]] || {
    echo "Release executable and dSYM UUIDs do not match." >&2
    exit 1
}
if [[ "$dry_run" == true ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" "$info_path"
    expected_public_key="$public_key"
fi

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
# Dry runs default to "-" (ad-hoc). Publication requires the maintainer's
# Developer ID Application identity, and the requirement checks below pin its
# Team ID rather than trusting the identity's editable Keychain name. A real
# identity also turns on the hardened runtime and a secure timestamp, which
# notarization requires; see release_codesign_options.
codesign_options=()
while IFS= read -r option; do
    codesign_options+=("$option")
done < <(release_codesign_options "$signing_identity")
sparkle_versions="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
sparkle_components=(
    "$sparkle_versions/XPCServices/Downloader.xpc"
    "$sparkle_versions/XPCServices/Installer.xpc"
    "$sparkle_versions/Updater.app"
    "$sparkle_versions/Autoupdate"
    "$sparkle_versions"
)
for nested in "${sparkle_components[@]}"; do
    [[ -e "$nested" ]] || {
        echo "Expected Sparkle component is missing: $nested" >&2
        exit 1
    }
    # Sparkle documents preserving the Downloader service's entitlements.
    preserve=()
    [[ "$nested" == *"/Downloader.xpc" ]] && preserve=(--preserve-metadata=entitlements)
    codesign --force "${codesign_options[@]}" ${preserve[@]+"${preserve[@]}"} \
        --sign "$signing_identity" "$nested"
done
codesign --force "${codesign_options[@]}" --sign "$signing_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
# Validate the final signed executable, after Xcode's strip step and signing.
[[ "$(dwarfdump --uuid "$app_path/Contents/MacOS/BetterTile" | awk '{print $2, $3}')" == "$dsym_uuid" ]] || {
    echo "Signed executable no longer matches the dSYM UUID." >&2
    exit 1
}
[[ "$(codesign -dvv "$app_path" 2>&1 | sed -n 's/^Identifier=//p')" == "com.lmckarma.BetterTile" ]] || {
    echo "Signed bundle identifier does not match the Accessibility grant identity." >&2
    exit 1
}
if [[ "$signing_identity" != "-" ]]; then
    codesign --verify --requirement "=$expected_signing_requirement" "$app_path" || {
        echo "Signed application does not satisfy the pinned Developer ID requirement." >&2
        exit 1
    }
    for nested in "${sparkle_components[@]}"; do
        codesign --verify --requirement "=$nested_signing_requirement" "$nested" || {
            echo "Sparkle component is not signed by the pinned Developer ID team: $nested" >&2
            exit 1
        }
    done
    signature_details="$(codesign -dv "$app_path" 2>&1)"
    grep '^CodeDirectory .*flags=.*runtime' <<< "$signature_details" >/dev/null || {
        echo "Signed application does not use the hardened runtime." >&2
        exit 1
    }
fi

# Notarize the application itself and staple its ticket, so a copy dragged out
# of the disk image passes Gatekeeper offline. The disk image is notarized
# separately below.
if [[ "$notarize" == true ]]; then
    mkdir -p "$work_dir/notarization"
    ditto -c -k --keepParent "$app_path" "$work_dir/notarization/BetterTile.zip"
    notarize_submission "$work_dir/notarization/BetterTile.zip" "$notary_profile" \
        "$work_dir/notarization/app"
    staple_ticket "$app_path"
    codesign --verify --deep --strict "$app_path"
    gatekeeper_accepts exec "$app_path"
fi

read_info() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$info_path"
}

[[ "$(read_info CFBundleShortVersionString)" == "$version" ]]
[[ "$(read_info CFBundleVersion)" == "$project_build" ]]
[[ "$(read_info SUPublicEDKey)" == "$expected_public_key" ]]
[[ "$(read_info SUFeedURL)" == "$feed_url" ]]
[[ "$(read_info SUScheduledCheckInterval)" == "14400" ]]
[[ "$(read_info SUEnableAutomaticChecks)" == "YES" ]]
[[ "$(read_info SUAutomaticallyUpdate)" == "false" ]]
[[ "$(read_info SUAllowsAutomaticUpdates)" == "false" ]]
[[ "$(read_info SUEnableSystemProfiling)" == "false" ]]
[[ "$(read_info SUShowReleaseNotes)" == "true" ]]

# The license and third-party notices ship inside the application.
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
    cmp -s "$app_path/Contents/Resources/$notice" "$repo_root/$notice" || {
        echo "The application does not contain the current $notice." >&2
        exit 1
    }
done

# The Layout Wheel's liquid renderer needs its compiled shader. A build machine
# without Xcode's Metal toolchain omits it silently, and the wheel falls back.
shader="$app_path/Contents/Resources/BetterTile_BetterTileMacOS.bundle/Contents/Resources/default.metallib"
[[ -s "$shader" ]] || {
    echo "The application does not contain the Layout Wheel shader (default.metallib)." >&2
    echo "Install the Metal toolchain: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}

mkdir -p "$stage_dir"
ditto "$app_path" "$stage_dir/BetterTile.app"
ln -s /Applications "$stage_dir/Applications"
hdiutil create -volname "BetterTile $version Beta" -srcfolder "$stage_dir" \
    -ov -format UDZO "$work_dir/$dmg_name"

# Sign, notarize, and staple the disk image before anything records its bytes.
# Stapling changes the file, so the checksums and the Sparkle EdDSA signature
# below must be computed only after this step.
if [[ "$signing_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$signing_identity" "$work_dir/$dmg_name"
    codesign --verify --requirement "=$nested_signing_requirement" "$work_dir/$dmg_name" || {
        echo "The disk image is not signed by the pinned Developer ID team." >&2
        exit 1
    }
fi
if [[ "$notarize" == true ]]; then
    notarize_submission "$work_dir/$dmg_name" "$notary_profile" "$work_dir/notarization/dmg"
    staple_ticket "$work_dir/$dmg_name"
    gatekeeper_accepts open "$work_dir/$dmg_name"
fi

mkdir -p "$mount_dir"
hdiutil attach "$work_dir/$dmg_name" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
[[ -d "$mount_dir/BetterTile.app" && -L "$mount_dir/Applications" ]]
# The signature must still validate through the disk image, which is what a
# tester actually launches from.
codesign --verify --deep --strict "$mount_dir/BetterTile.app"
if [[ "$signing_identity" != "-" ]]; then
    codesign --verify --requirement "=$expected_signing_requirement" "$mount_dir/BetterTile.app" || {
        echo "Packaged application does not satisfy the pinned Developer ID requirement." >&2
        exit 1
    }
fi
if [[ "$notarize" == true ]]; then
    xcrun stapler validate "$mount_dir/BetterTile.app" >/dev/null || {
        echo "The packaged application has no valid stapled ticket." >&2
        exit 1
    }
    gatekeeper_accepts exec "$mount_dir/BetterTile.app"
fi
hdiutil detach "$mount_dir" >/dev/null
rmdir "$mount_dir"

(
    cd "$work_dir"
    shasum -a 256 "$dmg_name" > "$checksum_name"
    cp "$dmg_name" "$stable_dmg_name"
    shasum -a 256 "$stable_dmg_name" > "$stable_checksum_name"
    cmp -s "$dmg_name" "$stable_dmg_name"
)
cp "$work_dir/$dmg_name" "$archive_dir/$dmg_name"
cp "$notes_path" "$archive_dir/$notes_name"
"$generate_appcast" ${appcast_signing_args[@]+"${appcast_signing_args[@]}"} --download-url-prefix "$release_url_prefix" \
    --embed-release-notes --maximum-deltas 0 --maximum-versions 0 \
    --versions "$project_build" "$archive_dir"
cp "$archive_dir/appcast.xml" "$appcast_path"
grep -q "sparkle:edSignature=" "$appcast_path"
grep -q "$release_url_prefix$dmg_name" "$appcast_path"
appcast_contains_build "$appcast_path" "$project_build"
appcast_contains_version "$appcast_path" "$version"
validate_arm64_appcast "$appcast_path" "$project_build"

# Retain only the finished, inspectable artifacts. DerivedData and the disk
# image staging tree stay in the temporary directory and are discarded.
mkdir -p "$artifact_dir"
cp "$work_dir/$dmg_name" "$work_dir/$checksum_name" "$work_dir/$stable_dmg_name" \
    "$work_dir/$stable_checksum_name" "$appcast_path" "$artifact_dir/"
cp "$notes_path" "$artifact_dir/$notes_name"
ditto "$dsym_path" "$artifact_dir/BetterTile.app.dSYM"
if [[ -d "$work_dir/notarization" ]]; then
    mkdir -p "$artifact_dir/notarization"
    cp "$work_dir"/notarization/*.json "$artifact_dir/notarization/" 2>/dev/null || true
fi

echo "Validated beta artifacts: $artifact_dir"
if [[ "$dry_run" == true ]]; then
    echo "Dry run complete; nothing was published."
    exit 0
fi

gh release create "$tag" "$work_dir/$dmg_name" "$work_dir/$checksum_name" "$work_dir/$stable_dmg_name" \
    "$work_dir/$stable_checksum_name" "$appcast_path" --repo "$repo" --target "$release_commit" --latest \
    --title "BetterTile $version Beta" --notes-file "$notes_path"

asset_url="$release_url_prefix$dmg_name"
# --retry alone only covers timeouts and 5xx. A release asset that has not
# finished propagating answers 404, which would abort the run after the release
# is already public, so retry on all errors.
curl --fail --location --head --retry 12 --retry-delay 5 --retry-all-errors "$asset_url" >/dev/null
curl --fail --location --head --retry 12 --retry-delay 5 --retry-all-errors \
    "$release_url_prefix$stable_dmg_name" >/dev/null

# The release and its Latest redirect can take a moment to propagate. Poll the
# public feed until it serves the build that was just published.
feed_confirmed=false
for _ in $(seq 1 30); do
    if curl --fail --silent --location --retry 3 --retry-delay 2 --retry-all-errors \
        --header 'Cache-Control: no-cache' --output "$published_appcast_path" "$feed_url" \
        && appcast_contains_build "$published_appcast_path" "$project_build"; then
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
