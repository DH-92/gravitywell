#!/usr/bin/env bash
# find-orphan-downloads.sh --- READ-ONLY discovery of reclaimable media in
# /pool1/media/downloads. DELETES NOTHING. Runs as the 'olympus' user, no sudo.
#
# It runs the Python analyzer INSIDE the qbit container, where both the qBittorrent
# API (localhost:8080) and the /downloads bind mount are reachable. Output is printed
# and saved to a timestamped report next to this script.
#
#   Usage:  bash ~/gravitywell/find-orphan-downloads.sh            # default >=200MB
#           MIN_MB=500 bash ~/gravitywell/find-orphan-downloads.sh # only >=500MB
set -euo pipefail

CONTAINER="${CONTAINER:-gravitywell-qbit-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$DIR/find-orphan-downloads.py"
MIN_MB="${MIN_MB:-200}"
REPORT="$DIR/orphan-downloads-report.$(date +%F-%H%M%S).txt"

[[ -f "$PY" ]] || { echo "missing analyzer: $PY" >&2; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "container $CONTAINER not found" >&2; exit 1; }

echo "Read-only analysis in $CONTAINER (media files >= ${MIN_MB}MiB, nlink==1, not required by qbit)..."
echo
# -i pipes the analyzer in on stdin; no file needs to exist inside the container.
docker exec -i -e MIN_MB="$MIN_MB" "$CONTAINER" python3 - < "$PY" | tee "$REPORT"
echo
echo "Report saved: $REPORT"
