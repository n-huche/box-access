#!/usr/bin/env bash
# Gate: everything needed to reach this box over Tailscale SSH.
# Packages, identity, authorized_keys, and a one-shot start of tailscaled
# + sshd on <tailscale-ipv4>:2222. Does not babysit them (host persistence
# is not this repo). Does not clone other repos. Does not start cron or AOS.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
STATE=/var/lib/tailscale/tailscaled.state
STATEDIR=/var/lib/tailscale
SOCKET=/run/tailscale/tailscaled.sock
TAILSCALED=/usr/sbin/tailscaled
SSHD=/usr/sbin/sshd
SSH_PORT=2222
SECRETS_DIR="${HOME_BOX}/.config/box-access"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
AUTH_KEYS="${HOME_BOX}/.ssh/authorized_keys"

# shellcheck source=lib/purge-stale-hostname.sh
source "$REPO/lib/purge-stale-hostname.sh"

ensure_pkg() {
  local pkg=$1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "pkg-ok: $pkg"
    return 0
  fi
  echo "pkg-install: $pkg"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

load_secrets() {
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "$SECRETS_FILE"
    set +a
    echo "secrets: loaded $SECRETS_FILE"
  fi
  if [[ -f "$REPO/.env" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "$REPO/.env"
    set +a
    echo "secrets: loaded $REPO/.env"
  fi
}

write_secrets_file() {
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  umask 077
  cat > "$SECRETS_FILE" <<EOF
# Outside git. Used by box-access recovery only.
TS_API_KEY=${TS_API_KEY}
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME}
EOF
  chmod 600 "$SECRETS_FILE"
  echo "secrets: wrote $SECRETS_FILE (chmod 600)"
}

prompt_secret() {
  local var=$1 label=$2 value=
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: $var is unset and stdin is not a TTY (cannot prompt)." >&2
    echo "Create $SECRETS_FILE with TS_API_KEY, TS_AUTHKEY, TS_HOSTNAME." >&2
    exit 1
  fi
  printf '%s: ' "$label" >&2
  read -r -s value
  printf '\n' >&2
  if [[ -z "$value" ]]; then
    echo "ERROR: empty $var." >&2
    exit 1
  fi
  printf -v "$var" '%s' "$value"
  export "$var"
}

prompt_hostname() {
  local value=
  if [[ -n "${TS_HOSTNAME:-}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    TS_HOSTNAME=cursor
    export TS_HOSTNAME
    return 0
  fi
  printf 'TS_HOSTNAME [%s]: ' "cursor" >&2
  read -r value
  TS_HOSTNAME="${value:-cursor}"
  export TS_HOSTNAME
}

ensure_secrets_for_recovery() {
  load_secrets

  local missing=0
  [[ -z "${TS_API_KEY:-}" ]] && missing=1
  [[ -z "${TS_AUTHKEY:-}" ]] && missing=1

  if [[ "$missing" -eq 0 ]]; then
    export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
    if [[ ! -f "$SECRETS_FILE" ]]; then
      write_secrets_file
    fi
    return 0
  fi

  echo "secrets: recovery needs TS_API_KEY + TS_AUTHKEY (paste from password manager)"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "secrets: will create $SECRETS_FILE"
  fi

  prompt_secret TS_API_KEY "TS_API_KEY (hidden)"
  prompt_secret TS_AUTHKEY "TS_AUTHKEY (hidden)"
  prompt_hostname
  write_secrets_file
}

ensure_tailscaled() {
  if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "tailscale: tailscaled already running"
    return 0
  fi
  if [[ ! -x "$TAILSCALED" ]]; then
    echo "ERROR: missing $TAILSCALED" >&2
    return 1
  fi

  echo "tailscale: starting tailscaled (no systemd; one-shot, not a watchdog)"
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

recover_missing_state() {
  ensure_secrets_for_recovery
  ensure_tailscaled

  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "recover: state missing — purging stale hostname=$TS_HOSTNAME then authenticating"

  purge_stale_hostname

  echo "recover: tailscale up --hostname=$TS_HOSTNAME"
  sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
  echo "recover: done"
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

sshd_listening() {
  local ip=$1
  ss -lntp 2>/dev/null | grep -qE "${ip}:${SSH_PORT}\\b"
}

ensure_sshd() {
  local n=0 ip=
  while true; do
    ip=$(tailscale_ip) || ip=""
    if [[ -n "$ip" ]] && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${ip}/"; then
      break
    fi
    sleep 0.2
    n=$((n + 1))
    if (( n > 50 )); then
      echo "ERROR: no Tailscale IPv4 yet" >&2
      return 1
    fi
  done

  if sshd_listening "$ip"; then
    echo "ssh: already listening on $ip:$SSH_PORT"
    return 0
  fi
  if [[ ! -x "$SSHD" ]]; then
    echo "ERROR: missing $SSHD" >&2
    return 1
  fi
  echo "ssh: starting sshd ListenAddress=$ip:$SSH_PORT (one-shot, not a watchdog)"
  sudo setsid "$SSHD" -D -e -p "$SSH_PORT" -o "ListenAddress=$ip" >/dev/null 2>&1 &
  sleep 1
  if sshd_listening "$ip"; then
    echo "ssh: listening on $ip:$SSH_PORT"
    return 0
  fi
  echo "ERROR: sshd not listening on $ip:$SSH_PORT" >&2
  return 1
}

echo "repo=$REPO"

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

if [[ "${1:-}" == "--install-only" ]]; then
  echo "install-only"
  exit 0
fi

if ! sudo test -f "$STATE"; then
  recover_missing_state
else
  echo "gate-ok: tailscale state present"
fi

ensure_ssh_authorized_key
ensure_tailscaled
ensure_sshd
