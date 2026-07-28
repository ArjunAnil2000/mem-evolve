#!/usr/bin/env bash
# setup_main_node.sh — provision the coordinator (main) node:
#   1. fix /mydata ownership
#   2. clone the repo (if not already)
#   3. install Python deps for the coordinator
#   4. install litellm[proxy] via pip and launch it against --litellm-config
#   5. health-check the LiteLLM endpoint the coordinator will use
#   6. drop you into an interactive SSH session on the host
#
# LLM calls go through a LiteLLM proxy (OpenAI-compatible) — see
# cache_policy_evolution/*.toml's [llm.mutator]/[llm.planner] `api_base`.
# Steps 3+ assume the host already has the cache_ext toolchain (clang-14,
# bpftool, vmlinux.h) from setup_cloudlab.sh — this script does not build
# or install the custom kernel.
#
# Usage:
#   ./setup_main_node.sh <host>
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=... ./setup_main_node.sh <host>
#
# Options:
#   --pat <token>          GitHub PAT. Optional — only needed if the repo
#                          being cloned is private. The default repo
#                          (ArjunAnil2000/mem-evolve) is public, so a plain
#                          anonymous clone is used when --pat is omitted.
#   --user <user>          SSH user              (default: aanil3)
#   --ssh-key <path>       SSH key               (default: ~/.ssh/id_ed25519)
#   --base-dir <path>      Install root          (default: /mydata)
#   --litellm-config <path> Local path to a litellm proxy config YAML to
#                          copy to the host and launch. Skips the
#                          install+launch step if omitted.
#   --litellm-port <port>  Port for the litellm proxy to listen on
#                          (default: 4000)
#   --litellm-url <url>    LiteLLM base URL to health-check from the remote
#                          host (default: http://localhost:<litellm-port>/v1)
#   --skip-litellm         Skip installing/launching litellm entirely —
#                          just health-check whatever's already at
#                          --litellm-url
#   --no-shell             Skip the final interactive ssh
#
###########################################################################################
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION must be
# exported in the calling shell if --litellm-config is given — they're
# forwarded to the remote litellm process's environment, never written to
# disk or to this script.
###########################################################################################

set -euo pipefail

PAT=""
SSH_USER="aanil3"
SSH_KEY="$HOME/.ssh/id_ed25519"
BASE_DIR="/mydata"
LITELLM_CONFIG=""
LITELLM_PORT="4000"
LITELLM_URL=""
SKIP_LITELLM=false
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
        --litellm-config) LITELLM_CONFIG="$2"; shift 2 ;;
        --litellm-port) LITELLM_PORT="$2"; shift 2 ;;
        --litellm-url) LITELLM_URL="$2"; shift 2 ;;
        --skip-litellm) SKIP_LITELLM=true; shift ;;
        --no-shell) NO_SHELL=true; shift ;;
        -h|--help)  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         err "unknown flag: $1"; exit 1 ;;
        *)          HOST="$1"; shift ;;
    esac
done

[[ -z "$HOST" ]] && { err "host required"; exit 1; }
[[ -z "$LITELLM_URL" ]] && LITELLM_URL="http://localhost:${LITELLM_PORT}/v1"

if [[ -n "$LITELLM_CONFIG" && ! -f "$LITELLM_CONFIG" ]]; then
    err "--litellm-config file not found: $LITELLM_CONFIG"
    exit 1
fi
if [[ -n "$LITELLM_CONFIG" ]] && ! $SKIP_LITELLM; then
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${AWS_DEFAULT_REGION:-}" ]]; then
        err "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION must be exported to launch litellm (or pass --skip-litellm)"
        exit 1
    fi
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY")
REPO_DIR="${BASE_DIR}/evo_cache"

run_remote() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "$1"; }

# 1) Ownership on /mydata
log "[$HOST] fixing ${BASE_DIR} ownership"
run_remote "sudo mkdir -p ${BASE_DIR} && sudo chown -R ${SSH_USER} ${BASE_DIR} && sudo chmod 755 ${BASE_DIR}"
ok   "[$HOST] ${BASE_DIR} owned by ${SSH_USER}"

# 2) Clone repo (if missing). Public repo -> plain anonymous clone. Only
#    embed a PAT in the URL if one was actually passed (private fork case).
if run_remote "test -d ${REPO_DIR}/.git"; then
    log "[$HOST] repo already present — pulling"
    run_remote "cd ${REPO_DIR} && git pull --ff-only && git submodule update --init --recursive"
else
    if [[ -n "$PAT" ]]; then
        CLONE_URL="https://ArjunAnil2000:${PAT}@github.com/ArjunAnil2000/mem-evolve"
    else
        CLONE_URL="https://github.com/ArjunAnil2000/mem-evolve"
    fi
    log "[$HOST] cloning repo"
    run_remote "git clone ${CLONE_URL} ${REPO_DIR} && cd ${REPO_DIR} && git submodule update --init --recursive"
fi
ok   "[$HOST] repo ready at ${REPO_DIR}"

# 3) Python deps for the coordinator. python3.11 (not the distro default
#    python3) — matches what setup_cloudlab.sh installs via deadsnakes and
#    what evolve.py's tomllib-based config loading expects.
log "[$HOST] installing Python deps"
run_remote "
    cd ${REPO_DIR} &&
    python3.11 -m pip install --user -r cache_policy_evolution/requirements.txt
"
ok   "[$HOST] Python deps installed"

# 4) Install litellm[proxy] via pip and launch it. Docker is NOT used here —
#    on a cache_ext custom kernel built via `make localmodconfig`, the
#    netfilter/bridge modules Docker's default networking needs are
#    typically missing (stripped because they weren't loaded when the
#    kernel config was captured), and there's no straightforward fix short
#    of rebuilding the kernel. A bare `pip install` avoids the whole
#    problem. Skipped entirely if --litellm-config wasn't given.
if [[ -n "$LITELLM_CONFIG" ]] && ! $SKIP_LITELLM; then
    LITELLM_REMOTE_DIR="\$HOME/lite-llm-server"
    log "[$HOST] installing litellm[proxy]"
    run_remote "python3.11 -m pip install --user 'litellm[proxy]'" >/dev/null
    ok   "[$HOST] litellm[proxy] installed"

    log "[$HOST] copying litellm config"
    run_remote "mkdir -p ${LITELLM_REMOTE_DIR}"
    # scp's SFTP transfer doesn't run a remote shell, so it can't expand
    # $HOME in the destination path (unlike run_remote's ssh calls) — use a
    # ~-relative path instead, which sftp resolves against the login home dir.
    scp -q -o StrictHostKeyChecking=no -i "$SSH_KEY" \
        "$LITELLM_CONFIG" "${SSH_USER}@${HOST}:~/lite-llm-server/litellm_config.yaml"
    ok   "[$HOST] config copied to ${LITELLM_REMOTE_DIR}/litellm_config.yaml"

    log "[$HOST] launching litellm proxy on :${LITELLM_PORT}"
    # pkill -f matches the FULL cmdline of every process, including the
    # remote bash process running this very script (whose cmdline is the
    # whole multi-line script text below, which itself contains the literal
    # string being searched for) — that self-match killed the SSH session's
    # own shell before it ever reached the nohup line. -x matches on the
    # process name only (exact match), which sidesteps the self-match.
    run_remote "
        export PATH=\"\$HOME/.local/bin:\$PATH\"
        export AWS_ACCESS_KEY_ID='${AWS_ACCESS_KEY_ID}'
        export AWS_SECRET_ACCESS_KEY='${AWS_SECRET_ACCESS_KEY}'
        export AWS_DEFAULT_REGION='${AWS_DEFAULT_REGION}'
        cd ${LITELLM_REMOTE_DIR}
        pkill -x litellm 2>/dev/null || true
        sleep 1
        nohup litellm --config litellm_config.yaml --port ${LITELLM_PORT} > litellm.log 2>&1 &
        disown
    "
    sleep 3
    ok   "[$HOST] litellm launched (log: ${LITELLM_REMOTE_DIR}/litellm.log — not a systemd service, won't survive reboot/crash)"
fi

# 5) Health-check the LiteLLM endpoint. Doesn't fail the provisioning run.
#    Send the master key if we have one — some litellm versions return 500
#    (not 401/403) for an unauthenticated /v1/models call, which otherwise
#    looks indistinguishable from the proxy actually being broken.
log "[$HOST] checking LiteLLM at ${LITELLM_URL}"
AUTH_HEADER=()
[[ -n "${LITELLM_MASTER_KEY:-}" ]] && AUTH_HEADER=(-H "'Authorization: Bearer ${LITELLM_MASTER_KEY}'")
if run_remote "curl -fs --max-time 5 ${AUTH_HEADER[*]:-} '${LITELLM_URL}/models' -o /dev/null -w '%{http_code}'" 2>/dev/null | grep -qE '^(200|401|403)$'; then
    ok   "[$HOST] LiteLLM reachable at ${LITELLM_URL}"
else
    err  "[$HOST] could not reach ${LITELLM_URL} — make sure your LiteLLM proxy is running there before starting evolution (use --litellm-url to point elsewhere, or --litellm-config to have this script launch one)"
fi

echo
ok "main node setup complete"
cat <<EOF

On the remote host you still need to:
  1. Make sure a LiteLLM proxy is reachable at: ${LITELLM_URL}
  2. Export the LiteLLM key referenced by your TOML's api_key_env
     (default: LITELLM_MASTER_KEY), e.g.:
       export LITELLM_MASTER_KEY=...
  3. Run evolution:
       cd ${REPO_DIR}/cache_policy_evolution
       python3.11 evolve.py scan_thrash.toml

EOF

if ! $NO_SHELL; then
    log "opening interactive SSH to ${SSH_USER}@${HOST}"
    exec ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "cd ${REPO_DIR} && exec \$SHELL -l"
fi
