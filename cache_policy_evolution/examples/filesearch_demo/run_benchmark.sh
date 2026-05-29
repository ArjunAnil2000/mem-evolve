#!/bin/bash
# ==========================================================================
# Filesearch benchmark - searches Linux kernel source with ripgrep
#
# Usage:
#   ./run_benchmark.sh [OPTIONS]
#
# Options:
#   --data-dir DIR        Directory to search (default: /mydata/evo_cache/linux)
#   --results-file FILE   Where to write JSON results (default: results.json)
#   --passes N            Number of ripgrep passes per iteration (default: 5)
#   --iterations N        Number of full iterations to run (default: 3)
#   --seed N              Random seed (default: based on time)
#
# Output JSON format (compatible with the evolution framework):
#   {
#     "results": {
#       "runtime_sec": 12.34,
#       "passes": 5,
#       "iterations": 3,
#       "terms_searched": ["write", "mutex", ...],
#       "avg_iteration_sec": 4.11,
#       "min_iteration_sec": 3.92,
#       "max_iteration_sec": 4.45
#     }
#   }
# ==========================================================================
set -euo pipefail

# ---- Defaults ----
DATA_DIR="/mydata/evo_cache/linux"
RESULTS_FILE="results.json"
PASSES=5
ITERATIONS=3
SEED=""

# ---- 100 kernel-related search terms (same pool as the Python bench) ----
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

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)    DATA_DIR="$2";      shift 2 ;;
    --results-file) RESULTS_FILE="$2"; shift 2 ;;
    --passes)      PASSES="$2";        shift 2 ;;
    --iterations)  ITERATIONS="$2";    shift 2 ;;
    --seed)        SEED="$2";          shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ---- Validate ----
if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: data directory not found: $DATA_DIR" >&2
  exit 1
fi

if ! command -v rg &>/dev/null; then
  echo "ERROR: ripgrep (rg) not found in PATH" >&2
  exit 1
fi

# ---- Seed the RANDOM generator ----
if [[ -n "$SEED" ]]; then
  RANDOM=$SEED
else
  RANDOM=$$  # PID-based for some variance between runs
fi

NUM_TERMS=${#TERMS[@]}

# ---- Helper: pick N random unique terms ----
pick_terms() {
  local n=$1
  local picked=()
  local indices=()

  # Fisher-Yates-ish: just pick random indices, skip dupes
  while [[ ${#picked[@]} -lt $n ]]; do
    local idx=$(( RANDOM % NUM_TERMS ))
    # simple dedup via string check
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

# ---- Run benchmark ----
echo "=== Filesearch Benchmark ==="
echo "  Data dir:    $DATA_DIR"
echo "  Passes:      $PASSES"
echo "  Iterations:  $ITERATIONS"
echo ""

ALL_TERMS_USED=()
ITER_TIMES=()
TOTAL_START=$(date +%s%N)

for (( iter=1; iter<=ITERATIONS; iter++ )); do
  # Pick fresh random terms for this iteration
  read -ra SEARCH_TERMS <<< "$(pick_terms "$PASSES")"
  ALL_TERMS_USED+=("${SEARCH_TERMS[@]}")

  echo "[iteration $iter/$ITERATIONS] searching: ${SEARCH_TERMS[*]}"

  ITER_START=$(date +%s%N)

  for term in "${SEARCH_TERMS[@]}"; do
    rg "$term" "$DATA_DIR" > /dev/null 2>&1 || true
  done

  ITER_END=$(date +%s%N)
  ITER_MS=$(( (ITER_END - ITER_START) / 1000000 ))
  ITER_SEC=$(awk "BEGIN {printf \"%.3f\", $ITER_MS / 1000.0}")
  ITER_TIMES+=("$ITER_SEC")
  echo "  -> ${ITER_SEC}s"
done

TOTAL_END=$(date +%s%N)
TOTAL_MS=$(( (TOTAL_END - TOTAL_START) / 1000000 ))
TOTAL_SEC=$(awk "BEGIN {printf \"%.3f\", $TOTAL_MS / 1000.0}")

# ---- Compute stats ----
AVG_SEC=$(printf '%s\n' "${ITER_TIMES[@]}" | awk '{s+=$1} END {printf "%.3f", s/NR}')
MIN_SEC=$(printf '%s\n' "${ITER_TIMES[@]}" | sort -n | head -1)
MAX_SEC=$(printf '%s\n' "${ITER_TIMES[@]}" | sort -n | tail -1)

# Deduplicate terms for the JSON list
UNIQUE_TERMS=($(printf '%s\n' "${ALL_TERMS_USED[@]}" | sort -u))
TERMS_JSON=$(printf '"%s",' "${UNIQUE_TERMS[@]}")
TERMS_JSON="[${TERMS_JSON%,}]"

echo ""
echo "=== Results ==="
echo "  Total:   ${TOTAL_SEC}s"
echo "  Average: ${AVG_SEC}s / iteration"
echo "  Min:     ${MIN_SEC}s"
echo "  Max:     ${MAX_SEC}s"

# ---- Write JSON ----
mkdir -p "$(dirname "$RESULTS_FILE")"
cat > "$RESULTS_FILE" <<EOF
{
    "results": {
        "runtime_sec": $TOTAL_SEC,
        "passes": $PASSES,
        "iterations": $ITERATIONS,
        "terms_searched": $TERMS_JSON,
        "avg_iteration_sec": $AVG_SEC,
        "min_iteration_sec": $MIN_SEC,
        "max_iteration_sec": $MAX_SEC
    }
}
EOF

echo ""
echo "Results written to $RESULTS_FILE"
