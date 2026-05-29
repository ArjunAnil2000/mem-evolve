#!/usr/bin/env bash
# Quick standalone benchmark runner for scan_thrash.
#
# Sets up a memory-limited cgroup and runs the scan_thrash workload inside it.
# No framework, no evolution — just raw benchmark results.
#
# Usage:
#   sudo bash examples/scan_thrash_demo/run_benchmark.sh
#
# Options (via env vars):
#   HOT_SIZE_MB=48        Hot working set size (default: 48)
#   SCAN_SIZE_MB=1024     Cold sequential scan size (default: 1024)
#   CACHE_LIMIT_MB=64     Cgroup memory limit (default: 64)
#   ROUNDS=5              Number of hot-scan-hot cycles (default: 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

export JOB_DIR="$SCRIPT_DIR"
export HOT_SIZE_MB="${HOT_SIZE_MB:-48}"
export SCAN_SIZE_MB="${SCAN_SIZE_MB:-1024}"
export CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-64}"
export ROUNDS="${ROUNDS:-5}"

echo "=== Scan Thrash Benchmark ==="
echo "  Hot set:     ${HOT_SIZE_MB}MB"
echo "  Cold scan:   ${SCAN_SIZE_MB}MB"
echo "  Cache limit: ${CACHE_LIMIT_MB}MB"
echo "  Rounds:      ${ROUNDS}"
echo ""

# Delegate to the wrapper that sets up cgroup + runs the workload
bash "$PROJECT_DIR/eval/scan_thrash/run.sh"

echo ""
echo "=== Results ==="
cat "$SCRIPT_DIR/results.json"
echo ""
