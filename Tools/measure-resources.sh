#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
    echo "usage: $0 PID [DURATION_SECONDS] [INTERVAL_SECONDS] [LABEL]" >&2
    exit 64
fi

target_pid=$1
duration_seconds=${2:-60}
interval_seconds=${3:-1}
label=${4:-sample}

if ! kill -0 "$target_pid" 2>/dev/null; then
    echo "process $target_pid is not running" >&2
    exit 69
fi

output_directory="${TMPDIR:-/tmp}/bettertile-resource-measurements"
mkdir -p "$output_directory"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_file="$output_directory/${label}-${timestamp}.csv"

echo "elapsed_seconds,cpu_percent,rss_kib" > "$output_file"
started_at=$(date +%s)

while kill -0 "$target_pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - started_at))
    if (( elapsed > duration_seconds )); then
        break
    fi

    sample=$(ps -p "$target_pid" -o %cpu=,rss=)
    if [[ -n "$sample" ]]; then
        read -r cpu rss <<< "$sample"
        echo "$elapsed,$cpu,$rss" >> "$output_file"
    fi
    sleep "$interval_seconds"
done

awk -F, '
    NR > 1 {
        if (count == 0) first_rss = $3
        last_rss = $3
        cpu_total += $2
        rss_total += $3
        if ($2 > cpu_max) cpu_max = $2
        if ($3 > rss_max) rss_max = $3
        count += 1
    }
    END {
        if (count == 0) {
            print "no samples captured" > "/dev/stderr"
            exit 1
        }
        printf "samples=%d avg_cpu=%.3f%% max_cpu=%.3f%% avg_rss=%.1fMiB max_rss=%.1fMiB rss_delta=%.1fMiB\n",
            count, cpu_total / count, cpu_max,
            rss_total / count / 1024, rss_max / 1024, (last_rss - first_rss) / 1024
    }
' "$output_file"

echo "csv=$output_file"
