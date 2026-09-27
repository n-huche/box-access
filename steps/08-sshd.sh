#!/usr/bin/env bash
# sshd on the Tailscale IPv4 only, port 2222. Never 0.0.0.0.
# Sets TS_IP. Watchdogs (09) adopt this listener; they are not required to bind it.

valid_listen_ip() {
  local ip=$1
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  case "$ip" in
    0.0.0.0|127.0.0.1) return 1 ;;
  esac
  return 0
}

sshd_listening() {
  local ip=$1
  local esc=${ip//./\\.}
  ss -lnt 2>/dev/null | grep -qE "${esc}:${SSH_PORT}\\b"
}

ensure_sshd() {
  local n=0
  TS_IP=""
  while true; do
    TS_IP=$(tailscale_ip 2>/dev/null || true)
    if valid_listen_ip "$TS_IP" && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${TS_IP}/"; then
      break
    fi
    sleep 0.2
    n=$((n + 1))
    if (( n > 50 )); then
      echo "ERROR: no Tailscale IPv4 yet" >&2
      return 1
    fi
  done

  if sshd_listening "$TS_IP"; then
    echo "ssh: already listening on $TS_IP:$SSH_PORT"
    return 0
  fi
  if [[ ! -x "$SSHD" ]]; then
    echo "ERROR: missing $SSHD" >&2
    return 1
  fi
  echo "ssh: starting sshd ListenAddress=$TS_IP:$SSH_PORT"
  sudo setsid "$SSHD" -D -e -p "$SSH_PORT" -o "ListenAddress=$TS_IP" >/dev/null 2>&1 &
  sleep 1
  if sshd_listening "$TS_IP"; then
    echo "ssh: listening on $TS_IP:$SSH_PORT"
    return 0
  fi
  echo "ERROR: sshd not listening on $TS_IP:$SSH_PORT" >&2
  return 1
}

assert_no_wildcard_sshd() {
  if ss -lnt 2>/dev/null | grep -qE "0\\.0\\.0\\.0:${SSH_PORT}\\b|\\*:${SSH_PORT}\\b|\\[::\\]:${SSH_PORT}\\b"; then
    echo "ERROR: sshd is listening on a wildcard address port ${SSH_PORT}; refusing to leave it up." >&2
    return 1
  fi
}

step_sshd() {
  if ! declare -F ensure_tailscaled >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/03-tailscaled.sh"
  fi
  ensure_tailscaled
  ensure_sshd
  assert_no_wildcard_sshd
  export TS_IP
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_sshd
fi
