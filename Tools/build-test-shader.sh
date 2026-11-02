#!/bin/bash
# Usage: build-test-shader.sh DIRECTORY
# Compiles the Layout Wheel shader into DIRECTORY/BetterTile_BetterTileMacOS.bundle
# for `swift test`. SwiftPM's native build system (the Swift 6.3 default) does
# not compile Metal files. xcodebuild compiles the shader for the app itself;
# these flags match its CompileMetalFile and MetalLink steps.
set -euo pipefail
if [[ $# != 1 || -z "$1" ]]; then
    echo "Usage: $0 DIRECTORY" >&2
    exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
source_file="$script_dir/../Sources/BetterTileMacOS/LayoutWheelLiquid.metal"
bundle="$1/BetterTile_BetterTileMacOS.bundle"
mkdir -p "$bundle/Contents/Resources"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>BetterTile.BetterTileMacOS.resources</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
PLIST
# Keep the target in step with platforms in Package.swift.
target=air64-apple-macos26.0
if ! xcrun -sdk macosx metal -c -target "$target" -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast \
        "$source_file" -o "$1/LayoutWheelLiquid.air"; then
    echo "Could not compile the Layout Wheel shader. Install the Metal Toolchain:" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi
xcrun -sdk macosx metal -target "$target" "$1/LayoutWheelLiquid.air" \
    -o "$bundle/Contents/Resources/default.metallib"
rm "$1/LayoutWheelLiquid.air"
