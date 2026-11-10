#!/usr/bin/env bash
# server-health-check.sh — read-only health poller for olympus24.
# Publishes alerts to the self-hosted ntfy container (topic: server-health) ONLY on
# threshold breach, with per-condition de-duplication so persistent issues remind you
# at most once per RENOTIFY window instead of every run. Sends a "RESOLVED" note when a
# condition clears. Runs entirely as the 'olympus' user — no sudo, no host installs.
#
#   Usage:  server-health-check.sh            # normal (cron) run
#           server-health-check.sh --once     # run once, verbose to stdout
#           server-health-check.sh --test     # force-send a sample alert (ignores dedup)
#
# All thresholds are env-overridable (see CONFIG). Requires: curl, zpool, docker,
# systemctl, df, free — all already present on the host.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ----- CONFIG (override via env) --------------------------------------------
NTFY_URL="${NTFY_URL:-http://127.0.0.1:8090/server-health}"
HOSTLABEL="${HOSTLABEL:-olympus24}"
RENOTIFY="${RENOTIFY:-86400}"          # seconds before re-alerting a persistent condition (24h)

ZFS_CAP_WARN="${ZFS_CAP_WARN:-85}"     # zpool capacity %
ZFS_CAP_CRIT="${ZFS_CAP_CRIT:-92}"
SCRUB_MAX_DAYS="${SCRUB_MAX_DAYS:-21}" # warn if last scrub older than this

FS_USE_WARN="${FS_USE_WARN:-90}"       # non-zfs filesystem use %
FS_USE_CRIT="${FS_USE_CRIT:-95}"

MEM_AVAIL_MIN_PCT="${MEM_AVAIL_MIN_PCT:-8}"   # warn if available memory below this %
SWAP_USED_WARN_PCT="${SWAP_USED_WARN_PCT:-50}"

TEMP_WARN_C="${TEMP_WARN_C:-80}"       # x86_pkg_temp warn threshold
LOAD_FACTOR="${LOAD_FACTOR:-2.0}"      # warn if 15-min loadavg > nproc * factor

# systemd units we've assessed as benign and do NOT want to alert on:
SYSTEMD_IGNORE="${SYSTEMD_IGNORE:-systemd-networkd-wait-online.service}"

STATE_DIR="${STATE_DIR:-$HOME/.cache/olympus-health}"
STATE_FILE="$STATE_DIR/state"
# ----------------------------------------------------------------------------

MODE="cron"
case "${1:-}" in
  --once) MODE="once" ;;
  --test) MODE="test" ;;
esac

mkdir -p "$STATE_DIR"

# alert accumulators (parallel arrays, indexed together)
A_KEY=(); A_SEV=(); A_MSG=()
add() { A_KEY+=("$1"); A_SEV+=("$2"); A_MSG+=("$3"); }
say() { [[ "$MODE" != "cron" ]] && echo "$@"; }

sev_rank() { case "$1" in crit) echo 3;; warn) echo 2;; info) echo 1;; *) echo 0;; esac; }

# ===== CHECKS ===============================================================

## ZFS pool health (degraded / faulted / errors)
zx="$(zpool status -x 2>/dev/null)"
if [[ -n "$zx" && "$zx" != "all pools are healthy" ]]; then
  add "zfs-health" crit "ZFS pool(s) not healthy:
$zx"
fi

## ZFS capacity + scrub age/errors (per pool)
while IFS=$'\t' read -r pname pcap; do
  [[ -z "$pname" ]] && continue
  cap="${pcap%\%}"
  if   (( cap >= ZFS_CAP_CRIT )); then add "zfs-cap-$pname" crit "ZFS pool '$pname' at ${cap}% capacity (crit >= ${ZFS_CAP_CRIT}%). Free space or ZFS performance will degrade."
  elif (( cap >= ZFS_CAP_WARN )); then add "zfs-cap-$pname" warn "ZFS pool '$pname' at ${cap}% capacity (warn >= ${ZFS_CAP_WARN}%)."
  fi
  scan="$(zpool status "$pname" 2>/dev/null | sed -n 's/^[[:space:]]*scan:[[:space:]]*//p')"
  if [[ "$scan" == *"with "*"errors on"* ]]; then
    errs="$(echo "$scan" | sed -n 's/.*with \([0-9]*\) errors on.*/\1/p')"
    [[ -n "$errs" && "$errs" != "0" ]] && add "zfs-scruberr-$pname" crit "ZFS pool '$pname' last scrub reported $errs error(s): $scan"
    when="${scan##* on }"
    if wepoch="$(date -d "$when" +%s 2>/dev/null)"; then
      now="$(date +%s)"; agedays=$(( (now - wepoch) / 86400 ))
      (( agedays > SCRUB_MAX_DAYS )) && add "zfs-scrubold-$pname" warn "ZFS pool '$pname' last scrub was ${agedays}d ago (> ${SCRUB_MAX_DAYS}d): $scan"
    fi
  fi
done < <(zpool list -H -o name,capacity 2>/dev/null)

## Non-ZFS filesystem usage
while read -r use mnt; do
  u="${use%\%}"
  if   (( u >= FS_USE_CRIT )); then add "fs-$mnt" crit "Filesystem $mnt at ${u}% used (crit >= ${FS_USE_CRIT}%)."
  elif (( u >= FS_USE_WARN )); then add "fs-$mnt" warn "Filesystem $mnt at ${u}% used (warn >= ${FS_USE_WARN}%)."
  fi
done < <(df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs -x zfs 2>/dev/null | awk 'NR>1{print $5, $6}')

## Docker containers not running / unhealthy
if command -v docker >/dev/null 2>&1; then
  bad="$(docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null \
        | awk -F'|' '$2!="running" || $3 ~ /unhealthy/ {print $1" ("$2"; "$3")"}')"
  [[ -n "$bad" ]] && add "docker" crit "Docker container(s) not healthy:
$bad"
fi

## Failed systemd units (minus allowlist)
failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
if [[ -n "$failed" ]]; then
  keep=""
  while read -r u; do
    [[ -z "$u" ]] && continue
    skip=0; for ig in $SYSTEMD_IGNORE; do [[ "$u" == "$ig" ]] && skip=1; done
    [[ $skip -eq 0 ]] && keep+="$u "
  done <<< "$failed"
  [[ -n "$keep" ]] && add "systemd" warn "Failed systemd unit(s): $keep"
fi

## Memory / swap pressure
read -r memtotal memavail <<< "$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{print t, a}' /proc/meminfo)"
if [[ -n "$memtotal" && "$memtotal" -gt 0 ]]; then
  availpct=$(( memavail * 100 / memtotal ))
  (( availpct < MEM_AVAIL_MIN_PCT )) && add "mem" warn "Available memory low: ${availpct}% (< ${MEM_AVAIL_MIN_PCT}%)."
fi
read -r swtotal swfree <<< "$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t, f}' /proc/meminfo)"
if [[ -n "$swtotal" && "$swtotal" -gt 0 ]]; then
  swused=$(( (swtotal - swfree) * 100 / swtotal ))
  (( swused > SWAP_USED_WARN_PCT )) && add "swap" warn "Swap usage high: ${swused}% (> ${SWAP_USED_WARN_PCT}%)."
fi

## CPU package temperature
for z in /sys/class/thermal/thermal_zone*; do
  [[ -e "$z/type" && -e "$z/temp" ]] || continue
  [[ "$(cat "$z/type")" == "x86_pkg_temp" ]] || continue
  c=$(( $(cat "$z/temp") / 1000 ))
  (( c >= TEMP_WARN_C )) && add "temp" warn "CPU package temperature ${c}C (>= ${TEMP_WARN_C}C)."
done

## Load average (15-min) vs cpu count
ncpu="$(nproc 2>/dev/null || echo 1)"
load15="$(awk '{print $3}' /proc/loadavg)"
if awk -v l="$load15" -v n="$ncpu" -v f="$LOAD_FACTOR" 'BEGIN{exit !(l > n*f)}'; then
  add "load" warn "15-min load average ${load15} on ${ncpu} CPUs (> ${ncpu} x ${LOAD_FACTOR})."
fi

## Reboot required (informational)
if [[ -f /var/run/reboot-required ]]; then
  pkgs="$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)"
  add "reboot" info "Reboot required (pending: ${pkgs:-see /var/run/reboot-required.pkgs})."
fi

## Pending security updates (informational)
if [[ -x /usr/lib/update-notifier/apt-check ]]; then
  secn="$(/usr/lib/update-notifier/apt-check 2>&1 | awk -F';' '{print $2}')"
  [[ "$secn" =~ ^[0-9]+$ && "$secn" -gt 0 ]] && add "aptsec" info "${secn} security update(s) available."
fi

# ===== TEST MODE ============================================================
if [[ "$MODE" == "test" ]]; then
  printf 'server-health TEST from %s at %s\n' "$HOSTLABEL" "$(date)" \
    | curl -fsS --max-time 15 \
        -H "Title: TEST: server-health on $HOSTLABEL" \
        -H "Priority: default" -H "Tags: white_check_mark,test_tube" \
        --data-binary @- "$NTFY_URL" >/dev/null \
    && echo "test push sent to $NTFY_URL" || echo "TEST PUSH FAILED to $NTFY_URL" >&2
  exit 0
fi

# ===== DE-DUP + DISPATCH ====================================================
declare -A LAST
[[ -f "$STATE_FILE" ]] && while read -r k t; do [[ -n "$k" ]] && LAST["$k"]="$t"; done < "$STATE_FILE"

now="$(date +%s)"
declare -A CURRENT
due_msgs=(); max_sev=0

for i in "${!A_KEY[@]}"; do
  k="${A_KEY[$i]}"; sev="${A_SEV[$i]}"; msg="${A_MSG[$i]}"
  CURRENT["$k"]="$now"
  last="${LAST[$k]:-0}"
  if [[ "$last" -eq 0 ]] || (( now - last >= RENOTIFY )) || [[ "$MODE" == "once" ]]; then
    due_msgs+=("[$sev] $msg")
    r=$(sev_rank "$sev"); (( r > max_sev )) && max_sev=$r
    CURRENT["$k"]="$now"          # stamp as notified now
  else
    CURRENT["$k"]="$last"         # keep prior notify time
  fi
done

# resolved = keys previously alerting that are no longer present
resolved=()
for k in "${!LAST[@]}"; do [[ -z "${CURRENT[$k]:-}" ]] && resolved+=("$k"); done

send() { # $1=title $2=priority $3=tags ; body on stdin
  curl -fsS --max-time 15 -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    --data-binary @- "$NTFY_URL" >/dev/null 2>&1
}

if [[ ${#due_msgs[@]} -gt 0 ]]; then
  case "$max_sev" in 3) prio=urgent; tags="rotating_light";; 2) prio=high; tags="warning";; *) prio=default; tags="information_source";; esac
  n=${#due_msgs[@]}
  body="$(printf '%s\n\n' "${due_msgs[@]}")"
  say "----- ALERTS ($n) -----"; say "$body"
  printf '%s' "$body" | send "$HOSTLABEL: $n health alert(s)" "$prio" "$tags" \
    && say "alert push sent" || say "ALERT PUSH FAILED"
else
  say "no active alerts"
fi

if [[ ${#resolved[@]} -gt 0 ]]; then
  rbody="Resolved: ${resolved[*]}"
  say "$rbody"
  printf '%s' "$rbody" | send "$HOSTLABEL: condition(s) resolved" "default" "white_check_mark" || true
fi

# persist state (only currently-active keys)
: > "$STATE_FILE"
for k in "${!CURRENT[@]}"; do printf '%s %s\n' "$k" "${CURRENT[$k]}" >> "$STATE_FILE"; done

exit 0
