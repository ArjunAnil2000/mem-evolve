#!/usr/bin/env bash
# Twitter trace replay over LevelDB — evolution-budget benchmark.
#
# Why LevelDB: vanilla My-YCSB already supports Twitter trace replay via
# init_leveldb / run_leveldb (request_distribution=trace). No patches
# needed, fast to build, matches the cache_ext paper's own twitter eval
# (Figure 7).
#
# Required env (set by evolve.py via the evaluator):
#   POLICY_BINARY    pre-compiled evo_policy.out (omit for baseline runs)
#   JOB_DIR          scratch dir; results.json written here
#   CACHE_EXT_CGROUP cgroup path (created if missing)
#
# One-time setup on each worker (do this from the coordinator):
#     ./start_workers.sh --install-bench h1 h2 h3
# After repo changes that affect My-YCSB:
#     ./start_workers.sh --rebuild-leveldb h1 h2 h3
#
# Twitter traces must exist at $TWITTER_TRACES_DIR with files
# cluster${N}_init.txt and cluster${N}_bench.txt for the chosen cluster.
#
# Tunables (env, all optional):
#   TWITTER_CLUSTER     cluster id (default 17)
#   CACHE_LIMIT_MB      cgroup memory.max (default 96)
#   BENCH_RUNTIME       bench seconds (default 30)
#   BENCH_THREADS       worker threads (default 4)
#   TWITTER_TRACES_DIR  trace files dir (default /mydata/evo_cache/twitter-traces)
#   DB_DIR_BASE         DB root, per-cluster suffixed (default /mydata/evo_twitter_leveldb)
#   YCSB_BUILD_DIR      My-YCSB build dir (default /mydata/evo_cache/cache_ext/My-YCSB/build)

set -euo pipefail

POLICY_BINARY="${POLICY_BINARY:-}"
JOB_DIR="${JOB_DIR:-/tmp/twitter_leveldb_job}"
TWITTER_CLUSTER="${TWITTER_CLUSTER:-17}"
CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-96}"
BENCH_RUNTIME="${BENCH_RUNTIME:-30}"
BENCH_THREADS="${BENCH_THREADS:-4}"
TWITTER_TRACES_DIR="${TWITTER_TRACES_DIR:-/mydata/evo_cache/twitter-traces}"
# If the cache_ext paper's pre-built LevelDB cluster DB is present (from
# download_dbs.sh → /mydata/evo_cache/leveldb_twitter_cluster${N}_db), use
# it directly and skip our init phase entirely. Otherwise fall back to
# running init_leveldb against cluster${N}_init.txt — slow first time,
# cached after.
PREBUILT_DB="/mydata/evo_cache/leveldb_twitter_cluster${TWITTER_CLUSTER}_db"
DB_DIR_BASE="${DB_DIR_BASE:-/mydata/evo_twitter_leveldb}"
if [[ -z "${DB_DIR:-}" ]]; then
    if [[ -d "$PREBUILT_DB" ]]; then
        DB_DIR="$PREBUILT_DB"
    else
        DB_DIR="${DB_DIR_BASE}_cluster${TWITTER_CLUSTER}"
    fi
fi
YCSB_BUILD_DIR="${YCSB_BUILD_DIR:-/mydata/evo_cache/cache_ext/My-YCSB/build}"

INIT_BIN="$YCSB_BUILD_DIR/init_leveldb"
RUN_BIN="$YCSB_BUILD_DIR/run_leveldb"
INIT_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_init.txt"
BENCH_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench.txt"

# Cluster shape from cache_ext paper / My-YCSB leveldb yamls.
case "$TWITTER_CLUSTER" in
    17) DB_KEY_SIZE=16; DB_VALUE_SIZE=408; DB_NR_ENTRY=800000 ;;
    18) DB_KEY_SIZE=16; DB_VALUE_SIZE=304; DB_NR_ENTRY=4194304 ;;
    24) DB_KEY_SIZE=16; DB_VALUE_SIZE=400; DB_NR_ENTRY=2097152 ;;
    34) DB_KEY_SIZE=16; DB_VALUE_SIZE=392; DB_NR_ENTRY=2097152 ;;
    52) DB_KEY_SIZE=16; DB_VALUE_SIZE=412; DB_NR_ENTRY=2097152 ;;
    *)  DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
        DB_VALUE_SIZE="${DB_VALUE_SIZE:-400}"
        DB_NR_ENTRY="${DB_NR_ENTRY:-1000000}" ;;
esac

if [[ -n "${CACHE_EXT_CGROUP:-}" ]]; then
    CGROUP_PATH="$CACHE_EXT_CGROUP"
    CGROUP_NAME="$(basename "$CGROUP_PATH")"
else
    CGROUP_NAME="cache_ext_evo_bench"
    CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
fi

LOADER_PID=""
log() { echo "[twitter_leveldb] $*"; }
err() { echo "[twitter_leveldb] ERROR: $*" >&2; exit 1; }

cleanup() {
    [[ -n "$LOADER_PID" ]] && {
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    }
}
trap cleanup EXIT

# Pre-flight.
[[ -d "$YCSB_BUILD_DIR" ]] || err \
    "$YCSB_BUILD_DIR not found. Run: ./start_workers.sh --install-bench HOSTS..."
[[ -x "$INIT_BIN" ]] || err "missing $INIT_BIN — run --install-bench"
[[ -x "$RUN_BIN"  ]] || err "missing $RUN_BIN — run --install-bench"
[[ -f "$INIT_TRACE"  ]] || err "missing init trace: $INIT_TRACE  (set TWITTER_TRACES_DIR)"
[[ -f "$BENCH_TRACE" ]] || err "missing bench trace: $BENCH_TRACE (set TWITTER_TRACES_DIR)"

mkdir -p "$JOB_DIR"
RESULTS_FILE="$JOB_DIR/results.json"
LOADER_LOG="$JOB_DIR/loader.log"
INIT_CFG="$JOB_DIR/init.yaml"
RUN_CFG="$JOB_DIR/run.yaml"
RUN_LOG="$JOB_DIR/run.log"

# --------------------------------------------------------------------------
# DB init (cached — re-init only if cluster id, sizes, or trace mtime changes).
# --------------------------------------------------------------------------
DB_STAMP="$DB_DIR/.evo_stamp"
init_mtime="$(stat -c %Y "$INIT_TRACE" 2>/dev/null || stat -f %m "$INIT_TRACE")"
DB_STAMP_VAL="cluster${TWITTER_CLUSTER}-${DB_KEY_SIZE}-${DB_VALUE_SIZE}-${init_mtime}"

if [[ "$DB_DIR" == "$PREBUILT_DB" ]]; then
    log "Using pre-built cluster${TWITTER_CLUSTER} LevelDB at $DB_DIR (skipping init)"
elif [[ ! -f "$DB_STAMP" || "$(cat "$DB_STAMP" 2>/dev/null)" != "$DB_STAMP_VAL" ]]; then
    log "Initializing LevelDB at $DB_DIR from $INIT_TRACE..."
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
  nr_op: 0
  nr_thread: 1
  next_op_interval_ns: 0
  operation_proportion:
    read: 0
    update: 0
    insert: 0
    scan: 0
    read_modify_write: 0
  request_distribution: trace
  zipfian_constant: 0.99
  trace_file: "$INIT_TRACE"
  trace_type: twitter_init
  scan_length: 100

leveldb:
  data_dir: "$DB_DIR"
  options_file: ""
  cache_size: 16777216
  print_stats: false
EOF
    if ! "$INIT_BIN" "$INIT_CFG" >"$JOB_DIR/init.log" 2>&1; then
        # My-YCSB twitter_init walks every trace line then fetches one
        # trailing op past EOF and aborts with "does not have next op".
        # The DB is already fully populated at that point. Tolerate the
        # crash iff the trace was fully consumed and SSTs were written.
        if grep -q "End of trace file" "$JOB_DIR/init.log" \
           && compgen -G "$DB_DIR/*.ldb" >/dev/null; then
            log "init_leveldb hit known trailing-EOF abort; DB populated OK"
        else
            tail -80 "$JOB_DIR/init.log" >&2
            err "init_leveldb failed"
        fi
    fi
    echo "$DB_STAMP_VAL" > "$DB_STAMP"
    log "DB ready ($(du -sh "$DB_DIR" | awk '{print $1}'))"
else
    log "Reusing cached DB at $DB_DIR"
fi

# Cgroup setup.
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

sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1

# Optional policy load.
if [[ -n "$POLICY_BINARY" ]]; then
    [[ -x "$POLICY_BINARY" ]] || err "Not executable: $POLICY_BINARY"
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
    log "No POLICY_BINARY set — running baseline (calibration mode)"
fi

# Bench config: trace replay (twitter_bench).
cat > "$RUN_CFG" <<EOF
database:
  key_size: $DB_KEY_SIZE
  value_size: $DB_VALUE_SIZE
  nr_entry: $DB_NR_ENTRY

workload:
  nr_warmup_op: 0
  warmup_runtime_seconds: 0
  runtime_seconds: $BENCH_RUNTIME
  nr_op: 1000000000
  nr_thread: $BENCH_THREADS
  next_op_interval_ns: 0
  operation_proportion:
    read: 0.5
    update: 0.5
    insert: 0
    scan: 0
    read_modify_write: 0
  request_distribution: trace
  zipfian_constant: 0.99
  trace_file: "$BENCH_TRACE"
  trace_type: twitter_bench
  scan_length: 100

leveldb:
  data_dir: "$DB_DIR"
  options_file: ""
  cache_size: 16777216
  print_stats: false
EOF

log "Replaying cluster${TWITTER_CLUSTER} bench trace (${BENCH_RUNTIME}s, ${BENCH_THREADS} threads)..."
(
    echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
    exec "$RUN_BIN" "$RUN_CFG"
) >"$RUN_LOG" 2>&1 \
    || { tail -80 "$RUN_LOG" >&2; err "run_leveldb failed"; }

if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
    cat "$LOADER_LOG" >&2 || true
    err "policy loader died during the benchmark"
fi

# Parse throughput / latency from run.log.
total_tput="$(grep -oE 'total throughput [0-9]+\.[0-9]+ ops/sec' "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_tput="$( grep -oE 'READ throughput [0-9]+\.[0-9]+ ops/sec'  "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_p99="$(  grep -oE 'READ p99 latency [0-9]+\.[0-9]+ ns'      "$RUN_LOG" | tail -1 | awk '{print $4}')"
read_avg="$(  grep -oE 'READ average latency [0-9]+\.[0-9]+ ns'  "$RUN_LOG" | tail -1 | awk '{print $4}')"
update_p99="$(grep -oE 'UPDATE p99 latency [0-9]+\.[0-9]+ ns'    "$RUN_LOG" | tail -1 | awk '{print $4}')"

total_tput="${total_tput:-0}"
read_tput="${read_tput:-0}"
read_p99="${read_p99:-0}"
read_avg="${read_avg:-0}"
update_p99="${update_p99:-0}"

cat > "$RESULTS_FILE" <<EOF
{
  "throughput_ops_per_sec": $total_tput,
  "read_throughput_ops_per_sec": $read_tput,
  "read_avg_latency_ns": $read_avg,
  "read_p99_latency_ns": $read_p99,
  "update_p99_latency_ns": $update_p99,
  "config": {
    "cluster": $TWITTER_CLUSTER,
    "key_size": $DB_KEY_SIZE,
    "value_size": $DB_VALUE_SIZE,
    "cache_limit_mb": $CACHE_LIMIT_MB,
    "runtime_seconds": $BENCH_RUNTIME,
    "threads": $BENCH_THREADS,
    "init_trace": "$INIT_TRACE",
    "bench_trace": "$BENCH_TRACE"
  }
}
EOF

log "Throughput: ${total_tput} ops/sec   READ p99=${read_p99} ns   → $RESULTS_FILE"
log "Done."
