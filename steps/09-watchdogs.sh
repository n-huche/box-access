#!/usr/bin/env bash
# Start the vendored tailscaled and sshd keep-alive loops.
# They live in units/ and adopt processes that are already up.
# ./up.sh skips this step on --no-watchdogs.

step_watchdogs() {
  if ! declare -F ensure_tailscaled >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/03-tailscaled.sh"
  fi
  ensure_tailscaled
  local ts="$REPO/units/tailscale-watchdog.sh"
  local sshw="$REPO/units/sshd-watchdog.sh"
  if [[ ! -x "$ts" || ! -x "$sshw" ]]; then
    echo "ERROR: watchdog scripts missing under $REPO/units" >&2
    return 1
  fi
  echo "watchdog: starting tailscaled keep-alive ($ts)"
  nohup "$ts" >/dev/null 2>&1 &
  sleep 1
  echo "watchdog: starting sshd keep-alive ($sshw)"
  nohup "$sshw" >/dev/null 2>&1 &
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
    echo "watchdog: skipped (--no-watchdogs)"
    exit 0
  fi
  step_watchdogs
fi
