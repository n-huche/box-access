#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

bash -n bootstrap.sh
bash -n lib/apt-update.sh
bash -n lib/purge-stale-hostname.sh
bash -n lib/magicdns-reclaim.sh
bash -n units/tailscale-watchdog.sh
bash -n units/sshd-watchdog.sh
python3 -m py_compile lib/purge_select.py lib/magicdns.py

for test in tests/*.test.sh; do
  echo "== $test =="
  bash "$test"
done
echo "all tests passed"
