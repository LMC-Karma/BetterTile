#!/bin/bash
#
# Sourceable helpers for Tools/release-beta.sh.
#
# These live in their own file so the destructive cleanup path can be tested
# without running a release. Tools/tests/release-workspace-test.sh covers them.

# Every temporary release workspace lives under this prefix. This is the single
# definition of the safety rule; nothing else may open-code it.
release_workspace_prefix="/private/tmp/bettertile-release."

# True only for a directory this tool could have created and may therefore
# delete. Anything else — an empty value, a path outside the prefix, a traversal
# escaping it, a non-directory — is rejected, because the only caller of this
# predicate goes on to run `rm -rf`.
is_release_workspace() {
    local candidate="${1:-}"
    [[ -n "$candidate" ]] || return 1
    [[ "$candidate" == "$release_workspace_prefix"?* ]] || return 1
    [[ "$candidate" != *".."* ]] || return 1
    [[ -d "$candidate" ]] || return 1
    [[ ! -L "$candidate" ]] || return 1
}

make_release_workspace() {
    mktemp -d "${release_workspace_prefix}XXXXXXXX"
}

# Detach the disk image if it is still mounted, then remove the workspace.
#
# Called from an EXIT trap, so it captures and re-returns the status that
# triggered it: a cleanup must never convert a failed release into a successful
# one, nor a successful one into a failure.
release_cleanup() {
    local status=$?
    local workspace="${1:-}"
    local mount_point="${2:-}"
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fi
    if is_release_workspace "$workspace"; then
        rm -rf "$workspace"
    fi
    return "$status"
}
