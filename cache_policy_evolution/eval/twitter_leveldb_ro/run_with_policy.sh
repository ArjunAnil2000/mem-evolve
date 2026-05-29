#!/usr/bin/env bash
# Twitter trace replay over LevelDB — READ-ONLY variant.
#
# Differences vs eval/twitter_leveldb/run_with_policy.sh:
#   * 100% reads — uses a get-only filtered trace, NOT op_proportion in the
#     YAML (twitter_bench reads op type from the trace file directly and
#     ignores yaml's read/update fractions).
#   * LevelDB block cache effectively disabled (cache_size=0 → 1-byte LRU)
#     so the page cache sees the real Zipfian access stream.
#   * BENCH_RUNTIME default 60s             — longer steady-state window
#   * Warmup phase (10s) before measurement — populated under the policy,
#                                             then measured separately.
#   * drop_caches still happens             — every run starts identical;
#                                             warmup repopulates fairly.
#
# PHASE MODEL
# -----------
# Driven by EVO_PHASE (set by the evaluator):
#   EVO_PHASE=warmup   — setup cgroup, drop_caches+swapoff, init LevelDB
#                        if needed, start the policy loader, replay
#                        $BENCH_WARMUP seconds of the trace under the
#                        policy. Loader stays running on exit (PID at
#                        $JOB_DIR/loader.pid; evaluator owns cleanup).
#   EVO_PHASE=measure  — replay $BENCH_RUNTIME seconds of the trace and
#                        parse results.json. Probes wrap THIS phase only
#                        (no init/drop_caches/swapoff noise).
#   EVO_PHASE=all      — legacy single-phase mode (default if unset).
#                        Original behavior: warmup + measure inside one
#                        run_leveldb invocation, loader killed on exit.
#
# REQUIRED ONE-SHOT SETUP (per worker, before this script can do its job):
#   bash cache_policy_evolution/scripts/setup_workload_ro.sh
# That script (a) patches My-YCSB to honor cache_size from YAML and rebuilds
# init_leveldb / run_leveldb, and (b) filters cluster${N}_bench.txt down to
# get-only lines (cached). Without it, this benchmark will (a) silently fall
# back to LevelDB's 8 MiB default block cache and (b) replay the original
# mixed read/write trace — both of which defeat the point of this variant.
#
# Required env (set by evolve.py via the evaluator):
#   POLICY_BINARY    pre-compiled evo_policy.out (omit for baseline runs)
#   JOB_DIR          scratch dir; results.json written here
#   CACHE_EXT_CGROUP cgroup path (created if missing)
#
# Tunables (env, all optional):
#   TWITTER_CLUSTER     cluster id (default 17)
#   CACHE_LIMIT_MB      cgroup memory.max (default 96)
#   BENCH_RUNTIME       bench seconds (default 60)
#   BENCH_WARMUP        warmup seconds before measurement (default 10, set 0 to skip)
#   BENCH_THREADS       worker threads (default 4)
#   TWITTER_TRACES_DIR  trace files dir (default /mydata/evo_cache/twitter-traces)
#   DB_DIR_BASE         DB root, per-cluster suffixed (default /mydata/evo_twitter_leveldb)
#   YCSB_BUILD_DIR      My-YCSB build dir (default /mydata/evo_cache/cache_ext/My-YCSB/build)

set -euo pipefail

POLICY_BINARY="${POLICY_BINARY:-}"
JOB_DIR="${JOB_DIR:-/tmp/twitter_leveldb_ro_job}"
TWITTER_CLUSTER="${TWITTER_CLUSTER:-17}"
CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-96}"
BENCH_RUNTIME="${BENCH_RUNTIME:-60}"
BENCH_WARMUP="${BENCH_WARMUP:-10}"
BENCH_THREADS="${BENCH_THREADS:-4}"
EVO_PHASE="${EVO_PHASE:-all}"
TWITTER_TRACES_DIR="${TWITTER_TRACES_DIR:-/mydata/evo_cache/twitter-traces}"
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
# Read-only trace produced by setup_workload_ro.sh (get-only lines).
# Falls back to the original bench trace if the filtered one is missing —
# but warns loudly because that defeats the read-only intent.
RO_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench_readonly.txt"
ORIG_BENCH_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench.txt"
if [[ -f "$RO_TRACE" ]]; then
    BENCH_TRACE="$RO_TRACE"
else
    BENCH_TRACE="$ORIG_BENCH_TRACE"
fi

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
log() { echo "[twitter_leveldb_ro:$EVO_PHASE] $*"; }
err() { echo "[twitter_leveldb_ro:$EVO_PHASE] ERROR: $*" >&2; exit 1; }

cleanup() {
    # In split mode the loader outlives this shell so the next phase can use
    # it; the evaluator tears it down via $JOB_DIR/loader.pid. In all-mode
    # we kill it ourselves like the original script.
    if [[ "$EVO_PHASE" == "all" && -n "$LOADER_PID" ]]; then
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$JOB_DIR"
RESULTS_FILE="$JOB_DIR/results.json"
LOADER_LOG="$JOB_DIR/loader.log"
LOADER_PID_FILE="$JOB_DIR/loader.pid"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a run_leveldb config that will replay $BENCH_TRACE for $1 seconds.
# Uses warmup_runtime_seconds=0 + runtime_seconds=$1 so the binary always
# enters its measurement phase (which is what actually drives I/O); the
# distinction between "warmup phase" and "measure phase" lives in EVO_PHASE,
# not in YCSB's internal warmup logic.
write_run_cfg() {
    local out_path="$1"
    local seconds="$2"
    cat > "$out_path" <<EOF
database:
  key_size: $DB_KEY_SIZE
  value_size: $DB_VALUE_SIZE
  nr_entry: $DB_NR_ENTRY

workload:
  nr_warmup_op: 0
  warmup_runtime_seconds: 0
  runtime_seconds: $seconds
  nr_op: 1000000000
  nr_thread: $BENCH_THREADS
  next_op_interval_ns: 0
  operation_proportion:
    read: 1.0
    update: 0
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
  cache_size: 0
  print_stats: false
EOF
}

# Parse the bench-phase results out of $1 (run_leveldb log) into $RESULTS_FILE.
# Encapsulates the "Trace overall" / fallback-realtime parsing so both the
# all-mode and measure-mode paths use identical logic.
parse_results() {
    local run_log="$1"
    python3 - "$run_log" "$JOB_DIR" "$TWITTER_CLUSTER" "$DB_KEY_SIZE" \
             "$DB_VALUE_SIZE" "$CACHE_LIMIT_MB" "$BENCH_WARMUP" "$BENCH_RUNTIME" \
             "$BENCH_THREADS" "$INIT_TRACE" "$BENCH_TRACE" <<'PYEOF'
import json, re, sys, os

(run_log, job_dir, cluster, ksz, vsz, cache_mb, warmup_s, run_s, threads,
 init_trace, bench_trace) = sys.argv[1:]
results_file = os.path.join(job_dir, "results.json")

def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return 0.0

NUM = r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"
OP_NAMES = ("UPDATE", "INSERT", "READ", "SCAN", "READ_MODIFY_WRITE")
TPUT_RE = {op: re.compile(rf"{op} throughput ({NUM})") for op in OP_NAMES}
TOTAL_TPUT_RE = re.compile(rf"total throughput ({NUM})")
LAT_AVG_RE = {op: re.compile(rf"{op} average latency ({NUM})") for op in OP_NAMES}
LAT_P99_RE = {op: re.compile(rf"{op} p99 latency ({NUM})") for op in OP_NAMES}

with open(run_log, "r", errors="replace") as f:
    log_lines = f.read().splitlines()

# Bench-phase overall: "Trace overall:" (warmup is "Trace (Warm-Up) overall:")
bench_tput_line = ""
bench_lat_line = ""
for line in log_lines:
    if line.startswith("Trace overall:"):
        if "throughput" in line and not bench_tput_line:
            bench_tput_line = line
        elif "latency" in line and not bench_lat_line:
            bench_lat_line = line

# Realtime epoch lines from bench phase only (not "Trace (Warm-Up) (epoch ...)")
EPOCH_RE = re.compile(r"^Trace \(epoch (\d+),")
bench_epochs = []
for line in log_lines:
    m = EPOCH_RE.match(line)
    if m:
        bench_epochs.append((int(m.group(1)), line))

per_op_tput = {op: num(TPUT_RE[op].search(bench_tput_line).group(1))
                   if bench_tput_line and TPUT_RE[op].search(bench_tput_line) else 0.0
               for op in OP_NAMES}
total_tput_overall = (num(TOTAL_TPUT_RE.search(bench_tput_line).group(1))
                      if bench_tput_line and TOTAL_TPUT_RE.search(bench_tput_line) else 0.0)
per_op_lat_avg = {op: num(LAT_AVG_RE[op].search(bench_lat_line).group(1))
                       if bench_lat_line and LAT_AVG_RE[op].search(bench_lat_line) else 0.0
                  for op in OP_NAMES}
per_op_lat_p99 = {op: num(LAT_P99_RE[op].search(bench_lat_line).group(1))
                       if bench_lat_line and LAT_P99_RE[op].search(bench_lat_line) else 0.0
                  for op in OP_NAMES}

fallback_window = 10
fallback_total = 0.0
fallback_read = 0.0
fallback_n = 0
if bench_epochs:
    tail = bench_epochs[-fallback_window:]
    totals, reads = [], []
    for _, line in tail:
        m = TOTAL_TPUT_RE.search(line)
        if m: totals.append(num(m.group(1)))
        m = TPUT_RE["READ"].search(line)
        if m: reads.append(num(m.group(1)))
    if totals: fallback_total = sum(totals) / len(totals)
    if reads:  fallback_read  = sum(reads) / len(reads)
    fallback_n = len(tail)

if total_tput_overall > 0:
    parse_status = "ok"
    throughput = total_tput_overall
    read_tput = per_op_tput["READ"]
    throughput_source = "overall_block"
elif fallback_total > 0:
    parse_status = "fallback_realtime"
    throughput = fallback_total
    read_tput = fallback_read
    throughput_source = f"avg_last_{fallback_n}_epochs"
else:
    parse_status = "failed"
    throughput = 0.0
    read_tput = 0.0
    throughput_source = "none"

latency_capture_broken = (
    bench_lat_line != "" and
    all(per_op_lat_avg[op] == 0.0 and per_op_lat_p99[op] == 0.0 for op in OP_NAMES)
)

with open(os.path.join(job_dir, "overall_final.txt"), "w") as f:
    f.write(bench_tput_line + "\n" + bench_lat_line + "\n")

log_tail = log_lines[-40:] if parse_status != "ok" else []

results = {
    "throughput_ops_per_sec": throughput,
    "read_throughput_ops_per_sec": read_tput,
    "read_avg_latency_ns": per_op_lat_avg["READ"],
    "read_p99_latency_ns": per_op_lat_p99["READ"],
    "parse": {
        "status": parse_status,
        "throughput_source": throughput_source,
        "bench_overall_throughput_present": bool(bench_tput_line),
        "bench_overall_latency_present": bool(bench_lat_line),
        "bench_epoch_count": len(bench_epochs),
        "fallback_window_epochs": fallback_n,
        "latency_capture_broken": latency_capture_broken,
    },
    "per_op_throughput_ops_per_sec": per_op_tput,
    "per_op_avg_latency_ns": per_op_lat_avg,
    "per_op_p99_latency_ns": per_op_lat_p99,
    "config": {
        "cluster": int(cluster),
        "key_size": int(ksz),
        "value_size": int(vsz),
        "cache_limit_mb": int(cache_mb),
        "warmup_seconds": int(warmup_s),
        "runtime_seconds": int(run_s),
        "threads": int(threads),
        "read_fraction": 1.0,
        "leveldb_block_cache_bytes": 0,
        "init_trace": init_trace,
        "bench_trace": bench_trace,
    },
}
if log_tail:
    results["parse"]["log_tail"] = log_tail

with open(results_file, "w") as f:
    json.dump(results, f, indent=2)

print(f"throughput={throughput:.2f} read_tput={read_tput:.2f} "
      f"parse={parse_status} src={throughput_source} "
      f"latency_broken={latency_capture_broken}")
PYEOF
}

# ---------------------------------------------------------------------------
# Phase: warmup
# Sets up cgroup, ensures DB exists, starts the loader, replays
# $BENCH_WARMUP seconds of the trace under the policy. Cache is now warm.
# Loader is left running (PID written to $LOADER_PID_FILE).
# ---------------------------------------------------------------------------
do_warmup() {
    [[ -d "$YCSB_BUILD_DIR" ]] || err \
        "$YCSB_BUILD_DIR not found. Run: ./start_workers.sh --install-bench HOSTS..."
    [[ -x "$INIT_BIN" ]] || err "missing $INIT_BIN — run --install-bench"
    [[ -x "$RUN_BIN"  ]] || err "missing $RUN_BIN — run --install-bench"
    [[ -f "$INIT_TRACE"  ]] || err "missing init trace: $INIT_TRACE  (set TWITTER_TRACES_DIR)"
    [[ -f "$BENCH_TRACE" ]] || err "missing bench trace: $BENCH_TRACE (set TWITTER_TRACES_DIR)"
    if [[ "$BENCH_TRACE" != "$RO_TRACE" ]]; then
        log "WARN: get-only trace not found at $RO_TRACE — falling back to original mixed trace"
        log "WARN: this is NOT read-only. Run scripts/setup_workload_ro.sh to fix."
    fi
    if ! grep -q "EVO_CACHE_RO_PATCH" "$YCSB_BUILD_DIR/../leveldb/leveldb_client.cpp" 2>/dev/null; then
        log "WARN: My-YCSB patch not detected — LevelDB will silently use its 8 MiB"
        log "WARN: default block cache. Run scripts/setup_workload_ro.sh to fix."
    fi

    # ---- Init LevelDB if needed ----
    DB_STAMP="$DB_DIR/.evo_stamp"
    init_mtime="$(stat -c %Y "$INIT_TRACE" 2>/dev/null || stat -f %m "$INIT_TRACE")"
    DB_STAMP_VAL="cluster${TWITTER_CLUSTER}-${DB_KEY_SIZE}-${DB_VALUE_SIZE}-${init_mtime}"
    INIT_CFG="$JOB_DIR/init.yaml"

    if [[ "$DB_DIR" == "$PREBUILT_DB" ]]; then
        log "Using pre-built cluster${TWITTER_CLUSTER} LevelDB at $DB_DIR (skipping init)"
        DB_FROM_INIT=0
    elif [[ ! -f "$DB_STAMP" || "$(cat "$DB_STAMP" 2>/dev/null)" != "$DB_STAMP_VAL" ]]; then
        DB_FROM_INIT=1
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
  cache_size: 0
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
        DB_FROM_INIT=0
    fi

    # ---- Canonicalize LevelDB compaction state (one-time, idempotent) ----
    # LevelDB SST layout drifts across machines depending on history; a
    # more-compacted DB walks fewer SSTs per get and shows dramatically
    # different read amp / throughput. Forcing a full CompactRange brings
    # every worker's DB to a deterministic shape. Stamp gates the work so
    # this runs at most once per DB-version.
    COMPACT_BIN="$YCSB_BUILD_DIR/compact_leveldb"
    COMPACT_STAMP="$DB_DIR/.compacted_stamp"
    COMPACT_STAMP_VAL="major-v1"
    if [[ -x "$COMPACT_BIN" ]]; then
        if [[ ! -f "$COMPACT_STAMP" || "$(cat "$COMPACT_STAMP" 2>/dev/null)" != "$COMPACT_STAMP_VAL" ]]; then
            log "Major-compacting $DB_DIR (one-time canonicalization)..."
            if "$COMPACT_BIN" "$DB_DIR" >"$JOB_DIR/compact.log" 2>&1; then
                echo "$COMPACT_STAMP_VAL" > "$COMPACT_STAMP"
                log "Compaction OK ($(du -sh "$DB_DIR" | awk '{print $1}'), $(ls "$DB_DIR"/*.ldb 2>/dev/null | wc -l) SSTs)"
            else
                tail -20 "$JOB_DIR/compact.log" >&2 || true
                log "WARN: compact_leveldb failed — continuing with uncompacted DB"
            fi
        else
            log "DB already canonicalized (stamp=$COMPACT_STAMP_VAL)"
        fi
    else
        log "WARN: $COMPACT_BIN missing — run scripts/setup_workload_ro.sh; skipping compaction"
    fi

    # ---- Cgroup setup ----
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
    # Hard wall only — no memory.high. Soft watermark triggered direct reclaim
    # outside cache_ext's hooks, contaminating iostat/memstat probes with the
    # kernel's own LRU activity. Reverting to memory.max as the only signal.
    limit_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    echo "$limit_bytes" > "$CGROUP_PATH/memory.max"
    echo 0              > "$CGROUP_PATH/memory.swap.max" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    log "Cgroup: $CGROUP_NAME max=${CACHE_LIMIT_MB}MB"

    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1

    # ---- Start loader ----
    if [[ -n "$POLICY_BINARY" ]]; then
        [[ -x "$POLICY_BINARY" ]] || err "Not executable: $POLICY_BINARY"
        echo 'n' | tee /sys/kernel/mm/lru_gen/enabled > /dev/null 2>&1 || true
        cgroup_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
        # setsid so the loader survives this bash's exit in split mode.
        setsid "$POLICY_BINARY" \
            -w "$DB_DIR" \
            -s "$cgroup_bytes" \
            -c "$CGROUP_PATH" >"$LOADER_LOG" 2>&1 &
        LOADER_PID=$!
        echo "$LOADER_PID" > "$LOADER_PID_FILE"
        sleep 1
        if ! kill -0 "$LOADER_PID" 2>/dev/null; then
            cat "$LOADER_LOG" >&2 || true
            err "policy loader died immediately"
        fi
        log "Policy loader running (PID $LOADER_PID)"
    else
        log "No POLICY_BINARY set — running baseline (calibration mode)"
        : > "$LOADER_PID_FILE"
    fi

    # ---- Warm the page cache via a $BENCH_WARMUP-second trace replay ----
    if (( BENCH_WARMUP > 0 )); then
        WARMUP_CFG="$JOB_DIR/warmup.yaml"
        WARMUP_LOG="$JOB_DIR/warmup.log"
        write_run_cfg "$WARMUP_CFG" "$BENCH_WARMUP"
        log "Warming cache: $BENCH_WARMUP s of trace replay under the policy..."
        (
            echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
            exec "$RUN_BIN" "$WARMUP_CFG"
        ) >"$WARMUP_LOG" 2>&1 \
            || { tail -80 "$WARMUP_LOG" >&2; err "warmup run_leveldb failed"; }

        if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
            cat "$LOADER_LOG" >&2 || true
            err "policy loader died during warmup"
        fi
    fi
    log "Warmup phase done (loader still alive, cache primed)"
}

# ---------------------------------------------------------------------------
# Phase: measure
# Replays $BENCH_RUNTIME seconds, parses results.json. The cgroup, DB, and
# policy loader were all set up by the warmup phase. Probes wrap this.
# ---------------------------------------------------------------------------
do_measure() {
    if [[ -z "$LOADER_PID" && -f "$LOADER_PID_FILE" ]]; then
        LOADER_PID="$(cat "$LOADER_PID_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" 2>/dev/null >&2 || true
        err "policy loader is not alive at start of measure"
    fi

    RUN_CFG="$JOB_DIR/run.yaml"
    RUN_LOG="$JOB_DIR/run.log"
    write_run_cfg "$RUN_CFG" "$BENCH_RUNTIME"

    log "Replaying cluster${TWITTER_CLUSTER} bench trace (measure=${BENCH_RUNTIME}s, ${BENCH_THREADS} threads, read-only)..."
    (
        echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
        exec "$RUN_BIN" "$RUN_CFG"
    ) >"$RUN_LOG" 2>&1 \
        || { tail -80 "$RUN_LOG" >&2; err "run_leveldb failed"; }

    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" >&2 || true
        err "policy loader died during the benchmark"
    fi

    parse_results "$RUN_LOG"

    total_tput="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["throughput_ops_per_sec"])' "$RESULTS_FILE")"
    read_p99="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["read_p99_latency_ns"])' "$RESULTS_FILE")"
    log "Throughput: ${total_tput} ops/sec   READ p99=${read_p99} ns   → $RESULTS_FILE"
    log "Done."
}

# ---------------------------------------------------------------------------
# Phase: all  (legacy single-shot — uses run_leveldb's own internal warmup,
# probes wrap everything including init/drop_caches, just like the original)
# ---------------------------------------------------------------------------
do_all() {
    do_warmup_setup_only=1   # marker only — do_all reuses do_warmup's body
    # We want everything do_warmup does EXCEPT we drive run_leveldb once
    # with both warmup and measure inside it (to preserve original semantics).
    # Easiest: invoke do_warmup with BENCH_WARMUP=0 (skip the inner warmup
    # replay), then call a single run_leveldb that does both phases inline.
    local saved_warmup="$BENCH_WARMUP"
    BENCH_WARMUP=0
    do_warmup
    BENCH_WARMUP="$saved_warmup"

    RUN_CFG="$JOB_DIR/run.yaml"
    RUN_LOG="$JOB_DIR/run.log"
    cat > "$RUN_CFG" <<EOF
database:
  key_size: $DB_KEY_SIZE
  value_size: $DB_VALUE_SIZE
  nr_entry: $DB_NR_ENTRY

workload:
  nr_warmup_op: 0
  warmup_runtime_seconds: $BENCH_WARMUP
  runtime_seconds: $BENCH_RUNTIME
  nr_op: 1000000000
  nr_thread: $BENCH_THREADS
  next_op_interval_ns: 0
  operation_proportion:
    read: 1.0
    update: 0
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
  cache_size: 0
  print_stats: false
EOF

    log "Replaying cluster${TWITTER_CLUSTER} bench trace (warmup=${BENCH_WARMUP}s, measure=${BENCH_RUNTIME}s, ${BENCH_THREADS} threads, read-only)..."
    (
        echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
        exec "$RUN_BIN" "$RUN_CFG"
    ) >"$RUN_LOG" 2>&1 \
        || { tail -80 "$RUN_LOG" >&2; err "run_leveldb failed"; }

    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" >&2 || true
        err "policy loader died during the benchmark"
    fi

    parse_results "$RUN_LOG"

    total_tput="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["throughput_ops_per_sec"])' "$RESULTS_FILE")"
    read_p99="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["read_p99_latency_ns"])' "$RESULTS_FILE")"
    log "Throughput: ${total_tput} ops/sec   READ p99=${read_p99} ns   → $RESULTS_FILE"
    log "Done."
}

case "$EVO_PHASE" in
    warmup)  do_warmup ;;
    measure) do_measure ;;
    all)     do_all ;;
    *)       err "Unknown EVO_PHASE=$EVO_PHASE (expected warmup|measure|all)" ;;
esac
