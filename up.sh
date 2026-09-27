#!/usr/bin/env bash
# Orchestrator for Tailscale SSH on this box.
# Sources lib/common.sh, then steps/*.sh in order.
# Flags: --install-only (stop after 01-packages), --no-watchdogs (skip 09).
# bootstrap.sh execs this script with the same arguments.
# Does not clone other repos. Does not start cron or AOS.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
box_access_parse_args "$@"

echo "repo=$REPO"

run_step() {
  local file=$1
  local func=$2
  echo "step: $(basename "$file")"
  # shellcheck source=/dev/null
  source "$file"
  "$func"
}

run_step "$REPO/steps/01-packages.sh" step_packages
if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only"
  exit 0
fi

run_step "$REPO/steps/02-secrets.sh" step_secrets
run_step "$REPO/steps/03-tailscaled.sh" step_tailscaled
run_step "$REPO/steps/04-purge.sh" step_purge
run_step "$REPO/steps/05-auth.sh" step_auth
run_step "$REPO/steps/06-magicdns.sh" step_magicdns
run_step "$REPO/steps/07-ssh-keys.sh" step_ssh_keys
run_step "$REPO/steps/08-sshd.sh" step_sshd

if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
  echo "watchdog: skipped (--no-watchdogs)"
else
  run_step "$REPO/steps/09-watchdogs.sh" step_watchdogs
fi

ts_ip="${TS_IP:-}"
if [[ -z "$ts_ip" ]]; then
  ts_ip=$(tailscale_ip 2>/dev/null || true)
fi
if [[ -n "$ts_ip" ]]; then
  echo "ssh: ready — ssh -p ${SSH_PORT} box@${ts_ip} (MagicDNS hostname ${TS_HOSTNAME:-cursor})"
fi
