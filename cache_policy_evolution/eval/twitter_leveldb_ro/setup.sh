#!/usr/bin/env bash
# Per-workload setup for twitter_leveldb_ro.
#
# On top of the shared base (yaml-cpp + leveldb fork + My-YCSB) installed
# by start_workers.sh --install-bench, this read-only variant needs:
#
#   1. My-YCSB patched so cache_size=0 in the YAML actually disables the
#      LevelDB block cache (vanilla My-YCSB ignores cache_size). Patch is
#      applied + the runners are rebuilt.
#   2. compact_leveldb helper binary (canonicalizes SST layout across
#      workers — see compact_leveldb.cpp under the legacy scripts/ dir).
#   3. cluster${N}_bench_readonly.txt: the original bench trace filtered
#      to get-only ops. Cached based on bench-trace mtime.
#
# Subcommands:
#   check  — verify everything is in place (read-only)
#   setup  — apply the patch, build, filter the trace (idempotent)
#
# Tunables (env, all optional):
#   TWITTER_TRACES_DIR  default: $REPO_ROOT/twitter-traces
#   TWITTER_CLUSTER     default: 17
#   YCSB_DIR            default: $REPO_ROOT/cache_ext/My-YCSB

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
EVO_DIR="$REPO_ROOT/cache_policy_evolution"
YCSB_DIR="${YCSB_DIR:-$REPO_ROOT/cache_ext/My-YCSB}"
PATCH_FILE="$EVO_DIR/patches/my_ycsb_disable_block_cache.patch"
TARGET_FILE="$YCSB_DIR/leveldb/leveldb_client.cpp"
TWITTER_TRACES_DIR="${TWITTER_TRACES_DIR:-$REPO_ROOT/twitter-traces}"
TWITTER_CLUSTER="${TWITTER_CLUSTER:-17}"
PREBUILT_DB="$REPO_ROOT/leveldb_twitter_cluster${TWITTER_CLUSTER}_db"

INIT_BIN="$YCSB_DIR/build/init_leveldb"
RUN_BIN="$YCSB_DIR/build/run_leveldb"
COMPACT_SRC="$EVO_DIR/scripts/compact_leveldb.cpp"
COMPACT_BIN="$YCSB_DIR/build/compact_leveldb"
INIT_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_init.txt"
ORIG_BENCH_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench.txt"
RO_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench_readonly.txt"
RO_STAMP="$TWITTER_TRACES_DIR/.cluster${TWITTER_CLUSTER}_bench_readonly.stamp"

log() { echo "[twitter_leveldb_ro] $*"; }
err() { echo "[twitter_leveldb_ro] ERROR: $*" >&2; exit 1; }

# ---- check ----------------------------------------------------------------
do_check() {
    rc=0
    [[ -x "$INIT_BIN"   ]] || { log "missing $INIT_BIN — run: ./start_workers.sh --install-bench HOST..." >&2; rc=1; }
    [[ -x "$RUN_BIN"    ]] || { log "missing $RUN_BIN — run: ./start_workers.sh --install-bench HOST..." >&2; rc=1; }
    [[ -x "$COMPACT_BIN" ]] || { log "missing $COMPACT_BIN — run: setup.sh setup" >&2; rc=1; }
    if [[ -f "$TARGET_FILE" ]] && ! grep -q "EVO_CACHE_RO_PATCH" "$TARGET_FILE"; then
        log "My-YCSB block-cache patch not applied — run: setup.sh setup" >&2
        rc=1
    fi
    [[ -d "$TWITTER_TRACES_DIR" ]] || { log "missing $TWITTER_TRACES_DIR — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -f "$INIT_TRACE"       ]] || { log "missing $INIT_TRACE — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -f "$ORIG_BENCH_TRACE" ]] || { log "missing $ORIG_BENCH_TRACE — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -d "$PREBUILT_DB"      ]] || { log "missing $PREBUILT_DB — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    if [[ -f "$ORIG_BENCH_TRACE" ]]; then
        local want_stamp src_mtime
        src_mtime="$(stat -c %Y "$ORIG_BENCH_TRACE" 2>/dev/null || stat -f %m "$ORIG_BENCH_TRACE")"
        want_stamp="cluster${TWITTER_CLUSTER}-${src_mtime}"
        if [[ ! -f "$RO_TRACE" || ! -f "$RO_STAMP" || "$(cat "$RO_STAMP" 2>/dev/null)" != "$want_stamp" ]]; then
            log "read-only trace stale or missing at $RO_TRACE — run: setup.sh setup" >&2
            rc=1
        fi
    fi
    if [[ $rc -eq 0 ]]; then
        log "ready (cluster=${TWITTER_CLUSTER}, patched, filtered, compactor built)"
    fi
    exit $rc
}

# ---- setup ----------------------------------------------------------------
do_setup() {
    [[ -f "$PATCH_FILE"  ]] || err "patch file not found: $PATCH_FILE"
    [[ -f "$TARGET_FILE" ]] || err "My-YCSB not present at $YCSB_DIR — run start_workers.sh --install-bench first"

    # Per-invocation log dir so concurrent runs / cross-user runs don't trip
    # over fs.protected_regular in /tmp.
    local tmp
    tmp="$(mktemp -d -t evo-tlro-setup.XXXXXX)"
    trap 'rm -rf "$tmp"' RETURN

    if grep -q "EVO_CACHE_RO_PATCH" "$TARGET_FILE"; then
        log "patch already applied to $TARGET_FILE — skipping apply"
    else
        log "applying patch to $TARGET_FILE..."
        (cd "$YCSB_DIR" && patch -p1 --no-backup-if-mismatch < "$PATCH_FILE") \
            || err "patch failed — file may have drifted from expected layout"
        log "patch applied."
    fi

    log "rebuilding init_leveldb + run_leveldb..."
    (
        cd "$YCSB_DIR"
        cmake -B build -S . >"$tmp/cmake.log" 2>&1 \
            || { tail -40 "$tmp/cmake.log" >&2; err "cmake configure failed"; }
        cmake --build build --target init_leveldb run_leveldb -j \
            >"$tmp/build.log" 2>&1 \
            || { tail -40 "$tmp/build.log" >&2; err "cmake build failed"; }
    )
    log "rebuild OK — binaries at $YCSB_DIR/build/{init,run}_leveldb"

    [[ -f "$COMPACT_SRC" ]] || err "missing $COMPACT_SRC"
    log "building compact_leveldb..."
    if g++ -O2 -std=c++17 -o "$COMPACT_BIN" "$COMPACT_SRC" \
           -lleveldb -lpthread -lsnappy >"$tmp/compact.log" 2>&1; then
        log "compact_leveldb at $COMPACT_BIN"
    else
        tail -40 "$tmp/compact.log" >&2
        err "compact_leveldb build failed (need libleveldb.a in /usr/local/lib)"
    fi

    if [[ ! -f "$ORIG_BENCH_TRACE" ]]; then
        log "bench trace $ORIG_BENCH_TRACE not present — skipping trace filter"
        log "(run start_workers.sh --download-dbs first if you need it)"
        exit 0
    fi

    local src_mtime want_stamp src_lines ro_lines pct
    src_mtime="$(stat -c %Y "$ORIG_BENCH_TRACE")"
    want_stamp="cluster${TWITTER_CLUSTER}-${src_mtime}"
    if [[ -f "$RO_TRACE" && -f "$RO_STAMP" && "$(cat "$RO_STAMP")" == "$want_stamp" ]]; then
        src_lines=$(wc -l < "$ORIG_BENCH_TRACE")
        ro_lines=$(wc -l < "$RO_TRACE")
        log "read-only trace already current: $RO_TRACE ($ro_lines / $src_lines get lines)"
    else
        log "filtering bench trace to get-only ops at $RO_TRACE..."
        grep '^get ' "$ORIG_BENCH_TRACE" > "$RO_TRACE.tmp"
        mv "$RO_TRACE.tmp" "$RO_TRACE"
        echo "$want_stamp" > "$RO_STAMP"
        src_lines=$(wc -l < "$ORIG_BENCH_TRACE")
        ro_lines=$(wc -l < "$RO_TRACE")
        pct=$(( ro_lines * 100 / (src_lines == 0 ? 1 : src_lines) ))
        log "wrote $ro_lines get ops ($pct% of $src_lines total) to $RO_TRACE"
    fi
    log "Done."
}

cmd="${1:-help}"
case "$cmd" in
    check) do_check ;;
    setup) do_setup ;;
    -h|--help|help|"")
        echo "usage: $0 {check|setup}"
        exit 0
        ;;
    *)
        echo "usage: $0 {check|setup}" >&2
        exit 2
        ;;
esac
