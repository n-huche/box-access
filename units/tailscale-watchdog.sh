#!/usr/bin/env bash
# Keep tailscaled alive by reusing /var/lib/tailscale (the current identity).
# Does not create a node. Missing state is ./up.sh recovery, not this loop.
# A live but unhealthy daemon is restarted only after TS_WATCHDOG_UNHEALTHY_READS
# bad samples (default 3) and at most once per TS_WATCHDOG_RESTART_COOLDOWN
# seconds (default 600). The cooldown timestamp is tailscale-watchdog.cooldown.
# Vendored into box-access; do not call out to another repo at runtime.

set -u

DIR=$(cd "$(dirname "$0")" && pwd)
LOG="${TS_WATCHDOG_LOG:-$DIR/tailscale-watchdog.log}"
LOCK_DIR="$DIR/tailscale-watchdog.lock"
BIN=/usr/sbin/tailscaled
STATE=/var/lib/tailscale/tailscaled.state
STATEDIR=/var/lib/tailscale
SOCKET=/run/tailscale/tailscaled.sock
MIN_BACKOFF=5
MAX_BACKOFF=60

# shellcheck source=../lib/tailscale-health.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/tailscale-health.sh"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

is_running() {
  pgrep -x tailscaled >/dev/null 2>&1
}

start_daemon() {
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  if ! sudo test -f "$STATE"; then
    log "ERROR: missing state $STATE (will not create a new identity)"
    return 1
  fi
  sudo mkdir -p "$STATEDIR" /run/tailscale
  sudo setsid "$BIN" \
    -state="$STATE" \
    -statedir="$STATEDIR" \
    -socket="$SOCKET" \
    >>"$LOG" 2>&1 &
  local pid=$!
  sleep "${TS_WATCHDOG_START_WAIT:-1}"
  if is_running; then
    log "started tailscaled (spawn_pid=$pid real=$(pgrep -x tailscaled | tr '\n' ' '))"
    return 0
  fi
  log "ERROR: tailscaled failed to stay up after start"
  return 1
}

watchdog_cooldown_file() {
  printf '%s\n' "${TS_WATCHDOG_COOLDOWN_FILE:-$DIR/tailscale-watchdog.cooldown}"
}

# True while a health restart is still inside the cooldown window.
watchdog_in_cooldown() {
  local file wait_s then now
  file=$(watchdog_cooldown_file)
  wait_s=${TS_WATCHDOG_RESTART_COOLDOWN:-600}
  [[ -f "$file" ]] || return 1
  then=$(tr -cd '0-9' <"$file" || true)
  [[ -n "$then" ]] || return 1
  now=$(date +%s)
  (( now - then < wait_s ))
}

watchdog_mark_cooldown() {
  local file
  file=$(watchdog_cooldown_file)
  printf '%s\n' "$(date +%s)" >"$file"
}

# Stop the live daemon, then start it again on the same state file.
restart_unhealthy_tailscaled() {
  local pid n=0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill "$pid" 2>/dev/null || true
  done < <(pgrep -x tailscaled || true)

  while is_running; do
    sleep 0.2
    n=$((n + 1))
    if (( n > 25 )); then
      while read -r pid; do
        [[ -n "$pid" ]] || continue
        sudo kill -9 "$pid" 2>/dev/null || true
      done < <(pgrep -x tailscaled || true)
      sleep 0.2
      break
    fi
  done

  if is_running; then
    log "ERROR: tailscaled did not exit; not starting a second copy"
    return 1
  fi
  if sudo test -S "$SOCKET" || sudo test -e "$SOCKET"; then
    sudo rm -f "$SOCKET"
  fi
  start_daemon
}

# One health sample while the process is up. Restarts are streak- and cooldown-limited.
watchdog_observe_running() {
  local need reason
  need=${TS_WATCHDOG_UNHEALTHY_READS:-3}
  if tailscale_healthy; then
    TS_WATCHDOG_BAD_COUNT=0
    TS_WATCHDOG_COOLDOWN_LOGGED=0
    return 0
  fi
  reason=${TS_HEALTH_REASON:-unhealthy}
  TS_WATCHDOG_BAD_COUNT=$(( ${TS_WATCHDOG_BAD_COUNT:-0} + 1 ))
  log "tailscaled unhealthy: $reason ($TS_WATCHDOG_BAD_COUNT/$need)"
  if (( TS_WATCHDOG_BAD_COUNT < need )); then
    return 0
  fi
  if watchdog_in_cooldown; then
    if [[ "${TS_WATCHDOG_COOLDOWN_LOGGED:-0}" -eq 0 ]]; then
      log "tailscaled unhealthy: $reason; restart skipped (cooldown)"
      TS_WATCHDOG_COOLDOWN_LOGGED=1
    fi
    return 0
  fi
  TS_WATCHDOG_COOLDOWN_LOGGED=0
  log "tailscaled unhealthy: $reason; restarting"
  restart_unhealthy_tailscaled || return 1
  watchdog_mark_cooldown
  TS_WATCHDOG_BAD_COUNT=0
  return 0
}

main() {
  local backoff
  mkdir -p "$LOCK_DIR"
  exec 9>"$LOCK_DIR/pid"
  if ! flock -n 9; then
    echo "tailscale-watchdog already running" >&2
    exit 0
  fi
  echo $$ >&9

  backoff=$MIN_BACKOFF
  log "watchdog start pid=$$"

  while true; do
    if is_running; then
      backoff=$MIN_BACKOFF
      TS_WATCHDOG_BAD_COUNT=0
      TS_WATCHDOG_COOLDOWN_LOGGED=0
      while is_running; do
        watchdog_observe_running || true
        if is_running; then
          sleep 5
        fi
      done
      log "tailscaled exited; will restart"
    else
      # Process is absent: start it. No health streak and no cooldown.
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
