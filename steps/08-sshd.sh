#!/usr/bin/env bash
# sshd on the Tailscale IPv4 only, port 2222. Never 0.0.0.0, *, or [::] on that port.
# Port 22 is closed: a package sshd there (often 0.0.0.0:22) is stopped.
# Sets TS_IP. Watchdogs (09) adopt this listener; they are not required to bind it.
# SSH_PORT, tailscale_ip, valid_listen_ip, sshd_listening, and stop_port22_sshd
# come from lib/listen.sh.

# shellcheck source=../lib/listen.sh
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")/lib/listen.sh"

ensure_sshd() {
  local n=0 foreign=""
  TS_IP=""
  while true; do
    TS_IP=$(tailscale_ip 2>/dev/null || true)
    if valid_listen_ip "$TS_IP" && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${TS_IP}/"; then
      break
    fi
    n=$((n + 1))
    if (( n >= SSH_IPV4_WAIT_TRIES )); then
      echo "WARN: no Tailscale IPv4 after ${SSH_IPV4_WAIT_TRIES} tries (${SSH_IPV4_WAIT_INTERVAL}s apart); sshd not started." >&2
      echo "WARN: continuing so the sshd watchdog can bind port ${SSH_PORT} when the address appears." >&2
      TS_IP=""
      return 0
    fi
    echo "ssh: waiting for Tailscale IPv4 (${n}/${SSH_IPV4_WAIT_TRIES})"
    sleep "$SSH_IPV4_WAIT_INTERVAL"
  done

  if sshd_listening "$TS_IP"; then
    foreign=$(box_access_foreign_sshd_pids "$(sshd_debug_log)")
    if [[ -n "$foreign" ]]; then
      # Only the listening pid is signaled. Session children are other pids.
      echo "ssh: replacing sshd from another checkout; active sessions stay up"
      box_access_stop_foreign_sshd_listeners "$(sshd_debug_log)"
    else
      echo "ssh: already listening on $TS_IP:$SSH_PORT"
      return 0
    fi
  fi
  if [[ ! -x "$SSHD" ]]; then
    echo "ERROR: missing $SSHD" >&2
    return 1
  fi
  if ! ensure_sshd_privsep_dir; then
    echo "WARN: could not create $SSHD_PRIVSEP_DIR; sshd will refuse to start." >&2
  fi
  echo "ssh: starting sshd ListenAddress=$TS_IP:$SSH_PORT"
  # -E is units/sshd.log in this checkout. A listener whose -E already matches
  # was returned above. ClientAlive applies on this start. A Tailscale resume
  # does not come through here; the watchdog adopts the listener.
  sudo setsid "$SSHD" -D -E "$(sshd_debug_log)" -p "$SSH_PORT" \
    -o "ListenAddress=$TS_IP" \
    -o "ClientAliveInterval=60" \
    -o "ClientAliveCountMax=30" \
    >/dev/null 2>&1 9>&- &
  sleep 1
  if sshd_listening "$TS_IP"; then
    echo "ssh: listening on $TS_IP:$SSH_PORT"
    return 0
  fi
  echo "WARN: sshd not listening on $TS_IP:$SSH_PORT; the sshd watchdog will retry." >&2
  return 0
}

close_port22() {
  local pid
  while IFS= read -r pid; do
    echo "ssh: stopped sshd pid=$pid on port 22"
  done < <(stop_port22_sshd)
}

# Wildcard check is port 2222 only; port 22 is closed by close_port22.
assert_no_wildcard_sshd() {
  if ss -lnt 2>/dev/null | grep -qE "0\\.0\\.0\\.0:${SSH_PORT}\\b|\\*:${SSH_PORT}\\b|\\[::\\]:${SSH_PORT}\\b"; then
    echo "ERROR: sshd is listening on a wildcard address port ${SSH_PORT}; refusing to leave it up." >&2
    return 1
  fi
}

step_sshd() {
  if ! declare -F ensure_tailscaled >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")")/03-tailscaled.sh"
  fi
  local repo=${REPO:-$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")}
  # An sshd watchdog from another checkout would start the old listener again.
  box_access_retire_other_watchdogs "$repo/units/sshd-watchdog.sh"
  ensure_tailscaled
  ensure_sshd
  close_port22
  assert_no_wildcard_sshd
  export TS_IP
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(realpath "$(dirname "$0")/..")/lib/common.sh"
  box_access_parse_args "$@"
  step_sshd
fi
