#!/usr/bin/env bash
# Cold start: sobe processos que reboot/Update da box não reiniciaram.
# Watchdogs em loop. Não toca na plataforma Grok Bot/Cursor.
# Uso: start.sh | start.sh status
set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
INFRA="${HOME_BOX}/infra"
HERE=$(cd "$(dirname "$0")" && pwd)

status_bin() {
  if [[ -x "$HERE/status.sh" ]]; then
    printf '%s\n' "$HERE/status.sh"
    return 0
  fi
  if [[ -x "${HOME_BOX}/status.sh" ]]; then
    printf '%s\n' "${HOME_BOX}/status.sh"
    return 0
  fi
  return 1
}

if [[ "${1:-}" == "status" ]]; then
  exec "$(status_bin)"
fi

nohup "$INFRA/tailscale-watchdog.sh" >/dev/null 2>&1 &
sleep 1
nohup "$INFRA/sshd-watchdog.sh" >/dev/null 2>&1 &
echo "started: tailscale-watchdog + sshd-watchdog"
pgrep -af 'tailscale-watchdog|sshd-watchdog' || true

if sb=$(status_bin); then
  sleep 2
  "$sb" || true
fi

# AOS é outro sistema. Se estiver neste disco, só o cold-starta.
AOS=/workspace/aos/scripts/aos
if [[ -x "$AOS" ]]; then
  "$AOS" up
fi
