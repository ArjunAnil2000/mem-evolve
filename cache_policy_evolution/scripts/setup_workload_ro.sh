#!/usr/bin/env bash
# DEPRECATED — kept as a thin compatibility wrapper.
#
# The per-workload setup logic now lives next to the benchmark script at:
#   cache_policy_evolution/eval/twitter_leveldb_ro/setup.sh
#
# Prefer driving setup via the coordinator instead of SSHing into each
# worker:
#   python3 evolve.py twitter_leveldb_ro.toml --setup-workers   # remote setup
#   python3 evolve.py twitter_leveldb_ro.toml --preflight       # remote check
#
# This wrapper just delegates to the new script for any code that still
# invokes the old path directly. Safe to remove once nothing references it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SCRIPT="$SCRIPT_DIR/../eval/twitter_leveldb_ro/setup.sh"

if [[ ! -x "$NEW_SCRIPT" ]]; then
    echo "[setup_workload_ro] ERROR: $NEW_SCRIPT not found or not executable" >&2
    exit 1
fi

echo "[setup_workload_ro] (deprecated) delegating to $NEW_SCRIPT setup"
exec bash "$NEW_SCRIPT" setup "$@"
