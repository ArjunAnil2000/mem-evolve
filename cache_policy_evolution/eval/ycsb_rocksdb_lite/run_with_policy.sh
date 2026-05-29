#!/usr/bin/env bash
# YCSB-on-RocksDB "lite" benchmark — a cache-sensitive zipfian read workload
# small enough to run inside a per-round evolution budget (~60-90s).
#
# Why this benchmark
# ------------------
# YCSB-C (100% reads, zipfian distribution) is the canonical cache-pressure
# workload: a small fraction of keys ("hot" set) get most of the requests, so
# a smart eviction policy that protects them yields large throughput wins.
# The full My-YCSB config in cache_ext/eval/ycsb runs minutes per policy
# against a multi-GB DB — too slow for an evolution loop. This script:
#   - uses a tiny ~200MB DB (initialized once, cached on disk)
#   - runs a 30s zipfian-read phase under a tight cgroup memory limit
#   - reports throughput in results.json
#
# Required env (set by evolve.py via the evaluator):
#   POLICY_BINARY  — pre-compiled evo_policy.out (omit for baseline runs)
#   JOB_DIR        — scratch dir; results.json written here
#   CACHE_EXT_CGROUP — cgroup path (created if missing)
#
# One-time setup (the script bails with a hint if these are missing):
#   - Build My-YCSB RocksDB:
#       cd /mydata/evo_cache/cache_ext/My-YCSB && cmake -B build && \
#         cmake --build build --target init_rocksdb run_rocksdb -j
#   - Or set $YCSB_BUILD_DIR to where init_rocksdb / run_rocksdb live.
#
# Tunables (env, all optional):
#   CACHE_LIMIT_MB    cgroup memory.max       (default 96)
#   DB_DIR            persistent DB location  (default /tmp/evo_rocksdb_db)
#   DB_NR_ENTRY       DB rowcount             (default 1048576 → ~210MB at 200B values)
#   BENCH_RUNTIME     bench seconds           (default 30)
#   BENCH_THREADS     YCSB threads            (default 4)
#   ZIPFIAN_CONST     skew                    (default 0.99)

set -euo pipefail

POLICY_BINARY="${POLICY_BINARY:-}"
JOB_DIR="${JOB_DIR:-/tmp/ycsb_lite_job}"
CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-96}"
DB_DIR="${DB_DIR:-/tmp/evo_rocksdb_db}"
DB_NR_ENTRY="${DB_NR_ENTRY:-1048576}"   # ~1M entries × 200B = ~210MB
DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
DB_VALUE_SIZE="${DB_VALUE_SIZE:-200}"
BENCH_RUNTIME="${BENCH_RUNTIME:-30}"
BENCH_THREADS="${BENCH_THREADS:-4}"
ZIPFIAN_CONST="${ZIPFIAN_CONST:-0.99}"

# Locate My-YCSB build dir.
YCSB_BUILD_DIR="${YCSB_BUILD_DIR:-/mydata/evo_cache/cache_ext/My-YCSB/build}"
INIT_BIN="$YCSB_BUILD_DIR/init_rocksdb"
RUN_BIN="$YCSB_BUILD_DIR/run_rocksdb"

# Cgroup.
if [[ -n "${CACHE_EXT_CGROUP:-}" ]]; then
    CGROUP_PATH="$CACHE_EXT_CGROUP"
    CGROUP_NAME="$(basename "$CGROUP_PATH")"
else
    CGROUP_NAME="cache_ext_evo_bench"
    CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
fi

LOADER_PID=""
log() { echo "[ycsb_lite] $*"; }
err() { echo "[ycsb_lite] ERROR: $*" >&2; exit 1; }

cleanup() {
    [[ -n "$LOADER_PID" ]] && {
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    }
}
trap cleanup EXIT

[[ -d "$YCSB_BUILD_DIR" ]] || err \
    "$YCSB_BUILD_DIR not found. One-time setup: cd cache_ext/My-YCSB && cmake -B build && cmake --build build --target init_rocksdb run_rocksdb -j"
[[ -x "$INIT_BIN" ]] || err "missing $INIT_BIN — build it (see header)"
[[ -x "$RUN_BIN"  ]] || err "missing $RUN_BIN — build it (see header)"

mkdir -p "$JOB_DIR"
RESULTS_FILE="$JOB_DIR/results.json"
LOADER_LOG="$JOB_DIR/loader.log"
INIT_CFG="$JOB_DIR/init.yaml"
RUN_CFG="$JOB_DIR/run.yaml"
RUN_LOG="$JOB_DIR/run.log"

# --------------------------------------------------------------------------
# DB init (cached). Only re-init if the key parameters changed.
# --------------------------------------------------------------------------
DB_STAMP="$DB_DIR/.evo_stamp"
DB_STAMP_VAL="${DB_NR_ENTRY}-${DB_KEY_SIZE}-${DB_VALUE_SIZE}"

if [[ ! -f "$DB_STAMP" || "$(cat "$DB_STAMP" 2>/dev/null)" != "$DB_STAMP_VAL" ]]; then
    log "Initializing RocksDB at $DB_DIR (entries=$DB_NR_ENTRY)..."
    rm -rf "$DB_DIR"
    mkdir -p "$DB_DIR"
    cat > "$INIT_CFG" <<EOF
database:
  key_size: $DB_KEY_SIZE
  value_size: $DB_VALUE_SIZE
  nr_entry: $DB_NR_ENTRY

workload:
  nr_warmup_op: 0
  warmup_runtime_seconds: 0
  runtime_seconds: 0
  nr_op: $DB_NR_ENTRY
  nr_thread: 4
  next_op_interval_ns: 0
  operation_proportion:
    read: 0
    update: 0
    insert: 1
    scan: 0
    read_modify_write: 0
  request_distribution: "sequential"
  zipfian_constant: 0.99
  scan_length: 100

rocksdb:
  data_dir: "$DB_DIR"
  cache_size: 16777216
  print_stats: false
EOF
    "$INIT_BIN" "$INIT_CFG" >"$JOB_DIR/init.log" 2>&1 \
        || { tail -50 "$JOB_DIR/init.log" >&2; err "init_rocksdb failed"; }
    echo "$DB_STAMP_VAL" > "$DB_STAMP"
    log "DB ready ($(du -sh "$DB_DIR" | awk '{print $1}'))"
else
    log "Reusing cached DB at $DB_DIR"
fi

# --------------------------------------------------------------------------
# Cgroup setup (matches scan_thrash; tolerates pre-existing cgroup).
# --------------------------------------------------------------------------
if [[ ! -d "$CGROUP_PATH" ]]; then
    mkdir -p "$CGROUP_PATH"
fi
parent_dir="$(dirname "$CGROUP_PATH")"
if [[ -f "$parent_dir/cgroup.subtree_control" ]]; then
    grep -q memory "$parent_dir/cgroup.subtree_control" 2>/dev/null \
        || echo "+memory" > "$parent_dir/cgroup.subtree_control" 2>/dev/null || true
    grep -q 'io' "$parent_dir/cgroup.subtree_control" 2>/dev/null \
        || echo "+io" > "$parent_dir/cgroup.subtree_control" 2>/dev/null || true
fi
limit_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
high_bytes=$(( limit_bytes * 95 / 100 ))
echo "$limit_bytes" > "$CGROUP_PATH/memory.max"
echo "$high_bytes"  > "$CGROUP_PATH/memory.high"
echo 0              > "$CGROUP_PATH/memory.swap.max" 2>/dev/null || true
swapoff -a 2>/dev/null || true
log "Cgroup: $CGROUP_NAME max=${CACHE_LIMIT_MB}MB"

# Drop caches so each round starts cold.
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1

# --------------------------------------------------------------------------
# Optional: load policy. The same script is used for baseline (no policy)
# runs by leaving POLICY_BINARY unset — handy for `--calibrate`.
# --------------------------------------------------------------------------
if [[ -n "$POLICY_BINARY" ]]; then
    [[ -x "$POLICY_BINARY" ]] || err "Not executable: $POLICY_BINARY"

    # Disable MGLRU so BPF policy is in control.
    echo 'n' | tee /sys/kernel/mm/lru_gen/enabled > /dev/null 2>&1 || true
    cgroup_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    "$POLICY_BINARY" \
        -w "$DB_DIR" \
        -s "$cgroup_bytes" \
        -c "$CGROUP_PATH" >"$LOADER_LOG" 2>&1 &
    LOADER_PID=$!
    sleep 1
    if ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" >&2 || true
        err "policy loader died immediately"
    fi
    log "Policy loader running (PID $LOADER_PID)"
else
    log "No POLICY_BINARY set — running with default kernel policy (calibration mode)"
fi

# --------------------------------------------------------------------------
# Bench config: YCSB-C (zipfian reads).
# --------------------------------------------------------------------------
cat > "$RUN_CFG" <<EOF
database:
  key_size: $DB_KEY_SIZE
  value_size: $DB_VALUE_SIZE
  nr_entry: $DB_NR_ENTRY

workload:
  nr_warmup_op: 0
  warmup_runtime_seconds: 5
  runtime_seconds: $BENCH_RUNTIME
  nr_op: 100000000
  nr_thread: $BENCH_THREADS
  next_op_interval_ns: 0
  operation_proportion:
    read: 1
    update: 0
    insert: 0
    scan: 0
    read_modify_write: 0
  request_distribution: "zipfian"
  zipfian_constant: $ZIPFIAN_CONST
  scan_length: 100

rocksdb:
  data_dir: "$DB_DIR"
  cache_size: 16777216
  print_stats: false
EOF

# --------------------------------------------------------------------------
# Run the bench inside the cgroup.
# --------------------------------------------------------------------------
log "Starting YCSB-C zipfian read phase (${BENCH_RUNTIME}s, ${BENCH_THREADS} threads)..."
(
    echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
    exec "$RUN_BIN" "$RUN_CFG"
) >"$RUN_LOG" 2>&1 \
    || { tail -80 "$RUN_LOG" >&2; err "run_rocksdb failed"; }

# Verify loader survived.
if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
    cat "$LOADER_LOG" >&2 || true
    err "policy loader died during the benchmark"
fi

# --------------------------------------------------------------------------
# Parse throughput from run.log → results.json. The My-YCSB binary prints:
#   "overall: ... READ throughput X ops/sec, ... total throughput Y ops/sec"
# --------------------------------------------------------------------------
total_tput="$(grep -oE 'total throughput [0-9]+\.[0-9]+ ops/sec' "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_tput="$( grep -oE 'READ throughput [0-9]+\.[0-9]+ ops/sec'  "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_p99="$(  grep -oE 'READ p99 latency [0-9]+\.[0-9]+ ns'      "$RUN_LOG" | tail -1 | awk '{print $4}')"
read_avg="$(  grep -oE 'READ average latency [0-9]+\.[0-9]+ ns'  "$RUN_LOG" | tail -1 | awk '{print $4}')"

# Defaults if parsing fails (the cgroup probes are still informative).
total_tput="${total_tput:-0}"
read_tput="${read_tput:-0}"
read_p99="${read_p99:-0}"
read_avg="${read_avg:-0}"

cat > "$RESULTS_FILE" <<EOF
{
  "throughput_ops_per_sec": $total_tput,
  "read_throughput_ops_per_sec": $read_tput,
  "read_avg_latency_ns": $read_avg,
  "read_p99_latency_ns": $read_p99,
  "config": {
    "db_nr_entry": $DB_NR_ENTRY,
    "value_size": $DB_VALUE_SIZE,
    "cache_limit_mb": $CACHE_LIMIT_MB,
    "runtime_seconds": $BENCH_RUNTIME,
    "threads": $BENCH_THREADS,
    "zipfian_constant": $ZIPFIAN_CONST
  }
}
EOF

log "Throughput: ${total_tput} ops/sec   p99=${read_p99} ns   → $RESULTS_FILE"
log "Done."
