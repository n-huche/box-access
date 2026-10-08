# Shared paths, logging, and secrets for ./up.sh.
# Sourced by the orchestrator and by a step that is executed directly.
# Never print TS_API_KEY, TS_AUTHKEY, or any other secret value.

if [[ -z "${BOX_ACCESS_COMMON_LOADED:-}" ]]; then
  BOX_ACCESS_COMMON_LOADED=1
  set -euo pipefail
fi

box_access_set_paths() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BOX_LIB_DIR=$lib_dir
  REPO=$(cd "$lib_dir/.." && pwd)
  HOME_BOX="${HOME_BOX:-/home/box}"
  STATE=/var/lib/tailscale/tailscaled.state
  STATEDIR=/var/lib/tailscale
  SOCKET=/run/tailscale/tailscaled.sock
  TAILSCALED=/usr/sbin/tailscaled
  SSHD=/usr/sbin/sshd
  SECRETS_DIR="${HOME_BOX}/.config/box-access"
  SECRETS_FILE="$SECRETS_DIR/secrets.env"
  AUTH_KEYS="${HOME_BOX}/.ssh/authorized_keys"
  TS_APT_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
  TS_APT_LIST=/etc/apt/sources.list.d/tailscale.list
  SSH_HOST_KEY_SNAPSHOT="${SSH_HOST_KEY_SNAPSHOT:-}"
  SSH_HOST_KEYS_CHANGED="${SSH_HOST_KEYS_CHANGED:-0}"
  INSTALL_ONLY="${INSTALL_ONLY:-0}"
  NO_WATCHDOGS="${NO_WATCHDOGS:-0}"
}

box_access_set_paths

# shellcheck source=listen.sh
source "$BOX_LIB_DIR/listen.sh"
# shellcheck source=tailscale-health.sh
source "$BOX_LIB_DIR/tailscale-health.sh"
# shellcheck source=apt-update.sh
source "$BOX_LIB_DIR/apt-update.sh"
# shellcheck source=purge-stale-hostname.sh
source "$BOX_LIB_DIR/purge-stale-hostname.sh"
# shellcheck source=magicdns-reclaim.sh
source "$BOX_LIB_DIR/magicdns-reclaim.sh"

log() {
  printf '%s\n' "$*"
}

box_access_parse_args() {
  INSTALL_ONLY=0
  NO_WATCHDOGS=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --install-only) INSTALL_ONLY=1 ;;
      --no-watchdogs) NO_WATCHDOGS=1 ;;
      *)
        echo "ERROR: unknown argument: $arg" >&2
        echo "Usage: ./up.sh [--install-only] [--no-watchdogs]" >&2
        exit 1
        ;;
    esac
  done
}

redact_secrets() {
  sed -E 's/tskey-[A-Za-z0-9._:+/=-]+/[redacted]/g'
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
