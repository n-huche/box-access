#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
readme=$ROOT/README.md
entry=$ROOT/up.sh
wrapper=$ROOT/bootstrap.sh

need() {
  local file=$1 needle=$2
  if ! grep -q -- "$needle" "$file"; then
    echo "FAIL missing [$needle] in ${file#"$ROOT"/}"
    exit 1
  fi
}

need "$readme" "./up.sh"
need "$readme" "./bootstrap.sh"
need "$readme" "secrets.env"
need "$readme" "TS_API_KEY"
need "$readme" "TS_AUTHKEY"
need "$readme" "MagicDNS"
need "$readme" "google-chrome.sources"
need "$readme" "dl.google.com"
need "$readme" "units/tailscale-watchdog.sh"
need "$readme" "units/sshd-watchdog.sh"
need "$readme" "2222"
need "$readme" "port 22"
need "$readme" "Port 22 stays closed"
need "$readme" "about 2 minutes"
need "$readme" "ssh-keygen -R"
need "$readme" "Tailscale IPv4"
need "$readme" "--install-only"
need "$readme" "--no-watchdogs"
need "$readme" "VM console"
need "$readme" "box-upkeep"
need "$readme" "steps/01-packages.sh"
need "$readme" "steps/09-watchdogs.sh"
need "$readme" "lib/common.sh"
need "$readme" "lib/listen.sh"
need "$entry" "lib/common.sh"
need "$entry" "steps/01-packages.sh"
need "$entry" "steps/02-secrets.sh"
need "$entry" "steps/04-purge.sh"
need "$entry" "steps/06-magicdns.sh"
need "$entry" "steps/08-sshd.sh"
need "$entry" "steps/09-watchdogs.sh"
need "$entry" "--install-only"
need "$entry" "--no-watchdogs"
need "$ROOT/lib/common.sh" "load_secrets"
need "$ROOT/steps/01-packages.sh" "disable_hanging_chrome_apt_sources"
need "$ROOT/steps/04-purge.sh" "prepare_purge_self_markers"
need "$ROOT/steps/05-auth.sh" "./up.sh"
need "$ROOT/steps/06-magicdns.sh" "reclaim_magicdns_if_needed"
need "$ROOT/steps/08-sshd.sh" "ListenAddress="
need "$ROOT/steps/09-watchdogs.sh" "tailscale-watchdog.sh"
need "$wrapper" 'exec'
need "$wrapper" 'up.sh'
if grep -q 'authkey' "$entry"; then
  echo "FAIL up.sh should only orchestrate; authkey lives in steps/05-auth.sh"
  exit 1
fi
if grep -q 'tailscale up' "$wrapper"; then
  echo "FAIL bootstrap.sh is not a thin wrapper"
  exit 1
fi
need "$ROOT/units/tailscale-watchdog.sh" "./up.sh"
need "$ROOT/units/tailscale-watchdog.sh" "STATE=/var/lib/tailscale/tailscaled.state"
need "$ROOT/units/tailscale-watchdog.sh" "STATEDIR=/var/lib/tailscale"
need "$ROOT/units/tailscale-watchdog.sh" "SOCKET=/run/tailscale/tailscaled.sock"
need "$ROOT/units/tailscale-watchdog.sh" "-state="
need "$ROOT/units/tailscale-watchdog.sh" "-statedir="
need "$ROOT/units/tailscale-watchdog.sh" "-socket="
need "$ROOT/lib/listen.sh" "flock -n 9"
need "$ROOT/units/tailscale-watchdog.sh" "watchdog_acquire_lock"
need "$ROOT/units/sshd-watchdog.sh" "watchdog_acquire_lock"
need "$ROOT/units/sshd-watchdog.sh" "ListenAddress="
need "$ROOT/packages.txt" "openssh-server"
need "$ROOT/packages.txt" "tailscale"

if grep -R -n -E 'tskey-(api|auth)-[A-Za-z0-9]{8,}' \
  --exclude-dir=.git --exclude-dir=tests "$ROOT" >/dev/null; then
  echo "FAIL secret-like token in the tree"
  exit 1
fi
echo "ok readme and entrypoint describe the lifecycle"
