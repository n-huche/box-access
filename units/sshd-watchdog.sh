#!/usr/bin/env bash
# Keep sshd on <tailscale-ipv4>:2222 only. Never 0.0.0.0.
# Restart when that IPv4 changes. Vendored into box-access.

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

valid_listen_ip() {
  local ip=$1
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  case "$ip" in
    0.0.0.0|127.0.0.1) return 1 ;;
  esac
  return 0
}

is_listening() {
  local ip=$1
  local esc=${ip//./\\.}
  ss -lnt 2>/dev/null | grep -qE "${esc}:${PORT}\\b"
}

# Print sshd pids listening on PORT whose local address is not $1.
# BOX_ACCESS_SS_TEXT, when set, replaces `ss` output (tests only).
sshd_pids_except() {
  local keep=$1
  local ss_text="${BOX_ACCESS_SS_TEXT-}"
  if [[ -z "$ss_text" ]]; then
    ss_text=$(sudo ss -lptn "sport = :${PORT}" 2>/dev/null || true)
  fi
  python3 -c '
import re, sys
keep, port = sys.argv[1], sys.argv[2]
addr = re.compile(r"(\*|0\.0\.0\.0|\[::\]|::|[0-9.]+):" + re.escape(port) + r"\b")
for line in sys.stdin:
    if "sshd" not in line:
        continue
    match = addr.search(line)
    if not match:
        continue
    host = match.group(1)
    if host == keep:
        continue
    for pid in re.findall(r"pid=(\d+)", line):
        print(pid)
' "$keep" "$PORT" <<<"$ss_text" || true
}

stop_sshd_except() {
  local keep=$1 pid killed=0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    log "stopping sshd pid=$pid (not ListenAddress=$keep:$PORT)"
    sudo kill "$pid" 2>/dev/null || true
    killed=1
  done < <(sshd_pids_except "$keep")
  if [[ "$killed" -eq 1 ]]; then
    sleep 0.3
  fi
}

wait_for_tailscale() {
  local n=0
  while ! pgrep -x tailscaled >/dev/null 2>&1; do
    log "waiting for tailscaled..."
    sleep 3
    n=$((n + 1))
    if (( n > 40 )); then
      log "ERROR: tailscaled still down after wait"
      return 1
    fi
  done
  n=0
  while true; do
    local ip
    ip=$(tailscale_ip) || ip=""
    if valid_listen_ip "$ip" && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${ip}/"; then
      printf '%s\n' "$ip"
      return 0
    fi
    if [[ -n "$ip" ]] && ! valid_listen_ip "$ip"; then
      log "ERROR: refusing ListenAddress=$ip"
    else
      log "waiting for tailscale0 address (got=${ip:-none})..."
    fi
    sleep 3
    n=$((n + 1))
    if (( n > 40 )); then
      log "ERROR: no tailscale IP yet"
      return 1
    fi
  done
}

start_sshd() {
  local ip=$1
  if ! valid_listen_ip "$ip"; then
    log "ERROR: refusing ListenAddress=${ip:-empty}"
    return 1
  fi
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  stop_sshd_except "$ip"
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

main() {
  local backoff ip now
  mkdir -p "$LOCK_DIR"
  exec 9>"$LOCK_DIR/pid"
  if ! flock -n 9; then
    echo "sshd-watchdog already running" >&2
    exit 0
  fi
  echo $$ >&9

  backoff=$MIN_BACKOFF
  log "watchdog start pid=$$"

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
        now=$(tailscale_ip) || now=""
        if [[ -n "$now" && "$now" != "$ip" ]]; then
          log "tailscale IPv4 changed $ip -> $now; restarting sshd"
          stop_sshd_except "$now"
          break
        fi
      done
      if ! is_listening "$ip"; then
        log "listener on $ip:$PORT gone; will restart"
      fi
      continue
    fi

    log "no listener on $ip:$PORT; starting sshd"
    if start_sshd "$ip"; then
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
