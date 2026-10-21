#!/usr/bin/env bash
# Delete other tailnet devices named TS_HOSTNAME. Runs after 04-auth.sh and
# only once this node is Running with a Tailscale IPv4, so a failed auth never
# leaves the tailnet without a device. The live node is kept by that IPv4
# (API device id and local Self.ID are different forms).
# No-op when this boot is not a recovery. A node that authenticated as
# TS_HOSTNAME-1 because the old device still existed gets its name back in
# 06-magicdns.sh. MagicDNS reclaim purges again only when the DNS name is stuck.

# Tries to see Running + IPv4 before giving up on the purge (1s apart).
TS_PURGE_WAIT_TRIES="${TS_PURGE_WAIT_TRIES:-30}"
TS_PURGE_WAIT_INTERVAL="${TS_PURGE_WAIT_INTERVAL:-1}"

box_need_tailscaled_funcs() {
  if ! declare -F refresh_recovery_reason >/dev/null 2>&1; then
    # shellcheck source=03-tailscaled.sh
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")")/03-tailscaled.sh"
  fi
}

# 0 once BackendState is Running and this node has a Tailscale IPv4.
wait_for_running_ipv4() {
  local i
  for ((i = 0; i < TS_PURGE_WAIT_TRIES; i++)); do
    tailscale_read_status
    if [[ "$TS_STATUS_BACKEND" == "Running" ]] && tailscale_ip >/dev/null 2>&1; then
      return 0
    fi
    sleep "$TS_PURGE_WAIT_INTERVAL"
  done
  return 1
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

  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  if ! wait_for_running_ipv4; then
    echo "WARN: purge: skipped; this node is not Running with a Tailscale IPv4 (BackendState=${TS_STATUS_BACKEND:-unknown}). Old devices named $TS_HOSTNAME are kept." >&2
    return 0
  fi
  ensure_secrets_for_recovery
  echo "recover: $TS_RECOVERY_REASON — node is up; purging stale hostname=$TS_HOSTNAME (keeping the live node)"
  prepare_purge_self_markers
  try_purge_stale_hostname
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(realpath "$(dirname "$0")/..")/lib/common.sh"
  box_access_parse_args "$@"
  step_purge
fi
