#!/usr/bin/env bash
# Primary entrypoint for Tailscale SSH on this box.
# Packages, secrets, tailscaled, safe purge + auth, MagicDNS reclaim,
# authorized_keys, sshd on <tailscale-ipv4>:2222, and keep-alive watchdogs.
# Does not clone other repos. Does not start cron or AOS.
# bootstrap.sh is a thin wrapper around this script.

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
TS_APT_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
TS_APT_LIST=/etc/apt/sources.list.d/tailscale.list
SSH_HOST_KEY_SNAPSHOT=""
SSH_HOST_KEYS_CHANGED=0

# shellcheck source=lib/apt-update.sh
source "$REPO/lib/apt-update.sh"
# shellcheck source=lib/purge-stale-hostname.sh
source "$REPO/lib/purge-stale-hostname.sh"
# shellcheck source=lib/magicdns-reclaim.sh
source "$REPO/lib/magicdns-reclaim.sh"

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

ssh_host_pub_checksums() {
  sudo sh -c 'sha256sum /etc/ssh/ssh_host_*_key.pub 2>/dev/null | sort' || true
}

snapshot_ssh_host_keys() {
  SSH_HOST_KEY_SNAPSHOT=$(ssh_host_pub_checksums)
}

ensure_ssh_host_keys() {
  if ! sudo test -x /usr/bin/ssh-keygen && ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ERROR: ssh-keygen is missing (openssh-server did not install?)." >&2
    return 1
  fi
  # Generate any missing host keys (reinstall after a wipe often leaves none).
  sudo ssh-keygen -A >/dev/null
  local now
  now=$(ssh_host_pub_checksums)
  if [[ "$now" != "$SSH_HOST_KEY_SNAPSHOT" ]]; then
    SSH_HOST_KEYS_CHANGED=1
    echo "ssh: host keys were created or regenerated this run"
  else
    echo "ssh: host keys unchanged"
  fi
}

print_ssh_host_fingerprints() {
  local pub line
  echo "ssh: host key fingerprints (compare to any Remote-SSH / known_hosts warning):"
  for pub in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    sudo test -f "$pub" || continue
    line=$(sudo ssh-keygen -lE sha256 -f "$pub" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      echo "  $line"
    fi
  done
}

print_known_hosts_remediation() {
  local hostname=${1:-${TS_HOSTNAME:-cursor}}
  local ip=${2:-}
  echo "ssh: clients that already have a host key will fail with REMOTE HOST IDENTIFICATION HAS CHANGED."
  echo "ssh: on the client (this box cannot edit the Mac known_hosts), remove the stale line:"
  echo "  ssh-keygen -R '[${hostname}]:${SSH_PORT}'"
  if [[ -n "$ip" ]]; then
    echo "  ssh-keygen -R '[${ip}]:${SSH_PORT}'"
  else
    echo "  ssh-keygen -R '[<tailscale-ipv4>]:${SSH_PORT}'"
  fi
}

report_ssh_host_keys() {
  local ip=${1:-}
  print_ssh_host_fingerprints
  if [[ "$SSH_HOST_KEYS_CHANGED" -eq 1 ]]; then
    print_known_hosts_remediation "${TS_HOSTNAME:-cursor}" "$ip"
  fi
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
  # printf, not an unquoted heredoc: secret values must not be re-expanded.
  {
    printf '%s\n' "# Outside git. Used by box-access recovery only."
    printf 'TS_API_KEY=%s\n' "$TS_API_KEY"
    printf 'TS_AUTHKEY=%s\n' "$TS_AUTHKEY"
    printf 'TS_HOSTNAME=%s\n' "$TS_HOSTNAME"
  } > "$SECRETS_FILE"
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

redact_secrets() {
  sed -E 's/tskey-[A-Za-z0-9._:+/=-]+/[redacted]/g'
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

  if [[ -f "$STATE" ]] || sudo test -f "$STATE"; then
    echo "tailscale: starting tailscaled (reusing $STATE)"
  else
    echo "tailscale: starting tailscaled so recovery can authenticate (no state file yet)"
  fi
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

tailscale_backend_state() {
  sudo tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(data.get("BackendState") or "")
' 2>/dev/null || true
}

tailscale_status_logged_out() {
  local text
  text=$(sudo tailscale status 2>&1 || true)
  grep -qiE 'NeedsLogin|Logged out|not logged in' <<<"$text"
}

try_purge_stale_hostname() {
  if [[ -z "${TS_API_KEY:-}" ]]; then
    echo "WARN: TS_API_KEY unset; skipping purge of hostname=${TS_HOSTNAME:-cursor}." >&2
    echo "WARN: if MagicDNS stays on ${TS_HOSTNAME:-cursor}-1, put the API key in $SECRETS_FILE and re-run." >&2
    return 0
  fi
  if purge_stale_hostname; then
    return 0
  fi
  echo "WARN: purge of stale hostname=${TS_HOSTNAME} failed (invalid TS_API_KEY, or the live Tailscale IPv4 was unknown)." >&2
  echo "WARN: continuing. A device is kept when its addresses contain this node's Tailscale IPv4." >&2
  return 0
}

print_authkey_next_steps() {
  echo "ERROR: tailscale up --authkey failed (TS_AUTHKEY invalid, expired, or already used)." >&2
  echo "Next step: generate a new reusable auth key in the Tailscale admin console," >&2
  echo "put it in $SECRETS_FILE as TS_AUTHKEY, and re-run ./up.sh." >&2
  echo "Or run: sudo tailscale up --hostname=${TS_HOSTNAME:-cursor}" >&2
  echo "and complete the printed browser login URL (do not invent secrets)." >&2
}

tailscale_up_with_auth() {
  echo "recover: tailscale up --hostname=$TS_HOSTNAME"
  local err rc
  set +e
  err=$(sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "recover: authenticated as $TS_HOSTNAME"
    return 0
  fi
  if [[ -n "$err" ]]; then
    printf '%s\n' "$err" | redact_secrets >&2
  fi
  print_authkey_next_steps
  if [[ -t 0 ]]; then
    echo "recover: authkey failed; starting interactive tailscale up (complete the printed browser URL)"
    sudo tailscale up --hostname="$TS_HOSTNAME"
    echo "recover: interactive login finished"
    return 0
  fi
  exit 1
}

recover_tailscale() {
  local reason=${1:-unknown}
  ensure_secrets_for_recovery
  ensure_tailscaled

  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "recover: $reason — purging stale hostname=$TS_HOSTNAME (keeping the live node) then authenticating as $TS_HOSTNAME"

  prepare_purge_self_markers
  try_purge_stale_hostname
  tailscale_up_with_auth
  echo "recover: done"
}

tailscale_needs_recovery() {
  if ! sudo test -f "$STATE"; then
    printf '%s\n' "state-missing"
    return 0
  fi

  local backend n=0
  while true; do
    backend=$(tailscale_backend_state)
    case "$backend" in
      NeedsLogin)
        printf '%s\n' "NeedsLogin"
        return 0
        ;;
      Running|Stopped|Starting)
        break
        ;;
      NoState|"")
        n=$((n + 1))
        if (( n > 15 )); then
          break
        fi
        sleep 0.2
        continue
        ;;
      *)
        break
        ;;
    esac
  done

  if tailscale_status_logged_out; then
    printf '%s\n' "logged-out"
    return 0
  fi

  if [[ "$backend" == "NoState" || -z "$backend" ]]; then
    if ! tailscale_ip >/dev/null 2>&1; then
      printf '%s\n' "${backend:-no-state}"
      return 0
    fi
  fi

  if tailscale_ip >/dev/null 2>&1; then
    return 1
  fi

  # Logged in but down (tailscale down / Stopped) is not a dead session.
  if [[ "$backend" == "Stopped" || "$backend" == "Starting" ]]; then
    return 1
  fi

  printf '%s\n' "no-ipv4"
  return 0
}

ensure_tailscale_up_if_down() {
  local backend
  backend=$(tailscale_backend_state)
  if tailscale_ip >/dev/null 2>&1 && [[ "$backend" == "Running" ]]; then
    return 0
  fi
  if [[ "$backend" == "NeedsLogin" ]] || tailscale_status_logged_out; then
    return 0
  fi
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "tailscale: session present but no IPv4 (BackendState=${backend:-unknown}); bringing up hostname=$TS_HOSTNAME"
  sudo tailscale up --hostname="$TS_HOSTNAME"
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
  local esc=${ip//./\\.}
  ss -lnt 2>/dev/null | grep -qE "${esc}:${SSH_PORT}\\b"
}

valid_listen_ip() {
  local ip=$1
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  case "$ip" in
    0.0.0.0|127.0.0.1) return 1 ;;
  esac
  return 0
}

ensure_sshd() {
  local n=0 ip=
  while true; do
    ip=$(tailscale_ip) || ip=""
    if valid_listen_ip "$ip" && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${ip}/"; then
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
  echo "ssh: starting sshd ListenAddress=$ip:$SSH_PORT"
  sudo setsid "$SSHD" -D -e -p "$SSH_PORT" -o "ListenAddress=$ip" >/dev/null 2>&1 &
  sleep 1
  if sshd_listening "$ip"; then
    echo "ssh: listening on $ip:$SSH_PORT"
    return 0
  fi
  echo "ERROR: sshd not listening on $ip:$SSH_PORT" >&2
  return 1
}

start_watchdogs() {
  local ts="$REPO/units/tailscale-watchdog.sh"
  local sshw="$REPO/units/sshd-watchdog.sh"
  if [[ ! -x "$ts" || ! -x "$sshw" ]]; then
    echo "ERROR: watchdog scripts missing under $REPO/units" >&2
    return 1
  fi
  echo "watchdog: starting tailscaled keep-alive ($ts)"
  nohup "$ts" >/dev/null 2>&1 &
  sleep 1
  echo "watchdog: starting sshd keep-alive ($sshw)"
  nohup "$sshw" >/dev/null 2>&1 &
}

wait_for_sshd() {
  local n=0 ip=
  while (( n < 30 )); do
    ip=$(tailscale_ip 2>/dev/null || true)
    if valid_listen_ip "$ip" && sshd_listening "$ip"; then
      if ss -lnt 2>/dev/null | grep -qE "0\\.0\\.0\\.0:${SSH_PORT}\\b|\\*:${SSH_PORT}\\b"; then
        echo "ERROR: sshd is listening on a wildcard address port ${SSH_PORT}" >&2
        return 1
      fi
      echo "ssh: listening on ${ip}:${SSH_PORT}"
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  echo "ERROR: sshd not listening on Tailscale IPv4:${SSH_PORT}" >&2
  if [[ -f "$REPO/units/sshd-watchdog.log" ]]; then
    echo "ssh: last sshd-watchdog log lines:" >&2
    tail -n 20 "$REPO/units/sshd-watchdog.log" >&2 || true
  fi
  return 1
}

echo "repo=$REPO"

# Chrome's apt source can block the first update. Disable it before any apt call.
disable_hanging_chrome_apt_sources

snapshot_ssh_host_keys
ensure_tailscale_apt_repo

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

ensure_python3
ensure_ssh_host_keys

if [[ "${1:-}" == "--install-only" ]]; then
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  report_ssh_host_keys
  echo "install-only"
  exit 0
fi

load_secrets
export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"

if [[ "$SSH_HOST_KEYS_CHANGED" -eq 1 ]]; then
  report_ssh_host_keys
fi

recover_reason=""
if ! sudo test -f "$STATE"; then
  recover_tailscale "state-missing"
else
  ensure_tailscaled
  if recover_reason=$(tailscale_needs_recovery); then
    recover_tailscale "$recover_reason"
  else
    echo "gate-ok: tailscale session is logged in"
    ensure_tailscale_up_if_down
  fi
fi

reclaim_magicdns_if_needed

ensure_ssh_authorized_key
ensure_tailscaled
start_watchdogs
if ! wait_for_sshd; then
  echo "ssh: keep-alive has not bound sshd yet; starting it once" >&2
  ensure_sshd
fi

ts_ip=""
ts_ip=$(tailscale_ip) || ts_ip=""
if ss -lnt 2>/dev/null | grep -qE "0\\.0\\.0\\.0:${SSH_PORT}\\b|\\*:${SSH_PORT}\\b|\\[::\\]:${SSH_PORT}\\b"; then
  echo "ERROR: sshd is listening on a wildcard address port ${SSH_PORT}; refusing to leave it up." >&2
  exit 1
fi
report_ssh_host_keys "$ts_ip"
if [[ -n "$ts_ip" ]]; then
  echo "ssh: ready — ssh -p ${SSH_PORT} box@${ts_ip} (MagicDNS hostname ${TS_HOSTNAME})"
fi
