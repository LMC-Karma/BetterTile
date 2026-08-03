#!/bin/bash
#
# Tests for Tools/lib/release-workspace.sh.
#
# release_cleanup runs `rm -rf` from an EXIT trap, so the guard deciding what it
# may delete is the highest-consequence line in the release tooling. It is
# covered here rather than only being exercised by a real release.
#
# Run directly: Tools/tests/release-workspace-test.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/release-workspace.sh
source "$script_dir/../lib/release-workspace.sh"

failures=0
scratch="$(mktemp -d /private/tmp/release-workspace-test.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

check_accepts() {
    if is_release_workspace "$1"; then pass "$2"; else fail "$2"; fi
}

check_rejects() {
    if is_release_workspace "$1"; then fail "$2"; else pass "$2"; fi
}

echo "is_release_workspace accepts only generated workspaces"

workspace="$(make_release_workspace)"
check_accepts "$workspace" "accepts a workspace from make_release_workspace"
[[ "$workspace" == "$release_workspace_prefix"* ]] \
    || fail "make_release_workspace used an unexpected prefix"

check_rejects "" "rejects an empty path"
check_rejects "/" "rejects the root directory"
check_rejects "$HOME" "rejects the home directory"
check_rejects "/private/tmp" "rejects the containing temporary directory"
check_rejects "/private/tmp/bettertile-release" "rejects the bare prefix without a suffix"
check_rejects "${release_workspace_prefix}doesnotexist" "rejects a correct prefix that does not exist"
check_rejects "/private/tmp/unrelated-directory" "rejects an unrelated temporary directory"
check_rejects "$scratch" "rejects a directory outside the prefix"

traversal="${workspace}/../../../etc"
check_rejects "$traversal" "rejects a path traversal escaping the prefix"

# Both objects live inside the unique workspace rather than at a predictable
# path directly under /private/tmp: creating a fixed name there could truncate
# or clobber whatever already sits at it. They still start with the workspace
# prefix, which is what these two cases need to exercise, and the workspace
# cleanup below removes them.
file_not_dir="$workspace/not-a-directory"
: > "$file_not_dir"
check_rejects "$file_not_dir" "rejects a regular file"

link="$workspace/outside-link"
ln -s "$scratch" "$link"
check_rejects "$link" "rejects a symlink pointing outside the prefix"

echo "release_cleanup deletes only a real workspace"

release_cleanup "$workspace" "" || true
if [[ -d "$workspace" ]]; then
    fail "release_cleanup did not remove a genuine workspace"
else
    pass "release_cleanup removed a genuine workspace"
fi

guarded="$scratch/must-survive"
mkdir -p "$guarded"
release_cleanup "$guarded" "" || true
if [[ -d "$guarded" ]]; then
    pass "release_cleanup preserved a directory outside the prefix"
else
    fail "release_cleanup deleted a directory outside the prefix"
fi

release_cleanup "" "" || true
if [[ -d "$scratch" ]]; then
    pass "release_cleanup with an empty workspace deleted nothing"
else
    fail "release_cleanup with an empty workspace deleted something"
fi

echo "release_cleanup preserves the triggering exit status"

status=0
survivor="$(make_release_workspace)"
# shellcheck disable=SC2317
( exit 42 ) || release_cleanup "$survivor" "" || status=$?
if [[ "$status" -eq 42 ]]; then
    pass "propagates a failing status"
else
    fail "expected status 42 from release_cleanup, got $status"
fi

status=0
survivor="$(make_release_workspace)"
true
release_cleanup "$survivor" "" || status=$?
if [[ "$status" -eq 0 ]]; then
    pass "propagates a successful status"
else
    fail "expected status 0 from release_cleanup, got $status"
fi

if [[ "$failures" -eq 0 ]]; then
    echo "release-workspace tests passed"
else
    echo "release-workspace tests failed: $failures" >&2
    exit 1
fi
