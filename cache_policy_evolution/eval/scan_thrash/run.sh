#!/usr/bin/env bash
# Wrapper: sets up the cgroup and runs run_evo.sh inside it.
#
# Usage:
#   sudo bash eval/scan_thrash/run.sh
#   CACHE_LIMIT_MB=512 sudo -E bash eval/scan_thrash/run.sh

set -euo pipefail

CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-64}"
CGROUP_NAME="cache_ext_scan_thrash"
CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[scan_thrash:setup] $*"; }

# Clean up old cgroup
sudo cgdelete -g "memory:$CGROUP_NAME" 2>/dev/null || true

# Create fresh cgroup
sudo cgcreate -g "memory:$CGROUP_NAME"

limit_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
high_bytes=$(( limit_bytes * 95 / 100 ))

sudo sh -c "echo $limit_bytes > $CGROUP_PATH/memory.max"
sudo sh -c "echo $high_bytes > $CGROUP_PATH/memory.high"
sudo sh -c "echo 0 > $CGROUP_PATH/memory.swap.max" 2>/dev/null || true

# Disable swap
sudo swapoff -a 2>/dev/null || true

log "cgroup $CGROUP_NAME: max=${CACHE_LIMIT_MB}MB high=$((high_bytes/1024/1024))MB swap=0"

# Run the benchmark inside the cgroup
sudo cgexec -g "memory:$CGROUP_NAME" \
    sudo -E -u "${SUDO_USER:-$(whoami)}" \
    bash "$SCRIPT_DIR/run_evo.sh"

# Cleanup
sudo cgdelete -g "memory:$CGROUP_NAME" 2>/dev/null || true
log "Done. Cgroup cleaned up."
