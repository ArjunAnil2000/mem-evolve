#!/usr/bin/env bash
# setup_main_node.sh — provision the coordinator (main) node:
#   1. fix /mydata ownership
#   2. clone the repo (if not already)
#   3. install Claude Code CLI via the official installer
#   4. install Python deps for coordinator + claude_api proxy
#   5. start the claude_api proxy in the background
#   6. drop you into an interactive SSH session on the host
#
# Usage:
#   ./setup_main_node.sh --pat <GITHUB_PAT> <host>
#
# Options:
#   --pat <token>       GitHub PAT (skip if repo already cloned on the node)
#   --user <user>       SSH user              (default: ddesai)
#   --ssh-key <path>    SSH key               (default: ~/.ssh/id_rsa)
#   --base-dir <path>   Install root          (default: /mydata)
#   --port <port>       claude_api port       (default: 8082)
#   --no-shell          Skip the final interactive ssh

set -euo pipefail

PAT=""
SSH_USER="ddesai"
SSH_KEY="$HOME/.ssh/id_rsa"
BASE_DIR="/mydata"
PORT="8082"
NO_SHELL=false
HOST=""

RED='\033[0;31m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLU}[$(date +%H:%M:%S)]${NC} $*"; }
ok()  { echo -e "${GRN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
err() { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pat)      PAT="$2"; shift 2 ;;
        --user)     SSH_USER="$2"; shift 2 ;;
        --ssh-key)  SSH_KEY="$2"; shift 2 ;;
        --base-dir) BASE_DIR="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --no-shell) NO_SHELL=true; shift ;;
        -h|--help)  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         err "unknown flag: $1"; exit 1 ;;
        *)          HOST="$1"; shift ;;
    esac
done

[[ -z "$HOST" ]] && { err "host required"; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY")
REPO_DIR="${BASE_DIR}/evo_cache"
PROXY_LOG="/tmp/claude_api.log"
PROXY_PID="/tmp/claude_api.pid"

run_remote() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$1"; }

# 1) Ownership on /mydata
log "[$HOST] fixing ${BASE_DIR} ownership"
run_remote "sudo mkdir -p ${BASE_DIR} && sudo chown -R ${SSH_USER} ${BASE_DIR} && sudo chmod 755 ${BASE_DIR}"
ok   "[$HOST] ${BASE_DIR} owned by ${SSH_USER}"

# 2) Clone repo (if missing)
if run_remote "test -d ${REPO_DIR}/.git"; then
    log "[$HOST] repo already present — pulling"
    run_remote "cd ${REPO_DIR} && git pull --ff-only && git submodule update --init --recursive"
else
    [[ -z "$PAT" ]] && { err "repo missing and --pat not given"; exit 1; }
    log "[$HOST] cloning repo"
    run_remote "git clone https://1611Dhruv:${PAT}@github.com/1611Dhruv/evo_cache ${REPO_DIR} && cd ${REPO_DIR} && git submodule update --init --recursive"
fi
ok   "[$HOST] repo ready at ${REPO_DIR}"

# 3) Claude Code CLI (official installer)
log "[$HOST] installing Claude Code CLI"
run_remote "bash -lc '
    set -e
    if ! command -v claude >/dev/null 2>&1; then
        curl -fsSL https://claude.ai/install.sh | bash
    fi
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    claude --version
'"
ok   "[$HOST] Claude Code installed"

# 4) Python deps
log "[$HOST] installing Python deps"
run_remote "
    cd ${REPO_DIR} &&
    python3 -m pip install --user -r cache_policy_evolution/requirements.txt &&
    python3 -m pip install --user -r claude_api/requirements.txt
"
ok   "[$HOST] Python deps installed"

# 5) Start claude_api in background
log "[$HOST] starting claude_api proxy on :${PORT}"
run_remote "
    pkill -f 'claude_api/server.py' 2>/dev/null || true
    sleep 0.5
    cd ${REPO_DIR}/claude_api || exit 1
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    : > ${PROXY_LOG}
    PORT=${PORT} setsid nohup python3 -u server.py >> ${PROXY_LOG} 2>&1 < /dev/null &
    echo \$! > ${PROXY_PID}
    disown -a 2>/dev/null || true
"

# Poll /health for up to ~20s
HEALTHY=false
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    if run_remote "curl -fs --max-time 3 http://localhost:${PORT}/health >/dev/null 2>&1"; then
        HEALTHY=true
        break
    fi
done

if $HEALTHY; then
    ok   "[$HOST] claude_api healthy on :${PORT}  (log: ${PROXY_LOG})"
else
    err  "[$HOST] claude_api did not come up — dumping last 40 lines of ${PROXY_LOG}:"
    run_remote "tail -n 40 ${PROXY_LOG} 2>/dev/null || echo '(log empty or missing)'" >&2
fi

echo
ok "main node setup complete"
cat <<EOF

On the remote host you still need to:
  1. Authenticate Claude Code once:
       claude   # complete OAuth, then exit
     (if claude --version already works but /v1/chat/completions fails, auth is the usual cause)
  2. Run evolution:
       cd ${REPO_DIR}/cache_policy_evolution
       export OPENAI_API_KEY=dummy
       python3 evolve.py scan_thrash.toml

Proxy logs:    ${PROXY_LOG}
Proxy pid:     \$(cat ${PROXY_PID} 2>/dev/null)
Stop proxy:    pkill -f claude_api/server.py

EOF

if ! $NO_SHELL; then
    log "opening interactive SSH to ${SSH_USER}@${HOST}"
    exec ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "cd ${REPO_DIR} && exec \$SHELL -l"
fi
