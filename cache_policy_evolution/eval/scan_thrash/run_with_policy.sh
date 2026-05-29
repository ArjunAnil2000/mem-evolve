#!/usr/bin/env bash
# run_with_policy.sh — Self-contained benchmark wrapper for evolve.py
#
# Mirrors the known-stable test_scan_thrash.sh run_seed() flow, except it
# uses a pre-compiled POLICY_BINARY (evolve.py builds it) instead of
# splitting/compiling a seed file.
#
# PHASE MODEL
# -----------
# Driven by EVO_PHASE (set by the evaluator):
#   EVO_PHASE=warmup   — setup cgroup, drop_caches, generate data files,
#                        start the policy loader, prime page cache by
#                        reading the hot files once. Loader stays running
#                        after this script exits (PID written to
#                        $JOB_DIR/loader.pid for the evaluator to clean up).
#   EVO_PHASE=measure  — rejoin cgroup, run run_evo.sh. No setup, no data
#                        regen, no drop_caches. Probes wrap THIS phase only.
#                        Loader (started by warmup) is NOT killed on exit.
#   EVO_PHASE=all      — legacy single-phase mode (default if unset). Does
#                        warmup + measure inline and tears the loader down
#                        on exit, exactly like the original script.
#
# Required env (set by evolve.py):
#   POLICY_BINARY  — absolute path to compiled evo_policy.out
#   JOB_DIR        — directory where loader.pid + loader.log live
#
# Optional env (tunable):
#   CACHE_LIMIT_MB   (default: 64)
#   HOT_SIZE_MB      (default: 16)
#   SCAN_SIZE_MB     (default: 256)
#   ROUNDS           (default: 3)
#   SCAN_PASSES      (default: 1)

set -euo pipefail

POLICY_BINARY="${POLICY_BINARY:-}"
JOB_DIR="${JOB_DIR:-}"
CACHE_LIMIT_MB="${CACHE_LIMIT_MB:-64}"
HOT_SIZE_MB="${HOT_SIZE_MB:-16}"
SCAN_SIZE_MB="${SCAN_SIZE_MB:-256}"
ROUNDS="${ROUNDS:-5}"
SCAN_PASSES="${SCAN_PASSES:-1}"
EVO_PHASE="${EVO_PHASE:-all}"
# Per-evaluation scratch — JOB_DIR is unique per evaluator.evaluate() call,
# so concurrent runs on the same worker (when num_branches > num_workers and
# the round-robin doubles up two branches on one host) get fully isolated
# data dirs. The previous shared `/tmp/scan_thrash_data` raced on `rm -rf`
# vs. another run's still-open `cat`/loader, producing ENOTEMPTY.
SCAN_THRASH_DIR="${SCAN_THRASH_DIR:-${JOB_DIR:-/tmp}/scan_thrash_data}"
if [[ -n "${CACHE_EXT_CGROUP:-}" ]]; then
    CGROUP_PATH="$CACHE_EXT_CGROUP"
    CGROUP_NAME="$(basename "$CGROUP_PATH")"
else
    CGROUP_NAME="cache_ext_evo_bench"
    CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER_PID=""

log() { echo "[evo_bench:$EVO_PHASE] $*"; }
err() { echo "[evo_bench:$EVO_PHASE] ERROR: $*" >&2; exit 1; }

cleanup() {
    # In split mode, the evaluator tears the loader down via $JOB_DIR/loader.pid
    # (the loader has to outlive the warmup subshell so measure can use it).
    # In all-mode, fall back to the original kill-on-exit behavior.
    if [[ "$EVO_PHASE" == "all" && -n "$LOADER_PID" ]]; then
        kill -INT "$LOADER_PID" 2>/dev/null || true
        sleep 0.5
        kill -0 "$LOADER_PID" 2>/dev/null && kill -9 "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
    fi
    # Do NOT cgdelete: the evaluator's post-probes read io.stat/memory.stat
    # from $CGROUP_PATH after this script exits.
}
trap cleanup EXIT

[[ -z "$JOB_DIR" ]] && err "JOB_DIR not set — evolve.py should set this"
mkdir -p "$JOB_DIR"
LOADER_LOG="$JOB_DIR/loader.log"
LOADER_PID_FILE="$JOB_DIR/loader.pid"

# ---------------------------------------------------------------------------
# Phase: warmup (also the first half of EVO_PHASE=all)
# ---------------------------------------------------------------------------
do_warmup() {
    [[ -z "$POLICY_BINARY" ]] && err "POLICY_BINARY not set — evolve.py should set this"
    [[ ! -x "$POLICY_BINARY" ]] && err "Not executable: $POLICY_BINARY"

    # Disable MGLRU so BPF policy is actually in control
    echo 'n' | tee /sys/kernel/mm/lru_gen/enabled > /dev/null 2>&1 || true
    mglru_state="$(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo n/a)"
    log "MGLRU disabled: $mglru_state"
    if [[ "$mglru_state" == *"y"* ]]; then
        err "MGLRU is still enabled — BPF policy will have no effect"
    fi

    # Drop caches BEFORE starting anything (matches test_scan_thrash.sh main)
    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1

    # Setup memory-limited cgroup FIRST (matches test_scan_thrash order).
    # cgroup-tools (cgcreate/cgexec) isn't guaranteed to be installed on every
    # worker, so drive cgroup-v2 directly via sysfs. The memory controller must
    # already be enabled in the parent's cgroup.subtree_control.
    if [[ ! -d "$CGROUP_PATH" ]]; then
        mkdir -p "$CGROUP_PATH"
    fi
    parent_dir="$(dirname "$CGROUP_PATH")"
    if [[ -f "$parent_dir/cgroup.subtree_control" ]]; then
        # memory is needed for the limit; io is needed so io.stat attributes
        # block reads/writes to this cgroup (else the iostat probe reads zero).
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

    # Pre-generate data files BEFORE starting the loader, so the loader's
    # inode watchlist includes the actual benchmark files.
    rm -rf "$SCAN_THRASH_DIR"
    mkdir -p "$SCAN_THRASH_DIR/hot" "$SCAN_THRASH_DIR/cold"

    hot_file_mb=1
    hot_files=$(( HOT_SIZE_MB / hot_file_mb ))
    [[ $hot_files -lt 1 ]] && hot_files=1
    for i in $(seq 1 "$hot_files"); do
        dd if=/dev/urandom of="$SCAN_THRASH_DIR/hot/hot_${i}.dat" bs=1M count=$hot_file_mb status=none
    done

    cold_file_mb=4
    cold_files=$(( SCAN_SIZE_MB / cold_file_mb ))
    [[ $cold_files -lt 1 ]] && cold_files=1
    for i in $(seq 1 "$cold_files"); do
        dd if=/dev/urandom of="$SCAN_THRASH_DIR/cold/cold_${i}.dat" bs=1M count=$cold_file_mb status=none
    done
    log "Data ready: ${HOT_SIZE_MB}MB hot, ${SCAN_SIZE_MB}MB cold"

    # Start BPF policy loader (watches the data dir for inodes). setsid
    # detaches the process group so it survives this shell's exit in split
    # mode; in all-mode the trap still kills it via $LOADER_PID.
    cgroup_bytes=$((CACHE_LIMIT_MB * 1024 * 1024))
    setsid "$POLICY_BINARY" \
        -w "$SCAN_THRASH_DIR" \
        -s "$cgroup_bytes" \
        -c "$CGROUP_PATH" >"$LOADER_LOG" 2>&1 &
    LOADER_PID=$!
    echo "$LOADER_PID" > "$LOADER_PID_FILE"
    sleep 1

    if ! kill -0 "$LOADER_PID" 2>/dev/null; then
        log "Loader log:"
        cat "$LOADER_LOG" >&2 || true
        err "Policy loader died immediately — check kernel/BPF support"
    fi
    log "Policy loader running (PID $LOADER_PID)"

    # Prime the page cache with the hot working set so measure starts from a
    # representative steady state (otherwise the first SCAN_PASS is mostly
    # cold-cache I/O and dominates the iostat delta). Reads happen outside
    # the cgroup — the loader is what cares about inode-level decisions, and
    # the bytes go into the kernel page cache regardless.
    cat "$SCAN_THRASH_DIR"/hot/*.dat > /dev/null 2>&1 || true
    log "Hot working-set primed"
}

# ---------------------------------------------------------------------------
# Phase: measure (also the second half of EVO_PHASE=all)
# ---------------------------------------------------------------------------
do_measure() {
    # In split mode the loader was started by the previous warmup invocation.
    # Recover its PID so we can sanity-check survival post-bench.
    if [[ -z "$LOADER_PID" && -f "$LOADER_PID_FILE" ]]; then
        LOADER_PID="$(cat "$LOADER_PID_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        log "Loader log:"
        cat "$LOADER_LOG" 2>/dev/null >&2 || true
        err "Policy loader is not alive at start of measure"
    fi

    # Run the benchmark inside the cgroup (data already generated, skip setup).
    # cgroup-v2 equivalent of `cgexec -g memory:<name>`: spawn a subshell, write
    # its PID into cgroup.procs, then exec the benchmark so it inherits membership.
    export SKIP_SETUP=1
    (
        echo $BASHPID > "$CGROUP_PATH/cgroup.procs"
        exec bash "$SCRIPT_DIR/run_evo.sh"
    )

    # Verify the loader is STILL alive after the benchmark — if it died
    # mid-run, the score is invalid (policy wasn't attached the whole time).
    if [[ -n "$LOADER_PID" ]] && ! kill -0 "$LOADER_PID" 2>/dev/null; then
        log "Loader log:"
        cat "$LOADER_LOG" 2>/dev/null >&2 || true
        err "Policy loader died during the benchmark — score is invalid"
    fi
    log "Policy loader still alive post-benchmark — score is valid"
    log "Benchmark done"
}

case "$EVO_PHASE" in
    warmup)  do_warmup ;;
    measure) do_measure ;;
    all)     do_warmup; do_measure ;;
    *)       err "Unknown EVO_PHASE=$EVO_PHASE (expected warmup|measure|all)" ;;
esac
