#!/usr/bin/env bash
# smartd-ntfy-up.sh — set up self-hosted ntfy alerts for host smartd on olympus24.
# Brings up the ntfy container (gravitywell stack) and wires smartd -> ntfy.
# Idempotent — safe to re-run. Run with:  sudo bash ~/gravitywell/smartd-ntfy-up.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root:  sudo bash $0" >&2
  exit 1
fi

STACK=/home/olympus/gravitywell
COMPOSE="$STACK/docker-compose.yml"
RUND=/etc/smartmontools/run.d
DATA=/pool0/share/docker/gravitywell/data/ntfy

echo "== 1/4  ensure ntfy service in compose =="
if grep -qE '^[[:space:]]+ntfy:' "$COMPOSE"; then
  echo "   ntfy service already present."
else
  cp "$COMPOSE" "$COMPOSE.bak.$(date +%F-%H%M%S)"
  mkdir -p "$DATA"
  cat >> "$COMPOSE" <<'YAML'

  # ntfy - self-hosted push notifications. smartd (host) posts to 127.0.0.1:8090.
  ntfy:
    image: binwiederhier/ntfy
    command: serve
    restart: always
    networks:
      public:
    ports:
      - "127.0.0.1:8090:80"   # host-local publish endpoint for smartd (no auth)
    environment:
      TZ:
      NTFY_BASE_URL: "https://ntfy.home.ahawp.com"
      NTFY_BEHIND_PROXY: "true"
      NTFY_CACHE_FILE: "/var/lib/ntfy/cache.db"
      NTFY_ATTACHMENT_CACHE_DIR: "/var/lib/ntfy/attachments"
    volumes:
      - ${DATA_DIR}/ntfy:/var/lib/ntfy
    labels:
      traefik.http.routers.ntfy.middlewares: test-auth@docker
      traefik.http.services.ntfy.loadbalancer.server.port: 80
YAML
  echo "   appended ntfy service."
fi

echo "== 2/4  (re)start ntfy container =="
( cd "$STACK" && docker compose up -d ntfy )

echo "== 3/4  install smartd -> ntfy hook =="
install -d "$RUND"
cat > "$RUND/20ntfy" <<'EOF'
#!/bin/bash
# smartd -> self-hosted ntfy. $1 = message-body file; env: SMARTD_SUBJECT / SMARTD_MESSAGE.
# Deliberately NOT 'set -e' and always exit 0 so a push failure can't abort the run.d chain.
URL="http://127.0.0.1:8090/disk-health"
body="$(cat "$1" 2>/dev/null)"; [ -z "$body" ] && body="${SMARTD_MESSAGE:-smartd alert (no body)}"
curl -fsS --max-time 15 \
  -H "Title: ${SMARTD_SUBJECT:-smartd alert on olympus24}" \
  -H "Priority: urgent" -H "Tags: warning,floppy_disk" \
  -d "$body" "$URL" >/dev/null || logger -t smartd-ntfy "ntfy POST failed"
exit 0
EOF
chmod +x "$RUND/20ntfy"
if [[ -e "$RUND/10mail" ]]; then chmod -x "$RUND/10mail"; echo "   disabled dead 10mail."; fi
echo "   installed 20ntfy."

echo "== 4/4  self-test push via smartd runner =="
echo "smartd->ntfy UP test from olympus24 $(date)" | \
  SMARTD_SUBJECT="TEST: smartd-ntfy UP on olympus24" \
  /usr/share/smartmontools/smartd-runner disk-health && \
  echo "   test push sent - check the 'disk-health' topic." || \
  echo "   WARNING: runner returned non-zero; see 'journalctl -t smartd-ntfy'."

echo
echo "UP complete. Subscribe the ntfy app to https://ntfy.home.ahawp.com/disk-health (basic auth)."
