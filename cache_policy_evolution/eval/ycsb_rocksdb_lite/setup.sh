#!/usr/bin/env bash
# Per-workload setup for ycsb_rocksdb_lite.
#
# RocksDB and its My-YCSB client are NOT built by start_workers.sh
# --install-bench (that flag's targets are init_leveldb / run_leveldb).
# This script builds init_rocksdb / run_rocksdb on top of the same
# yaml-cpp + My-YCSB skeleton.
#
# Subcommands:
#   check  — verify init_rocksdb + run_rocksdb are built
#   setup  — cmake + build the rocksdb targets (idempotent)
#
# Tunables (env, all optional):
#   YCSB_DIR  My-YCSB checkout (default: $REPO_ROOT/cache_ext/My-YCSB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
YCSB_DIR="${YCSB_DIR:-$REPO_ROOT/cache_ext/My-YCSB}"
INIT_BIN="$YCSB_DIR/build/init_rocksdb"
RUN_BIN="$YCSB_DIR/build/run_rocksdb"

log() { echo "[ycsb_rocksdb_lite] $*"; }
err() { echo "[ycsb_rocksdb_lite] ERROR: $*" >&2; exit 1; }

cmd="${1:-help}"

case "$cmd" in
    check)
        rc=0
        [[ -d "$YCSB_DIR" ]] || { log "missing $YCSB_DIR — run: ./start_workers.sh --install-bench HOST..." >&2; rc=1; }
        [[ -x "$INIT_BIN" ]] || { log "missing $INIT_BIN — run: setup.sh setup" >&2; rc=1; }
        [[ -x "$RUN_BIN"  ]] || { log "missing $RUN_BIN — run: setup.sh setup" >&2; rc=1; }
        if [[ $rc -eq 0 ]]; then
            log "ready"
        fi
        exit $rc
        ;;
    setup)
        [[ -d "$YCSB_DIR" ]] || err "$YCSB_DIR missing — run start_workers.sh --install-bench first"
        # Per-invocation log dir; /tmp's fs.protected_regular blocks cross-user overwrites.
        tmp="$(mktemp -d -t evo-rocks-setup.XXXXXX)"
        trap 'rm -rf "$tmp"' EXIT
        log "building init_rocksdb + run_rocksdb (this can take several minutes)..."
        (
            cd "$YCSB_DIR"
            cmake -B build -S . >"$tmp/cmake.log" 2>&1 \
                || { tail -40 "$tmp/cmake.log" >&2; err "cmake configure failed"; }
            cmake --build build --target init_rocksdb run_rocksdb -j \
                >"$tmp/build.log" 2>&1 \
                || { tail -40 "$tmp/build.log" >&2; err "cmake build failed"; }
        )
        log "built: $INIT_BIN, $RUN_BIN"
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
