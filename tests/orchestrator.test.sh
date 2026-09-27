#!/usr/bin/env bash
# Orchestrator wiring, flag parsing, purge skip, and secret redaction.
# Does not start tailscaled, sshd, or apt.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

order=$(grep -oE 'steps/[0-9]{2}-[a-z0-9-]+\.sh' "$ROOT/up.sh")
expected=$(printf '%s\n' \
  steps/01-packages.sh \
  steps/02-secrets.sh \
  steps/03-tailscaled.sh \
  steps/04-purge.sh \
  steps/05-auth.sh \
  steps/06-magicdns.sh \
  steps/07-ssh-keys.sh \
  steps/08-sshd.sh \
  steps/09-watchdogs.sh)
if [[ "$order" != "$expected" ]]; then
  echo "FAIL step order"
  printf '%s\n' "$order"
  exit 1
fi
echo "ok up.sh runs steps in order"

line() { grep -n "$1" "$ROOT/up.sh" | head -n1 | cut -d: -f1; }
p01=$(line 'steps/01-packages.sh')
inst=$(line 'INSTALL_ONLY')
p02=$(line 'steps/02-secrets.sh')
nw=$(line 'NO_WATCHDOGS')
p09=$(line 'steps/09-watchdogs.sh')
if (( p01 >= inst || inst >= p02 || nw >= p09 )); then
  echo "FAIL install-only must stop before secrets, and --no-watchdogs before step 09"
  exit 1
fi
echo "ok --install-only stops after packages; --no-watchdogs skips step 09"

box_access_parse_args --no-watchdogs --install-only
if [[ "$INSTALL_ONLY" -ne 1 || "$NO_WATCHDOGS" -ne 1 ]]; then
  echo "FAIL flags were not both set"
  exit 1
fi
box_access_parse_args
if [[ "$INSTALL_ONLY" -ne 0 || "$NO_WATCHDOGS" -ne 0 ]]; then
  echo "FAIL flags were not cleared"
  exit 1
fi
set +e
( box_access_parse_args --not-a-flag >/dev/null 2>&1 )
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL unknown flag was accepted"
  exit 1
fi
echo "ok flag parser"

# Sourcing steps must not start daemons. Functions become available.
# shellcheck source=../steps/01-packages.sh
source "$ROOT/steps/01-packages.sh"
# shellcheck source=../steps/03-tailscaled.sh
source "$ROOT/steps/03-tailscaled.sh"
# shellcheck source=../steps/04-purge.sh
source "$ROOT/steps/04-purge.sh"
for func in step_packages step_purge step_ssh_keys refresh_recovery_reason; do
  if ! declare -F "$func" >/dev/null; then
    echo "FAIL missing function $func"
    exit 1
  fi
done
TS_RECOVERY_REASON=""
prepare_purge_self_markers() { echo "FAIL prepare was called"; exit 1; }
try_purge_stale_hostname() { echo "FAIL purge was called"; exit 1; }
step_purge >/dev/null
echo "ok purge step skips when there is no recovery"

secret_api='tskey-api-testvalue1'
secret_auth='tskey-auth-testvalue1'
redacted=$(printf '%s %s\n' "$secret_api" "$secret_auth" | redact_secrets)
if printf '%s' "$redacted" | grep -q 'testvalue1'; then
  echo "FAIL redact left a secret fragment"
  exit 1
fi
if [[ "$redacted" != "[redacted] [redacted]" ]]; then
  echo "FAIL redact output was unexpected"
  exit 1
fi
echo "ok redact_secrets hides tskey values"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME_BOX="$TMP/home"
box_access_set_paths
export TS_API_KEY="$secret_api"
export TS_AUTHKEY="$secret_auth"
export TS_HOSTNAME=cursor
logged=$(write_secrets_file 2>&1)
if printf '%s' "$logged" | grep -q 'testvalue1'; then
  echo "FAIL write_secrets_file printed a secret"
  exit 1
fi
logged=$(load_secrets 2>&1)
if printf '%s' "$logged" | grep -q 'testvalue1'; then
  echo "FAIL load_secrets printed a secret"
  exit 1
fi
if [[ "$TS_HOSTNAME" != cursor ]]; then
  echo "FAIL hostname was not loaded"
  exit 1
fi
echo "ok secrets load and write do not print values"
