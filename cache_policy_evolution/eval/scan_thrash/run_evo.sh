#!/usr/bin/env bash
# scan_thrash — Worst-case workload for Linux page cache (LRU killer)
#
# Creates a mix of:
#   1. A small "hot" working set that should stay cached
#   2. Periodic large sequential scans that blow the cache (scan pollution)
#   3. Re-reads of the hot set (measuring cache misses)
#
# LRU will thrash because the sequential scan evicts the hot data every time.
# A smart policy (S3-FIFO, ARC, 2Q, etc.) should protect the hot set.
#
# IMPORTANT: This script must be run inside a memory-limited cgroup.
#   sudo cgexec -g memory:scan_thrash_cg bash eval/scan_thrash/run_evo.sh
#
# Or use the wrapper: bash eval/scan_thrash/run.sh
#
# Outputs results.json with timing info to $JOB_DIR (or current dir).

set -euo pipefail

# -----------------------------------------------------------------
# Config (tunable via env vars)
# -----------------------------------------------------------------
DATA_DIR="${SCAN_THRASH_DIR:-/tmp/scan_thrash_data}"
HOT_SIZE_MB="${HOT_SIZE_MB:-48}"           # Hot working set (~75% of cache)
SCAN_SIZE_MB="${SCAN_SIZE_MB:-1024}"       # Sequential scan (16x cache = guaranteed full eviction)
ROUNDS="${ROUNDS:-5}"                     # Number of hot-scan-hot cycles
SCAN_PASSES="${SCAN_PASSES:-1}"           # Cold scans per round (more = more eviction pressure)
RESULTS_DIR="${JOB_DIR:-.}"

log() { echo "[scan_thrash] $*"; }

# -----------------------------------------------------------------
# Setup: generate data files
# -----------------------------------------------------------------
setup_data() {
    log "Setting up data files..."
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR/hot" "$DATA_DIR/cold"

    # Hot set: small files (simulates frequently-accessed data)
    # Use 256KB files so even a 4MB hot set has enough files to exercise eviction
    local hot_file_kb=256
    local hot_files=$(( HOT_SIZE_MB * 1024 / hot_file_kb ))
    [[ $hot_files -lt 1 ]] && hot_files=1
    for i in $(seq 1 "$hot_files"); do
        local f="$DATA_DIR/hot/hot_${i}.dat"
        if [[ ! -f "$f" ]]; then
            dd if=/dev/urandom of="$f" bs=1K count=$hot_file_kb status=none
        fi
    done

    # Cold set: larger files (simulates sequential scans / bulk reads)
    local cold_file_mb=4
    local cold_files=$(( SCAN_SIZE_MB / cold_file_mb ))
    [[ $cold_files -lt 1 ]] && cold_files=1
    for i in $(seq 1 "$cold_files"); do
        local f="$DATA_DIR/cold/cold_${i}.dat"
        if [[ ! -f "$f" ]]; then
            dd if=/dev/urandom of="$f" bs=1M count=$cold_file_mb status=none
        fi
    done

    log "Data ready: ${HOT_SIZE_MB}MB hot, ${SCAN_SIZE_MB}MB cold"
}

# -----------------------------------------------------------------
# Read all files in a directory sequentially
# This runs in the CURRENT process, so pages are charged to our cgroup.
# -----------------------------------------------------------------
read_all_files() {
    local dir="$1"
    local bytes=0
    while IFS= read -r -d '' f; do
        cat "$f" > /dev/null
        bytes=$((bytes + $(stat --format=%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)))
    done < <(find "$dir" -type f -print0 | sort -z)
    log "    read $((bytes / 1024 / 1024))MB from $dir" >&2
}

# -----------------------------------------------------------------
# Time a function call in milliseconds
# -----------------------------------------------------------------
time_ms() {
    local start end
    start=$(date +%s%N)
    "$@" >&2
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

# -----------------------------------------------------------------
# Show cgroup memory stats
# -----------------------------------------------------------------
show_mem() {
    local label="$1"
    # Try cgroups v2 path (we might be in a sub-cgroup)
    local cg_dir
    cg_dir=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    local mem_file="/sys/fs/cgroup${cg_dir}/memory.current"
    if [[ -f "$mem_file" ]]; then
        local mem_bytes
        mem_bytes=$(cat "$mem_file")
        log "  cgroup memory $label: $((mem_bytes / 1024 / 1024))MB"
    fi
}

# -----------------------------------------------------------------
# Run the benchmark (everything in-process, inside whatever cgroup we're in)
# -----------------------------------------------------------------
run_benchmark() {
    local hot_times=()
    local scan_times=()
    local hot_after_scan_times=()

    log "Starting benchmark: $ROUNDS rounds"
    log "  hot=${HOT_SIZE_MB}MB  scan=${SCAN_SIZE_MB}MB"

    # Verify we're in a memory-limited cgroup
    local cg_dir
    cg_dir=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    local max_file="/sys/fs/cgroup${cg_dir}/memory.max"
    if [[ -f "$max_file" ]]; then
        local mem_max
        mem_max=$(cat "$max_file")
        if [[ "$mem_max" == "max" ]]; then
            log "WARNING: no memory limit on this cgroup — results will be meaningless!"
            log "Run inside a cgroup: sudo cgexec -g memory:scan_thrash_cg bash $0"
        else
            log "  cgroup memory.max = $((mem_max / 1024 / 1024))MB"
        fi
    fi

    for round in $(seq 1 "$ROUNDS"); do
        log "--- Round $round/$ROUNDS ---"

        # 0. Drop all caches for a clean start each round
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
        sleep 0.5
        show_mem "after drop"

        # 1. Prime: read hot set into cache (always from disk — establishes baseline)
        local t
        t=$(time_ms read_all_files "$DATA_DIR/hot")
        log "  Hot prime (from disk): ${t}ms"

        # 2. Verify hot set is cached (should be near-instant)
        t=$(time_ms read_all_files "$DATA_DIR/hot")
        hot_times+=("$t")
        log "  Hot cached read: ${t}ms"

        show_mem "after hot"

        # 3. Sequential scan of cold data (pollutes cache under LRU)
        #    Multiple passes amplify policy differences: MRU self-evicts cold,
        #    LRU keeps evicting hot each pass.
        local total_scan_ms=0
        for pass in $(seq 1 "$SCAN_PASSES"); do
            t=$(time_ms read_all_files "$DATA_DIR/cold")
            total_scan_ms=$((total_scan_ms + t))
            if [[ "$SCAN_PASSES" -gt 1 ]]; then
                log "  Cold scan pass $pass/$SCAN_PASSES: ${t}ms"
            fi
        done
        scan_times+=("$total_scan_ms")
        log "  Cold scan total ($SCAN_PASSES passes): ${total_scan_ms}ms"

        show_mem "after scan"

        # 4. Re-read hot set (this is the key metric — was it evicted?)
        t=$(time_ms read_all_files "$DATA_DIR/hot")
        hot_after_scan_times+=("$t")
        log "  Hot re-read after scan: ${t}ms"

        show_mem "after re-read"
    done

    # -----------------------------------------------------------------
    # Compute results
    # -----------------------------------------------------------------
    local total_hot_after=0
    local total_hot=0
    for i in "${!hot_after_scan_times[@]}"; do
        total_hot_after=$((total_hot_after + hot_after_scan_times[i]))
        total_hot=$((total_hot + hot_times[i]))
    done

    local avg_hot_after=$((total_hot_after / ROUNDS))
    local avg_hot=$((total_hot / ROUNDS))

    # Score: ratio of initial hot read time to post-scan hot read time.
    # Closer to 1.0 = hot set stayed cached (good policy).
    # Much < 1.0 = hot set was evicted by scan (bad policy / LRU).
    local score
    if [[ $avg_hot_after -gt 0 && $avg_hot -gt 0 ]]; then
        score=$(awk "BEGIN {printf \"%.4f\", $avg_hot / $avg_hot_after}")
    else
        score="0.0"
    fi

    log "Results: avg_hot=${avg_hot}ms, avg_hot_after_scan=${avg_hot_after}ms, score=$score"

    # Write results.json
    cat > "$RESULTS_DIR/results.json" <<-ENDJSON
{
    "combined_score": $score,
    "avg_hot_read_ms": $avg_hot,
    "avg_hot_after_scan_ms": $avg_hot_after,
    "rounds": $ROUNDS,
    "hot_size_mb": $HOT_SIZE_MB,
    "scan_size_mb": $SCAN_SIZE_MB,
    "hot_times_ms": [$(IFS=,; echo "${hot_times[*]}")],
    "scan_times_ms": [$(IFS=,; echo "${scan_times[*]}")],
    "hot_after_scan_times_ms": [$(IFS=,; echo "${hot_after_scan_times[*]}")],
    "time": $avg_hot_after
}
ENDJSON

    log "Results written to $RESULTS_DIR/results.json"
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------
if [[ "${SKIP_SETUP:-0}" != "1" ]]; then
    setup_data
fi

# Drop all caches so we start clean
sudo sync
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sleep 1

run_benchmark

log "Done."
