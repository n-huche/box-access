#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
readme=$ROOT/README.md
boot=$ROOT/bootstrap.sh

need() {
  local file=$1 needle=$2
  if ! grep -q -- "$needle" "$file"; then
    echo "FAIL missing [$needle] in ${file#"$ROOT"/}"
    exit 1
  fi
}

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
need "$readme" "ssh-keygen -R"
need "$readme" "Tailscale IPv4"
need "$boot" "reclaim_magicdns_if_needed"
need "$boot" "start_watchdogs"
need "$boot" "disable_hanging_chrome_apt_sources"
need "$boot" "prepare_purge_self_markers"
need "$ROOT/units/tailscale-watchdog.sh" "STATE=/var/lib/tailscale/tailscaled.state"
need "$ROOT/units/tailscale-watchdog.sh" "STATEDIR=/var/lib/tailscale"
need "$ROOT/units/tailscale-watchdog.sh" "SOCKET=/run/tailscale/tailscaled.sock"
need "$ROOT/units/tailscale-watchdog.sh" "-state="
need "$ROOT/units/tailscale-watchdog.sh" "-statedir="
need "$ROOT/units/tailscale-watchdog.sh" "-socket="
need "$ROOT/units/tailscale-watchdog.sh" "flock -n 9"
need "$ROOT/units/sshd-watchdog.sh" "ListenAddress="
need "$ROOT/packages.txt" "openssh-server"
need "$ROOT/packages.txt" "tailscale"

if grep -R -n -E 'tskey-(api|auth)-[A-Za-z0-9]{8,}' \
  --exclude-dir=.git --exclude-dir=tests "$ROOT" >/dev/null; then
  echo "FAIL secret-like token in the tree"
  exit 1
fi
echo "ok readme and entrypoint describe the lifecycle"
