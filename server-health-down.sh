#!/usr/bin/env bash
# server-health-down.sh — remove the server-health poller cron job (and optionally files).
# Runs as the 'olympus' user, no sudo. Idempotent.
#   Usage:  bash ~/gravitywell/server-health-down.sh [--purge]
#           --purge also deletes the poller script and its state/cache.
set -euo pipefail

PURGE=0; [[ "${1:-}" == "--purge" ]] && PURGE=1
SCRIPT=/home/olympus/gravitywell/server-health-check.sh
STATE_DIR="$HOME/.cache/olympus-health"

echo "== remove cron entry =="
if crontab -l 2>/dev/null | grep -q 'server-health-check.sh'; then
  crontab -l 2>/dev/null | grep -v 'server-health-check.sh' | { grep -q . && crontab - || crontab -r; }
  echo "   removed poller line from crontab."
else
  echo "   no poller cron line present."
fi

if [[ $PURGE -eq 1 ]]; then
  echo "== purge script + state =="
  rm -f "$SCRIPT" && echo "   removed $SCRIPT"
  rm -rf "$STATE_DIR" && echo "   removed $STATE_DIR"
else
  echo "Kept $SCRIPT and $STATE_DIR (re-run with --purge to delete them)."
fi

echo "DOWN complete."
