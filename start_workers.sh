#!/usr/bin/env bash
# start_workers.sh — provision + launch the evo-worker HTTP daemon on remote
# nodes.
#
# Model: coordinator (this machine) can SSH to every node, but the nodes
# themselves may NOT be able to SSH each other. SSH is used exclusively by
# this script (at provision time). At runtime the coordinator talks to
# workers over plain HTTP (see cache_policy_evolution/evolution/worker.py).
#
# Usage:
#   ./start_workers.sh host1 host2 host3
#   ./start_workers.sh $(./parse_ssh.sh "ssh aanil3@host1" "ssh aanil3@host2")
#
# Options:
#   --user <user>       SSH user                (default: aanil3)
#   --ssh-key <path>    SSH key                 (default: ~/.ssh/id_ed25519)
#   --base-dir <path>   Repo parent on remote   (default: ~)
#   --port <port>       Worker listen port      (default: 8080)
#   --token <str>       Shared auth token; passed as X-Auth-Token by clients
#   --git-pull          Run `git pull` on each worker before (re)starting
#   --stop              Kill running workers instead of starting
#   --status            Just check /health on each host
#   --install-bench     One-shot install of the DB benchmark stack on each
#                       worker: apt deps, yaml-cpp from source, leveldb
#                       (cache_ext fork), and My-YCSB build. ~10–15 min/host.
#                       Idempotent — re-runs are mostly no-ops.
#   --download-dbs      Pull Twitter trace files + pre-built LevelDB cluster
#                       DBs from the cache_ext paper's public GCS bucket.
#                       Bucket stores .tar.zst archives (download_dbs.sh in
#                       cache_ext is broken — it expects directory paths
#                       that don't exist), so this flag downloads + extracts
#                       directly via curl + tar. Override which clusters with
#                       TWITTER_CLUSTERS="17 18 24" (default: 17).
#                       Runtime depends on network (~1–10 min/host).
#   --rebuild-leveldb   Rebuild My-YCSB's init_leveldb + run_leveldb only
#                       (fast — assumes --install-bench already ran once).
#   --run CMD           Run an arbitrary shell command on each worker (with
#                       the worker's repo dir as cwd) and exit. Output is
#                       streamed per-host. Use single quotes to keep $vars
#                       from expanding locally.
#   --cwd <path>        Override the cwd used by --run (default: the worker's
#                       cache_policy_evolution dir). Pass an absolute path or
#                       one relative to the remote $HOME.
#
# Examples:
#   # First-time DB stack bringup (slow, once per node):
#   ./start_workers.sh --install-bench h1 h2 h3
#
#   # Pull repo and rebuild leveldb runners (fast, after code changes):
#   ./start_workers.sh --git-pull --rebuild-leveldb h1 h2 h3
#
#   # Generic shell command:
#   ./start_workers.sh --run 'df -h /mydata' h1 h2 h3
#   ./start_workers.sh --run 'ls /mydata/twitter-traces' h1 h2 h3

set -euo pipefail

SSH_USER="aanil3"
SSH_KEY="$HOME/.ssh/id_ed25519"
BASE_DIR="/mydata"
PORT="8080"
TOKEN=""
GIT_PULL=false
STOP=false
STATUS=false
REBUILD_LEVELDB=false
INSTALL_BENCH=false
DOWNLOAD_DBS=false
EXEC_CMD=""
EXEC_CWD=""
HOSTS=()

RED='\033[0;31m'; GRN='\033[0;32m'; BLU='\033[0;34m'; YLW='\033[0;33m'; NC='\033[0m'
log() { echo -e "${BLU}[$(date +%H:%M:%S)]${NC} $*"; }
ok()  { echo -e "${GRN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn(){ echo -e "${YLW}[$(date +%H:%M:%S)] !${NC} $*"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      SSH_USER="$2"; shift 2 ;;
        --ssh-key)   SSH_KEY="$2"; shift 2 ;;
        --base-dir)  BASE_DIR="$2"; shift 2 ;;
        --port)      PORT="$2"; shift 2 ;;
        --token)     TOKEN="$2"; shift 2 ;;
        --git-pull)  GIT_PULL=true; shift ;;
        --stop)      STOP=true; shift ;;
        --status)    STATUS=true; shift ;;
        --rebuild-leveldb) REBUILD_LEVELDB=true; shift ;;
        --install-bench)   INSTALL_BENCH=true; shift ;;
        --download-dbs)    DOWNLOAD_DBS=true; shift ;;
        --run)       EXEC_CMD="$2"; shift 2 ;;
        --cwd)       EXEC_CWD="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        -*)          err "unknown flag: $1"; usage; exit 1 ;;
        *)           HOSTS+=("$1"); shift ;;
    esac
done

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    err "no hosts specified"
    usage
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY")
REPO_DIR="${BASE_DIR}/evo_cache"
WORKER_DIR="${REPO_DIR}/cache_policy_evolution"
SCRIPT="worker_server.py"
LOG_PATH="/tmp/evo-worker.log"
PID_FILE="/tmp/evo-worker.pid"

run_remote() {
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" "$2"
}

# ---- STATUS ---------------------------------------------------------------
if $STATUS; then
    log "Checking /health on ${#HOSTS[@]} host(s)..."
    for h in "${HOSTS[@]}"; do
        {
            if curl -s --max-time 5 "http://${h}:${PORT}/health" | grep -q '"ok"'; then
                ok "[$h] healthy"
            else
                err "[$h] no response on :${PORT}"
            fi
        } &
    done
    wait
    exit 0
fi

# ---- GENERIC --run --------------------------------------------------------
if [[ -n "$EXEC_CMD" ]]; then
    RUN_CWD="${EXEC_CWD:-$WORKER_DIR}"
    log "Running on ${#HOSTS[@]} host(s) [cwd=${RUN_CWD}]: $EXEC_CMD"
    rc=0
    for h in "${HOSTS[@]}"; do
        {
            if run_remote "$h" "cd ${RUN_CWD} && $EXEC_CMD"; then
                ok "[$h] done"
            else
                err "[$h] FAILED"
                rc=1
            fi
        }
    done
    exit "$rc"
fi

# ---- INSTALL DB BENCH STACK (one-shot per worker) -------------------------
# Sets up everything My-YCSB needs to build init_leveldb / run_leveldb:
#   apt: build-essential cmake unzip libsnappy-dev pkg-config
#   yaml-cpp 0.8.0: built from upstream tarball (~1 min)
#   leveldb: cache_ext's fork via cache_ext/install_leveldb.sh
#   My-YCSB: build leveldb-latency branch's init_leveldb + run_leveldb
# Idempotent — apt is fast, yaml-cpp/leveldb skip if already installed,
# My-YCSB just rebuilds. ~10–15 min on first run, ~1 min thereafter.
if $INSTALL_BENCH; then
    log "Installing DB bench stack on ${#HOSTS[@]} host(s)..."
    YCSB_DIR="${REPO_DIR}/cache_ext/My-YCSB"
    INSTALL_CMD='set -euo pipefail
        REPO='"$REPO_DIR"'
        YCSB='"$YCSB_DIR"'
        cd "$REPO" && git pull --ff-only || true

        # APT deps. Quiet but verbose enough to diagnose failures.
        if ! command -v cmake >/dev/null || ! dpkg -s libsnappy-dev >/dev/null 2>&1 \
             || ! command -v zstd >/dev/null; then
            sudo -n apt-get update -qq
            sudo -n apt-get install -y -qq \
                build-essential cmake unzip libsnappy-dev pkg-config wget git zstd
        fi

        # yaml-cpp 0.8.0 from source (matches install_ycsb.sh).
        if [[ ! -f /usr/local/include/yaml-cpp/yaml.h ]]; then
            cd /tmp
            [[ -f yaml-cpp-0.8.0.zip ]] || \
                wget -q -O yaml-cpp-0.8.0.zip \
                    https://github.com/jbeder/yaml-cpp/archive/refs/tags/0.8.0.zip
            rm -rf yaml-cpp-0.8.0
            unzip -q yaml-cpp-0.8.0.zip
            cd yaml-cpp-0.8.0
            cmake -B build -S . -DYAML_BUILD_SHARED_LIBS=ON \
                  >/tmp/yaml-cpp-cmake.log 2>&1
            cmake --build build -j >/tmp/yaml-cpp-build.log 2>&1
            sudo -n cmake --install build >/tmp/yaml-cpp-install.log 2>&1
            sudo -n ldconfig
        fi

        # LevelDB (cache_ext fork). install_leveldb.sh builds + installs.
        if [[ ! -f /usr/local/lib/libleveldb.so && ! -f /usr/local/lib/libleveldb.a ]]; then
            cd "$REPO/cache_ext"
            bash install_leveldb.sh >/tmp/leveldb-install.log 2>&1
            sudo -n ldconfig
        fi

        # My-YCSB submodule + build init_leveldb + run_leveldb.
        cd "$YCSB"
        if [[ ! -f CMakeLists.txt ]]; then
            (cd "$REPO/cache_ext" && git submodule update --init -- My-YCSB)
        fi
        # Match the cache_ext eval/twitter/run.sh: leveldb-latency branch.
        git checkout leveldb-latency 2>/dev/null || true
        cmake -B build -S . >/tmp/ycsb-cmake.log 2>&1
        cmake --build build --target init_leveldb run_leveldb -j \
            >/tmp/ycsb-build.log 2>&1
        ls -la build/init_leveldb build/run_leveldb
        echo "OK"
    '
    for h in "${HOSTS[@]}"; do
        {
            log "[$h] installing (this can take 10–15 min on first run)..."
            if run_remote "$h" "$INSTALL_CMD"; then
                ok "[$h] bench stack ready"
            else
                err "[$h] install failed — check /tmp/{yaml-cpp-*,leveldb-install,ycsb-*}.log on host"
            fi
        } &
    done
    wait
    exit 0
fi

# ---- DOWNLOAD TWITTER TRACES + PREBUILT LEVELDB DBS ----------------------
# Wraps cache_ext/download_dbs.sh, which uses rclone against the cache_ext
# paper's public GCS bucket (anonymous access). Pulls:
#   /mydata/twitter-traces/         (cluster17_init.txt etc.)
#   /mydata/leveldb_twitter_cluster${N}_db/  for N in 17 18 24 34 52
# These are big (multi-GB total). The runner skips init_leveldb when the
# pre-built DB is present.
if $DOWNLOAD_DBS; then
    # Which clusters to fetch. Trace files for ALL clusters live in a single
    # twitter-traces.tar.zst, so we always grab that. Per-cluster DBs are
    # separate tarballs — we fetch only the ones requested.
    CLUSTERS="${TWITTER_CLUSTERS:-17}"
    log "Downloading Twitter traces + LevelDB DBs (clusters: ${CLUSTERS}) on ${#HOSTS[@]} host(s)..."
    DOWNLOAD_CMD='set -euo pipefail
        REPO='"$REPO_DIR"'
        CLUSTERS="'"$CLUSTERS"'"
        BUCKET_URL="https://storage.googleapis.com/cache-ext-artifact-data"
        DEST="$REPO"
        cd "$DEST"

        if ! command -v zstd >/dev/null; then
            sudo -n apt-get update -qq
            sudo -n apt-get install -y -qq zstd
        fi

        # Twitter trace files (shared across clusters). ~few GB.
        if [[ ! -d "$DEST/twitter-traces" ]]; then
            echo "Fetching twitter-traces.tar.zst..."
            curl -fL --retry 3 -o /tmp/twitter-traces.tar.zst \
                "$BUCKET_URL/twitter-traces.tar.zst"
            tar -I zstd -xf /tmp/twitter-traces.tar.zst -C "$DEST"
            rm -f /tmp/twitter-traces.tar.zst
        else
            echo "twitter-traces already present, skipping"
        fi

        # Per-cluster pre-built LevelDB DBs.
        for c in $CLUSTERS; do
            db_dir="$DEST/leveldb_twitter_cluster${c}_db"
            if [[ -d "$db_dir" && -n "$(ls -A "$db_dir" 2>/dev/null)" ]]; then
                echo "cluster${c} DB already present, skipping"
                continue
            fi
            echo "Fetching leveldb_twitter_cluster${c}_db.tar.zst..."
            curl -fL --retry 3 -o "/tmp/cluster${c}.tar.zst" \
                "$BUCKET_URL/leveldb_twitter_cluster${c}_db.tar.zst"
            tar -I zstd -xf "/tmp/cluster${c}.tar.zst" -C "$DEST"
            rm -f "/tmp/cluster${c}.tar.zst"
        done

        echo "--- contents ---"
        ls "$DEST/twitter-traces" | head -5
        ls -d "$DEST"/leveldb_twitter_cluster*_db
    '
    for h in "${HOSTS[@]}"; do
        {
            log "[$h] downloading..."
            if run_remote "$h" "$DOWNLOAD_CMD" 2>&1 | sed "s/^/[$h] /"; then
                ok "[$h] DBs + traces ready"
            else
                err "[$h] download failed"
            fi
        } &
    done
    wait
    exit 0
fi

# ---- REBUILD MY-YCSB LEVELDB RUNNERS (fast path) -------------------------
# Use after --install-bench has run once and you've changed something in
# this repo or My-YCSB. Just rebuilds init_leveldb + run_leveldb.
if $REBUILD_LEVELDB; then
    log "Rebuilding My-YCSB leveldb on ${#HOSTS[@]} host(s)..."
    YCSB_DIR="${REPO_DIR}/cache_ext/My-YCSB"
    BUILD_CMD="set -euo pipefail; \
        cd ${REPO_DIR} && git pull --ff-only || true; \
        cd ${YCSB_DIR} && \
        cmake -B build -S . >/tmp/ycsb-cmake.log 2>&1 && \
        cmake --build build --target init_leveldb run_leveldb -j \
            >/tmp/ycsb-build.log 2>&1 && \
        ls -la build/init_leveldb build/run_leveldb"
    for h in "${HOSTS[@]}"; do
        {
            log "[$h] building..."
            if run_remote "$h" "$BUILD_CMD"; then
                ok "[$h] init_leveldb + run_leveldb built"
            else
                err "[$h] build failed — tail /tmp/ycsb-{cmake,build}.log on host"
            fi
        } &
    done
    wait
    exit 0
fi

# ---- STOP -----------------------------------------------------------------
if $STOP; then
    log "Stopping workers on ${#HOSTS[@]} host(s)..."
    for h in "${HOSTS[@]}"; do
        {
            run_remote "$h" "sudo -n pkill -f 'python3 ${SCRIPT}' || true" || true
            ok "[$h] stopped"
        } &
    done
    wait
    exit 0
fi

# ---- START ----------------------------------------------------------------
log "Starting evo-worker on ${#HOSTS[@]} host(s) (port ${PORT})..."
[[ -n "$TOKEN" ]] && log "Using shared auth token (length=${#TOKEN})"

TOKEN_EXPORT=""
if [[ -n "$TOKEN" ]]; then
    TOKEN_EXPORT="EVO_WORKER_TOKEN=$(printf '%q' "$TOKEN") "
fi

start_one() {
    local h="$1"
    log "[$h] preparing..."

    if $GIT_PULL; then
        if ! run_remote "$h" "cd ${REPO_DIR} && git pull --ff-only"; then
            warn "[$h] git pull failed (continuing)"
        fi
    fi

    # Sanity check.
    if ! run_remote "$h" "test -f ${WORKER_DIR}/${SCRIPT}"; then
        err "[$h] ${WORKER_DIR}/${SCRIPT} missing — is the repo cloned?"
        return
    fi
    if ! run_remote "$h" "command -v python3 >/dev/null"; then
        err "[$h] python3 missing"
        return
    fi
    # Worker needs passwordless sudo (drop_caches, cgroup writes, BPF attach).
    if ! run_remote "$h" "sudo -n true 2>/dev/null"; then
        err "[$h] passwordless sudo not available for ${SSH_USER} — worker cannot run"
        return
    fi

    # Stop any previous instance. Prior workers ran as root, so pkill needs sudo.
    run_remote "$h" "sudo -n pkill -f 'python3 ${SCRIPT}' || true; sleep 0.3" || true

    # Launch detached via nohup. Worker MUST run as root: benchmark writes
    # /proc/sys/vm/drop_caches, creates/configures cgroups, and attaches BPF
    # struct_ops — all need CAP_SYS_ADMIN. We don't record a PID file; stop
    # uses `sudo pkill -f` which is the robust option anyway.
    #
    # Redirect outer bash's fds away from the SSH channel BEFORE backgrounding.
    # Without this, the backgrounded child inherits sshd pipes via the subshell,
    # and SSH refuses to close the session until the child exits.
    local LAUNCH="exec </dev/null >${LOG_PATH} 2>&1; cd ${WORKER_DIR} && sudo -n -E ${TOKEN_EXPORT}nohup python3 ${SCRIPT} --port ${PORT} &"
    if ! run_remote "$h" "$LAUNCH"; then
        err "[$h] failed to launch"
        return
    fi

    # Poll /health for up to ~15s — worker may take a moment to bind.
    local i
    for i in $(seq 1 30); do
        if curl -s --max-time 2 "http://${h}:${PORT}/health" 2>/dev/null | grep -q '"ok"'; then
            ok "[$h] up  →  http://${h}:${PORT}"
            return
        fi
        sleep 0.5
    done
    err "[$h] did not respond on :${PORT} after 15s — check ${LOG_PATH} on host"
}

for h in "${HOSTS[@]}"; do
    start_one "$h" &
done
wait

# ---- Hint for the coordinator TOML ---------------------------------------
echo
log "Worker URLs for scan_thrash.toml:"
printf '    workers = [\n'
for h in "${HOSTS[@]}"; do
    printf '        "http://%s:%s",\n' "$h" "$PORT"
done
printf '    ]\n'
