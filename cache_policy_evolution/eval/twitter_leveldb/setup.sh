#!/usr/bin/env bash
# Per-workload setup for twitter_leveldb (read/write variant).
#
# Vanilla My-YCSB twitter_bench replays the original mixed-op trace as-is,
# no patches needed. Setup is purely a sanity check that the shared base
# stack (yaml-cpp + leveldb + My-YCSB binaries) and the Twitter trace +
# pre-built cluster DB downloaded.
#
# Subcommands:
#   check  — verify everything this benchmark needs is present
#   setup  — install workload-specific extras (none for this variant)
#
# Tunables (env, all optional):
#   TWITTER_TRACES_DIR  trace files dir (default /mydata/evo_cache/twitter-traces)
#   TWITTER_CLUSTER     cluster id (default 17)
#   YCSB_DIR            My-YCSB checkout (default $REPO_ROOT/cache_ext/My-YCSB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
YCSB_DIR="${YCSB_DIR:-$REPO_ROOT/cache_ext/My-YCSB}"
TWITTER_TRACES_DIR="${TWITTER_TRACES_DIR:-$REPO_ROOT/twitter-traces}"
TWITTER_CLUSTER="${TWITTER_CLUSTER:-17}"
PREBUILT_DB="$REPO_ROOT/leveldb_twitter_cluster${TWITTER_CLUSTER}_db"

INIT_BIN="$YCSB_DIR/build/init_leveldb"
RUN_BIN="$YCSB_DIR/build/run_leveldb"
INIT_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_init.txt"
BENCH_TRACE="$TWITTER_TRACES_DIR/cluster${TWITTER_CLUSTER}_bench.txt"

cmd="${1:-help}"

do_check() {
    rc=0
    [[ -x "$INIT_BIN" ]] || { echo "[twitter_leveldb] missing $INIT_BIN — run: ./start_workers.sh --install-bench HOST..." >&2; rc=1; }
    [[ -x "$RUN_BIN"  ]] || { echo "[twitter_leveldb] missing $RUN_BIN — run: ./start_workers.sh --install-bench HOST..." >&2; rc=1; }
    [[ -d "$TWITTER_TRACES_DIR" ]] || { echo "[twitter_leveldb] missing $TWITTER_TRACES_DIR — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -f "$INIT_TRACE"  ]] || { echo "[twitter_leveldb] missing $INIT_TRACE  — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -f "$BENCH_TRACE" ]] || { echo "[twitter_leveldb] missing $BENCH_TRACE — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    [[ -d "$PREBUILT_DB" ]] || { echo "[twitter_leveldb] missing $PREBUILT_DB — run: ./start_workers.sh --download-dbs HOST..." >&2; rc=1; }
    if [[ $rc -eq 0 ]]; then
        echo "[twitter_leveldb] ready (cluster=${TWITTER_CLUSTER}, prebuilt DB)"
    fi
    exit $rc
}

case "$cmd" in
    check) do_check ;;
    setup)
        echo "[twitter_leveldb] no extra setup beyond --install-bench / --download-dbs"
        ;;
    -h|--help|help|"")
        echo "usage: $0 {check|setup}"
        exit 0
        ;;
    *)
        echo "usage: $0 {check|setup}" >&2
        exit 2
        ;;
esac
