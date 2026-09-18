#!/usr/bin/env bash
# Cold start: sobe processos que reboot/Update da box não reiniciaram.
# Watchdogs em loop. Não toca na plataforma Grok Bot/Cursor.
set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
INFRA="${HOME_BOX}/infra"

nohup "$INFRA/tailscale-watchdog.sh" >/dev/null 2>&1 &
sleep 1
nohup "$INFRA/sshd-watchdog.sh" >/dev/null 2>&1 &
echo "started: tailscale-watchdog + sshd-watchdog"
pgrep -af 'tailscale-watchdog|sshd-watchdog' || true

# AOS é outro sistema. Se estiver neste disco, só o cold-starta.
AOS=/workspace/aos/scripts/aos
if [[ -x "$AOS" ]]; then
  "$AOS" up || echo "WARN: aos up falhou" >&2
fi
