#!/usr/bin/env bash
# Authenticate with TS_AUTHKEY when recovery is required.
# A logged-in session that is only down is `tailscale up` without a new key.
# Interactive browser login is the TTY fallback. Secret values are redacted.

print_authkey_next_steps() {
  echo "ERROR: tailscale up --authkey failed (TS_AUTHKEY invalid, expired, or already used)." >&2
  echo "Next step: generate a new reusable auth key in the Tailscale admin console," >&2
  echo "put it in $SECRETS_FILE as TS_AUTHKEY, and re-run ./up.sh." >&2
  echo "Or run: sudo tailscale up --hostname=${TS_HOSTNAME:-cursor}" >&2
  echo "and complete the printed browser login URL (do not invent secrets)." >&2
}

tailscale_up_with_auth() {
  echo "recover: tailscale up --hostname=$TS_HOSTNAME"
  local err rc
  set +e
  err=$(sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "recover: authenticated as $TS_HOSTNAME"
    return 0
  fi
  if [[ -n "$err" ]]; then
    printf '%s\n' "$err" | redact_secrets >&2
  fi
  print_authkey_next_steps
  if [[ -t 0 ]]; then
    echo "recover: authkey failed; starting interactive tailscale up (complete the printed browser URL)"
    sudo tailscale up --hostname="$TS_HOSTNAME"
    echo "recover: interactive login finished"
    return 0
  fi
  exit 1
}

step_auth() {
  if ! declare -F ensure_tailscale_up_if_down >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/03-tailscaled.sh"
  fi
  if [[ -z "${TS_RECOVERY_REASON+x}" ]]; then
    ensure_tailscaled
    refresh_recovery_reason
  fi
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  if [[ -n "${TS_RECOVERY_REASON:-}" ]]; then
    ensure_secrets_for_recovery
    tailscale_up_with_auth
    echo "recover: done"
    return 0
  fi
  echo "gate-ok: tailscale session is logged in"
  ensure_tailscale_up_if_down
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_auth
fi
