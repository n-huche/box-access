#!/usr/bin/env bash
# sshd watchdog binds the Tailscale IPv4 only and can see foreign listeners.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../units/sshd-watchdog.sh
source "$ROOT/units/sshd-watchdog.sh"

if valid_listen_ip "100.64.0.8"; then
  echo "ok accepts tailscale ipv4"
else
  echo "FAIL rejected a tailscale ipv4"
  exit 1
fi
for bad in "" 0.0.0.0 127.0.0.1 "*" "::" "10.1.2.3 extra"; do
  if valid_listen_ip "$bad"; then
    echo "FAIL accepted ListenAddress=$bad"
    exit 1
  fi
done
echo "ok rejects wildcard and empty listen addresses"

export BOX_ACCESS_SS_TEXT=$'LISTEN 0 128 100.64.0.8:2222 0.0.0.0:* users:(("sshd",pid=111,fd=3))\nLISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=222,fd=4))\nLISTEN 0 128 100.64.0.9:2222 0.0.0.0:* users:(("sshd",pid=333,fd=5))\nLISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=444,fd=6))'
got=$(sshd_pids_except "100.64.0.8")
if [[ "$got" != $'222\n333' ]]; then
  echo "FAIL foreign pids: $(printf %q "$got")"
  exit 1
fi
echo "ok foreign port-2222 sshd pids exclude the live tailscale ip and port 22"

# Sourcing the unit must not enter the keep-alive loop.
echo "ok sourcing sshd watchdog did not start the loop"
