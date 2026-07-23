#!/usr/bin/env bash
# GET-SCAN over LevelDB — evolution-budget benchmark (cache_ext paper
# Figure 8, scaled down for fast per-round iteration).
#
# Zipfian GET/SCAN mix against LevelDB via My-YCSB's mixed_get_scan
# workload: mostly point reads over a hot-skewed keyspace, with a minority
# of large sequential range scans that risk evicting the hot GET working
# set. Needs the leveldb-scan My-YCSB branch (see setup.sh) — vanilla
# My-YCSB doesn't carry the mixed_get_scan op mix or the scan_pids
# BPF-map hook.
#
# Required env (set by evolve.py via the evaluator):
#   POLICY_BINARY    pre-compiled evo_policy.out (omit for baseline runs)
#   JOB_DIR          scratch dir; results.json written here
#   CACHE_EXT_CGROUP cgroup path (created if missing)
#
# One-time setup (per worker):
#     eval/get_scan/setup.sh setup
#
# Tunables (env, all optional):
#   CACHE_LIMIT_MB     cgroup memory.max (default 64)
#   BENCH_RUNTIME      bench seconds (default 30)
#   BENCH_THREADS      worker threads (default 4). Exactly ONE of these
#                      becomes the dedicated scan thread — hardcoded
#                      scan_worker_count=1 in leveldb-scan's
#                      core/worker.cpp, not configurable via yaml.
#   SCAN_PROPORTION    fraction of ops that are SCAN on the scan thread
#                      (default 0.05, matches the paper's mixed_get_scan.yaml)
#   SCAN_LENGTH        keys per scan (default 500 — paper uses 10000 against
#                      a 536M-entry DB; scaled down to stay well inside our
#                      much smaller DB_NR_ENTRY)
#   DB_NR_ENTRY        keyspace size (default 500000)
#   DB_KEY_SIZE        (default 16, matches paper)
#   DB_VALUE_SIZE      (default 200, matches paper)
#   ZIPFIAN_CONSTANT   (default 0.99, matches paper)
#   DB_DIR             DB location (default /mydata/evo_get_scan_db)
#   YCSB_SCAN_DIR       My-YCSB(leveldb-scan) build dir
#                       (default /mydata/evo_cache/cache_ext/My-YCSB-scan)
#   ENABLE_BPF_SCAN_MAP ground-truth scan-thread classification via the
#                       pinned scan_pids BPF map (default "1" — ON).
#                       See setup.sh's header comment for the underlying
#                       My-YCSB mechanism. THIS SCRIPT owns the map's
#                       lifecycle, not the attached policy: it creates and
#                       pins an empty scan_pids map itself (via bpftool,
#                       below) before the policy loader ever starts, and
#                       removes the pin on exit. This is deliberate —
#                       fairness across experiments requires every policy
#                       to see the exact same benchmark environment
#                       regardless of whether it knows what scan_pids is,
#                       so the map's existence must never depend on which
#                       policy happens to be attached. My-YCSB's writes
#                       into it always succeed once this script has run;
#                       most seeds simply never look at it. A seed that
#                       wants the ground-truth signal attaches to this
#                       SAME map via bpf_obj_get() + bpf_map__reuse_fd()
#                       in its own loader (see vulcan_scan_class.c) rather
#                       than creating/pinning its own — do not have a seed
#                       pin its own map at this path, it would race this
#                       script's create/cleanup.

set -euo pipefail

POLICY_BINARY="${POLICY_BINARY:-}"
JOB_DIR="${JOB_DIR:-/tmp/get_scan_job}"
CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-64}"
BENCH_RUNTIME="${BENCH_RUNTIME:-30}"
BENCH_THREADS="${BENCH_THREADS:-4}"
SCAN_PROPORTION="${SCAN_PROPORTION:-0.05}"
SCAN_LENGTH="${SCAN_LENGTH:-500}"
DB_NR_ENTRY="${DB_NR_ENTRY:-500000}"
DB_KEY_SIZE="${DB_KEY_SIZE:-16}"
DB_VALUE_SIZE="${DB_VALUE_SIZE:-200}"
ZIPFIAN_CONSTANT="${ZIPFIAN_CONSTANT:-0.99}"
DB_DIR="${DB_DIR:-/mydata/evo_get_scan_db}"
YCSB_SCAN_DIR="${YCSB_SCAN_DIR:-/mydata/evo_cache/cache_ext/My-YCSB-scan}"
ENABLE_BPF_SCAN_MAP="${ENABLE_BPF_SCAN_MAP:-1}"
SCAN_PIDS_PIN_PATH="/sys/fs/bpf/cache_ext/scan_pids"

INIT_BIN="$YCSB_SCAN_DIR/build/init_leveldb"
RUN_BIN="$YCSB_SCAN_DIR/build/run_leveldb"

if [[ -n "${CACHE_EXT_CGROUP:-}" ]]; then
    CGROUP_PATH="$CACHE_EXT_CGROUP"
    CGROUP_NAME="$(basename "$CGROUP_PATH")"
else
    CGROUP_NAME="cache_ext_evo_bench"
    CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
fi

LOADER_PID=""
log() { echo "[get_scan] $*"; }
err() { echo "[get_scan] ERROR: $*" >&2; exit 1; }

cleanup() {
    [[ -n "$LOADER_PID" ]] && {
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    }
    # This script owns the scan_pids map's lifecycle (see ENABLE_BPF_SCAN_MAP
    # doc above) — always clear its own pin on exit, regardless of how the
    # round ended, so a crashed round never shadows the next one's map.
    rm -f "$SCAN_PIDS_PIN_PATH" 2>/dev/null || true
}
trap cleanup EXIT

# Pre-flight.
[[ -x "$INIT_BIN" ]] || err "missing $INIT_BIN — run: eval/get_scan/setup.sh setup"
[[ -x "$RUN_BIN"  ]] || err "missing $RUN_BIN — run: eval/get_scan/setup.sh setup"
if [[ "$ENABLE_BPF_SCAN_MAP" == "1" ]]; then
    command -v bpftool >/dev/null || err "bpftool not found (needed for ENABLE_BPF_SCAN_MAP=1)"
fi

mkdir -p "$JOB_DIR"
RESULTS_FILE="$JOB_DIR/results.json"
LOADER_LOG="$JOB_DIR/loader.log"
INIT_CFG="$JOB_DIR/init.yaml"
RUN_CFG="$JOB_DIR/run.yaml"
RUN_LOG="$JOB_DIR/run.log"

# --------------------------------------------------------------------------
# scan_pids map: created and pinned by THIS SCRIPT (not by whichever policy
# is attached — see ENABLE_BPF_SCAN_MAP doc above), so its existence never
# depends on the policy under test. Key/value sizes match
# cache_ext/policies/cache_ext_get_scan.bpf.c's own scan_pids declaration
# (key=int TID, value=bool) — My-YCSB's fill_bpf_map_with_scan_pid() writes
# a 4-byte int but bpf_map_update_elem() only copies the map's actual
# value_size (1 byte) from it, so this matches regardless of the C++ side's
# looser local variable type.
# --------------------------------------------------------------------------
rm -f "$SCAN_PIDS_PIN_PATH" 2>/dev/null || true
if [[ "$ENABLE_BPF_SCAN_MAP" == "1" ]]; then
    mkdir -p "$(dirname "$SCAN_PIDS_PIN_PATH")"
    bpftool map create "$SCAN_PIDS_PIN_PATH" \
        type hash key 4 value 1 entries 1024 name scan_pids \
        || err "failed to create+pin scan_pids map at $SCAN_PIDS_PIN_PATH"
    log "scan_pids map pinned at $SCAN_PIDS_PIN_PATH"
fi

# --------------------------------------------------------------------------
# DB init (cached — re-init only if size/shape changes). init_leveldb
# ignores workload.operation_proportion entirely for the zipfian case (see
# leveldb/init_leveldb.cpp) — only database.{nr_entry,key_size,value_size}
# and leveldb.data_dir matter, so the workload block below is a harmless
# placeholder, not real config.
# --------------------------------------------------------------------------
DB_STAMP="$DB_DIR/.evo_stamp"
DB_STAMP_VAL="${DB_NR_ENTRY}-${DB_KEY_SIZE}-${DB_VALUE_SIZE}"

if [[ ! -f "$DB_STAMP" || "$(cat "$DB_STAMP" 2>/dev/null)" != "$DB_STAMP_VAL" ]]; then
    log "Initializing LevelDB at $DB_DIR ($DB_NR_ENTRY entries)..."
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
  request_distribution: "zipfian"
  zipfian_constant: $ZIPFIAN_CONSTANT
  trace_file_list: []
  scan_length: $SCAN_LENGTH

leveldb:
  data_dir: "$DB_DIR"
  options_file: ""
  cache_size: 16777216
  print_stats: false
EOF
    if ! "$INIT_BIN" "$INIT_CFG" >"$JOB_DIR/init.log" 2>&1; then
        tail -80 "$JOB_DIR/init.log" >&2
        err "init_leveldb failed"
    fi
    echo "$DB_STAMP_VAL" > "$DB_STAMP"
    log "DB ready ($(du -sh "$DB_DIR" | awk '{print $1}'))"
else
    log "Reusing cached DB at $DB_DIR"
fi

# Cgroup setup (cgroup-v2 via sysfs, same pattern as scan_thrash / twitter_leveldb).
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

# Optional policy load. The scan_pids map (above) already exists
# independent of this, so no ordering dependency between the two anymore.
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

BENCH_EXTRA_ENVS=()
[[ "$ENABLE_BPF_SCAN_MAP" == "1" ]] && BENCH_EXTRA_ENVS+=("ENABLE_BPF_SCAN_MAP=1")

# Bench config: zipfian GET/SCAN mix (mixed_get_scan-equivalent).
read_prop="$(awk "BEGIN { printf \"%.4f\", 1 - $SCAN_PROPORTION }")"
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
    read: $read_prop
    update: 0
    insert: 0
    scan: $SCAN_PROPORTION
    read_modify_write: 0
  request_distribution: "zipfian"
  zipfian_constant: $ZIPFIAN_CONSTANT
  trace_file_list: []
  scan_length: $SCAN_LENGTH

leveldb:
  data_dir: "$DB_DIR"
  options_file: ""
  cache_size: 16777216
  print_stats: false
EOF

log "Running GET-SCAN (${BENCH_RUNTIME}s, ${BENCH_THREADS} threads, scan=${SCAN_PROPORTION}, ENABLE_BPF_SCAN_MAP=${ENABLE_BPF_SCAN_MAP})..."
(
    echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
    for kv in "${BENCH_EXTRA_ENVS[@]+"${BENCH_EXTRA_ENVS[@]}"}"; do
        export "${kv?}"
    done
    exec "$RUN_BIN" "$RUN_CFG"
) >"$RUN_LOG" 2>&1 \
    || { tail -80 "$RUN_LOG" >&2; err "run_leveldb failed"; }

if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
    cat "$LOADER_LOG" >&2 || true
    err "policy loader died during the benchmark"
fi

# Parse throughput / latency from run.log.
total_tput="$(grep -oE 'total throughput [0-9]+\.[0-9]+ ops/sec'  "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_tput="$( grep -oE 'READ throughput [0-9]+\.[0-9]+ ops/sec'   "$RUN_LOG" | tail -1 | awk '{print $3}')"
scan_tput="$( grep -oE 'SCAN throughput [0-9]+\.[0-9]+ ops/sec'   "$RUN_LOG" | tail -1 | awk '{print $3}')"
read_p99="$(  grep -oE 'READ p99 latency [0-9]+\.[0-9]+ ns'       "$RUN_LOG" | tail -1 | awk '{print $4}')"
read_avg="$(  grep -oE 'READ average latency [0-9]+\.[0-9]+ ns'   "$RUN_LOG" | tail -1 | awk '{print $4}')"
scan_p99="$(  grep -oE 'SCAN p99 latency [0-9]+\.[0-9]+ ns'       "$RUN_LOG" | tail -1 | awk '{print $4}')"

total_tput="${total_tput:-0}"
read_tput="${read_tput:-0}"
scan_tput="${scan_tput:-0}"
read_p99="${read_p99:-0}"
read_avg="${read_avg:-0}"
scan_p99="${scan_p99:-0}"

cat > "$RESULTS_FILE" <<EOF
{
  "throughput_ops_per_sec": $total_tput,
  "read_throughput_ops_per_sec": $read_tput,
  "scan_throughput_ops_per_sec": $scan_tput,
  "read_avg_latency_ns": $read_avg,
  "read_p99_latency_ns": $read_p99,
  "scan_p99_latency_ns": $scan_p99,
  "config": {
    "db_nr_entry": $DB_NR_ENTRY,
    "key_size": $DB_KEY_SIZE,
    "value_size": $DB_VALUE_SIZE,
    "cache_limit_mb": $CACHE_LIMIT_MB,
    "runtime_seconds": $BENCH_RUNTIME,
    "threads": $BENCH_THREADS,
    "scan_proportion": $SCAN_PROPORTION,
    "scan_length": $SCAN_LENGTH,
    "enable_bpf_scan_map": "$ENABLE_BPF_SCAN_MAP"
  }
}
EOF

log "Throughput: ${total_tput} ops/sec   READ p99=${read_p99} ns   SCAN p99=${scan_p99} ns   → $RESULTS_FILE"
log "Done."
