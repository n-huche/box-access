#!/usr/bin/env bash
# Start tailscaled. Reuse /var/lib/tailscale when the state file exists.
# A missing state file is recovery (05-auth.sh), not a new identity from this step.
# A process that is up but unhealthy (not Running, no IPv4, or Self.Online
# still false after a second read) is restarted on the same state. That bounce
# does not auth and does not mint a node; purge and tailscale up still run afterwards.

tailscale_backend_state() {
  sudo tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(data.get("BackendState") or "")
' 2>/dev/null || true
}

tailscale_status_logged_out() {
  local text
  text=$(sudo tailscale status 2>&1 || true)
  grep -qiE 'NeedsLogin|Logged out|not logged in' <<<"$text"
}

tailscale_needs_recovery() {
  if ! sudo test -f "$STATE"; then
    printf '%s\n' "state-missing"
    return 0
  fi

  local backend n=0
  while true; do
    backend=$(tailscale_backend_state)
    case "$backend" in
      NeedsLogin)
        printf '%s\n' "NeedsLogin"
        return 0
        ;;
      Running|Stopped|Starting)
        break
        ;;
      NoState|"")
        n=$((n + 1))
        if (( n > 15 )); then
          break
        fi
        sleep 0.2
        continue
        ;;
      *)
        break
        ;;
    esac
  done

  if tailscale_status_logged_out; then
    printf '%s\n' "logged-out"
    return 0
  fi

  if [[ "$backend" == "NoState" || -z "$backend" ]]; then
    if ! tailscale_ip >/dev/null 2>&1; then
      printf '%s\n' "${backend:-no-state}"
      return 0
    fi
  fi

  if tailscale_ip >/dev/null 2>&1; then
    return 1
  fi

  # Logged in but down (tailscale down / Stopped) is not a dead session.
  if [[ "$backend" == "Stopped" || "$backend" == "Starting" ]]; then
    return 1
  fi

  printf '%s\n' "no-ipv4"
  return 0
}

# Stop the current daemon so it can be started again on the same state file.
# Does not delete STATE and does not log the node out.
stop_tailscaled() {
  local pid n=0
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill "$pid" 2>/dev/null || true
  done < <(pgrep -x tailscaled || true)

  while pgrep -x tailscaled >/dev/null 2>&1; do
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

  if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "ERROR: tailscaled did not exit; not starting a second copy" >&2
    return 1
  fi
  if sudo test -S "$SOCKET" || sudo test -e "$SOCKET"; then
    sudo rm -f "$SOCKET"
  fi
}

ensure_tailscaled() {
  local restart=0
  if pgrep -x tailscaled >/dev/null 2>&1; then
    if tailscale_healthy; then
      echo "tailscale: tailscaled already running"
      return 0
    fi
    restart=1
  fi
  if [[ ! -x "$TAILSCALED" ]]; then
    echo "ERROR: missing $TAILSCALED" >&2
    return 1
  fi

  if [[ "$restart" -eq 1 ]]; then
    # Same STATE / STATEDIR / SOCKET. No authkey and no new identity here.
    echo "tailscale: tailscaled running but unhealthy (${TS_HEALTH_REASON:-unknown}); restarting (reusing $STATE)"
    stop_tailscaled || return 1
  elif [[ -f "$STATE" ]] || sudo test -f "$STATE"; then
    echo "tailscale: starting tailscaled (reusing $STATE)"
  else
    echo "tailscale: starting tailscaled so recovery can authenticate (no state file yet)"
  fi
  sudo mkdir -p "$STATEDIR" /run/tailscale
  sudo setsid "$TAILSCALED" \
    -state="$STATE" \
    -statedir="$STATEDIR" \
    -socket="$SOCKET" \
    >/dev/null 2>&1 &

  local n=0
  while ! sudo test -S "$SOCKET"; do
    sleep 0.2
    n=$((n + 1))
    if (( n > 50 )); then
      echo "ERROR: tailscaled socket did not appear at $SOCKET" >&2
      return 1
    fi
  done
  echo "tailscale: socket ready"
}

ensure_tailscale_up_if_down() {
  local backend
  backend=$(tailscale_backend_state)
  if tailscale_ip >/dev/null 2>&1 && [[ "$backend" == "Running" ]]; then
    return 0
  fi
  if [[ "$backend" == "NeedsLogin" ]] || tailscale_status_logged_out; then
    return 0
  fi
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "tailscale: session present but no IPv4 (BackendState=${backend:-unknown}); bringing up hostname=$TS_HOSTNAME"
  sudo tailscale up --hostname="$TS_HOSTNAME"
}

# Sets TS_RECOVERY_REASON to a non-empty reason, or empty when the session is fine.
# Stdout of tailscale_needs_recovery is the reason only.
refresh_recovery_reason() {
  TS_RECOVERY_REASON=""
  if ! sudo test -f "$STATE"; then
    TS_RECOVERY_REASON=state-missing
    return 0
  fi
  local reason=""
  if reason=$(tailscale_needs_recovery); then
    TS_RECOVERY_REASON=$reason
  fi
}

step_tailscaled() {
  ensure_tailscaled
  refresh_recovery_reason
  if [[ -n "$TS_RECOVERY_REASON" ]]; then
    echo "tailscale: recovery needed ($TS_RECOVERY_REASON)"
  else
    echo "tailscale: state present"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_tailscaled
fi
