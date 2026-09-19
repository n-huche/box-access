#!/usr/bin/env bash
# Gate: packages + an existing Tailscale identity.
# If state is missing: ensure secrets (prompt on TTY if needed), start
# tailscaled (this host has no systemd), purge stale hostname via API,
# then authenticate once.
# Does not start sshd (upkeep does).

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
STATE=/var/lib/tailscale/tailscaled.state
STATEDIR=/var/lib/tailscale
SOCKET=/run/tailscale/tailscaled.sock
TAILSCALED=/usr/sbin/tailscaled
SECRETS_DIR=/home/box/.config/box-access
SECRETS_FILE="$SECRETS_DIR/secrets.env"

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
    # shellcheck disable=SC1090
    set -a
    source "$SECRETS_FILE"
    set +a
    echo "secrets: loaded $SECRETS_FILE"
  fi
  if [[ -f "$REPO/.env" ]]; then
    # shellcheck disable=SC1091
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
  # $1=var name  $2=prompt label
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

ensure_tailscaled_for_recovery() {
  if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "recover: tailscaled already running"
    return 0
  fi
  if [[ ! -x "$TAILSCALED" ]]; then
    echo "ERROR: missing $TAILSCALED" >&2
    return 1
  fi

  echo "recover: starting tailscaled (no systemd)"
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
  echo "recover: tailscaled socket ready"
}

recover_missing_state() {
  ensure_secrets_for_recovery
  ensure_tailscaled_for_recovery

  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "recover: state missing — purging stale hostname=$TS_HOSTNAME then authenticating"

  purge_stale_hostname

  echo "recover: tailscale up --hostname=$TS_HOSTNAME"
  sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
  echo "recover: done"
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
