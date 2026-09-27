#!/usr/bin/env bash
# Tailscale apt repo, openssh-server, chrome apt hang workaround.
# --install-only stops after this step (plus host-key fingerprints).

# Host-key helpers. Sourcing does not run step_ssh_keys.
# shellcheck source=07-ssh-keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/07-ssh-keys.sh"

os_release_var() {
  local key=$1
  awk -F= -v k="$key" '
    $1 == k {
      v = $2
      gsub(/\r/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      print v
      exit
    }
  ' /etc/os-release
}

tailscale_apt_repo_configured() {
  if ! grep -Rqs -- 'pkgs.tailscale.com' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    return 1
  fi
  sudo test -s "$TS_APT_KEYRING"
}

ensure_tailscale_apt_repo() {
  if tailscale_apt_repo_configured; then
    echo "tailscale-apt: repo already configured"
    return 0
  fi

  if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release is missing; cannot detect the Debian suite for the Tailscale apt repo." >&2
    return 1
  fi

  local os suite
  os=$(os_release_var ID)
  suite=$(os_release_var VERSION_CODENAME)
  case "$os" in
    debian)
      os=debian
      ;;
    ubuntu)
      os=ubuntu
      suite=$(os_release_var UBUNTU_CODENAME)
      [[ -n "$suite" ]] || suite=$(os_release_var VERSION_CODENAME)
      ;;
    *)
      echo "ERROR: Tailscale apt repo helper supports debian/ubuntu (got ID=${os:-unknown})." >&2
      echo "Production is Debian (suite from VERSION_CODENAME, e.g. trixie)." >&2
      return 1
      ;;
  esac

  if [[ -z "$suite" ]]; then
    echo "ERROR: could not detect Debian/Ubuntu suite from /etc/os-release (VERSION_CODENAME empty)." >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "tailscale-apt: installing curl to fetch the official repo"
    apt_get_update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  fi

  echo "tailscale-apt: adding official stable repo os=$os suite=$suite"
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/${os}/${suite}.noarmor.gpg" \
    | sudo tee "$TS_APT_KEYRING" >/dev/null
  sudo chmod 0644 "$TS_APT_KEYRING"
  curl -fsSL "https://pkgs.tailscale.com/stable/${os}/${suite}.tailscale-keyring.list" \
    | sudo tee "$TS_APT_LIST" >/dev/null
  sudo chmod 0644 "$TS_APT_LIST"
  echo "tailscale-apt: wrote $TS_APT_LIST (signed-by $TS_APT_KEYRING)"
  apt_get_update
}

ensure_pkg() {
  local pkg=$1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "pkg-ok: $pkg"
    return 0
  fi
  echo "pkg-install: $pkg"
  apt_get_update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

ensure_python3() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  echo "pkg-install: python3"
  apt_get_update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3
}

step_packages() {
  # Chrome's apt source can block the first update. Disable it before any apt call.
  disable_hanging_chrome_apt_sources

  snapshot_ssh_host_keys
  ensure_tailscale_apt_repo

  local pkg
  while read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    ensure_pkg "$pkg"
  done < "$REPO/packages.txt"

  ensure_python3
  ensure_ssh_host_keys

  if [[ "$INSTALL_ONLY" -eq 1 ]]; then
    export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
    report_ssh_host_keys
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_packages
  if [[ "$INSTALL_ONLY" -eq 1 ]]; then
    echo "install-only"
    exit 0
  fi
fi
