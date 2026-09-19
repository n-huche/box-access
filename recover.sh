#!/usr/bin/env bash
# One-shot VM recovery after a full reset.
# Order: secrets → clone repos → box-access (Tailscale identity) → box-upkeep (daemons + aos up).
# Does not touch sand-*/.cursor/chrome-profile.

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
HOME_BOX="${HOME_BOX:-/home/box}"
SECRETS_FILE="${SECRETS_FILE:-$HOME_BOX/.config/box-access/secrets.env}"
TS_HOSTNAME="${TS_HOSTNAME:-cursor}"

GH_USER="${GH_USER:-n-huche}"
REPO_ACCESS="https://github.com/${GH_USER}/box-access.git"
REPO_UPKEEP="https://github.com/${GH_USER}/box-upkeep.git"
REPO_AOS="https://github.com/${GH_USER}/aos.git"
REPO_AOS_USER="https://github.com/${GH_USER}/aos-user.git"

log() { printf 'recover: %s\n' "$*"; }
die() { printf 'recover ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

clone_or_pull() {
  local url=$1 dest=$2
  if [[ -d "$dest/.git" ]]; then
    log "pull $dest"
    git -C "$dest" pull --ff-only
  elif [[ -d "$dest" ]]; then
    die "$dest exists but is not a git repo"
  else
    log "clone $url → $dest"
    git clone "$url" "$dest"
  fi
}

need_cmd git
need_cmd curl
need_cmd python3
need_cmd sudo

mkdir -p "$WORKSPACE" "$HOME_BOX/.config/box-access"
chmod 700 "$HOME_BOX/.config/box-access"

if [[ ! -f "$SECRETS_FILE" ]]; then
  die "missing $SECRETS_FILE
Create it (chmod 600) with:
  TS_API_KEY=tskey-api-...
  TS_AUTHKEY=tskey-auth-...
  TS_HOSTNAME=$TS_HOSTNAME"
fi
chmod 600 "$SECRETS_FILE"
# shellcheck disable=SC1090
set -a
source "$SECRETS_FILE"
set +a

[[ -n "${TS_API_KEY:-}" ]] || die "TS_API_KEY empty in $SECRETS_FILE"
[[ -n "${TS_AUTHKEY:-}" ]] || die "TS_AUTHKEY empty in $SECRETS_FILE"
export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"

log "workspace=$WORKSPACE hostname=$TS_HOSTNAME"

clone_or_pull "$REPO_ACCESS" "$WORKSPACE/box-access"
clone_or_pull "$REPO_UPKEEP" "$WORKSPACE/box-upkeep"
clone_or_pull "$REPO_AOS" "$WORKSPACE/aos"

if [[ ! -d "$WORKSPACE/aos/user/.git" ]]; then
  log "clone private aos-user (needs gh auth or HTTPS credentials)"
  clone_or_pull "$REPO_AOS_USER" "$WORKSPACE/aos/user"
else
  log "pull aos/user"
  git -C "$WORKSPACE/aos/user" pull --ff-only || true
fi

log "1/2 box-access bootstrap (purge stale + auth if state missing)"
"$WORKSPACE/box-access/bootstrap.sh"

log "2/2 box-upkeep bootstrap (watchdogs + aos up)"
"$WORKSPACE/box-upkeep/bootstrap.sh"

log "done"
log "check: tailscale status | head"
log "check: ssh -p 2222 box@\$(tailscale ip -4)"
log "check: $WORKSPACE/aos/scripts/aos validate"
