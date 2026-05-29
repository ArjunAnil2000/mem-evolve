#!/usr/bin/env bash
# run_filebench.sh — Launch FileBench workload and produce JSON results.
#
# Usage:
#   bash run_filebench.sh --workload fileserver --results-file /tmp/fb.json --duration 60
#   bash run_filebench.sh --custom-workload /path/to/custom.f --results-file /tmp/fb.json
#
# Output JSON:
#   {"results": {"ops_per_sec": N, "throughput_mb_sec": N, "avg_latency_us": N,
#                "p99_latency_ms": N, "runtime_sec": N, "workload": "..."}}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
WORKLOAD=""
CUSTOM_WORKLOAD=""
RESULTS_FILE=""
DURATION=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workload)
            WORKLOAD="$2"; shift 2 ;;
        --custom-workload)
            CUSTOM_WORKLOAD="$2"; shift 2 ;;
        --results-file)
            RESULTS_FILE="$2"; shift 2 ;;
        --duration)
            DURATION="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Determine workload file
if [[ -n "$CUSTOM_WORKLOAD" ]]; then
    WORKLOAD_FILE="$CUSTOM_WORKLOAD"
    WORKLOAD_NAME="$(basename "$CUSTOM_WORKLOAD" .f)"
elif [[ -n "$WORKLOAD" ]]; then
    WORKLOAD_FILE="${SCRIPT_DIR}/workloads/${WORKLOAD}.f"
    WORKLOAD_NAME="$WORKLOAD"
else
    echo "Error: must specify --workload <name> or --custom-workload <path>" >&2
    exit 1
fi

if [[ ! -f "$WORKLOAD_FILE" ]]; then
    echo "Error: workload file not found: $WORKLOAD_FILE" >&2
    exit 1
fi

if [[ -z "$RESULTS_FILE" ]]; then
    echo "Error: --results-file is required" >&2
    exit 1
fi

# Create a temporary workload file with the requested duration
TMPFILE="$(mktemp /tmp/filebench_XXXXXX.f)"
trap 'rm -f "$TMPFILE"' EXIT

# Copy workload, replacing any 'run <N>' line with our duration
sed "s/^run [0-9]*/run ${DURATION}/" "$WORKLOAD_FILE" > "$TMPFILE"

echo "Running FileBench workload: ${WORKLOAD_NAME} (duration=${DURATION}s)"
echo "Workload file: ${WORKLOAD_FILE}"

# Run filebench and capture output
START_TIME=$(date +%s)
FB_OUTPUT="$(filebench -f "$TMPFILE" 2>&1)" || true
END_TIME=$(date +%s)
RUNTIME=$((END_TIME - START_TIME))

echo "$FB_OUTPUT"

# Parse the IO Summary line from FileBench output.
# Format: "IO Summary: <ops> ops <ops/s> ops/s <rd/wr> rd/wr <mb/s> mb/s <ms/op> ms/op"
# Or newer: "IO Summary: <ops> ops, <ops/s> ops/s, <rd/wr> rd/wr, <mb/s>mb/s, <latency>us/op"
IO_LINE="$(echo "$FB_OUTPUT" | grep -i 'IO Summary' | tail -1)" || true

if [[ -z "$IO_LINE" ]]; then
    echo "Warning: no IO Summary line found in FileBench output" >&2
    # Write empty results
    cat > "$RESULTS_FILE" <<ENDJSON
{"results": {"ops_per_sec": 0, "throughput_mb_sec": 0, "avg_latency_us": 0, "p99_latency_ms": 0, "runtime_sec": ${RUNTIME}, "workload": "${WORKLOAD_NAME}", "error": "no IO Summary line found"}}
ENDJSON
    exit 1
fi

# Extract ops/sec — look for number before "ops/s"
OPS_PER_SEC="$(echo "$IO_LINE" | grep -oP '[\d.]+(?=\s*ops/s)' | head -1)" || OPS_PER_SEC=0

# Extract throughput in mb/s — look for number before "mb/s"
THROUGHPUT="$(echo "$IO_LINE" | grep -oP '[\d.]+(?=\s*mb/s)' | head -1)" || THROUGHPUT=0

# Extract latency — could be in ms/op or us/op
LATENCY_MS="$(echo "$IO_LINE" | grep -oP '[\d.]+(?=\s*ms/op)' | head -1)" || LATENCY_MS=""
LATENCY_US="$(echo "$IO_LINE" | grep -oP '[\d.]+(?=\s*us/op)' | head -1)" || LATENCY_US=""

if [[ -n "$LATENCY_US" ]]; then
    AVG_LATENCY_US="$LATENCY_US"
elif [[ -n "$LATENCY_MS" ]]; then
    # Convert ms to us
    AVG_LATENCY_US="$(echo "$LATENCY_MS * 1000" | bc -l 2>/dev/null || echo 0)"
else
    AVG_LATENCY_US=0
fi

# Estimate p99 as ~3x average (FileBench doesn't provide percentiles directly)
P99_LATENCY_MS="$(echo "${AVG_LATENCY_US} * 3 / 1000" | bc -l 2>/dev/null || echo 0)"

# Write JSON results
cat > "$RESULTS_FILE" <<ENDJSON
{"results": {"ops_per_sec": ${OPS_PER_SEC:-0}, "throughput_mb_sec": ${THROUGHPUT:-0}, "avg_latency_us": ${AVG_LATENCY_US:-0}, "p99_latency_ms": ${P99_LATENCY_MS:-0}, "runtime_sec": ${RUNTIME}, "workload": "${WORKLOAD_NAME}"}}
ENDJSON

echo "Results written to ${RESULTS_FILE}"
