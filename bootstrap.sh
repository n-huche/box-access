#!/usr/bin/env bash
# Instala pacotes + scripts em /home/box e (por padrão) roda start.sh.
# Fonte da verdade: este repo. Identidade Tailscale/SSH/gh não entra aqui.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
INFRA_DST="${HOME_BOX}/infra"
STATE=/var/lib/tailscale/tailscaled.state
INSTALL_ONLY=0

if [[ "${1:-}" == "--install-only" ]]; then
  INSTALL_ONLY=1
fi

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

mkdir -p "$INFRA_DST"
install -m 755 "$REPO/start.sh" "${HOME_BOX}/start.sh"
install -m 755 "$REPO/sshd-watchdog.sh" "${INFRA_DST}/sshd-watchdog.sh"
install -m 755 "$REPO/tailscale-watchdog.sh" "${INFRA_DST}/tailscale-watchdog.sh"
echo "installed: ${HOME_BOX}/start.sh + ${INFRA_DST}/*.sh"

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start"
  exit 0
fi

exec "${HOME_BOX}/start.sh"
