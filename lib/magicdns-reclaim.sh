# Reclaim a sticky MagicDNS name after the stale device is gone.
# Production: HostName was already `cursor` but DNSName stayed
# `cursor-1.<tailnet>.ts.net` until hostname was bounced tmp -> cursor.
# Requires: REPO, TS_HOSTNAME, python3, and (from the caller) tailscale_ip
# and try_purge_stale_hostname. Never prints secrets.

tailscale_as_root() {
  if [[ -n "${BOX_ACCESS_NOSUDO:-}" ]]; then
    tailscale "$@"
  else
    sudo tailscale "$@"
  fi
}

read_tailscale_status_fields() {
  local lib_dir line key val ip4
  TS_STATUS_HOST=""
  TS_STATUS_DNS=""
  TS_STATUS_HAS_SELF=0
  TS_SELF_IPS=""
  TS_SELF_IDS=""
  TS_SELF_IPV4=""
  TS_PURGE_REQUIRE_SELF=0

  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key=${line%% *}
    if [[ "$key" == "$line" ]]; then
      val=""
    else
      val=${line#* }
    fi
    case "$key" in
      HAS_SELF) TS_STATUS_HAS_SELF=$val ;;
      HOST) TS_STATUS_HOST=$val ;;
      DNS) TS_STATUS_DNS=$val ;;
      IPS) TS_SELF_IPS=$val ;;
      IDS) TS_SELF_IDS=$val ;;
    esac
  done < <(tailscale_as_root status --json 2>/dev/null | python3 "$lib_dir/magicdns.py" status-fields || true)

  ip4=$(tailscale_ip 2>/dev/null || true)
  TS_SELF_IPV4=$ip4
  if [[ -n "$ip4" && " $TS_SELF_IPS " != *" $ip4 "* ]]; then
    TS_SELF_IPS="${TS_SELF_IPS:+$TS_SELF_IPS }$ip4"
  fi

  if [[ -n "$TS_SELF_IPS" ]]; then
    TS_PURGE_REQUIRE_SELF=1
  elif [[ "$TS_STATUS_HAS_SELF" == "1" ]]; then
    # Logged in, but we cannot see our Tailscale IPv4. Do not delete by id:
    # the API id and Self.ID are different forms.
    TS_PURGE_REQUIRE_SELF=1
    TS_SELF_IDS=""
  else
    TS_PURGE_REQUIRE_SELF=0
  fi
}

prepare_purge_self_markers() {
  read_tailscale_status_fields
  if [[ "$TS_PURGE_REQUIRE_SELF" == "1" && -n "$TS_SELF_IPV4" ]]; then
    echo "purge: live node Tailscale IPv4=$TS_SELF_IPV4 (that device will be kept)"
  elif [[ "$TS_PURGE_REQUIRE_SELF" == "1" ]]; then
    echo "purge: live node present but Tailscale IPv4 unknown; purge will refuse" >&2
  else
    echo "purge: no live self node; hostname matches are stale"
  fi
}

set_tailscale_hostname() {
  local name=$1
  if tailscale_as_root set --hostname="$name"; then
    return 0
  fi
  echo "magicdns: tailscale set --hostname=$name failed; trying tailscale up --hostname=$name" >&2
  tailscale_as_root up --hostname="$name"
}

wait_for_hostname() {
  local want=$1
  local tries=${2:-15}
  local i
  for ((i = 0; i < tries; i++)); do
    read_tailscale_status_fields
    if [[ "$TS_STATUS_HOST" == "$want" || "${TS_STATUS_HOST,,}" == "${want,,}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_dns_label() {
  local want=$1
  local tries=${2:-20}
  local i label lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  for ((i = 0; i < tries; i++)); do
    read_tailscale_status_fields
    label=$(python3 "$lib_dir/magicdns.py" label "$TS_STATUS_DNS")
    if [[ "$label" == "${want,,}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Bounce tmp -> desired. The temporary name is what cleared a sticky
# cursor-1 MagicDNS label in production; setting the desired name alone did not.
bounce_hostname_for_magicdns() {
  local want=$1
  echo "magicdns: bounce hostname tmp -> $want"
  if ! set_tailscale_hostname tmp; then
    echo "WARN: could not set temporary hostname tmp" >&2
    return 1
  fi
  if ! wait_for_hostname tmp 15; then
    echo "WARN: HostName did not become tmp within timeout; setting $want anyway" >&2
  fi
  if ! set_tailscale_hostname "$want"; then
    echo "WARN: could not set hostname $want" >&2
    return 1
  fi
  if ! wait_for_dns_label "$want" 20; then
    echo "WARN: MagicDNS label is not $want yet (DNSName=${TS_STATUS_DNS:-unknown})" >&2
    return 1
  fi
  echo "magicdns: reclaimed DNSName=${TS_STATUS_DNS}"
}

reclaim_magicdns_if_needed() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  read_tailscale_status_fields
  if ! python3 "$lib_dir/magicdns.py" stuck "$TS_STATUS_HOST" "$TS_STATUS_DNS" "${TS_HOSTNAME:-cursor}"; then
    echo "magicdns: no reclaim (HostName=${TS_STATUS_HOST:-unknown} DNSName=${TS_STATUS_DNS:-unknown})"
    return 0
  fi

  echo "magicdns: HostName=${TS_STATUS_HOST:-unknown} DNSName=${TS_STATUS_DNS:-unknown} is stuck; reclaiming ${TS_HOSTNAME}"
  echo "magicdns: purge other devices named ${TS_HOSTNAME}, then bounce hostname tmp -> ${TS_HOSTNAME}"
  # read_tailscale_status_fields already set the self markers. Keep them so
  # purge cannot delete this node. Refresh once more in case the IP just appeared.
  prepare_purge_self_markers
  try_purge_stale_hostname || true
  if ! bounce_hostname_for_magicdns "$TS_HOSTNAME"; then
    echo "WARN: MagicDNS reclaim did not finish; SSH still uses the Tailscale IPv4 on port 2222." >&2
  fi
  return 0
}
