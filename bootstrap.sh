#!/usr/bin/env bash
# Instala pacotes + scripts em /home/box e (por padrão) roda start.sh.
# Fonte da verdade: este repo. Identidade Tailscale/SSH/gh não entra aqui.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
INFRA_DST="${HOME_BOX}/infra"
STATE=/var/lib/tailscale/tailscaled.state
DISTRO_HOST_KEY=/etc/ssh/ssh_host_ed25519_key
HOST_KEY="${INFRA_DST}/ssh_host_ed25519_key"
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

ensure_host_key() {
  mkdir -p "$INFRA_DST"
  if sudo test -f "$HOST_KEY"; then
    sudo chmod 600 "$HOST_KEY" >/dev/null 2>&1 || true
    if ! sudo test -f "${HOST_KEY}.pub"; then
      sudo ssh-keygen -y -f "$HOST_KEY" | sudo tee "${HOST_KEY}.pub" >/dev/null
      sudo chmod 644 "${HOST_KEY}.pub"
    fi
    sudo chown root:root "$HOST_KEY" "${HOST_KEY}.pub" >/dev/null 2>&1 || true
    echo "host-key: keep $HOST_KEY"
    return 0
  fi
  if sudo test -f "$DISTRO_HOST_KEY"; then
    echo "host-key: copy $DISTRO_HOST_KEY -> $HOST_KEY"
    sudo cp "$DISTRO_HOST_KEY" "$HOST_KEY"
    if sudo test -f "${DISTRO_HOST_KEY}.pub"; then
      sudo cp "${DISTRO_HOST_KEY}.pub" "${HOST_KEY}.pub"
    else
      sudo ssh-keygen -y -f "$HOST_KEY" | sudo tee "${HOST_KEY}.pub" >/dev/null
    fi
  else
    echo "host-key: generate $HOST_KEY"
    sudo ssh-keygen -q -t ed25519 -f "$HOST_KEY" -N "" -C "box-infra"
  fi
  sudo chmod 600 "$HOST_KEY"
  sudo chmod 644 "${HOST_KEY}.pub" >/dev/null 2>&1 || true
  sudo chown root:root "$HOST_KEY" "${HOST_KEY}.pub" >/dev/null 2>&1 || true
}

# Para unidades da distro. Não mata o nosso sshd da 2222 (isso é o watchdog).
disable_distro_sshd_units() {
  sudo systemctl disable --now ssh.socket sshd.socket ssh.service sshd.service >/dev/null 2>&1 || true
  sudo service ssh stop >/dev/null 2>&1 || true
  sudo service sshd stop >/dev/null 2>&1 || true
  echo "sshd-distro: unidades desabilitadas (best-effort)"
}

install_reboot_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "WARN: crontab ausente (best-effort; @reboot não instalado)"
    return 0
  fi
  local tmp marker line
  tmp=$(mktemp)
  marker='# box-infra cold start (best-effort; cron often missing after Update)'
  line="@reboot /bin/bash ${HOME_BOX}/start.sh >>${INFRA_DST}/cron-reboot.log 2>&1"
  crontab -l 2>/dev/null | grep -v 'box-infra cold start' | grep -vF "${HOME_BOX}/start.sh" >"$tmp" || true
  printf '%s\n' "$marker" >>"$tmp"
  printf '%s\n' "$line" >>"$tmp"
  if crontab "$tmp"; then
    echo "cron-ok: @reboot ${HOME_BOX}/start.sh"
  else
    echo "WARN: não consegui gravar crontab (best-effort)"
  fi
  rm -f "$tmp"
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
install -m 755 "$REPO/sshd-watchdog.sh" "${INFRA_DST}/sshd-watchdog.sh"
install -m 755 "$REPO/tailscale-watchdog.sh" "${INFRA_DST}/tailscale-watchdog.sh"
ensure_host_key
install_reboot_cron
echo "installed: ${HOME_BOX}/start.sh + ${HOME_BOX}/status.sh + ${INFRA_DST}/*.sh"

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start (sem parar/subir processos)"
  exit 0
fi

disable_distro_sshd_units
# Recarrega o código novo dos watchdogs; os daemons (tailscaled/sshd) ficam
# para o watchdog adotar ou substituir se não forem o nosso listener.
pkill -f 'sshd-watchdog.sh' >/dev/null 2>&1 || true
pkill -f 'tailscale-watchdog.sh' >/dev/null 2>&1 || true
sleep 1

exec "${HOME_BOX}/start.sh"
