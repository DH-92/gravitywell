#!/usr/bin/env bash
# smartd-ntfy-down.sh — revert everything smartd-ntfy-up.sh set up.
# Removes the smartd->ntfy hook, restores the original 10mail, stops/removes the ntfy
# container, and strips the ntfy service from the compose file.
# The ntfy data dir is KEPT unless you pass --purge.
# Idempotent. Run with:  sudo bash ~/gravitywell/smartd-ntfy-down.sh [--purge]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root:  sudo bash $0 [--purge]" >&2
  exit 1
fi

PURGE=0; [[ "${1:-}" == "--purge" ]] && PURGE=1
STACK=/home/olympus/gravitywell
COMPOSE="$STACK/docker-compose.yml"
RUND=/etc/smartmontools/run.d
DATA=/pool0/share/docker/gravitywell/data/ntfy

echo "== 1/4  remove smartd -> ntfy hook =="
if [[ -e "$RUND/20ntfy" ]]; then rm -f "$RUND/20ntfy"; echo "   removed 20ntfy."; else echo "   20ntfy not present."; fi

echo "== 2/4  restore original 10mail (re-enable execute bit) =="
if [[ -e "$RUND/10mail" && ! -x "$RUND/10mail" ]]; then
  chmod +x "$RUND/10mail"
  echo "   re-enabled 10mail (NOTE: reverts to original state; it will error until /usr/bin/mail exists)."
else
  echo "   10mail already executable or absent; nothing to do."
fi

echo "== 3/4  stop & remove ntfy container =="
if ( cd "$STACK" && docker compose ps --services 2>/dev/null | grep -qx ntfy ); then
  ( cd "$STACK" && docker compose rm -sf ntfy )
  echo "   ntfy container stopped & removed."
else
  echo "   ntfy container not defined/running."
fi

echo "== 4/4  strip ntfy service from compose =="
if grep -qE '^[[:space:]]+ntfy:' "$COMPOSE"; then
  cp "$COMPOSE" "$COMPOSE.bak.down.$(date +%F-%H%M%S)"
  # up appends ntfy as the LAST service; delete from its comment/key marker to EOF.
  awk 'f{next} /^  # ntfy - self-hosted/||/^  ntfy:/ {f=1; next} {print}' "$COMPOSE" > "$COMPOSE.tmp"
  if ( cd "$STACK" && docker compose -f "$COMPOSE.tmp" config >/dev/null 2>&1 ); then
    mv "$COMPOSE.tmp" "$COMPOSE"
    echo "   removed ntfy service (timestamped backup saved alongside)."
  else
    rm -f "$COMPOSE.tmp"
    echo "   WARNING: automatic edit would fail compose validation; left compose UNTOUCHED." >&2
    echo "            Remove the ntfy: block manually, then 'docker compose config' to verify." >&2
  fi
else
  echo "   no ntfy service in compose."
fi

if [[ $PURGE -eq 1 ]]; then
  echo "== purge: removing ntfy data dir $DATA =="
  rm -rf "$DATA" && echo "   purged $DATA." || echo "   could not remove $DATA"
else
  echo "Data dir kept: $DATA  (re-run with --purge to delete it)"
fi

echo
echo "DOWN complete."
