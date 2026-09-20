#!/usr/bin/env bash
# Keep sshd on <tailscale-ipv4>:2222. Depends on Tailscale already being up.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
LOG="$DIR/sshd-watchdog.log"
LOCK_DIR="$DIR/sshd-watchdog.lock"
BIN=/usr/sbin/sshd
PORT=2222
MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "sshd-watchdog already running" >&2
  exit 0
fi
echo $$ >&9

backoff=$MIN_BACKOFF
log "watchdog start pid=$$"

tailscale_ip() {
  local ip
  ip=$(sudo tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

is_listening() {
  local ip=$1
  ss -lntp 2>/dev/null | grep -qE "${ip}:${PORT}\\b"
}

wait_for_tailscale() {
  local n=0
  while ! pgrep -x tailscaled >/dev/null 2>&1; do
    log "waiting for tailscaled..."
    sleep 3
    n=$((n+1))
    if (( n > 40 )); then
      log "ERROR: tailscaled still down after wait"
      return 1
    fi
  done
  n=0
  while true; do
    local ip
    ip=$(tailscale_ip) || ip=""
    if [[ -n "$ip" ]] && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${ip}/"; then
      printf '%s\n' "$ip"
      return 0
    fi
    log "waiting for tailscale0 address (got=${ip:-none})..."
    sleep 3
    n=$((n+1))
    if (( n > 40 )); then
      log "ERROR: no tailscale IP yet"
      return 1
    fi
  done
}

start_sshd() {
  local ip=$1
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  if ! sudo "$BIN" -t -p "$PORT" -o "ListenAddress=$ip" >/dev/null 2>&1; then
    if ! sudo "$BIN" -t >/dev/null 2>&1; then
      log "WARN: sshd -t failed; trying to start anyway"
    fi
  fi
  sudo setsid "$BIN" -D -e -p "$PORT" -o "ListenAddress=$ip" >>"$LOG" 2>&1 &
  local pid=$!
  sleep 1
  if is_listening "$ip"; then
    log "started sshd ListenAddress=$ip:$PORT (spawn_pid=$pid)"
    return 0
  fi
  log "ERROR: sshd not listening on $ip:$PORT after start"
  return 1
}

while true; do
  ip=$(wait_for_tailscale) || {
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
    continue
  }

  if is_listening "$ip"; then
    backoff=$MIN_BACKOFF
    log "adopting existing listener on $ip:$PORT"
    while is_listening "$ip"; do
      sleep 5
    done
    log "listener on $ip:$PORT gone; will restart"
  else
    log "no listener on $ip:$PORT; starting sshd"
    if start_sshd "$ip"; then
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  fi
done
