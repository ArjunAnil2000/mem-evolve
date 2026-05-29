#!/usr/bin/env bash
# test_scan_thrash.sh — Compare cache policies on the scan-thrash benchmark
#
# Usage:
#   sudo -A bash test_scan_thrash.sh seeds/lru.c seeds/mru.c
#
# Runs scan_thrash for each seed and prints a comparison table.
# Must be run on a machine with the cache_ext kernel + build tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_EXT_DIR="$(cd "$PROJECT_DIR/../cache_ext" && pwd)"
POLICIES_DIR="$CACHE_EXT_DIR/policies"

# Benchmark tunables (override via env)
# Tight cache (32MB) with hot=50% forces more eviction decisions.
# 1 pass keeps cold pages flowing one-way through HEAD — clean MRU self-eviction.
# Multiple passes cause re-access churning that muddies the signal.
export CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-64}"
export HOT_SIZE_MB="${HOT_SIZE_MB:-16}"
export SCAN_SIZE_MB="${SCAN_SIZE_MB:-256}"
export ROUNDS="${ROUNDS:-3}"
export SCAN_PASSES="${SCAN_PASSES:-1}"

CGROUP_NAME="cache_ext_scan_thrash"
CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
RESULTS_DIR="$SCRIPT_DIR/results/scan_thrash_comparison"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[test]${NC} $*"; }
ok()   { echo -e "${GREEN}[test] ✓${NC} $*"; }
err()  { echo -e "${RED}[test] ✗${NC} $*"; exit 1; }

if [[ $# -lt 1 ]]; then
    echo "Usage: sudo -A bash $0 seeds/lru.c seeds/mru.c [...]"
    exit 1
fi

SEEDS=("$@")

# ------------------------------------------------------------------
# Split a combined seed file into BPF + loader
# ------------------------------------------------------------------
split_seed() {
    local seed_path="$1"
    python3 -c "
import sys
sys.path.insert(0, '$PROJECT_DIR')
from targets.code_splitter import split_sections
with open('$seed_path') as f:
    code = f.read()
bpf, loader = split_sections(code)
if not bpf or not loader:
    print('ERROR: could not split sections', file=sys.stderr)
    sys.exit(1)
with open('$POLICIES_DIR/evo_policy.bpf.c', 'w') as f:
    f.write(bpf)
with open('$POLICIES_DIR/evo_policy.c', 'w') as f:
    f.write(loader)
print('Split OK')
"
}

# ------------------------------------------------------------------
# Compile the policy
# ------------------------------------------------------------------
compile_policy() {
    log "Compiling policy..."
    make -C "$POLICIES_DIR" clean 2>/dev/null || true
    make -C "$POLICIES_DIR" evo_policy.out
    if [[ ! -x "$POLICIES_DIR/evo_policy.out" ]]; then
        err "Compilation failed — evo_policy.out not found"
    fi
    ok "Compiled $POLICIES_DIR/evo_policy.out"
}

# ------------------------------------------------------------------
# Setup cgroup
# ------------------------------------------------------------------
setup_cgroup() {
    # Clean up any old cgroup
    cgdelete -g "memory:$CGROUP_NAME" 2>/dev/null || true

    cgcreate -g "memory:$CGROUP_NAME"

    local limit_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    local high_bytes=$(( limit_bytes * 95 / 100 ))

    echo "$limit_bytes" > "$CGROUP_PATH/memory.max"
    echo "$high_bytes" > "$CGROUP_PATH/memory.high"
    echo 0 > "$CGROUP_PATH/memory.swap.max" 2>/dev/null || true

    swapoff -a 2>/dev/null || true

    ok "Cgroup $CGROUP_NAME: max=${CACHE_LIMIT_MB}MB"
}

# ------------------------------------------------------------------
# Run one seed: compile, load policy, run benchmark, collect results
# ------------------------------------------------------------------
run_seed() {
    local seed_path="$1"
    local seed_name
    seed_name="$(basename "$seed_path" .c)"
    local result_dir="$RESULTS_DIR/$seed_name"
    mkdir -p "$result_dir"

    log "========================================="
    log "Testing: $seed_name ($seed_path)"
    log "========================================="

    # Step 1: Split and compile
    split_seed "$seed_path"
    compile_policy

    # Step 2: Setup cgroup
    setup_cgroup

    # Step 3: Pre-generate data files BEFORE starting the loader,
    # so the loader's inode watchlist includes the actual benchmark files.
    export SCAN_THRASH_DIR="/tmp/scan_thrash_data"
    log "Pre-generating benchmark data..."
    rm -rf "$SCAN_THRASH_DIR"
    mkdir -p "$SCAN_THRASH_DIR/hot" "$SCAN_THRASH_DIR/cold"

    local hot_file_mb=1
    local hot_files=$(( HOT_SIZE_MB / hot_file_mb ))
    [[ $hot_files -lt 1 ]] && hot_files=1
    for i in $(seq 1 "$hot_files"); do
        dd if=/dev/urandom of="$SCAN_THRASH_DIR/hot/hot_${i}.dat" \
            bs=1M count=$hot_file_mb status=none
    done

    local cold_file_mb=4
    local cold_files=$(( SCAN_SIZE_MB / cold_file_mb ))
    [[ $cold_files -lt 1 ]] && cold_files=1
    for i in $(seq 1 "$cold_files"); do
        dd if=/dev/urandom of="$SCAN_THRASH_DIR/cold/cold_${i}.dat" \
            bs=1M count=$cold_file_mb status=none
    done
    ok "Data files ready: ${HOT_SIZE_MB}MB hot, ${SCAN_SIZE_MB}MB cold"

    # Step 4: Start the policy loader in background (reads inodes from existing data files)
    local watch_dir="$SCAN_THRASH_DIR"
    local cgroup_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))

    log "Starting policy loader ($seed_name)..."
    "$POLICIES_DIR/evo_policy.out" \
        -w "$watch_dir" \
        -s "$cgroup_bytes" \
        -c "$CGROUP_PATH" &
    local LOADER_PID=$!
    sleep 1

    if ! kill -0 "$LOADER_PID" 2>/dev/null; then
        err "Policy loader died immediately — check kernel/BPF support"
    fi
    ok "Policy loader running (PID $LOADER_PID)"

    # Step 5: Run the benchmark inside the cgroup (skip data setup — already done)
    export JOB_DIR="$result_dir"
    export SKIP_SETUP=1
    log "Running scan_thrash benchmark..."
    cgexec -g "memory:$CGROUP_NAME" \
        bash "$PROJECT_DIR/eval/scan_thrash/run_evo.sh"
    unset SKIP_SETUP

    # Step 6: Stop the loader (sends SIGINT since it traps that, fallback to SIGKILL)
    kill -INT "$LOADER_PID" 2>/dev/null || true
    sleep 1
    kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
    wait "$LOADER_PID" 2>/dev/null || true
    ok "Policy loader stopped"

    # Step 7: Cleanup cgroup
    cgdelete -g "memory:$CGROUP_NAME" 2>/dev/null || true

    ok "Results saved to $result_dir/results.json"
    echo ""
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"

# Disable MGLRU — when enabled, it handles ALL eviction and BPF policies have zero effect
log "MGLRU status before: $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"
echo 'n' | sudo -A tee /sys/kernel/mm/lru_gen/enabled > /dev/null 2>&1 || true
log "MGLRU status after disable: $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"

# Drop caches before starting
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1

for seed in "${SEEDS[@]}"; do
    # Resolve relative paths from project dir (where seeds/ lives)
    if [[ ! "$seed" = /* ]]; then
        seed="$PROJECT_DIR/$seed"
    fi
    if [[ ! -f "$seed" ]]; then
        err "Seed file not found: $seed"
    fi
    run_seed "$seed"
done

# ------------------------------------------------------------------
# Print comparison
# ------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================="
echo "  SCAN-THRASH RESULTS COMPARISON"
echo -e "=========================================${NC}"
echo ""
printf "%-15s  %-12s  %-12s  %-10s\n" "POLICY" "HOT (ms)" "AFTER SCAN" "SCORE"
printf "%-15s  %-12s  %-12s  %-10s\n" "------" "--------" "----------" "-----"

for seed in "${SEEDS[@]}"; do
    seed_name="$(basename "$seed" .c)"
    result_file="$RESULTS_DIR/$seed_name/results.json"
    if [[ -f "$result_file" ]]; then
        hot=$(python3 -c "import json; d=json.load(open('$result_file')); print(d['avg_hot_read_ms'])")
        after=$(python3 -c "import json; d=json.load(open('$result_file')); print(d['avg_hot_after_scan_ms'])")
        score=$(python3 -c "import json; d=json.load(open('$result_file')); print(d['combined_score'])")
        printf "%-15s  %-12s  %-12s  %-10s\n" "$seed_name" "${hot}ms" "${after}ms" "$score"
    else
        printf "%-15s  %-12s\n" "$seed_name" "(no results)"
    fi
done

echo ""
echo "Score = hot_read_time / hot_after_scan_time"
echo "  ~1.0 = hot data stayed cached (good)"
echo "  <0.3 = hot data evicted by scan (bad)"

log "Done. MGLRU status: $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null)"
