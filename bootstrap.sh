#!/usr/bin/env bash
# Gate: packages + an existing Tailscale identity.
# If state is missing: purge stale hostname via API, then authenticate once.
# Does not start daemons (sshd stays separate).

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
STATE=/var/lib/tailscale/tailscaled.state
SECRETS_FILE=/home/box/.config/box-access/secrets.env

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

recover_missing_state() {
  load_secrets

  if [[ -z "${TS_API_KEY:-}" ]]; then
    echo "ERROR: missing $STATE and TS_API_KEY is not set." >&2
    echo "Put TS_API_KEY in $SECRETS_FILE (chmod 600). Refusing to create a duplicate node." >&2
    exit 1
  fi
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    echo "ERROR: missing $STATE and TS_AUTHKEY is not set." >&2
    echo "Recovery needs both TS_API_KEY (purge stale device) and TS_AUTHKEY (authenticate)." >&2
    echo "Put both in $SECRETS_FILE (chmod 600)." >&2
    exit 1
  fi

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
