#!/bin/bash
# ==========================================================================
# Filesearch A/B comparison: baseline vs. cache policies
#
# Runs ripgrep inside a memory-limited cgroup with and without BPF cache
# eviction policies, then compares wall-clock times.
#
# Usage:
#   sudo ./run_comparison.sh [OPTIONS]
#
# Options:
#   --data-dir DIR         Directory to search (default: /mydata/evo_cache/linux)
#   --policies "p1 p2..."  Space-separated policy binaries to test
#                          (default: all .out in cache_ext/policies/)
#   --mem-limit BYTES      Cgroup memory limit (default: 1073741824 = 1 GiB)
#   --passes N             rg passes per iteration (default: 5)
#   --iterations N         Iterations per configuration (default: 3)
#   --results-dir DIR      Where to write JSON results (default: ./comparison_results)
#   --seed N               Random seed for reproducibility
# ==========================================================================
set -euo pipefail

# ---- Defaults ----
DATA_DIR="/mydata/evo_cache/linux"
POLICIES=""
MEM_LIMIT=1073741824    # 1 GiB
PASSES=5
ITERATIONS=3
RESULTS_DIR=""
SEED=""
CGROUP_NAME="evo_bench"
CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_EXT_DIR="/mydata/evo_cache/cache_ext"
POLICY_DIR="$CACHE_EXT_DIR/policies"

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)     DATA_DIR="$2";    shift 2 ;;
    --policies)     POLICIES="$2";    shift 2 ;;
    --mem-limit)    MEM_LIMIT="$2";   shift 2 ;;
    --passes)       PASSES="$2";      shift 2 ;;
    --iterations)   ITERATIONS="$2";  shift 2 ;;
    --results-dir)  RESULTS_DIR="$2"; shift 2 ;;
    --seed)         SEED="$2";        shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/comparison_results}"

# ---- Check prerequisites ----
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (need cgroup + BPF policy loading)" >&2
  echo "Usage: sudo $0 [OPTIONS]" >&2
  exit 1
fi

if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: data directory not found: $DATA_DIR" >&2
  exit 1
fi

if ! command -v rg &>/dev/null; then
  echo "ERROR: ripgrep (rg) not found" >&2
  exit 1
fi

# ---- Discover policies if not specified ----
if [[ -z "$POLICIES" ]]; then
  POLICIES=$(ls "$POLICY_DIR"/*.out 2>/dev/null | tr '\n' ' ')
  if [[ -z "$POLICIES" ]]; then
    echo "WARNING: no compiled policies found in $POLICY_DIR" >&2
    echo "Will only run baseline." >&2
  fi
fi

# ---- Search terms ----
TERMS=(
  write read open close ioctl mmap munmap brk
  fork exec exit wait kill signal sigaction pipe
  socket bind listen accept connect send recv poll
  select epoll kqueue futex mutex spinlock rwlock
  semaphore atomic barrier memory cache page slab
  kmalloc vmalloc kfree vfree dma irq interrupt
  softirq tasklet workqueue timer jiffies schedule
  preempt migrate affinity cpu numa node zone
  buddy compact reclaim swap writeback dirty flush
  sync fsync buffer block sector bio request
  queue elevator deadline cfq noop device driver
  probe remove suspend resume power acpi pci
  usb scsi nvme mmc gpio i2c spi uart
  tty console printk trace debug panic oops
  bug warn error fault exception trap syscall
  vdso vsyscall compat namespace cgroup seccomp
  capability selinux apparmor audit keyring crypto
)
NUM_TERMS=${#TERMS[@]}

if [[ -n "$SEED" ]]; then
  RANDOM=$SEED
else
  RANDOM=$$
fi

# ---- Helpers ----
pick_terms() {
  local n=$1
  local picked=()
  local indices=()
  while [[ ${#picked[@]} -lt $n ]]; do
    local idx=$(( RANDOM % NUM_TERMS ))
    local dup=0
    for prev in "${indices[@]+"${indices[@]}"}"; do
      [[ "$prev" == "$idx" ]] && { dup=1; break; }
    done
    if [[ $dup -eq 0 ]]; then
      indices+=("$idx")
      picked+=("${TERMS[$idx]}")
    fi
  done
  echo "${picked[@]}"
}

setup_cgroup() {
  # Clean up any leftover cgroup
  teardown_cgroup 2>/dev/null || true

  # Enable memory controller on the root cgroup
  echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

  mkdir -p "$CGROUP_PATH"
  echo "$MEM_LIMIT" > "$CGROUP_PATH/memory.max"
  echo "Cgroup $CGROUP_NAME: memory.max=$(cat "$CGROUP_PATH/memory.max")"
}

teardown_cgroup() {
  # Move any leftover procs back to root
  if [[ -f "$CGROUP_PATH/cgroup.procs" ]]; then
    while read -r pid; do
      echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
    done < "$CGROUP_PATH/cgroup.procs"
  fi
  rmdir "$CGROUP_PATH" 2>/dev/null || true
}

drop_caches() {
  sync
  echo 3 > /proc/sys/vm/drop_caches
}

run_in_cgroup() {
  # Run a command inside the benchmark cgroup.
  # We use a subshell: move it into the cgroup, then exec the real command.
  bash -c "echo \$\$ > '$CGROUP_PATH/cgroup.procs' && exec $*"
}

start_policy() {
  local policy_bin="$1"
  "$policy_bin" \
    --watch_dir "$DATA_DIR" \
    --cgroup_path "$CGROUP_PATH" \
    --cgroup_size "$MEM_LIMIT" \
    &>/dev/null &
  POLICY_PID=$!
  # Give the policy time to load BPF and attach
  sleep 3
  if ! kill -0 "$POLICY_PID" 2>/dev/null; then
    echo "  WARNING: policy exited early" >&2
    POLICY_PID=""
    return 1
  fi
  return 0
}

stop_policy() {
  if [[ -n "${POLICY_PID:-}" ]]; then
    kill -INT "$POLICY_PID" 2>/dev/null || true
    wait "$POLICY_PID" 2>/dev/null || true
    POLICY_PID=""
    sleep 1
  fi
}

# Run the benchmark and print elapsed seconds
run_workload() {
  local label="$1"
  local iter_times=()
  local all_terms=()

  for (( i=1; i<=ITERATIONS; i++ )); do
    read -ra search_terms <<< "$(pick_terms "$PASSES")"
    all_terms+=("${search_terms[@]}")

    echo -n "  [$label iter $i/$ITERATIONS] ${search_terms[*]} ... "

    drop_caches

    local start_ns=$(date +%s%N)

    for term in "${search_terms[@]}"; do
      run_in_cgroup rg "$term" "$DATA_DIR" > /dev/null 2>&1 || true
    done

    local end_ns=$(date +%s%N)
    local ms=$(( (end_ns - start_ns) / 1000000 ))
    local sec=$(awk "BEGIN {printf \"%.3f\", $ms / 1000.0}")
    iter_times+=("$sec")
    echo "${sec}s"
  done

  # Compute stats
  AVG=$(printf '%s\n' "${iter_times[@]}" | awk '{s+=$1} END {printf "%.3f", s/NR}')
  MIN=$(printf '%s\n' "${iter_times[@]}" | sort -n | head -1)
  MAX=$(printf '%s\n' "${iter_times[@]}" | sort -n | tail -1)

  UNIQUE_TERMS=($(printf '%s\n' "${all_terms[@]}" | sort -u))
  TERMS_JSON=$(printf '"%s",' "${UNIQUE_TERMS[@]}")
  TERMS_JSON="[${TERMS_JSON%,}]"

  # Return via global vars (bash has no easy return-struct)
  _RESULT_AVG="$AVG"
  _RESULT_MIN="$MIN"
  _RESULT_MAX="$MAX"
  _RESULT_TERMS_JSON="$TERMS_JSON"
  _RESULT_ITER_TIMES=("${iter_times[@]}")
}

write_result_json() {
  local file="$1"
  local label="$2"
  cat > "$file" <<EOF
{
    "label": "$label",
    "results": {
        "avg_sec": $_RESULT_AVG,
        "min_sec": $_RESULT_MIN,
        "max_sec": $_RESULT_MAX,
        "runtime_sec": $_RESULT_AVG,
        "passes": $PASSES,
        "iterations": $ITERATIONS,
        "mem_limit_bytes": $MEM_LIMIT,
        "terms_searched": $_RESULT_TERMS_JSON
    }
}
EOF
}

# ---- Main ----
echo "================================================================"
echo " Filesearch Comparison Benchmark"
echo "================================================================"
echo "  Data dir:     $DATA_DIR"
echo "  Memory limit: $(( MEM_LIMIT / 1048576 )) MiB"
echo "  Passes:       $PASSES  (rg invocations per iteration)"
echo "  Iterations:   $ITERATIONS"
echo "  Policies:     $(echo "$POLICIES" | wc -w | tr -d ' ') + baseline"
echo ""

mkdir -p "$RESULTS_DIR"

# Disable MGLRU so cache_ext policies take effect
if [[ -f "$CACHE_EXT_DIR/utils/disable-mglru.sh" ]]; then
  "$CACHE_EXT_DIR/utils/disable-mglru.sh" || true
fi

setup_cgroup

# Collect summary rows: "label  avg  min  max"
declare -a SUMMARY_LABELS=()
declare -a SUMMARY_AVGS=()
declare -a SUMMARY_MINS=()
declare -a SUMMARY_MAXS=()

# ---- Baseline (no policy) ----
echo "--- Baseline (no policy) ---"
run_workload "baseline"
write_result_json "$RESULTS_DIR/baseline.json" "baseline"
BASELINE_AVG="$_RESULT_AVG"
SUMMARY_LABELS+=("baseline")
SUMMARY_AVGS+=("$_RESULT_AVG")
SUMMARY_MINS+=("$_RESULT_MIN")
SUMMARY_MAXS+=("$_RESULT_MAX")
echo ""

# ---- Each policy ----
for policy_path in $POLICIES; do
  policy_name=$(basename "$policy_path" .out)
  echo "--- Policy: $policy_name ---"

  if start_policy "$policy_path"; then
    run_workload "$policy_name"
    write_result_json "$RESULTS_DIR/${policy_name}.json" "$policy_name"
    SUMMARY_LABELS+=("$policy_name")
    SUMMARY_AVGS+=("$_RESULT_AVG")
    SUMMARY_MINS+=("$_RESULT_MIN")
    SUMMARY_MAXS+=("$_RESULT_MAX")
    stop_policy
  else
    echo "  SKIPPED (policy failed to start)"
    SUMMARY_LABELS+=("$policy_name")
    SUMMARY_AVGS+=("FAIL")
    SUMMARY_MINS+=("-")
    SUMMARY_MAXS+=("-")
  fi
  echo ""
done

# ---- Cleanup ----
teardown_cgroup

# ---- Summary table ----
echo "================================================================"
echo " RESULTS SUMMARY"
echo "================================================================"
printf "%-30s %10s %10s %10s %10s\n" "POLICY" "AVG (s)" "MIN (s)" "MAX (s)" "vs BASE"
printf "%-30s %10s %10s %10s %10s\n" "------" "-------" "-------" "-------" "-------"

for (( i=0; i<${#SUMMARY_LABELS[@]}; i++ )); do
  label="${SUMMARY_LABELS[$i]}"
  avg="${SUMMARY_AVGS[$i]}"
  min="${SUMMARY_MINS[$i]}"
  max="${SUMMARY_MAXS[$i]}"

  if [[ "$avg" == "FAIL" ]]; then
    printf "%-30s %10s %10s %10s %10s\n" "$label" "FAIL" "-" "-" "-"
  else
    if [[ "$label" == "baseline" ]]; then
      speedup="1.00x"
    else
      speedup=$(awk "BEGIN {
        if ($avg > 0) printf \"%.2fx\", $BASELINE_AVG / $avg;
        else printf \"N/A\"
      }")
    fi
    printf "%-30s %10s %10s %10s %10s\n" "$label" "$avg" "$min" "$max" "$speedup"
  fi
done

echo ""
echo "Results saved to $RESULTS_DIR/"

# ---- Write combined JSON ----
{
  echo "["
  first=1
  for f in "$RESULTS_DIR"/*.json; do
    [[ "$f" == *"combined"* ]] && continue
    [[ $first -eq 0 ]] && echo ","
    cat "$f"
    first=0
  done
  echo ""
  echo "]"
} > "$RESULTS_DIR/combined.json"

echo "Combined results: $RESULTS_DIR/combined.json"
