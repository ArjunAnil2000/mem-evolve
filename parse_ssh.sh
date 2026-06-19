#!/usr/bin/env bash
# parse_ssh.sh — Extract hostnames from SSH connection strings
#
# Usage:
#   ./parse_ssh.sh "ssh aanil3@host1" "ssh user@host2" ...
#   echo "ssh aanil3@host1" | ./parse_ssh.sh
#   ./parse_ssh.sh < file_with_ssh_lines.txt
#
# Pipe into setup_cloudlab.sh:
#   ./setup_cloudlab.sh --pat <TOKEN> $(./parse_ssh.sh "ssh aanil3@host1" "ssh aanil3@host2")

set -euo pipefail

# ------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[parse_ssh]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[parse_ssh] ✓${NC} $*" >&2; }
err()  { echo -e "${RED}[parse_ssh] ✗${NC} $*" >&2; }

# ------------------------------------------------------------------
# Parse a single SSH string into a hostname
# ------------------------------------------------------------------
parse_host() {
    local input="$1"
    # Strip leading "ssh " and any flags (e.g. ssh -p 22 user@host)
    local target="${input##* }"
    # Strip "user@" prefix if present
    echo "${target##*@}"
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
HOSTS=()

if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
        [[ -z "$arg" ]] && continue
        HOSTS+=("$(parse_host "$arg")")
    done
else
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        HOSTS+=("$(parse_host "$line")")
    done
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    err "No SSH strings provided."
    echo "Usage: $0 \"ssh user@host1\" \"ssh user@host2\" ..." >&2
    exit 1
fi

log "Parsed ${#HOSTS[@]} host(s):"
for h in "${HOSTS[@]}"; do
    log "  $h"
done

# Print space-separated list to stdout (logs go to stderr)
echo "${HOSTS[*]}"
