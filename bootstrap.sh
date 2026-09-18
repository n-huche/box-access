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

# Fingerprint estável: backup em infra, restore para /etc/ssh (sshd continua a ler as chaves da distro).
persist_host_keys() {
  mkdir -p "$INFRA_DST"
  local name inf sys
  for name in ssh_host_ed25519_key ssh_host_rsa_key ssh_host_ecdsa_key; do
    inf="${INFRA_DST}/${name}"
    sys="/etc/ssh/${name}"
    if sudo test -f "$inf"; then
      sudo cp "$inf" "$sys"
      sudo test -f "${inf}.pub" && sudo cp "${inf}.pub" "${sys}.pub" || true
      sudo chmod 600 "$sys"
      sudo chmod 644 "${sys}.pub" 2>/dev/null || true
      echo "host-key: restore $name"
    elif sudo test -f "$sys"; then
      sudo cp "$sys" "$inf"
      sudo test -f "${sys}.pub" && sudo cp "${sys}.pub" "${inf}.pub" || true
      echo "host-key: backup $name"
    fi
  done
}

stop_distro_sshd() {
  sudo systemctl disable --now ssh.socket sshd.socket ssh.service sshd.service >/dev/null 2>&1 || true
  sudo service ssh stop >/dev/null 2>&1 || true
  sudo service sshd stop >/dev/null 2>&1 || true
  echo "sshd-distro: stop :22 (best-effort)"
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
install -m 755 "$REPO/status.sh" "${HOME_BOX}/status.sh"
install -m 644 "$REPO/sshd_config" "${INFRA_DST}/sshd_config"
install -m 755 "$REPO/sshd-watchdog.sh" "${INFRA_DST}/sshd-watchdog.sh"
install -m 755 "$REPO/tailscale-watchdog.sh" "${INFRA_DST}/tailscale-watchdog.sh"
persist_host_keys
echo "installed: ${HOME_BOX}/start.sh + ${HOME_BOX}/status.sh + ${INFRA_DST}/*"

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start"
  exit 0
fi

stop_distro_sshd
# Código novo dos watchdogs: mata só os watchdogs; tailscaled/sshd o novo processo adota.
pkill -f 'sshd-watchdog.sh' >/dev/null 2>&1 || true
pkill -f 'tailscale-watchdog.sh' >/dev/null 2>&1 || true
sleep 1

exec "${HOME_BOX}/start.sh"
