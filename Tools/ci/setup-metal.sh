#!/bin/bash
# Cache Apple's exported component, then import it for the selected Xcode.
set -euo pipefail
if [[ $# != 1 || -z "$1" ]]; then
    echo "Usage: $0 EXPORT_DIRECTORY" >&2
    exit 1
fi
# Inspect the selected Xcode before fetching a large component on a cold cache.
component_installed() {
    local status
    if ! status="$(xcodebuild -showComponent MetalToolchain)"; then
        echo "Could not inspect Metal Toolchain for the selected Xcode." >&2
        exit 1
    fi
    [[ "$status" =~ (^|$'\n')Status:\ installed($|$'\n') ]]
}
if component_installed; then
    echo "Metal Toolchain is already installed for the selected Xcode."
    exit 0
fi
metal_export_dir="$1"
mkdir -p "$metal_export_dir"
shopt -s nullglob
bundles=("$metal_export_dir"/*.exportedBundle "$metal_export_dir"/*.dmg)
downloaded=0
if [[ ${#bundles[@]} == 0 ]]; then
    xcodebuild -downloadComponent MetalToolchain -exportPath "$metal_export_dir"
    bundles=("$metal_export_dir"/*.exportedBundle "$metal_export_dir"/*.dmg)
    downloaded=1
fi
if [[ ${#bundles[@]} != 1 ]]; then
    echo "Expected one exported Metal Toolchain in $metal_export_dir; found ${#bundles[@]}." >&2
    exit 1
fi
# Download can install too. Validate its export before skipping the import.
if [[ "$downloaded" == 1 ]] && component_installed; then
    echo "Metal Toolchain was installed by the download."
    exit 0
fi
xcodebuild -importComponent MetalToolchain -importPath "${bundles[0]}"
