#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/token-push.log"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

source "$SCRIPT_DIR/oc-profiles.sh"

LOCK_FILE="$SCRIPT_DIR/.token-push.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log "token-push started"

oc-sync anthropic openai 2>&1 | while read -r line; do log "$line"; done
oc-refresh 2>&1 | while read -r line; do log "$line"; done
oc-deploy --all 2>&1 | while read -r line; do log "$line"; done

log "token-push completed"
