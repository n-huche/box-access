#!/usr/bin/env bash
# Keep Tailscale + sshd up. Identity and ListenAddress live in this repo.
# Does not start cron or AOS.

set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
ACCESS="${HOME_BOX}/access"

nohup "$ACCESS/tailscale-watchdog.sh" >/dev/null 2>&1 &
sleep 1
nohup "$ACCESS/sshd-watchdog.sh" >/dev/null 2>&1 &
echo "started: tailscale + sshd watchdogs"
pgrep -af '/home/box/access/.*-watchdog\.sh' || true
