# Tailscale IPv4 and sshd listen helpers.
# Safe to source from lib/common.sh, lib/tailscale-health.sh, and units/sshd-watchdog.sh.
# Constants and functions only: no apt, no secrets, no `set -e`, no daemons.

if [[ -z "${BOX_ACCESS_LISTEN_LOADED:-}" ]]; then
  BOX_ACCESS_LISTEN_LOADED=1
  # sshd for this box. Port 22 stays closed (see stop_port22_sshd).
  SSH_PORT="${SSH_PORT:-2222}"
  # Shared by steps/08-sshd.sh and units/sshd-watchdog.sh.
  # 40 * 3s is about 2 minutes.
  SSH_IPV4_WAIT_INTERVAL="${SSH_IPV4_WAIT_INTERVAL:-3}"
  SSH_IPV4_WAIT_TRIES="${SSH_IPV4_WAIT_TRIES:-40}"
fi

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

# Accept a dotted IPv4 that can be a Tailscale address.
# Reject empty, 0.0.0.0, and 127.0.0.1. Callers also require the address
# to be configured on tailscale0 before sshd binds it.
valid_listen_ip() {
  local ip=$1
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  case "$ip" in
    0.0.0.0|127.0.0.1) return 1 ;;
  esac
  return 0
}

# True when sshd is listening on $1:$SSH_PORT. Does not look at port 22.
sshd_listening() {
  local ip=$1
  local esc=${ip//./\\.}
  ss -lnt 2>/dev/null | grep -qE "${esc}:${SSH_PORT}\\b"
}

# Print pids of sshd listening on port 22, any address.
# BOX_ACCESS_SS22_TEXT, when set, replaces `ss` output (tests only).
port22_sshd_pids() {
  local ss_text="${BOX_ACCESS_SS22_TEXT-}"
  if [[ -z "$ss_text" ]]; then
    ss_text=$(sudo ss -lptn 'sport = :22' 2>/dev/null || true)
  fi
  grep -E ':22[[:space:]]' <<<"$ss_text" | grep -F '"sshd"' \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
}

# This box is reached on <tailscale-ipv4>:$SSH_PORT only: stop any sshd on
# port 22 (a package sshd listens on 0.0.0.0:22). Prints each stopped pid.
stop_port22_sshd() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill "$pid" 2>/dev/null || true
    printf '%s\n' "$pid"
  done < <(port22_sshd_pids)
}
