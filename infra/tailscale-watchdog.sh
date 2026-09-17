#!/usr/bin/env bash
# Mantém tailscaled vivo reutilizando /var/lib/tailscale (identidade atual).
# Não consome pool. Não toca na plataforma. Não cria nó novo.

set -u

INFRA=$(cd "$(dirname "$0")" && pwd)
LOG="$INFRA/tailscale-watchdog.log"
LOCK_DIR="$INFRA/tailscale-watchdog.lock"
BIN=/usr/sbin/tailscaled
STATE=/var/lib/tailscale/tailscaled.state
STATEDIR=/var/lib/tailscale
SOCKET=/run/tailscale/tailscaled.sock
MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "tailscale-watchdog already running" >&2
  exit 0
fi
echo $$ >&9

backoff=$MIN_BACKOFF
log "watchdog start pid=$$"

is_running() {
  pgrep -x tailscaled >/dev/null 2>&1
}

start_daemon() {
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  if ! sudo test -f "$STATE"; then
    log "ERROR: missing state $STATE (não vou criar identidade nova)"
    return 1
  fi
  sudo mkdir -p "$STATEDIR" /run/tailscale
  sudo setsid "$BIN" \
    -state="$STATE" \
    -statedir="$STATEDIR" \
    -socket="$SOCKET" \
    >>"$LOG" 2>&1 &
  local pid=$!
  sleep 1
  if is_running; then
    log "started tailscaled (spawn_pid=$pid real=$(pgrep -x tailscaled | tr '\n' ' '))"
    return 0
  fi
  log "ERROR: tailscaled failed to stay up after start"
  return 1
}

while true; do
  if is_running; then
    backoff=$MIN_BACKOFF
    while is_running; do
      sleep 5
    done
    log "tailscaled exited; will restart"
  else
    log "tailscaled not running; starting"
    if start_daemon; then
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  fi
done
