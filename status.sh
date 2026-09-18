#!/usr/bin/env bash
# A box está acessível? Não toca em processos. Exit 0 só com acesso ok.
set -u

HOME_BOX="${HOME_BOX:-/home/box}"
PORT=2222
ok=1

if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "tailscaled: up"
else
  echo "tailscaled: down"
  ok=0
fi

ip=$(sudo -n tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
if [[ -z "$ip" ]]; then
  ip=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
fi
if [[ -n "$ip" ]]; then
  echo "tailscale-ip: $ip"
else
  echo "tailscale-ip: none"
  ok=0
fi

if [[ -n "$ip" ]] && ss -lntp 2>/dev/null | grep sshd | grep -qF "${ip}:${PORT}"; then
  echo "sshd: ${ip}:${PORT}"
else
  echo "sshd: not listening ${ip:-?}:${PORT}"
  ok=0
fi

if ss -lntp 2>/dev/null | grep sshd | grep -qE ':22[[:space:]]'; then
  echo "sshd-extra: something on :22"
  ok=0
fi

for w in tailscale-watchdog sshd-watchdog; do
  pidfile="${HOME_BOX}/infra/${w}.lock/pid"
  pid=""
  [[ -r "$pidfile" ]] && pid=$(tr -d '[:space:]' <"$pidfile")
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
    echo "${w}: up pid=${pid}"
  else
    echo "${w}: down"
  fi
done

if [[ "$ok" -eq 1 ]]; then
  echo "acesso: ok"
  exit 0
fi
echo "acesso: fail"
exit 1
