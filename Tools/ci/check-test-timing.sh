#!/bin/bash
# Count real-time operations without invoking Swift or touching the desktop.
set -euo pipefail
trap 'exit 1' ERR
export LC_ALL=C
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/../.."
baseline=Tools/ci/test-timing-baseline.txt
update=0
allow_increase=0
for arg in "$@"; do
    case "$arg" in
        --update-baseline) update=1 ;;
        --allow-increase) allow_increase=1 ;;
        *) echo "Usage: $0 [--update-baseline [--allow-increase]]" >&2; exit 1 ;;
    esac
done
if [[ "$allow_increase" == 1 && "$update" == 0 ]]; then
    echo "--allow-increase requires --update-baseline." >&2
    exit 1
fi
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
# A missing baseline starts with zero allowances; it never grants new ones.
if [[ -f "$baseline" ]]; then
    cp "$baseline" "$work_dir/old"
else
    : > "$work_dir/old"
fi

find Tests -type f -name '*.swift' -exec awk '
BEGIN {
    ws = "[[:space:]]*"
    boundary = "(^|[^[:alnum:]_])"
    dot = ws "[.]" ws
    patterns["Task.sleep"] = boundary "Task(" ws "<[^>]+>)?" dot "sleep" ws "\\("
    patterns["usleep"] = boundary "usleep" ws "\\("
    patterns["Thread.sleep"] = boundary "Thread" dot "sleep" ws "\\("
    patterns["sleep"] = "((^|[^[:alnum:]_.])|" boundary "(Darwin|Glibc)" dot ")sleep" ws "\\("
    patterns["Date()"] = boundary "Date" ws "\\(" ws "\\)"
    patterns["Date.now"] = boundary "Date" dot "now([^[:alnum:]_]|$)"
    patterns["CFAbsoluteTimeGetCurrent"] = boundary "CFAbsoluteTimeGetCurrent" ws "\\("
    patterns["systemUptime"] = boundary "ProcessInfo" dot "processInfo" dot "systemUptime([^[:alnum:]_]|$)"
    patterns["DispatchTime.now"] = boundary "DispatchTime" dot "now" ws "\\("
    patterns["ContinuousClock"] = boundary "ContinuousClock(" dot "now([^[:alnum:]_]|$)|(" dot "init)?" ws "\\()"
    patterns["SuspendingClock"] = boundary "SuspendingClock(" dot "now([^[:alnum:]_]|$)|(" dot "init)?" ws "\\()"
    disabled = "[.]" ws "disabled" ws "\\("
    quarantine = "^[[:space:]]*\"quarantine: #[1-9][0-9]*[[:space:]]+[^\"[:space:]][^\"]*\"[[:space:]]*\\)"
    # A condition gate, like `.enabled(if:)`, is not a quarantine.
    conditional = "^[[:space:]]*if[[:space:]]*:"
}
# Mask comments and string contents while retaining offsets and newlines.
# This is a spelling guard, not a Swift parser (aliases are outside its scope).
function scrub(line,    i, c, pair, triple, masked, visible, n, rest, token, chunk, spaces, size, j) {
    masked = visible = ""
    n = length(line)
    for (i = 1; i <= n; i++) {
        # Copy whole runs between delimiters instead of visiting every byte.
        if (!escaped) {
            rest = substr(line, i)
            token = (block ? "/\\*|\\*/" : (quoted ? "[\"\\\\]" : "[\"/]"))
            size = (match(rest, token) ? RSTART - 1 : length(rest))
            if (size) {
                chunk = substr(rest, 1, size); spaces = chunk
                gsub(/./, " ", spaces)
                masked = masked (block || quoted ? spaces : chunk)
                visible = visible (block ? spaces : chunk)
                i += size
                if (i > n) break
            }
        }
        c = substr(line, i, 1)
        pair = substr(line, i, 2)
        triple = substr(line, i, 3)
        if (block) {
            if (pair == "/*") { block++; i++; masked = masked "  "; visible = visible "  " }
            else if (pair == "*/") { block--; i++; masked = masked "  "; visible = visible "  " }
            else { masked = masked " "; visible = visible " " }
        } else if (quoted) {
            visible = visible c
            masked = masked " "
            if (escaped) escaped = 0
            else if (c == "\\" && hashes == "") escaped = 1
            else if (quoted == 3 && triple == "\"\"\"" && substr(line, i + 3, length(hashes)) == hashes) {
                visible = visible "\"\""; masked = masked "  "; i += 2; quoted = 0
            } else if (quoted == 1 && c == "\"" && substr(line, i + 1, length(hashes)) == hashes) quoted = 0
        } else if (pair == "//") {
            if (substr(line, i) ~ /\/\/ real-time:[[:space:]]*[^[:space:]]/) annotated[FNR] = 1
            spaces = substr(line, i); gsub(/./, " ", spaces)
            masked = masked spaces; visible = visible spaces
            break
        } else if (pair == "/*") {
            block = 1; i++; masked = masked "  "; visible = visible "  "
        } else if (c == "\"") {
            hashes = ""
            for (j = i - 1; j > 0 && substr(line, j, 1) == "#"; j--) hashes = hashes "#"
            quoted = (triple == "\"\"\"" ? 3 : 1)
            visible = visible (quoted == 3 ? "\"\"\"" : "\"")
            masked = masked (quoted == 3 ? "   " : " ")
            if (quoted == 3) i += 2
        } else { masked = masked c; visible = visible c }
    }
    source = source masked "\n"
    original = original visible "\n"
}
function line_at(offset,    prefix) {
    prefix = substr(source, 1, offset - 1)
    return gsub(/\n/, "", prefix) + 1
}
function scan(    key, rest, offset, start, size, line, argument, declaration) {
    for (key in patterns) {
        rest = source; offset = 0
        while (match(rest, patterns[key])) {
            start = offset + RSTART; size = RLENGTH
            # The boundary may include the previous newline or indentation.
            while (substr(source, start, 1) ~ /[[:space:]]/) start++
            line = line_at(start)
            declaration = (key == "sleep" && substr(source, 1, start - 1) ~ /(^|[^[:alnum:]_])func[[:space:]]*$/)
            if (!annotated[line] && !declaration) printf "%s\t%s\t%d\n", file, key, line
            offset += RSTART + size - 1
            rest = substr(source, offset + 1)
        }
    }
    rest = source; offset = 0
    while (match(rest, disabled)) {
        start = offset + RSTART; size = RLENGTH
        argument = substr(original, offset + RSTART + size)
        if (argument !~ quarantine && argument !~ conditional) printf "%s\tquarantine\t%d\n", file, line_at(start)
        offset += RSTART + size - 1
        rest = substr(source, offset + 1)
    }
}
FNR == 1 {
    if (NR > 1) scan()
    file = FILENAME; source = original = ""; block = quoted = escaped = 0
    for (line in annotated) delete annotated[line]
}
{ scrub($0) }
END { scan() }
' {} + > "$work_dir/hits"

awk -F '\t' '
    { counts[$1 FS $2]++ }
    END { for (key in counts) print key FS counts[key] }
' "$work_dir/hits" | sort > "$work_dir/current"

if ! awk -F '\t' -v update="$update" -v allow="$allow_increase" '
FILENAME == ARGV[1] {
    if ($0 ~ /^#/ || $0 == "") next
    if (NF != 3 || $3 !~ /^[1-9][0-9]*$/ || ($1 FS $2) in old) {
        print "Invalid timing baseline row " FNR ": " $0; failed = 1
    }
    old[$1 FS $2] = $3
    next
}
FILENAME == ARGV[2] { current[$1 FS $2] = $3; next }
{
    key = $1 FS $2
    if (current[key] > old[key] && !(update && allow)) {
        if (!reported[key]++) {
            printf "%s:%s: %s count %d exceeds baseline %d. ", $1, $3, $2, current[key], old[key]
            if ($2 == "quarantine") print "Use .disabled(\"quarantine: #<number> <reason>\")."
            else print "Use the injected clock or add // real-time: <reason> on the call line."
        }
        failed = 1
    }
}
END {
    for (key in old) if (current[key] + 0 < old[key]) {
        split(key, parts, FS)
        printf "%s:1: hint: %s count fell from %d to %d; run Tools/ci/check-test-timing.sh --update-baseline to lower the baseline.\n", parts[1], parts[2], old[key], current[key]
    }
    if (failed && update) print "Baseline unchanged. Refusing increases without --allow-increase (or fix the invalid baseline)."
    exit (failed ? 1 : 0)
}' "$work_dir/old" "$work_dir/current" "$work_dir/hits"; then
    exit 1
fi

if [[ "$update" == 1 ]]; then
    { printf '# File\tPattern\tCount (unannotated calls; quarantine counts invalid disabled traits)\n'; cat "$work_dir/current"; } > "$baseline"
    echo "Updated $baseline."
else
    echo "Test timing and quarantine guard passed."
fi
