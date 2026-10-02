#!/bin/bash
# Exercise only commit capture and publication arguments with command stubs.
# Never execute the release entrypoint, build, sign, or publish an artifact.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
release_script="$script_dir/../release-beta.sh"
validated_commit=1111111111111111111111111111111111111111
advanced_commit=2222222222222222222222222222222222222222
remote_main="$validated_commit"
git() {
    case "$*" in
        'rev-parse HEAD') printf '%s\n' "$validated_commit" ;;
        'rev-parse origin/main') printf '%s\n' "$remote_main" ;;
        *) echo "Unexpected git command in source capture" >&2; return 1 ;;
    esac
}
gh() {
    [[ "$1 $2" == 'release create' ]] || return 1
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --target ]]; then
            [[ "${2:-}" == "$validated_commit" ]] || {
                echo "Publication must target the validated source commit, even after main advances." >&2
                return 1
            }
            return 0
        fi
        shift
    done
    echo "Publication did not supply a target." >&2
    return 1
}
# Execute the exact capture and final publication commands rather than a copy
# of their policy. Their surrounding packaging commands are never evaluated.
capture="$(sed -n '/^    release_commit=.*git rev-parse HEAD/p' "$release_script")"
[[ -n "$capture" ]] || { echo "Release source commit is not captured." >&2; exit 1; }
eval "$capture"
remote_main="$advanced_commit"
tag=v0.0.0-beta
work_dir=/unused
dmg_name=fixture.dmg
checksum_name=fixture.sha256
appcast_path=/unused/appcast.xml
repo=fixture/repository
version=0.0.0
notes_path=/unused/notes.md
publication="$(awk '/^gh release create / { found = 1 } found && count++ < 3 { print }' "$release_script")"
[[ "$publication" == *'--title '*'--notes-file '* ]] || {
    echo "The three-line publication command was not found." >&2
    exit 1
}
eval "$publication"
echo "release-source tests passed"
