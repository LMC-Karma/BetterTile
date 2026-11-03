#!/bin/bash
# Verify component download/cache/import behavior without network or Xcode.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$METAL_TEST_CALLS"
if [[ "$1" == -downloadComponent ]]; then
    [[ "$2" == MetalToolchain && "$3" == -exportPath && $# == 4 ]]
    [[ "${METAL_TEST_DOWNLOAD_FAIL:-0}" == 0 ]] || exit 7
    [[ "${METAL_TEST_EMPTY:-0}" == 0 ]] || exit 0
    mkdir "$4/MetalToolchain-test.exportedBundle"
elif [[ "$1" == -showComponent ]]; then
    [[ "$2" == MetalToolchain && $# == 2 ]]
    [[ "${METAL_TEST_SHOW_FAIL:-0}" == 0 ]] || exit 9
    if [[ "${METAL_TEST_INSTALLED:-0}" == 1 ]]; then echo 'Status: installed'; else echo 'Status: not installed'; fi
else
    [[ "$1" == -importComponent && "$2" == MetalToolchain && "$3" == -importPath && $# == 4 ]]
    [[ -e "$4" ]]
    [[ "${METAL_TEST_IMPORT_FAIL:-0}" == 0 ]] || exit 8
fi
STUB
chmod +x "$work/bin/xcodebuild"
export PATH="$work/bin:$PATH" METAL_TEST_CALLS="$work/calls"
setup="$script_dir/../ci/setup-metal.sh"
"$setup" "$work/cache with spaces"
[[ $(wc -l < "$METAL_TEST_CALLS" | tr -d ' ') == 4 ]]
"$setup" "$work/cache with spaces"
[[ $(wc -l < "$METAL_TEST_CALLS" | tr -d ' ') == 6 ]]
[[ $(tail -1 "$METAL_TEST_CALLS") == '-importComponent MetalToolchain -importPath '* ]]
METAL_TEST_INSTALLED=1 "$setup" "$work/cache with spaces"
[[ $(tail -1 "$METAL_TEST_CALLS") == '-showComponent MetalToolchain' ]]
before_installed=$(wc -l < "$METAL_TEST_CALLS" | tr -d ' ')
METAL_TEST_INSTALLED=1 "$setup" "$work/installed cold cache"
after_installed=$(wc -l < "$METAL_TEST_CALLS" | tr -d ' ')
[[ $((after_installed - before_installed)) == 1 ]] || {
    echo "An installed component with a cold cache must not download or import." >&2
    exit 1
}
[[ $(tail -1 "$METAL_TEST_CALLS") == '-showComponent MetalToolchain' ]]
mkdir "$work/dmg cache"
touch "$work/dmg cache/MetalToolchain.dmg"
"$setup" "$work/dmg cache"
reject() {
    if "$setup" "$1"; then
        echo "Accepted an invalid Metal setup: $1" >&2
        exit 1
    fi
}
METAL_TEST_SHOW_FAIL=1 reject "$work/show failure"
METAL_TEST_DOWNLOAD_FAIL=1 reject "$work/download failure"
METAL_TEST_IMPORT_FAIL=1 reject "$work/cache with spaces"
METAL_TEST_EMPTY=1 reject "$work/empty export"
mkdir "$work/cache with spaces/another.exportedBundle"
reject "$work/cache with spaces"
if "$setup"; then
    echo "Accepted missing arguments" >&2
    exit 1
fi
echo "Metal Toolchain setup tests passed (download, cache reuse, import, failures)."
