#!/bin/bash
# This renders SwiftUI artwork and records this host's macOS build,
# architecture and Swift toolchain as the generator. The glyph mask tests run
# exactly only on a host that matches that record and use tolerance checks
# elsewhere, so regenerate on the machine that should own the exact check.
# On a shared test machine, hold QUIET then DESKTOP around this entire
# script, including every build and test command.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ${1:-} == --set ]]; then
    df -h /
    swift build --target BetterTileMacOS
    exec python3 Tools/glyph-mask-processes.py "$@"
fi
[[ $# -eq 0 ]] || { echo "Usage: Tools/generate-glyph-masks.sh [--set menu-glass --work-directory PATH [--check]]" >&2; exit 2; }
output="$(pwd)/Sources/BetterTileMacOS/Resources/GlyphMasks"
BT_GENERATE_GLYPH_MASKS="$output" swift test --no-parallel \
    --filter GlyphMaskStoreTests/shippedResourcesAreFreshOrRegenerateExplicitly
# Copy changed resources into the built bundle before parity/freshness tests.
swift build --build-tests
# A successful generation is not an acceptance result. Keep the exact gate.
swift test --skip-build --no-parallel --filter GlyphMaskStoreTests
