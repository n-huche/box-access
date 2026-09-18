#!/usr/bin/env bash
# Disco vazio → git clone + este script. Junta Tailscale, sshd :2222, aos up.
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
INFRA_DST="${HOME_BOX}/infra"
STATE=/var/lib/tailscale/tailscaled.state
AUTHKEY_FILE="$REPO/secrets/ts-authkey"
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

ensure_tailscale_pkg() {
  if dpkg -s tailscale >/dev/null 2>&1; then
    echo "pkg-ok: tailscale"
    return 0
  fi
  echo "pkg-install: tailscale"
  sudo apt-get update -y
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale; then
    return 0
  fi
  echo "pkg-install: tailscale via install.sh (apt repo ausente)"
  curl -fsSL https://tailscale.com/install.sh | sudo sh || true
  dpkg -s tailscale >/dev/null 2>&1
}

ensure_box_user() {
  if ! id -u box >/dev/null 2>&1; then
    if [[ -d "$HOME_BOX" ]]; then
      sudo useradd -M -s /bin/bash -d "$HOME_BOX" box
    else
      sudo useradd -m -s /bin/bash -d "$HOME_BOX" box
    fi
    echo "user: created box"
  fi
  echo 'box ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/box-infra >/dev/null
  sudo chmod 440 /etc/sudoers.d/box-infra
  sudo mkdir -p "$HOME_BOX" "$INFRA_DST" "$HOME_BOX/.ssh"
}

install_authorized_keys() {
  local src="$REPO/authorized_keys"
  if [[ ! -f "$src" ]]; then
    echo "WARN: sem $src — sshd sobe, mas ninguém entra por chave"
    return 0
  fi
  sudo install -m 700 -d "$HOME_BOX/.ssh"
  sudo install -m 600 -o box -g box "$src" "$HOME_BOX/.ssh/authorized_keys"
  echo "authorized_keys: installed"
}

# Repo (secrets/) vence; senão backup em infra; senão o que o apt gerou.
persist_host_keys() {
  sudo mkdir -p "$INFRA_DST"
  local name inf sys repo_key
  for name in ssh_host_ed25519_key ssh_host_rsa_key ssh_host_ecdsa_key; do
    inf="${INFRA_DST}/${name}"
    sys="/etc/ssh/${name}"
    repo_key="${REPO}/secrets/${name}"
    if [[ -f "$repo_key" ]]; then
      sudo cp "$repo_key" "$sys"
      [[ -f "${repo_key}.pub" ]] && sudo cp "${repo_key}.pub" "${sys}.pub" || true
      sudo cp "$sys" "$inf"
      sudo test -f "${sys}.pub" && sudo cp "${sys}.pub" "${inf}.pub" || true
      sudo chmod 600 "$sys"
      sudo chmod 644 "${sys}.pub" 2>/dev/null || true
      echo "host-key: from repo $name"
    elif sudo test -f "$inf"; then
      sudo cp "$inf" "$sys"
      sudo test -f "${inf}.pub" && sudo cp "${inf}.pub" "${sys}.pub" || true
      sudo chmod 600 "$sys"
      echo "host-key: restore $name"
    elif sudo test -f "$sys"; then
      sudo cp "$sys" "$inf"
      sudo test -f "${sys}.pub" && sudo cp "${sys}.pub" "${inf}.pub" || true
      echo "host-key: backup $name"
    fi
  done
}

read_authkey() {
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    printf '%s' "$TS_AUTHKEY"
    return 0
  fi
  if [[ -f "$AUTHKEY_FILE" ]]; then
    tr -d '[:space:]' <"$AUTHKEY_FILE"
    return 0
  fi
  return 1
}

# State no disco: reusa o nó. Disco vazio: auth key reutilizável no repo privado.
join_tailscale() {
  local key="" ip="" n=0
  ip=$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)
  if [[ -n "$ip" ]]; then
    echo "tailscale: already up $ip"
    return 0
  fi

  start_tailscaled() {
    sudo mkdir -p /var/lib/tailscale /run/tailscale
    if pgrep -x tailscaled >/dev/null 2>&1; then
      return 0
    fi
    sudo setsid /usr/sbin/tailscaled \
      -state="$STATE" \
      -statedir=/var/lib/tailscale \
      -socket=/run/tailscale/tailscaled.sock \
      >/dev/null 2>&1 &
    sleep 2
  }

  if sudo test -s "$STATE"; then
    echo "tailscale-state: present"
    start_tailscaled
    n=0
    while (( n < 15 )); do
      ip=$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)
      [[ -n "$ip" ]] && break
      sleep 1
      n=$((n+1))
    done
    if [[ -n "$ip" ]]; then
      echo "tailscale-ip: $ip"
      return 0
    fi
  fi

  if ! key=$(read_authkey) || [[ -z "$key" ]]; then
    echo "ERROR: sem state Tailscale e sem secrets/ts-authkey (ou TS_AUTHKEY)." >&2
    echo "Uma vez: auth key reutilizável (não efémera) em secrets/ts-authkey;" >&2
    echo "  chmod 600 secrets/ts-authkey && git add -f secrets/ts-authkey && git commit && git push" >&2
    echo "Depois disto, clone + ./bootstrap.sh junta o nó sozinho." >&2
    exit 1
  fi

  start_tailscaled
  echo "tailscale: joining as hostname=box"
  sudo tailscale up --authkey="$key" --hostname=box --ssh=false --accept-dns=false
  n=0
  ip=""
  while (( n < 30 )); do
    ip=$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)
    [[ -n "$ip" ]] && break
    sleep 1
    n=$((n+1))
  done
  if [[ -z "$ip" ]]; then
    echo "ERROR: tailscale up não deu IPv4" >&2
    exit 1
  fi
  echo "tailscale-ip: $ip"
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
  if [[ "$pkg" == tailscale ]]; then
    ensure_tailscale_pkg
  else
    ensure_pkg "$pkg"
  fi
done < "$REPO/packages.txt"

ensure_box_user
sudo mkdir -p "$INFRA_DST"
sudo install -m 755 -o box -g box "$REPO/start.sh" "${HOME_BOX}/start.sh"
sudo install -m 755 -o box -g box "$REPO/status.sh" "${HOME_BOX}/status.sh"
sudo install -m 644 -o box -g box "$REPO/sshd_config" "${INFRA_DST}/sshd_config"
sudo install -m 755 -o box -g box "$REPO/sshd-watchdog.sh" "${INFRA_DST}/sshd-watchdog.sh"
sudo install -m 755 -o box -g box "$REPO/tailscale-watchdog.sh" "${INFRA_DST}/tailscale-watchdog.sh"
persist_host_keys
install_authorized_keys
sudo chown -R box:box "$HOME_BOX"
echo "installed: ${HOME_BOX}/start.sh + ${HOME_BOX}/status.sh + ${INFRA_DST}/*"

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start"
  exit 0
fi

stop_distro_sshd
join_tailscale
pkill -f 'sshd-watchdog.sh' >/dev/null 2>&1 || true
pkill -f 'tailscale-watchdog.sh' >/dev/null 2>&1 || true
sleep 1

sudo -u box -H env HOME="$HOME_BOX" HOME_BOX="$HOME_BOX" "${HOME_BOX}/start.sh"
"${HOME_BOX}/status.sh" || true
