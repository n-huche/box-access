#!/usr/bin/env bash
# Authenticate with TS_AUTHKEY when recovery is required.
# A logged-in session that is only down is `tailscale up` without a new key.
# Interactive browser login is the TTY fallback. Secret values are redacted.
# A daemon that cannot be reached on its socket is reported as that, with
# status 3, not as a bad auth key (status 1). Runs before 05-purge.sh, so no
# device is deleted until this node is up.

# Status when tailscaled cannot be reached (socket missing or daemon down).
TS_DAEMON_UNREACHABLE_RC=3

print_authkey_next_steps() {
  echo "ERROR: tailscale up --authkey failed (TS_AUTHKEY invalid, expired, or already used)." >&2
  echo "Next step: generate a new reusable auth key in the Tailscale admin console," >&2
  echo "put it in $SECRETS_FILE as TS_AUTHKEY, and re-run ./up.sh." >&2
  echo "Or run: sudo tailscale --socket=$(tailscale_socket) up --hostname=${TS_HOSTNAME:-cursor}" >&2
  echo "and complete the printed browser login URL (do not invent secrets)." >&2
}

print_daemon_unreachable() {
  local sock
  sock=$(tailscale_socket)
  echo "ERROR: tailscaled is not reachable on $sock (socket missing or daemon down)." >&2
  echo "This is not an auth key problem: keep TS_AUTHKEY as it is." >&2
  echo "Next step: check that tailscaled runs with -socket=$sock (pgrep -a tailscaled," >&2
  echo "sudo test -S $sock), then re-run ./up.sh." >&2
}

tailscale_up_with_auth() {
  echo "recover: tailscale up --hostname=$TS_HOSTNAME"
  local err rc
  if ! tailscale_daemon_reachable; then
    print_daemon_unreachable
    exit "$TS_DAEMON_UNREACHABLE_RC"
  fi
  set +e
  err=$(ts_cli up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" 2>&1)
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "recover: authenticated as $TS_HOSTNAME"
    return 0
  fi
  if [[ -n "$err" ]]; then
    printf '%s\n' "$err" | redact_secrets >&2
  fi
  if tailscale_daemon_unreachable_text "$err"; then
    print_daemon_unreachable
    exit "$TS_DAEMON_UNREACHABLE_RC"
  fi
  print_authkey_next_steps
  if [[ -t 0 ]]; then
    echo "recover: authkey failed; starting interactive tailscale up (complete the printed browser URL)"
    ts_cli up --hostname="$TS_HOSTNAME"
    echo "recover: interactive login finished"
    return 0
  fi
  exit 1
}

step_auth() {
  if ! declare -F ensure_tailscale_up_if_down >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")")/03-tailscaled.sh"
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
  source "$(realpath "$(dirname "$0")/..")/lib/common.sh"
  box_access_parse_args "$@"
  step_auth
fi
