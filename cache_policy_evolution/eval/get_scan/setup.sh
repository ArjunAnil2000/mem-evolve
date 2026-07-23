#!/usr/bin/env bash
# Per-workload setup for get_scan (GET-SCAN over LevelDB, cache_ext paper
# Figure 8).
#
# Needs a DIFFERENT My-YCSB branch (leveldb-scan) than twitter_leveldb uses
# (leveldb-latency) — the two aren't compatible in the same checkout, so
# this workload gets its own separate My-YCSB clone rather than reusing
# cache_ext/My-YCSB or start_workers.sh's --install-bench flow (which only
# knows about the leveldb-latency branch). Shared native deps (yaml-cpp,
# the cache_ext LevelDB fork) ARE reused if --install-bench already
# installed them; this script only installs what's missing.
#
# scan_pids mechanism (why ENABLE_BPF_SCAN_MAP exists — see
# run_with_policy.sh): the leveldb-scan branch's core/worker.cpp hardcodes
# exactly one dedicated scan-only worker thread (scan_worker_count = 1).
# On that thread's first scan op, core/workload.cpp calls SYS_gettid and,
# iff $ENABLE_BPF_SCAN_MAP is set, bpf_obj_get()s the pinned map at
# /sys/fs/bpf/cache_ext/scan_pids and writes {tid: 1} into it via a raw
# bpf_map_update_elem — this is policy-agnostic (keyed purely by the pinned
# path, not by which BPF skeleton owns the map). run_with_policy.sh
# exploits exactly this: it creates and pins that map itself (via bpftool)
# before any policy loader starts, so the map's existence never depends on
# which seed is attached — every seed sees the identical environment. A
# seed that wants the ground-truth signal attaches to that SAME map via
# bpf_obj_get() + bpf_map__reuse_fd() in its own loader (see
# vulcan_scan_class.c) instead of creating/pinning its own.
# Confirmed by reading My-YCSB @ leveldb-scan branch commit de95ae5
# (core/workload.cpp, core/worker.cpp) directly.
#
# Subcommands:
#   check  — verify everything this benchmark needs is present
#   setup  — install shared deps if missing + build the leveldb-scan checkout
#
# Tunables (env, all optional):
#   YCSB_SCAN_DIR     separate My-YCSB checkout for this branch
#                      (default $REPO_ROOT/cache_ext/My-YCSB-scan)
#   YCSB_SCAN_URL      (default https://github.com/xrp-project/My-YCSB.git)
#   YCSB_SCAN_BRANCH   (default leveldb-scan)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
YCSB_SCAN_DIR="${YCSB_SCAN_DIR:-$REPO_ROOT/cache_ext/My-YCSB-scan}"
YCSB_SCAN_URL="${YCSB_SCAN_URL:-https://github.com/xrp-project/My-YCSB.git}"
YCSB_SCAN_BRANCH="${YCSB_SCAN_BRANCH:-leveldb-scan}"

INIT_BIN="$YCSB_SCAN_DIR/build/init_leveldb"
RUN_BIN="$YCSB_SCAN_DIR/build/run_leveldb"

cmd="${1:-help}"

do_check() {
    rc=0
    command -v cmake >/dev/null || { echo "[get_scan] missing cmake" >&2; rc=1; }
    command -v bpftool >/dev/null || { echo "[get_scan] missing bpftool — needed for ENABLE_BPF_SCAN_MAP (default on)" >&2; rc=1; }
    [[ -f /usr/local/include/yaml-cpp/yaml.h ]] || { echo "[get_scan] missing yaml-cpp — run: ./start_workers.sh --install-bench HOST... (shared dep)" >&2; rc=1; }
    [[ -f /usr/local/lib/libleveldb.so || -f /usr/local/lib/libleveldb.a ]] || { echo "[get_scan] missing libleveldb — run: ./start_workers.sh --install-bench HOST... (shared dep)" >&2; rc=1; }
    [[ -x "$INIT_BIN" ]] || { echo "[get_scan] missing $INIT_BIN — run: eval/get_scan/setup.sh setup" >&2; rc=1; }
    [[ -x "$RUN_BIN"  ]] || { echo "[get_scan] missing $RUN_BIN — run: eval/get_scan/setup.sh setup" >&2; rc=1; }
    if [[ $rc -eq 0 ]]; then
        echo "[get_scan] ready ($YCSB_SCAN_DIR @ $YCSB_SCAN_BRANCH)"
    fi
    exit $rc
}

do_setup() {
    echo "[get_scan] checking base build toolchain..."
    if ! command -v cmake >/dev/null || ! dpkg -s libsnappy-dev >/dev/null 2>&1 \
         || ! command -v zstd >/dev/null || ! command -v bpftool >/dev/null; then
        # Mirrors start_workers.sh's --install-bench apt list. bpftool
        # isn't in that list (it's a cache_ext kernel-build artifact,
        # normally already present) — check but don't try to apt-install
        # it here if missing; that means install_kernel.sh hasn't run.
        command -v bpftool >/dev/null || echo "[get_scan] WARNING: bpftool missing — was install_kernel.sh run on this host?"
        sudo -n apt-get update -qq
        sudo -n apt-get install -y -qq \
            build-essential cmake unzip libsnappy-dev pkg-config wget git zstd
        echo "[get_scan] base toolchain installed"
    fi

    echo "[get_scan] checking shared native deps (yaml-cpp, LevelDB fork)..."
    if [[ ! -f /usr/local/include/yaml-cpp/yaml.h ]]; then
        cd /tmp
        [[ -f yaml-cpp-0.8.0.zip ]] || \
            wget -q -O yaml-cpp-0.8.0.zip \
                https://github.com/jbeder/yaml-cpp/archive/refs/tags/0.8.0.zip
        rm -rf yaml-cpp-0.8.0
        unzip -q yaml-cpp-0.8.0.zip
        cd yaml-cpp-0.8.0
        cmake -B build -S . -DYAML_BUILD_SHARED_LIBS=ON >/tmp/yaml-cpp-cmake.log 2>&1
        cmake --build build -j >/tmp/yaml-cpp-build.log 2>&1
        sudo -n cmake --install build >/tmp/yaml-cpp-install.log 2>&1
        sudo -n ldconfig
        echo "[get_scan] yaml-cpp installed"
    fi
    if [[ ! -f /usr/local/lib/libleveldb.so && ! -f /usr/local/lib/libleveldb.a ]]; then
        (cd "$REPO_ROOT/cache_ext" && bash install_leveldb.sh) >/tmp/leveldb-install.log 2>&1
        sudo -n ldconfig
        echo "[get_scan] libleveldb installed"
    fi

    echo "[get_scan] checking out My-YCSB @ $YCSB_SCAN_BRANCH into $YCSB_SCAN_DIR..."
    if [[ ! -d "$YCSB_SCAN_DIR/.git" ]]; then
        git clone --quiet "$YCSB_SCAN_URL" "$YCSB_SCAN_DIR"
    fi
    (cd "$YCSB_SCAN_DIR" && git fetch --quiet origin "$YCSB_SCAN_BRANCH" \
        && git checkout --quiet "$YCSB_SCAN_BRANCH")

    echo "[get_scan] building init_leveldb + run_leveldb..."
    (cd "$YCSB_SCAN_DIR" \
        && cmake -B build -S . >/tmp/ycsb-scan-cmake.log 2>&1 \
        && cmake --build build --target init_leveldb run_leveldb -j \
               >/tmp/ycsb-scan-build.log 2>&1)
    ls -la "$INIT_BIN" "$RUN_BIN"
    echo "[get_scan] setup complete"
}

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
