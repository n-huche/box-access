#!/usr/bin/env bash
# Portão: pacotes + identidade Tailscale já existente.
# Não arranca daemons. Não chama o AOS. Processos = box-keep.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
STATE=/var/lib/tailscale/tailscaled.state
KEEP="${WORKSPACE:-/workspace}/box-keep"

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
echo "home=$HOME_BOX"

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

if ! sudo test -f "$STATE"; then
  echo "ERROR: missing $STATE — não vou criar identidade Tailscale nova." >&2
  echo "Recupere o estado do nó ou autentique na mão. Depois rode de novo." >&2
  exit 1
fi

echo "gate-ok: tailscale state present"

if [[ "${1:-}" == "--install-only" ]]; then
  echo "install-only: skip keep hint"
  exit 0
fi

echo "next: start processes with ${KEEP}/bootstrap.sh"
if [[ ! -x "${KEEP}/bootstrap.sh" ]]; then
  echo "WARN: box-keep not found at ${KEEP}" >&2
fi
