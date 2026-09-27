#!/usr/bin/env bash
# Host-key fingerprints, known_hosts hints, and authorized_keys.
# Functions are sourced by 01-packages (snapshot around apt) and by ./up.sh.

snapshot_ssh_host_keys() {
  SSH_HOST_KEY_SNAPSHOT=$(ssh_host_pub_checksums)
}

ssh_host_pub_checksums() {
  sudo sh -c 'sha256sum /etc/ssh/ssh_host_*_key.pub 2>/dev/null | sort' || true
}

ensure_ssh_host_keys() {
  if ! sudo test -x /usr/bin/ssh-keygen && ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ERROR: ssh-keygen is missing (openssh-server did not install?)." >&2
    return 1
  fi
  # Generate any missing host keys (reinstall after a wipe often leaves none).
  sudo ssh-keygen -A >/dev/null
  local now
  now=$(ssh_host_pub_checksums)
  if [[ "$now" != "$SSH_HOST_KEY_SNAPSHOT" ]]; then
    SSH_HOST_KEYS_CHANGED=1
    echo "ssh: host keys were created or regenerated this run"
  else
    echo "ssh: host keys unchanged"
  fi
}

print_ssh_host_fingerprints() {
  local pub line
  echo "ssh: host key fingerprints (compare to any Remote-SSH / known_hosts warning):"
  for pub in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    sudo test -f "$pub" || continue
    line=$(sudo ssh-keygen -lE sha256 -f "$pub" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      echo "  $line"
    fi
  done
}

print_known_hosts_remediation() {
  local hostname=${1:-${TS_HOSTNAME:-cursor}}
  local ip=${2:-}
  echo "ssh: clients that already have a host key will fail with REMOTE HOST IDENTIFICATION HAS CHANGED."
  echo "ssh: on the client (this box cannot edit the Mac known_hosts), remove the stale line:"
  echo "  ssh-keygen -R '[${hostname}]:${SSH_PORT}'"
  if [[ -n "$ip" ]]; then
    echo "  ssh-keygen -R '[${ip}]:${SSH_PORT}'"
  else
    echo "  ssh-keygen -R '[<tailscale-ipv4>]:${SSH_PORT}'"
  fi
}

report_ssh_host_keys() {
  local ip=${1:-}
  print_ssh_host_fingerprints
  if [[ "$SSH_HOST_KEYS_CHANGED" -eq 1 ]]; then
    print_known_hosts_remediation "${TS_HOSTNAME:-cursor}" "$ip"
  fi
}

ensure_ssh_authorized_key() {
  mkdir -p "${HOME_BOX}/.ssh"
  chmod 700 "${HOME_BOX}/.ssh"
  if [[ -s "$AUTH_KEYS" ]]; then
    echo "ssh: authorized_keys present"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: $AUTH_KEYS is empty and stdin is not a TTY." >&2
    echo "Put an SSH public key in $AUTH_KEYS (chmod 600)." >&2
    exit 1
  fi
  printf 'SSH public key (required): ' >&2
  local line=
  read -r line
  if [[ -z "$line" ]]; then
    echo "ERROR: empty SSH public key." >&2
    exit 1
  fi
  printf '%s\n' "$line" >>"$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  echo "ssh: wrote $AUTH_KEYS"
}

step_ssh_keys() {
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  ensure_ssh_authorized_key
  local ts_ip=""
  ts_ip=$(tailscale_ip 2>/dev/null || true)
  report_ssh_host_keys "$ts_ip"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_ssh_keys
fi
