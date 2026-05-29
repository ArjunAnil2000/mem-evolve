#!/usr/bin/env bash
# setup_cloudlab.sh — Initialize CloudLab machines for evo_cache
#
# Usage:
#   ./setup_cloudlab.sh --pat <GITHUB_PAT> node0.foo.emulab.net node1.foo.emulab.net ...
#   ./setup_cloudlab.sh --update node0 node1 ...          # just git-pull on each host
#
# Options:
#   --pat <token>       GitHub personal access token (required unless --update)
#   --user <user>       SSH user (default: ddesai)
#   --ssh-key <path>    SSH key path (default: ~/.ssh/id_rsa)
#   --skip-reboot       Skip kernel install + reboot (for already-rebooted machines)
#   --dry-run           Print commands without executing
#   --base-dir <path>   Base directory on remote machines (default: ~)
#   --verbose           Log every remote command before running it
#   --serial            Run kernel install (phase 2) serially across hosts
#                       (default: parallel). --parallel is still accepted as a
#                       no-op for backwards compat.
#   --workers-only      Only run post-reboot setup (install_filesearch, etc.)
#   --update            Fast-forward git pull the repo on each host and update
#                       submodules. Skips clone/kernel/reboot/setup. Use when
#                       you've pushed coordinator-side code changes and the
#                       kernel on each worker is already good.
#
# The script will:
#   1. Clone the repo on each machine
#   2. Initialize cache_ext submodule + install kernel
#   3. Reboot into the custom kernel
#   4. Wait for machines to come back up
#   5. Run post-reboot setup scripts

set -euo pipefail

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
PAT=""
SSH_USER="ddesai"
SSH_KEY="$HOME/.ssh/id_rsa"
SKIP_REBOOT=false
DRY_RUN=false
VERBOSE=false
PARALLEL=true
WORKERS_ONLY=false
UPDATE_ONLY=false
HOSTS=()
POLL_INTERVAL=15
POLL_TIMEOUT=600  # 10 minutes max wait for reboot
BASE_DIR="/mydata"
REPO_DIR=""  # derived after arg parsing

# ------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; }
verb() { $VERBOSE && echo -e "${MAGENTA}[$(date +%H:%M:%S)] ▶${NC} $*" || true; }

# ------------------------------------------------------------------
# Parse args
# ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pat)          PAT="$2"; shift 2 ;;
        --user)         SSH_USER="$2"; shift 2 ;;
        --ssh-key)      SSH_KEY="$2"; shift 2 ;;
        --base-dir)     BASE_DIR="$2"; shift 2 ;;
        --skip-reboot)  SKIP_REBOOT=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --verbose|-v)   VERBOSE=true; shift ;;
        --parallel|-p)  PARALLEL=true; shift ;;   # default; kept for compat
        --serial)       PARALLEL=false; shift ;;
        --workers-only) WORKERS_ONLY=true; shift ;;
        --update)       UPDATE_ONLY=true; shift ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        -*)
            err "Unknown flag: $1"; exit 1 ;;
        *)
            HOSTS+=("$1"); shift ;;
    esac
done

if [[ -z "$PAT" ]] && ! $UPDATE_ONLY; then
    err "GitHub PAT is required. Use --pat <token>  (not needed for --update)"
    exit 1
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    err "No hosts specified. Pass hostnames as positional arguments."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"
REPO_DIR="${BASE_DIR}/evo_cache"

log "Machines: ${HOSTS[*]}"
log "SSH user: $SSH_USER"
log "Base dir: $BASE_DIR"
log "Repo dir: $REPO_DIR"

# ------------------------------------------------------------------
# Helper: run command on remote host
# ------------------------------------------------------------------
run_remote() {
    local host="$1"
    shift
    local cmd="$*"

    if $DRY_RUN; then
        echo "  [DRY RUN] ssh $SSH_USER@$host: $cmd"
        return 0
    fi

    verb "[$host] ssh $SSH_USER@$host $cmd"

    local rc=0
    if $VERBOSE; then
        # Stream stdout and stderr in real-time, prefixed with hostname
        # Disable errexit so a non-zero ssh doesn't abort before we capture rc
        # shellcheck disable=SC2086
        set +eo pipefail
        ssh $SSH_OPTS "$SSH_USER@$host" "$cmd" 2>&1 \
            | sed -u "s/^/  [$host] /"
        rc=${PIPESTATUS[0]}
        set -eo pipefail
    else
        # shellcheck disable=SC2086
        ssh $SSH_OPTS "$SSH_USER@$host" "$cmd" 2>&1 || rc=$?
    fi

    if $VERBOSE && [[ $rc -ne 0 ]]; then
        err "[$host] Exit code: $rc"
    fi

    return $rc
}

# ------------------------------------------------------------------
# Helper: check if host is reachable via SSH
# ------------------------------------------------------------------
is_reachable() {
    local host="$1"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_USER@$host" "echo ok" &>/dev/null
}

# ------------------------------------------------------------------
# Phase 1: Clone repo + submodules + kernel install
# ------------------------------------------------------------------
phase1_setup() {
    local host="$1"
    log "[$host] Phase 1: Clone repo + init submodules"

    # Fix ownership — CloudLab mounts /mydata owned by root. Make it writable
    # by $SSH_USER so git clone + all downstream installs don't need sudo.
    run_remote "$host" "
        sudo mkdir -p $BASE_DIR &&
        sudo chown -R $SSH_USER $BASE_DIR &&
        sudo chmod 755 $BASE_DIR
    "

    # Clone repo
    run_remote "$host" "
        if [ -d '$REPO_DIR/.git' ]; then
            echo 'Repo already exists, pulling latest...'
            cd $REPO_DIR && git pull
        else
            git clone https://1611Dhruv:${PAT}@github.com/1611Dhruv/evo_cache $REPO_DIR
        fi
    "

    # Init submodules (cache_ext is itself a submodule)
    run_remote "$host" "
        cd $REPO_DIR && git submodule update --init --recursive
    "

    ok "[$host] Repo cloned and submodules initialized"
}

# ------------------------------------------------------------------
# Phase 2: Install kernel + reboot
# ------------------------------------------------------------------
phase2_kernel() {
    local host="$1"
    log "[$host] Phase 2: Install cache_ext kernel"

    # Auto-answer kernel install prompts: 1, Y, 1, N
    run_remote "$host" "
        cd $REPO_DIR/cache_ext && printf '1\nY\n1\nN\n' | bash ./install_kernel.sh
    "

    run_remote "$host" "
        sudo grub-reboot 'Advanced options for Ubuntu>Ubuntu, with Linux 6.6.8-cache-ext+'
    "

    ok "[$host] Kernel installed, rebooting..."
    run_remote "$host" "sudo reboot now" || true  # reboot kills the SSH session
}

# ------------------------------------------------------------------
# Phase 3: Wait for machines to come back up
# ------------------------------------------------------------------
wait_for_hosts() {
    local -a waiting=("$@")
    local start_time
    start_time=$(date +%s)

    log "Waiting for ${#waiting[@]} machines to come back online (polling every ${POLL_INTERVAL}s, timeout ${POLL_TIMEOUT}s)..."

    while [[ ${#waiting[@]} -gt 0 ]]; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $POLL_TIMEOUT ]]; then
            err "Timeout waiting for: ${waiting[*]}"
            return 1
        fi

        local still_waiting=()
        for host in "${waiting[@]}"; do
            if is_reachable "$host"; then
                ok "[$host] Back online (${elapsed}s)"
            else
                still_waiting+=("$host")
            fi
        done

        waiting=("${still_waiting[@]+"${still_waiting[@]}"}")

        if [[ ${#waiting[@]} -gt 0 ]]; then
            log "Still waiting for ${#waiting[@]}: ${waiting[*]} (${elapsed}s elapsed)"
            sleep "$POLL_INTERVAL"
        fi
    done

    ok "All machines are back online"
}

# ------------------------------------------------------------------
# Phase 4: Post-reboot setup
# ------------------------------------------------------------------
phase4_post_reboot() {
    local host="$1"
    log "[$host] Phase 4: Post-reboot setup"

    # Verify we're running the right kernel
    local kernel
    kernel=$(run_remote "$host" "uname -r" 2>/dev/null || echo "unknown")
    log "[$host] Running kernel: $kernel"

    if [[ "$kernel" != *"cache-ext"* ]]; then
        warn "[$host] Kernel does not contain 'cache-ext': $kernel"
        warn "[$host] Proceeding anyway, but cache_ext may not work"
    fi

    # Install Python 3.11
    run_remote "$host" "
        sudo -A apt-get install -y software-properties-common &&
        sudo -A add-apt-repository -y ppa:deadsnakes/python &&
        sudo -A apt-get update &&
        sudo -A apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils
    "
    ok "[$host] Python 3.11 installed"

    run_remote "$host" "cd $REPO_DIR/cache_ext && bash ./install_filesearch.sh"
    ok "[$host] install_filesearch.sh done"

    run_remote "$host" "cd $REPO_DIR/cache_ext && bash ./install_misc.sh"
    ok "[$host] install_misc.sh done"

    run_remote "$host" "cd $REPO_DIR/cache_ext && bash ./setup_isolation.sh"
    ok "[$host] setup_isolation.sh done"

    run_remote "$host" "cd $REPO_DIR/cache_ext && bash ./build_policies.sh"
    ok "[$host] build_policies.sh done"

    ok "[$host] Phase 4 complete"
}

# ------------------------------------------------------------------
# Update: fast-forward git pull + submodule refresh. Assumes the repo is
# already cloned. Handy when only coordinator-side code has changed and the
# kernel/installed artifacts on workers are still good.
# ------------------------------------------------------------------
phase_update() {
    local host="$1"
    log "[$host] Update: git pull + submodule update"

    # Sanity check — bail loudly if the clone is missing so we don't silently
    # do nothing on a fresh node.
    if ! run_remote "$host" "test -d $REPO_DIR/.git"; then
        err "[$host] $REPO_DIR/.git missing — run without --update first to clone"
        return 1
    fi

    run_remote "$host" "
        cd $REPO_DIR &&
        git fetch --prune &&
        git pull --ff-only &&
        git submodule update --init --recursive
    "
    ok "[$host] updated to $(run_remote "$host" "cd $REPO_DIR && git rev-parse --short HEAD" 2>/dev/null | tail -1)"
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

if $UPDATE_ONLY; then
    log "=== Update-only mode: git pull on ${#HOSTS[@]} host(s) ==="
    for host in "${HOSTS[@]}"; do
        phase_update "$host" &
    done
    wait
    ok "=== All hosts updated ==="
    echo
    log "Hint: restart worker daemons to pick up worker_server.py changes:"
    echo "    ./start_workers.sh ${HOSTS[*]}"
    exit 0
fi

if $WORKERS_ONLY; then
    log "=== Workers-only mode: skipping clone/kernel/reboot ==="
    for host in "${HOSTS[@]}"; do
        phase4_post_reboot "$host" &
    done
    wait
    ok "=== All machines setup complete ==="
    exit 0
fi

# Phase 1: Clone in parallel
log "=== Phase 1: Cloning repos ==="
for host in "${HOSTS[@]}"; do
    phase1_setup "$host" &
done
wait
ok "=== Phase 1 complete ==="

if ! $SKIP_REBOOT; then
    # Phase 2: Install kernel + reboot
    log "=== Phase 2: Installing kernel + rebooting ==="
    if $PARALLEL; then
        for host in "${HOSTS[@]}"; do
            phase2_kernel "$host" &
        done
        wait
    else
        for host in "${HOSTS[@]}"; do
            phase2_kernel "$host"
        done
    fi
    ok "=== Phase 2 complete (all rebooting) ==="

    # Phase 3: Wait for all to come back
    log "=== Phase 3: Waiting for reboot ==="
    sleep 10  # give them a moment to actually go down
    wait_for_hosts "${HOSTS[@]}"
    ok "=== Phase 3 complete ==="
fi

# Phase 4: Post-reboot setup in parallel
log "=== Phase 4: Post-reboot setup ==="
for host in "${HOSTS[@]}"; do
    phase4_post_reboot "$host" &
done
wait
ok "=== All machines setup complete ==="

echo ""
log "Summary:"
for host in "${HOSTS[@]}"; do
    echo "  $host — ready"
done
