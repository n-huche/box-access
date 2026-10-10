#!/usr/bin/env bash
# Keep tailscaled alive by reusing /var/lib/tailscale (the current identity).
# Does not create a node. Missing state is ./up.sh recovery, not this loop.
# A live but unhealthy daemon is restarted only after TS_WATCHDOG_UNHEALTHY_READS
# bad samples (default 3) and at most once per TS_WATCHDOG_RESTART_COOLDOWN
# seconds (default 600). The cooldown timestamp is tailscale-watchdog.cooldown.
# A VM pause (wall clock ahead of /proc/uptime by more than TS_RESUME_SKEW_SECS,
# default 5) restarts tailscaled immediately on the same state file, ignoring
# the bad-read streak and the cooldown, at most once per
# TS_RESUME_MIN_INTERVAL_SECS (default 60). Other health restarts stay on
# TS_WATCHDOG_UNHEALTHY_READS (default 3) and TS_WATCHDOG_RESTART_COOLDOWN
# (default 600). Daemon output goes to units/tailscaled.log, not this script's log.
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
  pgrep -x tailscaled >/dev/null 2>&1 9>&-
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
  local daemon_log
  daemon_log=$(tailscaled_prepare_daemon_log)
  # 9>&- so sudo/setsid/tailscaled do not inherit the watchdog lock.
  sudo TZ=UTC setsid "$BIN" \
    -state="$STATE" \
    -statedir="$STATEDIR" \
    -socket="$SOCKET" \
    >>"$daemon_log" 2>&1 9>&- &
  local pid=$!
  sleep "${TS_WATCHDOG_START_WAIT:-1}" 9>&-
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
  done < <(pgrep -x tailscaled 9>&- || true)

  while is_running; do
    sleep 0.2 9>&-
    n=$((n + 1))
    if (( n > 25 )); then
      while read -r pid; do
        [[ -n "$pid" ]] || continue
        sudo kill -9 "$pid" 2>/dev/null || true
      done < <(pgrep -x tailscaled 9>&- || true)
      sleep 0.2 9>&-
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

# 0 when a resume restart ran (caller skips the health sample).
# 1 when this iteration should use the normal health rules.
# A second pause inside TS_RESUME_MIN_INTERVAL_SECS does not restart again.
watchdog_on_resume() {
  local interval now
  if ! tailscale_resume_from_pause; then
    return 1
  fi
  interval=${TS_RESUME_MIN_INTERVAL_SECS:-60}
  now=$(tailscale_wall_secs)
  if [[ -n "${TS_RESUME_LAST_RESTART:-}" ]] && (( now - TS_RESUME_LAST_RESTART < interval )); then
    return 1
  fi
  log "resume detected (paused ${TS_RESUME_PAUSED}s)"
  if ! restart_unhealthy_tailscaled; then
    return 1
  fi
  TS_RESUME_LAST_RESTART=$now
  TS_WATCHDOG_BAD_COUNT=0
  TS_WATCHDOG_COOLDOWN_LOGGED=0
  return 0
}

# One loop pass while tailscaled is up.
watchdog_tick() {
  if watchdog_on_resume; then
    return 0
  fi
  watchdog_observe_running || true
}

main() {
  local backoff
  watchdog_acquire_lock "$(basename "$0")" || exit 0

  backoff=$MIN_BACKOFF
  log "watchdog start pid=$$"

  while true; do
    if is_running; then
      backoff=$MIN_BACKOFF
      TS_WATCHDOG_BAD_COUNT=0
      TS_WATCHDOG_COOLDOWN_LOGGED=0
      while is_running; do
        watchdog_tick || true
        if is_running; then
          sleep 5 9>&-
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
      sleep "$backoff" 9>&-
      backoff=$(( backoff * 2 ))
      if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
