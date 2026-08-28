#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

git fetch --prune origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/master)
[[ "$LOCAL" == "$REMOTE" ]] && exit 0        # nothing to do

git reset --hard origin/main               # server never has local commits
docker compose pull --quiet
docker compose up -d --remove-orphans
docker image prune -f --filter "until=168h"
