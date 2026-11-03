#!/bin/bash
# Test the exact decision body without a token, network, checkout or rerun POST.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
workflow="$script_dir/../../.github/workflows/rerun-unacquired.yml"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Extract only the decision step; the POST step must never be executed here.
awk '/^        run: \|$/ && !found { found=1; next }
     found && /^      - name:/ { exit }
     found { sub(/^          /, ""); print }' "$workflow" > "$scratch/decision.sh"
[[ -s "$scratch/decision.sh" ]]
mkdir "$scratch/bin"
cat > "$scratch/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$*" != *POST* ]] || { echo 'Unexpected mutation' >&2; exit 99; }
case "${*: -1}" in
    repos/fixture/repo/actions/runs/123/attempts/[12]/jobs\?per_page=100) cat "$JOBS" ;;
    repos/fixture/repo/check-runs/456/annotations\?per_page=100) cat "$ANNOTATIONS" ;;
    *) echo "Unexpected API request: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" REPOSITORY=fixture/repo RUN_ID=123 RUN_ATTEMPT=1
export JOBS="$scratch/jobs" ANNOTATIONS="$scratch/annotations" GITHUB_OUTPUT="$scratch/output"
printf '[[{"message":"The job was not acquired by Runner of type hosted"}]]\n' > "$ANNOTATIONS"
zero='{"name":"app","conclusion":"cancelled","steps":[]}'
ran='{"name":"unit-tests","conclusion":"failure","steps":[{"status":"completed","conclusion":"failure"}]}'
placeholder='{"name":"app","conclusion":"failure","check_run_url":"https://api.github.com/repos/fixture/repo/check-runs/456","steps":[{"status":"queued","conclusion":null}]}'
aggregate='{"name":"test","conclusion":"failure","steps":[{"conclusion":"failure"}]}'
expect() {
    local expected="$1" description="$2" jobs="$3"
    printf '[{"jobs":[%s]}]\n' "$jobs" > "$JOBS"
    : > "$GITHUB_OUTPUT"
    bash "$scratch/decision.sh" > "$scratch/log"
    [[ "$(tail -1 "$GITHUB_OUTPUT")" == "rerun=$expected" ]] || {
        cat "$scratch/log" >&2; echo "FAIL: $description" >&2; exit 1;
    }
    echo "ok: $description"
}
expect true 'zero-step failure with failed aggregate' "$zero,$aggregate"
expect false 'executed test failure' "$ran,$aggregate"
expect false 'mixed capacity and test failure' "$zero,$ran,$aggregate"
expect true 'unstarted placeholders with runner annotation' "$placeholder,$aggregate"
# An annotation never permits retrying an executed step.
expect false 'executed failure even with annotation' "$ran,$aggregate"
printf '[[{"message":"A test failed"}]]\n' > "$ANNOTATIONS"
expect false 'unstarted placeholders without runner annotation' "$placeholder,$aggregate"
expect false 'missing step data' '{"name":"app","conclusion":"failure"}'
expect false 'only aggregate failed' "$aggregate"
expect false 'no failed jobs' '{"name":"app","conclusion":"success","steps":[]}'
RUN_ATTEMPT=2 expect true 'second attempt still qualifies' "$zero,$aggregate"
for invalid_attempt in 3 0 '1; echo unsafe'; do
    if RUN_ATTEMPT="$invalid_attempt" bash "$scratch/decision.sh" > /dev/null 2>&1; then
        echo 'Accepted an invalid or capped attempt' >&2; exit 1
    fi
    echo 'ok: invalid or capped attempt rejected'
done
echo 'runner recovery decision tests passed'
