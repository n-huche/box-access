#!/usr/bin/env bash
# Delete other tailnet devices named TS_HOSTNAME. Skip the live node by
# Tailscale IPv4 (API device id and local Self.ID are different forms).
# No-op when this boot is not a recovery. MagicDNS reclaim purges again
# only when the DNS name is stuck.

box_need_tailscaled_funcs() {
  if ! declare -F refresh_recovery_reason >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/03-tailscaled.sh"
  fi
}

step_purge() {
  box_need_tailscaled_funcs
  if [[ -z "${TS_RECOVERY_REASON+x}" ]]; then
    ensure_tailscaled
    refresh_recovery_reason
  fi
  if [[ -z "${TS_RECOVERY_REASON:-}" ]]; then
    echo "purge: skipped (no recovery)"
    return 0
  fi

  ensure_secrets_for_recovery
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  echo "recover: $TS_RECOVERY_REASON — purging stale hostname=$TS_HOSTNAME (keeping the live node) then authenticating as $TS_HOSTNAME"
  prepare_purge_self_markers
  try_purge_stale_hostname
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_purge
fi
