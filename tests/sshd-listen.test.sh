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

if [[ "$SSH_PORT" != "2222" ]]; then
  echo "FAIL SSH_PORT=$SSH_PORT (want 2222 from lib/listen.sh)"
  exit 1
fi
if ! declare -F tailscale_ip >/dev/null || ! declare -F sshd_listening >/dev/null; then
  echo "FAIL listen helpers were not loaded with the watchdog"
  exit 1
fi
if grep -q '^tailscale_ip()' "$ROOT/units/sshd-watchdog.sh" || grep -q '^PORT=' "$ROOT/units/sshd-watchdog.sh"; then
  echo "FAIL watchdog still defines its own port or tailscale_ip"
  exit 1
fi
if ! grep -q 'lib/listen.sh' "$ROOT/units/sshd-watchdog.sh" || ! grep -q 'listen.sh' "$ROOT/lib/common.sh"; then
  echo "FAIL lib/listen.sh is not sourced by both the watchdog and common.sh"
  exit 1
fi
echo "ok watchdog and orchestrator share lib/listen.sh (SSH_PORT=$SSH_PORT)"

export BOX_ACCESS_SS_TEXT=$'LISTEN 0 128 100.64.0.8:2222 0.0.0.0:* users:(("sshd",pid=111,fd=3))\nLISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=222,fd=4))\nLISTEN 0 128 100.64.0.9:2222 0.0.0.0:* users:(("sshd",pid=333,fd=5))\nLISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=444,fd=6))'
got=$(sshd_pids_except "100.64.0.8")
if [[ "$got" != $'222\n333' ]]; then
  echo "FAIL foreign pids: $(printf %q "$got")"
  exit 1
fi
echo "ok foreign port-2222 sshd pids exclude the live tailscale ip and port 22"

export BOX_ACCESS_SS22_TEXT=$'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\nLISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=444,fd=6))\nLISTEN 0 128 [::]:22 [::]:* users:(("sshd",pid=444,fd=7))\nLISTEN 0 128 100.64.0.8:2222 0.0.0.0:* users:(("sshd",pid=111,fd=3))\nLISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("dropbear",pid=555,fd=3))'
got=$(port22_sshd_pids)
if [[ "$got" != "444" ]]; then
  echo "FAIL port 22 sshd pids: $(printf %q "$got")"
  exit 1
fi
BOX_ACCESS_SS22_TEXT=$'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
got=$(port22_sshd_pids)
if [[ -n "$got" ]]; then
  echo "FAIL port 22 closed but got pids: $(printf %q "$got")"
  exit 1
fi
unset BOX_ACCESS_SS22_TEXT
if ! grep -q 'close_port22' "$ROOT/steps/08-sshd.sh" || ! grep -q 'close_port22' "$ROOT/units/sshd-watchdog.sh"; then
  echo "FAIL step 08 and the sshd watchdog must both close port 22"
  exit 1
fi
echo "ok port 22 sshd pids are found once and never include port 2222"

# Sourcing the unit must not enter the keep-alive loop.
echo "ok sourcing sshd watchdog did not start the loop"
