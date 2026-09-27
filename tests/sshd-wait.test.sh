#!/usr/bin/env bash
# ensure_sshd uses the shared ~2 minute budget and does not abort the run
# when the Tailscale IPv4 never arrives. Watchdogs can still start.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export SSH_IPV4_WAIT_TRIES=2
export SSH_IPV4_WAIT_INTERVAL=0
# shellcheck source=../steps/08-sshd.sh
source "$ROOT/steps/08-sshd.sh"

tailscale_ip() { return 1; }

start=$(date +%s)
set +e
out=$(ensure_sshd 2>&1)
rc=$?
set -e
end=$(date +%s)
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL ensure_sshd aborted without an IPv4 (rc=$rc)"
  printf '%s\n' "$out"
  exit 1
fi
if (( end - start > 5 )); then
  echo "FAIL wait ignored SSH_IPV4_WAIT_INTERVAL (took $((end - start))s)"
  exit 1
fi
if ! grep -q 'no Tailscale IPv4' <<<"$out"; then
  echo "FAIL missing wait warning"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'sshd watchdog can bind' <<<"$out"; then
  echo "FAIL warning does not say the watchdog will continue"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'waiting for Tailscale IPv4 (1/2)' <<<"$out"; then
  echo "FAIL missing progress line"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok ensure_sshd warns and returns after the shared wait"

for f in lib/listen.sh steps/08-sshd.sh units/sshd-watchdog.sh; do
  if ! grep -q 'SSH_IPV4_WAIT_TRIES' "$ROOT/$f"; then
    echo "FAIL $f does not use SSH_IPV4_WAIT_TRIES"
    exit 1
  fi
done
echo "ok sshd wait budget is shared"
