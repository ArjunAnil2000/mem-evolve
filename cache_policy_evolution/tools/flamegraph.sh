#!/usr/bin/env bash
# flamegraph.sh — proxychains-style wrapper that flame-graphs any command
#
# Usage:
#   sudo ./tools/flamegraph.sh command [args...]
#   sudo ./tools/flamegraph.sh -o output.svg command [args...]
#   sudo ./tools/flamegraph.sh -F 199 -o my.svg bash eval/scan_thrash/run.sh
#
# Options:
#   -o FILE    Output SVG path (default: flamegraph.svg)
#   -F FREQ    Sampling frequency in Hz (default: 99)
#   -a         System-wide recording (all CPUs, not just the command)
#   -k         Kernel stacks only (skip userspace)
#   -t TITLE   Title shown in the SVG header
#   --keep     Keep intermediate perf.data and stacks files
#
# Requirements:
#   - perf (linux-tools-common / linux-tools-$(uname -r))
#   - FlameGraph repo (auto-cloned to ~/.flamegraph if not found)

set -euo pipefail

# -----------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------
OUTPUT="flamegraph.svg"
FREQ=99
SYSTEM_WIDE=false
KERNEL_ONLY=false
TITLE=""
KEEP=false

# -----------------------------------------------------------------
# Parse options (everything before the command)
# -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)       OUTPUT="$2"; shift 2 ;;
        -F)       FREQ="$2"; shift 2 ;;
        -a)       SYSTEM_WIDE=true; shift ;;
        -k)       KERNEL_ONLY=true; shift ;;
        -t)       TITLE="$2"; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# //; s/^#//; p; }' "$0"
            exit 0
            ;;
        --)       shift; break ;;
        -*)       echo "Unknown option: $1" >&2; exit 1 ;;
        *)        break ;;  # first non-option = start of command
    esac
done

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") [options] command [args...]" >&2
    echo "Run '$(basename "$0") --help' for details." >&2
    exit 1
fi

# -----------------------------------------------------------------
# Find or install FlameGraph tools
# -----------------------------------------------------------------
FLAMEGRAPH_DIR=""

find_flamegraph() {
    # 1. Check PATH
    if command -v flamegraph.pl &>/dev/null; then
        FLAMEGRAPH_DIR="$(dirname "$(command -v flamegraph.pl)")"
        return 0
    fi

    # 2. Check common locations
    for dir in ~/.flamegraph /opt/FlameGraph /usr/local/share/FlameGraph; do
        if [[ -x "$dir/flamegraph.pl" ]]; then
            FLAMEGRAPH_DIR="$dir"
            return 0
        fi
    done

    # 3. Auto-clone
    echo "[flamegraph] FlameGraph tools not found — cloning to ~/.flamegraph" >&2
    git clone --depth 1 https://github.com/brendangregg/FlameGraph.git ~/.flamegraph >&2
    FLAMEGRAPH_DIR="$HOME/.flamegraph"
}

find_flamegraph

STACKCOLLAPSE="$FLAMEGRAPH_DIR/stackcollapse-perf.pl"
FLAMEGRAPH_PL="$FLAMEGRAPH_DIR/flamegraph.pl"

if [[ ! -x "$STACKCOLLAPSE" || ! -x "$FLAMEGRAPH_PL" ]]; then
    echo "[flamegraph] ERROR: FlameGraph scripts not executable in $FLAMEGRAPH_DIR" >&2
    exit 1
fi

# -----------------------------------------------------------------
# Temp files
# -----------------------------------------------------------------
WORKDIR=$(mktemp -d)
PERF_DATA="$WORKDIR/perf.data"
STACKS="$WORKDIR/stacks.folded"

cleanup() {
    if [[ "$KEEP" == "false" ]]; then
        rm -rf "$WORKDIR"
    else
        echo "[flamegraph] Intermediate files kept in: $WORKDIR" >&2
    fi
}
trap cleanup EXIT

# -----------------------------------------------------------------
# Build perf record command
# -----------------------------------------------------------------
PERF_ARGS=(-F "$FREQ" -g --call-graph dwarf -o "$PERF_DATA")

if [[ "$SYSTEM_WIDE" == "true" ]]; then
    PERF_ARGS+=(-a)
fi

# Title defaults to the command being profiled
if [[ -z "$TITLE" ]]; then
    TITLE="$*"
fi

echo "[flamegraph] Recording: $*" >&2
echo "[flamegraph] Frequency: ${FREQ}Hz | Output: $OUTPUT" >&2

# -----------------------------------------------------------------
# Record
# -----------------------------------------------------------------
perf record "${PERF_ARGS[@]}" -- "$@"
RETCODE=$?

echo "[flamegraph] Command exited with code $RETCODE" >&2

# -----------------------------------------------------------------
# Generate SVG
# -----------------------------------------------------------------
echo "[flamegraph] Generating flame graph..." >&2

COLLAPSE_ARGS=()
if [[ "$KERNEL_ONLY" == "true" ]]; then
    COLLAPSE_ARGS+=(--kernel)
fi

perf script -i "$PERF_DATA" \
    | "$STACKCOLLAPSE" "${COLLAPSE_ARGS[@]}" \
    | "$FLAMEGRAPH_PL" --title "$TITLE" --width 1600 \
    > "$OUTPUT"

echo "[flamegraph] Done: $OUTPUT" >&2
exit $RETCODE
