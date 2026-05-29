#!/usr/bin/env bash
# Per-workload setup for scan_thrash.
#
# scan_thrash generates its own data files at runtime (dd if=/dev/urandom),
# so there's nothing workload-specific to install. This script exists so
# every eval directory follows the same setup.sh {check|setup} contract
# evolve.py / worker_server.py expect.
#
# Subcommands:
#   check  — verify the worker can run this benchmark (read-only)
#   setup  — install/configure anything missing (idempotent; no-op here)

set -euo pipefail

cmd="${1:-help}"

case "$cmd" in
    check)
        rc=0
        if [[ ! -d /sys/fs/cgroup ]]; then
            echo "[scan_thrash] cgroup-v2 not mounted at /sys/fs/cgroup" >&2
            rc=1
        fi
        if ! uname -r | grep -q cache-ext; then
            echo "[scan_thrash] WARN: kernel does not look like cache-ext: $(uname -r)" >&2
        fi
        if [[ $rc -eq 0 ]]; then
            echo "[scan_thrash] ready"
        fi
        exit $rc
        ;;
    setup)
        echo "[scan_thrash] no setup required (data is generated at runtime)"
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
