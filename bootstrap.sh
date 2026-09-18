#!/usr/bin/env bash
# Gate: packages + an existing Tailscale identity.
# Does not start daemons.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
STATE=/var/lib/tailscale/tailscaled.state

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

echo "repo=$REPO"

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

if ! sudo test -f "$STATE"; then
  echo "ERROR: missing $STATE — will not create a new Tailscale identity." >&2
  echo "Restore the node state or authenticate by hand. Then run again." >&2
  exit 1
fi

echo "gate-ok: tailscale state present"

if [[ "${1:-}" == "--install-only" ]]; then
  echo "install-only"
fi
