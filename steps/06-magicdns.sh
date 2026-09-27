#!/usr/bin/env bash
# Reclaim MagicDNS when HostName is correct but the DNS label is stuck
# (cursor-1.<tailnet>.ts.net). Bounce hostname tmp → TS_HOSTNAME.
# Purge of the other device with that hostname happens inside the reclaim,
# and it skips this node's Tailscale IPv4.

step_magicdns() {
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  reclaim_magicdns_if_needed
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_magicdns
fi
