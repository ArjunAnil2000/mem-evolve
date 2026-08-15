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
# PHASE MODEL
# -----------
# Driven by EVO_PHASE (set by the evaluator) — same contract as
# eval/twitter_leveldb_ro/run_with_policy.sh and eval/scan_thrash:
#   EVO_PHASE=warmup   — pin scan_pids map, init/reuse LevelDB, cgroup
#                        setup, drop_caches+swapoff, start the policy
#                        loader, replay $BENCH_WARMUP seconds of the SAME
#                        GET/SCAN mix under the policy to warm the cache.
#                        Loader stays running on exit (PID at
#                        $JOB_DIR/loader.pid; evaluator owns cleanup after
#                        the measure phase). scan_pids pin is also left in
#                        place — the measure phase reuses it.
#   EVO_PHASE=measure  — replay $BENCH_RUNTIME seconds and parse
#                        results.json. Probes wrap THIS phase only (no
#                        init/drop_caches/swapoff/warmup noise). Removes
#                        the scan_pids pin on exit (this is the true end
#                        of the round in split mode).
#   EVO_PHASE=all      — legacy single-phase mode (default if unset, and
#                        what runs unless get_scan.toml sets
#                        benchmark_split=true). Original behavior: pin
#                        scan_pids, init DB, drop_caches, run ONE
#                        $BENCH_RUNTIME-second bench (no separate warmup
#                        replay), loader killed and scan_pids pin removed
#                        on exit — byte-for-byte the same as before this
#                        script had a phase split.
#
# Required env (set by evolve.py via the evaluator):
#   POLICY_BINARY    pre-compiled policy loader (omit for baseline runs).
#                    Accepts both mem-evolve-generated seed loaders
#                    (-w/-s/-c) and cache_ext's own reference-policy
#                    loaders (-w/-c only, no cgroup_size) — see
#                    start_policy_loader() below, which tries the
#                    3-flag form first and falls back on "invalid option".
#   JOB_DIR          scratch dir; results.json written here
#   CACHE_EXT_CGROUP cgroup path (created if missing)
#
# One-time setup (per worker):
#     eval/get_scan/setup.sh setup
#
# Tunables (env, all optional):
#   CACHE_LIMIT_MB     cgroup memory.max (default 64)
#   BENCH_RUNTIME      bench seconds (default 30)
#   BENCH_WARMUP       warmup seconds before measurement, EVO_PHASE=warmup
#                      only (default 10, set 0 to skip warming)
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
#                       removes the pin once the round is truly over (see
#                       PHASE MODEL above). This is deliberate — fairness
#                       across experiments requires every policy to see
#                       the exact same benchmark environment regardless
#                       of whether it knows what scan_pids is, so the
#                       map's existence must never depend on which
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
BENCH_WARMUP="${BENCH_WARMUP:-10}"
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
EVO_PHASE="${EVO_PHASE:-all}"
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
log() { echo "[get_scan:$EVO_PHASE] $*"; }
err() { echo "[get_scan:$EVO_PHASE] ERROR: $*" >&2; exit 1; }

cleanup() {
    # In split mode the loader outlives this shell so the measure phase can
    # use it; the evaluator tears it down via $JOB_DIR/loader.pid after
    # measure completes. In all-mode we kill it ourselves like the
    # original (pre-split) script always did.
    if [[ "$EVO_PHASE" == "all" && -n "$LOADER_PID" ]]; then
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    fi
    # This script owns the scan_pids map's lifecycle (see ENABLE_BPF_SCAN_MAP
    # doc above). In split mode the warmup phase must leave the pin in place
    # for measure to reuse — only remove it once the round is truly over
    # (measure or all), never at the end of warmup. Always clear on
    # measure/all regardless of how the round ended, so a crashed round
    # never shadows the next one's map.
    if [[ "$EVO_PHASE" == "measure" || "$EVO_PHASE" == "all" ]]; then
        rm -f "$SCAN_PIDS_PIN_PATH" 2>/dev/null || true
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

# Write a run_leveldb config that replays the zipfian GET/SCAN mix for $2
# seconds into $1. Used for both the warmup replay and the measured run —
# only the duration differs.
write_run_cfg() {
    local out_path="$1"
    local seconds="$2"
    local read_prop
    read_prop="$(awk "BEGIN { printf \"%.4f\", 1 - $SCAN_PROPORTION }")"
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
}

# Run $RUN_BIN against $1 (a config written by write_run_cfg), inside the
# cgroup, with the scan-map env forwarded, logging to $2.
run_bench() {
    local cfg_path="$1"
    local log_path="$2"
    local extra_envs=()
    [[ "$ENABLE_BPF_SCAN_MAP" == "1" ]] && extra_envs+=("ENABLE_BPF_SCAN_MAP=1")
    (
        echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
        for kv in "${extra_envs[@]+"${extra_envs[@]}"}"; do
            export "${kv?}"
        done
        exec "$RUN_BIN" "$cfg_path"
    ) >"$log_path" 2>&1 \
        || { tail -80 "$log_path" >&2; err "run_leveldb failed"; }
}

# Parse throughput/latency out of $1 (a run_leveldb log) and write
# $RESULTS_FILE.
parse_results() {
    local run_log="$1"
    local total_tput read_tput scan_tput read_p99 read_avg scan_p99
    total_tput="$(grep -oE 'total throughput [0-9]+\.[0-9]+ ops/sec'  "$run_log" | tail -1 | awk '{print $3}')"
    read_tput="$( grep -oE 'READ throughput [0-9]+\.[0-9]+ ops/sec'   "$run_log" | tail -1 | awk '{print $3}')"
    scan_tput="$( grep -oE 'SCAN throughput [0-9]+\.[0-9]+ ops/sec'   "$run_log" | tail -1 | awk '{print $3}')"
    read_p99="$(  grep -oE 'READ p99 latency [0-9]+\.[0-9]+ ns'       "$run_log" | tail -1 | awk '{print $4}')"
    read_avg="$(  grep -oE 'READ average latency [0-9]+\.[0-9]+ ns'   "$run_log" | tail -1 | awk '{print $4}')"
    scan_p99="$(  grep -oE 'SCAN p99 latency [0-9]+\.[0-9]+ ns'       "$run_log" | tail -1 | awk '{print $4}')"

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
    "warmup_seconds": $BENCH_WARMUP,
    "threads": $BENCH_THREADS,
    "scan_proportion": $SCAN_PROPORTION,
    "scan_length": $SCAN_LENGTH,
    "enable_bpf_scan_map": "$ENABLE_BPF_SCAN_MAP"
  }
}
EOF
    log "Throughput: ${total_tput} ops/sec   READ p99=${read_p99} ns   SCAN p99=${scan_p99} ns   → $RESULTS_FILE"
}

# Loader CLI compat: mem-evolve-generated seed loaders (evo_policy.c) all
# take -w/-s/-c (watch_dir/cgroup_size/cgroup_path). cache_ext's OWN
# reference policies (cache_ext/policies/*.c, e.g. cache_ext_fifo.c)
# predate that convention and only take -w/-c — no cgroup_size flag at
# all. Try the full 3-flag form first; if argp rejects it (a genuine
# "invalid option" from getopt, not some other startup failure), retry
# with just -w/-c so both loader families work against this script.
# setsid so the loader survives this bash's exit in split mode (warmup
# phase's shell exits while the loader must keep running for measure).
start_policy_loader() {
    local cgroup_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    local extra_args=(-w "$DB_DIR" -s "$cgroup_bytes" -c "$CGROUP_PATH")
    setsid "$POLICY_BINARY" "${extra_args[@]}" >"$LOADER_LOG" 2>&1 &
    LOADER_PID=$!
    sleep 1
    if kill -0 "$LOADER_PID" 2>/dev/null; then
        return 0
    fi

    if grep -q "invalid option" "$LOADER_LOG" 2>/dev/null; then
        log "Loader rejected -s (cgroup_size) — retrying with -w/-c only" \
            "(cache_ext reference-policy CLI, no cgroup_size flag)"
        extra_args=(-w "$DB_DIR" -c "$CGROUP_PATH")
        setsid "$POLICY_BINARY" "${extra_args[@]}" >"$LOADER_LOG" 2>&1 &
        LOADER_PID=$!
        sleep 1
        if kill -0 "$LOADER_PID" 2>/dev/null; then
            return 0
        fi
    fi

    cat "$LOADER_LOG" >&2 || true
    err "policy loader died immediately (tried -w/-s/-c and -w/-c)"
}

# ---------------------------------------------------------------------------
# Phase: warmup
# Pins scan_pids, sets up cgroup, ensures DB exists, drops caches, starts
# the loader, replays $BENCH_WARMUP seconds of the same GET/SCAN mix under
# the policy so the cache is warm before measurement. Loader (and the
# scan_pids pin) are left running/pinned on exit.
# ---------------------------------------------------------------------------
do_warmup() {
    [[ -x "$INIT_BIN" ]] || err "missing $INIT_BIN — run: eval/get_scan/setup.sh setup"
    [[ -x "$RUN_BIN"  ]] || err "missing $RUN_BIN — run: eval/get_scan/setup.sh setup"
    if [[ "$ENABLE_BPF_SCAN_MAP" == "1" ]]; then
        command -v bpftool >/dev/null || err "bpftool not found (needed for ENABLE_BPF_SCAN_MAP=1)"
    fi

    # ---- scan_pids map (see ENABLE_BPF_SCAN_MAP doc above) ----
    rm -f "$SCAN_PIDS_PIN_PATH" 2>/dev/null || true
    if [[ "$ENABLE_BPF_SCAN_MAP" == "1" ]]; then
        mkdir -p "$(dirname "$SCAN_PIDS_PIN_PATH")"
        bpftool map create "$SCAN_PIDS_PIN_PATH" \
            type hash key 4 value 1 entries 1024 name scan_pids \
            || err "failed to create+pin scan_pids map at $SCAN_PIDS_PIN_PATH"
        log "scan_pids map pinned at $SCAN_PIDS_PIN_PATH"
    fi

    # ---- DB init (cached — re-init only if size/shape changes) ----
    # init_leveldb ignores workload.operation_proportion entirely for the
    # zipfian case (see leveldb/init_leveldb.cpp) — only
    # database.{nr_entry,key_size,value_size} and leveldb.data_dir matter,
    # so the workload block below is a harmless placeholder, not real config.
    local db_stamp="$DB_DIR/.evo_stamp"
    local db_stamp_val="${DB_NR_ENTRY}-${DB_KEY_SIZE}-${DB_VALUE_SIZE}"
    if [[ ! -f "$db_stamp" || "$(cat "$db_stamp" 2>/dev/null)" != "$db_stamp_val" ]]; then
        log "Initializing LevelDB at $DB_DIR ($DB_NR_ENTRY entries)..."
        rm -rf "$DB_DIR"
        mkdir -p "$DB_DIR"
        local init_cfg="$JOB_DIR/init.yaml"
        cat > "$init_cfg" <<EOF
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
        if ! "$INIT_BIN" "$init_cfg" >"$JOB_DIR/init.log" 2>&1; then
            tail -80 "$JOB_DIR/init.log" >&2
            err "init_leveldb failed"
        fi
        echo "$db_stamp_val" > "$db_stamp"
        log "DB ready ($(du -sh "$DB_DIR" | awk '{print $1}'))"
    else
        log "Reusing cached DB at $DB_DIR"
    fi

    # ---- Cgroup setup (cgroup-v2 via sysfs, same pattern as scan_thrash / twitter_leveldb) ----
    if [[ ! -d "$CGROUP_PATH" ]]; then
        mkdir -p "$CGROUP_PATH"
    fi
    local parent_dir
    parent_dir="$(dirname "$CGROUP_PATH")"
    if [[ -f "$parent_dir/cgroup.subtree_control" ]]; then
        grep -q memory "$parent_dir/cgroup.subtree_control" 2>/dev/null \
            || echo "+memory" > "$parent_dir/cgroup.subtree_control" 2>/dev/null || true
        grep -q 'io' "$parent_dir/cgroup.subtree_control" 2>/dev/null \
            || echo "+io" > "$parent_dir/cgroup.subtree_control" 2>/dev/null || true
    fi
    local limit_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    local high_bytes=$(( limit_bytes * 95 / 100 ))
    echo "$limit_bytes" > "$CGROUP_PATH/memory.max"
    echo "$high_bytes"  > "$CGROUP_PATH/memory.high"
    echo 0              > "$CGROUP_PATH/memory.swap.max" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    log "Cgroup: $CGROUP_NAME max=${CACHE_LIMIT_MB}MB"

    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1

    # ---- Start loader (scan_pids map already exists independent of this) ----
    if [[ -n "$POLICY_BINARY" ]]; then
        [[ -x "$POLICY_BINARY" ]] || err "Not executable: $POLICY_BINARY"
        echo 'n' | tee /sys/kernel/mm/lru_gen/enabled > /dev/null 2>&1 || true
        start_policy_loader
        echo "$LOADER_PID" > "$LOADER_PID_FILE"
        log "Policy loader running (PID $LOADER_PID)"
    else
        log "No POLICY_BINARY set — running baseline (calibration mode)"
        : > "$LOADER_PID_FILE"
    fi

    # ---- Warm the page cache: replay $BENCH_WARMUP seconds under the policy ----
    if (( BENCH_WARMUP > 0 )); then
        local warmup_cfg="$JOB_DIR/warmup.yaml"
        local warmup_log="$JOB_DIR/warmup.log"
        write_run_cfg "$warmup_cfg" "$BENCH_WARMUP"
        log "Warming cache: ${BENCH_WARMUP}s of GET/SCAN replay under the policy..."
        run_bench "$warmup_cfg" "$warmup_log"

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

    local run_cfg="$JOB_DIR/run.yaml"
    local run_log="$JOB_DIR/run.log"
    write_run_cfg "$run_cfg" "$BENCH_RUNTIME"

    log "Running GET-SCAN (measure=${BENCH_RUNTIME}s, ${BENCH_THREADS} threads, scan=${SCAN_PROPORTION}, ENABLE_BPF_SCAN_MAP=${ENABLE_BPF_SCAN_MAP})..."
    run_bench "$run_cfg" "$run_log"

    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" >&2 || true
        err "policy loader died during the benchmark"
    fi

    parse_results "$run_log"
    log "Done."
}

# ---------------------------------------------------------------------------
# Phase: all  (legacy single-shot — identical to this script's behavior
# before the phase split: no separate warmup replay, one $BENCH_RUNTIME-
# second bench, loader and scan_pids pin torn down on exit)
# ---------------------------------------------------------------------------
do_all() {
    local saved_warmup="$BENCH_WARMUP"
    BENCH_WARMUP=0
    do_warmup
    BENCH_WARMUP="$saved_warmup"

    local run_cfg="$JOB_DIR/run.yaml"
    local run_log="$JOB_DIR/run.log"
    write_run_cfg "$run_cfg" "$BENCH_RUNTIME"

    log "Running GET-SCAN (${BENCH_RUNTIME}s, ${BENCH_THREADS} threads, scan=${SCAN_PROPORTION}, ENABLE_BPF_SCAN_MAP=${ENABLE_BPF_SCAN_MAP})..."
    run_bench "$run_cfg" "$run_log"

    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        cat "$LOADER_LOG" >&2 || true
        err "policy loader died during the benchmark"
    fi

    parse_results "$run_log"
    log "Done."
}

case "$EVO_PHASE" in
    warmup)  do_warmup ;;
    measure) do_measure ;;
    all)     do_all ;;
    *)       err "Unknown EVO_PHASE=$EVO_PHASE (expected warmup|measure|all)" ;;
esac
